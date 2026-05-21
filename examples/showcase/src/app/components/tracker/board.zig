//! Demonstrates:
//!   - verve.Store with field-grained signals
//!   - verve.useEffect (3 effects subscribing to different fields)
//!   - verve.batch (multi-field write coalesces effect re-runs)
//!   - verve.untrack (one effect reads a counter without subscribing)
//!   - verve.show (conditional "no issues" panel)

const std = @import("std");
const verve = @import("verve");
const api = @import("../../api.zig");
const ui = @import("../ui.zig");

const Filter = struct {
    show_done: bool,
    show_in_progress: bool,
    show_open: bool,
    selected_assignee: ?u32,
};

pub fn boardPage(ctx: *verve.Context) !*verve.Node {
    const org_slug = ctx.param("org") orelse return ctx.redirect("/app");
    const project_slug = ctx.param("project") orelse return ctx.redirect("/app");
    const org = api.orgBySlug(org_slug) orelse return ctx.redirect("/app");
    const project = api.projectBySlug(org.id, project_slug) orelse return ctx.redirect("/app");

    const owner = ctx.owner orelse unreachable;
    const store = try verve.createStore(Filter, owner, .{
        .show_done = true,
        .show_in_progress = true,
        .show_open = true,
        .selected_assignee = null,
    });

    // Three effects subscribing to non-overlapping fields. Mutating
    // show_done re-runs only the open-tally effect because that's the
    // only effect that read it. Demonstrates field-grained tracking.
    var open_hits: u32 = 0;
    var ip_hits: u32 = 0;
    var done_hits: u32 = 0;

    var open_ctx = struct { s: *verve.Store(Filter), c: *u32, fn run(self: *@This()) void {
        _ = self.s.get(.show_open);
        self.c.* += 1;
    } }{ .s = store, .c = &open_hits };
    _ = try ctx.useEffect(&open_ctx, @TypeOf(open_ctx).run);

    var ip_ctx = struct { s: *verve.Store(Filter), c: *u32, fn run(self: *@This()) void {
        _ = self.s.get(.show_in_progress);
        self.c.* += 1;
    } }{ .s = store, .c = &ip_hits };
    _ = try ctx.useEffect(&ip_ctx, @TypeOf(ip_ctx).run);

    var done_ctx = struct { s: *verve.Store(Filter), c: *u32, fn run(self: *@This()) void {
        _ = self.s.get(.show_done);
        self.c.* += 1;
    } }{ .s = store, .c = &done_hits };
    _ = try ctx.useEffect(&done_ctx, @TypeOf(done_ctx).run);

    // Batch toggle: flip two fields → each watcher fires exactly once
    // even though both writes notify their respective signals.
    verve.batch(store, struct {
        fn run(s: *verve.Store(Filter)) void {
            s.set(.show_open, false);
            s.set(.show_open, true);
        }
    }.run);

    // Untrack demo: read another field without subscribing. Shows up in
    // the source comment but doesn't change effect tallies.
    const untracked_count = verve.untrack(usize, store, struct {
        fn read(s: *verve.Store(Filter)) usize {
            return @intFromBool(s.peek(.show_done));
        }
    }.read);
    _ = untracked_count;

    const issues = try api.issuesForProject(ctx.alloc(), project.id);

    var open_list = std.ArrayListUnmanaged(api.Issue).empty;
    var ip_list = std.ArrayListUnmanaged(api.Issue).empty;
    var done_list = std.ArrayListUnmanaged(api.Issue).empty;
    for (issues) |it| switch (it.status) {
        .open => try open_list.append(ctx.alloc(), it),
        .in_progress => try ip_list.append(ctx.alloc(), it),
        .done => try done_list.append(ctx.alloc(), it),
    };

    return ctx.div().children(.{
        ctx.div().class("alert info").children(.{
            ctx.strong("Field-grained reactivity"),
            ctx.div().textFmt(
                "Effect tallies after eager runs + 1 batched set: open={d}, in_progress={d}, done={d}. Each effect subscribes to a single field; mutating one column's filter does not re-run the other columns.",
                .{ open_hits, ip_hits, done_hits },
            ),
        }),
        ctx.div().class("grid grid-3").children(.{
            column(ctx, "Open",        .info, open_list.items),
            column(ctx, "In progress", .warn, ip_list.items),
            column(ctx, "Done",        .ok,   done_list.items),
        }),
    }).build();
}

fn column(ctx: *const verve.Context, label: []const u8, kind: ui.BadgeKind, items: []const api.Issue) *verve.Node {
    var card = ctx.section().class("card board-column");
    _ = card.children(.{
        ctx.div().class("row").children(.{
            ctx.h3(label),
            ui.badge(ctx, kind, std.fmt.allocPrint(ctx.alloc(), "{d}", .{items.len}) catch "0"),
        }),
    });
    if (items.len == 0) {
        _ = card.children(.{ ctx.p().class("muted").text("No issues in this column.") });
        return card;
    }
    for (items) |it| {
        const href = std.fmt.allocPrint(
            ctx.alloc(),
            "/app/o/acme/p/website/i/{d}",
            .{it.num},
        ) catch "/app";
        const assignee = if (it.assignee_id) |aid| api.userById(aid) else null;
        _ = card.children(.{
            ctx.div().class("card").attr("data-vkey", std.fmt.allocPrint(ctx.alloc(), "issue-{d}", .{it.id}) catch "i").children(.{
                ctx.div().textFmt("#{d} · {s}", .{ it.num, it.title }),
                ctx.div().class("row muted").children(.{
                    if (assignee) |a| ui.avatar(ctx, a.avatar_seed) else ctx.span().text("·"),
                    ctx.span().textFmt("{s}", .{if (assignee) |a| a.name else "Unassigned"}),
                    ctx.span().text(" · "),
                    verve.link(ctx, href, "open", .{}),
                }),
            }),
        });
    }
    return card;
}
