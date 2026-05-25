const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const public_dir_opt = b.option(
        []const u8,
        "public-dir",
        "Directory whose contents are baked into the binary and served at verve://app/<path>",
    ) orelse "frontend";

    const verve_dep = b.dependency("verve", .{
        .target = target,
        .optimize = optimize,
    });
    const verve_mod = verve_dep.module("verve");

    // Build-time SSR. A tiny host-target program imports `verve` +
    // `components` and prints the rendered HTML to stdout; the captured
    // output is grafted into `public_assets` as `index.html`, replacing
    // any on-disk copy in the frontend directory.
    const host_target = b.graph.host;
    const verve_host_dep = b.dependency("verve", .{
        .target = host_target,
        .optimize = optimize,
    });
    const verve_host_mod = verve_host_dep.module("verve");

    const components_host_mod = b.createModule(.{
        .root_source_file = b.path("src/components.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "verve", .module = verve_host_mod } },
    });

    const render_index_mod = b.createModule(.{
        .root_source_file = b.path("tools/render_index.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "verve", .module = verve_host_mod },
            .{ .name = "components", .module = components_host_mod },
        },
    });
    const render_index_exe = b.addExecutable(.{
        .name = "render_index",
        .root_module = render_index_mod,
    });
    const render_index_run = b.addRunArtifact(render_index_exe);
    const generated_index = render_index_run.captureStdOut(.{
        .basename = "index.html",
    });

    // WASM client. Compiled to wasm32-freestanding ReleaseSmall and
    // served at verve://app/client.wasm. The verve_desktop.js bridge
    // instantiates it and seeds `verve_init_*` exports from the
    // server-rendered DOM.
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const client_mod = b.createModule(.{
        .root_source_file = b.path("src/client/main.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    const client_wasm = b.addExecutable(.{
        .name = "client",
        .root_module = client_mod,
    });
    client_wasm.entry = .disabled;
    client_wasm.rdynamic = true;

    const public_assets_mod = buildPublicAssets(b, public_dir_opt, &.{
        .{ .name = "index.html", .lazy = generated_index, .content_type = "text/html; charset=utf-8" },
        .{ .name = "client.wasm", .lazy = client_wasm.getEmittedBin(), .content_type = "application/wasm" },
    });

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
            // or override with `-Dwebview2-sdk=...`. When the SDK is
            // not present, `tools/fetch_webview2.{sh,ps1}` downloads
            // the pinned NuGet release. The script is idempotent so
            // running it from every Windows build is cheap (an
            // existing .lib short-circuits before any network I/O).
            const sdk = b.option([]const u8, "webview2-sdk", "Path to the WebView2 SDK") orelse "third_party/webview2";
            const skip_fetch = b.option(bool, "webview2-no-fetch", "Skip auto-vendor of WebView2 SDK from NuGet") orelse false;
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

    // `zig build dev`: a host-target watcher that re-runs `zig build`
    // and respawns the app whenever a watched source file changes.
    // Assets are baked into the binary at build time (SSR'd index.html,
    // wasm client, embedded CSS / bridge JS) so this is process-restart
    // grain, not HMR.
    const dev_mod = b.createModule(.{
        .root_source_file = b.path("tools/dev.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    const dev_exe = b.addExecutable(.{
        .name = "verve-dev-watcher",
        .root_module = dev_mod,
    });
    const dev_run = b.addRunArtifact(dev_exe);
    const dev_step = b.step("dev", "Watch sources, auto-rebuild + respawn the app");
    dev_step.dependOn(&dev_run.step);

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
        // Path to a `.icns` file. Copied into Contents/Resources/ and
        // referenced from Info.plist via CFBundleIconFile. Generate one
        // from a square PNG with: `mkdir AppIcon.iconset && sips -z N N
        // src.png --out AppIcon.iconset/icon_NxN.png` per size, then
        // `iconutil -c icns AppIcon.iconset`. The bundle still works
        // without an icon; Finder falls back to the generic app glyph.
        const icon_path = b.option(
            []const u8,
            "icon",
            "Path to .icns file for the macOS bundle (default: none — generic app icon).",
        );

        // Optional custom URL scheme registration. When set, the
        // generated Info.plist gains a `CFBundleURLTypes` array so
        // macOS knows this .app handles `<scheme>://...` URLs. Click
        // a verve://... link in a browser and the OS launches (or
        // foregrounds) this bundle, routing the URL through the
        // AppleEventManager handler the framework installs at
        // `setUrlOpenHandler` time.
        const url_scheme = b.option(
            []const u8,
            "url-scheme",
            "Register a custom URL scheme on macOS (e.g. -Durl-scheme=verve). Default: none.",
        );

        const bundle_root = b.fmt("{s}.app", .{exe.name});
        const macos_dir = b.fmt("{s}/Contents/MacOS", .{bundle_root});
        const contents_dir = b.fmt("{s}/Contents", .{bundle_root});
        const resources_dir = b.fmt("{s}/Contents/Resources", .{bundle_root});

        // Drop the binary in Contents/MacOS/<name>.
        const inst_bin = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = macos_dir } },
        });

        // CFBundleIconFile names the icon WITHOUT its extension —
        // macOS appends `.icns`. So with icon=path/to/AppIcon.icns
        // the bundle ends up with Resources/AppIcon.icns and a
        // CFBundleIconFile entry of "AppIcon".
        const icon_plist_entry: []const u8 = if (icon_path != null)
            "    <key>CFBundleIconFile</key>\n    <string>AppIcon</string>\n"
        else
            "";

        // CFBundleURLTypes is an array of dicts; one dict per scheme
        // group. CFBundleURLName conventionally matches CFBundleIdentifier.
        const url_plist_entry: []const u8 = if (url_scheme) |s|
            b.fmt(
                \\    <key>CFBundleURLTypes</key>
                \\    <array>
                \\        <dict>
                \\            <key>CFBundleURLName</key>
                \\            <string>{s}.url</string>
                \\            <key>CFBundleURLSchemes</key>
                \\            <array>
                \\                <string>{s}</string>
                \\            </array>
                \\        </dict>
                \\    </array>
                \\
            , .{ exe.name, s })
        else
            "";

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
            \\{s}{s}</dict>
            \\</plist>
            \\
        , .{ exe.name, bundle_id, exe.name, exe.name, bundle_version, bundle_version, icon_plist_entry, url_plist_entry });
        const plist_wf = b.addWriteFiles();
        const plist_lazy = plist_wf.add("Info.plist", plist_src);
        const inst_plist = b.addInstallFileWithDir(plist_lazy, .{ .custom = contents_dir }, "Info.plist");

        const bundle_step = b.step("bundle", "Lay out the macOS .app bundle in zig-out/");
        bundle_step.dependOn(&inst_bin.step);
        bundle_step.dependOn(&inst_plist.step);

        if (icon_path) |ip| {
            // Accept both build-root-relative paths (`assets/icon.icns`)
            // and absolute paths (`/Users/.../icon.icns`); `b.path()`
            // rejects the latter. `LazyPath.cwd_relative` is the
            // documented escape hatch and copes with both.
            const icon_lazy: std.Build.LazyPath = if (std.fs.path.isAbsolute(ip))
                .{ .cwd_relative = ip }
            else
                b.path(ip);
            const inst_icon = b.addInstallFileWithDir(
                icon_lazy,
                .{ .custom = resources_dir },
                "AppIcon.icns",
            );
            bundle_step.dependOn(&inst_icon.step);
        }

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
            const smoke_step = b.step(
                "smoke",
                "Level-3 smoke (macOS): run app under --smoke, diff checksum vs tests/golden",
            );
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

