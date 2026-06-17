//! mission-control page components.

const std = @import("std");
const verve = @import("verve");
const sim = @import("sim.zig");

/// SSR power-bar placeholder showing current power as a width indicator.
/// The client island updates `data-ref="dash-power-fill"` live.
fn dashChartSsr(ctx: *const verve.Context, power_kw: f32) *verve.Node {
    const pct: f32 = @min(power_kw / 5000.0 * 100.0, 100.0);
    const pct_str = std.fmt.allocPrint(ctx.alloc(), "{d:.1}%", .{pct}) catch "0%";
    const fill_style = std.fmt.allocPrint(
        ctx.alloc(),
        "height:100%;width:{s};background:linear-gradient(90deg,#2563eb,#7c3aed);border-radius:3px;transition:width .4s",
        .{pct_str},
    ) catch "height:100%;width:0%;background:#2563eb";
    return ctx.div().class("mc-chart-bar").children(.{
        ctx.div().attr("data-ref", "dash-power-fill").attr("style", fill_style),
    });
}

/// Hero page: h1 title + FarmScene 3D canvas + Dashboard telemetry island.
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

    const scene_inner = ctx.div().children(.{
        ctx.h1("Mission Control"),
        ctx.p().class("hint").text("Wind farm — drag to orbit, scroll to zoom."),
        canvas,
    });
    const scene_island = verve.island(ctx, .{ .name = "FarmScene" }, scene_inner);

    // SSR placeholder for the Dashboard island — initial values from tick 0.
    const t0 = sim.sample(0, 0);
    const dash_inner = ctx.section().class("mc-dashboard").children(.{
        ctx.h2("Turbine 0 — Live Telemetry"),
        ctx.div().class("mc-dash-row").children(.{
            ctx.div().class("mc-stat").children(.{
                ctx.span().class("mc-stat-label").text("Power"),
                ctx.span().class("mc-stat-value").bind("power_kw"),
                ctx.span().class("mc-stat-unit").text("kW"),
            }),
            ctx.div().class("mc-stat").children(.{
                ctx.span().class("mc-stat-label").text("RPM"),
                ctx.span().class("mc-stat-value").bind("rpm"),
            }),
            ctx.div().class("mc-stat").children(.{
                ctx.span().class("mc-stat-label").text("Wind"),
                ctx.span().class("mc-stat-value").bind("wind_ms"),
                ctx.span().class("mc-stat-unit").text("m/s"),
            }),
        }),
        ctx.p().class("mc-hint-live").children(.{
            ctx.span().text("Live via SSE "),
            ctx.code("/push?channel=metrics"),
        }),
        // SSR chart placeholder: power bar from sim snapshot at tick 0.
        dashChartSsr(ctx, t0.power_kw),
    });

    const dash_island = verve.island(ctx, .{ .name = "Dashboard" }, dash_inner);

    return ctx.main_().class("mc-main").children(.{
        scene_island,
        dash_island,
    });
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
                \\h2{font-size:1.1rem;color:#7ec8e3;margin:1.5rem 0 .75rem}
                \\.hint{color:#607080;font-size:.9em;margin-bottom:1rem}
                \\.mc-dashboard{background:#0d1117;border:1px solid #1e2a38;border-radius:8px;padding:1.25rem;margin-top:1.5rem}
                \\.mc-dash-row{display:flex;gap:2rem;flex-wrap:wrap;margin-bottom:1rem}
                \\.mc-stat{display:flex;flex-direction:column;min-width:7rem}
                \\.mc-stat-label{font-size:.75rem;text-transform:uppercase;letter-spacing:.06em;color:#607080}
                \\.mc-stat-value{font-size:1.5rem;font-weight:600;font-variant-numeric:tabular-nums;color:#e0e8f0}
                \\.mc-stat-unit{font-size:.8rem;color:#607080}
                \\.mc-hint-live{font-size:.8rem;color:#607080;margin:.5rem 0}
                \\code{background:#121c28;border:1px solid #1e2a38;border-radius:3px;padding:.1rem .3rem;font-size:.8em}
                \\.mc-chart-bar{height:10px;background:#1a2535;border-radius:4px;overflow:hidden;margin-top:.5rem}
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
