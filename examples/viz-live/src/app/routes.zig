const verve = @import("verve");
const components = @import("components.zig");

pub const Route = verve.Route;

pub const routes: []const verve.Route = &.{
    verve.Route.init("/", renderIndex),
    verve.Route.init("/multi", renderMulti),
    verve.Route.init("/canvas", renderCanvas),
};

fn renderIndex(ctx: *verve.Context) !*verve.Node {
    const body = try components.index(ctx);
    return components.page(ctx, body);
}

fn renderMulti(ctx: *verve.Context) !*verve.Node {
    const body = try components.vizMulti(ctx);
    return components.page(ctx, body);
}

fn renderCanvas(ctx: *verve.Context) !*verve.Node {
    const body = try components.vizCanvas(ctx);
    return components.page(ctx, body);
}
