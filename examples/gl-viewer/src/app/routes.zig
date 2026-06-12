const verve = @import("verve");
const components = @import("components.zig");

pub const Route = verve.Route;

pub const routes: []const verve.Route = &.{
    // Product viewer: scroll-scrub turntable (P5) over the full declarative
    // surface — camera, light, named pick, poster.
    verve.Route.init("/", renderViewer),
    // Plain interactive orbit/pick mode: drag to orbit, wheel to zoom, click
    // to pick, with a gentle continuous auto-rotate.
    verve.Route.init("/orbit", renderOrbit),
};

fn renderViewer(ctx: *verve.Context) !*verve.Node {
    const body = try components.viewerPage(ctx);
    return components.page(ctx, body);
}

fn renderOrbit(ctx: *verve.Context) !*verve.Node {
    const body = try components.orbitPage(ctx);
    return components.page(ctx, body);
}
