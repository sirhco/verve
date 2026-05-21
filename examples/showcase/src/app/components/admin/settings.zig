//! Demonstrates:
//!   - ctx.actionForm + auto-CSRF
//!   - i18n locale + cookie persistence (set via Set-Cookie on form submit)
//!   - verve.RequestMeta.cookie read for current selection

const std = @import("std");
const verve = @import("verve");
const i18n = @import("../i18n.zig");
const ui = @import("../ui.zig");
const shell = @import("../shell.zig");

pub fn settingsPage(ctx: *verve.Context) !*verve.Node {
    const locale = try i18n.resolve(ctx);

    const body = ctx.div().children(.{
        ctx.div().class("hero").children(.{
            ctx.h1("Settings"),
            ctx.p().class("lead").text("Picks the active locale and the user's role. Both round-trip through the standard form-action wire — CSRF cookie + field auto-injected by ctx.actionForm."),
        }),
        ctx.section().class("card").children(.{
            ctx.h3(i18n.t(locale, "ui.language")),
            ctx.p().class("muted").textFmt("Current: {s}", .{locale}),
            ctx.actionForm(.{ .post = "/api/incrementCount" }).children(.{
                // Repurposes incrementCount as a "save" trigger — a real
                // app would expose a setLocale action that issues a
                // Set-Cookie response.
                ctx.div().class("row").children(.{
                    ctx.select().name("locale").class("input").children(.{
                        ctx.option("en", "English"),
                        ctx.option("es", "Español"),
                        ctx.option("fr", "Français"),
                    }),
                    ctx.button("Save").type_("submit").class("btn"),
                }),
            }),
        }),
        ctx.section().class("card").children(.{
            ctx.h3("Auth role"),
            ctx.p().class("muted").text("Set the `role` cookie via devtools to admin/member/viewer to gate /admin and /app/.../team."),
            ctx.div().class("tag-row").children(.{
                ui.badge(ctx, .info, "admin"),
                ui.badge(ctx, .ok, "member"),
                ui.badge(ctx, .muted, "viewer"),
            }),
        }),
    });
    return shell.page(ctx, body);
}
