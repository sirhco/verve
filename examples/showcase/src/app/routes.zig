//! Route table for the hybrid product hub. Phase A ships routes 1-6
//! (home + blog area + RSS + sitemap). Subsequent phases add tracker,
//! admin, realtime, island, and i18n routes.

const std = @import("std");
const verve = @import("verve");
const api = @import("api.zig");
const components = @import("components.zig");
const shell = components.shell;
const blog_list = components.blog.list;
const blog_post = components.blog.post;
const blog_feed = components.blog.feed;
const tracker_org = components.tracker.org;
const tracker_project = components.tracker.project;
const tracker_board = components.tracker.board;
const tracker_issue = components.tracker.issue;
const tracker_issues = components.tracker.issues;
const tracker_team = components.tracker.team;

pub const routes: []const verve.Route = &.{
    // Phase A
    verve.Route.init("/",                  renderHome),
    verve.Route.init("/blog",              renderBlogIndex),
    verve.Route.init("/blog/c/:slug",      renderBlogCategory),
    verve.Route.init("/blog/:lang/p/:slug", renderBlogPost),
    verve.Route.init("/blog/rss.xml",      renderRss),
    verve.Route.init("/blog/sitemap.xml",  renderSitemap),

    // Phase B — project tracker (3-level nesting)
    verve.Route.init("/app", renderAppRedirect),
    verve.Route.layout("/app/o/:org", renderOrgShell, &.{
        verve.Route.init("/projects", renderProjectList),
        verve.Route.layout("/p/:project", renderProjectShell, &.{
            verve.Route.init("/board",   renderBoard),
            verve.Route.init("/issues",  renderIssues),
            verve.Route.init("/i/:num",  renderIssueDetail),
            verve.Route.init("/team",    renderTeam).protect(api.teamGuard),
        }),
        verve.Route.init("/realtime", renderRealtime),
    }),

    // Phase C — admin sub-routes guarded; /admin itself renders an
    // auth-hint page when the role cookie is missing so the URL keeps
    // working in the browser (devtools Sources view, deep links).
    verve.Route.init("/admin",            renderAdminHome),
    verve.Route.init("/admin/analytics",  renderAdminAnalytics).protect(api.adminGuard),
    verve.Route.init("/admin/settings",   renderAdminSettings).protect(api.adminGuard),
    verve.Route.init("/admin/jobs",       renderAdminJobs).protect(api.adminGuard),
    verve.Route.init("/admin/audit",      renderAdminAudit).protect(api.adminGuard),
    verve.Route.init("/admin/users/:id",  renderAdminUser).protect(api.adminGuard),

    // Phase D
    verve.Route.init("/island-demo", renderIslandDemo),
};

fn renderIslandDemo(ctx: *verve.Context) !*verve.Node {
    const inline_widget = ctx.div().class("kpi").children(.{
        ctx.span().class("kpi-label").text("hydration target"),
        ctx.span().class("kpi-value").bind("count").textInt(api.last_count.load(.monotonic)),
    });
    const wrapped = verve.island(ctx, .{
        .name = "Counter",
        .props = "{\"initial\":0}",
    }, inline_widget);

    const body = ctx.div().children(.{
        ctx.div().class("hero").children(.{
            ctx.h1("Islands"),
            ctx.p().class("lead").text("Server emits a `<verve-island data-name=… data-props=…>` marker around the SSR subtree. The Phase 8 client runtime will fetch a per-island WASM chunk and hydrate this subtree in place. View source to see the wrapper."),
        }),
        ctx.section().class("card").children(.{ wrapped }),
    });
    return components.shell.page(ctx, body);
}

fn renderRealtime(ctx: *verve.Context) !*verve.Node {
    return components.tracker.realtime.realtimePage(ctx);
}

fn renderAdminHome(ctx: *verve.Context) !*verve.Node {
    return components.admin.index.adminHome(ctx);
}

fn renderAdminAnalytics(ctx: *verve.Context) !*verve.Node {
    return components.admin.analytics.analyticsPage(ctx);
}

fn renderAdminSettings(ctx: *verve.Context) !*verve.Node {
    return components.admin.settings.settingsPage(ctx);
}

fn renderAdminJobs(ctx: *verve.Context) !*verve.Node {
    return components.admin.jobs.jobsPage(ctx);
}

fn renderAdminAudit(ctx: *verve.Context) !*verve.Node {
    return components.admin.audit.auditPage(ctx);
}

fn renderAdminUser(ctx: *verve.Context) !*verve.Node {
    return components.admin.users.userPage(ctx);
}

fn renderAppRedirect(ctx: *verve.Context) !*verve.Node {
    return ctx.redirect("/app/o/acme/projects");
}

