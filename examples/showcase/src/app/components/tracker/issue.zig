//! Demonstrates:
//!   - verve.Route.init (nested level 3 of 3)
//!   - verve.suspense (3 independent boundaries on one page)
//!   - verve.Resource via createResource for each suspended panel
//!   - verve.createAction (pending / value / version signals)
//!   - verve.createErrorBoundary (captureError + reset display)
//!   - verve.actionForm + CSRF for the comment submit
//!   - verve.forEach with data-vkey for the comment list

const std = @import("std");
const verve = @import("verve");
const api = @import("../../api.zig");
const ui = @import("../ui.zig");

pub fn issueDetail(ctx: *verve.Context) !*verve.Node {
    const org_slug = ctx.param("org") orelse return ctx.redirect("/app");
    const project_slug = ctx.param("project") orelse return ctx.redirect("/app");
    const num_s = ctx.param("num") orelse return ctx.redirect("/app");
    const num = std.fmt.parseInt(u32, num_s, 10) catch return ctx.redirect("/app");

    const org = api.orgBySlug(org_slug) orelse return ctx.redirect("/app");
    const project = api.projectBySlug(org.id, project_slug) orelse return ctx.redirect("/app");
    const issue = api.issueByNum(ctx.alloc(), project.id, num) orelse return ctx.redirect(
        try std.fmt.allocPrint(ctx.alloc(), "/app/o/{s}/p/{s}/issues", .{ org.slug, project.slug }),
    );

    const owner = ctx.owner orelse unreachable;

    // Three suspense boundaries with independent fallbacks. Two of the
    // Resources resolve synchronously (ready); the third intentionally
    // errors, exercising the err arm.
    const CommentsFetcher = struct {
        issue_id: u32,
        arena: std.mem.Allocator,
        fn run(self: *@This()) anyerror![]const api.Comment {
            return try api.commentsForIssue(self.arena, self.issue_id);
        }
    };
    var cf: CommentsFetcher = .{ .issue_id = issue.id, .arena = ctx.alloc() };
    const comments_res = try verve.createResource([]const api.Comment, ctx.io.?, owner, &cf, CommentsFetcher.run);

    const ActivityFetcher = struct {
        arena: std.mem.Allocator,
        fn run(self: *@This()) anyerror![]const api.Activity {
            return try api.recentActivity(self.arena, 5);
        }
    };
    var af: ActivityFetcher = .{ .arena = ctx.alloc() };
    const activity_res = try verve.createResource([]const api.Activity, ctx.io.?, owner, &af, ActivityFetcher.run);

    // ErrorBoundary demo: capture an error from a synthetic widget; a
    // real app would call eb.reset() from a "Try again" button.
    const eb = try verve.createErrorBoundary(owner);
    eb.captureError(error.RelatedIssuesLookupFailed);

    // Action wrapper for the comment submit. Server-side we just expose
    // the pending/value/version signals for inspection; client-side
    // hydration (Phase 8) will flip them around an HTTP request.
    const PostArgs = struct { issue_id: u32, body: []const u8 };
    const PostComment = struct {
        fn run(_: *@This(), args: PostArgs) anyerror!void {
            try api.Actions.addComment(.{ .issue_id = args.issue_id, .body = args.body });
        }
    };
    var pc: PostComment = .{};
    const comment_action = try verve.createAction(
        PostArgs,
        void,
        owner,
        &pc,
        PostComment.run,
    );
    _ = comment_action; // referenced via the form below for parity

    const assignee = if (issue.assignee_id) |aid| api.userById(aid) else null;

    return ctx.div().children(.{
        ui.breadcrumb(ctx, &.{
            .{ .label = "Tracker", .href = "/app" },
            .{ .label = org.name, .href = std.fmt.allocPrint(ctx.alloc(), "/app/o/{s}/projects", .{org.slug}) catch "/app" },
            .{ .label = project.name, .href = std.fmt.allocPrint(ctx.alloc(), "/app/o/{s}/p/{s}/board", .{ org.slug, project.slug }) catch "/app" },
            .{ .label = std.fmt.allocPrint(ctx.alloc(), "#{d}", .{issue.num}) catch "#?", .href = null },
        }),
        ctx.div().class("row").children(.{
            ctx.h1(issue.title),
            ui.badge(ctx, switch (issue.status) {
                .open => .info,
                .in_progress => .warn,
                .done => .ok,
            }, @tagName(issue.status)),
        }),
        ctx.div().class("row muted").children(.{
            if (assignee) |a| ui.avatar(ctx, a.avatar_seed) else ctx.span().text("·"),
            ctx.span().text(if (assignee) |a| a.name else "Unassigned"),
            ctx.span().text(" · opened "),
            ctx.span().text(issue.created_at),
        }),
        ctx.section().class("card").children(.{
            ctx.h2("Description"),
            ctx.p().text(issue.body),
        }),

        ctx.div().class("grid grid-2").children(.{
            commentsPanel(ctx, comments_res),
            activityPanel(ctx, activity_res),
        }),

        relatedPanel(ctx, eb),

        commentForm(ctx, issue),
    }).build();
}

