const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const verve_dep = b.dependency("verve", .{
        .target = target,
        .optimize = optimize,
    });
    const verve_mod = verve_dep.module("verve");

    // Walk `frontend/` and bake the files into `public_assets.entries`
    // at compile time. Served at verve://app/<path> by the asset router.
    const public_assets_mod = buildPublicAssets(b, "frontend");

    // The desktop platform layer is vendored at scaffold time.
    const desktop_mod = b.createModule(.{
        .root_source_file = b.path("src/desktop/window.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "verve", .module = verve_mod },
            .{ .name = "desktop", .module = desktop_mod },
            .{ .name = "public_assets", .module = public_assets_mod },
        },
    });
    const exe = b.addExecutable(.{
        .name = "app",
        .root_module = exe_mod,
    });

    desktop_mod.link_libc = true;
    exe_mod.link_libc = true;
    switch (target.result.os.tag) {
        .macos => {
            desktop_mod.linkFramework("Cocoa", .{});
            desktop_mod.linkFramework("WebKit", .{});
            desktop_mod.linkFramework("Foundation", .{});
            // IOKit: desktop.power battery / charging readout.
            desktop_mod.linkFramework("IOKit", .{});
            desktop_mod.linkFramework("CoreFoundation", .{});
            // SystemConfiguration: desktop.network reachability probe.
            desktop_mod.linkFramework("SystemConfiguration", .{});
            // CoreServices: desktop.fswatch FSEvents stream API.
            desktop_mod.linkFramework("CoreServices", .{});
            // Carbon: desktop.hotkeys RegisterEventHotKey.
            desktop_mod.linkFramework("Carbon", .{});
            desktop_mod.linkSystemLibrary("objc", .{});
        },
        .windows => {
            desktop_mod.linkSystemLibrary("Ole32", .{});
            desktop_mod.linkSystemLibrary("OleAut32", .{});
            desktop_mod.linkSystemLibrary("User32", .{});
            desktop_mod.linkSystemLibrary("Shell32", .{});
            desktop_mod.linkSystemLibrary("Shlwapi", .{});
            desktop_mod.linkSystemLibrary("Shcore", .{});
            // Auto-vendor the pinned WebView2 SDK on first build.
            const sdk = b.option([]const u8, "webview2-sdk", "Path to the WebView2 SDK") orelse "third_party/webview2";
            const skip_fetch = b.option(bool, "webview2-no-fetch", "Skip auto-vendor of WebView2 SDK") orelse false;
            if (!skip_fetch) {
                const fetch_cmd = if (builtin.os.tag == .windows) blk: {
                    const c = b.addSystemCommand(&.{ "pwsh", "-File", "tools/fetch_webview2.ps1", "-Dest" });
                    c.addArg(sdk);
                    break :blk c;
                } else blk: {
                    const c = b.addSystemCommand(&.{ "sh", "tools/fetch_webview2.sh" });
                    c.addArg(b.fmt("--dest={s}", .{sdk}));
                    break :blk c;
                };
                exe.step.dependOn(&fetch_cmd.step);
            }
            desktop_mod.addLibraryPath(b.path(sdk));
            desktop_mod.linkSystemLibrary("WebView2Loader.dll", .{});
        },
        .linux => {
            desktop_mod.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
            desktop_mod.linkSystemLibrary("webkit2gtk-4.1", .{ .use_pkg_config = .force });
        },
        else => @panic("unsupported OS — desktop builds target macOS, Windows, or Linux"),
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the desktop app");
    run_step.dependOn(&run_cmd.step);
}

fn buildPublicAssets(b: *std.Build, dir: []const u8) *std.Build.Module {
    const wf = b.addWriteFiles();
    var manifest: std.ArrayList(u8) = .empty;
    manifest.appendSlice(b.allocator,
        \\const std = @import("std");
        \\
        \\pub const Entry = struct {
        \\    path: []const u8,
        \\    bytes: []const u8,
        \\    content_type: []const u8,
        \\};
        \\
        \\pub const entries: []const Entry = &.{
        \\
    ) catch @panic("OOM");

    const io = b.graph.io;
    if (b.build_root.handle.openDir(io, dir, .{ .iterate = true })) |root_dir| {
        var root = root_dir;
        defer root.close(io);

        var walker = root.walk(b.allocator) catch @panic("OOM");
        defer walker.deinit();

        while (walker.next(io) catch @panic("walk failed")) |entry| {
            if (entry.kind != .file) continue;
            const path_fwd = b.allocator.dupe(u8, entry.path) catch @panic("OOM");
            for (path_fwd) |*ch| if (ch.* == '\\') {
                ch.* = '/';
            };
            const lazy = b.path(b.pathJoin(&.{ dir, entry.path }));
            _ = wf.addCopyFile(lazy, path_fwd);
            const line = std.fmt.allocPrint(b.allocator,
                \\    .{{ .path = "{s}", .bytes = @embedFile("{s}"), .content_type = "{s}" }},
                \\
            , .{ path_fwd, path_fwd, guessContentType(entry.path) }) catch @panic("OOM");
            manifest.appendSlice(b.allocator, line) catch @panic("OOM");
        }
    } else |_| {}

    manifest.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    _ = wf.add("public_assets.zig", manifest.items);

    return b.createModule(.{
        .root_source_file = wf.getDirectory().path(b, "public_assets.zig"),
    });
}

fn guessContentType(path: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "application/octet-stream";
    const ext = path[dot + 1 ..];
    const table = .{
        .{ "html", "text/html; charset=utf-8" },
        .{ "css", "text/css; charset=utf-8" },
        .{ "js", "application/javascript" },
        .{ "wasm", "application/wasm" },
        .{ "json", "application/json" },
        .{ "svg", "image/svg+xml" },
        .{ "png", "image/png" },
        .{ "ico", "image/x-icon" },
    };
    inline for (table) |row| {
        if (std.ascii.eqlIgnoreCase(ext, row[0])) return row[1];
    }
    return "application/octet-stream";
}
