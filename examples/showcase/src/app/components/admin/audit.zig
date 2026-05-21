//! Demonstrates:
//!   - SSE-driven counter via z-bind (existing /events stream)
//!   - Activity log rendered from in-memory state

const std = @import("std");
const verve = @import("verve");
const api = @import("../../api.zig");
const ui = @import("../ui.zig");
const shell = @import("../shell.zig");

pub fn auditPage(ctx: *verve.Context) !*verve.Node {
    const items = try api.recentActivity(ctx.alloc(), 20);

    var list = ctx.div();
    for (items) |a| {
        const actor = api.userById(a.actor_id) orelse api.users[0];
        _ = list.children(.{
            ctx.div().class("card").attr("data-vkey", std.fmt.allocPrint(ctx.alloc(), "a-{d}", .{a.id}) catch "a").children(.{
                ctx.div().class("row").children(.{
                    ui.avatar(ctx, actor.avatar_seed),
                    ctx.strong(actor.name),
                    ui.badge(ctx, .info, a.kind),
                    ctx.span().class("muted").text(a.created_at),
                }),
                ctx.p().textFmt("{s} (target {s} #{d})", .{ a.body, a.target_kind, a.target_id }),
            }),
        });
    }

    const body = ctx.div().children(.{
        ctx.div().class("hero").children(.{
            ctx.h1("Audit log"),
            ctx.p().class("lead").text("Live activity. The counter below subscribes to /events; every server-side mutation ticks it."),
        }),
        ctx.section().class("card").children(.{
            ctx.h3("Live tick"),
            ctx.div().class("kpi").children(.{
                ctx.span().class("kpi-label").text("server tick"),
                ctx.span().class("kpi-value").bind("count").textInt(api.last_count.load(.monotonic)),
            }),
        }),
        ctx.h2("Recent events"),
        list,
    });
    return shell.page(ctx, body);
}