fn commentsPanel(ctx: *const verve.Context, res: *verve.Resource([]const api.Comment)) *verve.Node {
    const InnerCtx = struct {
        ctx: *const verve.Context,
        res: *verve.Resource([]const api.Comment),
        fn render(self: *@This()) anyerror!*verve.Node {
            return switch (self.res.state.get()) {
                .ready => |list| commentsList(self.ctx, list),
                .err => |e| self.ctx.p().textFmt("Failed: {s}", .{@errorName(e)}),
                .loading => self.ctx.p().text("(unreachable on sync fetcher)"),
            };
        }
    };
    var ic: InnerCtx = .{ .ctx = ctx, .res = res };
    const fallback = ctx.div().class("empty").text("Loading comments…");
    return ctx.section().class("card").children(.{
        ctx.h3("Comments"),
        verve.suspense(ctx, .{ .fallback = fallback }, &ic, InnerCtx.render) catch fallback,
    });
}

fn commentsList(ctx: *const verve.Context, items: []const api.Comment) *verve.Node {
    if (items.len == 0) return ctx.p().class("muted").text("No comments yet — be first.");
    var list = ctx.div();
    for (items) |c| {
        const author = api.userById(c.author_id) orelse api.users[0];
        const key = std.fmt.allocPrint(ctx.alloc(), "comment-{d}", .{c.id}) catch "c";
        _ = list.children(.{
            ctx.div().class("card").attr("data-vkey", key).children(.{
                ctx.div().class("row").children(.{
                    ui.avatar(ctx, author.avatar_seed),
                    ctx.strong(author.name),
                    ctx.span().class("muted").text(c.created_at),
                }),
                ctx.p().text(c.body),
            }),
        });
    }
    return list;
}

fn activityPanel(ctx: *const verve.Context, res: *verve.Resource([]const api.Activity)) *verve.Node {
    const InnerCtx = struct {
        ctx: *const verve.Context,
        res: *verve.Resource([]const api.Activity),
        fn render(self: *@This()) anyerror!*verve.Node {
            return switch (self.res.state.get()) {
                .ready => |list| activityList(self.ctx, list),
                .err => |e| self.ctx.p().textFmt("Failed: {s}", .{@errorName(e)}),
                .loading => self.ctx.p().text("(loading)"),
            };
        }
    };
    var ic: InnerCtx = .{ .ctx = ctx, .res = res };
    const fallback = ctx.div().class("empty").text("Loading activity…");
    return ctx.section().class("card").children(.{
        ctx.h3("Recent activity"),
        verve.suspense(ctx, .{ .fallback = fallback }, &ic, InnerCtx.render) catch fallback,
    });
}

fn activityList(ctx: *const verve.Context, items: []const api.Activity) *verve.Node {
    if (items.len == 0) return ctx.p().class("muted").text("No activity yet.");
    var list = ctx.div();
    for (items) |a| {
        const actor = api.userById(a.actor_id) orelse api.users[0];
        _ = list.children(.{
            ctx.div().class("row muted").children(.{
                ui.avatar(ctx, actor.avatar_seed),
                ctx.span().textFmt("{s} · {s}", .{ actor.name, a.kind }),
                ctx.span().textFmt(" — {s}", .{a.body}),
            }),
        });
    }
    return list;
}

fn relatedPanel(ctx: *const verve.Context, eb: *verve.ErrorBoundary) *verve.Node {
    return ctx.section().class("card").children(.{
        ctx.h3("Related issues"),
        if (eb.captured()) |err|
            ctx.div().class("alert err").children(.{
                ctx.strong("Couldn't load related issues"),
                ctx.div().textFmt("Error: {s}. A real app would expose a 'Try again' button that calls eb.reset() to clear the captured signal — sibling cards keep rendering regardless.", .{@errorName(err)}),
            })
        else
            ctx.p().class("muted").text("(no related)"),
    });
}

fn commentForm(ctx: *const verve.Context, issue: api.Issue) *verve.Node {
    return ctx.section().class("card").children(.{
        ctx.h3("Add a comment"),
        ctx.actionForm(.{ .post = "/api/addComment" }).children(.{
            ctx.input().type_("hidden").name("issue_id").attrFmt("value", "{d}", .{issue.id}),
            ctx.textarea().name("body").class("textarea").attr("placeholder", "What's the latest?"),
            ctx.div().class("row").children(.{
                ctx.button("Post comment").type_("submit").class("btn"),
                ctx.span().class("muted").text("CSRF auto-injected via ctx.actionForm"),
            }),
        }),
    });
}
