//! Page routes for the demo app. Server matches `path` against this table
//! at request time; the matched `render` builds the page Node tree.

const std = @import("std");
const verve = @import("verve");
const components = @import("components.zig");
const api = @import("api.zig");

pub const Route = struct {
    path: []const u8,
    render: *const fn (ctx: *const verve.Context) anyerror!verve.Node,
};

pub const routes: []const Route = &.{
    .{ .path = "/", .render = renderHome },
    .{ .path = "/counter", .render = renderCounter },
};

fn renderHome(ctx: *const verve.Context) !verve.Node {
    const body = try components.home(ctx);
    return components.page(ctx, body);
}

fn renderCounter(ctx: *const verve.Context) !verve.Node {
    const body = try components.counter(ctx, api.last_count);
    return components.page(ctx, body);
}
