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
    // Public wasm-client façade: reactive primitives + DOM-wired adapter.
    // The client.wasm target imports this so signals registered in the
    // scaffold drive DOM mutations through the runtime's `on_set` hook.
    const verve_client_mod = verve_dep.module("verve_client");

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
        .imports = &.{.{ .name = "verve", .module = verve_host_mod }},
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
        .imports = &.{
            .{ .name = "verve", .module = verve_client_mod },
        },
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
            // UserNotifications: desktop.notifications UNUserNotificationCenter.
            desktop_mod.linkFramework("UserNotifications", .{});
            // IOKit: desktop.power battery / charging readout.
            desktop_mod.linkFramework("IOKit", .{});
            // CoreFoundation: pulled in transitively by Cocoa/Foundation
            // but linking explicitly so power.zig's CF externs resolve
            // regardless of macOS SDK version.
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
            // Shcore provides GetDpiForMonitor (used by
            // `desktop.displays.list`). Available on Win 8.1+.
            desktop_mod.linkSystemLibrary("Shcore", .{});
            // Windowscodecs (WIC) backs the CF_DIBV5 image clipboard
            // (PNG <-> DIB transcode).
            desktop_mod.linkSystemLibrary("Windowscodecs", .{});
            // Uiautomationcore backs the server-side UIA accessibility
            // provider (role description / subrole / help text).
            desktop_mod.linkSystemLibrary("Uiautomationcore", .{});
            // combase exports the WinRT activation entry points
            // (Ro*/Windows*String) used by the Action Center toast.
            desktop_mod.linkSystemLibrary("combase", .{});
            // WebView2 loader. Ship the SDK under `third_party/webview2/`
            // or override with `-Dwebview2-sdk=...`. When the SDK is
            // not present, `tools/fetch_webview2.{sh,ps1}` downloads
            // the pinned NuGet release. The script is idempotent so
            // running it from every Windows build is cheap (an
            // existing .lib short-circuits before any network I/O).
            const sdk = b.option([]const u8, "webview2-sdk", "Path to the WebView2 SDK") orelse "third_party/webview2";
            const skip_fetch = b.option(bool, "webview2-no-fetch", "Skip auto-vendor of WebView2 SDK from NuGet") orelse false;
            const fetch_cmd: ?*std.Build.Step.Run = if (skip_fetch) null else if (builtin.os.tag == .windows) blk: {
                // Prefer PowerShell 7 (`pwsh`) but fall back to Windows
                // PowerShell 5.1 (`powershell`), which ships on every
                // Windows host — `pwsh` is an optional separate install.
                const ps = b.findProgram(&.{ "pwsh", "powershell" }, &.{}) catch "powershell";
                const c = b.addSystemCommand(&.{ ps, "-NoProfile", "-File", "tools/fetch_webview2.ps1", "-Dest" });
                c.addArg(sdk);
                break :blk c;
            } else blk: {
                const c = b.addSystemCommand(&.{ "sh", "tools/fetch_webview2.sh" });
                c.addArg(b.fmt("--dest={s}", .{sdk}));
                break :blk c;
            };
            if (fetch_cmd) |fc| exe.step.dependOn(&fc.step);
            desktop_mod.addLibraryPath(b.path(sdk));
            desktop_mod.linkSystemLibrary("WebView2Loader.dll", .{});

            // The produced .exe has a load-time import of WebView2Loader.dll;
            // the Windows loader resolves it next to the binary, so install a
            // copy into bin/ alongside app.exe. Without this the app fails to
            // start with STATUS_DLL_NOT_FOUND before main() runs.
            const install_loader = b.addInstallBinFile(b.path(b.pathJoin(&.{ sdk, "WebView2Loader.dll" })), "WebView2Loader.dll");
            if (fetch_cmd) |fc| install_loader.step.dependOn(&fc.step);
            b.getInstallStep().dependOn(&install_loader.step);
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
        const notarize_profile = b.option(
            []const u8,
            "notarize-profile",
            "notarytool keychain profile (from `xcrun notarytool store-credentials`). " ++
                "Enables `zig build notarize`; requires -Dcodesign=<Developer ID Application> (hardened implied).",
        );
        // Opt-in hardened runtime + entitlements. Required before
        // notarization but not before ad-hoc signing — self-built apps
        // can leave this off. When set, codesign runs with
        // `--options=runtime --entitlements <generated.plist>` where
        // the plist enables the three keys WKWebView needs under the
        // hardened runtime (JIT, unsigned-executable-memory, library
        // validation disable for embedded WebKit dylibs).
        const hardened = (b.option(
            bool,
            "hardened",
            "Sign with hardened runtime + entitlements (required for notarization; implied by -Dnotarize-profile).",
        ) orelse false) or (notarize_profile != null);
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
            \\    <string>11.0</string>
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

        var sign_step: ?*std.Build.Step = null;
        if (codesign_id) |ident| {
            const bundle_path = b.fmt("zig-out/{s}", .{bundle_root});
            const sign = b.addSystemCommand(&.{
                "codesign", "--force", "--deep", "--sign", ident,
            });
            if (hardened) {
                // Hardened runtime forbids JIT and unsigned executable
                // memory by default; WKWebView's JS engine needs both.
                // `disable-library-validation` lets the bundled WebKit
                // dylibs load without their own signature chain.
                const entitlements_src =
                    \\<?xml version="1.0" encoding="UTF-8"?>
                    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                    \\<plist version="1.0">
                    \\<dict>
                    \\    <key>com.apple.security.cs.allow-jit</key>
                    \\    <true/>
                    \\    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
                    \\    <true/>
                    \\    <key>com.apple.security.cs.disable-library-validation</key>
                    \\    <true/>
                    \\</dict>
                    \\</plist>
                    \\
                ;
                const ent_wf = b.addWriteFiles();
                const ent_lazy = ent_wf.add(b.fmt("{s}.entitlements", .{exe.name}), entitlements_src);
                sign.addArg("--options=runtime");
                sign.addPrefixedFileArg("--entitlements=", ent_lazy);
            }
            sign.addArg(bundle_path);
            sign.step.dependOn(bundle_step);
            const s = b.step("codesign", "Sign the macOS bundle (-Dcodesign=<identity>)");
            s.dependOn(&sign.step);
            sign_step = s;
        }

        if (notarize_profile) |profile| {
            if (sign_step) |signed| {
                const app_path = b.fmt("zig-out/{s}", .{bundle_root});
                const submit_zip = b.fmt("zig-out/{s}-submission.zip", .{exe.name});
                const ship_zip = b.fmt("zig-out/{s}.zip", .{exe.name});

                // 1. Zip the signed .app — notarytool needs a container.
                const zip_submit = b.addSystemCommand(&.{
                    "ditto", "-c", "-k", "--keepParent", app_path, submit_zip,
                });
                zip_submit.step.dependOn(signed);

                // 2. Submit + wait for the notary verdict.
                const submit = b.addSystemCommand(&.{
                    "xcrun",              "notarytool", "submit", submit_zip,
                    "--keychain-profile", profile,      "--wait",
                });
                submit.step.dependOn(&zip_submit.step);

                // 3. Staple the ticket into the .app.
                const staple = b.addSystemCommand(&.{
                    "xcrun", "stapler", "staple", app_path,
                });
                staple.step.dependOn(&submit.step);

                // 4. Re-zip the STAPLED .app as the distributable artifact.
                const zip_ship = b.addSystemCommand(&.{
                    "ditto", "-c", "-k", "--keepParent", app_path, ship_zip,
                });
                zip_ship.step.dependOn(&staple.step);

                const notarize_step = b.step(
                    "notarize",
                    "Notarize + staple the signed macOS bundle (-Dnotarize-profile=<name>; requires -Dcodesign=<Developer ID Application>)",
                );
                notarize_step.dependOn(&zip_ship.step);
            }
        }
    }

    // Linux desktop-integration step. `zig build install-icons` lays
    // out a Hicolor icon-theme tree + a freedesktop `.desktop` file
    // under `zig-out/share/`. Run after `zig build` to produce:
    //
    //   zig-out/share/icons/hicolor/scalable/apps/<name>.png   (always, if -Dlinux-icon set)
    //   zig-out/share/icons/hicolor/<N>x<N>/apps/<name>.png    (per -Dlinux-icon-<N>)
    //   zig-out/share/applications/<name>.desktop              (always)
    //
    // Install with:
    //   cp -r zig-out/share ~/.local/share        # user install
    //   sudo cp -r zig-out/share /usr/share       # system install
    // and optionally `gtk-update-icon-cache` / `update-desktop-database`.
    //
    // No image resizing — Zig stdlib has no image library and pulling
    // ImageMagick / libpng as a build dep is heavier than the value.
    // Callers either pre-resize per size or rely on the single
    // scalable/ entry as the catch-all (Hicolor's icon-lookup spec
    // explicitly walks scalable when no size match exists).
    if (target.result.os.tag == .linux) {
        const linux_icon = b.option(
            []const u8,
            "linux-icon",
            "Path to a PNG icon installed into share/icons/hicolor/scalable/apps/<name>.png.",
        );
        const linux_categories = b.option(
            []const u8,
            "linux-categories",
            "Semicolon-separated freedesktop categories list for the .desktop Categories= field (default: Utility;).",
        ) orelse "Utility;";
        const linux_comment = b.option(
            []const u8,
            "linux-comment",
            "Short description for the .desktop Comment= field (default: derived from the exe name).",
        ) orelse b.fmt("Verve desktop application: {s}", .{exe.name});
        const linux_generic = b.option(
            []const u8,
            "linux-generic-name",
            "GenericName= for the .desktop file (default: 'Application').",
        ) orelse "Application";
        const linux_exec = b.option(
            []const u8,
            "linux-exec",
            "Exec= line for the .desktop file. Default: '<name> %U' (relies on $PATH lookup). Override with an absolute path for prefix installs.",
        ) orelse b.fmt("{s} %U", .{exe.name});

        const desktop_step = b.step(
            "install-icons",
            "Stage Hicolor icons + .desktop file under zig-out/share/ for Linux install",
        );

        // `.desktop` file is always generated — even without an icon
        // the entry shows up in app launchers with a generic glyph.
        const desktop_src = b.fmt(
            \\[Desktop Entry]
            \\Type=Application
            \\Version=1.0
            \\Name={s}
            \\GenericName={s}
            \\Comment={s}
            \\Exec={s}
            \\Icon={s}
            \\Terminal=false
            \\Categories={s}
            \\StartupNotify=true
            \\StartupWMClass={s}
            \\
        , .{ exe.name, linux_generic, linux_comment, linux_exec, exe.name, linux_categories, exe.name });
        const desktop_wf = b.addWriteFiles();
        const desktop_lazy = desktop_wf.add(b.fmt("{s}.desktop", .{exe.name}), desktop_src);
        const inst_desktop = b.addInstallFileWithDir(
            desktop_lazy,
            .{ .custom = "share/applications" },
            b.fmt("{s}.desktop", .{exe.name}),
        );
        desktop_step.dependOn(&inst_desktop.step);

        if (linux_icon) |ip| {
            const icon_lazy: std.Build.LazyPath = if (std.fs.path.isAbsolute(ip))
                .{ .cwd_relative = ip }
            else
                b.path(ip);
            const inst_icon = b.addInstallFileWithDir(
                icon_lazy,
                .{ .custom = "share/icons/hicolor/scalable/apps" },
                b.fmt("{s}.png", .{exe.name}),
            );
            desktop_step.dependOn(&inst_icon.step);
        }

        // Per-size variants. Hicolor's standard sizes are
        // 16/22/24/32/48/64/96/128/256/512 — we expose the most
        // commonly shipped ones. Each is optional; missing sizes are
        // resolved by app launchers via Hicolor's scalable fallback.
        const sizes = [_]u32{ 16, 22, 24, 32, 48, 64, 96, 128, 256, 512 };
        inline for (sizes) |sz| {
            const flag = b.fmt("linux-icon-{d}", .{sz});
            const desc = b.fmt("PNG icon for {d}x{d} Hicolor variant.", .{ sz, sz });
            const ip = b.option([]const u8, flag, desc);
            if (ip) |path| {
                const icon_lazy: std.Build.LazyPath = if (std.fs.path.isAbsolute(path))
                    .{ .cwd_relative = path }
                else
                    b.path(path);
                const subdir = b.fmt("share/icons/hicolor/{d}x{d}/apps", .{ sz, sz });
                const inst_sz = b.addInstallFileWithDir(
                    icon_lazy,
                    .{ .custom = subdir },
                    b.fmt("{s}.png", .{exe.name}),
                );
                desktop_step.dependOn(&inst_sz.step);
            }
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
            // `pwsh` (PS7) is optional; fall back to bundled `powershell` (5.1).
            const ps = b.findProgram(&.{ "pwsh", "powershell" }, &.{}) catch "powershell";
            const smoke = b.addSystemCommand(&.{ ps, "-NoProfile", "-File", "tools/smoke_windows.ps1", "-App" });
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
