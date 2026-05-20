const std = @import("std");
const verve = @import("verve");
const components = @import("components.zig");
const api = @import("api.zig");

pub const Route = struct {
    path: []const u8,
    render: *const fn (ctx: *const verve.Context) anyerror!*verve.Node,
};

pub const routes: []const Route = &.{
    .{ .path = "/", .render = renderIndex },
    .{ .path = "/stats", .render = renderStats },
};

fn renderIndex(ctx: *const verve.Context) !*verve.Node {
    const items = try api.snapshot(ctx.alloc());
    const body = try components.index(ctx, items);
    return components.page(ctx, body);
}

fn renderStats(ctx: *const verve.Context) !*verve.Node {
    const body = try components.stats(ctx, api.totalBookmarks(), api.totalVisits());
    return components.page(ctx, body);
}
