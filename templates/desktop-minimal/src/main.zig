//! Minimal desktop scaffold entry point.
//!
//! Opens a window, wires the IPC handler, runs the platform event loop.
//! No tray, no multi-window, no smoke harness — see the full scaffold
//! (`verve-cli new <dir> --desktop`) for those.

const std = @import("std");
const verve = @import("verve");
const desktop = @import("desktop");
const public_assets = @import("public_assets");
const handlers = @import("handlers.zig");

pub fn main(init: std.process.Init) !void {
    // Seed the confirmation-token key once at startup — same seam the
    // server uses next to its CSRF init. Without this, a `.dangerous`
    // `verve.ai` tool stays permanently unconfirmable (fails closed, not a
    // security hole, but a silent capability gap). Idempotent.
    verve.ai.policy.initRandom(init.io);

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // The build embeds `frontend/` into `public_assets.entries` with
    // the same shape the desktop asset router consumes. Cast directly —
    // the field layout is intentionally compatible.
    const asset_entries: []const desktop.AssetEntry = @ptrCast(public_assets.entries);

    var window = try desktop.Window.init(allocator, .{
        .title = "Verve Desktop — minimal",
        .width = 480,
        .height = 320,
        .devtools = true,
        .assets = asset_entries,
        .initial_path = "index.html",
    });
    defer window.deinit();

    const ctx_ptr = handlers.attach(&window);
    window.setMessageHandler(handlers.onMessage, ctx_ptr);

    window.run();
}
