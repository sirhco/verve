//! Route table for the showcase app. Each route demonstrates a
//! distinct Phase 0-10 surface — see components.zig for the body
//! of each render.

const std = @import("std");
const verve = @import("verve");
const components = @import("components.zig");
const api = @import("api.zig");

pub const routes: []const verve.Route = &.{
    verve.Route.init("/",                renderHome),

    // Phase 0: path parameters + Location query + assetHref
    verve.Route.init("/work/:slug",      renderWorkDetail),
    verve.Route.init("/files/*rest",     renderFilePath),

    // Phase 1+9: reactive Signal + Effect + Store
    verve.Route.init("/counter-reactive", renderCounterReactive),
    verve.Route.init("/store-demo",      renderStoreDemo),

    // Phase 3+4: Resource + Suspense
    verve.Route.init("/resource-demo",   renderResourceDemo),
    verve.Route.init("/suspense-demo",   renderSuspenseDemo),

    // Phase 9: ErrorBoundary
    verve.Route.init("/error-boundary",  renderErrorBoundary),

    // Phase 5: CSRF-protected forms + ActionForm
    verve.Route.init("/forms-demo",      renderForms),

    // Phase 9: i18n
    verve.Route.init("/i18n/:locale",    renderI18n),

    // Phase 7: nested routes via Route.layout + ctx.outlet()
    verve.Route.layout("/app", renderAppShell, &.{
        verve.Route.init("/dashboard",         renderAppDashboard),
        verve.Route.init("/settings/:section", renderAppSettings),
    }),

    // Phase 7: ProtectedRoute guard
    verve.Route.init("/private", renderPrivate).protect(api.privateGuard),

    // Phase 7: SPA Link demo (same routes; SPA nav comes free via verve.link)
    verve.Route.init("/spa-tour", renderSpaTour),

    // Phase 8: islands scaffold
    verve.Route.init("/island-demo", renderIslandDemo),

    // Non-HTML response: fragment + contentType
    verve.Route.init("/sitemap.xml", renderSitemap),
};

fn renderHome(ctx: *verve.Context) !*verve.Node {
    try ctx.setTitle("Verve Showcase");
    return components.home(ctx);
}

fn renderWorkDetail(ctx: *verve.Context) !*verve.Node {
    const slug = ctx.param("slug") orelse "";
    return components.workDetail(ctx, slug);
}

fn renderFilePath(ctx: *verve.Context) !*verve.Node {
    const rest = ctx.param("rest") orelse "";
    return components.filePath(ctx, rest);
}

fn renderCounterReactive(ctx: *verve.Context) !*verve.Node {
    return components.counterReactive(ctx);
}

fn renderStoreDemo(ctx: *verve.Context) !*verve.Node {
    return components.storeDemo(ctx);
}

fn renderResourceDemo(ctx: *verve.Context) !*verve.Node {
    return components.resourceDemo(ctx);
}

fn renderSuspenseDemo(ctx: *verve.Context) !*verve.Node {
    return components.suspenseDemo(ctx);
}

fn renderErrorBoundary(ctx: *verve.Context) !*verve.Node {
    return components.errorBoundaryDemo(ctx);
}

fn renderForms(ctx: *verve.Context) !*verve.Node {
    const items = try api.copyTodos(ctx.alloc());
    return components.formsDemo(ctx, items);
}

fn renderI18n(ctx: *verve.Context) !*verve.Node {
    const path_locale = ctx.param("locale") orelse "en";
    return components.i18nDemo(ctx, path_locale);
}

fn renderAppShell(ctx: *verve.Context) !*verve.Node {
    return components.appShell(ctx, ctx.outlet());
}

fn renderAppDashboard(ctx: *verve.Context) !*verve.Node {
    return components.appDashboard(ctx);
}

fn renderAppSettings(ctx: *verve.Context) !*verve.Node {
    const section = ctx.param("section") orelse "general";
    return components.appSettings(ctx, section);
}

fn renderPrivate(ctx: *verve.Context) !*verve.Node {
    return components.privatePage(ctx);
}

fn renderSpaTour(ctx: *verve.Context) !*verve.Node {
    return components.spaTour(ctx);
}

fn renderIslandDemo(ctx: *verve.Context) !*verve.Node {
    return components.islandDemo(ctx);
}

fn renderSitemap(ctx: *verve.Context) !*verve.Node {
    return components.sitemap(ctx);
}
