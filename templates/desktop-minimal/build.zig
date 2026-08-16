const std = @import("std");

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

    // The desktop platform layer is vendored at scaffold time. `verve` is
    // wired in by name (not reachable by relative import — it's outside
    // this module's root subtree) for `ai_cli.zig`'s `verve.ai.Provider`/
    // `Message` vocabulary.
    const desktop_mod = b.createModule(.{
        .root_source_file = b.path("src/desktop/window.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "verve", .module = verve_mod },
        },
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
            // Windowscodecs (WIC) backs the CF_DIBV5 image clipboard
            // (PNG <-> DIB transcode).
            desktop_mod.linkSystemLibrary("Windowscodecs", .{});
            // Uiautomationcore backs the server-side UIA accessibility
            // provider (role description / subrole / help text).
            desktop_mod.linkSystemLibrary("Uiautomationcore", .{});
            // Comdlg32: GetOpen/SaveFileNameW (native file dialogs).
            desktop_mod.linkSystemLibrary("Comdlg32", .{});
            // Gdi32: GetDeviceCaps (DPI scale factor in the native host).
            desktop_mod.linkSystemLibrary("Gdi32", .{});
            // WinRT activation entry points (Ro*/Windows*String) for the
            // Action Center toast. combase.dll has no x86_64 import lib in
            // zig's mingw, so link the split API-set stubs that carry them.
            desktop_mod.linkSystemLibrary("api-ms-win-core-winrt-l1-1-0", .{});
            desktop_mod.linkSystemLibrary("api-ms-win-core-winrt-string-l1-1-0", .{});

            // Native C++ WebView2 host. The Windows desktop backend
            // (src/desktop/windows_native.zig) is a thin Zig shim over this
            // flat-C-ABI host; the host loads WebView2Loader.dll dynamically at
            // runtime, so only the vendored headers + the DLL (shipped next to
            // the exe below) are needed — no import lib / SDK fetch.
            desktop_mod.addIncludePath(b.path("src/desktop/win_native/include"));
            desktop_mod.addCSourceFile(.{
                .file = b.path("src/desktop/win_native/webview2_host.cpp"),
                .flags = &.{
                    "-std=c++17", "-fms-extensions", "-fno-exceptions", "-fno-rtti",
                    "-DUNICODE",  "-D_UNICODE",
                },
            });

            // Ship the vendored loader next to app.exe; the host
            // LoadLibraryW()s it at startup (else STATUS_DLL_NOT_FOUND).
            const install_loader = b.addInstallBinFile(
                b.path("src/desktop/win_native/include/WebView2Loader.dll"),
                "WebView2Loader.dll",
            );
            b.getInstallStep().dependOn(&install_loader.step);
        },
        .linux => {
            const use_gtk4 = b.option(bool, "gtk4", "Use GTK4 + WebKitGTK 6.0 instead of GTK3 + WebKitGTK 4.1") orelse false;
            if (use_gtk4) {
                desktop_mod.linkSystemLibrary("gtk4", .{ .use_pkg_config = .force });
                desktop_mod.linkSystemLibrary("webkitgtk-6.0", .{ .use_pkg_config = .force });
            } else {
                desktop_mod.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
                desktop_mod.linkSystemLibrary("webkit2gtk-4.1", .{ .use_pkg_config = .force });
            }
            const gtk4_opts = b.addOptions();
            gtk4_opts.addOption(bool, "gtk4", use_gtk4);
            desktop_mod.addOptions("desktop_options", gtk4_opts);
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
