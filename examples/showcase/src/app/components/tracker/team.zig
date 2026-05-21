//! Demonstrates:
//!   - Route guard (.protect(api.teamGuard)) — appears on routes.zig
//!   - verve.use to read CurrentUser provided by parent
//!   - Conditional UI by role

const std = @import("std");
const verve = @import("verve");
const api = @import("../../api.zig");
const ui = @import("../ui.zig");
const org_mod = @import("org.zig");

pub fn teamPage(ctx: *verve.Context) !*verve.Node {
    const user_opt = ctx.use(org_mod.CurrentUser);

    var grid = ctx.div().class("grid grid-3");
    for (api.users) |u| {
        const kind: ui.BadgeKind = switch (u.role) {
            .admin => .info,
            .member => .ok,
            .viewer => .muted,
        };
        _ = grid.children(.{
            ctx.section().class("card").children(.{
                ctx.div().class("row").children(.{
                    ui.avatar(ctx, u.avatar_seed),
                    ctx.strong(u.name),
                    ui.badge(ctx, kind, @tagName(u.role)),
                }),
                ctx.p().class("muted").text(u.email),
            }),
        });
    }

    return ctx.div().children(.{
        ctx.div().class("alert info").children(.{
            ctx.strong("Protected route"),
            ctx.div().text("This page is gated by a guard fn that requires ?token= in the URL. Without it, a Redirect short-circuits before render."),
        }),
        if (user_opt) |u|
            ctx.p().class("muted").textFmt("You're viewing as {s} ({s}).", .{ u.name, @tagName(u.role) })
        else
            ctx.p().class("muted").text("Anonymous (DI didn't surface a user)."),
        grid,
    }).build();
}
