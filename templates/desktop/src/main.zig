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
    var lock: ?desktop.single_instance.Lock = null;
    defer if (lock) |*l| l.release();
    if (smoke_dir == null) {
        if (desktop.single_instance.acquire(allocator, "verve-desktop")) |l| {
            lock = l;
        } else |err| switch (err) {
            error.AlreadyRunning => {
                std.log.err("verve.desktop: another instance is already running", .{});
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

    // Cold-launch URL: synthesize a delivery through the same
    // callback so apps don't need a separate code path for argv vs.
    // OS-delivered URLs. macOS already routes the URL via the AEH
    // installed in setUrlOpenHandler; the cold_url branch is the
    // Win/Linux argv path. Harmless on macOS (no `--url` arg expected
    // there for non-dev usage).
    if (cold_url) |u| window.deliverUrl(u);

    window.run();
}
