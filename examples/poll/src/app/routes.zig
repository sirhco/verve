const std = @import("std");
const verve = @import("verve");
const components = @import("components.zig");
const api = @import("api.zig");

pub const routes: []const verve.Route = &.{
    verve.Route.init("/", renderPoll),
};

fn renderPoll(ctx: *verve.Context) !*verve.Node {
    const body = try components.poll(ctx);
    return components.page(ctx, body);
}
