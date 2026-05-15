const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const verve_mod = b.addModule("verve", .{
        .root_source_file = b.path("src/verve.zig"),
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
    _ = wf.addCopyFile(b.path("src/bridge/verve.js"), "verve.js");
    _ = wf.add("assets.zig",
        \\pub const wasm: []const u8 = @embedFile("client.wasm");
        \\pub const js: []const u8 = @embedFile("verve.js");
        \\
    );
    const assets_mod = b.createModule(.{
        .root_source_file = wf.getDirectory().path(b, "assets.zig"),
    });

    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/app/api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "verve", .module = verve_mod },
        },
    });

    const server_mod = b.createModule(.{
        .root_source_file = b.path("src/server/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "verve", .module = verve_mod },
            .{ .name = "assets", .module = assets_mod },
            .{ .name = "app", .module = app_mod },
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

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/verve.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);

    const server_test_mod = b.createModule(.{
        .root_source_file = b.path("src/server/api_handler.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "verve", .module = verve_mod },
            .{ .name = "app", .module = app_mod },
        },
    });
    const server_tests = b.addTest(.{ .root_module = server_test_mod });
    const run_server_tests = b.addRunArtifact(server_tests);

    const integration_opts = b.addOptions();
    integration_opts.addOptionPath("server_exe", server.getEmittedBin());

    const integration_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_mod.addOptions("build_options", integration_opts);

    const integration_tests = b.addTest(.{ .root_module = integration_mod });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    run_integration_tests.step.dependOn(&server.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_server_tests.step);
    test_step.dependOn(&run_integration_tests.step);
}
