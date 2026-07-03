//! Build wiring for the `showcase` example. Mirrors the framework's
//! own `build.zig` to exercise every codegen path: typed server-fn
//! stubs (`app_client.zig`), the island manifest, and per-island
//! WASM chunks discovered from `src/app/islands.zig`.

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

    // Chunk-side `verve` façade (the island runtime) + the core modules it
    // imports. Framework island chunks (resolved from ../../src/client/islands)
    // `@import("verve")` against this — mirrors examples/viz-live.
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
    const verve_island_mod = b.addModule("verve_island", .{
        .root_source_file = b.path("../../src/client/island_runtime.zig"),
        .imports = &.{
            .{ .name = "serialize", .module = serialize_island_mod },
            .{ .name = "island_state", .module = island_state_island_mod },
            .{ .name = "viz_core", .module = viz_core_mod },
            .{ .name = "anim_core", .module = anim_core_mod },
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

    // ---- Phase 11: typed server-fn codegen ------------------------------
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

    // ---- Phase 13B: island manifest codegen -----------------------------
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

    const island_names = discoverIslandNames(b);

    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(wasm.getEmittedBin(), "client.wasm");
    _ = wf.addCopyFile(b.path("../../src/bridge/verve.js"), "verve.js");
    _ = wf.addCopyFile(b.path("../../src/bridge/verve-worker.js"), "verve-worker.js");

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
        // Chunk source resolution: example-local override → the framework's
        // own implementation → the `_default` stub.
        const local_rel = b.fmt("src/client/islands/{s}.zig", .{name});
        const framework_rel = b.fmt("../../src/client/islands/{s}.zig", .{name});
        const fallback_rel = "../../src/client/islands/_default.zig";
        const io_h = b.graph.io;
        const probe = struct {
            fn exists(bld: *std.Build, io: anytype, p: []const u8) bool {
                var f = bld.build_root.handle.openFile(io, p, .{}) catch return false;
                f.close(io);
                return true;
            }
        }.exists;
        const rel = if (probe(b, io_h, local_rel))
            local_rel
        else if (probe(b, io_h, framework_rel))
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
        // Private per-chunk table supplied by the bridge (JS needs the handle
        // to translate `&handler` indices into main-table slots).
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

    // Dedicated WriteFiles for app_client.zig — keeping it out of the
    // assets `wf` (which holds client.wasm) avoids a client_mod ->
    // app_client -> wf -> client_mod dependency loop. Mirrors the
    // framework's own build.zig (`wf_app_client`).
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

    const gl_assets_stub_mod = b.createModule(.{
        .root_source_file = b.path("../../src/server/gl_assets_stub.zig"),
    });
    const viz_assets_stub_mod = b.createModule(.{
        .root_source_file = b.path("../../src/server/viz_assets_stub.zig"),
    });

    const server_mod = b.createModule(.{
        .root_source_file = b.path("../../src/server/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "verve", .module = verve_mod },
            .{ .name = "assets", .module = assets_mod },
            .{ .name = "gl_assets", .module = gl_assets_stub_mod },
            .{ .name = "viz_assets", .module = viz_assets_stub_mod },
            .{ .name = "app", .module = app_mod },
            .{ .name = "app_client", .module = app_client_mod },
            .{ .name = "client_manifest", .module = client_manifest_mod },
            .{ .name = "public_assets", .module = public_assets_mod },
        },
    });
    const server = b.addExecutable(.{
        .name = "showcase-server",
        .root_module = server_mod,
    });
    b.installArtifact(server);

    const run_cmd = b.addRunArtifact(server);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the showcase server");
    run_step.dependOn(&run_cmd.step);
}

/// Parse `src/app/islands.zig` at configure time to harvest every
/// top-level `pub const <Name> = struct` decl. Mirrors the framework
/// helper of the same name.
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
