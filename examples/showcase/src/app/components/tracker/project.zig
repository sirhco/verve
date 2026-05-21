//! Demonstrates:
//!   - verve.Route.layout (nested route — level 2 of 3)
//!   - verve.use (reads CurrentUser provided by org shell)
//!   - ctx.outlet (passes through to issue routes)
//!   - ui.breadcrumb with three levels

const std = @import("std");
const verve = @import("verve");
const api = @import("../../api.zig");
const ui = @import("../ui.zig");
const shell = @import("../shell.zig");
const org_mod = @import("org.zig");

pub fn projectShell(ctx: *verve.Context, outlet: *verve.Node) !*verve.Node {
    const org_slug = ctx.param("org") orelse return ctx.redirect("/app");
    const project_slug = ctx.param("project") orelse return ctx.redirect("/app");
    const org = api.orgBySlug(org_slug) orelse return ctx.redirect("/app");
    const project = api.projectBySlug(org.id, project_slug) orelse return ctx.redirect("/app");

    try ctx.setTitle(try std.fmt.allocPrint(ctx.alloc(), "{s} · {s}", .{ project.name, org.name }));

    // Read the current user from the parent's DI scope. Demonstrates
    // ctx.use returning the provided value walking the owner chain.
    const user_opt = ctx.use(org_mod.CurrentUser);

    const board_href = std.fmt.allocPrint(ctx.alloc(), "/app/o/{s}/p/{s}/board", .{ org.slug, project.slug }) catch "/app";
    const issues_href = std.fmt.allocPrint(ctx.alloc(), "/app/o/{s}/p/{s}/issues", .{ org.slug, project.slug }) catch "/app";
    const team_href = std.fmt.allocPrint(ctx.alloc(), "/app/o/{s}/p/{s}/team", .{ org.slug, project.slug }) catch "/app";

    const body = ctx.div().class("project-shell").children(.{
        ui.breadcrumb(ctx, &.{
            .{ .label = "Tracker", .href = "/app" },
            .{
                .label = org.name,
                .href = std.fmt.allocPrint(ctx.alloc(), "/app/o/{s}/projects", .{org.slug}) catch "/app",
            },
            .{ .label = project.name, .href = null },
        }),
        ctx.div().class("row").children(.{
            ctx.h1(project.name),
            ui.badge(ctx, if (project.status == .active) .ok else .muted, @tagName(project.status)),
            if (user_opt) |u| ui.badge(ctx, .info, u.name) else ui.badge(ctx, .muted, "guest"),
        }),
        ctx.nav().class("tag-row").children(.{
            verve.link(ctx, board_href,  "Board",  .{ .prefetch_on_hover = true }).class("badge info"),
            verve.link(ctx, issues_href, "Issues", .{ .prefetch_on_hover = true }).class("badge info"),
            verve.link(ctx, team_href,   "Team",   .{}).class("badge muted"),
        }),
        ctx.section().children(.{ outlet }),
    });
    return shell.page(ctx, body);
}
