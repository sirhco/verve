const std = @import("std");
const verve = @import("verve");
const components = @import("components.zig");
const api = @import("api.zig");

pub const Route = struct {
    path: []const u8,
    render: *const fn (ctx: *const verve.Context) anyerror!verve.Node,
};

pub const routes: []const Route = &.{
    .{ .path = "/", .render = renderPoll },
};

fn renderPoll(ctx: *const verve.Context) !verve.Node {
    const body = try components.poll(ctx);
    return components.page(ctx, body);
}
