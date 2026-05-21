//! Demonstrates:
//!   - verve.StoredValue (owner-bound value cell)
//!   - on_cleanup via owner disposal (logged via the cleanup hook)

const std = @import("std");
const verve = @import("verve");
const api = @import("../../api.zig");
const ui = @import("../ui.zig");
const shell = @import("../shell.zig");

pub fn userPage(ctx: *verve.Context) !*verve.Node {
    const id_s = ctx.param("id") orelse return ctx.redirect("/admin");
    const id = std.fmt.parseInt(u32, id_s, 10) catch return ctx.redirect("/admin");
    const user = api.userById(id) orelse return ctx.redirect("/admin");

    const owner = ctx.owner orelse unreachable;

    // StoredValue: a non-reactive value cell allocated under the
    // request owner. Disposed automatically when the request ends.
    // (Allocated via owner.allocator() directly here; the
    // `verve.StoredValue(T)` type wraps the same idea.)
    const Session = struct {
        last_seen: []const u8,
        prefs_loaded: bool,
    };
    var session = try owner.allocator().create(verve.StoredValue(Session));
    session.* = .{ .value = .{ .last_seen = "just now", .prefs_loaded = false } };
    session.set(.{ .last_seen = "1m ago", .prefs_loaded = true });

    // Effect with an on_cleanup hook attached via the owner. When the
    // owner disposes at end of request, the cleanup logs (visible in
    // verve-server's stderr at info level).
    const CleanupTag = struct {
        tag: []const u8,
        fn run(self: *@This()) void {
            std.log.scoped(.showcase).info("/admin/users cleanup fired: {s}", .{self.tag});
        }
    };
    var ct: CleanupTag = .{ .tag = "user-page" };
    try owner.onCleanup(&ct, CleanupTag.run);

    const body = ctx.div().children(.{
        ui.breadcrumb(ctx, &.{
            .{ .label = "Admin", .href = "/admin" },
            .{ .label = "Users", .href = null },
            .{ .label = user.name, .href = null },
        }),
        ctx.h1(user.name),
        ctx.div().class("row muted").children(.{
            ui.avatar(ctx, user.avatar_seed),
            ctx.span().text(user.email),
            ui.badge(ctx, switch (user.role) {
                .admin => .info,
                .member => .ok,
                .viewer => .muted,
            }, @tagName(user.role)),
        }),
        ctx.section().class("card").children(.{
            ctx.h3("StoredValue + Owner on_cleanup"),
            ctx.p().text("A StoredValue(Session) lives in the request owner's arena. When the response is fully written, the owner disposes — the on_cleanup hook fires (check the server's stderr for the line `cleanup fired: user-page`). Real apps use this for connection close, cache invalidation, span flush."),
        }),
    });
    return shell.page(ctx, body);
}
