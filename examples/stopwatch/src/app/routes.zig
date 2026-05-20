const std = @import("std");
const verve = @import("verve");
const components = @import("components.zig");

pub const routes: []const verve.Route = &.{
    verve.Route.init("/", renderStopwatch),
};

fn renderStopwatch(ctx: *verve.Context) !*verve.Node {
    const body = try components.stopwatch(ctx);
    return components.page(ctx, body);
}
