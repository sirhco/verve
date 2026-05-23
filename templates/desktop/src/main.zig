//! Entry point for the scaffolded desktop app. The body shows the
//! common shape: bind embedded assets, register an IPC handler, open
//! the window, and run the platform event loop.

const std = @import("std");
const desktop = @import("desktop");
const public_assets = @import("public_assets");
const handlers = @import("handlers.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // The build embeds `frontend/` (configurable via `-Dpublic-dir`)
    // and emits `public_assets.entries` with the same shape the desktop
    // asset router consumes. Cast it directly — the field layout is
    // intentionally compatible.
    const asset_entries: []const desktop.AssetEntry = @ptrCast(public_assets.entries);

    var window = try desktop.Window.init(allocator, .{
        .title = "Verve Desktop",
        .width = 1100,
        .height = 760,
        .devtools = true,
        .assets = asset_entries,
        .initial_path = "index.html",
        .on_message = handlers.onMessage,
        .on_message_ctx = null,
    });
    defer window.deinit();

    handlers.attach(&window, asset_entries);
    window.run();
}
