const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const public_dir_opt = b.option(
        []const u8,
        "public-dir",
        "Directory whose contents are baked into the binary and served at /public/*",
    );

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

    const public_assets_mod = buildPublicAssets(b, public_dir_opt);

    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/app/api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "verve", .module = verve_mod },
        },
    });

    // Phase 11: typed client stubs for `app.Actions`. A small native
    // codegen binary imports `app` and prints a per-action wrapper to
    // stdout; the run step's captured output is grafted into the build
    // WriteFiles as `app_client.zig`, then wrapped as `app_client_mod`.
    const codegen_mod = b.createModule(.{
        .root_source_file = b.path("tools/server_fn_codegen.zig"),
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
    _ = wf.addCopyFile(generated_app_client, "app_client.zig");

    const app_client_mod = b.createModule(.{
        .root_source_file = wf.getDirectory().path(b, "app_client.zig"),
        .imports = &.{
            .{ .name = "verve", .module = verve_mod },
            .{ .name = "app", .module = app_mod },
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
            .{ .name = "app_client", .module = app_client_mod },
            .{ .name = "public_assets", .module = public_assets_mod },
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

    // Dedicated server executable for the embed integration test, with
    // tests/public_fixture baked in regardless of the user's -Dpublic-dir
    // flag. Lets CI verify the embed path without polluting the main
    // production binary.
    const embed_assets_mod = buildPublicAssets(b, "tests/public_fixture");
    const embed_server_mod = b.createModule(.{
        .root_source_file = b.path("src/server/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "verve", .module = verve_mod },
            .{ .name = "assets", .module = assets_mod },
            .{ .name = "app", .module = app_mod },
            .{ .name = "app_client", .module = app_client_mod },
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
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "skeleton", .module = skeleton_mod },
        },
    });
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

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_server_tests.step);
    test_step.dependOn(&run_client_tests.step);
    test_step.dependOn(&run_integration_tests.step);
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
