//! Page routes for the demo app. Server matches `path` against this table
//! at request time; the matched `render` builds the page Node tree.

const std = @import("std");
const verve = @import("verve");
const components = @import("components.zig");
const api = @import("api.zig");

pub const routes: []const verve.Route = &.{
    verve.Route.init("/", renderHome),
    verve.Route.init("/counter", renderCounter),
    verve.Route.init("/viz", renderViz),
    verve.Route.init("/viz-canvas", renderVizCanvas),
    verve.Route.init("/ws-demo", renderWsDemo),
    verve.Route.init("/anim", renderAnim),
    verve.Route.init("/smooth", renderSmooth),
    verve.Route.init("/gl", renderGl),
    verve.Route.init("/gl-scene", renderGlScene),
    verve.Route.init("/gl-mixed", renderGlMixed),
    verve.Route.init("/gl-shadow", renderGlShadow),
    verve.Route.init("/gl-cutout", renderGlCutout),
    verve.Route.init("/gl-multi", renderGlMulti),
    verve.Route.init("/gl-webgpu", renderGlWebgpu),
    verve.Route.init("/gl-scene-webgpu", renderGlSceneWebgpu),
    verve.Route.init("/gl-skin", renderGlSkin),
    verve.Route.init("/gl-post", renderGlPost),
    verve.Route.init("/gl-double", renderGlDouble),
    verve.Route.init("/gl-cull", renderGlCull),
    verve.Route.init("/gl-instanced", renderGlInstanced),
    verve.Route.init("/gl-fog", renderGlFog),
    verve.Route.init("/gl-morph", renderGlMorph),
    verve.Route.init("/gl-spot", renderGlSpot),
    verve.Route.init("/gl-point", renderGlPoint),
    verve.Route.init("/gl-multishadow", renderGlMultiShadow),
    verve.Route.init("/gl-csm", renderGlCsm),
    verve.Route.init("/gl-area", renderGlArea),
    verve.Route.init("/gl-tonemap", renderGlTonemap),
    verve.Route.init("/gl-ssao", renderGlSsao),
    verve.Route.init("/gl-ssr", renderGlSsr),
    verve.Route.init("/push-multi", renderPushMulti),
    verve.Route.init("/todos", renderTodos),
    verve.Route.init("/work/:slug", renderWorkDetail),
    verve.Route.layout("/app", renderAppShell, &.{
        verve.Route.init("/dashboard", renderAppDashboard),
        verve.Route.init("/settings/:section", renderAppSettings),
    }),
    verve.Route.init("/private", renderPrivate).protect(privateGuard),
};

fn renderHome(ctx: *verve.Context) !*verve.Node {
    const body = try components.home(ctx);
    return components.page(ctx, body);
}

fn renderCounter(ctx: *verve.Context) !*verve.Node {
    const body = try components.counter(ctx, api.currentCount());
    return components.page(ctx, body);
}

fn renderViz(ctx: *verve.Context) !*verve.Node {
    const body = try components.viz(ctx);
    return components.page(ctx, body);
}

fn renderVizCanvas(ctx: *verve.Context) !*verve.Node {
    const body = try components.vizCanvas(ctx);
    return components.page(ctx, body);
}

fn renderWsDemo(ctx: *verve.Context) !*verve.Node {
    const body = try components.wsDemo(ctx);
    return components.page(ctx, body);
}

fn renderAnim(ctx: *verve.Context) !*verve.Node {
    const body = try components.animDemo(ctx);
    return components.page(ctx, body);
}

fn renderSmooth(ctx: *verve.Context) !*verve.Node {
    const body = try components.smoothDemo(ctx);
    return components.page(ctx, body);
}

fn renderGl(ctx: *verve.Context) !*verve.Node {
    const body = try components.glDemo(ctx);
    return components.page(ctx, body);
}

fn renderGlScene(ctx: *verve.Context) !*verve.Node {
    const body = try components.glScenePage(ctx);
    return components.page(ctx, body);
}

fn renderGlMixed(ctx: *verve.Context) !*verve.Node {
    const body = try components.glSceneMixed(ctx);
    return components.page(ctx, body);
}

fn renderGlShadow(ctx: *verve.Context) !*verve.Node {
    const body = try components.glSceneShadow(ctx);
    return components.page(ctx, body);
}

fn renderGlMulti(ctx: *verve.Context) !*verve.Node {
    const body = try components.glSceneMulti(ctx);
    return components.page(ctx, body);
}

fn renderGlCutout(ctx: *verve.Context) !*verve.Node {
    const body = try components.glSceneCutout(ctx);
    return components.page(ctx, body);
}