fn renderOrgShell(ctx: *verve.Context) !*verve.Node {
    return tracker_org.orgShell(ctx, ctx.outlet());
}

fn renderProjectList(ctx: *verve.Context) !*verve.Node {
    return tracker_org.projectList(ctx);
}

fn renderProjectShell(ctx: *verve.Context) !*verve.Node {
    return tracker_project.projectShell(ctx, ctx.outlet());
}

fn renderBoard(ctx: *verve.Context) !*verve.Node {
    return tracker_board.boardPage(ctx);
}

fn renderIssues(ctx: *verve.Context) !*verve.Node {
    return tracker_issues.issuesList(ctx);
}

fn renderIssueDetail(ctx: *verve.Context) !*verve.Node {
    return tracker_issue.issueDetail(ctx);
}

fn renderTeam(ctx: *verve.Context) !*verve.Node {
    return tracker_team.teamPage(ctx);
}

fn renderHome(ctx: *verve.Context) !*verve.Node {
    return components.shell.page(ctx, try homeBody(ctx));
}

fn homeBody(ctx: *verve.Context) !*verve.Node {
    try ctx.setTitle("Verve Showcase — full-stack Zig");
    try ctx.metaTag(.{ .name = "description", .content = "Tour of every Verve framework capability in one app: blog, tracker, analytics, realtime." });

    const ui = components.ui;

    return ctx.div().children(.{
        ctx.div().class("hero").children(.{
            ctx.h1("Verve Showcase"),
            ctx.p().class("lead").text("Three sub-products composed in one Zig binary: a blog with i18n and RSS, a collaborative project tracker with realtime collaborators, and an admin dashboard with analytics. Click around — every URL is a real route hitting in-process data."),
            ctx.div().class("row").children(.{
                ctx.el("span").class("btn").children(.{ verve.link(ctx, "/blog", "Read the blog", .{ .prefetch_on_hover = true }) }),
                ctx.el("span").class("btn secondary").children(.{ verve.link(ctx, "/app", "Open the tracker", .{}) }),
                ctx.el("span").class("btn ghost").children(.{ verve.link(ctx, "/admin", "Admin dashboard", .{}) }),
            }),
        }),
        ctx.div().class("grid grid-3").children(.{
            ui.kpi(ctx, .{ .label = "Routes",      .value = "6",   .delta = "phase A · 25 total" }),
            ui.kpi(ctx, .{ .label = "Surfaces",    .value = "60",  .delta = "every public export" }),
            ui.kpi(ctx, .{ .label = "Examples",    .value = "8",   .delta = "this is the canonical demo" }),
        }),
        ctx.section().class("card").children(.{
            ctx.h2("What's here"),
            ctx.div().class("grid grid-2").children(.{
                feature(ctx, "Blog (/blog)",          "Path-param locales, head slot variety, Slot named children, hashed asset preload, RSS + sitemap fragments."),
                feature(ctx, "Tracker (/app)",        "3-level nested routes, multiple guards, Store cascade, ErrorBoundary, createAction with pending UI, WS + SSE on one page."),
                feature(ctx, "Admin (/admin)",        "ctx.fetch Resource, multi-Suspense, provide/use DI, NodeRef + nonced inline scripts, batch / untrack escape hatches."),
                feature(ctx, "i18n",                  "Cookie + query + Accept-Language fallback chain. EN / ES / FR catalogs."),
            }),
        }),
        ctx.div().class("alert info").children(.{
            ctx.strong("Dev mode tip"),
            ctx.span().text(" · run "),
            ctx.code("zig build --watch run -- --dev"),
            ctx.span().text(" and the browser refreshes on every rebuild."),
        }),
    }).build();
}

fn feature(ctx: *const verve.Context, title: []const u8, body: []const u8) *verve.Node {
    return ctx.div().class("card").children(.{
        ctx.h3(title),
        ctx.p().class("muted").text(body),
    });
}

fn renderBlogIndex(ctx: *verve.Context) !*verve.Node {
    return blog_list.blogIndex(ctx);
}

fn renderBlogCategory(ctx: *verve.Context) !*verve.Node {
    const slug = ctx.param("slug") orelse return ctx.redirect("/blog");
    return blog_list.blogCategory(ctx, slug);
}

fn renderBlogPost(ctx: *verve.Context) !*verve.Node {
    const lang = ctx.param("lang") orelse "en";
    const slug = ctx.param("slug") orelse return ctx.redirect("/blog");
    return blog_post.blogPost(ctx, lang, slug);
}

fn renderRss(ctx: *verve.Context) !*verve.Node {
    return blog_feed.rss(ctx);
}

fn renderSitemap(ctx: *verve.Context) !*verve.Node {
    return blog_feed.sitemap(ctx);
}
