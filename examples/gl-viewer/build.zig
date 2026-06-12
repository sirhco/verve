//! Build wiring for the `gl-viewer` example. Mirrors the framework's own
//! `build.zig` (and the viz-live / anim-landing examples) with the verve.gl
//! additions:
//!
//!   1. The chunk runtime gets the `gl_core` module — `island_runtime.zig`
//!      imports it, and the reused framework `GlScene` chunk builds scenes +
//!      encodes command streams through it.
//!   2. The GL asset pipeline (gen_demo_glb → gl_asset_gen → demo.vmesh and
//!      gen_demo_hdr → gl_asset_gen → studio.venv) runs at build time and
//!      embeds the results into a `gl_assets` module the server imports to
//!      serve `/gl/*`.
//!
//! No island chunk source of its own: the chunk resolver falls back to the
//! framework's `../../src/client/islands/GlScene.zig`, used here verbatim.
//! No gl tool is copied either — both `gl_core` and the three tools are
//! consumed from the framework tree by relative path.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const verve_mod = b.addModule("verve", .{
        .root_source_file = b.path("../../src/verve.zig"),
    });

    // Chunk runtime + the core modules it imports: the typed-props codec,
    // island state, the client-side viz/anim math, and the pure gl engine
    // (math/scene/command/mesh) the GlScene chunk drives.
    const serialize_island_mod = b.createModule(.{
        .root_source_file = b.path("../../src/core/serialize.zig"),
    });
    const island_state_island_mod = b.createModule(.{
        .root_source_file = b.path("../../src/core/island_state.zig"),
    });
    const viz_core_mod = b.createModule(.{
        .root_source_file = b.path("../../src/core/viz/client_core.zig"),
    });
    const anim_core_mod = b.createModule(.{
        .root_source_file = b.path("../../src/core/anim/client_core.zig"),
    });
    const gl_core_mod = b.createModule(.{
        .root_source_file = b.path("../../src/core/gl/gl.zig"),
    });
    const verve_island_mod = b.addModule("verve_island", .{
        .root_source_file = b.path("../../src/client/island_runtime.zig"),
        .imports = &.{
            .{ .name = "serialize", .module = serialize_island_mod },
            .{ .name = "island_state", .module = island_state_island_mod },
            .{ .name = "viz_core", .module = viz_core_mod },
            .{ .name = "anim_core", .module = anim_core_mod },
            .{ .name = "gl_core", .module = gl_core_mod },
        },
    });

    const client_mod = b.createModule(.{
        .root_source_file = b.path("../../src/client/main.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "verve", .module = verve_mod },
        },
    });
    const wasm = b.addExecutable(.{
        .name = "client",
        .root_module = client_mod,
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    // Table isolation (matches the live bridge in ../../src/bridge/verve.js):
    // the main client IMPORTS a JS-created growable table; chunks get private
    // tables and the bridge translates `&handler` indices at the boundary.
    wasm.import_table = true;

    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/app/api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "verve", .module = verve_mod },
        },
    });

    // ---- typed server-fn codegen -----------------------------------------
    const codegen_mod = b.createModule(.{
        .root_source_file = b.path("../../tools/server_fn_codegen.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "app", .module = app_mod },
        },
    });
    const codegen_exe = b.addExecutable(.{
        .name = "verve-codegen-server-fn",
        .root_module = codegen_mod,
    });
    const codegen_run = b.addRunArtifact(codegen_exe);
    const generated_app_client = codegen_run.captureStdOut(.{ .basename = "app_client.zig" });

    // ---- island manifest codegen ------------------------------------------
    const manifest_mod = b.createModule(.{
        .root_source_file = b.path("../../tools/island_manifest_gen.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "app", .module = app_mod },
        },
    });
    const manifest_exe = b.addExecutable(.{
        .name = "verve-codegen-islands",
        .root_module = manifest_mod,
    });
    const manifest_run = b.addRunArtifact(manifest_exe);
    const generated_manifest = manifest_run.captureStdOut(.{ .basename = "client_manifest.zig" });

    // ---- GL asset pipeline ------------------------------------------------
    // Mirrors the framework build's gl asset chain. Both tools target the
    // host so they run during the build; `verve_gl` wraps src/core/gl/gl.zig
    // with a host target so the tools can call the full native-side pipeline
    // (fixture, gltf, vmesh, png, IBL prefilter).
    const host_target = b.graph.host;
    const host_gl_mod = b.createModule(.{
        .root_source_file = b.path("../../src/core/gl/gl.zig"),
        .target = host_target,
        .optimize = optimize,
    });

    // gen_demo_glb → demo.glb → gl_asset_gen → demo.vmesh
    const gen_demo_glb_mod = b.createModule(.{
        .root_source_file = b.path("../../tools/gen_demo_glb.zig"),
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

    const gl_asset_gen_mod = b.createModule(.{
        .root_source_file = b.path("../../tools/gl_asset_gen.zig"),
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
    const gl_asset_gen_run = b.addRunArtifact(gl_asset_gen_exe);
    gl_asset_gen_run.addFileArg(demo_glb_path);
    const demo_vmesh_path = gl_asset_gen_run.addOutputFileArg("demo.vmesh");

    // gen_demo_hdr → studio.hdr → gl_asset_gen (branches on .hdr) → studio.venv
    const gen_demo_hdr_mod = b.createModule(.{
        .root_source_file = b.path("../../tools/gen_demo_hdr.zig"),
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
    const studio_venv_path = gl_asset_gen_hdr_run.addOutputFileArg("studio.venv");

    // Embed the generated assets into a gl_assets.zig the server imports.
    const wf_gl = b.addWriteFiles();
    _ = wf_gl.addCopyFile(demo_vmesh_path, "demo.vmesh");
    _ = wf_gl.addCopyFile(studio_venv_path, "studio.venv");
    const gl_assets_src =
        \\// Generated by build.zig — do not edit.
        \\pub const GlAsset = struct { name: []const u8, bytes: []const u8 };
        \\
        \\pub const gl_assets: []const GlAsset = &.{
        \\    .{ .name = "demo.vmesh", .bytes = @embedFile("demo.vmesh") },
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

    // ---- island chunks + embedded asset table ----------------------------
    const island_names = discoverIslandNames(b);

    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(wasm.getEmittedBin(), "client.wasm");
    _ = wf.addCopyFile(b.path("../../src/bridge/verve.js"), "verve.js");

    var assets_buf: std.ArrayList(u8) = .empty;
    assets_buf.appendSlice(b.allocator,
        \\pub const wasm: []const u8 = @embedFile("client.wasm");
        \\pub const js: []const u8 = @embedFile("verve.js");
        \\
        \\pub const IslandChunk = struct { name: []const u8, bytes: []const u8 };
        \\
        \\pub const island_chunks: []const IslandChunk = &.{
        \\
    ) catch @panic("OOM");

    for (island_names) |name| {
        // Chunk source resolution: example-local override → the framework's
        // own implementation → the `_default` stub. GlScene resolves to the
        // framework chunk (`../../src/client/islands/GlScene.zig`).
        const local_rel = b.fmt("src/client/islands/{s}.zig", .{name});
        const framework_rel = b.fmt("../../src/client/islands/{s}.zig", .{name});
        const fallback_rel = "../../src/client/islands/_default.zig";
        const rel = if (fileExists(b, local_rel))
            local_rel
        else if (fileExists(b, framework_rel))
            framework_rel
        else
            fallback_rel;

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
        exe.import_memory = true;
        // Private per-chunk table supplied by the bridge (table isolation).
        exe.import_table = true;
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

    // Dedicated WriteFiles for app_client.zig — keeping it out of the assets
    // `wf` (which holds client.wasm) avoids a dependency loop. Mirrors the
    // framework's own build.zig.
    const wf_app_client = b.addWriteFiles();
    _ = wf_app_client.addCopyFile(generated_app_client, "app_client.zig");
    const app_client_mod = b.createModule(.{
        .root_source_file = wf_app_client.getDirectory().path(b, "app_client.zig"),
        .imports = &.{
            .{ .name = "verve", .module = verve_mod },
            .{ .name = "app", .module = app_mod },
        },
    });

    const wf_manifest = b.addWriteFiles();
    _ = wf_manifest.addCopyFile(generated_manifest, "client_manifest.zig");
    const client_manifest_mod = b.createModule(.{
        .root_source_file = wf_manifest.getDirectory().path(b, "client_manifest.zig"),
    });
    client_mod.addImport("client_manifest", client_manifest_mod);
    client_mod.addImport("app_client", app_client_mod);

    const public_wf = b.addWriteFiles();
    _ = public_wf.add("public_assets.zig",
        \\pub const Entry = struct { path: []const u8, bytes: []const u8, content_type: []const u8 };
        \\pub const entries: []const Entry = &.{};
        \\
    );
    const public_assets_mod = b.createModule(.{
        .root_source_file = public_wf.getDirectory().path(b, "public_assets.zig"),
    });

    const server_mod = b.createModule(.{
        .root_source_file = b.path("../../src/server/main.zig"),
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
        },
    });
    const server = b.addExecutable(.{
        .name = "gl-viewer-server",
        .root_module = server_mod,
    });
    b.installArtifact(server);

    const run_cmd = b.addRunArtifact(server);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the gl-viewer server");
    run_step.dependOn(&run_cmd.step);
}

fn fileExists(b: *std.Build, rel: []const u8) bool {
    const io = b.graph.io;
    var probe = b.build_root.handle.openFile(io, rel, .{}) catch return false;
    probe.close(io);
    return true;
}

/// Parse `src/app/islands.zig` at configure time to harvest every top-level
/// `pub const <Name> = struct` decl. Mirrors the framework helper.
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
        const prefix = "pub const ";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const rest = line[prefix.len..];

        var end: usize = 0;
        while (end < rest.len) : (end += 1) {
            const ch = rest[end];
            if (ch == ' ' or ch == '\t' or ch == ':' or ch == '=' or ch == '\n' or ch == '\r') break;
        }
        if (end == 0) continue;
        const ident = rest[0..end];

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
        if (std.mem.indexOf(u8, rest[end..], "struct") == null) continue;

        const owned = b.allocator.dupe(u8, ident) catch @panic("OOM");
        names.append(b.allocator, owned) catch @panic("OOM");
    }
    return names.toOwnedSlice(b.allocator) catch @panic("OOM");
}
