const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const public_dir_opt = b.option(
        []const u8,
        "public-dir",
        "Directory whose contents are baked into the binary and served at /public/*",
    );

    const i18n_dir_opt = b.option([]const u8, "i18n-dir", "Directory of <locale>.json catalogs (default: i18n)") orelse "i18n";
    const i18n_default_opt = b.option([]const u8, "i18n-default", "Default locale tag for the lazy catalog");

    // Lower the build-time IBL prefilter sample counts (faster build, coarser
    // environment lighting). The .venv format is unchanged — only quality.
    const gl_ibl_fast = b.option(bool, "gl-ibl-fast", "Faster, lower-quality IBL prefilter (fewer samples)") orelse false;

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const verve_mod = b.addModule("verve", .{
        .root_source_file = b.path("src/verve.zig"),
    });

    // Build-generated per-locale i18n catalog (LazyCatalog manifest).
    const i18n_catalog_mod = buildI18nCatalog(b, i18n_dir_opt, i18n_default_opt, verve_mod);

    // Public façade for downstream wasm clients (desktop template,
    // browser-only apps). Re-exports reactive primitives from `verve`
    // plus the DOM-wired adapter from `src/client/runtime.zig`. Target-
    // agnostic so the same module satisfies both host-target tests and
    // wasm32-freestanding consumers.
    const verve_client_mod = b.addModule("verve_client", .{
        .root_source_file = b.path("src/client/verve_client.zig"),
        .imports = &.{
            .{ .name = "verve", .module = verve_mod },
        },
    });
    _ = verve_client_mod;

    // Phase 13F — chunk-side façade. Each per-island chunk imports
    // this module as `verve`; it carries the `extern "verve_runtime"`
    // declarations the bridge JS resolves against the main client's
    // exports at instantiation time. Wasm-only by construction (its
    // externs don't exist on the native target) so per-island chunks
    // are the only consumers.
    // Core codec modules the chunk runtime needs for typed props + island
    // state (chunks can't reach ../core via relative import — module path is
    // src/client). Exposed by name so `island_runtime.zig` can @import them.
    const serialize_island_mod = b.createModule(.{
        .root_source_file = b.path("src/core/serialize.zig"),
    });
    const island_state_island_mod = b.createModule(.{
        .root_source_file = b.path("src/core/island_state.zig"),
    });
    // Pure viz math (geometry, layouts, interaction, edge paths) so chunks
    // can recompute layouts client-side with the exact SSR algorithms.
    const viz_core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/viz/client_core.zig"),
    });
    // Pure anim builders (tween/timeline/easing/stagger + wire serializer)
    // so chunks can construct descriptors for the verve.js interpreter.
    const anim_core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/anim/client_core.zig"),
    });
    // Pure gl engine (math/scene/command/mesh) so island chunks can
    // build scenes + encode command streams without the full verve module.
    const gl_core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/gl/gl.zig"),
    });
    const verve_island_mod = b.addModule("verve_island", .{
        .root_source_file = b.path("src/client/island_runtime.zig"),
        .imports = &.{
            .{ .name = "serialize", .module = serialize_island_mod },
            .{ .name = "island_state", .module = island_state_island_mod },
            .{ .name = "viz_core", .module = viz_core_mod },
            .{ .name = "anim_core", .module = anim_core_mod },
            .{ .name = "gl_core", .module = gl_core_mod },
        },
    });

    const client_mod = b.createModule(.{
        .root_source_file = b.path("src/client/main.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "verve", .module = verve_mod },
        },
    });
    // `client_manifest_mod` is wired into the client below — its
    // module is created after `app_mod` because the codegen run needs
    // `app.islands` to resolve at the tool's comptime.
    const wasm = b.addExecutable(.{
        .name = "client",
        .root_module = client_mod,
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    // Table isolation — the main client IMPORTS its indirect function
    // table from JS (`env.__indirect_function_table`), so the bridge owns
    // a growable table. Island chunks instantiate against PRIVATE tables;
    // any fn-pointer index a chunk hands the main runtime (registerEvent,
    // timers, response/drop handlers) is translated by the bridge into a
    // freshly grown slot of this table. Previously main exported its own
    // fixed-size table and chunks imported it directly — but a chunk's
    // element segment writes at slots 1..count, clobbering the main
    // client's own entries ("function signature mismatch" once a chunk's
    // address-taken set grew past the slots main happened not to call).
    wasm.import_table = true;

    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(wasm.getEmittedBin(), "client.wasm");
    _ = wf.addCopyFile(b.path("src/bridge/verve.js"), "verve.js");
    _ = wf.addCopyFile(b.path("src/bridge/verve-worker.js"), "verve-worker.js");

    // Phase 13D: meta-codegen builds one WASM chunk per island
    // declared under `app.islands`. Names are discovered by parsing
    // `src/app/islands.zig` at configure time — the codegen tool used
    // for the manifest can't feed back into the build graph since
    // build.zig already has to know which targets to add. Each
    // island uses its dedicated source file (`src/client/islands/
    // <Name>.zig`) when present, falling back to the shared
    // `_default.zig` stub otherwise.
    const island_names = discoverIslandNames(b);

    var assets_buf: std.ArrayList(u8) = .empty;
    assets_buf.appendSlice(b.allocator,
        \\pub const wasm: []const u8 = @embedFile("client.wasm");
        \\pub const js: []const u8 = @embedFile("verve.js");
        \\pub const worker_js: []const u8 = @embedFile("verve-worker.js");
        \\
        \\pub const IslandChunk = struct { name: []const u8, bytes: []const u8 };
        \\
        \\pub const island_chunks: []const IslandChunk = &.{
        \\
    ) catch @panic("OOM");

    for (island_names) |name| {
        const source_rel = b.fmt("src/client/islands/{s}.zig", .{name});
        const fallback_rel = "src/client/islands/_default.zig";
        // Custom source wins when the file exists on disk; otherwise
        // every island shares the default stub.
        const io_h = b.graph.io;
        const exists = blk: {
            var probe = b.build_root.handle.openFile(io_h, source_rel, .{}) catch break :blk false;
            probe.close(io_h);
            break :blk true;
        };
        const rel = if (exists) source_rel else fallback_rel;

        const island_mod = b.createModule(.{
            .root_source_file = b.path(rel),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .imports = &.{
                .{ .name = "verve", .module = verve_island_mod },
            },
        });
        const exe = b.addExecutable(.{
            .name = b.fmt("island_{s}", .{name}),
            .root_module = island_mod,
        });
        exe.entry = .disabled;
        exe.rdynamic = true;
        // Phase 13E: per-island chunks share the main client's
        // linear memory at instantiation time. Combined with
        // chunk sources that declare zero static state, this lets
        // the chunks ship as pure-function bundles with no
        // duplicated runtime bytes.
        exe.import_memory = true;
        // Phase 13G: chunks import the main client's exported
        // indirect function table. Any `&handler` reference taken
        // inside the chunk lands in this table; the main runtime's
        // `event_slots` stores the same index and dispatches into
        // chunk code via `call_indirect`.
        exe.import_table = true;
        // Small stack — chunks only hold transient locals during
        // `hydrate`; the linker reserves the bottom of imported
        // memory for it, which the main runtime is responsible
        // for avoiding (`__heap_base` ≥ stack ceiling).
        exe.stack_size = 4 * 1024;

        const out_name = b.fmt("island_{s}.wasm", .{name});
        _ = wf.addCopyFile(exe.getEmittedBin(), out_name);

        const line = b.fmt(
            "    .{{ .name = \"{s}\", .bytes = @embedFile(\"{s}\") }},\n",
            .{ name, out_name },
        );
        assets_buf.appendSlice(b.allocator, line) catch @panic("OOM");
    }

    assets_buf.appendSlice(b.allocator,
        \\};
        \\
        \\pub fn lookupIslandChunk(name: []const u8) ?IslandChunk {
        \\    const std_mod = @import("std");
        \\    for (island_chunks) |c| {
        \\        if (std_mod.mem.eql(u8, c.name, name)) return c;
        \\    }
        \\    return null;
        \\}
        \\
    ) catch @panic("OOM");

    _ = wf.add("assets.zig", assets_buf.items);
    const assets_mod = b.createModule(.{
        .root_source_file = wf.getDirectory().path(b, "assets.zig"),
    });

    const public_assets_mod = buildPublicAssets(b, public_dir_opt);

    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/app/api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "verve", .module = verve_mod },
        },
    });

    // Codegen tools always target the host: they run during the
    // build to emit Zig source the cross-target server binary then
    // imports. Cross-compiling them would produce binaries the host
    // can't execute. The duplicate `app`/`verve` host modules are
    // build-time only — they don't ship in the produced artifacts.
    const host_target = b.graph.host;
    const host_verve_mod = b.createModule(.{
        .root_source_file = b.path("src/verve.zig"),
        .target = host_target,
    });
    const host_app_mod = b.createModule(.{
        .root_source_file = b.path("src/app/api.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "verve", .module = host_verve_mod },
        },
    });

    // GL asset pipeline: gen_demo_glb → demo.glb → gl_asset_gen → demo.vmesh
    // → embedded gl_assets.zig. Both tools target the host so they can run
    // during the build (same rule as the codegen tools above). The `verve_gl`
    // host module wraps src/core/gl/gl.zig with a host target so the tools
    // can call the full native-side pipeline (fixture, gltf, vmesh, png).
    const host_gl_mod = b.createModule(.{
        .root_source_file = b.path("src/core/gl/gl.zig"),
        .target = host_target,
        .optimize = optimize,
    });

    const gen_demo_glb_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_demo_glb.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "verve_gl", .module = host_gl_mod },
        },
    });
    const gen_demo_glb_exe = b.addExecutable(.{
        .name = "verve-gen-demo-glb",
        .root_module = gen_demo_glb_mod,
    });
    const gen_demo_glb_run = b.addRunArtifact(gen_demo_glb_exe);
    const demo_glb_path = gen_demo_glb_run.addOutputFileArg("demo.glb");

    // Mixed-material GLB: two named meshes ("MixedFull" full-PBR, "MixedBase"
    // base-color only). The distinct materials drive the per-submesh shader-
    // variant fan-out at render time (/gl-mixed demo route).
    const gen_mixed_glb_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_mixed_glb.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "verve_gl", .module = host_gl_mod },
        },
    });
    const gen_mixed_glb_exe = b.addExecutable(.{
        .name = "verve-gen-mixed-glb",
        .root_module = gen_mixed_glb_mod,
    });
    const gen_mixed_glb_run = b.addRunArtifact(gen_mixed_glb_exe);
    const mixed_glb_path = gen_mixed_glb_run.addOutputFileArg("mixed.glb");

    // Cutout demo GLB: a single cube ("Cutout") whose base-color texture has an
    // alpha channel with HOLES and whose material is alphaMode:MASK (cutoff 0.5).
    // The variant_alpha_test shader discards sub-cutoff fragments (/gl-cutout).
    const gen_cutout_glb_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_cutout_glb.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "verve_gl", .module = host_gl_mod },
        },
    });
    const gen_cutout_glb_exe = b.addExecutable(.{
        .name = "verve-gen-cutout-glb",
        .root_module = gen_cutout_glb_mod,
    });
    const gen_cutout_glb_run = b.addRunArtifact(gen_cutout_glb_exe);
    const cutout_glb_path = gen_cutout_glb_run.addOutputFileArg("cutout.glb");

    // Shadow demo GLB: a cube above a floor quad ("Cube" + "Floor"), both
    // base-color only. The floor receives the cube's directional shadow
    // (P9 slice 3, /gl-shadow demo route).
    const gen_shadow_glb_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_shadow_glb.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "verve_gl", .module = host_gl_mod },
        },
    });
    const gen_shadow_glb_exe = b.addExecutable(.{
        .name = "verve-gen-shadow-glb",
        .root_module = gen_shadow_glb_mod,
    });
    const gen_shadow_glb_run = b.addRunArtifact(gen_shadow_glb_exe);
    const shadow_glb_path = gen_shadow_glb_run.addOutputFileArg("shadow.glb");

    // Skinned-bar GLB: a rigged bar (3-joint chain + JOINTS_0/WEIGHTS_0) for
    // the skinning demo (slice 1, /gl-skin route).
    const gen_skin_glb_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_skin_glb.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "verve_gl", .module = host_gl_mod },
        },
    });
    const gen_skin_glb_exe = b.addExecutable(.{
        .name = "verve-gen-skin-glb",
        .root_module = gen_skin_glb_mod,
    });
    const gen_skin_glb_run = b.addRunArtifact(gen_skin_glb_exe);
    const skin_glb_path = gen_skin_glb_run.addOutputFileArg("skinbar.glb");

    const gl_asset_gen_mod = b.createModule(.{
        .root_source_file = b.path("tools/gl_asset_gen.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "verve_gl", .module = host_gl_mod },
        },
    });
    const gl_asset_gen_exe = b.addExecutable(.{
        .name = "verve-gl-asset-gen",
        .root_module = gl_asset_gen_mod,
    });
    // argv shape: <in> <out_dir> <stem>. The tool writes <out_dir>/<stem>.vmesh
    // plus one <out_dir>/<stem>.tex{index}.{ext} per externalized large texture.
    const gl_asset_gen_run = b.addRunArtifact(gl_asset_gen_exe);
    gl_asset_gen_run.addFileArg(demo_glb_path);
    const demo_dir = gl_asset_gen_run.addOutputDirectoryArg("demo");
    gl_asset_gen_run.addArg("demo");

    // Mixed-material asset through the same gl_asset_gen binary (glb → vmesh).
    const gl_asset_gen_mixed_run = b.addRunArtifact(gl_asset_gen_exe);
    gl_asset_gen_mixed_run.addFileArg(mixed_glb_path);
    const mixed_dir = gl_asset_gen_mixed_run.addOutputDirectoryArg("mixed");
    gl_asset_gen_mixed_run.addArg("mixed");

    // Cutout asset through the same gl_asset_gen binary (glb → vmesh). The 256²
    // RGBA base (alpha holes) externalizes to cutout.tex0.png like demo's.
    const gl_asset_gen_cutout_run = b.addRunArtifact(gl_asset_gen_exe);
    gl_asset_gen_cutout_run.addFileArg(cutout_glb_path);
    const cutout_dir = gl_asset_gen_cutout_run.addOutputDirectoryArg("cutout");
    gl_asset_gen_cutout_run.addArg("cutout");

    // Shadow-demo asset through the same gl_asset_gen binary (glb → vmesh).
    const gl_asset_gen_shadow_run = b.addRunArtifact(gl_asset_gen_exe);
    gl_asset_gen_shadow_run.addFileArg(shadow_glb_path);
    const shadow_dir = gl_asset_gen_shadow_run.addOutputDirectoryArg("shadow");
    gl_asset_gen_shadow_run.addArg("shadow");

    // Skinned-bar asset through the same gl_asset_gen binary (skinned glb →
    // vmesh v5 with skeleton). 8×8 base stays in-blob (no sidecar texture).
    const gl_asset_gen_skin_run = b.addRunArtifact(gl_asset_gen_exe);
    gl_asset_gen_skin_run.addFileArg(skin_glb_path);
    const skin_dir = gl_asset_gen_skin_run.addOutputDirectoryArg("skinbar");
    gl_asset_gen_skin_run.addArg("skinbar");

    // Wind-farm asset: gen_windfarm_glb → windfarm.glb → gl_asset_gen → windfarm.vmesh.
    const gen_windfarm_glb_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_windfarm_glb.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "verve_gl", .module = host_gl_mod },
        },
    });
    const gen_windfarm_glb_exe = b.addExecutable(.{
        .name = "verve-gen-windfarm-glb",
        .root_module = gen_windfarm_glb_mod,
    });
    const gen_windfarm_glb_run = b.addRunArtifact(gen_windfarm_glb_exe);
    const windfarm_glb_path = gen_windfarm_glb_run.addOutputFileArg("windfarm.glb");

    const gl_asset_gen_windfarm_run = b.addRunArtifact(gl_asset_gen_exe);
    gl_asset_gen_windfarm_run.addFileArg(windfarm_glb_path);
    const windfarm_dir = gl_asset_gen_windfarm_run.addOutputDirectoryArg("windfarm");
    gl_asset_gen_windfarm_run.addArg("windfarm");

    // HDR fixture → studio.hdr → studio.venv pipeline.
    // gen_demo_hdr writes the procedural studio environment; the same
    // gl_asset_gen binary (branching on the .hdr extension) runs the full
    // IBL prefilter chain and writes a packed .venv file.
    const gen_demo_hdr_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_demo_hdr.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "verve_gl", .module = host_gl_mod },
        },
    });
    const gen_demo_hdr_exe = b.addExecutable(.{
        .name = "verve-gen-demo-hdr",
        .root_module = gen_demo_hdr_mod,
    });
    const gen_demo_hdr_run = b.addRunArtifact(gen_demo_hdr_exe);
    const studio_hdr_path = gen_demo_hdr_run.addOutputFileArg("studio.hdr");

    const gl_asset_gen_hdr_run = b.addRunArtifact(gl_asset_gen_exe);
    gl_asset_gen_hdr_run.addFileArg(studio_hdr_path);
    const studio_dir = gl_asset_gen_hdr_run.addOutputDirectoryArg("studio");
    gl_asset_gen_hdr_run.addArg("studio");
    if (gl_ibl_fast) gl_asset_gen_hdr_run.addArg("--fast");

    // Embed the generated assets into a gl_assets.zig source that the server
    // imports. Pattern mirrors the island_chunks embedded table above.
    const wf_gl = b.addWriteFiles();
    _ = wf_gl.addCopyFile(demo_dir.path(b, "demo.vmesh"), "demo.vmesh");
    // Demo's 256² base texture is externalized as a sibling compressed PNG.
    _ = wf_gl.addCopyFile(demo_dir.path(b, "demo.tex0.png"), "demo.tex0.png");
    _ = wf_gl.addCopyFile(mixed_dir.path(b, "mixed.vmesh"), "mixed.vmesh");
    _ = wf_gl.addCopyFile(cutout_dir.path(b, "cutout.vmesh"), "cutout.vmesh");
    // Cutout's 256² alpha-hole base texture is externalized as a sibling PNG.
    _ = wf_gl.addCopyFile(cutout_dir.path(b, "cutout.tex0.png"), "cutout.tex0.png");
    _ = wf_gl.addCopyFile(shadow_dir.path(b, "shadow.vmesh"), "shadow.vmesh");
    _ = wf_gl.addCopyFile(skin_dir.path(b, "skinbar.vmesh"), "skinbar.vmesh");
    _ = wf_gl.addCopyFile(windfarm_dir.path(b, "windfarm.vmesh"), "windfarm.vmesh");
    _ = wf_gl.addCopyFile(studio_dir.path(b, "studio.venv"), "studio.venv");
    const gl_assets_src =
        \\// Generated by build.zig — do not edit.
        \\pub const GlAsset = struct { name: []const u8, bytes: []const u8 };
        \\
        \\pub const gl_assets: []const GlAsset = &.{
        \\    .{ .name = "demo.vmesh", .bytes = @embedFile("demo.vmesh") },
        \\    .{ .name = "demo.tex0.png", .bytes = @embedFile("demo.tex0.png") },
        \\    .{ .name = "mixed.vmesh", .bytes = @embedFile("mixed.vmesh") },
        \\    .{ .name = "cutout.vmesh", .bytes = @embedFile("cutout.vmesh") },
        \\    .{ .name = "cutout.tex0.png", .bytes = @embedFile("cutout.tex0.png") },
        \\    .{ .name = "shadow.vmesh", .bytes = @embedFile("shadow.vmesh") },
        \\    .{ .name = "skinbar.vmesh", .bytes = @embedFile("skinbar.vmesh") },
        \\    .{ .name = "windfarm.vmesh", .bytes = @embedFile("windfarm.vmesh") },
        \\    .{ .name = "studio.venv", .bytes = @embedFile("studio.venv") },
        \\};
        \\
        \\pub fn lookupGlAsset(name: []const u8) ?GlAsset {
        \\    const std_mod = @import("std");
        \\    for (gl_assets) |a| {
        \\        if (std_mod.mem.eql(u8, a.name, name)) return a;
        \\    }
        \\    return null;
        \\}
        \\
    ;
    _ = wf_gl.add("gl_assets.zig", gl_assets_src);
    const gl_assets_mod = b.createModule(.{
        .root_source_file = wf_gl.getDirectory().path(b, "gl_assets.zig"),
    });

    // Phase 11: typed client stubs for `app.Actions`. A small native
    // codegen binary imports `app` and prints a per-action wrapper to
    // stdout; the run step's captured output is grafted into the build
    // WriteFiles as `app_client.zig`, then wrapped as `app_client_mod`.
    const codegen_mod = b.createModule(.{
        .root_source_file = b.path("tools/server_fn_codegen.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "app", .module = host_app_mod },
        },
    });
    const codegen_exe = b.addExecutable(.{
        .name = "verve-codegen-server-fn",
        .root_module = codegen_mod,
    });
    const codegen_run = b.addRunArtifact(codegen_exe);
    const generated_app_client = codegen_run.captureStdOut(.{ .basename = "app_client.zig" });
    // Dedicated WriteFiles so the wasm client can import app_client.zig
    // without a dependency cycle through the main `wf` step (which holds
    // client.wasm, the output of the very client module that imports this).
    const wf_app_client = b.addWriteFiles();
    _ = wf_app_client.addCopyFile(generated_app_client, "app_client.zig");

    const app_client_mod = b.createModule(.{
        .root_source_file = wf_app_client.getDirectory().path(b, "app_client.zig"),
        .imports = &.{
            .{ .name = "verve", .module = verve_mod },
            .{ .name = "app", .module = app_mod },
        },
    });

    // Phase 13B: client island manifest. Companion codegen binary
    // walks `app.islands` at comptime and emits `client_manifest.zig`.
    const manifest_mod = b.createModule(.{
        .root_source_file = b.path("tools/island_manifest_gen.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "app", .module = host_app_mod },
        },
    });
    const manifest_exe = b.addExecutable(.{
        .name = "verve-codegen-islands",
        .root_module = manifest_mod,
    });
    const manifest_run = b.addRunArtifact(manifest_exe);
    const generated_manifest = manifest_run.captureStdOut(.{ .basename = "client_manifest.zig" });
    // Use a dedicated WriteFiles for the manifest so the WASM client
    // can import it without creating a dependency cycle through the
    // main `wf` step (which also holds `client.wasm`).
    const wf_manifest = b.addWriteFiles();
    _ = wf_manifest.addCopyFile(generated_manifest, "client_manifest.zig");

    const client_manifest_mod = b.createModule(.{
        .root_source_file = wf_manifest.getDirectory().path(b, "client_manifest.zig"),
    });
    client_mod.addImport("client_manifest", client_manifest_mod);
    // Compile the generated typed server-fn stubs into the wasm client so
    // `app_client.<name>_call` reaches a real round-trip call-site.
    client_mod.addImport("app_client", app_client_mod);

    const server_mod = b.createModule(.{
        .root_source_file = b.path("src/server/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "verve", .module = verve_mod },
            .{ .name = "assets", .module = assets_mod },
            .{ .name = "gl_assets", .module = gl_assets_mod },
            .{ .name = "app", .module = app_mod },
            .{ .name = "app_client", .module = app_client_mod },
            .{ .name = "client_manifest", .module = client_manifest_mod },
            .{ .name = "public_assets", .module = public_assets_mod },
            .{ .name = "i18n_catalog", .module = i18n_catalog_mod },
        },
    });
    const server = b.addExecutable(.{
        .name = "verve-server",
        .root_module = server_mod,
    });
    b.installArtifact(server);

    const run_cmd = b.addRunArtifact(server);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the Verve full-stack server");
    run_step.dependOn(&run_cmd.step);

    // ---- WebView2 native-host smoke exe (Windows) ---------------------------
    // Standalone smoke exe that drives the REAL native-host backend
    // (src/desktop/windows_native.zig) through its public `Window` surface.
    // Cross-compiles from any host so `zig build win-native` works on macOS;
    // gated to its own step so the default build never touches it. The GUI is
    // only runnable on Windows (human operator's job) — this gate just proves
    // the cross-compile + link is clean.
    inline for (.{
        .{ .arch = .x86_64, .step = "win-native", .name = "verve-win-native", .desc = "Build the WebView2 native-host smoke exe (Windows x86-64)" },
        .{ .arch = .aarch64, .step = "win-native-arm64", .name = "verve-win-native-arm64", .desc = "Build the WebView2 native-host smoke exe (Windows ARM64)" },
    }) |cfg| {
        const win_target = b.resolveTargetQuery(.{
            .cpu_arch = cfg.arch,
            .os_tag = .windows,
            .abi = .gnu,
        });
        const smoke_mod = b.createModule(.{
            .root_source_file = b.path("src/desktop/win_native/smoke/win_native_smoke.zig"),
            .target = win_target,
            .optimize = optimize,
        });
        // The smoke harness drives the real backend. Expose it as a named
        // import (a bare `@import("../../windows_native.zig")` would escape the
        // smoke module's path). windows_native.zig roots at src/desktop, so its
        // sibling `@import("options.zig")` etc. resolve naturally.
        const windows_native_mod = b.createModule(.{
            .root_source_file = b.path("src/desktop/windows_native.zig"),
            .target = win_target,
            .optimize = optimize,
        });
        smoke_mod.addImport("windows_native", windows_native_mod);
        linkWinNative(b, smoke_mod);

        const smoke_exe = b.addExecutable(.{
            .name = cfg.name,
            .root_module = smoke_mod,
        });
        // The exe LoadLibrary's WebView2Loader.dll at runtime, so each arch
        // needs ITS OWN loader sitting beside ITS exe — both vendored from the
        // same SDK (include/VERSION.txt). The arm64 pair installs under
        // bin/arm64/ because two same-named DLLs can't share one directory.
        const is_arm = cfg.arch == .aarch64;
        const smoke_install = b.addInstallArtifact(smoke_exe, .{
            .dest_dir = if (is_arm)
                .{ .override = .{ .custom = "bin/arm64" } }
            else
                .default,
        });
        const loader_src = if (is_arm)
            b.path("src/desktop/win_native/include/arm64/WebView2Loader.dll")
        else
            b.path("src/desktop/win_native/include/WebView2Loader.dll");
        const loader_install = if (is_arm)
            b.addInstallFileWithDir(loader_src, .{ .custom = "bin/arm64" }, "WebView2Loader.dll")
        else
            b.addInstallBinFile(loader_src, "WebView2Loader.dll");
        const native_step = b.step(cfg.step, cfg.desc);
        native_step.dependOn(&smoke_install.step);
        native_step.dependOn(&loader_install.step);
    }

    // Dedicated server executable for the embed integration test, with
    // tests/public_fixture baked in regardless of the user's -Dpublic-dir
    // flag. Lets CI verify the embed path without polluting the main
    // production binary.
    //
    // When verve is consumed as a Zig package dependency, `tests/` is not
    // included (see build.zig.zon `.paths` — only src + LICENSE ship). Skip
    // every test-related artifact in that case so consumers don't trip the
    // panic in `buildPublicAssets`.
    const tests_present = blk: {
        const io_h = b.graph.io;
        var probe = b.build_root.handle.openDir(io_h, "tests/public_fixture", .{}) catch break :blk false;
        probe.close(io_h);
        break :blk true;
    };

    if (tests_present) {
        const embed_assets_mod = buildPublicAssets(b, "tests/public_fixture");
        const embed_server_mod = b.createModule(.{
            .root_source_file = b.path("src/server/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "verve", .module = verve_mod },
                .{ .name = "assets", .module = assets_mod },
                .{ .name = "gl_assets", .module = gl_assets_mod },
                .{ .name = "app", .module = app_mod },
                .{ .name = "app_client", .module = app_client_mod },
                .{ .name = "client_manifest", .module = client_manifest_mod },
                .{ .name = "public_assets", .module = embed_assets_mod },
            },
        });
        const embed_server = b.addExecutable(.{
            .name = "verve-server-embed",
            .root_module = embed_server_mod,
        });

        // CLI scaffolder. Embeds the entire project tree (sources + build
        // wiring + tests fixture) into the binary; `verve-cli new <dir>` then
        // writes it out as a self-contained starter app.
        const skeleton_mod = buildCliSkeleton(b);
        const skeleton_desktop_mod = buildCliSkeletonDesktop(b);
        const skeleton_desktop_minimal_mod = buildCliSkeletonDesktopMinimal(b);

        // Default verve dependency path baked into `verve-cli`. Desktop
        // scaffolds reference verve through a `.path` dep — without a
        // baked default the generated `build.zig.zon` would have to guess
        // `../verve`, which only works for sibling-layout projects. Users
        // can override per-scaffold via `verve-cli new --verve-path ...`,
        // and once verve ships GitHub releases this default flips to a
        // `.url + .hash` flow.
        const default_verve_path = b.option(
            []const u8,
            "verve-path",
            "Absolute path to the Verve checkout that scaffolded apps depend on (default: this build root)",
        ) orelse b.build_root.path orelse ".";
        const cli_options = b.addOptions();
        cli_options.addOption([]const u8, "default_verve_path", default_verve_path);

        const cli_mod = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "skeleton", .module = skeleton_mod },
                .{ .name = "skeleton_desktop", .module = skeleton_desktop_mod },
                .{ .name = "skeleton_desktop_minimal", .module = skeleton_desktop_minimal_mod },
            },
        });
        cli_mod.addOptions("build_options", cli_options);
        const cli = b.addExecutable(.{
            .name = "verve-cli",
            .root_module = cli_mod,
        });
        b.installArtifact(cli);

        const test_mod = b.createModule(.{
            .root_source_file = b.path("src/verve.zig"),
            .target = target,
            .optimize = optimize,
        });
        const tests = b.addTest(.{ .root_module = test_mod });
        const run_tests = b.addRunArtifact(tests);

        const server_test_mod = b.createModule(.{
            .root_source_file = b.path("src/server/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "verve", .module = verve_mod },
                .{ .name = "app", .module = app_mod },
                .{ .name = "app_client", .module = app_client_mod },
                .{ .name = "client_manifest", .module = client_manifest_mod },
            },
        });
        const server_tests = b.addTest(.{ .root_module = server_test_mod });
        const run_server_tests = b.addRunArtifact(server_tests);

        // Client modules are wasm-shaped but the data structures (FBA,
        // escape helpers) are target-agnostic. Run their tests on native
        // so they participate in `zig build test` without requiring a
        // wasm runtime.
        const client_test_mod = b.createModule(.{
            .root_source_file = b.path("src/client/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "verve", .module = verve_mod },
            },
        });
        const client_tests = b.addTest(.{ .root_module = client_test_mod });
        const run_client_tests = b.addRunArtifact(client_tests);

        // Demo-app action tests (api.zig test blocks). Tests only run from a
        // compilation's root module, so the app gets its own artifact.
        const app_test_mod = b.createModule(.{
            .root_source_file = b.path("src/app/api.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "verve", .module = verve_mod },
            },
        });
        const app_tests = b.addTest(.{ .root_module = app_test_mod });
        const run_app_tests = b.addRunArtifact(app_tests);

        const integration_opts = b.addOptions();
        integration_opts.addOptionPath("server_exe", server.getEmittedBin());
        integration_opts.addOptionPath("embed_server_exe", embed_server.getEmittedBin());
        integration_opts.addOptionPath("public_dir", b.path("tests/public_fixture"));

        const integration_mod = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
        });
        integration_mod.addOptions("build_options", integration_opts);

        const integration_tests = b.addTest(.{ .root_module = integration_mod });
        const run_integration_tests = b.addRunArtifact(integration_tests);
        run_integration_tests.step.dependOn(&server.step);
        run_integration_tests.step.dependOn(&embed_server.step);

        // Desktop platform layer's pure-Zig pieces (asset router, MIME
        // guess) get a headless test artifact so they run on every host
        // without requiring a windowing system. The native backends
        // (macos/windows/linux) are not exercised here.
        const desktop_test_mod = b.createModule(.{
            .root_source_file = b.path("src/desktop/asset_router_test.zig"),
            .target = target,
            .optimize = optimize,
        });
        // power.zig + single_instance.zig use extern "c" symbols (flock,
        // getenv, CoreFoundation / IOKit). Link libc on both macOS and
        // Linux so the test binary resolves them; Windows path uses
        // kernel32 which Zig links automatically.
        if (target.result.os.tag == .linux) {
            desktop_test_mod.link_libc = true;
        }
        if (target.result.os.tag == .macos) {
            desktop_test_mod.link_libc = true;
            desktop_test_mod.linkFramework("IOKit", .{});
            desktop_test_mod.linkFramework("CoreFoundation", .{});
            desktop_test_mod.linkFramework("SystemConfiguration", .{});
            desktop_test_mod.linkFramework("CoreServices", .{});
            desktop_test_mod.linkFramework("Carbon", .{});
        }
        const desktop_tests = b.addTest(.{ .root_module = desktop_test_mod });
        const run_desktop_tests = b.addRunArtifact(desktop_tests);

        // i18n catalog integration: load the build-generated module into a
        // LazyCatalog and resolve fixture keys end-to-end.
        const i18n_it_mod = b.createModule(.{
            .root_source_file = b.path("tests/i18n_catalog_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "verve", .module = verve_mod },
                .{ .name = "i18n_catalog", .module = i18n_catalog_mod },
            },
        });
        const i18n_it_tests = b.addTest(.{ .root_module = i18n_it_mod });
        const run_i18n_it_tests = b.addRunArtifact(i18n_it_tests);

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_tests.step);
        test_step.dependOn(&run_i18n_it_tests.step);
        test_step.dependOn(&run_server_tests.step);
        test_step.dependOn(&run_client_tests.step);
        test_step.dependOn(&run_app_tests.step);
        test_step.dependOn(&run_integration_tests.step);
        test_step.dependOn(&run_desktop_tests.step);
    } // end if (tests_present)

    // ---- Autodoc generation -------------------------------------------------
    // `zig build docs` emits the Zig autodoc HTML/JS bundle for the
    // public `verve` module into `zig-out/docs/api/`. Open
    // `zig-out/docs/api/index.html` in a browser (or serve the
    // directory) to browse the generated reference.
    const docs_lib = b.addLibrary(.{
        .name = "verve",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/verve.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs/api",
    });
    const docs_step = b.step("docs", "Generate Zig autodoc for the verve module");
    docs_step.dependOn(&install_docs.step);
}

