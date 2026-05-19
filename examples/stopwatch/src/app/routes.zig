const std = @import("std");
const verve = @import("verve");
const components = @import("components.zig");

pub const Route = struct {
    path: []const u8,
    render: *const fn (ctx: *const verve.Context) anyerror!verve.Node,
};

pub const routes: []const Route = &.{
    .{ .path = "/", .render = renderStopwatch },
};

fn renderStopwatch(ctx: *const verve.Context) !verve.Node {
    const body = try components.stopwatch(ctx);
    return components.page(ctx, body);
}
