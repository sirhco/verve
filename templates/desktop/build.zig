const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const public_dir_opt = b.option(
        []const u8,
        "public-dir",
        "Directory whose contents are baked into the binary and served at verve://app/<path>",
    ) orelse "frontend";

    const public_assets_mod = buildPublicAssets(b, public_dir_opt);

    const verve_dep = b.dependency("verve", .{
        .target = target,
        .optimize = optimize,
    });
    const verve_mod = verve_dep.module("verve");

    // The desktop platform layer is shipped inside this project tree
    // (vendored at scaffold time). It depends only on Zig stdlib and
    // the OS's native window/webview headers.
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

    // Platform-specific linkage. The desktop layer's macOS/Windows/
    // Linux backends call into native frameworks; we wire them up here
    // so the consuming project gets a single `zig build` story.
    //
    // Zig 0.16 moved link-time configuration to the module level —
    // `linkFramework` / `linkSystemLibrary` live on `*std.Build.Module`
    // and require an options struct. We apply links to both the
    // executable's root module and the desktop module that owns the
    // ObjC/C imports.
    desktop_mod.link_libc = true;
    exe_mod.link_libc = true;
    switch (target.result.os.tag) {
        .macos => {
            desktop_mod.linkFramework("Cocoa", .{});
            desktop_mod.linkFramework("WebKit", .{});
            desktop_mod.linkFramework("Foundation", .{});
            desktop_mod.linkSystemLibrary("objc", .{});
        },
        .windows => {
            desktop_mod.linkSystemLibrary("Ole32", .{});
            desktop_mod.linkSystemLibrary("OleAut32", .{});
            desktop_mod.linkSystemLibrary("User32", .{});
            desktop_mod.linkSystemLibrary("Shell32", .{});
            desktop_mod.linkSystemLibrary("Shlwapi", .{});
            // WebView2 loader. Ship the SDK under `third_party/webview2/`
            // or override with `-Dwebview2-sdk=...`.
            const sdk = b.option([]const u8, "webview2-sdk", "Path to the WebView2 SDK") orelse "third_party/webview2";
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

    // macOS .app bundle. `zig build bundle` lays out the Mach-O
    // executable + Info.plist into `zig-out/<name>.app/Contents/`. The
    // bundle is what Finder, Launchpad, and Gatekeeper expect — the
    // bare exe in `zig-out/bin/` cannot be code-signed or notarized.
    if (target.result.os.tag == .macos) {
        const bundle_id = b.option(
            []const u8,
            "bundle-id",
            "macOS bundle identifier (default: dev.verve.<name>)",
        ) orelse b.fmt("dev.verve.{s}", .{exe.name});
        const bundle_version = b.option(
            []const u8,
            "bundle-version",
            "Short version string written into Info.plist (default: 0.0.0)",
        ) orelse "0.0.0";
        const codesign_id = b.option(
            []const u8,
            "codesign",
            "Apple Developer signing identity. When set, the bundle is signed (use \"-\" for ad-hoc).",
        );

        const bundle_root = b.fmt("{s}.app", .{exe.name});
        const macos_dir = b.fmt("{s}/Contents/MacOS", .{bundle_root});
        const contents_dir = b.fmt("{s}/Contents", .{bundle_root});

        // Drop the binary in Contents/MacOS/<name>.
        const inst_bin = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = macos_dir } },
        });

        // Generate Info.plist with substituted name + bundle id +
        // version. Written through addWriteFiles so the source is
        // build-cache resident, not a stray file in the project root.
        const plist_src = b.fmt(
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            \\<plist version="1.0">
            \\<dict>
            \\    <key>CFBundleExecutable</key>
            \\    <string>{s}</string>
            \\    <key>CFBundleIdentifier</key>
            \\    <string>{s}</string>
            \\    <key>CFBundleName</key>
            \\    <string>{s}</string>
            \\    <key>CFBundleDisplayName</key>
            \\    <string>{s}</string>
            \\    <key>CFBundleVersion</key>
            \\    <string>{s}</string>
            \\    <key>CFBundleShortVersionString</key>
            \\    <string>{s}</string>
            \\    <key>CFBundlePackageType</key>
            \\    <string>APPL</string>
            \\    <key>CFBundleInfoDictionaryVersion</key>
            \\    <string>6.0</string>
            \\    <key>LSMinimumSystemVersion</key>
            \\    <string>10.15</string>
            \\    <key>NSHighResolutionCapable</key>
            \\    <true/>
            \\    <key>NSPrincipalClass</key>
            \\    <string>NSApplication</string>
            \\</dict>
            \\</plist>
            \\
        , .{ exe.name, bundle_id, exe.name, exe.name, bundle_version, bundle_version });
        const plist_wf = b.addWriteFiles();
        const plist_lazy = plist_wf.add("Info.plist", plist_src);
        const inst_plist = b.addInstallFileWithDir(plist_lazy, .{ .custom = contents_dir }, "Info.plist");

        const bundle_step = b.step("bundle", "Lay out the macOS .app bundle in zig-out/");
        bundle_step.dependOn(&inst_bin.step);
        bundle_step.dependOn(&inst_plist.step);

        if (codesign_id) |ident| {
            const bundle_path = b.fmt("zig-out/{s}", .{bundle_root});
            const sign = b.addSystemCommand(&.{
                "codesign", "--force", "--deep", "--sign", ident, bundle_path,
            });
            sign.step.dependOn(bundle_step);
            const sign_step = b.step("codesign", "Sign the macOS bundle (-Dcodesign=<identity>)");
            sign_step.dependOn(&sign.step);
        }
    }

    // Level-1 smoke harness. One step per platform — invoked via the
    // platform's shell so the embedded scripts do not need their
    // executable bit preserved through the scaffolder's WriteFile path.
    switch (target.result.os.tag) {
        .macos => {
            const smoke = b.addSystemCommand(&.{ "sh", "tools/smoke_macos.sh" });
            smoke.addArtifactArg(exe);
            smoke.step.dependOn(b.getInstallStep());
            const smoke_step = b.step("smoke", "Boot the app, screenshot it, validate capture (macOS)");
            smoke_step.dependOn(&smoke.step);
        },
        .linux => {
            const smoke = b.addSystemCommand(&.{ "bash", "tools/smoke_linux.sh" });
            smoke.addArtifactArg(exe);
            smoke.step.dependOn(b.getInstallStep());
            const smoke_step = b.step("smoke", "Boot the app under Xvfb, screenshot it, validate (Linux)");
            smoke_step.dependOn(&smoke.step);
        },
        .windows => {
            const smoke = b.addSystemCommand(&.{ "pwsh", "-File", "tools/smoke_windows.ps1", "-App" });
            smoke.addArtifactArg(exe);
            smoke.step.dependOn(b.getInstallStep());
            const smoke_step = b.step("smoke", "Boot the app, screenshot the primary display, validate (Windows)");
            smoke_step.dependOn(&smoke.step);
        },
        else => {},
    }
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
    var root = b.build_root.handle.openDir(io, dir, .{ .iterate = true }) catch {
        // No frontend directory yet — emit an empty manifest so the
        // build still succeeds.
        manifest.appendSlice(b.allocator, "};\n") catch @panic("OOM");
        _ = wf.add("public_assets.zig", manifest.items);
        return b.createModule(.{
            .root_source_file = wf.getDirectory().path(b, "public_assets.zig"),
        });
    };
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

        const ct = guessContentType(entry.path);
        const line = std.fmt.allocPrint(b.allocator,
            \\    .{{ .path = "{s}", .bytes = @embedFile("{s}"), .content_type = "{s}" }},
            \\
        , .{ path_fwd, path_fwd, ct }) catch @panic("OOM");
        manifest.appendSlice(b.allocator, line) catch @panic("OOM");
    }

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
        .{ "mjs", "application/javascript" },
        .{ "wasm", "application/wasm" },
        .{ "json", "application/json" },
        .{ "svg", "image/svg+xml" },
        .{ "png", "image/png" },
        .{ "jpg", "image/jpeg" },
        .{ "ico", "image/x-icon" },
        .{ "woff2", "font/woff2" },
    };
    inline for (table) |row| {
        if (std.ascii.eqlIgnoreCase(ext, row[0])) return row[1];
    }
    return "application/octet-stream";
}