/// Wire the native WebView2 host (C++ behind a flat C ABI) into `mod`:
/// the vendored WebView2 headers, the host translation unit, and the
/// Win32/COM system libraries it links against. Used by both the
/// `win-native` smoke exe and (later) any consumer that selects the
/// native Windows backend.
fn linkWinNative(b: *std.Build, mod: *std.Build.Module) void {
    mod.addIncludePath(b.path("src/desktop/win_native/include"));
    mod.addCSourceFile(.{
        .file = b.path("src/desktop/win_native/webview2_host.cpp"),
        .flags = &.{
            "-std=c++17",
            "-fms-extensions",
            "-fno-exceptions",
            "-fno-rtti",
            "-DUNICODE",
            "-D_UNICODE",
        },
    });
    // host.h is a sibling of webview2_host.cpp; addCSourceFile resolves
    // quote-includes (`#include "host.h"`) relative to the .cpp's own
    // directory, so no extra include path is needed for it.
    mod.linkSystemLibrary("ole32", .{});
    mod.linkSystemLibrary("shell32", .{}); // DragQueryFileW (CF_HDROP)
    mod.linkSystemLibrary("comdlg32", .{}); // GetOpen/SaveFileNameW
    mod.linkSystemLibrary("user32", .{});
    mod.linkSystemLibrary("gdi32", .{});
    mod.linkSystemLibrary("windowscodecs", .{}); // WIC: clipboard PNG<->DIB transcode
    mod.linkSystemLibrary("shlwapi", .{}); // SHCreateMemStream (clipboard image)
    // Bundle 8: server-side UIA provider (a11y). uiautomationcore.dll carries
    // UiaReturnRawElementProvider / UiaHostProviderFromHwnd; oleaut32 carries
    // SysAllocString / VariantInit for the property VARIANTs. Ports the legacy
    // windows.zig backend's IRawElementProviderSimple.
    mod.linkSystemLibrary("uiautomationcore", .{});
    mod.linkSystemLibrary("oleaut32", .{});
    // Bundle 8: WinRT toast. combase.dll has no x86_64 import lib in zig's
    // bundled mingw — link the split API-set stubs that carry Ro*/Windows*String
    // (proven to cross-compile by the legacy backend, commit 76a7374).
    mod.linkSystemLibrary("api-ms-win-core-winrt-l1-1-0", .{}); // Ro* (Initialize/Activate/Factory)
    mod.linkSystemLibrary("api-ms-win-core-winrt-string-l1-1-0", .{}); // Windows*String (HSTRING)
    mod.link_libc = true;
}

