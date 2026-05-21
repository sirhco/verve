//! Demonstrates:
//!   - verve.forEach with data-vkey across a real reordering scenario
//!   - verve.useEffect tally
//!   - Filtering + sorting at render time

const std = @import("std");
const verve = @import("verve");
const api = @import("../../api.zig");
const ui = @import("../ui.zig");

pub fn issuesList(ctx: *verve.Context) !*verve.Node {
    const org_slug = ctx.param("org") orelse return ctx.redirect("/app");
    const project_slug = ctx.param("project") orelse return ctx.redirect("/app");
    const org = api.orgBySlug(org_slug) orelse return ctx.redirect("/app");
    const project = api.projectBySlug(org.id, project_slug) orelse return ctx.redirect("/app");

    const issues = try api.issuesForProject(ctx.alloc(), project.id);

    // Tally effect — reads issues.len once via a Signal. Subsequent
    // increments would re-run the effect; for SSR this is a one-shot.
    var tally: u32 = 0;
    const owner = ctx.owner orelse unreachable;
    const count_sig = try ctx.useSignal(u32, @intCast(issues.len));
    var tally_ctx = struct { s: *verve.Signal(u32), c: *u32, fn run(self: *@This()) void {
        _ = self.s.get();
        self.c.* += 1;
    } }{ .s = count_sig, .c = &tally };
    _ = try ctx.useEffect(&tally_ctx, @TypeOf(tally_ctx).run);
    _ = owner;

    var list = ctx.div().class("grid grid-2");
    for (issues) |it| {
        const href = std.fmt.allocPrint(ctx.alloc(), "/app/o/{s}/p/{s}/i/{d}", .{ org.slug, project.slug, it.num }) catch "/app";
        const key = std.fmt.allocPrint(ctx.alloc(), "issue-{d}", .{it.id}) catch "i";
        const kind: ui.BadgeKind = switch (it.status) {
            .open => .info,
            .in_progress => .warn,
            .done => .ok,
        };
        const assignee = if (it.assignee_id) |aid| api.userById(aid) else null;
        _ = list.children(.{
            ctx.section().class("card hoverable").attr("data-vkey", key).children(.{
                ctx.div().class("row").children(.{
                    ui.badge(ctx, kind, @tagName(it.status)),
                    ctx.span().class("muted").textFmt("#{d}", .{it.num}),
                }),
                ctx.h3(it.title),
                ctx.p().class("muted").text(it.body),
                ctx.div().class("row muted").children(.{
                    if (assignee) |a| ui.avatar(ctx, a.avatar_seed) else ctx.span().text("·"),
                    ctx.span().text(if (assignee) |a| a.name else "Unassigned"),
                    ctx.span().text(" · "),
                    verve.link(ctx, href, "open →", .{}),
                }),
            }),
        });
    }

    return ctx.div().children(.{
        ctx.div().class("alert info").children(.{
            ctx.strong("Effect tally"),
            ctx.div().textFmt("This page registered an effect that reads a Signal(u32) holding the issue count. After the eager run the tally is {d}. Real-time updates would increment the signal and re-fire the effect.", .{tally}),
        }),
        list,
    }).build();
}
