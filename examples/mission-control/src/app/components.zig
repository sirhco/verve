//! mission-control page components.

const std = @import("std");
const verve = @import("verve");
const sim = @import("sim.zig");

/// Chart layout constants — must match the client island's coordinate math.
/// Plot area: x ∈ [48, 580], y ∈ [20, 160].  Power domain: [0, 5000 kW].
const CHART_W: f32 = 600;
const CHART_H: f32 = 200;
const PLOT_X0: f32 = 48;
const PLOT_X1: f32 = 580;
const PLOT_Y0: f32 = 160; // bottom (larger y = lower on screen)
const PLOT_Y1: f32 = 20; // top
const POWER_MAX: f32 = 5000;
const RING_LEN: usize = 60;

/// Map a power value to Y pixel in SVG coordinate space.
fn powerToY(power: f32) f32 {
    const frac = @max(0.0, @min(power / POWER_MAX, 1.0));
    return PLOT_Y0 - frac * (PLOT_Y0 - PLOT_Y1);
}

/// Append "NNN.N" to buf starting at pos, return new pos.
fn appendF1Ssr(buf: []u8, pos: usize, v: f32) usize {
    const s = std.fmt.bufPrint(buf[pos..], "{d:.1}", .{v}) catch return pos;
    return pos + s.len;
}

/// Append a single byte to buf at pos, return new pos.  Clamps on overflow.
fn appendCharSsr(buf: []u8, pos: usize, c: u8) usize {
    if (pos < buf.len) {
        buf[pos] = c;
        return pos + 1;
    }
    return pos; // buffer full — stop advancing
}

/// Write n coordinate pairs "x0,y0 x1,y1 …" for a flat power line into buf[pos..].
/// All samples share the same `power_kw` value (SSR initial state).
/// Returns the updated pos.
fn appendCoordsSsr(buf: []u8, pos_in: usize, power_kw: f32) usize {
    var pos = pos_in;
    const denom: f32 = @as(f32, @floatFromInt(RING_LEN - 1));
    for (0..RING_LEN) |i| {
        const fi: f32 = @floatFromInt(i);
        const x = PLOT_X0 + fi / denom * (PLOT_X1 - PLOT_X0);
        const y = powerToY(power_kw);
        if (i > 0) pos = appendCharSsr(buf, pos, ' ');
        pos = appendF1Ssr(buf, pos, x);
        pos = appendCharSsr(buf, pos, ',');
        pos = appendF1Ssr(buf, pos, y);
    }
    return pos;
}

/// SSR rolling line/area chart skeleton for turbine 0's power history.
/// Emits a static SVG whose `<polyline data-ref="dash-power-line">` and
/// `<polygon data-ref="dash-power-area">` are patched live by the Dashboard
/// client island via `verve.setRefAttr`.
fn dashChartSsr(ctx: *const verve.Context, power_kw: f32) *verve.Node {
    // Build initial 60-sample flat line at the current power level.
    var pts_buf: [RING_LEN * 16]u8 = undefined;
    const pts_pos = appendCoordsSsr(&pts_buf, 0, power_kw);
    const pts_str = pts_buf[0..pts_pos];

    // Area fill polygon: same curve + two baseline corners.
    var area_buf: [(RING_LEN + 2) * 16]u8 = undefined;
    var area_pos = appendCoordsSsr(&area_buf, 0, power_kw);
    // right-bottom corner
    area_pos = appendCharSsr(&area_buf, area_pos, ' ');
    area_pos = appendF1Ssr(&area_buf, area_pos, PLOT_X1);
    area_pos = appendCharSsr(&area_buf, area_pos, ',');
    area_pos = appendF1Ssr(&area_buf, area_pos, PLOT_Y0);
    // left-bottom corner
    area_pos = appendCharSsr(&area_buf, area_pos, ' ');
    area_pos = appendF1Ssr(&area_buf, area_pos, PLOT_X0);
    area_pos = appendCharSsr(&area_buf, area_pos, ',');
    area_pos = appendF1Ssr(&area_buf, area_pos, PLOT_Y0);
    const area_pts = area_buf[0..area_pos];

    const tick_vals = [_]f32{ 0, 1250, 2500, 3750, 5000 };

    const svg = ctx.el("svg")
        .attr("xmlns", "http://www.w3.org/2000/svg")
        .attr("viewBox", "0 0 600 200")
        .attr("width", "600")
        .attr("height", "200")
        .attr("style", "width:100%;max-width:600px;height:auto;display:block;overflow:visible;margin-top:.75rem");

    // Grid lines + Y-axis tick labels.
    for (tick_vals) |tv| {
        const y_px = powerToY(tv);
        var yb: [20]u8 = undefined;
        var xb0: [20]u8 = undefined;
        var xb1: [20]u8 = undefined;
        var lyb: [20]u8 = undefined;
        var lb: [10]u8 = undefined;
        const y_str = std.fmt.bufPrint(&yb, "{d:.1}", .{y_px}) catch "0";
        const x0_str = std.fmt.bufPrint(&xb0, "{d:.1}", .{PLOT_X0}) catch "48";
        const x1_str = std.fmt.bufPrint(&xb1, "{d:.1}", .{PLOT_X1}) catch "580";
        const ly_str = std.fmt.bufPrint(&lyb, "{d:.1}", .{y_px + 4}) catch "0";
        const lbl = if (tv >= 1000)
            std.fmt.bufPrint(&lb, "{d:.0}k", .{tv / 1000.0}) catch ""
        else
            std.fmt.bufPrint(&lb, "{d:.0}", .{tv}) catch "";
        _ = svg.children(.{
            ctx.el("line")
                .attr("x1", std.fmt.allocPrint(ctx.alloc(), "{s}", .{x0_str}) catch "48")
                .attr("y1", std.fmt.allocPrint(ctx.alloc(), "{s}", .{y_str}) catch "0")
                .attr("x2", std.fmt.allocPrint(ctx.alloc(), "{s}", .{x1_str}) catch "580")
                .attr("y2", std.fmt.allocPrint(ctx.alloc(), "{s}", .{y_str}) catch "0")
                .attr("stroke", "#1e2a38")
                .attr("stroke-width", "1"),
            ctx.el("text")
                .attr("x", "44")
                .attr("y", std.fmt.allocPrint(ctx.alloc(), "{s}", .{ly_str}) catch "0")
                .attr("text-anchor", "end")
                .attr("font-size", "10")
                .attr("fill", "#607080")
                .text(std.fmt.allocPrint(ctx.alloc(), "{s}", .{lbl}) catch ""),
        });
    }

    // X-axis baseline.
    _ = svg.children(.{
        ctx.el("line")
            .attr("x1", "48").attr("y1", "160")
            .attr("x2", "580").attr("y2", "160")
            .attr("stroke", "#1e2a38").attr("stroke-width", "1"),
    });

    // "kW" axis label.
    _ = svg.children(.{
        ctx.el("text")
            .attr("x", "8").attr("y", "90")
            .attr("text-anchor", "middle")
            .attr("font-size", "10")
            .attr("fill", "#607080")
            .attr("transform", "rotate(-90,8,90)")
            .text("kW"),
    });

    // Area fill (cosmetic background — client patches this too).
    _ = svg.children(.{
        ctx.el("polygon")
            .attr("data-ref", "dash-power-area")
            .attr("points", std.fmt.allocPrint(ctx.alloc(), "{s}", .{area_pts}) catch "")
            .attr("fill", "#2563eb")
            .attr("opacity", "0.18"),
    });

    // Power line — the element the client patches on every metrics frame.
    _ = svg.children(.{
        ctx.el("polyline")
            .attr("data-ref", "dash-power-line")
            .attr("points", std.fmt.allocPrint(ctx.alloc(), "{s}", .{pts_str}) catch "")
            .attr("fill", "none")
            .attr("stroke", "#3b82f6")
            .attr("stroke-width", "2")
            .attr("stroke-linejoin", "round")
            .attr("stroke-linecap", "round"),
    });

    return svg;
}

