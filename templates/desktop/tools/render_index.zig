//! Build-time SSR for the desktop scaffold.
//!
//! Imports `components` + `verve`, builds a Node tree via
//! `components.page(ctx, components.home(ctx))`, then walks it through
//! `verve.Renderer.render` and writes the HTML to stdout. `build.zig`
//! captures the output via `addRunArtifact.captureStdOut` and grafts it
//! into the `public_assets` table as `index.html`.

const std = @import("std");
const verve = @import("verve");
const components = @import("components");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_alloc.deinit();
    const gpa = debug_alloc.allocator();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const ctx = verve.Context.init(&arena);

    const tree = try components.page(&ctx, try components.home(&ctx));

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try out.writeAll("<!doctype html>");
    try verve.Renderer.render(out, tree);
    try out.flush();
}