/// Walk `dir_opt` (relative to build root) at configure time, copy each
/// regular file into a generated WriteFiles directory, and emit a
/// `public_assets.zig` manifest containing `@embedFile` references plus
/// a content-type guess and a content hash for cache-busting. When
/// `dir_opt` is null an empty manifest is emitted so the server module's
/// import always resolves.
fn buildPublicAssets(b: *std.Build, dir_opt: ?[]const u8) *std.Build.Module {
    const wf = b.addWriteFiles();
    const manifest_header =
        \\const std = @import("std");
        \\
        \\pub const Entry = struct {
        \\    path: []const u8,
        \\    bytes: []const u8,
        \\    content_type: []const u8,
        \\    /// Lower 32 bits of Wyhash(bytes). Rendered as 8 hex chars in
        \\    /// the hashed-asset URL — collision-resistant enough for cache
        \\    /// busting without inflating the path length.
        \\    hash: u32,
        \\};
        \\
        \\pub const entries: []const Entry = &.{
        \\
    ;

    if (dir_opt) |dir| {
        var manifest: std.ArrayList(u8) = .empty;

        manifest.appendSlice(b.allocator, manifest_header) catch @panic("OOM");

        const io = b.graph.io;
        var root = b.build_root.handle.openDir(io, dir, .{ .iterate = true }) catch |err| {
            std.debug.print("verve: -Dpublic-dir={s} open failed: {s}\n", .{ dir, @errorName(err) });
            @panic("public-dir not found");
        };
        defer root.close(io);

        var walker = root.walk(b.allocator) catch @panic("OOM");
        defer walker.deinit();

        while (walker.next(io) catch @panic("walk failed")) |entry| {
            if (entry.kind != .file) continue;

            // Forward slashes in the manifest so @embedFile resolves on
            // Windows hosts too. The walker yields native separators.
            const path_forward = b.allocator.dupe(u8, entry.path) catch @panic("OOM");
            for (path_forward) |*c| if (c.* == '\\') {
                c.* = '/';
            };

            const lazy = b.path(b.pathJoin(&.{ dir, entry.path }));
            _ = wf.addCopyFile(lazy, path_forward);

            // Hash the bytes once at configure time so we can embed the
            // hash in the manifest. The runtime never re-hashes.
            const native_path = b.pathJoin(&.{ dir, entry.path });
            var f = b.build_root.handle.openFile(io, native_path, .{}) catch @panic("asset open failed");
            defer f.close(io);
            const stat = f.stat(io) catch @panic("asset stat failed");
            const bytes = b.allocator.alloc(u8, @intCast(stat.size)) catch @panic("OOM");
            defer b.allocator.free(bytes);
            _ = f.readPositionalAll(io, bytes, 0) catch @panic("asset read failed");
            const hash64 = std.hash.Wyhash.hash(0, bytes);
            const hash32: u32 = @truncate(hash64);

            const ct = guessContentType(entry.path);
            const line = std.fmt.allocPrint(b.allocator,
                \\    .{{ .path = "{s}", .bytes = @embedFile("{s}"), .content_type = "{s}", .hash = 0x{x:0>8} }},
                \\
            , .{ path_forward, path_forward, ct, hash32 }) catch @panic("OOM");
            manifest.appendSlice(b.allocator, line) catch @panic("OOM");
        }

        manifest.appendSlice(b.allocator, "};\n\n" ++ manifest_helpers) catch @panic("OOM");
        _ = wf.add("public_assets.zig", manifest.items);
    } else {
        _ = wf.add("public_assets.zig", manifest_header ++ "};\n\n" ++ manifest_helpers);
    }

    return b.createModule(.{
        .root_source_file = wf.getDirectory().path(b, "public_assets.zig"),
    });
}

/// Walk `dir` for `<tag>.json` locale files at configure time and generate an
/// `i18n_catalog` module: per-locale `@embedFile` blobs + a `locales` manifest
/// of `verve.I18nLocale`. Missing dir → empty manifest (graceful). `default`
/// is the default locale tag (else the first tag alphabetically). Mirrors
/// `buildPublicAssets`'s configure-time walk + embed.
fn buildI18nCatalog(b: *std.Build, dir: []const u8, default: ?[]const u8, verve_mod: *std.Build.Module) *std.Build.Module {
    const wf = b.addWriteFiles();
    var manifest: std.ArrayList(u8) = .empty;
    manifest.appendSlice(b.allocator,
        \\const Locale = @import("verve").I18nLocale;
        \\
        \\pub const locales: []const Locale = &.{
        \\
    ) catch @panic("OOM");

    var first_tag: ?[]const u8 = null;
    const io = b.graph.io;
    if (b.build_root.handle.openDir(io, dir, .{ .iterate = true })) |root_const| {
        var root = root_const;
        defer root.close(io);
        var walker = root.walk(b.allocator) catch @panic("OOM");
        defer walker.deinit();
        while (walker.next(io) catch @panic("i18n walk failed")) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".json")) continue;
            // Flat layout only: skip files nested in subdirs (their basenames
            // could collide across dirs, producing duplicate locale tags).
            if (!std.mem.eql(u8, entry.path, entry.basename)) continue;
            const tag = entry.basename[0 .. entry.basename.len - ".json".len];
            const tag_owned = b.allocator.dupe(u8, tag) catch @panic("OOM");
            if (first_tag == null or std.mem.lessThan(u8, tag_owned, first_tag.?)) first_tag = tag_owned;
            // Forward slashes so @embedFile resolves on Windows hosts too.
            const path_forward = b.allocator.dupe(u8, entry.path) catch @panic("OOM");
            for (path_forward) |*c| if (c.* == '\\') {
                c.* = '/';
            };
            _ = wf.addCopyFile(b.path(b.pathJoin(&.{ dir, entry.path })), path_forward);
            manifest.appendSlice(b.allocator, b.fmt(
                "    .{{ .tag = \"{s}\", .json = @embedFile(\"{s}\") }},\n",
                .{ tag_owned, path_forward },
            )) catch @panic("OOM");
        }
    } else |_| {
        // Missing dir → empty manifest. Graceful, like absent templates.
    }

    const default_tag = default orelse (first_tag orelse "");
    manifest.appendSlice(b.allocator, b.fmt(
        "}};\n\npub const default_locale: []const u8 = \"{s}\";\n",
        .{default_tag},
    )) catch @panic("OOM");

    const gen = wf.add("i18n_catalog.zig", manifest.items);
    return b.createModule(.{
        .root_source_file = gen,
        .imports = &.{.{ .name = "verve", .module = verve_mod }},
    });
}

