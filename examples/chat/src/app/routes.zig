//! Page routes.

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
    .{ .path = "/chat", .render = renderChat },
};

fn renderHome(ctx: *const verve.Context) !verve.Node {
    const body = try components.home(ctx);
    return components.page(ctx, body);
}

fn renderChat(ctx: *const verve.Context) !verve.Node {
    const msgs = try api.snapshot(ctx.alloc());
    const body = try components.chat(ctx, msgs);
    return components.page(ctx, body);
}
