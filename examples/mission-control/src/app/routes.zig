const verve = @import("verve");
const components = @import("components.zig");

pub const Route = verve.Route;

pub const routes: []const verve.Route = &.{
    verve.Route.init("/", renderIndex),
};

fn renderIndex(ctx: *verve.Context) !*verve.Node {
    const body = try components.index(ctx);
    return components.page(ctx, body);
}
