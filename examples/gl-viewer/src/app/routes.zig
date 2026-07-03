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
    // Wireframe overlay — demo.vmesh + GlScene + .wireframe(.{.color}).
    verve.Route.init("/wireframe", renderWireframe),
    // Orthographic (parallel) projection — demo.vmesh + .projection(.{.mode=.orthographic}).
    verve.Route.init("/ortho", renderOrtho),
    // Clip planes — shadow.vmesh + .clipPlanes(&.{...}).
    verve.Route.init("/clip", renderClip),
    // Directional shadow map — shadow.vmesh + depth-mapped PCF shadow.
    verve.Route.init("/shadow", renderShadow),
    // Skeletal skinning — GlSkin island + skinbar.vmesh.
    verve.Route.init("/skin", renderSkin),
};

fn renderViewer(ctx: *verve.Context) !*verve.Node {
    const body = try components.viewerPage(ctx);
    return components.page(ctx, body);
}

fn renderOrbit(ctx: *verve.Context) !*verve.Node {
    const body = try components.orbitPage(ctx);
    return components.page(ctx, body);
}

fn renderWireframe(ctx: *verve.Context) !*verve.Node {
    const body = try components.wireframePage(ctx);
    return components.page(ctx, body);
}

fn renderOrtho(ctx: *verve.Context) !*verve.Node {
    const body = try components.orthoPage(ctx);
    return components.page(ctx, body);
}

fn renderClip(ctx: *verve.Context) !*verve.Node {
    const body = try components.clipPage(ctx);
    return components.page(ctx, body);
}

fn renderShadow(ctx: *verve.Context) !*verve.Node {
    const body = try components.shadowPage(ctx);
    return components.page(ctx, body);
}

fn renderSkin(ctx: *verve.Context) !*verve.Node {
    const body = try components.skinPage(ctx);
    return components.page(ctx, body);
}
