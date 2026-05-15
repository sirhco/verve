//! Page routes for the demo app. Server matches `path` against this table
//! at request time; the matched `render` builds the page Node tree.

const std = @import("std");
const verve = @import("verve");
const components = @import("components.zig");

pub const Route = struct {
    path: []const u8,
    render: *const fn (ctx: *const verve.Context) anyerror!verve.Node,
};

pub const routes: []const Route = &.{
    .{ .path = "/", .render = renderHome },
    .{ .path = "/counter", .render = renderHome },
};

fn renderHome(ctx: *const verve.Context) !verve.Node {
    const body = try components.counter(ctx, 0);
    return components.page(ctx, body);
}
