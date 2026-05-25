//! Entry point for the scaffolded desktop app. The body shows the
//! common shape: bind embedded assets, register an IPC handler, open
//! the window, and run the platform event loop.

const std = @import("std");
const desktop = @import("desktop");
const public_assets = @import("public_assets");
const handlers = @import("handlers.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // CLI:
    //   --smoke <dir>      Enables the Level-3 smoke harness. The
    //                      bridge JS sees `?smoke=1` in location.search
    //                      and drives a scripted ping → counter-click →
    //                      smoke_done sequence; the smoke_done IPC
    //                      handler writes a checksum.txt + shot.png
    //                      into <dir>, then terminates the app.
    //                      Production runs leave this off.
    //   --dev <dir>        Enables runtime disk-read fallback for the
    //                      asset router. Scheme-handler requests that
    //                      miss the embedded `public_assets` table fall
    //                      through to <dir>/<path>. Edit
    //                      frontend/style.css, reload (Cmd+R), see the
    //                      change without rebuilding the binary. Path
    //                      traversal is rejected. Disabled by default.
    var smoke_dir: ?[]const u8 = null;
    var dev_dir: ?[]const u8 = null;
    // Cold-launch deep-link URL. Set when argv has either `--url <u>`
    // or a positional that starts with the app's custom scheme. macOS
    // routes URLs through NSAppleEventManager instead (its AEH fires
    // even for cold launches), so this path is mostly Windows + Linux.
    var cold_url: ?[]const u8 = null;
    var initial_path: []const u8 = "index.html";
    {
        var arg_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
        defer arg_iter.deinit();
        _ = arg_iter.skip(); // argv[0] = exe path
        while (arg_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--smoke")) {
                if (arg_iter.next()) |val| {
                    smoke_dir = try allocator.dupe(u8, val);
                    initial_path = "index.html?smoke=1";
                }
            } else if (std.mem.eql(u8, arg, "--dev")) {
                if (arg_iter.next()) |val| {
                    dev_dir = try allocator.dupe(u8, val);
                }
            } else if (std.mem.eql(u8, arg, "--url")) {
                if (arg_iter.next()) |val| {
                    cold_url = try allocator.dupe(u8, val);
                }
            } else if (std.mem.startsWith(u8, arg, "verve://")) {
                cold_url = try allocator.dupe(u8, arg);
            }
        }
    }
    defer if (smoke_dir) |d| allocator.free(d);
    defer if (dev_dir) |d| allocator.free(d);
    defer if (cold_url) |u| allocator.free(u);

    // Single-instance lock. Held for the lifetime of `main` — when the
    // process exits the kernel reclaims the underlying flock / named
    // mutex, so a second launch immediately picks up the slot. Skip in
    // smoke runs so back-to-back CI invocations don't race on the
    // tmp-file fd / mutex name.
    const instance_name = "verve-desktop";
    var lock: ?desktop.single_instance.Lock = null;
    defer if (lock) |*l| l.release();
    if (smoke_dir == null) {
        if (desktop.single_instance.acquire(allocator, instance_name)) |l| {
            lock = l;
        } else |err| switch (err) {
            error.AlreadyRunning => {
                // Second instance with a cold-launch URL: hand the
                // URL off to the running copy via the deep-link
                // forwarder (WM_COPYDATA on Win, abstract AF_UNIX
                // socket on Linux), then exit. macOS never reaches
                // this branch — the OS routes URLs to the running
                // process via NSAppleEventManager directly.
                if (cold_url) |u| {
                    desktop.deep_link.forwardToRunningInstance(allocator, instance_name, u) catch |fe| switch (fe) {
                        // macOS routes URLs via NSAppleEventManager, so
                        // the manual forward isn't supposed to run on
                        // that backend. Suppress the noise.
                        error.Unsupported => {},
                        else => std.log.err("verve.desktop: forward to running instance failed: {s}", .{@errorName(fe)}),
                    };
                } else {
                    std.log.err("verve.desktop: another instance is already running", .{});
                }
                return;
            },
            else => |e| return e,
        }
    }

    // Caller is responsible for creating <smoke-dir> before launching;
    // the build step does this. App-side does not pull in std.Io just
    // to mkdir.

    // The build embeds `frontend/` (configurable via `-Dpublic-dir`)
    // and emits `public_assets.entries` with the same shape the desktop
    // asset router consumes. Cast it directly — the field layout is
    // intentionally compatible.
    const asset_entries: []const desktop.AssetEntry = @ptrCast(public_assets.entries);

    var window: desktop.Window = undefined;
    // The router needs a stable pointer to its Ctx, and the Window
    // needs that pointer in `on_message_ctx`. Order: build the Window
    // first (so `attach` has a real pointer to capture), then plug
    // the returned Ctx pointer in via `setMessageHandler`.
    const dev_assets: ?desktop.DevAssetsConfig = if (dev_dir) |d| .{ .dir = d, .io = io } else null;

    window = try desktop.Window.init(allocator, .{
        .title = "Verve Desktop",
        .width = 1100,
        .height = 760,
        .devtools = true,
        .assets = asset_entries,
        .dev_assets = dev_assets,
        .initial_path = initial_path,
    });
    defer window.deinit();

    const ctx_ptr = handlers.attach(&window, asset_entries, smoke_dir, io);
    window.setMessageHandler(handlers.onMessage, ctx_ptr);
    window.setUrlOpenHandler(handlers.onUrlOpen, ctx_ptr);

    // Optional tray icon with a submenu. Best-effort: a runtime error
    // (libayatana missing on Linux, status-bar unavailable in headless
    // macOS, …) just logs + drops the tray; the rest of the app keeps
    // running. Menu items surface via `handlers.onTrayItem` keyed on
    // the per-item `id` (1 = focus window, 2 = fire native notify, 99
    // = quit).
    const tray_menu = [_]desktop.tray.TrayMenuItem{
        .{ .label = "Show window", .id = 1 },
        .{ .label = "Notify", .id = 2 },
        .{ .label = null }, // separator
        .{ .label = "Quit", .id = 99 },
    };
    var tray_handle: ?desktop.tray.Tray = desktop.tray.init(allocator, &window, .{
        .label = "V",
        .tooltip = "Verve Desktop",
        .menu = &tray_menu,
        .on_menu_item = handlers.onTrayItem,
        .on_menu_item_ctx = ctx_ptr,
    }) catch |err| blk: {
        std.log.warn("verve.desktop: tray init failed: {s}", .{@errorName(err)});
        break :blk null;
    };
    defer if (tray_handle) |*t| t.deinit();

    // Start the warm-launch URL listener. macOS makes this a no-op
    // (NSAppleEventManager already covers warm-launch). Windows leans
    // on the wndProc WM_COPYDATA case, so this is also a no-op there.
    // Linux binds an abstract AF_UNIX socket keyed on `instance_name`
    // and wires a GIOChannel watch into the GTK main loop.
    desktop.deep_link.startListener(&window, instance_name) catch |err| {
        std.log.warn("verve.desktop: deep-link listener failed: {s}", .{@errorName(err)});
    };

    // Cold-launch URL: synthesize a delivery through the same
    // callback so apps don't need a separate code path for argv vs.
    // OS-delivered URLs. macOS already routes the URL via the AEH
    // installed in setUrlOpenHandler; the cold_url branch is the
    // Win/Linux argv path. Harmless on macOS (no `--url` arg expected
    // there for non-dev usage).
    if (cold_url) |u| window.deliverUrl(u);

    window.run();
}
