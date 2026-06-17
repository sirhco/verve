//! mission-control page components.

const std = @import("std");
const verve = @import("verve");

/// Hero page: h1 title + FarmScene 3D canvas.
pub fn index(ctx: *const verve.Context) !*verve.Node {
    try ctx.setTitle("Mission Control — Wind Farm");

    const canvas = ctx.el("canvas")
        .attr("data-ref", "farmscene-canvas")
        .attr("width", "960")
        .attr("height", "540")
        .attr("style", "width:100%;max-width:960px;aspect-ratio:16/9;display:block;background:#121420;border-radius:8px;touch-action:none;")
        .attr("z-on-pointerdown", "farmscene_pointerdown")
        .attr("z-on-pointermove", "farmscene_pointermove")
        .attr("z-on-pointerup", "farmscene_pointerup")
        .attr("z-on-wheel", "farmscene_wheel");

    const inner = ctx.main_().class("mc-main").children(.{
        ctx.h1("Mission Control"),
        ctx.p().class("hint").text("Wind farm — drag to orbit, scroll to zoom."),
        canvas,
    });

    return verve.island(ctx, .{ .name = "FarmScene" }, inner);
}

pub fn page(ctx: *const verve.Context, body: *verve.Node) !*verve.Node {
    return ctx.el("html").children(.{
        ctx.el("head").children(.{
            ctx.meta("charset", "utf-8"),
            ctx.title("Mission Control"),
            ctx.style(
                \\*{box-sizing:border-box}
                \\body{font:16px/1.6 system-ui;margin:0;background:#080c10;color:#e0e8f0}
                \\.mc-main{max-width:80rem;margin:0 auto;padding:1.5rem}
                \\h1{margin-top:0;font-size:1.75rem;letter-spacing:.03em;color:#7ec8e3}
                \\.hint{color:#607080;font-size:.9em;margin-bottom:1rem}
            ),
        }),
        ctx.el("body").children(.{
            body,
            ctx.script("/verve.js"),
        }),
    }).build();
}

pub fn notFound(ctx: *const verve.Context, path: []const u8) !*verve.Node {
    return ctx.main_().children(.{
        ctx.h1("404 — Not Found"),
        ctx.p().children(.{ ctx.span().text("No route for "), ctx.code(path) }),
        ctx.p().children(.{ctx.a("/", "← Home")}),
    }).build();
}

pub fn errorPage(
    ctx: *const verve.Context,
    status_code: u16,
    status_text: []const u8,
    message: []const u8,
) !*verve.Node {
    return ctx.main_().children(.{
        ctx.el("h1").textFmt("{d} — {s}", .{ status_code, status_text }),
        ctx.p().text(message),
        ctx.p().children(.{ctx.a("/", "← Home")}),
    }).build();
}