/// Helper functions appended after the `entries` slice. Both lookups
/// run linearly over the entries; the public-asset count is small (and
/// hot files like style.css land near the front of the walk) so a hash
/// index isn't worth the build-time complexity.
const manifest_helpers =
    \\/// Look up an entry by its unhashed path (`style.css`). Used by
    \\/// `Context.assetHref` to resolve the hashed URL and by the server
    \\/// when a request arrives with the unhashed name.
    \\pub fn lookupByOriginalPath(path: []const u8) ?Entry {
    \\    for (entries) |e| {
    \\        if (std.mem.eql(u8, e.path, path)) return e;
    \\    }
    \\    return null;
    \\}
    \\
    \\/// Look up an entry by its hashed URL form (`style-7f4c1d20.css`).
    \\/// Returns null when no entry's `<basename>-<hash><ext>` matches the
    \\/// request path.
    \\pub fn lookupByHashedPath(hashed: []const u8) ?Entry {
    \\    for (entries) |e| {
    \\        var buf: [256]u8 = undefined;
    \\        const formatted = formatHashedPath(&buf, e) orelse continue;
    \\        if (std.mem.eql(u8, formatted, hashed)) return e;
    \\    }
    \\    return null;
    \\}
    \\
    \\/// Render an entry as `<basename>-<hash><ext>` into `buf`. Returns
    \\/// null when the resulting string would overflow.
    \\pub fn formatHashedPath(buf: []u8, e: Entry) ?[]const u8 {
    \\    const dot = std.mem.lastIndexOfScalar(u8, e.path, '.');
    \\    const stem = if (dot) |i| e.path[0..i] else e.path;
    \\    const ext = if (dot) |i| e.path[i..] else "";
    \\    return std.fmt.bufPrint(buf, "{s}-{x:0>8}{s}", .{ stem, e.hash, ext }) catch null;
    \\}
    \\
