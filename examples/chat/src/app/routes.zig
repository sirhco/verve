//! Page routes.

const std = @import("std");
const verve = @import("verve");
const components = @import("components.zig");
const api = @import("api.zig");

pub const routes: []const verve.Route = &.{
    verve.Route.init("/", renderHome),
    verve.Route.init("/chat", renderChat),
};

fn renderHome(ctx: *verve.Context) !*verve.Node {
    const body = try components.home(ctx);
    return components.page(ctx, body);
}

fn renderChat(ctx: *verve.Context) !*verve.Node {
    const msgs = try api.snapshot(ctx.alloc());
    const body = try components.chat(ctx, msgs);
    return components.page(ctx, body);
}
