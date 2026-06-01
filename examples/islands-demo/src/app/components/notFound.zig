//! Framework integration: components.notFound, components.errorPage.

const verve = @import("verve");

pub fn notFound(ctx: *const verve.Context, path: []const u8) !*verve.Node {
    return ctx.main_().class("wrap").children(.{
        ctx.h1("404 — Not Found"),
        ctx.p().children(.{
            ctx.span().text("No route for "),
            ctx.code(path),
        }),
        ctx.p().children(.{ verve.link(ctx, "/", "← Home", .{}) }),
    }).build();
}

pub fn errorPage(
    ctx: *const verve.Context,
    status_code: u16,
    status_text: []const u8,
    message: []const u8,
) !*verve.Node {
    return ctx.main_().class("wrap").children(.{
        ctx.el("h1").textFmt("{d} — {s}", .{ status_code, status_text }),
        ctx.p().text(message),
        ctx.p().children(.{ verve.link(ctx, "/", "← Home", .{}) }),
    }).build();
}