;

/// Walk the directories the scaffolded starter project needs and emit
/// `skeleton.zig`, a flat list of (relative-path, @embedFile-bytes)
/// entries. The CLI binary uses this list to lay out the new app.
fn buildCliSkeleton(b: *std.Build) *std.Build.Module {
    const wf = b.addWriteFiles();
    var manifest: std.ArrayList(u8) = .empty;

    manifest.appendSlice(b.allocator,
        \\pub const Entry = struct {
        \\    path: []const u8,
        \\    bytes: []const u8,
        \\};
        \\
        \\pub const entries: []const Entry = &.{
        \\
    ) catch @panic("OOM");

    embedSingleFile(b, wf, &manifest, "build.zig");
    embedSingleFile(b, wf, &manifest, "build.zig.zon");
    embedSingleFile(b, wf, &manifest, "LICENSE");
    embedTree(b, wf, &manifest, "src");
    embedTree(b, wf, &manifest, "tests");
    // `tools/` holds the build-time codegen binaries (server-fn stubs,
    // island manifest). The generated project's build.zig invokes them,
    // so they must travel with the scaffold.
    embedTree(b, wf, &manifest, "tools");

    manifest.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    _ = wf.add("skeleton.zig", manifest.items);

    return b.createModule(.{
        .root_source_file = wf.getDirectory().path(b, "skeleton.zig"),
    });
}

fn embedSingleFile(
    b: *std.Build,
    wf: *std.Build.Step.WriteFile,
    manifest: *std.ArrayList(u8),
    rel: []const u8,
) void {
    const dest = b.allocator.dupe(u8, rel) catch @panic("OOM");
    for (dest) |*c| if (c.* == '\\') {
        c.* = '/';
    };
    _ = wf.addCopyFile(b.path(rel), dest);
    const line = std.fmt.allocPrint(b.allocator,
        \\    .{{ .path = "{s}", .bytes = @embedFile("{s}") }},
        \\
    , .{ dest, dest }) catch @panic("OOM");
    manifest.appendSlice(b.allocator, line) catch @panic("OOM");
}

/// Sibling of `buildCliSkeleton` that produces the desktop template
/// manifest. The output tree layout is:
///
///   build.zig, build.zig.zon, LICENSE, README.md, .gitignore   ← from templates/desktop/
///   src/main.zig, src/handlers.zig, frontend/*, public/*       ← from templates/desktop/
///   src/desktop/*.zig                                          ← vendored from framework src/desktop/
///
/// The vendor step lets the produced project be self-contained: it
/// imports the platform window layer through a relative path inside
/// its own `src/desktop/` tree, with no compile-time dependency back
/// on the Verve checkout.
fn buildCliSkeletonDesktop(b: *std.Build) *std.Build.Module {
    const wf = b.addWriteFiles();
    var manifest: std.ArrayList(u8) = .empty;

    manifest.appendSlice(b.allocator,
        \\pub const Entry = struct {
        \\    path: []const u8,
        \\    bytes: []const u8,
        \\};
        \\
        \\pub const entries: []const Entry = &.{
        \\
    ) catch @panic("OOM");

    // The desktop template tree only exists in the framework checkout.
    // When the verve sources are vendored into a scaffolded app the
    // `templates/` directory is not shipped (web apps don't need it),
    // so emit an empty entry list rather than aborting the build. The
    // generated CLI in that case can still scaffold web projects.
    const io = b.graph.io;
    const have_templates = blk: {
        var probe = b.build_root.handle.openDir(io, "templates/desktop", .{}) catch break :blk false;
        probe.close(io);
        break :blk true;
    };

    if (have_templates) {
        // Root LICENSE is shared between web and desktop generated apps.
        embedSingleFile(b, wf, &manifest, "LICENSE");
        // Everything else comes from the desktop template tree (rooted at
        // `templates/desktop`) plus a vendored copy of the platform layer.
        embedTreeAs(b, wf, &manifest, "templates/desktop", "");
        embedTreeAs(b, wf, &manifest, "src/desktop", "src/desktop");
    }

    manifest.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    _ = wf.add("skeleton_desktop.zig", manifest.items);

    return b.createModule(.{
        .root_source_file = wf.getDirectory().path(b, "skeleton_desktop.zig"),
    });
}

/// Sibling of `buildCliSkeletonDesktop` that produces the minimal
/// desktop template — single window, single IPC route, static HTML.
/// Same vendoring of `src/desktop/` so the scaffolded app is self-
/// contained.
fn buildCliSkeletonDesktopMinimal(b: *std.Build) *std.Build.Module {
    const wf = b.addWriteFiles();
    var manifest: std.ArrayList(u8) = .empty;

    manifest.appendSlice(b.allocator,
        \\pub const Entry = struct {
        \\    path: []const u8,
        \\    bytes: []const u8,
        \\};
        \\
        \\pub const entries: []const Entry = &.{
        \\
    ) catch @panic("OOM");

    const io = b.graph.io;
    const have_templates = blk: {
        var probe = b.build_root.handle.openDir(io, "templates/desktop-minimal", .{}) catch break :blk false;
        probe.close(io);
        break :blk true;
    };

    if (have_templates) {
        embedSingleFile(b, wf, &manifest, "LICENSE");
        embedTreeAs(b, wf, &manifest, "templates/desktop-minimal", "");
        embedTreeAs(b, wf, &manifest, "src/desktop", "src/desktop");
    }

    manifest.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    _ = wf.add("skeleton_desktop_minimal.zig", manifest.items);

    return b.createModule(.{
        .root_source_file = wf.getDirectory().path(b, "skeleton_desktop_minimal.zig"),
    });
}

/// Like `embedTree`, but rewrites the in-binary path so files end up
/// at `out_prefix/<rel>` regardless of where they live on disk. Used
/// by `buildCliSkeletonDesktop` to lift `templates/desktop/...` to the
/// project root and to vendor `src/desktop/` under the generated app.
fn embedTreeAs(
    b: *std.Build,
    wf: *std.Build.Step.WriteFile,
    manifest: *std.ArrayList(u8),
    disk_root: []const u8,
    out_prefix: []const u8,
) void {
    const io = b.graph.io;
    var root = b.build_root.handle.openDir(io, disk_root, .{ .iterate = true }) catch |err| {
        std.debug.print("verve: cannot embed {s}: {s}\n", .{ disk_root, @errorName(err) });
        @panic("desktop skeleton root missing");
    };
    defer root.close(io);

    var walker = root.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();

    while (walker.next(io) catch @panic("walk failed")) |entry| {
        if (entry.kind != .file) continue;

        // Forward-slashed relative path from the disk root.
        const rel_fwd = b.allocator.dupe(u8, entry.path) catch @panic("OOM");
        for (rel_fwd) |*c| if (c.* == '\\') {
            c.* = '/';
        };

        const out_path = if (out_prefix.len == 0)
            rel_fwd
        else
            std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ out_prefix, rel_fwd }) catch @panic("OOM");

        // The on-disk source path for @embedFile/addCopyFile is the
        // join of disk_root and the relative entry path.
        const disk_path = std.fs.path.join(b.allocator, &.{ disk_root, entry.path }) catch @panic("OOM");
        for (disk_path) |*c| if (c.* == '\\') {
            c.* = '/';
        };

        _ = wf.addCopyFile(b.path(disk_path), out_path);
        const line = std.fmt.allocPrint(b.allocator,
            \\    .{{ .path = "{s}", .bytes = @embedFile("{s}") }},
            \\
        , .{ out_path, out_path }) catch @panic("OOM");
        manifest.appendSlice(b.allocator, line) catch @panic("OOM");
    }
}

fn embedTree(
    b: *std.Build,
    wf: *std.Build.Step.WriteFile,
    manifest: *std.ArrayList(u8),
    rel_root: []const u8,
) void {
    const io = b.graph.io;
    var root = b.build_root.handle.openDir(io, rel_root, .{ .iterate = true }) catch |err| {
        std.debug.print("verve: cannot embed {s}: {s}\n", .{ rel_root, @errorName(err) });
        @panic("skeleton root missing");
    };
    defer root.close(io);

    var walker = root.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();

    while (walker.next(io) catch @panic("walk failed")) |entry| {
        if (entry.kind != .file) continue;

        const joined = std.fs.path.join(b.allocator, &.{ rel_root, entry.path }) catch @panic("OOM");
        for (joined) |*c| if (c.* == '\\') {
            c.* = '/';
        };

        _ = wf.addCopyFile(b.path(joined), joined);
        const line = std.fmt.allocPrint(b.allocator,
            \\    .{{ .path = "{s}", .bytes = @embedFile("{s}") }},
            \\
        , .{ joined, joined }) catch @panic("OOM");
        manifest.appendSlice(b.allocator, line) catch @panic("OOM");
    }
}

/// Parse `src/app/islands.zig` at configure time and extract every
/// island name declared via `pub const <Name> = struct` at the
/// top level. Build.zig needs the list before the codegen tool
/// runs so it can wire one WASM exe per name into the build graph.
/// Returns an empty slice when the file is missing — apps without
/// islands stay legal.
fn discoverIslandNames(b: *std.Build) [][]const u8 {
    const io = b.graph.io;
    const path = "src/app/islands.zig";
    var f = b.build_root.handle.openFile(io, path, .{}) catch return &.{};
    defer f.close(io);

    const stat = f.stat(io) catch return &.{};
    const bytes = b.allocator.alloc(u8, @intCast(stat.size)) catch @panic("OOM");
    defer b.allocator.free(bytes);
    _ = f.readPositionalAll(io, bytes, 0) catch return &.{};

    var names: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        // Top-level Zig decls start at column 0 by convention — that
        // sidesteps having to track brace depth around nested struct
        // bodies and line comments. Doc-comments (`///`) start with
        // a slash so they get filtered by the prefix check.
        const prefix = "pub const ";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const rest = line[prefix.len..];

        // Harvest identifier until whitespace, '=' or ':' — Zig
        // identifiers can't contain those.
        var end: usize = 0;
        while (end < rest.len) : (end += 1) {
            const ch = rest[end];
            if (ch == ' ' or ch == '\t' or ch == ':' or ch == '=' or ch == '\n' or ch == '\r') break;
        }
        if (end == 0) continue;
        const ident = rest[0..end];

        // Validate identifier shape — alphanumeric + underscore only.
        var ok = true;
        for (ident) |ch| {
            const alpha = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z');
            const digit = ch >= '0' and ch <= '9';
            if (!alpha and !digit and ch != '_') {
                ok = false;
                break;
            }
        }
        if (!ok) continue;

        // Confirm `struct` appears on the same line (after the `=`).
        if (std.mem.indexOf(u8, rest[end..], "struct") == null) continue;

        const owned = b.allocator.dupe(u8, ident) catch @panic("OOM");
        names.append(b.allocator, owned) catch @panic("OOM");
    }
    return names.toOwnedSlice(b.allocator) catch @panic("OOM");
}

fn guessContentType(path: []const u8) []const u8 {
    const ext_pos = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "application/octet-stream";
    const ext = path[ext_pos + 1 ..];
    const table = .{
        .{ "css", "text/css; charset=utf-8" },
        .{ "html", "text/html; charset=utf-8" },
        .{ "ico", "image/x-icon" },
        .{ "js", "application/javascript" },
        .{ "json", "application/json" },
        .{ "png", "image/png" },
        .{ "svg", "image/svg+xml" },
        .{ "txt", "text/plain; charset=utf-8" },
        .{ "wasm", "application/wasm" },
        .{ "webp", "image/webp" },
    };
    inline for (table) |row| {
        if (std.ascii.eqlIgnoreCase(ext, row[0])) return row[1];
    }
    return "application/octet-stream";
}