/// Hero page: h1 title + FarmScene 3D canvas + Dashboard telemetry island.
pub fn index(ctx: *const verve.Context) !*verve.Node {
    const anim = verve.anim;
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
    const a = ctx.alloc();
    const dash_inner = ctx.section().class("mc-dashboard").children(.{
        // Heading: turbine name binds to `selected_label` (updated on pick); the
        // "Live Telemetry" label is SplitText-animated on load. The SplitText is
        // its OWN sibling h2 so its char-span node surgery never touches the
        // bound `.mc-sel-label` span.
        ctx.el("h2").children(.{
            // Bound to `selected_label`; the Dashboard chunk updates it on pick.
            ctx.span().class("mc-sel-label").bind("selected_label").text("Turbine 0"),
            ctx.span().text(" — Live Telemetry"),
        }),
        ctx.p().class("mc-tele")
            .text("real-time wind farm metrics")
            .splitText(.{ .by = .chars })
            .animate(anim.from(a, ".mc-tele .st-char")
            .opacity(0).y(10)
            .duration(0.4).ease(.out_cubic)
            .stagger(.{ .each = 0.02 })),
        // Hidden per-turbine select proxies: the page <script> clicks the one
        // for the picked turbine, forwarding the pick into THIS island's vid via
        // z-on-click named delegation. The id rides the EXPORT NAME (one proxy
        // per turbine) rather than an attribute, so it never depends on the
        // shared event-dataset scratch buffer.
        ctx.div().class("mc-select-proxies").attr("style", "display:none").children(.{
            ctx.div().attr("data-turbine", "0").attr("z-on-click", "dashboard_select_0"),
            ctx.div().attr("data-turbine", "1").attr("z-on-click", "dashboard_select_1"),
            ctx.div().attr("data-turbine", "2").attr("z-on-click", "dashboard_select_2"),
            ctx.div().attr("data-turbine", "3").attr("z-on-click", "dashboard_select_3"),
        }),
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
        // SSR rolling line/area chart — client patches points on every metrics frame.
        ctx.div().class("mc-power-chart").children(.{
            dashChartSsr(ctx, t0.power_kw),
        }),
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
                \\.mc-power-chart{margin-top:.5rem;background:#0a0f16;border-radius:6px;padding:.5rem}
            ),
        }),
        ctx.el("body").children(.{
            body,
            ctx.script("/verve.js"),
            // Cross-island selection glue: FarmScene dispatches a bubbling
            // CustomEvent("mc-select", {detail:{name:"<id>"}}) on pick. We
            // forward the id into the Dashboard island by stamping it on the
            // hidden proxy element (data-turbine) and firing a synthetic click —
            // verve.js's delegated z-on-click handler then runs
            // dashboard_on_select under Dashboard's own vid. No internal API,
            // no server round-trip. scriptInline applies the CSP nonce.
            ctx.scriptInline(
                \\document.addEventListener("mc-select", function (e) {
                \\  var id = (e.detail && e.detail.name) || "0";
                \\  var proxy = document.querySelector('.mc-select-proxies [data-turbine="' + id + '"]');
                \\  if (!proxy) return;
                \\  proxy.dispatchEvent(new MouseEvent("click", { bubbles: true }));
                \\});
            ),
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
