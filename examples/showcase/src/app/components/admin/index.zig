//! Demonstrates:
//!   - Route guard (.protect(api.adminGuard))
//!   - verve.RequestMeta.cookie reading the role cookie

const std = @import("std");
const verve = @import("verve");
const api = @import("../../api.zig");
const ui = @import("../ui.zig");
const shell = @import("../shell.zig");

pub fn adminHome(ctx: *verve.Context) !*verve.Node {
    const role = if (ctx.request_meta) |m| (m.cookie("role") orelse "") else "";
    const is_admin = std.mem.eql(u8, role, "admin");

    const body = ctx.div().children(.{
        ctx.div().class("hero").children(.{
            ctx.h1("Admin"),
            ctx.p().class("lead").text("Role-gated area. Sub-routes are wrapped in .protect(api.adminGuard); this index page stays accessible so unauthenticated visitors see what's behind the gate."),
        }),
        if (is_admin)
            ctx.div().class("alert info").children(.{
                ctx.strong("Authenticated as admin"),
                ctx.div().text("Your `role` cookie says: \"admin\". All admin sub-routes will render. Clear the cookie and any sub-route redirects with reason=admin-only."),
            })
        else
            authHint(ctx, role),
        ctx.div().class("grid grid-2").children(.{
            tile(ctx, "Analytics",  "Resource via ctx.fetch + multi-Suspense fallback.",   "/admin/analytics"),
            tile(ctx, "Settings",   "actionForm + i18n cookie persistence.",               "/admin/settings"),
            tile(ctx, "Audit log",  "SSE-driven activity feed (live).",                    "/admin/audit"),
            tile(ctx, "Jobs",       "batch + untrack escape-hatch demos.",                 "/admin/jobs"),
            tile(ctx, "Users",      "StoredValue + on_cleanup pattern.",                   "/admin/users/1"),
        }),
    });
    return shell.page(ctx, body);
}

fn authHint(ctx: *const verve.Context, current_role: []const u8) *verve.Node {
    const label = if (current_role.len == 0) "(none)" else current_role;
    return ctx.div().class("alert warn").children(.{
        ctx.strong("Not authenticated as admin"),
        ctx.div().textFmt(
            "Current `role` cookie: \"{s}\". The /admin sub-routes require role=admin. " ++
                "Set the cookie in devtools (Application → Cookies) and reload. " ++
                "Or run: document.cookie = 'role=admin; path=/'",
            .{label},
        ),
        ctx.div().class("muted").text("This index page is intentionally unguarded so the URL still works in browser devtools Sources tab even without the cookie."),
    });
}

fn tile(ctx: *const verve.Context, title: []const u8, body: []const u8, href: []const u8) *verve.Node {
    return ctx.section().class("card hoverable").children(.{
        ctx.h3(title),
        ctx.p().class("muted").text(body),
        ctx.p().children(.{ verve.link(ctx, href, "Open →", .{}) }),
    });
}
