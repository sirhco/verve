const std = @import("std");
const verve = @import("verve");
const components = @import("components.zig");

pub const Route = struct {
    path: []const u8,
    render: *const fn (ctx: *const verve.Context) anyerror!verve.Node,
};

pub const routes: []const Route = &.{
    .{ .path = "/", .render = render },
};

fn render(ctx: *const verve.Context) !verve.Node {
    const body = try components.calculator(ctx);
    return components.page(ctx, body);
}
