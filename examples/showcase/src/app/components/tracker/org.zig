//! Demonstrates:
//!   - verve.Route.layout (nested route — level 1 of 3)
//!   - ctx.outlet (slot for nested children)
//!   - verve.provide / verve.use (CurrentUser injected into the subtree)
//!   - ui.breadcrumb (auto-built from path params)

const std = @import("std");
const verve = @import("verve");
const api = @import("../../api.zig");
const ui = @import("../ui.zig");
const shell = @import("../shell.zig");

/// Current-user context. Phase 2 DI value. Children read it via
/// `ctx.use(CurrentUser).?.role`.
pub const CurrentUser = struct {
    id: u32,
    name: []const u8,
    role: api.Role,
};

pub fn orgShell(ctx: *verve.Context, outlet: *verve.Node) !*verve.Node {
    const slug = ctx.param("org") orelse return ctx.redirect("/app/o/acme");
    const org = api.orgBySlug(slug) orelse return ctx.redirect("/app/o/acme");

    // Provide the current user to every descendant via DI.
    const user = api.currentUser(ctx);
    try ctx.provide(CurrentUser, .{ .id = user.id, .name = user.name, .role = user.role });

    try ctx.setTitle(try std.fmt.allocPrint(ctx.alloc(), "{s} · Tracker", .{org.name}));
    try ctx.metaTag(.{ .name = "description", .content = "Verve project tracker — collaborative issues and projects." });

    const projects = try api.projectsForOrg(ctx.alloc(), org.id);

    const body = ctx.div().class("tracker-shell").children(.{
        ui.breadcrumb(ctx, &.{
            .{ .label = "Tracker", .href = "/app" },
            .{ .label = org.name, .href = null },
        }),
        ctx.div().class("row").children(.{
            ctx.h1(org.name),
            ui.badge(ctx, .info, user.email),
            ui.badge(ctx, .muted, @tagName(user.role)),
        }),
        orgNav(ctx, org, projects),
        ctx.section().children(.{ outlet }),
    });
    return shell.page(ctx, body);
}

fn orgNav(ctx: *const verve.Context, org: api.Org, projects: []const api.Project) *verve.Node {
    var nav = ctx.nav().class("tag-row").attr("aria-label", "Org navigation");
    _ = nav.children(.{ orgLink(ctx, "/app/o", org.slug, "projects", "Projects") });
    _ = nav.children(.{ orgLink(ctx, "/app/o", org.slug, "realtime", "Realtime") });
    for (projects) |p| {
        const href = std.fmt.allocPrint(ctx.alloc(), "/app/o/{s}/p/{s}", .{ org.slug, p.slug }) catch "/app";
        _ = nav.children(.{ verve.link(ctx, href, p.name, .{ .prefetch_on_hover = true }).class("badge muted") });
    }
    return nav;
}

fn orgLink(ctx: *const verve.Context, prefix: []const u8, org_slug: []const u8, segment: []const u8, label: []const u8) *verve.Node {
    const href = std.fmt.allocPrint(ctx.alloc(), "{s}/{s}/{s}", .{ prefix, org_slug, segment }) catch "/app";
    var n = verve.link(ctx, href, label, .{ .prefetch_on_hover = true });
    _ = n.class("badge info");
    return n;
}

pub fn projectList(ctx: *verve.Context) !*verve.Node {
    const slug = ctx.param("org") orelse return ctx.redirect("/app/o/acme");
    const org = api.orgBySlug(slug) orelse return ctx.redirect("/app/o/acme");
    const projects = try api.projectsForOrg(ctx.alloc(), org.id);

    var grid = ctx.div().class("grid grid-2");
    for (projects) |p| {
        const href = std.fmt.allocPrint(ctx.alloc(), "/app/o/{s}/p/{s}/board", .{ org.slug, p.slug }) catch "/app";
        _ = grid.children(.{
            ctx.section().class("card hoverable").attr("data-vkey", p.slug).children(.{
                ctx.div().class("row").children(.{
                    ctx.h2(p.name),
                    ui.badge(
                        ctx,
                        if (p.status == .active) .ok else .muted,
                        @tagName(p.status),
                    ),
                }),
                ctx.p().class("muted").textFmt("Slug: /{s}", .{p.slug}),
                ctx.p().children(.{ verve.link(ctx, href, "Open board →", .{}) }),
            }),
        });
    }
    return grid;
}
