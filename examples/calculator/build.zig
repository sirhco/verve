//! Build wiring for the `calculator` example. Emits stub
//! `app_client.zig` and `client_manifest.zig` modules so the
//! shared `src/client/main.zig` + `src/server/main.zig` compile
//! cleanly. Examples that grow into using server-fn codegen or
//! islands can swap these stubs for the framework's
//! `tools/server_fn_codegen.zig` + `tools/island_manifest_gen.zig`
//! by mirroring the wiring in the framework's own build.zig.

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

    const client_mod = b.createModule(.{
        .root_source_file = b.path("src/client/main.zig"),
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

    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(wasm.getEmittedBin(), "client.wasm");
    _ = wf.addCopyFile(b.path("../../src/bridge/verve.js"), "verve.js");
    _ = wf.add("assets.zig",
        \\pub const wasm: []const u8 = @embedFile("client.wasm");
        \\pub const js: []const u8 = @embedFile("verve.js");
        \\
        \\pub const IslandChunk = struct { name: []const u8, bytes: []const u8 };
        \\pub const island_chunks: []const IslandChunk = &.{};
        \\pub fn lookupIslandChunk(_: []const u8) ?IslandChunk { return null; }
        \\
    );
    const assets_mod = b.createModule(.{
        .root_source_file = wf.getDirectory().path(b, "assets.zig"),
    });

    const stubs_wf = b.addWriteFiles();
    _ = stubs_wf.add("client_manifest.zig",
        \\pub const Entry = struct { name: []const u8, props_schema: []const u8, chunk_url: []const u8 };
        \\pub const entries: []const Entry = &.{};
        \\pub fn lookup(_: []const u8) ?Entry { return null; }
        \\
    );
    const client_manifest_mod = b.createModule(.{
        .root_source_file = stubs_wf.getDirectory().path(b, "client_manifest.zig"),
    });
    client_mod.addImport("client_manifest", client_manifest_mod);

    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/app/api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "verve", .module = verve_mod },
        },
    });

    _ = stubs_wf.add("app_client.zig",
        \\// Stub app_client — examples that need typed stubs should
        \\// wire `tools/server_fn_codegen.zig` like the framework's
        \\// own build.zig does.
        \\
    );
    const app_client_mod = b.createModule(.{
        .root_source_file = stubs_wf.getDirectory().path(b, "app_client.zig"),
        .imports = &.{
            .{ .name = "verve", .module = verve_mod },
            .{ .name = "app", .module = app_mod },
        },
    });
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

    const server_mod = b.createModule(.{
        .root_source_file = b.path("../../src/server/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "verve", .module = verve_mod },
            .{ .name = "assets", .module = assets_mod },
            .{ .name = "gl_assets", .module = gl_assets_stub_mod },
            .{ .name = "app", .module = app_mod },
            .{ .name = "app_client", .module = app_client_mod },
            .{ .name = "client_manifest", .module = client_manifest_mod },
            .{ .name = "public_assets", .module = public_assets_mod },
        },
    });
    const server = b.addExecutable(.{
        .name = "calculator-server",
        .root_module = server_mod,
    });
    b.installArtifact(server);

    const run_cmd = b.addRunArtifact(server);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the calculator server");
    run_step.dependOn(&run_cmd.step);
}
