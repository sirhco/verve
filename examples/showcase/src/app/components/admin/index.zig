//! Demonstrates:
//!   - Route guard (.protect(api.adminGuard))
//!   - verve.RequestMeta.cookie reading the role cookie

const std = @import("std");
const verve = @import("verve");
const api = @import("../../api.zig");
const ui = @import("../ui.zig");
const shell = @import("../shell.zig");

pub fn adminHome(ctx: *verve.Context) !*verve.Node {
    const meta = ctx.request_meta orelse return ctx.redirect("/");
    const role = meta.cookie("role") orelse "(none)";

    const body = ctx.div().children(.{
        ctx.div().class("hero").children(.{
            ctx.h1("Admin"),
            ctx.p().class("lead").text("Role-gated area. The .protect(api.adminGuard) route guard checks the `role` cookie before invoking render."),
        }),
        ctx.div().class("alert info").children(.{
            ctx.strong("Authenticated as admin"),
            ctx.div().textFmt("Your `role` cookie says: \"{s}\". Try clearing the cookie — the next request redirects to /?reason=admin-only.", .{role}),
        }),
        ctx.div().class("grid grid-2").children(.{
            tile(ctx, "Analytics",  "Resource fetched via ctx.fetch + multi-Suspense fallback.", "/admin/analytics"),
            tile(ctx, "Settings",   "actionForm + i18n cookie persistence.",                    "/admin/settings"),
            tile(ctx, "Audit log",  "SSE-driven activity feed (live).",                          "/admin/audit"),
            tile(ctx, "Jobs",       "batch + untrack escape-hatch demos.",                       "/admin/jobs"),
            tile(ctx, "Users",      "StoredValue + useEffect cleanup pattern.",                  "/admin/users/1"),
        }),
    });
    return shell.page(ctx, body);
}

fn tile(ctx: *const verve.Context, title: []const u8, body: []const u8, href: []const u8) *verve.Node {
    return ctx.section().class("card hoverable").children(.{
        ctx.h3(title),
        ctx.p().class("muted").text(body),
        ctx.p().children(.{ verve.link(ctx, href, "Open →", .{}) }),
    });
}
