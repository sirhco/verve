const std = @import("std");
const verve = @import("verve");
const components = @import("components.zig");

pub const routes: []const verve.Route = &.{
    verve.Route.init("/", render),
};

fn render(ctx: *verve.Context) !*verve.Node {
    const body = try components.calculator(ctx);
    return components.page(ctx, body);
}