pub const Overlay = struct {
    /// Forward-slashed path inside the public-assets tree (e.g.
    /// "index.html", "client.wasm"). Replaces any on-disk file with the
    /// same name; otherwise appended as a fresh entry after the walk.
    name: []const u8,
    lazy: std.Build.LazyPath,
    /// Optional explicit content type. When empty, derived from the
    /// name's extension via `guessContentType`.
    content_type: []const u8 = "",
};

fn buildPublicAssets(b: *std.Build, dir: []const u8, overlays: []const Overlay) *std.Build.Module {
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

    // Track which overlays were consumed during the walk so we can
    // append fresh entries for any that didn't shadow an on-disk file.
    const consumed = b.allocator.alloc(bool, overlays.len) catch @panic("OOM");
    @memset(consumed, false);

    const emitEntry = struct {
        fn call(
            b_: *std.Build,
            wf_: *std.Build.Step.WriteFile,
            mf: *std.ArrayList(u8),
            entry_name: []const u8,
            lazy: std.Build.LazyPath,
            ct: []const u8,
        ) void {
            _ = wf_.addCopyFile(lazy, entry_name);
            const line = std.fmt.allocPrint(b_.allocator,
                \\    .{{ .path = "{s}", .bytes = @embedFile("{s}"), .content_type = "{s}" }},
                \\
            , .{ entry_name, entry_name, ct }) catch @panic("OOM");
            mf.appendSlice(b_.allocator, line) catch @panic("OOM");
        }
    }.call;

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

            // Overlay takes precedence over the on-disk file.
            const overlay_idx = findOverlay(overlays, path_fwd);
            if (overlay_idx) |i| {
                consumed[i] = true;
                const ct = if (overlays[i].content_type.len > 0)
                    overlays[i].content_type
                else
                    guessContentType(overlays[i].name);
                emitEntry(b, wf, &manifest, path_fwd, overlays[i].lazy, ct);
                continue;
            }

            const lazy = b.path(b.pathJoin(&.{ dir, entry.path }));
            emitEntry(b, wf, &manifest, path_fwd, lazy, guessContentType(entry.path));
        }
    } else |_| {
        // No frontend directory — fall through to the overlay-only emit.
    }

    // Emit any overlay that didn't shadow an on-disk file.
    for (overlays, 0..) |ov, i| {
        if (consumed[i]) continue;
        const ct = if (ov.content_type.len > 0) ov.content_type else guessContentType(ov.name);
        emitEntry(b, wf, &manifest, ov.name, ov.lazy, ct);
    }

    manifest.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    _ = wf.add("public_assets.zig", manifest.items);

    return b.createModule(.{
        .root_source_file = wf.getDirectory().path(b, "public_assets.zig"),
    });
}

fn findOverlay(overlays: []const Overlay, name: []const u8) ?usize {
    for (overlays, 0..) |ov, i| {
        if (std.mem.eql(u8, ov.name, name)) return i;
    }
    return null;
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