fn renderGlWebgpu(ctx: *verve.Context) !*verve.Node {
    const body = try components.glWebgpu(ctx);
    return components.page(ctx, body);
}

fn renderGlSceneWebgpu(ctx: *verve.Context) !*verve.Node {
    const body = try components.glSceneWebgpu(ctx);
    return components.page(ctx, body);
}

fn renderGlSkin(ctx: *verve.Context) !*verve.Node {
    const body = try components.glSkin(ctx);
    return components.page(ctx, body);
}

fn renderGlPost(ctx: *verve.Context) !*verve.Node {
    const body = try components.glPost(ctx);
    return components.page(ctx, body);
}

fn renderGlDouble(ctx: *verve.Context) !*verve.Node {
    const body = try components.glSceneDouble(ctx);
    return components.page(ctx, body);
}

fn renderGlCull(ctx: *verve.Context) !*verve.Node {
    const body = try components.glSceneCull(ctx);
    return components.page(ctx, body);
}

fn renderGlInstanced(ctx: *verve.Context) !*verve.Node {
    const body = try components.glSceneInstanced(ctx);
    return components.page(ctx, body);
}

fn renderGlFog(ctx: *verve.Context) !*verve.Node {
    const body = try components.glSceneFog(ctx);
    return components.page(ctx, body);
}

fn renderGlMorph(ctx: *verve.Context) !*verve.Node {
    const body = try components.glSceneMorph(ctx);
    return components.page(ctx, body);
}

fn renderGlSpot(ctx: *verve.Context) !*verve.Node {
    const body = try components.glSceneSpot(ctx);
    return components.page(ctx, body);
}

fn renderGlPoint(ctx: *verve.Context) !*verve.Node {
    const body = try components.glScenePoint(ctx);
    return components.page(ctx, body);
}

fn renderGlMultiShadow(ctx: *verve.Context) !*verve.Node {
    const body = try components.glSceneMultiShadow(ctx);
    return components.page(ctx, body);
}

fn renderGlCsm(ctx: *verve.Context) !*verve.Node {
    const body = try components.glSceneCsm(ctx);
    return components.page(ctx, body);
}

fn renderGlArea(ctx: *verve.Context) !*verve.Node {
    const body = try components.glSceneArea(ctx);
    return components.page(ctx, body);
}

fn renderGlTonemap(ctx: *verve.Context) !*verve.Node {
    const body = try components.glTonemap(ctx);
    return components.page(ctx, body);
}

fn renderGlSsao(ctx: *verve.Context) !*verve.Node {
    const body = try components.glSsao(ctx);
    return components.page(ctx, body);
}

fn renderGlSsr(ctx: *verve.Context) !*verve.Node {
    const body = try components.glSsr(ctx);
    return components.page(ctx, body);
}

fn renderPushMulti(ctx: *verve.Context) !*verve.Node {
    const body = try components.pushMulti(ctx);
    return components.page(ctx, body);
}

fn renderTodos(ctx: *verve.Context) !*verve.Node {
    const items = try api.copyTodosInto(ctx.alloc());
    const body = try components.todoList(ctx, items);
    return components.page(ctx, body);
}

fn renderWorkDetail(ctx: *verve.Context) !*verve.Node {
    const slug = ctx.param("slug") orelse "";
    const body = try components.workDetail(ctx, slug);
    return components.page(ctx, body);
}

fn renderAppShell(ctx: *verve.Context) !*verve.Node {
    const body = try components.appShell(ctx, ctx.outlet());
    return components.page(ctx, body);
}

fn renderAppDashboard(ctx: *verve.Context) !*verve.Node {
    return components.appDashboard(ctx);
}

fn renderAppSettings(ctx: *verve.Context) !*verve.Node {
    const section = ctx.param("section") orelse "general";
    return components.appSettings(ctx, section);
}

fn renderPrivate(ctx: *verve.Context) !*verve.Node {
    const body = try components.privatePage(ctx);
    return components.page(ctx, body);
}

/// Sample route guard: redirects to /counter unless `?token=...`
/// is present in the URL. Real apps would check a session cookie or
/// auth header; the shape is the same.
fn privateGuard(ctx: *verve.Context) ?verve.Redirect {
    const loc = ctx.location orelse return .{ .to = "/counter" };
    var l = loc.*;
    const t = l.queryGet(ctx.alloc(), "token") catch return .{ .to = "/counter" };
    if (t) |val| if (val.len > 0) return null;
    return .{ .to = "/counter" };
}
