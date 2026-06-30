//! Example components for the demo app.

const std = @import("std");
const verve = @import("verve");
const islands = @import("islands.zig");

/// Visualization demo: an interactive force-directed graph (VizGraph island,
/// nodes reveal on hydrate) plus static SSR charts — all from `verve.viz`.
pub fn viz(ctx: *const verve.Context) !*verve.Node {
    // --- Force graph as an island -------------------------------------------
    const nodes = [_]verve.viz.GraphNode{
        .{ .id = "core", .label = "core" },
        .{ .id = "server", .label = "server" },
        .{ .id = "client", .label = "client" },
        .{ .id = "desktop", .label = "desktop" },
        .{ .id = "viz", .label = "viz" },
        .{ .id = "cli", .label = "cli" },
    };
    const edges = [_]verve.viz.GraphEdge{
        .{ .from = "core", .to = "server" },
        .{ .from = "core", .to = "client" },
        .{ .from = "core", .to = "desktop" },
        .{ .from = "core", .to = "viz" },
        .{ .from = "viz", .to = "client" },
        .{ .from = "server", .to = "cli" },
    };
    const g = verve.viz.Graph{ .nodes = &nodes, .edges = &edges, .layout = .force };
    const gopts = verve.viz.GraphOpts{ .width = 640, .height = 420, .node_color = "#1f6feb", .edge_color = "#30363d", .label_color = "#f5f5f5" };

    // Positions reused for SSR; node/edge/label arrays feed the island props.
    const positions = try verve.viz.graphPositions(ctx, g, gopts);
    const xs = try ctx.alloc().alloc(f64, positions.len);
    const ys = try ctx.alloc().alloc(f64, positions.len);
    const node_labels = try ctx.alloc().alloc([]const u8, nodes.len);
    const node_ids = try ctx.alloc().alloc([]const u8, nodes.len);
    for (positions, 0..) |p, i| {
        xs[i] = p.x;
        ys[i] = p.y;
    }
    for (nodes, 0..) |nd, i| {
        node_labels[i] = nd.label;
        node_ids[i] = nd.id;
    }
    var ef: std.ArrayList(u32) = .empty;
    var et: std.ArrayList(u32) = .empty;
    for (edges) |e| {
        var fi: u32 = 0;
        var ti: u32 = 0;
        for (nodes, 0..) |nd, i| {
            if (std.mem.eql(u8, nd.id, e.from)) fi = @intCast(i);
            if (std.mem.eql(u8, nd.id, e.to)) ti = @intCast(i);
        }
        try ef.append(ctx.alloc(), fi);
        try et.append(ctx.alloc(), ti);
    }
    const props = try verve.encodeProps(ctx, islands.VizGraphInteractive.Props{
        .xs = xs,
        .ys = ys,
        .ef = ef.items,
        .et = et.items,
        .labels = node_labels,
        .ids = node_ids,
        .layout = @intFromEnum(g.layout),
        .margin = gopts.margin,
    });
    const graph_svg = verve.viz.renderGraphInteractive(ctx, g, gopts);
    const controls = ctx.div().class("viz-controls").children(.{
        ctx.el("button").attr("z-on-click", "viz_add_node").text("+ node"),
        ctx.el("button").attr("z-on-click", "viz_remove_node").text("− node"),
        ctx.el("button").attr("z-on-click", "viz_toggle_live").attr("data-ref", "viz-live-btn").text("● live"),
        ctx.el("button").attr("z-on-click", "viz_layout_cycle").attr("data-ref", "viz-layout-btn").text("⟳ force"),
    });
    const graph_inner = ctx.div().children(.{ controls, graph_svg });
    const graph_island = verve.island(ctx, .{ .name = "VizGraphInteractive", .props = props }, graph_inner);

    // --- Static charts ------------------------------------------------------
    const bars = [_]verve.viz.Datum{
        .{ .label = "Jan", .value = 12 }, .{ .label = "Feb", .value = 19 },
        .{ .label = "Mar", .value = 7 },  .{ .label = "Apr", .value = 24 },
        .{ .label = "May", .value = 15 },
    };
    const cure = [_]verve.viz.Point{
        .{ .x = 0, .y = 2 }, .{ .x = 1, .y = 5 }, .{ .x = 2, .y = 3 },
        .{ .x = 3, .y = 8 }, .{ .x = 4, .y = 6 }, .{ .x = 5, .y = 9 },
    };
    const cloud = [_]verve.viz.Point{
        .{ .x = 1, .y = 3 },   .{ .x = 2, .y = 5 },   .{ .x = 3, .y = 2 },
        .{ .x = 4, .y = 7 },   .{ .x = 5, .y = 4 },   .{ .x = 6, .y = 6 },
        .{ .x = 2.5, .y = 8 }, .{ .x = 4.5, .y = 3 },
    };
    const slices = [_]verve.viz.Datum{
        .{ .label = "core", .value = 40 },   .{ .label = "client", .value = 25 },
        .{ .label = "server", .value = 20 }, .{ .label = "desktop", .value = 15 },
    };
    const copts = verve.viz.ChartOpts{ .width = 420, .height = 260, .color = "#1f6feb", .axis_color = "#8b949e" };

    const candles = [_]verve.viz.Candle{
        .{ .label = "Mon", .open = 100, .high = 112, .low = 96, .close = 109 },
        .{ .label = "Tue", .open = 109, .high = 114, .low = 104, .close = 106 },
        .{ .label = "Wed", .open = 106, .high = 108, .low = 95, .close = 98 },
        .{ .label = "Thu", .open = 98, .high = 111, .low = 97, .close = 110 },
        .{ .label = "Fri", .open = 110, .high = 118, .low = 108, .close = 116 },
    };
    const boxes = [_]verve.viz.BoxStats{
        .{ .label = "p50", .min = 8, .q1 = 14, .median = 19, .q3 = 26, .max = 34 },
        .{ .label = "p95", .min = 20, .q1 = 32, .median = 41, .q3 = 55, .max = 72 },
        .{ .label = "p99", .min = 40, .q1 = 58, .median = 70, .q3 = 88, .max = 110 },
    };
    const heat_rows = [_][]const u8{ "Mon", "Tue", "Wed", "Thu" };
    const heat_cols = [_][]const u8{ "00h", "06h", "12h", "18h" };
    const heat_vals = [_]f64{
        2, 1, 8,  5,
        3, 2, 12, 7,
        4, 3, 15, 9,
        6, 5, 18, 11,
    };
    const radar_axes = [_][]const u8{ "speed", "power", "range", "safety", "cost" };
    const radar_series = [_]verve.viz.StackSeries{
        .{ .name = "EV", .values = &.{ 8, 6, 5, 9, 4 }, .color = "#1f6feb" },
        .{ .name = "ICE", .values = &.{ 6, 8, 9, 6, 7 }, .color = "#f59e0b" },
    };
    const violin_data = [_]verve.viz.ViolinSeries{
        .{ .label = "ctrl", .samples = &.{ 18, 20, 21, 22, 22, 23, 23, 24, 25, 27, 30 } },
        .{ .label = "A/B", .samples = &.{ 12, 15, 16, 17, 18, 18, 19, 20, 22, 26 } },
        .{ .label = "new", .samples = &.{ 8, 10, 11, 11, 12, 12, 13, 14, 16, 20 } },
    };
    const quarters = [_][]const u8{ "Q1", "Q2", "Q3", "Q4" };
    const stack_series = [_]verve.viz.StackSeries{
        .{ .name = "web", .values = &.{ 12, 19, 9, 22 }, .color = "#1f6feb" },
        .{ .name = "api", .values = &.{ 8, 11, 14, 7 }, .color = "#10b981" },
        .{ .name = "jobs", .values = &.{ 4, 6, 5, 9 }, .color = "#f59e0b" },
    };

    // Sankey: request flow through the stack.
    const sankey_nodes = [_]verve.viz.SankeyNode{
        .{ .id = "in", .label = "requests" },    .{ .id = "cache", .label = "cache" },
        .{ .id = "app", .label = "app" },        .{ .id = "db", .label = "db" },
        .{ .id = "resp", .label = "responses" },
    };
    const sankey_links = [_]verve.viz.SankeyLink{
        .{ .from = "in", .to = "cache", .value = 60 },
        .{ .from = "in", .to = "app", .value = 40 },
        .{ .from = "cache", .to = "resp", .value = 45 },
        .{ .from = "cache", .to = "app", .value = 15 },
        .{ .from = "app", .to = "db", .value = 30 },
        .{ .from = "app", .to = "resp", .value = 25 },
        .{ .from = "db", .to = "resp", .value = 30 },
    };

    // Treemap: repo bytes by module (parent-index hierarchy, parents first).
    const tm_items = [_]verve.viz.TreemapItem{
        .{ .label = "core" }, // 0
        .{ .label = "node", .value = 18, .parent = 0 },
        .{ .label = "viz", .value = 31, .parent = 0 },
        .{ .label = "signal", .value = 9, .parent = 0 },
        .{ .label = "server" }, // 4
        .{ .label = "http", .value = 14, .parent = 4 },
        .{ .label = "push", .value = 4, .parent = 4 },
        .{ .label = "client", .value = 16 },
        .{ .label = "desktop", .value = 22 },
    };

    // Chord: traffic between regions (row-major flows).
    const chord_labels = [_][]const u8{ "us", "eu", "apac" };
    const chord_matrix = [_]f64{
        0, 12, 5,
        9, 0,  7,
        4, 6,  0,
    };

    // A directed pipeline with a skip edge (src→emit spans 3 layers) so the
    // long edge routes through virtual-node bends instead of cutting straight.
    const dag_nodes = [_]verve.viz.GraphNode{
        .{ .id = "src", .label = "source" },   .{ .id = "parse", .label = "parse" },
        .{ .id = "opt", .label = "optimize" }, .{ .id = "emit", .label = "emit" },
        .{ .id = "log", .label = "log" },
    };
    const dag_edges = [_]verve.viz.GraphEdge{
        .{ .from = "src", .to = "parse" }, .{ .from = "parse", .to = "opt" },
        .{ .from = "opt", .to = "emit" },  .{ .from = "opt", .to = "log" },
        .{ .from = "src", .to = "emit" }, // skip edge → bends through parse/opt layers
    };
    const dag = verve.viz.Graph{ .nodes = &dag_nodes, .edges = &dag_edges, .layout = .dag };
    const dag_svg = verve.viz.renderGraph(ctx, dag, .{ .width = 560, .height = 380, .node_color = "#8b5cf6", .edge_color = "#30363d", .label_color = "#f5f5f5" });

    // Edge-routing A/B/C: the same pipeline drawn with straight polyline
    // bends, Catmull-Rom splines, and orthogonal runs with rounded corners.
    const dag_curved = verve.viz.renderGraph(ctx, dag, .{ .width = 420, .height = 300, .node_color = "#8b5cf6", .edge_color = "#fbbf24", .label_color = "#f5f5f5", .edge_routing = .curved });
    const dag_ortho = verve.viz.renderGraph(ctx, dag, .{ .width = 420, .height = 300, .node_color = "#8b5cf6", .edge_color = "#38bdf8", .label_color = "#f5f5f5", .edge_routing = .orthogonal });

    // Crossing-minimization A/B: a deliberately tangled DAG (A→Z, B→Y, C→X).
    // Under id-order the three edges all cross; the sweep reorders the bottom
    // layer to Z,Y,X so they fan cleanly.
    const cross_nodes = [_]verve.viz.GraphNode{
        .{ .id = "a", .label = "A" }, .{ .id = "b", .label = "B" }, .{ .id = "c", .label = "C" },
        .{ .id = "x", .label = "X" }, .{ .id = "y", .label = "Y" }, .{ .id = "z", .label = "Z" },
    };
    const cross_edges = [_]verve.viz.GraphEdge{
        .{ .from = "a", .to = "z" }, .{ .from = "b", .to = "y" }, .{ .from = "c", .to = "x" },
    };
    const cdag = verve.viz.Graph{ .nodes = &cross_nodes, .edges = &cross_edges, .layout = .dag };
    const dag_off = verve.viz.renderGraph(ctx, cdag, .{ .width = 420, .height = 240, .node_color = "#8b5cf6", .edge_color = "#f87171", .label_color = "#f5f5f5", .dag_crossing_iterations = 0 });
    const dag_on = verve.viz.renderGraph(ctx, cdag, .{ .width = 420, .height = 240, .node_color = "#8b5cf6", .edge_color = "#34d399", .label_color = "#f5f5f5" });

    return ctx.div().class("viz-page").children(.{
        ctx.h1("Visualizations"),
        ctx.p().text("Native verve.viz: SVG scene model, scales/axes, and tree/radial/force/dag layouts — computed in Zig, rendered server-side. The graph below is an island: nodes reveal on hydrate, yet the page is fully formed with JS off."),
        ctx.section().class("card viz-card").children(.{ ctx.h2("Force-directed graph — interactive"), ctx.p().class("hint").text("Scroll to zoom, drag to pan, drag a node (works past the svg edge — pointer capture), hover for a label, click to select, double-click to collapse a subtree (+N badge; double-click again to expand). +/− mutate the graph; ⟳ cycles tree/radial/force/dag with a tween; ● live streams server-pushed wire deltas over SSE every second — zoom, selection, and collapse all survive."), graph_island }),
        ctx.section().class("card viz-card").children(.{ ctx.h2("Layered DAG"), ctx.p().class("hint").text("The src→emit skip edge spans 3 layers — it routes through virtual-node bends rather than cutting straight across."), dag_svg }),
        ctx.section().class("card viz-card").children(.{ ctx.h2("Edge routing — curved"), ctx.p().class("hint").text("edge_routing = .curved — the same DAG with Catmull-Rom splines through the via-points."), dag_curved }),
        ctx.section().class("card viz-card").children(.{ ctx.h2("Edge routing — orthogonal"), ctx.p().class("hint").text("edge_routing = .orthogonal — Manhattan runs through the reserved virtual-node channels, corners rounded."), dag_ortho }),
        ctx.section().class("card viz-card").children(.{ ctx.h2("Crossing minimization — OFF"), ctx.p().class("hint").text("dag_crossing_iterations = 0 → A→Z, B→Y, C→X all cross (id-order)."), dag_off }),
        ctx.section().class("card viz-card").children(.{ ctx.h2("Crossing minimization — ON"), ctx.p().class("hint").text("Default sweeps reorder the bottom layer to Z,Y,X → edges fan cleanly, zero crossings."), dag_on }),
        ctx.section().class("card viz-card").children(.{ ctx.h2("Bar chart"), verve.viz.barChart(ctx, &bars, copts) }),
        ctx.section().class("card viz-card").children(.{ ctx.h2("Stacked bar chart"), verve.viz.stackedBarChart(ctx, &quarters, &stack_series, .{ .width = 480, .height = 300, .axis_color = "#8b949e" }) }),
        ctx.section().class("card viz-card").children(.{ ctx.h2("Grouped bar chart"), verve.viz.groupedBarChart(ctx, &quarters, &stack_series, .{ .width = 480, .height = 300, .axis_color = "#8b949e" }) }),
        ctx.section().class("card viz-card").children(.{ ctx.h2("Candlestick chart"), verve.viz.candlestickChart(ctx, &candles, .{ .width = 480, .height = 300, .axis_color = "#8b949e" }) }),
        ctx.section().class("card viz-card").children(.{ ctx.h2("Box plot"), verve.viz.boxPlotChart(ctx, &boxes, .{ .width = 480, .height = 300, .color = "#1f6feb", .axis_color = "#8b949e" }) }),
        ctx.section().class("card viz-card").children(.{ ctx.h2("Heatmap"), verve.viz.heatmapChart(ctx, &heat_rows, &heat_cols, &heat_vals, .{ .width = 420, .height = 280, .show_values = true }) }),
        ctx.section().class("card viz-card").children(.{ ctx.h2("Radar chart"), verve.viz.radarChart(ctx, &radar_axes, &radar_series, .{ .width = 360, .height = 360, .axis_color = "#8b949e" }) }),
        ctx.section().class("card viz-card").children(.{ ctx.h2("Violin plot"), verve.viz.violinChart(ctx, &violin_data, .{ .width = 480, .height = 320, .axis_color = "#8b949e" }) }),
        ctx.section().class("card viz-card").children(.{ ctx.h2("Line chart"), verve.viz.lineChart(ctx, &cure, copts) }),
        ctx.section().class("card viz-card").children(.{ ctx.h2("Area chart"), verve.viz.areaChart(ctx, &cure, copts) }),
        ctx.section().class("card viz-card").children(.{ ctx.h2("Scatter plot"), verve.viz.scatterChart(ctx, &cloud, copts) }),
        ctx.section().class("card viz-card").children(.{ ctx.h2("Donut chart"), verve.viz.pieChart(ctx, &slices, .{ .width = 280, .height = 280, .inner_ratio = 0.55 }) }),
        ctx.section().class("card viz-card").children(.{ ctx.h2("Sankey diagram"), ctx.p().class("hint").text("Weighted flows between columns — link width ∝ value, node height ∝ throughput."), verve.viz.sankeyChart(ctx, &sankey_nodes, &sankey_links, .{ .width = 560, .height = 320, .label_color = "#f5f5f5" }) }),
        ctx.section().class("card viz-card").children(.{ ctx.h2("Treemap"), ctx.p().class("hint").text("Squarified: leaf area ∝ value, nested by parent, colored by root."), verve.viz.treemapChart(ctx, &tm_items, .{ .width = 560, .height = 320 }) }),
        ctx.section().class("card viz-card").children(.{ ctx.h2("Chord diagram"), ctx.p().class("hint").text("Pairwise flows around a circle — arc span ∝ row sum, ribbons connect nonzero pairs."), verve.viz.chordChart(ctx, &chord_labels, &chord_matrix, .{ .width = 380, .height = 380, .label_color = "#f5f5f5" }) }),
        ctx.p().children(.{verve.link(ctx, "/", "← Home", .{})}),
    }).build();
}

/// verve.viz canvas render path demo — /viz-canvas. A ~1500-node procedural
/// graph (deterministic jittered grid, index-seeded — no RNG at SSR) drawn to a
/// single canvas2d via the VizGraphCanvas island. Pan/zoom/hover/select.
pub fn vizCanvas(ctx: *const verve.Context) !*verve.Node {
    const canvas = ctx.div().class("gl-wrap").children(.{
        ctx.el("canvas")
            .attr("data-ref", "vizcanvas-canvas")
            .attr("width", "640")
            .attr("height", "420")
            .attr("z-on-pointerdown", "vizcanvas_pointerdown")
            .attr("z-on-pointermove", "vizcanvas_pointermove")
            .attr("z-on-pointerup", "vizcanvas_pointerup")
            .attr("z-on-wheel", "vizcanvas_wheel")
            .attr("style", "width:100%;max-width:640px;aspect-ratio:32/21;display:block;background:#0d1117;border-radius:8px;touch-action:none;cursor:grab;"),
    });
    const inner = ctx.section().class("card").children(.{
        ctx.h2("Large graph — canvas2d render path"),
        canvas,
    });
    const island = verve.island(ctx, .{ .name = "VizGraphCanvas" }, inner);
    return ctx.main_().class("home").children(.{
        ctx.h1("verve.viz — canvas render"),
        ctx.p().text("A ~1500-node graph drawn to a single canvas2d (vs the SVG-DOM " ++
            "path): one batched draw call per frame. Drag to pan, wheel to zoom, " ++
            "hover/click a node to highlight."),
        island,
    });
}

/// WebSocket hub demo — /ws-demo. Type a message → re-published over the
/// "ws-demo" push channel via WS → broadcast to every connected tab.
pub fn wsDemo(ctx: *const verve.Context) !*verve.Node {
    const card = ctx.section().class("card").children(.{
        ctx.h2("WebSocket hub — broadcast"),
        ctx.el("input")
            .attr("data-ref", "wsdemo-input")
            .attr("placeholder", "type a message…")
            .attr("style", "width:70%;padding:6px;margin-right:6px;"),
        ctx.el("button").attr("z-on-click", "wsdemo_send").text("Send"),
        ctx.el("pre")
            .attr("data-ref", "wsdemo-log")
            .attr("style", "min-height:160px;margin-top:10px;background:#0d1117;color:#d5d5d5;padding:10px;border-radius:6px;white-space:pre-wrap;"),
    });
    const island = verve.island(ctx, .{ .name = "WsDemo" }, card);
    return ctx.main_().class("home").children(.{
        ctx.h1("verve — WebSocket hub"),
        ctx.p().text("Full-duplex over one socket: a message you send re-publishes " ++
            "to the channel and fans out to every connected tab (incl. this one). " ++
            "Open /ws-demo in two tabs to see it broadcast."),
        island,
    });
}

pub fn counter(ctx: *const verve.Context, initial: i32) !*verve.Node {
    return ctx.div().class("counter-card").children(.{
        ctx.h1("Verve Counter"),
        ctx.span().class("count").bind("count").textInt(initial),
        // +/- buttons are wrapped in forms so they work without JS (native
        // submit → 303 to Referer). When wasm/WS is available, the bridge's
        // delegated click handler calls preventDefault and routes through
        // the wasm export instead.
        ctx.actionForm(.{ .post = "/api/incrementCount", .class = "counter-form" }).children(.{
            ctx.button("+").type_("submit").onClick("increment_counter"),
        }),
        ctx.actionForm(.{ .post = "/api/decrementCount", .class = "counter-form" }).children(.{
            ctx.button("-").type_("submit").onClick("decrement_counter"),
        }),
        // Typed `_call` round-trip demo: no form — the wasm export posts
        // and the correlated reply sets the count.
        ctx.button("call +").type_("button").onClick("verve_call_increment"),
        ctx.p().class("clicks").children(.{
            ctx.span().text("Total clicks: "),
            ctx.span().bind("clicks").text("0"),
        }),
    }).build();
}

pub fn home(ctx: *const verve.Context) !*verve.Node {
    return ctx.main_().class("home").children(.{
        ctx.h1("Verve"),
        ctx.p().text("Full-stack Zig web framework — fine-grained reactivity, no macros."),
        ctx.p().children(.{verve.link(ctx, "/counter", "Counter demo →", .{ .prefetch_on_hover = true })}),
        ctx.p().children(.{verve.link(ctx, "/todos", "Todo list (form fallback) →", .{})}),
        ctx.p().children(.{verve.link(ctx, "/anim", "Animation engine (verve.anim) →", .{})}),
        ctx.p().children(.{verve.link(ctx, "/smooth", "ScrollSmoother + snap →", .{})}),
        ctx.p().children(.{verve.link(ctx, "/work/hello-world", "Path-param demo (/work/:slug) →", .{})}),
    }).build();
}

/// verve.anim demo page: declarative SSR entrance animations via
/// `Node.animate(...)` (no island) plus the `AnimDemo` island exercising
/// the imperative control API.
pub fn animDemo(ctx: *const verve.Context) !*verve.Node {
    const anim = verve.anim;
    const a = ctx.alloc();

    // --- Imperative island: staggered deck + control buttons --------------
    const controls = ctx.div().class("anim-controls").children(.{
        ctx.el("button").attr("z-on-click", "anim_pause").text("pause"),
        ctx.el("button").attr("z-on-click", "anim_play").text("play"),
        ctx.el("button").attr("z-on-click", "anim_reverse").text("reverse"),
        ctx.el("button").attr("z-on-click", "anim_restart").text("restart"),
        ctx.el("button").attr("z-on-click", "anim_half_speed").text("0.5x"),
        ctx.el("button").attr("z-on-click", "anim_full_speed").text("1x"),
        ctx.el("button").attr("z-on-click", "anim_scatter").text("scatter"),
    });
    const deck = ctx.div().class("anim-deck");
    var i: usize = 0;
    while (i < 7) : (i += 1) {
        _ = deck.children(.{ctx.div().class("anim-card").textInt(i + 1)});
    }
    const island_inner = ctx.div().children(.{
        ctx.h2("Imperative timeline (island)").class("anim-title"),
        ctx.p().class("hint").children(.{
            ctx.span().text("status: "),
            ctx.span().bind("anim_status").text("loading…"),
        }),
        controls,
        deck,
        // Standalone-trigger + Observer probe. Lives INSIDE the island so
        // its z-binds get vid-rewritten consistently with the chunk's
        // scoped registerStr/signalSetStr calls.
        ctx.div().class("anim-spacer").ariaHidden(true),
        ctx.div().id("scroll-probe").class("anim-probe").children(.{
            ctx.p().children(.{
                ctx.span().text("island trigger: "),
                ctx.span().bind("scroll_state").text("scroll down…"),
            }),
            ctx.p().children(.{
                ctx.span().text("trigger progress: "),
                ctx.span().bind("scroll_prog").text("0%"),
            }),
            ctx.p().children(.{
                ctx.span().text("wheel/touch velocity: "),
                ctx.span().bind("obs_vel").text("0 px/s"),
            }),
            // imperative MorphSVG: the chunk's anim_morph_toggle export
            // animPlay()s a morph tween on this shape per click
            ctx.el("svg").attr("viewBox", "0 0 100 100").attr("width", "80").attr("height", "80").children(.{
                // data-ref lets the chunk read the LIVE d (morph-from-current)
                ctx.el("path").id("morph-island").attr("data-ref", "morph-path").attr("d", "M50,5 L61,38 L95,38 L67,58 L78,91 L50,71 L22,91 L33,58 L5,38 L39,38 Z").attr("fill", "#10b981"),
            }),
            ctx.el("button").attr("z-on-click", "anim_morph_toggle").text("morph"),
            // drop zones for the drag probe (zone hover class is zero-wasm;
            // the on_drop callback reports the index)
            ctx.div().class("drop-row").children(.{
                ctx.div().class("drop-zone").text("zone 0"),
                ctx.div().class("drop-zone").text("zone 1"),
            }),
            ctx.el("button").attr("z-on-click", "anim_flip_card_toggle").text("remove/restore card"),
            // imperative Draggable: the chunk wires callbacks + reads
            // position/velocity through a DragHandle
            ctx.div().id("drag-probe").class("anim-card drag-card").text("drag"),
            ctx.p().class("hint").children(.{
                ctx.span().text("drag: "),
                ctx.span().bind("drag_state").text("idle"),
                ctx.span().text(" · pos "),
                ctx.span().bind("drag_pos").text("0, 0"),
                ctx.span().text(" · vel "),
                ctx.span().bind("drag_vel").text("0 px/s"),
            }),
            // FLIP shuffle: capture -> listDiff reorder -> play. The grid
            // is a keyed bind so move_keyed_child preserves element
            // identity (the FLIP fast path).
            ctx.el("button").attr("z-on-click", "anim_shuffle").text("shuffle"),
            ctx.el("button").attr("z-on-click", "anim_flip_scale_toggle").text("scale morph"),
            flipGrid(ctx),
        }),
    });
    const anim_island = verve.island(ctx, .{ .name = "AnimDemo" }, island_inner);

    // --- Declarative SSR surface: data-anim attributes, no island ---------
    return ctx.main_().class("home").children(.{
        ctx.h1("verve.anim").animate(anim.from(a, null)
            .opacity(0).y(24)
            .duration(0.6).ease(.out_cubic)),
        ctx.p()
            .text("Tweens, timelines, keyframes, stagger, and a control API. " ++
                "Zig builds + serializes descriptors; the bridge interpreter runs them. " ++
                "With prefers-reduced-motion set, entrances jump to their end state.")
            .animate(anim.from(a, null).opacity(0).duration(0.8).delay(0.2)),
        ctx.div().class("anim-pulse").ariaHidden(true).animate(anim.to(a, null)
            .step(0).scale(1.0)
            .step(50).stepEase(.in_out_sine).scale(1.3)
            .step(100).scale(1.0)
            .duration(1.4).repeat(-1).reducedMotion(.skip)),
        anim_island,
        splitSection(ctx),
        pathSection(ctx),
        sortableSection(ctx),
        dragSection(ctx),
        scrollSection(ctx),
        containerScrollSection(ctx),
        ctx.p().children(.{ctx.a("/", "← Home")}),
    }).build();
}

const star_d: []const u8 =
    "M50,5 L61,38 L95,38 L67,58 L78,91 L50,71 L22,91 L33,58 L5,38 L39,38 Z";
const blob_d: []const u8 =
    "M10,50 A40,40 0 0 1 90,50 A40,40 0 0 1 10,50 Z";

/// MotionPath + MorphSVG demo (phase 3): a marker orbiting a
/// viz-generated curved edge with tangent rotation, and an infinite
/// star <-> circle morph. Both are pure phase functions, so the third
/// block scrubs a motion path with ScrollTrigger.
fn pathSection(ctx: *const verve.Context) *verve.Node {
    const anim = verve.anim;
    const a = ctx.alloc();

    // viz edge-path output plugs straight into .motionPath
    const orbit_pts = [_]verve.viz.Vec2{
        .{ .x = 20, .y = 90 },   .{ .x = 90, .y = 20 },
        .{ .x = 170, .y = 110 }, .{ .x = 250, .y = 30 },
        .{ .x = 300, .y = 80 },
    };
    const orbit_d = verve.viz.edgePathD(a, &orbit_pts, .curved, .{}) catch "M0,0 L10,0";

    return ctx.el("section").class("anim-path").children(.{
        ctx.h2("MotionPath: orbit a viz edge"),
        ctx.p().class("hint").text("The marker follows a verve.viz curved edge path with tangent auto-rotation."),
        ctx.div().class("anim-orbit-wrap")
            .children(.{
                ctx.el("svg").attr("viewBox", "0 0 320 130").attr("width", "320").attr("height", "130").children(.{
                    ctx.el("path").attr("d", orbit_d).attr("fill", "none").attr("stroke", "#30363d").attr("stroke-width", "1.5"),
                }),
                ctx.div().class("anim-orbiter").ariaHidden(true),
            })
            .animate(anim.to(a, ".anim-orbiter")
            .motionPath(.{ .path = orbit_d, .rotate = true })
            .duration(4).ease(.linear).repeat(-1)
            .reducedMotion(.skip)),
        ctx.h2("MorphSVG: star ↔ circle"),
        ctx.div()
            .children(.{
                ctx.el("svg").attr("viewBox", "0 0 100 100").attr("width", "120").attr("height", "120").children(.{
                    ctx.el("path").id("morph-shape").attr("d", star_d).attr("fill", "#1f6feb"),
                }),
            })
            .animate(anim.to(a, "#morph-shape")
            .morph(.{ .from = star_d, .to = blob_d })
            .duration(1.4).ease(.in_out_sine)
            .repeat(-1).yoyo(true)
            .reducedMotion(.skip)),
        ctx.h2("Scrubbed motion path"),
        ctx.p().class("hint").text("Scroll drives the dot along the S-curve (smoothed scrub)."),
        ctx.div().class("anim-orbit-wrap")
            .children(.{
                ctx.el("svg").attr("viewBox", "0 0 320 100").attr("width", "320").attr("height", "100").children(.{
                    ctx.el("path").attr("d", "M10,80 C90,80 90,20 160,20 C230,20 230,80 310,80").attr("fill", "none").attr("stroke", "#30363d").attr("stroke-width", "1.5"),
                }),
                ctx.div().class("anim-scrub-dot").ariaHidden(true),
            })
            .animate(anim.to(a, ".anim-scrub-dot")
            .motionPath(.{ .path = "M10,80 C90,80 90,20 160,20 C230,20 230,80 310,80" })
            .duration(1).ease(.linear)
            .scrollTrigger(.{
            .start = .{ .viewport = .{ .pct = 90 } },
            .end = .{ .at = .{ .trigger = .bottom, .viewport = .{ .pct = 40 } } },
            .scrub = .{ .smooth = 0.3 },
        })),
    });
}

/// ScrollSmoother + snap demo (phase 6): the whole page content rides a
/// smoother (native scrolling preserved — the visual eases behind the
/// scrollbar), with parallax layers, a snapping section deck, and a
/// transform-pinned panel. Render the smoothScroll() RETURN VALUE.
pub fn smoothDemo(ctx: *const verve.Context) !*verve.Node {
    const anim = verve.anim;
    const a = ctx.alloc();

    // 4-section deck: container-scrubbed progress bar + step snap —
    // idle always settles on a section boundary.
    const deck = ctx.el("section").id("snap-deck").children(.{
        ctx.div().class("smooth-deck-bar").ariaHidden(true),
        smoothSection(ctx, "One", "#1f6feb"),
        smoothSection(ctx, "Two", "#10b981"),
        smoothSection(ctx, "Three", "#f59e0b"),
        smoothSection(ctx, "Four", "#e3506f"),
    }).animate(anim.to(a, ".smooth-deck-bar")
        .scaleX(1).propFrom("scaleX", 0)
        .duration(1).ease(.linear)
        .scrollTrigger(.{
        .start = .{ .trigger = .top, .viewport = .top },
        .end = .{ .at = .{ .trigger = .bottom, .viewport = .bottom } },
        .scrub = .exact,
        .snap = .{ .step = 1.0 / 3.0 },
        .snap_ease = .out_bounce,
        .snap_directional = true,
    }));

    const content = ctx.main_().class("home smooth-page").children(.{
        ctx.el("section").class("smooth-hero").children(.{
            ctx.div().class("smooth-bg").ariaHidden(true).parallaxSpeed(0.5),
            ctx.div().class("smooth-mid").ariaHidden(true).parallaxSpeed(0.8),
            ctx.h1("ScrollSmoother").splitText(.{ .by = .chars })
                .animate(anim.from(a, ".st-char")
                .opacity(0).y(18)
                .duration(0.5).ease(.out_cubic)
                .stagger(.{ .each = 0.03 })),
            ctx.p().class("hint").text("Native scrolling, eased visuals. The scrollbar, keyboard, and anchors all work — the content glides to catch up."),
            ctx.div().class("smooth-badge").text("lag 0.4").parallaxLag(0.4),
        }),
        ctx.h2("Snapping deck").animate(anim.reveal(a, "in-view", .{
            .start = .{ .viewport = .{ .pct = 85 } },
            .once = true,
        })),
        ctx.p().class("hint").text("Scroll into the deck and let go — it settles on a section boundary."),
        deck,
        ctx.h2("Pinned under the smoother"),
        ctx.p().class("hint").text("position:fixed breaks inside transformed content, so this pin counter-translates instead."),
        ctx.div().class("anim-pin-panel")
            .children(.{
                ctx.div().class("anim-scrub-bar").ariaHidden(true),
                ctx.p().text("Transform-pinned while the bar scrubs (smoothed)."),
            })
            .animate(anim.to(a, ".anim-scrub-bar")
            .scaleX(1).propFrom("scaleX", 0)
            .duration(1).ease(.linear)
            .scrollTrigger(.{
            .start = .{ .trigger = .top, .viewport = .{ .pct = 20 } },
            .end = .{ .rel_vh = 1.5 },
            .scrub = .{ .smooth = 0.3 },
            .pin = .self,
            .snap = .{ .points = &.{ 0, 0.5, 1 } },
        })),
        smoothProbe(ctx),
        ctx.div().class("anim-spacer").ariaHidden(true),
        ctx.p().children(.{ctx.a("/", "← Home")}),
    });

    return content.smoothScroll(.{ .smooth = 1.2 }).build();
}

fn smoothSection(ctx: *const verve.Context, label: []const u8, color: []const u8) *verve.Node {
    return ctx.el("section").class("smooth-section").children(.{
        ctx.h2(label).attrFmt("style", "color:{s}", .{color}),
    });
}

/// Island probe: native vs smoothed scroll side by side (visualizes the
/// lag; exercises verve_sm_get end-to-end).
fn smoothProbe(ctx: *const verve.Context) *verve.Node {
    const inner = ctx.div().class("anim-probe").children(.{
        ctx.p().children(.{
            ctx.span().text("native: "),
            ctx.span().bind("sm_native").text("0"),
            ctx.span().text(" px · smoothed: "),
            ctx.span().bind("sm_smooth").text("0"),
            ctx.span().text(" px · vel: "),
            ctx.span().bind("sm_vel").text("0 px/s"),
        }),
    });
    return verve.island(ctx, .{ .name = "SmoothDemo" }, inner);
}

/// Eight keyed cards for the FLIP shuffle (data-vkey "c1".."c8" — the
/// chunk's anim_shuffle reorders these keys via listDiff).
fn flipGrid(ctx: *const verve.Context) *verve.Node {
    const grid = ctx.div().class("flip-grid").bind("flip_list");
    const keys = [_][]const u8{ "c1", "c2", "c3", "c4", "c5", "c6", "c7", "c8" };
    for (keys, 0..) |k, i| {
        const card = ctx.div().class("anim-card fcard").attr("data-vkey", k).textInt(i + 1);
        // data-ref="flip-c1" lets the AnimDemo chunk's anim_flip_scale_toggle
        // find card c1 via queryRef for the counter-scale size-morph demo.
        if (i == 0) _ = card.attr("data-ref", "flip-c1");
        _ = grid.children(.{card});
    }
    return grid;
}

/// SplitText demo (phase 5): server-side text splitting — chars stagger
/// in on scroll, paragraph reveals by line (lines grouped client-side
/// by offsetTop since wrap depends on layout).
fn splitSection(ctx: *const verve.Context) *verve.Node {
    const anim = verve.anim;
    const a = ctx.alloc();

    return ctx.el("section").class("anim-split").children(.{
        ctx.h2("Split, stagger, scroll")
            .splitText(.{ .by = .chars })
            .animate(anim.from(a, ".st-char")
            .opacity(0).y(18)
            .duration(0.45).ease(.out_cubic)
            .stagger(.{ .each = 0.025 })
            .scrollTrigger(.{
            .start = .{ .viewport = .{ .pct = 85 } },
            .actions = .{ .on_enter = .play, .on_leave_back = .reverse },
        })),
        // Grapheme split (UAX#29, SSR): the emoji ZWJ family, skin-tone
        // thumbs-up, flag (two regional indicators), and decomposed "café"
        // each stay ONE span — `.by = .graphemes` keeps clusters whole.
        ctx.h2("Cafe\u{0301} \u{1F44D}\u{1F3FD} \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} \u{1F1FA}\u{1F1F8}")
            .splitText(.{ .by = .graphemes })
            .animate(anim.from(a, ".anim-split h2:nth-of-type(2) .st-char")
            .opacity(0).y(18).scale(0.6)
            .duration(0.5).ease(.out_back)
            .stagger(.{ .each = 0.06 })
            .scrollTrigger(.{
            .start = .{ .viewport = .{ .pct = 85 } },
            .actions = .{ .on_enter = .play, .on_leave_back = .reverse },
        })),
        ctx.p()
            .text("Each line of this paragraph reveals on its own as you scroll. " ++
                "The server splits the text into word spans; the bridge groups " ++
                "them into lines once it knows where the browser wrapped them.")
            .splitText(.{ .by = .lines })
            .animate(anim.from(a, ".st-line")
            .opacity(0).y(24)
            .duration(0.5).ease(.out_cubic)
            .stagger(.{ .each = 0.12 })
            .scrollTrigger(.{
            .start = .{ .viewport = .{ .pct = 85 } },
            .actions = .{ .on_enter = .play, .on_leave_back = .reverse },
        })),
        // RTL-aware split (phase 5 / task 6): mixed LTR + RTL headline.
        // "Hello שלום مرحبا" — Latin, Hebrew, Arabic each form their own
        // directional run. RTL runs get <span dir="rtl"> so the browser
        // reorders glyphs correctly while data-st-i stays logical-order.
        ctx.h2("Hello \u{05E9}\u{05DC}\u{05D5}\u{05DD} \u{0645}\u{0631}\u{062D}\u{0628}\u{0627}")
            .splitText(.{ .by = .chars, .rtl_aware = true })
            .animate(anim.from(a, ".anim-split h2:nth-of-type(3) .st-char")
            .opacity(0).y(18).scale(0.7)
            .duration(0.5).ease(.out_back)
            .stagger(.{ .each = 0.04 })
            .scrollTrigger(.{
            .start = .{ .viewport = .{ .pct = 85 } },
            .actions = .{ .on_enter = .play, .on_leave_back = .reverse },
        })),
    });
}

/// Draggable demo (phase 4): a zero-wasm bounded drag card with inertia
/// + grid snap — pure data-drag, no island.
/// Sortable demo (phase 7): a single-list sortable + a two-column board
/// demonstrating cross-list group transfer and edge autoscroll.
fn sortableSection(ctx: *const verve.Context) *verve.Node {
    // Single-list (7b demo — unchanged).
    const list = ctx.el("ul").id("sort-list").class("sort-list");
    const items = [_][]const u8{ "Alpha", "Beta", "Gamma", "Delta", "Epsilon" };
    for (items) |item| {
        _ = list.children(.{ctx.el("li").class("sort-item").text(item)});
    }

    // Two-column board (7c demo): cross-list group transfer + autoscroll.
    // Column A: "Todo" items; Column B: "Done" items.
    // The island attaches both as group="board" sortables.
    const col_a = ctx.el("ul").id("board-col-a").class("sort-list board-col");
    const todo_items = [_][]const u8{ "Write tests", "Review PR", "Update docs", "Fix bug", "Deploy" };
    for (todo_items) |item| {
        _ = col_a.children(.{ctx.el("li").class("sort-item").text(item)});
    }

    const col_b = ctx.el("ul").id("board-col-b").class("sort-list board-col");
    const done_items = [_][]const u8{ "Setup CI", "Init repo" };
    for (done_items) |item| {
        _ = col_b.children(.{ctx.el("li").class("sort-item").text(item)});
    }

    const board = ctx.div().class("sort-board").children(.{
        ctx.div().class("sort-board-col").children(.{
            ctx.h3("Todo"),
            col_a,
        }),
        ctx.div().class("sort-board-col").children(.{
            ctx.h3("Done"),
            col_b,
        }),
    });

    return ctx.el("section").class("anim-drag").children(.{
        ctx.h2("Sortable: drag-to-reorder + FLIP"),
        ctx.p().class("hint").text("Drag any row — siblings FLIP-shift to preview the drop slot. The island fires on_reorder when you release."),
        list,
        ctx.p().class("hint").children(.{
            ctx.span().text("status: "),
            ctx.span().bind("sort_status").text("drag an item to reorder"),
        }),
        ctx.h3("Cross-list board (group transfer + autoscroll)"),
        ctx.p().class("hint").text("Drag items between Todo and Done columns. Edge autoscroll activates near the top/bottom of each column."),
        board,
        ctx.p().class("hint").children(.{
            ctx.span().text("board status: "),
            ctx.span().bind("board_status").text("drag an item between columns"),
        }),
    });
}

fn dragSection(ctx: *const verve.Context) *verve.Node {
    const anim = verve.anim;
    const a = ctx.alloc();

    return ctx.el("section").class("anim-drag").children(.{
        ctx.h2("Draggable: bounds + inertia + grid snap"),
        ctx.p().class("hint").text("Pure data-drag — no island, no wasm. Flick the card at a wall to see elastic bounce-back (bounce=0.35); settles on the 40px grid."),
        ctx.div().class("drag-pen").children(.{
            ctx.div().class("anim-card drag-card").text("drag")
                .draggable(anim.draggable(a, .{
                .bounds = .{ .selector = ".drag-pen" },
                .inertia = .on,
                .bounce = 0.35,
                .snap = .{ .grid = .{ .x = 40, .y = 40 } },
                .toggle_class = "dragging",
            })),
        }),
    });
}

/// ScrollTrigger demo (phase 2): scroll-gated stagger, zero-wasm class
/// reveal, and a pinned scrubbed panel (markers on for DX show-off).
fn containerScrollSection(ctx: *const verve.Context) *verve.Node {
    const anim = verve.anim;
    const a = ctx.alloc();

    // A fixed-height scrollable container. Each card inside reveals when
    // it enters the container's viewport (not the window). `scroller`
    // passes the wire key "sl" so the JS side binds a scroll listener on
    // the container element instead of window.
    const container = ctx.div().id("cscroll-box").class("cscroll-container");
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        _ = container.children(.{ctx.div()
            .class("anim-card cscroll-card")
            .textInt(i + 1)
            .animate(anim.reveal(a, "in-view", .{
            .scroller = "#cscroll-box",
            .start = .{ .trigger = .bottom, .viewport = .bottom },
            .once = true,
        }))});
    }

    return ctx.el("section").class("anim-scroll").children(.{
        ctx.div().class("anim-spacer").ariaHidden(true),
        ctx.h2("Container scroller"),
        ctx.p().class("hint").text("Cards reveal as they scroll into the box — tracked against the container's scrollTop, not the window."),
        container,
        ctx.div().class("anim-spacer").ariaHidden(true),
    });
}

fn scrollSection(ctx: *const verve.Context) *verve.Node {
    const anim = verve.anim;
    const a = ctx.alloc();

    const deck = ctx.div().class("anim-deck");
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        _ = deck.children(.{ctx.div().class("anim-card scard").textInt(i + 1)});
    }

    return ctx.el("section").class("anim-scroll").children(.{
        ctx.div().class("anim-spacer").ariaHidden(true),
        ctx.h2("ScrollTrigger: gated entrance")
            .animate(anim.reveal(a, "in-view", .{
            .start = .{ .viewport = .{ .pct = 85 } },
            .once = true,
        })),
        ctx.p().class("hint").text("Cards play in at 80% viewport, reverse when you scroll back above them. The heading gets a zero-wasm class toggle."),
        deck.animate(anim.from(a, ".scard")
            .opacity(0).y(40)
            .duration(0.5).ease(.out_back)
            .stagger(.{ .each = 0.07 })
            .scrollTrigger(.{
            .start = .{ .viewport = .{ .pct = 80 } },
            .actions = .{ .on_enter = .play, .on_leave_back = .reverse },
        })),
        ctx.div().class("anim-spacer").ariaHidden(true),
        ctx.h2("Scrub + pin"),
        ctx.p().class("hint").text("The panel pins for 150vh while the bar scrubs scroll progress (smoothed, 0.3s). Dashed lines are debug markers."),
        ctx.div().class("anim-pin-panel")
            .children(.{
                ctx.div().class("anim-scrub-bar").ariaHidden(true),
                ctx.p().text("This panel is pinned while the bar scrubs."),
            })
            .animate(anim.to(a, ".anim-scrub-bar")
            .scaleX(1).propFrom("scaleX", 0)
            .duration(1).ease(.linear)
            .scrollTrigger(.{
            .start = .{ .trigger = .top, .viewport = .{ .pct = 20 } },
            .end = .{ .rel_vh = 1.5 },
            .scrub = .{ .smooth = 0.3 },
            .pin = .self,
            .markers = true,
        })),
        ctx.div().class("anim-spacer").ariaHidden(true),
    });
}

pub fn workDetail(ctx: *const verve.Context, slug: []const u8) !*verve.Node {
    // Per-page <head> contributions. The shell drains ctx.head in
    // priority order before emitting the body, so canonical / OG /
    // JSON-LD end up correctly ordered regardless of where they were
    // contributed from.
    try ctx.setTitle(try std.fmt.allocPrint(ctx.alloc(), "Work — {s}", .{slug}));
    try ctx.metaTag(.{ .name = "description", .content = "Work-detail demo for path params + per-page head." });
    try ctx.linkTag(.{ .rel = "canonical", .href = try std.fmt.allocPrint(ctx.alloc(), "https://example.com/work/{s}", .{slug}) });
    try ctx.metaTag(.{ .name = "og:title", .content = slug, .is_property = true, .priority = 40 });
    try ctx.jsonLd(try std.fmt.allocPrint(
        ctx.alloc(),
        "{{\"@context\":\"https://schema.org\",\"@type\":\"CreativeWork\",\"name\":\"{s}\"}}",
        .{slug},
    ));

    return ctx.main_().class("home").children(.{
        ctx.h1("Work Detail"),
        ctx.p().children(.{
            ctx.span().text("Slug: "),
            ctx.code(slug),
        }),
        ctx.p().text("This route uses /work/:slug. The matched parameter is bound to ctx.params[\"slug\"] by the router."),
        ctx.p().children(.{ctx.a("/", "← Home")}),
    }).build();
}

pub fn todoList(ctx: *const verve.Context, items: []const []const u8) !*verve.Node {
    const list = ctx.ul().class("todo-list");
    for (items, 0..) |item_text, i| {
        _ = list.children(.{
            ctx.li().children(.{
                ctx.span().text(item_text),
                ctx.actionForm(.{ .post = "/api/removeTodo", .class = "todo-remove" }).children(.{
                    ctx.input().type_("hidden").name("index").attrFmt("value", "{d}", .{i}),
                    ctx.button("×").type_("submit"),
                }),
            }),
        });
    }

    return ctx.main_().class("home").children(.{
        ctx.h1("Todos"),
        ctx.p().text("Pure server-rendered list. Submissions degrade gracefully without wasm."),
        ctx.actionForm(.{ .post = "/api/addTodo", .class = "todo-form" }).children(.{
            ctx.input().name("text").type_("text").placeholder("Write something to do").required().autofocus(),
            ctx.button("Add").type_("submit"),
        }),
        list,
    }).build();
}

pub fn appShell(ctx: *const verve.Context, outlet: *verve.Node) !*verve.Node {
    return ctx.main_().class("home").children(.{
        ctx.h1("App"),
        ctx.nav().children(.{
            verve.link(ctx, "/app/dashboard", "Dashboard", .{}),
            ctx.span().text(" · "),
            verve.link(ctx, "/app/settings/general", "Settings", .{}),
            ctx.span().text(" · "),
            verve.link(ctx, "/", "← Home", .{}),
        }),
        ctx.el("section").children(.{outlet}),
    }).build();
}

pub fn appDashboard(ctx: *const verve.Context) !*verve.Node {
    return ctx.div().children(.{
        ctx.h2("Dashboard"),
        ctx.p().text("Nested layout demo. /app is a layout route; this is the leaf rendered into ctx.outlet()."),
    }).build();
}

pub fn appSettings(ctx: *const verve.Context, section: []const u8) !*verve.Node {
    return ctx.div().children(.{
        ctx.h2("Settings"),
        ctx.p().children(.{ ctx.span().text("Section: "), ctx.code(section) }),
    }).build();
}

pub fn privatePage(ctx: *const verve.Context) !*verve.Node {
    return ctx.main_().class("home").children(.{
        ctx.h1("Protected page"),
        ctx.p().text("This route is gated by a guard fn — visiting without ?token=... redirects to /counter."),
        ctx.p().children(.{ctx.a("/", "← Home")}),
    }).build();
}

pub fn notFound(ctx: *const verve.Context, path: []const u8) !*verve.Node {
    return ctx.main_().class("home").children(.{
        ctx.h1("404 — Not Found"),
        ctx.p().children(.{
            ctx.span().text("No route for "),
            ctx.code(path),
        }),
        ctx.p().children(.{ctx.a("/", "← Home")}),
    }).build();
}

pub fn errorPage(
    ctx: *const verve.Context,
    status_code: u16,
    status_text: []const u8,
    message: []const u8,
) !*verve.Node {
    return ctx.main_().class("home").children(.{
        ctx.el("h1").textFmt("{d} — {s}", .{ status_code, status_text }),
        ctx.p().text(message),
        ctx.p().children(.{ctx.a("/", "← Home")}),
    }).build();
}

/// verve.gl demo: both /gl canvases wrapped in a single GlDemo island.
/// Two separate stateful islands would produce co-located wasm chunks that
/// overlap in shared linear memory (0x1000 data-segment collision); merging
/// them into one island+chunk avoids that. With JS off the page still
/// renders shell + copy (canvases stay blank).
pub fn glDemo(ctx: *const verve.Context) !*verve.Node {
    const cube_canvas = ctx.div().class("gl-wrap").children(.{
        ctx.el("canvas")
            .attr("data-ref", "glcube-canvas")
            .attr("width", "640")
            .attr("height", "400")
            .attr("style", "width:100%;max-width:640px;aspect-ratio:8/5;display:block;background:#121420;border-radius:8px;"),
    });
    const model_canvas = ctx.div().class("gl-wrap").children(.{
        ctx.el("canvas")
            .attr("data-ref", "glmodel-canvas")
            .attr("width", "640")
            .attr("height", "400")
            .attr("style", "width:100%;max-width:640px;aspect-ratio:8/5;display:block;background:#121420;border-radius:8px;"),
    });

    // Both canvases live inside one GlDemo island: co-located stateful wasm
    // chunks would overlap at the same 0x1000 data-segment base in shared
    // linear memory, so they must be driven by a single chunk.
    const demo_inner = ctx.div().children(.{
        ctx.section().class("card").children(.{
            ctx.h2("Unlit cube"),
            cube_canvas,
        }),
        ctx.section().class("card").children(.{
            ctx.h2("Asset pipeline — PBR + image-based lighting"),
            ctx.p().text("vmesh + prefiltered .venv fetched via gl_load; readers parse " ++
                "views; Cook-Torrance PBR under image-based lighting with direct lights."),
            model_canvas,
        }),
    });
    const demo_island = verve.island(ctx, .{ .name = "GlDemo" }, demo_inner);

    return ctx.main_().class("home").children(.{
        ctx.h1("verve.gl"),
        ctx.p().text("Rotating unlit cube — scene graph, culling state, and a " ++
            "binary draw-command stream all computed in Zig/wasm; JS is a " ++
            "dumb WebGL2 interpreter over linear memory."),
        demo_island,
    });
}

/// verve.gl P10 WebGPU demo — /gl-webgpu. An unlit vertex-color cube uploaded
/// and driven through the WebGPU backend (gl_start_gpu) instead of WebGL2. The
/// same Zig-computed binary command stream feeds a WebGPU interpreter. Requires
/// a WebGPU-capable browser; degrades to the poster/blank canvas otherwise.
pub fn glWebgpu(ctx: *const verve.Context) !*verve.Node {
    const canvas = ctx.div().class("gl-wrap").children(.{
        ctx.el("canvas")
            .attr("data-ref", "glwebgpu-canvas")
            .attr("width", "640")
            .attr("height", "400")
            .attr("style", "width:100%;max-width:640px;aspect-ratio:8/5;display:block;background:#121420;border-radius:8px;"),
    });

    const inner = ctx.section().class("card").children(.{
        ctx.h2("Unlit cube — WebGPU backend"),
        canvas,
    });
    const demo_island = verve.island(ctx, .{ .name = "GlWebgpu" }, inner);

    return ctx.main_().class("home").children(.{
        ctx.h1("verve.gl — WebGPU"),
        ctx.p().text("The same Zig-computed binary draw-command stream as /gl, " ++
            "but interpreted by the WebGPU backend (P10) instead of WebGL2. " ++
            "Requires a WebGPU-capable browser; degrades to a blank canvas " ++
            "otherwise."),
        demo_island,
    });
}

/// verve.gl P10 WebGPU PBR scene — /gl-scene-webgpu (slices 2a + 2b + 2c). A
/// textured Cook-Torrance cube on a ground plane, lit by a directional light +
/// image-based lighting (a prefiltered `.venv` environment) and casting a PCF
/// shadow, all driven through the WebGPU backend: the WGSL PBR + depth shaders,
/// stride-48 meshes, material/lights, IBL cubemaps, and the shadow depth pass all
/// computed in Zig/wasm. Requires a WebGPU-capable browser; degrades to a blank
/// canvas.
pub fn glSceneWebgpu(ctx: *const verve.Context) !*verve.Node {
    const canvas = ctx.div().class("gl-wrap").children(.{
        ctx.el("canvas")
            .attr("data-ref", "glscenewebgpu-canvas")
            .attr("width", "640")
            .attr("height", "400")
            .attr("style", "width:100%;max-width:640px;aspect-ratio:8/5;display:block;background:#121420;border-radius:8px;"),
    });

    const inner = ctx.section().class("card").children(.{
        ctx.h2("PBR cube + IBL + shadow — WebGPU backend"),
        canvas,
    });
    const demo_island = verve.island(ctx, .{ .name = "GlSceneWebgpu" }, inner);

    return ctx.main_().class("home").children(.{
        ctx.h1("verve.gl — WebGPU PBR"),
        ctx.p().text("A textured Cook-Torrance cube on a ground plane rendered " ++
            "through the WebGPU backend (P10 slices 2a + 2b + 2c): WGSL PBR + depth " ++
            "shaders, stride-48 meshes, a directional light plus image-based " ++
            "lighting from a prefiltered .venv environment, and a PCF shadow cast " ++
            "from a depth pass — all from the same Zig-computed command stream. " ++
            "Requires a WebGPU-capable browser; degrades to a blank canvas otherwise."),
        demo_island,
    });
}

/// verve.gl skinning demo — /gl-skin. A GPU-skinned rigged bar deformed by a
/// fixed bent pose, rendered through either backend (WebGPU when available, else
/// WebGL2). The GlSkin chunk fetches skinbar.vmesh and drives the skinned PBR
/// program; the SSR marker just places the canvas + island.
pub fn glSkin(ctx: *const verve.Context) !*verve.Node {
    const canvas = ctx.div().class("gl-wrap").children(.{
        ctx.el("canvas")
            .attr("data-ref", "glskin-canvas")
            .attr("width", "640")
            .attr("height", "400")
            .attr("style", "width:100%;max-width:640px;aspect-ratio:8/5;display:block;background:#121420;border-radius:8px;"),
    });

    // Controls (slice 3) — wired to the GlSkin chunk's no-arg exports via
    // z-on-click. Must live INSIDE the island subtree so events route to it.
    const controls = ctx.div().class("gl-controls").children(.{
        ctx.el("button").attr("z-on-click", "glskin_clip0").text("Bend"),
        ctx.el("button").attr("z-on-click", "glskin_clip1").text("Twist"),
        ctx.el("button").attr("z-on-click", "glskin_clip2").text("Smooth"),
        ctx.el("button").attr("z-on-click", "glskin_pause").text("Pause"),
        ctx.el("button").attr("z-on-click", "glskin_play").text("Play"),
        ctx.el("button").attr("z-on-click", "glskin_speed_half").text("0.5×"),
        ctx.el("button").attr("z-on-click", "glskin_speed_1x").text("1×"),
        ctx.el("button").attr("z-on-click", "glskin_speed_2x").text("2×"),
        ctx.el("button").attr("z-on-click", "glskin_loop").text("Loop"),
        ctx.el("button").attr("z-on-click", "glskin_once").text("Once"),
        ctx.el("button").attr("z-on-click", "glskin_pingpong").text("Ping-Pong"),
        ctx.el("button").attr("z-on-click", "glskin_blend_mix").text("Mix"),
        ctx.el("button").attr("z-on-click", "glskin_blend_add").text("Additive"),
        ctx.el("button").attr("z-on-click", "glskin_mask_all").text("Mask: All"),
        ctx.el("button").attr("z-on-click", "glskin_mask_upper").text("Mask: Upper"),
        ctx.el("button").attr("z-on-click", "glskin_freeze").text("Freeze"),
        ctx.el("button").attr("z-on-click", "glskin_unfreeze").text("Unfreeze"),
    });

    // Scrub track: drag to set clip time (pointer-drag → glskin_scrub_* exports).
    // Inside the island subtree so events route to this chunk. touch-action:none
    // so touch-drag scrubs instead of scrolling.
    const track = ctx.div().class("gl-scrub")
        .attr("data-ref", "glskin-track")
        .attr("z-on-pointerdown", "glskin_scrub_down")
        .attr("z-on-pointermove", "glskin_scrub_move")
        .attr("z-on-pointerup", "glskin_scrub_up")
        .attr("style", "width:100%;max-width:640px;height:18px;margin-top:6px;background:#222636;border-radius:4px;cursor:ew-resize;touch-action:none;");

    // Mix track: drag 0→100% to blend the current clip with the next clip
    // (pointer-drag → glskin_mix_* exports). Inside the island subtree.
    const mix = ctx.div().class("gl-mix")
        .attr("data-ref", "glskin-mix")
        .attr("z-on-pointerdown", "glskin_mix_down")
        .attr("z-on-pointermove", "glskin_mix_move")
        .attr("z-on-pointerup", "glskin_mix_up")
        .attr("style", "width:100%;max-width:640px;height:18px;margin-top:6px;background:#2a2236;border-radius:4px;cursor:ew-resize;touch-action:none;");

    const inner = ctx.section().class("card").children(.{
        ctx.h2("Skinned bar — multiple clips + controls"),
        canvas,
        controls,
        track,
        mix,
    });
    const demo_island = verve.island(ctx, .{ .name = "GlSkin" }, inner);

    return ctx.main_().class("home").children(.{
        ctx.h1("verve.gl — skeletal skinning"),
        ctx.p().text("A rigged bar GPU-skinned by a 3-joint skeleton, playing baked " ++
            "animation clips. Buttons switch clip (Bend / Twist), pause/play, and set " ++
            "speed. Vertices carry joint indices + weights; per frame the selected " ++
            "clip's keyframe tracks are sampled into a bone-matrix palette and pushed " ++
            "via set_bones, and the skinned PBR shader (variant_pbr | variant_skinned) " ++
            "blends the bone matrices per vertex. Renders through WebGPU when " ++
            "available, else WebGL2."),
        demo_island,
    });
}

/// verve.gl combined skinned+morph demo — /gl-skin-morph.
/// Renders a GPU-skinned bar that is simultaneously morphed (Bulge target) using
/// `variant_pbr | variant_skinned | variant_morph`. The morph deltas are applied
/// to local pos/normal FIRST, then the skin matrix transforms the morphed locals
/// (glTF-correct order). The morph weight oscillates 0→1→0 so the bulge is
/// continuously visible; the bar also bends via a slow jmid rotation, making
/// both skin and morph effects simultaneously observable. Renders through WebGPU
/// when available, else WebGL2.
pub fn glSkinMorph(ctx: *const verve.Context) !*verve.Node {
    const canvas = ctx.div().class("gl-wrap").children(.{
        ctx.el("canvas")
            .attr("data-ref", "glskinmorph-canvas")
            .attr("width", "640")
            .attr("height", "400")
            .attr("style", "width:100%;max-width:640px;aspect-ratio:8/5;display:block;background:#070810;border-radius:8px;"),
    });

    const controls = ctx.div().class("gl-controls").children(.{
        ctx.el("button").attr("z-on-click", "glskinmorph_freeze").text("Freeze"),
    });

    const inner = ctx.div().children(.{ canvas, controls });
    const demo_island = verve.island(ctx, .{ .name = "GlSkinMorph" }, inner);

    return ctx.main_().class("home").children(.{
        ctx.h1("verve.gl — combined skinned+morph"),
        ctx.p().text("A rigged bar rendered with variant_pbr | variant_skinned | variant_morph: " ++
            "morph deltas (Bulge target) applied to local pos/normal first, then the skin " ++
            "matrix transforms the morphed locals. The morph weight oscillates 0→1→0 (3 s " ++
            "period) while the bar bends via a jmid rotation, confirming both effects " ++
            "simultaneously in WebGL2 and WebGPU."),
        demo_island,
    });
}

/// verve.gl post-processing demo — /gl-post.
/// Renders a bright emissive PBR cube with bloom + FXAA post-processing.
/// The GlPost chunk uses `variant_pbr | variant_emissive | variant_linear_output`
/// so the scene renders to a linear HDR offscreen target; the post pipeline
/// runs bloom (bright-pass + blur chain) and FXAA, then composites to canvas.
/// Toggle buttons wire to `glpost_toggle_bloom` / `glpost_toggle_fxaa` exports.
/// Renders through WebGPU when available, else WebGL2.
pub fn glPost(ctx: *const verve.Context) !*verve.Node {
    const canvas = ctx.div().class("gl-wrap").children(.{
        ctx.el("canvas")
            .attr("data-ref", "glpost-canvas")
            .attr("width", "640")
            .attr("height", "400")
            .attr("style", "width:100%;max-width:640px;aspect-ratio:8/5;display:block;background:#0a0b0f;border-radius:8px;"),
    });

    // Controls wired to the GlPost chunk's no-arg exports via z-on-click.
    // Must live INSIDE the island subtree so events route to this chunk.
    const controls = ctx.div().class("gl-controls").children(.{
        ctx.el("button").attr("z-on-click", "glpost_toggle_bloom").text("Toggle Bloom"),
        ctx.el("button").attr("z-on-click", "glpost_toggle_fxaa").text("Toggle FXAA"),
        ctx.el("button").attr("z-on-click", "glpost_toggle_freeze").text("Freeze"),
        // Image-quality slice 1: G-buffer prepass debug viz.
        ctx.el("button").attr("z-on-click", "glpost_toggle_gbuffer").text("Toggle G-buffer"),
        ctx.el("button").attr("z-on-click", "glpost_toggle_gbuffer_mode").text("G-buffer Mode (normals/depth)"),
    });

    const inner = ctx.section().class("card").children(.{
        ctx.h2("Emissive cube — bloom + FXAA"),
        canvas,
        controls,
    });
    const demo_island = verve.island(ctx, .{ .name = "GlPost" }, inner);

    return ctx.main_().class("home").children(.{
        ctx.h1("verve.gl — post-processing"),
        ctx.p().text("A bright emissive PBR cube rendered through the full post-processing " ++
            "pipeline. The scene shader uses variant_linear_output to emit linear HDR " ++
            "(no in-shader tonemap); beginPostProcess/endPostProcess runs a bloom " ++
            "bright-pass + two-pass Gaussian blur, a composite pass with ACES tonemap, " ++
            "and optional FXAA anti-aliasing. Renders through WebGPU when available, " ++
            "else WebGL2. Use the toggle buttons to compare bloom on/off and FXAA on/off."),
        demo_island,
    });
}

/// verve.gl tone-mapping + vignette demo — /gl-tonemap (image-quality slice 2).
/// Renders a bright emissive PBR cube through a selectable composite tone-mapper.
/// Cycle Tone-mapper cycles through 6 operators (Linear/Reinhard/Reinhard-ext/ACES/AgX/Uncharted2).
/// Vignette toggle adds a smoothstep corner-darkening pass after tone-mapping.
/// Default operator is ACES so the initial appearance matches /gl-post.
pub fn glTonemap(ctx: *const verve.Context) !*verve.Node {
    const canvas = ctx.div().class("gl-wrap").children(.{
        ctx.el("canvas")
            .attr("data-ref", "gltonemap-canvas")
            .attr("width", "640")
            .attr("height", "400")
            .attr("style", "width:100%;max-width:640px;aspect-ratio:8/5;display:block;background:#0a0b0f;border-radius:8px;"),
    });

    // Controls wired to the GlTonemap chunk's no-arg exports via z-on-click.
    // Must live INSIDE the island subtree so events route to this chunk.
    const controls = ctx.div().class("gl-controls").children(.{
        ctx.el("button").attr("z-on-click", "gltonemap_cycle_tonemap").text("Cycle Tone-mapper"),
        ctx.el("button").attr("z-on-click", "gltonemap_toggle_vignette").text("Toggle Vignette"),
        ctx.el("button").attr("z-on-click", "gltonemap_freeze").text("Freeze"),
    });

    const inner = ctx.section().class("card").children(.{
        ctx.h2("Emissive cube — selectable tone-mapper + vignette"),
        canvas,
        controls,
    });
    const demo_island = verve.island(ctx, .{ .name = "GlTonemap" }, inner);

    return ctx.main_().class("home").children(.{
        ctx.h1("verve.gl — tone-mapping"),
        ctx.p().text("A bright emissive PBR cube rendered through the full post-processing " ++
            "pipeline with a selectable tone-mapping operator. The Cycle Tone-mapper button " ++
            "steps through: Linear (clips to white), Reinhard (soft rolloff), " ++
            "Reinhard-extended (brighter shoulder), ACES (filmic S-curve, default), " ++
            "AgX (neutral, perceptually uniform), Uncharted2/Hable (crushed blacks, filmic). " ++
            "Toggle Vignette darkens the corners with a smoothstep falloff applied AFTER " ++
            "tone-mapping. Default (ACES) reproduces the /gl-post appearance exactly. " ++
            "Renders through WebGPU when available, else WebGL2."),
        demo_island,
    });
}

/// verve.gl SSAO demo — /gl-ssao (image-quality slice 3).
/// Renders a floor with cubes resting on it through the G-buffer prepass → SSAO
/// → composite chain. SSAO darkens cube-cube gaps and cube-floor contacts.
/// Toggle SSAO compares the lit scene with and without ambient occlusion; Toggle
/// AO View blits the raw AO buffer (dark in crevices, white on open surfaces).
/// Renders through WebGPU when available, else WebGL2.
pub fn glSsao(ctx: *const verve.Context) !*verve.Node {
    const canvas = ctx.div().class("gl-wrap").children(.{
        ctx.el("canvas")
            .attr("data-ref", "glssao-canvas")
            .attr("width", "640")
            .attr("height", "400")
            .attr("style", "width:100%;max-width:640px;aspect-ratio:8/5;display:block;background:#0a0b0f;border-radius:8px;"),
    });

    // Controls wired to the GlSsao chunk's no-arg exports via z-on-click.
    // Must live INSIDE the island subtree so events route to this chunk.
    const controls = ctx.div().class("gl-controls").children(.{
        ctx.el("button").attr("z-on-click", "glssao_toggle").text("Toggle SSAO"),
        ctx.el("button").attr("z-on-click", "glssao_toggle_view").text("Toggle AO View"),
        ctx.el("button").attr("z-on-click", "glssao_freeze").text("Freeze"),
    });

    const inner = ctx.section().class("card").children(.{
        ctx.h2("Cubes on a floor — screen-space ambient occlusion"),
        canvas,
        controls,
    });
    const demo_island = verve.island(ctx, .{ .name = "GlSsao" }, inner);

    return ctx.main_().class("home").children(.{
        ctx.h1("verve.gl — SSAO"),
        ctx.p().text("Several cubes resting on a floor, rendered through the depth + " ++
            "view-space-normal G-buffer prepass and a screen-space ambient occlusion " ++
            "pass. SSAO reconstructs view-space position from the G-buffer (inv_proj), " ++
            "samples a 16-point hemisphere kernel around each fragment, re-projects each " ++
            "sample (proj), and counts occluded samples — the result is blurred and " ++
            "multiplied into the scene before bloom + tonemapping. Toggle SSAO compares " ++
            "the contact shadows with and without AO; Toggle AO View shows the raw AO " ++
            "buffer (dark in crevices, white on open surfaces). Renders through WebGPU " ++
            "when available, else WebGL2."),
        demo_island,
    });
}

/// verve.gl SSR demo — /gl-ssr (image-quality slice 4).
/// Renders a reflective floor with bright emissive cubes floating above it through
/// the G-buffer prepass → scene → SSR → composite chain. SSR ray-marches the
/// reflected view vector against the G-buffer and adds the inverted reflection of
/// the cubes into the floor. Toggle SSR compares the reflective vs matte floor;
/// Toggle View blits the raw SSR target (scene + reflections). WebGPU when
/// available, else WebGL2.
pub fn glSsr(ctx: *const verve.Context) !*verve.Node {
    const canvas = ctx.div().class("gl-wrap").children(.{
        ctx.el("canvas")
            .attr("data-ref", "glssr-canvas")
            .attr("width", "640")
            .attr("height", "400")
            .attr("style", "width:100%;max-width:640px;aspect-ratio:8/5;display:block;background:#0a0b0f;border-radius:8px;"),
    });

    // Controls wired to the GlSsr chunk's no-arg exports via z-on-click.
    // Must live INSIDE the island subtree so events route to this chunk.
    const controls = ctx.div().class("gl-controls").children(.{
        ctx.el("button").attr("z-on-click", "glssr_toggle").text("Toggle SSR"),
        ctx.el("button").attr("z-on-click", "glssr_toggle_view").text("Toggle View"),
        ctx.el("button").attr("z-on-click", "glssr_freeze").text("Freeze"),
    });

    const inner = ctx.section().class("card").children(.{
        ctx.h2("Reflective floor — screen-space reflections"),
        canvas,
        controls,
    });
    const demo_island = verve.island(ctx, .{ .name = "GlSsr" }, inner);

    return ctx.main_().class("home").children(.{
        ctx.h1("verve.gl — SSR"),
        ctx.p().text("Bright emissive cubes floating above a dark, smooth floor, rendered " ++
            "through the depth + view-space-normal G-buffer prepass and a screen-space " ++
            "reflection pass. SSR reconstructs view-space position from the G-buffer " ++
            "(inv_proj), reflects the view vector around the surface normal, ray-marches " ++
            "that reflection in screen space (re-projecting each step with proj), samples " ++
            "the lit scene at hits, and adds the reflection — modulated by a uniform " ++
            "strength and a Schlick Fresnel term — into the scene before bloom + " ++
            "tonemapping. Toggle SSR compares the reflective floor (inverted reflections " ++
            "of the cubes appear below the surface) with a matte floor; Toggle View shows " ++
            "the raw scene + reflections target. GLOBAL SSR — material-aware / " ++
            "roughness-weighted reflections are deferred (the G-buffer has no roughness " ++
            "channel; it needs MRT). Renders through WebGPU when available, else WebGL2."),
        demo_island,
    });
}

/// verve.gl DOF demo — /gl-dof (image-quality slice 5).
/// Renders a row of bright emissive cubes receding from near to far through the
/// G-buffer prepass → scene → DOF → composite chain. The DOF pass blurs the scene
/// and composites sharp vs blurred per pixel by a circle-of-confusion derived from
/// the cube's linear view-space depth relative to a focus distance. Toggle DOF
/// compares the depth-of-field scene with the all-sharp scene; Focus Near/Far sweep
/// the sharp band through the depth range; Toggle View blits the raw DOF target.
/// WebGPU when available, else WebGL2.
pub fn glDof(ctx: *const verve.Context) !*verve.Node {
    const canvas = ctx.div().class("gl-wrap").children(.{
        ctx.el("canvas")
            .attr("data-ref", "gldof-canvas")
            .attr("width", "640")
            .attr("height", "400")
            .attr("style", "width:100%;max-width:640px;aspect-ratio:8/5;display:block;background:#0a0b0f;border-radius:8px;"),
    });

    // Controls wired to the GlDof chunk's no-arg exports via z-on-click.
    // Must live INSIDE the island subtree so events route to this chunk.
    const controls = ctx.div().class("gl-controls").children(.{
        ctx.el("button").attr("z-on-click", "gldof_toggle").text("Toggle DOF"),
        ctx.el("button").attr("z-on-click", "gldof_focus_near").text("Focus Near"),
        ctx.el("button").attr("z-on-click", "gldof_focus_far").text("Focus Far"),
        ctx.el("button").attr("z-on-click", "gldof_toggle_view").text("Toggle View"),
        ctx.el("button").attr("z-on-click", "gldof_freeze").text("Freeze"),
    });

    const inner = ctx.section().class("card").children(.{
        ctx.h2("Receding cubes — depth of field"),
        canvas,
        controls,
    });
    const demo_island = verve.island(ctx, .{ .name = "GlDof" }, inner);

    return ctx.main_().class("home").children(.{
        ctx.h1("verve.gl — DOF"),
        ctx.p().text("A row of bright emissive cubes receding from near to far, rendered " ++
            "through the depth + view-space-normal G-buffer prepass and a depth-of-field " ++
            "pass. DOF blurs the scene with two separable Gaussian passes, then composites " ++
            "the sharp and blurred images per pixel by a circle-of-confusion: " ++
            "coc = clamp(|depth − focus_distance| / focal_range, 0, 1) × max_blur, where " ++
            "depth is the linear view-space depth read straight from the G-buffer alpha " ++
            "(no matrices needed). out = mix(sharp, blurred, coc), fed into the scene before " ++
            "bloom + tonemapping. Toggle DOF compares the depth-of-field scene (cubes far " ++
            "from the focus band blur) with the all-sharp scene; Focus Near / Focus Far " ++
            "sweep the sharp band through the depth range; Toggle View shows the raw DOF " ++
            "target. Renders through WebGPU when available, else WebGL2."),
        demo_island,
    });
}

/// verve.gl Weighted-Blended OIT demo — /gl-oit (image-quality slice 6, FINAL).
/// An opaque backdrop of lit cubes plus several overlapping translucent quads
/// (alpha ~0.5) at varying depth. WBOIT accumulates every transparent fragment
/// with NO depth sort into an additive accum buffer + a multiplicative revealage
/// buffer, then a fullscreen resolve composites them over the opaque scene. The
/// result is order-INDEPENDENT — rotating the camera does not change the blend.
/// Toggle WBOIT compares the order-independent blend with naive alpha-over (which
/// pops as the draw order vs camera order diverges); Freeze pins the orbit.
/// WebGPU fills both buffers in one MRT pass; WebGL2 in two single-target passes.
pub fn glOit(ctx: *const verve.Context) !*verve.Node {
    const canvas = ctx.div().class("gl-wrap").children(.{
        ctx.el("canvas")
            .attr("data-ref", "gloit-canvas")
            .attr("width", "640")
            .attr("height", "400")
            .attr("style", "width:100%;max-width:640px;aspect-ratio:8/5;display:block;background:#0a0b0f;border-radius:8px;"),
    });

    // Controls wired to the GlOit chunk's no-arg exports via z-on-click.
    const controls = ctx.div().class("gl-controls").children(.{
        ctx.el("button").attr("z-on-click", "gloit_toggle").text("Toggle WBOIT"),
        ctx.el("button").attr("z-on-click", "gloit_freeze").text("Freeze"),
    });

    const inner = ctx.section().class("card").children(.{
        ctx.h2("Overlapping translucent layers — order-independent transparency"),
        canvas,
        controls,
    });
    const demo_island = verve.island(ctx, .{ .name = "GlOit" }, inner);

    return ctx.main_().class("home").children(.{
        ctx.h1("verve.gl — Weighted-Blended OIT"),
        ctx.p().text("An opaque backdrop of lit cubes plus several overlapping translucent " ++
            "quads (alpha ~0.5) at varying depth. Weighted-Blended OIT renders the transparent " ++
            "geometry ONCE with no depth sort into two buffers — an additive accumulation buffer " ++
            "(accum += vec4(color·alpha, alpha)·weight) and a multiplicative revealage buffer " ++
            "(reveal ·= 1−alpha) — then a fullscreen resolve composites them over the opaque " ++
            "scene: avg = accum.rgb/max(accum.a, 1e-5); out = avg·(1−reveal) + opaque·reveal. " ++
            "The blend is ORDER-INDEPENDENT: rotate the camera and the overlap stays stable. " ++
            "Toggle WBOIT switches to naive alpha-over blending, which pops and flickers as the " ++
            "draw order diverges from the camera order. WebGPU fills both buffers in a single " ++
            "MRT pass with per-target blend; WebGL2 (no per-attachment blend) replays the " ++
            "geometry in two single-target passes — same resolve, same image."),
        demo_island,
    });
}

/// verve.gl billboard / points demo — /gl-points (Slice 1 — Points/Sprites).
/// A 2000-particle upward-drift cloud rendered as round soft additive points
/// (variant_billboard, tex_handle 0, flags bit0=sizeAttenuation + bit1=round)
/// plus one textured disc sprite above the cloud (sizeAttenuation OFF, alpha blend,
/// tex = procedural 16×16 golden/white disc). Demonstrates both billboard paths.
pub fn glPoints(ctx: *const verve.Context) !*verve.Node {
    const canvas = ctx.div().class("gl-wrap").children(.{
        ctx.el("canvas")
            .attr("data-ref", "glpoints-canvas")
            .attr("width", "640")
            .attr("height", "400")
            .attr("style", "width:100%;max-width:640px;aspect-ratio:8/5;display:block;background:#000;border-radius:8px;"),
    });

    // Controls wired to the GlPoints chunk's no-arg exports via z-on-click.
    // Must live INSIDE the island subtree so events route to this chunk.
    const controls = ctx.div().class("gl-controls").children(.{
        ctx.el("button").attr("z-on-click", "glpoints_toggle_attenuation").text("Toggle Attenuation"),
        ctx.el("button").attr("z-on-click", "glpoints_toggle_additive").text("Toggle Additive"),
        ctx.el("button").attr("z-on-click", "glpoints_freeze").text("Freeze"),
        ctx.el("button").attr("z-on-click", "glpoints_unfreeze").text("Unfreeze"),
    });

    const inner = ctx.section().class("card").children(.{
        ctx.h2("Particle cloud + sprite — billboard primitive"),
        canvas,
        controls,
    });
    const demo_island = verve.island(ctx, .{ .name = "GlPoints" }, inner);

    return ctx.main_().class("home").children(.{
        ctx.h1("verve.gl — billboards (Points / Sprites)"),
        ctx.p().text("A 2000-particle upward-drift cloud rendered as camera-facing " ++
            "billboard quads (variant_billboard, wire tag 42). Particles use " ++
            "sizeAttenuation ON (world-unit radius) + round discard (soft disc FS) " ++
            "with additive blend — classic GPU particle system. The golden disc " ++
            "above the cloud is a single textured sprite: sizeAttenuation OFF " ++
            "(screen-constant size) and normal alpha blend, demonstrating the " ++
            "SpriteMaterial path. Both backends: WebGPU (WGSL) and WebGL2 (GLSL)."),
        demo_island,
    });
}

/// verve.gl fat-line demo — /gl-lines (Slice 2 — Fat Lines).
/// Animated Lissajous trail (63 segments, alpha fade, state_depth_test|state_blend)
/// and a static opaque wireframe cube (12 edges, state_depth_test). Both rendered
/// via `Encoder.drawLines` (wire tag 43, variant_fatline). Width-step controls,
/// worldUnits toggle, freeze. Canvas `data-ref="gllines-canvas"`.
pub fn glLines(ctx: *const verve.Context) !*verve.Node {
    const canvas = ctx.div().class("gl-wrap").children(.{
        ctx.el("canvas")
            .attr("data-ref", "gllines-canvas")
            .attr("width", "640")
            .attr("height", "400")
            .attr("style", "width:100%;max-width:640px;aspect-ratio:8/5;display:block;background:#000;border-radius:8px;"),
    });

    // Controls wired to the GlLines chunk's no-arg exports via z-on-click.
    // Must live INSIDE the island subtree so events route to this chunk.
    const controls = ctx.div().class("gl-controls").children(.{
        ctx.el("button").attr("z-on-click", "gllines_width_up").text("Width +"),
        ctx.el("button").attr("z-on-click", "gllines_width_down").text("Width -"),
        ctx.el("button").attr("z-on-click", "gllines_toggle_worldunits").text("Toggle World Units"),
        ctx.el("button").attr("z-on-click", "gllines_freeze").text("Freeze"),
        ctx.el("button").attr("z-on-click", "gllines_unfreeze").text("Unfreeze"),
    });

    const inner = ctx.section().class("card").children(.{
        ctx.h2("Animated trail + wireframe cube — fat-line primitive"),
        canvas,
        controls,
    });
    const demo_island = verve.island(ctx, .{ .name = "GlLines" }, inner);

    return ctx.main_().class("home").children(.{
        ctx.h1("verve.gl — fat lines"),
        ctx.p().text("An animated Lissajous-curve trail (63 segments, alpha-fading " ++
            "from transparent tail to opaque head) and a static wireframe cube " ++
            "(12 edges, opaque) rendered via Encoder.drawLines (wire tag 43, " ++
            "variant_fatline). Screen-space width is pixel-constant at any depth. " ++
            "Toggle World Units to see perspective-shrink; Freeze pins the orbit " ++
            "camera while the trail keeps animating. Both backends: WebGPU (WGSL) " ++
            "and WebGL2 (GLSL)."),
        demo_island,
    });
}

/// verve.gl decal demo — /gl-decals (Slice 3 — Decals).
/// UV sphere (variant_pbr) with a crosshair/ring decal (variant_decal, wire
/// tag 44) projected via `gl.decal.projectDecal`. The decal conforms to the
/// sphere curvature. Move/grow/shrink re-project on demand; freeze pins orbit.
/// Canvas `data-ref="gldecals-canvas"`.
pub fn glDecals(ctx: *const verve.Context) !*verve.Node {
    const canvas = ctx.div().class("gl-wrap").children(.{
        ctx.el("canvas")
            .attr("data-ref", "gldecals-canvas")
            .attr("width", "640")
            .attr("height", "400")
            .attr("style", "width:100%;max-width:640px;aspect-ratio:8/5;display:block;background:#000;border-radius:8px;"),
    });

    // Controls wired to the GlDecals chunk's no-arg exports via z-on-click.
    // Must live INSIDE the island subtree so events route to this chunk.
    const controls = ctx.div().class("gl-controls").children(.{
        ctx.el("button").attr("z-on-click", "gldecals_move_left").text("← Left"),
        ctx.el("button").attr("z-on-click", "gldecals_move_right").text("Right →"),
        ctx.el("button").attr("z-on-click", "gldecals_move_up").text("↑ Up"),
        ctx.el("button").attr("z-on-click", "gldecals_move_down").text("↓ Down"),
        ctx.el("button").attr("z-on-click", "gldecals_grow").text("Grow"),
        ctx.el("button").attr("z-on-click", "gldecals_shrink").text("Shrink"),
        ctx.el("button").attr("z-on-click", "gldecals_freeze").text("Freeze"),
        ctx.el("button").attr("z-on-click", "gldecals_unfreeze").text("Unfreeze"),
    });

    const inner = ctx.section().class("card").children(.{
        ctx.h2("UV sphere + projected decal — decal primitive"),
        canvas,
        controls,
    });
    const demo_island = verve.island(ctx, .{ .name = "GlDecals" }, inner);

    return ctx.main_().class("home").children(.{
        ctx.h1("verve.gl — decals"),
        ctx.p().text("A procedural UV sphere rendered with the PBR shader " ++
            "(variant_pbr) and a crosshair/ring decal (variant_decal, " ++
            "wire tag 44) projected via gl.decal.projectDecal. The decal " ++
            "conforms to the sphere curvature — its basis forward vector equals " ++
            "the sphere normal at the placement point. Move/grow/shrink re-project " ++
            "on demand (dirty flag). Depth bias is applied by the bridge so the " ++
            "coplanar overlay wins the z-test without z-fighting. Both backends: " ++
            "WebGPU (WGSL) and WebGL2 (GLSL)."),
        demo_island,
    });
}

/// verve.gl declarative scene demo — /gl-scene.
/// Uses the GlSceneBuilder fluent API (ctx.glScene → chain → .build()).
/// Picking: `.onPickExport("Cube", "verve:glpick")` (P8) wires the cube to a
/// DOM CustomEvent instead of a server closure id — clicking the cube
/// dispatches `verve:glpick` (detail.name = "Cube") from the canvas, which any
/// page JS can `addEventListener` for. No closure-id mechanism needed.
pub fn glScenePage(ctx: *const verve.Context) !*verve.Node {
    const anim = verve.anim;
    const a = ctx.alloc();

    // scrub(true): builder owns the 300vh scroll section + sticky wrapper
    // internally so that `queryRef("glscene-scroll-section")` resolves to the
    // vid-suffixed ref inside the island. autoRotate is zeroed automatically
    // when scrub is on (scroll drives yaw; continuous spin would conflict).
    const scene = ctx.glScene(.{
        .src = "/gl/demo.vmesh",
        .env = "/gl/studio.venv",
        .poster = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='640' height='400' viewBox='0 0 640 400'%3E%3Crect width='640' height='400' rx='8' fill='%23121420'/%3E%3Ctext x='320' y='215' font-family='system-ui' font-size='48' font-weight='700' fill='%23f5f5f5' text-anchor='middle'%3E3D%3C/text%3E%3C/svg%3E",
    })
        .camera(.{ .distance = 4, .pitch = 0.3, .yaw = 0.6 })
        .light(.{ .dir = .{ -0.4, -0.7, -0.6 }, .intensity = 3.0 })
        .onPickExport("Cube", "verve:glpick")
        .scrub(true)
        .build();

    // SSR scroll-driven camera dolly (P6 slot-0 path): "camera.distance" is in
    // the static (no-reader) gl-target vocabulary, so it resolves server-side
    // at comptime — `orelse unreachable` is a const-assert on a frozen literal.
    const dolly_id = comptime (verve.gl.anim_target.resolvePathStatic("camera.distance") orelse unreachable);

    // SSR DEFERRED targets: material:/node: need the vmesh name table (only on
    // the client), so SSR bakes the comptime-pure {kind, field, name_hash} and
    // the bridge resolves name_hash → submesh index on the first tick. The
    // placeholder id carries kind+field with submesh bits 0.
    const metallic = comptime (verve.gl.anim_target.resolvePathStaticDeferred("material:Cube.metallic") orelse unreachable);
    const roty = comptime (verve.gl.anim_target.resolvePathStaticDeferred("node:Cube.rotationY") orelse unreachable);
    const transy = comptime (verve.gl.anim_target.resolvePathStaticDeferred("node:Cube.translateY") orelse unreachable);
    const sclx = comptime (verve.gl.anim_target.resolvePathStaticDeferred("node:Cube.scaleX") orelse unreachable);
    const basecol = comptime (verve.gl.anim_target.resolvePathStaticDeferred("material:Cube.baseColorR") orelse unreachable);
    const alpha = comptime (verve.gl.anim_target.resolvePathStaticDeferred("material:Cube.baseColorA") orelse unreachable);
    const metallic_ph = comptime verve.gl.anim_target.encode(metallic.kind, 0, metallic.field);
    const roty_ph = comptime verve.gl.anim_target.encode(roty.kind, 0, roty.field);
    const transy_ph = comptime verve.gl.anim_target.encode(transy.kind, 0, transy.field);
    const sclx_ph = comptime verve.gl.anim_target.encode(sclx.kind, 0, sclx.field);
    const basecol_ph = comptime verve.gl.anim_target.encode(basecol.kind, 0, basecol.field);
    const alpha_ph = comptime verve.gl.anim_target.encode(alpha.kind, 0, alpha.field);

    // SSR dolly tween: setter slot 0 = the page-default gl setter the bridge
    // resolves at hydration. Targets are disjoint from the island's scrub
    // timeline (island = yaw/roughness/rotationX/emissiveR; SSR = distance +
    // deferred metallic + deferred rotationY + deferred translateY + deferred
    // scaleX + deferred baseColorR + deferred baseColorA) so writes never collide. Note:
    // translateY/scaleX are absolute overwrites (not delta) and non-uniform
    // scale makes cross-node pick-t approximate when multiple node targets share
    // the same scroll range. The tween is hung on a wrapper that CONTAINS the
    // island's 300vh section so the ScrollTrigger selector (SSR cannot serialize
    // ref handles) resolves within scope — a selector on a sibling element would
    // query an empty subtree.
    const scene_wrap = ctx.div()
        .children(.{scene})
        .animate(anim.to(a, null)
        .glTargetRange(dolly_id, 0, 4.0, 2.5)
        .glTargetRangeHashed(metallic_ph, metallic.name_hash, 0, 0.0, 1.0)
        .glTargetRangeHashed(roty_ph, roty.name_hash, 0, -0.6, 0.6)
        .glTargetRangeHashed(transy_ph, transy.name_hash, 0, -0.4, 0.4)
        .glTargetRangeHashed(sclx_ph, sclx.name_hash, 0, 0.7, 1.3)
        .glTargetRangeHashed(basecol_ph, basecol.name_hash, 0, 1.0, 0.2)
        .glTargetRangeHashed(alpha_ph, alpha.name_hash, 0, 1.0, 0.25)
        .duration(1).ease(.linear)
        .scrollTrigger(.{
        .trigger = "section[data-ref^=glscene-scroll-section]",
        .start = .{ .trigger = .top, .viewport = .top },
        .end = .{ .at = .{ .trigger = .bottom, .viewport = .top } },
        .scrub = .{ .smooth = 0.4 },
    }));

    return ctx.main_().class("home gl-scene-page").children(.{
        ctx.h1("verve.gl — scroll to spin"),
        ctx.p().text("Scroll to rotate · drag to orbit · wheel to zoom · click a mesh to pick. " ++
            "Scene declared in Zig; scroll scrubs the turntable timeline."),
        // The island brings its own 300vh scroll section + sticky viewport.
        scene_wrap,
        ctx.p().class("hint")
            .text("Keep scrolling — the model completes a full rotation over 300vh of scroll travel."),
        ctx.p().text("Drag to orbit · wheel to zoom · click a mesh to pick. " ++
            "The GlScene chunk owns the WebGL2 render loop; Zig declares the scene."),
    });
}

/// /gl-mixed: the mixed-material scene (two cubes, distinct PBR variants).
/// "MixedFull" is full-PBR (variant pbr|normal_map|emissive), "MixedBase" is
/// base-color only (variant pbr) offset +2.5 on X. GlScene compiles two
/// shaders and switches `setPipeline` between the submeshes — this route makes
/// the per-submesh shader-variant fan-out visibly exercisable. No scrub: a
/// plain auto-rotating turntable, simpler than /gl-scene.
pub fn glSceneMixed(ctx: *const verve.Context) !*verve.Node {
    // Both cubes span X≈[-1,1] and [1.5,3.5]; frame the pair by orbiting from a
    // larger distance so both stay in view (no orbit-target offset exists; the
    // wider pullback keeps the off-center second cube on screen).
    const scene = ctx.glScene(.{
        .src = "/gl/mixed.vmesh",
        .env = "/gl/studio.venv",
        .poster = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='640' height='400' viewBox='0 0 640 400'%3E%3Crect width='640' height='400' rx='8' fill='%23121420'/%3E%3Ctext x='320' y='215' font-family='system-ui' font-size='48' font-weight='700' fill='%23f5f5f5' text-anchor='middle'%3E3D%3C/text%3E%3C/svg%3E",
    })
        .camera(.{ .distance = 7, .pitch = 0.3, .yaw = 0.6 })
        .light(.{ .dir = .{ -0.4, -0.7, -0.6 }, .intensity = 3.0 })
        .autoRotate(0.4)
        .onPickExport("MixedFull", "verve:glpick-full")
        .onPickExport("MixedBase", "verve:glpick-base")
        .build();

    // Non-scrub layout needs a definite-sized container (the island's inner
    // wrapper is 100%/100%); give it an aspect-ratio box like /gl's gl-wrap.
    const scene_box = ctx.div().class("gl-wrap").children(.{
        ctx.div()
            .attr("style", "width:100%;max-width:640px;aspect-ratio:8/5;display:block;background:#121420;border-radius:8px;margin:0 auto")
            .children(.{scene}),
    });

    return ctx.main_().class("home gl-scene-page").children(.{
        ctx.h1("verve.gl — mixed materials"),
        ctx.p().text("Two cubes, two PBR shader variants: the left is full-PBR " ++
            "(normal map + emissive), the right is base-color only. GlScene compiles " ++
            "a shader per variant and switches pipeline between submeshes."),
        scene_box,
        ctx.p().class("hint")
            .text("Drag to orbit · wheel to zoom · click a cube to pick. " ++
            "MixedFull → verve:glpick-full, MixedBase → verve:glpick-base."),
    });
}

/// /gl-shadow: a cube on a floor, demonstrating the P9 slice-3 directional
/// shadow map. The "Cube" casts a real depth-mapped shadow onto the "Floor"
/// receiver; the camera looks slightly down so the cast shadow is in frame.
pub fn glSceneShadow(ctx: *const verve.Context) !*verve.Node {
    const scene = ctx.glScene(.{
        .src = "/gl/shadow.vmesh",
        .env = "/gl/studio.venv",
        .poster = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='640' height='400' viewBox='0 0 640 400'%3E%3Crect width='640' height='400' rx='8' fill='%23121420'/%3E%3Ctext x='320' y='215' font-family='system-ui' font-size='48' font-weight='700' fill='%23f5f5f5' text-anchor='middle'%3E3D%3C/text%3E%3C/svg%3E",
    })
        // Pitch up so the camera looks down onto the floor; pull back to frame
        // the cube + its cast shadow.
        .camera(.{ .distance = 9, .pitch = 0.55, .yaw = 0.7 })
        // Light from up and to the side → the cube's shadow rakes across the
        // floor toward the viewer.
        .light(.{ .dir = .{ -0.45, -0.82, -0.35 }, .intensity = 3.2 })
        .autoRotate(0.25)
        .onPickExport("Cube", "verve:glpick-cube")
        .build();

    const scene_box = ctx.div().class("gl-wrap").children(.{
        ctx.div()
            .attr("style", "width:100%;max-width:640px;aspect-ratio:8/5;display:block;background:#121420;border-radius:8px;margin:0 auto")
            .children(.{scene}),
    });

    return ctx.main_().class("home gl-scene-page").children(.{
        ctx.h1("verve.gl — shadow map"),
        ctx.p().text("A cube on a floor. The single directional light casts a " ++
            "real depth-mapped shadow (P9 slice 3): a depth pass renders the " ++
            "scene from the light, and the floor samples it with 3×3 PCF."),
        scene_box,
        ctx.p().class("hint")
            .text("Drag to orbit · wheel to zoom · the cube casts onto the floor."),
    });
}

/// /gl-spot: spot light + spot shadow + multi-light demo. Three lights mix in
/// one scene: a spot caster above the cube (perspective shadow map — fovy =
/// 2 × outer_deg), a dim fill directional (no shadow), and a colored point
/// accent. Reuses shadow.vmesh (cube on a floor) so the cone shadow falls on
/// the floor receiver. The spot type is serialized as light type 2 in the
/// data-gllights CSV; the fill directional is type 0; the point is type 1.
pub fn glSceneSpot(ctx: *const verve.Context) !*verve.Node {
    // Three-light array: spot caster (type 2) + fill directional (type 0) +
    // colored point accent (type 1). All three land in data-gllights; the spot
    // is type 2 so its field 0 reads "2," in the CSV output.
    const spot_lights = [_]verve.GlLight{
        // Spot above the cube, slight forward tilt. casts_shadow=true →
        // perspective depth pass (fovy = 2 × outer_deg = 44°).
        .{
            .kind = .spot,
            .pos = .{ 0, 6, 1 },
            .dir = .{ 0, -1, -0.15 },
            .color = .{ 1, 0.95, 0.85 },
            .intensity = 60,
            .inner_deg = 14,
            .outer_deg = 22,
            .range = 20,
            .casts_shadow = true,
        },
        // Dim fill directional — keeps the unlit side visible, no shadow.
        .{
            .kind = .directional,
            .dir = .{ -0.4, -0.7, -0.4 },
            .intensity = 0.6,
        },
        // Colored point accent — shows 1/d² attenuation on the cube face.
        .{
            .kind = .point,
            .pos = .{ -3, 2, 2 },
            .color = .{ 0.3, 0.5, 1.0 },
            .intensity = 12,
            .range = 10,
        },
    };

    const scene = ctx.glScene(.{
        .src = "/gl/shadow.vmesh",
        .env = "/gl/studio.venv",
        .poster = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='640' height='400' viewBox='0 0 640 400'%3E%3Crect width='640' height='400' rx='8' fill='%23121420'/%3E%3Ctext x='320' y='215' font-family='system-ui' font-size='48' font-weight='700' fill='%23f5f5f5' text-anchor='middle'%3ESpot%3C/text%3E%3C/svg%3E",
    })
        // Frame camera down to see the cone shadow on the floor.
        .camera(.{ .distance = 9, .pitch = 0.55, .yaw = 0.7 })
        .lights(&spot_lights)
        .autoRotate(0.2)
        .build();

    const scene_box = ctx.div().class("gl-wrap").children(.{
        ctx.div()
            .attr("style", "width:100%;max-width:640px;aspect-ratio:8/5;display:block;background:#121420;border-radius:8px;margin:0 auto")
            .children(.{scene}),
    });

    return ctx.main_().class("home gl-scene-page").children(.{
        ctx.h1("verve.gl — spot lights + spot shadow"),
        ctx.p().text("Three lights in one scene: a spot caster above the cube " ++
            "that casts a perspective shadow (fovy = 2 \u{00d7} outer angle, same " ++
            "depth pass + PCF as the directional shadow), a dim fill directional " ++
            "keeping the unlit side visible, and a blue-tinted point accent that " ++
            "shows 1/d\u{00b2} attenuation on the cube face."),
        scene_box,
        ctx.p().class("hint")
            .text("Drag to orbit \u{00b7} wheel to zoom \u{00b7} cone shadow tracks the spot."),
        ctx.p().text("The spot cone uses " ++
            "smoothstep(cos_outer, cos_inner, dot(-L, dir)) for soft " ++
            "falloff at the penumbra. The scene is lit by up to 4 mixed " ++
            "directional / point / spot lights packed into SET_LIGHTS " ++
            "(type 0 / 1 / 2 in the data-gllights attribute)."),
    });
}

/// /gl-point: omnidirectional point-light shadow demo. ONE point caster above
/// the cube radiates shadows in all directions via a 6-face RGBA8 distance
/// atlas (1536×1024, 3×2 of 512² tiles). The receiver samples the atlas with
/// face-select + manual 3×3 PCF (`variant_shadow_point = 1<<15`). A dim fill
/// directional keeps the unlit side from going pure-black. Reuses
/// shadow.vmesh (cube + floor) and studio.venv.
pub fn glScenePoint(ctx: *const verve.Context) !*verve.Node {
    // Single point caster positioned high-right. 1/d² at ~3-4 units needs a
    // large raw intensity (~40); fill dir keeps shadow side visible.
    const point_lights = [_]verve.GlLight{
        .{
            .kind = .point,
            .pos = .{ 1.5, 3.0, 1.5 },
            .color = .{ 1, 0.9, 0.8 },
            .intensity = 40,
            .range = 18,
            .casts_shadow = true,
        },
        // Dim fill so the unlit cube face isn't pure black.
        .{
            .kind = .directional,
            .dir = .{ -0.4, -0.7, -0.4 },
            .color = .{ 1, 1, 1 },
            .intensity = 0.5,
        },
    };

    const scene = ctx.glScene(.{
        .src = "/gl/shadow.vmesh",
        .env = "/gl/studio.venv",
        .poster = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='640' height='400' viewBox='0 0 640 400'%3E%3Crect width='640' height='400' rx='8' fill='%23121420'/%3E%3Ctext x='320' y='215' font-family='system-ui' font-size='48' font-weight='700' fill='%23f5f5f5' text-anchor='middle'%3EPoint%3C/text%3E%3C/svg%3E",
    })
        .camera(.{ .distance = 9, .pitch = 0.55, .yaw = 0.7 })
        .lights(&point_lights)
        .autoRotate(0.2)
        .build();

    const scene_box = ctx.div().class("gl-wrap").children(.{
        ctx.div()
            .attr("style", "width:100%;max-width:640px;aspect-ratio:8/5;display:block;background:#121420;border-radius:8px;margin:0 auto")
            .children(.{scene}),
    });

    return ctx.main_().class("home gl-scene-page").children(.{
        ctx.h1("verve.gl — point-light shadow"),
        ctx.p().text("A point light positioned above the cube casts an " ++
            "OMNIDIRECTIONAL shadow via a 6-face RGBA8 distance atlas " ++
            "(1536\u{00d7}1024, 3\u{00d7}2 of 512\u{00b2} tiles). The receiver " ++
            "face-selects the correct tile and applies manual 3\u{00d7}3 PCF " ++
            "(`variant_shadow_point`). Unlike the directional (/gl-shadow) and " ++
            "spot (/gl-spot) demos, the shadow radiates in all directions from " ++
            "the light — the cube casts on the floor and the floor edge casts " ++
            "back onto the cube side."),
        scene_box,
        ctx.p().class("hint")
            .text("Drag to orbit \u{00b7} wheel to zoom \u{00b7} omnidirectional shadow from the point light."),
    });
}

/// /gl-multishadow: Slice 1 capstone — directional + spot + point lights ALL
/// cast shadows SIMULTANEOUSLY in one scene. Three casters land in the
/// data-gllights CSV with casts_shadow=1: a directional (type 0) raking from
/// upper-left, a spot (type 2) from above-forward, and a point (type 1) off to
/// the right with a positive range (range==far contract). Each shadow falls in a
/// different direction on the floor so all three read distinctly. Reuses
/// shadow.vmesh (cube + floor) and studio.venv. A Freeze/Unfreeze control
/// (glscene_freeze / glscene_unfreeze, page-global) pins the auto-orbit so a CDP
/// run has a stable frame for pixel metrics; the buttons are appended INSIDE the
/// GlScene island subtree so z-on-click routes to the chunk's exports.
pub fn glSceneMultiShadow(ctx: *const verve.Context) !*verve.Node {
    // Three simultaneous casters — one of each light type, all casts_shadow=true.
    const lights = [_]verve.GlLight{
        // Directional caster (type 0) raking from upper-left → shadow stretches
        // to lower-right on the floor.
        .{
            .kind = .directional,
            .dir = .{ -0.55, -0.78, -0.30 },
            .color = .{ 1, 0.97, 0.9 },
            .intensity = 2.2,
            .casts_shadow = true,
        },
        // Spot caster (type 2) above + forward → perspective cone shadow toward
        // the viewer. casts_shadow=true → fovy = 2 × outer_deg depth pass.
        .{
            .kind = .spot,
            .pos = .{ 0.5, 6, 2.5 },
            .dir = .{ -0.05, -1, -0.35 },
            .color = .{ 0.85, 0.95, 1.0 },
            .intensity = 55,
            .inner_deg = 16,
            .outer_deg = 26,
            .range = 22,
            .casts_shadow = true,
        },
        // Point caster (type 1) off to the right → omnidirectional shadow via the
        // cube distance atlas, casting to the left. Positive range so range==far.
        .{
            .kind = .point,
            .pos = .{ 3.5, 2.5, -0.5 },
            .color = .{ 1.0, 0.8, 0.6 },
            .intensity = 38,
            .range = 16,
            .casts_shadow = true,
        },
    };

    const island_node = ctx.glScene(.{
        .src = "/gl/shadow.vmesh",
        .env = "/gl/studio.venv",
        .poster = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='640' height='400' viewBox='0 0 640 400'%3E%3Crect width='640' height='400' rx='8' fill='%23121420'/%3E%3Ctext x='320' y='215' font-family='system-ui' font-size='44' font-weight='700' fill='%23f5f5f5' text-anchor='middle'%3EMulti-shadow%3C/text%3E%3C/svg%3E",
    })
        .camera(.{ .distance = 9.5, .pitch = 0.55, .yaw = 0.7 })
        .lights(&lights)
        .autoRotate(0.2)
        .build();

    // Freeze/Unfreeze control. Appended INSIDE the GlScene island node so the
    // z-on-click resolves against the GlScene chunk's exports (the verve.js
    // dispatcher walks `target.closest("verve-island")`). Mirrors the GlSkin /
    // GlPost freeze convention.
    const controls = ctx.div().class("gl-controls").children(.{
        ctx.el("button").attr("z-on-click", "glscene_freeze").text("Freeze"),
        ctx.el("button").attr("z-on-click", "glscene_unfreeze").text("Unfreeze"),
    });
    _ = island_node.children(.{controls});

    const scene_box = ctx.div().class("gl-wrap").children(.{
        ctx.div()
            .attr("style", "width:100%;max-width:640px;aspect-ratio:8/5;display:block;background:#121420;border-radius:8px;margin:0 auto")
            .children(.{island_node}),
    });

    return ctx.main_().class("home gl-scene-page").children(.{
        ctx.h1("verve.gl — simultaneous multi-light shadows"),
        ctx.p().text("Slice 1 capstone: a directional, a spot, AND a point light " ++
            "all cast real depth-mapped shadows AT THE SAME TIME onto the floor. " ++
            "The directional rakes from the upper-left (shadow to lower-right), the " ++
            "spot drops a perspective cone from above-forward (toward the viewer), " ++
            "and the point off to the right casts an omnidirectional shadow to the " ++
            "left via its cube distance atlas. Up to 4 casters of each type pack " ++
            "into a tiled 2D shadow atlas plus an enlarged point cube atlas; both " ++
            "the WebGL2 and WebGPU backends decode all three at once."),
        scene_box,
        ctx.p().class("hint")
            .text("Drag to orbit \u{00b7} wheel to zoom \u{00b7} Freeze pins the orbit. " ++
            "Look for THREE distinct shadows fanning in different directions."),
    });
}

/// /gl-csm: Slice 2 capstone — Cascaded Shadow Maps. A SINGLE directional light
/// (type 0) with casts_shadow=true automatically becomes a 4-cascade CSM caster
/// (S2T3: every directional caster is split into 4 cascades fit to view-frustum
/// depth slices, practical split λ=0.5). The view frustum is sliced near→far and
/// each slice gets its own tight depth pass, so near shadows stay crisp while far
/// shadows remain covered; per-fragment cascade selection + a boundary blend hide
/// the seams. Reuses shadow.vmesh (cube + floor) so the flat ground plane acts as
/// a receiver: the shadow stretches across the floor and the near-crisp / far-soft
/// gradient is clearly visible as the shadow travels away from the cube. Reuses the
/// page-global glscene_freeze / glscene_unfreeze control (Slice 1) so a CDP run
/// has a stable frame; the buttons sit INSIDE the GlScene island subtree so
/// z-on-click routes to the chunk's exports.
pub fn glSceneCsm(ctx: *const verve.Context) !*verve.Node {
    // ONE directional caster → 4 CSM cascades (automatic, S2T3). Raking from the
    // upper-left so the shadow stretches across the floor receiver; casts_shadow=true
    // is the only flag CSM needs.
    const lights = [_]verve.GlLight{
        .{
            .kind = .directional,
            .dir = .{ -0.55, -0.72, -0.42 },
            .color = .{ 1, 0.97, 0.9 },
            .intensity = 2.6,
            .casts_shadow = true,
        },
    };

    const island_node = ctx.glScene(.{
        .src = "/gl/shadow.vmesh",
        .env = "/gl/studio.venv",
        .poster = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='640' height='400' viewBox='0 0 640 400'%3E%3Crect width='640' height='400' rx='8' fill='%23121420'/%3E%3Ctext x='320' y='215' font-family='system-ui' font-size='44' font-weight='700' fill='%23f5f5f5' text-anchor='middle'%3ECascaded Shadows%3C/text%3E%3C/svg%3E",
    })
        // Flatter pitch + larger distance so the floor plane recedes into the
        // frame and the near/far cascade quality split is visible on the ground.
        .camera(.{ .distance = 14.0, .pitch = 0.30, .yaw = 0.55 })
        .lights(&lights)
        .autoRotate(0.15)
        .build();

    // Freeze/Unfreeze control — appended INSIDE the GlScene island node so
    // z-on-click resolves against the GlScene chunk's exports (Slice-1 control;
    // do NOT re-define it). Mirrors the GlSkin / GlPost freeze convention.
    const controls = ctx.div().class("gl-controls").children(.{
        ctx.el("button").attr("z-on-click", "glscene_freeze").text("Freeze"),
        ctx.el("button").attr("z-on-click", "glscene_unfreeze").text("Unfreeze"),
    });
    _ = island_node.children(.{controls});

    const scene_box = ctx.div().class("gl-wrap").children(.{
        ctx.div()
            .attr("style", "width:100%;max-width:640px;aspect-ratio:8/5;display:block;background:#121420;border-radius:8px;margin:0 auto")
            .children(.{island_node}),
    });

    return ctx.main_().class("home gl-scene-page").children(.{
        ctx.h1("verve.gl — Cascaded Shadow Maps (CSM)"),
        ctx.p().text("Slice 2 capstone: ONE directional light casts shadows split " ++
            "into FOUR cascades. The view frustum is sliced near→far (practical " ++
            "split λ=0.5) and each slice gets its own tight depth pass packed into " ++
            "the shadow atlas. Near shadows stay crisp at high resolution while far " ++
            "shadows stay covered; the fragment shader picks the right cascade per " ++
            "pixel and blends across cascade boundaries so the transitions are " ++
            "seamless. The shadow falls on a flat floor plane that recedes into the " ++
            "distance — near-crisp vs far-smooth is directly observable on the ground " ++
            "receiver — both WebGL2 and WebGPU backends decode all four cascades " ++
            "from the Slice-1 shadow atlas."),
        scene_box,
        ctx.p().class("hint")
            .text("Drag to orbit \u{00b7} wheel to zoom \u{00b7} Freeze pins the orbit. " ++
            "Look for a crisp shadow edge close to the cube and a softer shadow where " ++
            "the floor recedes into the distance — different cascade bands at work."),
    });
}

/// /gl-instanced-shadow: Slice 4 capstone — instanced geometry that BOTH casts AND
/// receives directional shadows. cubeshadow.vmesh has 9 instances of the same unit cube:
/// instance 0 is a WIDE FLAT FLOOR SLAB (receiver) and instances 1–8 are TALL PILLARS
/// standing on it that cast clearly-visible diagonal shadows across open slab area.
/// A single raking directional light (`casts_shadow = true`) drives both the instanced
/// shadow depth pass (`draw_depth_instanced`) and the instanced PBR pass
/// (`draw_pbr_instanced`) — one draw call each, WebGL2 and WebGPU backends.
///
/// FRAMING NOTE: the camera is positioned to frame the whole slab so all pillar shadows
/// fall on visible open slab area. ALL 9 instances remain inside the frustum at all times.
/// This is required because per-instance frustum culling (slice 3) renumbers the
/// visible-instance buffer by compaction order, while the shadow pass records shadows keyed
/// by original instance index. If any instance were culled, its shadow index would no longer
/// align with its draw index (known v1 limitation — "All instances are kept in frame —
/// per-instance frustum culling would desync the shadow wave-phase from the mesh (v2 fix)").
pub fn glSceneInstancedShadow(ctx: *const verve.Context) !*verve.Node {
    // Single raking directional caster — light from upper-left so pillar shadows
    // fall diagonally across the open slab area between pillars.
    const lights = [_]verve.GlLight{
        .{
            .kind = .directional,
            .dir = .{ -0.55, -0.72, -0.42 },
            .color = .{ 1, 0.97, 0.9 },
            .intensity = 2.6,
            .casts_shadow = true,
        },
    };

    const island_node = ctx.glScene(.{
        .src = "/gl/cubeshadow.vmesh",
        .env = "/gl/studio.venv",
        .poster = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='640' height='400' viewBox='0 0 640 400'%3E%3Crect width='640' height='400' rx='8' fill='%23121420'/%3E%3Ctext x='320' y='215' font-family='system-ui' font-size='40' font-weight='700' fill='%23f5f5f5' text-anchor='middle'%3EInstanced Shadows%3C/text%3E%3C/svg%3E",
    })
        // Lower pitch + generous distance: frame the whole slab so pillar shadows
        // land on visible open slab between the pillars. All 9 instances stay in frustum.
        .camera(.{ .distance = 22.0, .pitch = 0.25, .yaw = 0.5 })
        .lights(&lights)
        // Slow rotation keeps the slab + shadows framed and readable.
        .autoRotate(0.08)
        .build();

    const scene_box = ctx.div().class("gl-wrap").children(.{
        ctx.div()
            .attr("style", "width:100%;max-width:640px;aspect-ratio:8/5;display:block;background:#121420;border-radius:8px;margin:0 auto")
            .children(.{island_node}),
    });

    return ctx.main_().class("home gl-scene-page").children(.{
        ctx.h1("verve.gl — Instanced Shadows (slice 4)"),
        ctx.p().text("Slice 4 capstone: GPU-instanced cubes — one scaled into a wide " ++
            "floor slab, the rest tall pillars casting directional shadows onto it " ++
            "(instanced cast + receive). A single raking directional light drives both " ++
            "the instanced shadow depth pass and the instanced PBR pass — one draw call " ++
            "each, WebGL2 and WebGPU backends."),
        scene_box,
        ctx.p().class("hint")
            .text("Drag to orbit \u{00b7} wheel to zoom. " ++
            "All instances are kept in frame — per-instance frustum culling would " ++
            "desync the shadow wave-phase from the mesh (v2 fix)."),
    });
}

/// /gl-ortho-csm: CSM under an ORTHOGRAPHIC camera. Same single directional caster
/// and shadow.vmesh floor as /gl-csm, but the scene renders with parallel projection
/// (`.projection(.orthographic)`). Exercises the ortho-aware cascade fit: each cascade
/// slice is a rectangular SLAB (constant width at every depth) rather than a frustum
/// wedge, so the directional shadow lands correctly on the receding floor with no
/// perspective foreshortening. The bug this guards: a perspective cascade fit under
/// ortho mis-sizes the light frustum, smearing or dropping the shadow.
pub fn glSceneOrthoCsm(ctx: *const verve.Context) !*verve.Node {
    const lights = [_]verve.GlLight{
        .{
            .kind = .directional,
            .dir = .{ -0.55, -0.72, -0.42 },
            .color = .{ 1, 0.97, 0.9 },
            .intensity = 2.6,
            .casts_shadow = true,
        },
    };

    const island_node = ctx.glScene(.{
        .src = "/gl/shadow.vmesh",
        .env = "/gl/studio.venv",
        .poster = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='640' height='400' viewBox='0 0 640 400'%3E%3Crect width='640' height='400' rx='8' fill='%23121420'/%3E%3Ctext x='320' y='215' font-family='system-ui' font-size='40' font-weight='700' fill='%23f5f5f5' text-anchor='middle'%3EOrtho CSM%3C/text%3E%3C/svg%3E",
    })
        .camera(.{ .distance = 14.0, .pitch = 0.30, .yaw = 0.55 })
        // Orthographic projection: cascade slices become rectangular slabs. ortho_height
        // is the view half-height in world units — sized to frame the cube + floor.
        .projection(.{ .mode = .orthographic, .ortho_height = 8.0 })
        .lights(&lights)
        .autoRotate(0.15)
        .build();

    const controls = ctx.div().class("gl-controls").children(.{
        ctx.el("button").attr("z-on-click", "glscene_freeze").text("Freeze"),
        ctx.el("button").attr("z-on-click", "glscene_unfreeze").text("Unfreeze"),
    });
    _ = island_node.children(.{controls});

    const scene_box = ctx.div().class("gl-wrap").children(.{
        ctx.div()
            .attr("style", "width:100%;max-width:640px;aspect-ratio:8/5;display:block;background:#121420;border-radius:8px;margin:0 auto")
            .children(.{island_node}),
    });

    return ctx.main_().class("home gl-scene-page").children(.{
        ctx.h1("verve.gl — Cascaded Shadow Maps under orthographic projection"),
        ctx.p().text("The same single directional caster + four cascades as /gl-csm, but " ++
            "the camera uses ORTHOGRAPHIC (parallel) projection. Each cascade slice is fit " ++
            "as a rectangular slab — constant width at every depth — instead of a frustum " ++
            "wedge, so the shadow lands correctly on the floor with no perspective " ++
            "foreshortening. Both WebGL2 and WebGPU."),
        scene_box,
        ctx.p().class("hint")
            .text("Drag to orbit \u{00b7} wheel to zoom \u{00b7} Freeze pins the orbit. " ++
            "The floor stays the same width front-to-back (parallel projection) and the " ++
            "cast shadow stays attached to the cube across the cascade bands."),
    });
}

/// /gl-area: LTC (Linearly Transformed Cosines, Heitz 2016) rect AREA light demo.
/// ONE overhead rect area light hovers above the model + floor, facing straight
/// down (cross(ex,ey) = −Y), and casts a SOFT area shadow. Unlike a point/spot
/// light, the rect has finite size so it produces realistic soft diffuse falloff,
/// a stretched specular highlight that follows the rect's shape (the LTC
/// approximation), and a penumbra-soft shadow whose edge widens with distance from
/// the receiver. The regular punctual lights are kept to a tiny ambient-ish fill so
/// the area light's lighting + shadow are the visible feature, not drowned out by a
/// directional key. Reuses shadow.vmesh (cube + floor receiver) and the page-global
/// glscene_freeze / glscene_unfreeze control (Slice 1) so a CDP run has a stable
/// frame; the buttons sit INSIDE the GlScene island subtree so z-on-click routes to
/// the chunk's exports. The LTC LUTs are fetched as /gl/ltc.bin.
pub fn glSceneArea(ctx: *const verve.Context) !*verve.Node {
    // Tiny low-intensity fill so the scene isn't pure black where the area light
    // doesn't reach — kept minimal so the AREA light is the visible feature.
    const lights = [_]verve.GlLight{
        .{
            .kind = .directional,
            .dir = .{ -0.2, -1.0, -0.3 },
            .color = .{ 0.6, 0.65, 0.8 },
            .intensity = 0.25,
            .casts_shadow = false,
        },
    };

    const island_node = ctx.glScene(.{
        .src = "/gl/shadow.vmesh",
        .env = "/gl/studio.venv",
        .poster = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='640' height='400' viewBox='0 0 640 400'%3E%3Crect width='640' height='400' rx='8' fill='%23121420'/%3E%3Ctext x='320' y='215' font-family='system-ui' font-size='44' font-weight='700' fill='%23f5f5f5' text-anchor='middle'%3EArea Light (LTC)%3C/text%3E%3C/svg%3E",
    })
        .camera(.{ .distance = 14.0, .pitch = 0.30, .yaw = 0.55 })
        .lights(&lights)
        // ONE overhead rect area light. ex=+X half-edge, ey=+Z half-edge →
        // cross(ex,ey) = −Y, so the rect faces DOWN onto the model + floor and
        // casts a soft area shadow. casts_shadow=true renders the rect as a
        // perspective caster into the 2D shadow atlas.
        .areaLight(.{
            .pos = .{ 0, 3, 0 },
            .ex = .{ 0.6, 0, 0 },
            .ey = .{ 0, 0, 0.6 },
            .color = .{ 1, 1, 1 },
            .intensity = 5,
            .casts_shadow = true,
        })
        .autoRotate(0.15)
        .build();

    const controls = ctx.div().class("gl-controls").children(.{
        ctx.el("button").attr("z-on-click", "glscene_freeze").text("Freeze"),
        ctx.el("button").attr("z-on-click", "glscene_unfreeze").text("Unfreeze"),
    });
    _ = island_node.children(.{controls});

    const scene_box = ctx.div().class("gl-wrap").children(.{
        ctx.div()
            .attr("style", "width:100%;max-width:640px;aspect-ratio:8/5;display:block;background:#121420;border-radius:8px;margin:0 auto")
            .children(.{island_node}),
    });

    return ctx.main_().class("home gl-scene-page").children(.{
        ctx.h1("verve.gl — Area Light (LTC)"),
        ctx.p().text("Slice 3 capstone: ONE rectangular AREA light hovers overhead, " ++
            "facing straight down at the model and floor. Real area lights have finite " ++
            "size, so instead of a single hard highlight they produce a soft diffuse " ++
            "spread and a specular reflection STRETCHED into the shape of the rectangle. " ++
            "Verve evaluates this with Linearly Transformed Cosines (LTC, Heitz 2016): a " ++
            "pair of small lookup tables (fetched as /gl/ltc.bin) transform a cosine " ++
            "distribution into the rect's clipped solid angle, giving physically-based " ++
            "area lighting in one shader pass. The rect also casts a SOFT area shadow — " ++
            "rendered as a perspective caster into the 2D shadow atlas — whose penumbra " ++
            "widens with distance from the receiver. Both WebGL2 and WebGPU backends."),
        scene_box,
        ctx.p().class("hint")
            .text("Drag to orbit \u{00b7} wheel to zoom \u{00b7} Freeze pins the orbit. " ++
            "Look for soft, even lighting on the top faces, a specular highlight that " ++
            "stretches to match the rectangle, and a soft-edged shadow under the cube " ++
            "on the floor."),
    });
}

/// /gl-cutout: alpha-test (MASK) cutout dissolve demo. The "Cutout" cube's
/// base-color texture has a real alpha channel with HOLES; its material is
/// alphaMode:MASK (cutoff 0.5), so the variant_alpha_test shader DISCARDS any
/// fragment whose sampled base-texture alpha is below the cutoff — the holes
/// punch clean see-through cutouts with a HARD edge (opaque pass, no blend /
/// no sort, order-independent). Unlike BLEND, the background shows straight
/// through; there is no translucency.
///
/// Dissolve: scroll scrubs `material:Cutout.baseColorA` 1.0→0.0. The base-color
/// alpha multiplies the sampled texture alpha, so as it falls more texels drop
/// below the cutoff and the silhouette erodes. Reuses the same deferred-target
/// idiom as /gl-scene (resolvePathStaticDeferred + encode + glTargetRangeHashed):
/// material:/node: targets need the client-side vmesh name table, so SSR bakes
/// the comptime {kind, field, name_hash} and the bridge resolves the submesh on
/// the first tick.
pub fn glSceneCutout(ctx: *const verve.Context) !*verve.Node {
    const anim = verve.anim;
    const a = ctx.alloc();

    const scene = ctx.glScene(.{
        .src = "/gl/cutout.vmesh",
        .env = "/gl/studio.venv",
        .poster = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='640' height='400' viewBox='0 0 640 400'%3E%3Crect width='640' height='400' rx='8' fill='%23121420'/%3E%3Ctext x='320' y='215' font-family='system-ui' font-size='48' font-weight='700' fill='%23f5f5f5' text-anchor='middle'%3E3D%3C/text%3E%3C/svg%3E",
    })
        .camera(.{ .distance = 4, .pitch = 0.3, .yaw = 0.6 })
        .light(.{ .dir = .{ -0.4, -0.7, -0.6 }, .intensity = 3.0 })
        .onPickExport("Cutout", "verve:glpick-cutout")
        .scrub(true)
        .build();

    // SSR scroll-driven camera dolly (slot-0 static path resolves at comptime).
    const dolly_id = comptime (verve.gl.anim_target.resolvePathStatic("camera.distance") orelse unreachable);

    // SSR DEFERRED dissolve target: material:Cutout.baseColorA. The placeholder
    // id carries kind+field (submesh bits 0); the bridge resolves name_hash →
    // submesh index on the first tick.
    const roty = comptime (verve.gl.anim_target.resolvePathStaticDeferred("node:Cutout.rotationY") orelse unreachable);
    const alpha = comptime (verve.gl.anim_target.resolvePathStaticDeferred("material:Cutout.baseColorA") orelse unreachable);
    const roty_ph = comptime verve.gl.anim_target.encode(roty.kind, 0, roty.field);
    const alpha_ph = comptime verve.gl.anim_target.encode(alpha.kind, 0, alpha.field);

    const scene_wrap = ctx.div()
        .children(.{scene})
        .animate(anim.to(a, null)
        .glTargetRange(dolly_id, 0, 4.0, 3.0)
        .glTargetRangeHashed(roty_ph, roty.name_hash, 0, -0.6, 0.6)
        // baseColorA 1.0 → 0.0: the cutout dissolves as more fragments fall
        // below the alpha cutoff. Stop at 0.05 so the silhouette fully erodes
        // by the end of the scroll travel.
        .glTargetRangeHashed(alpha_ph, alpha.name_hash, 0, 1.0, 0.05)
        .duration(1).ease(.linear)
        .scrollTrigger(.{
        .trigger = "section[data-ref^=glscene-scroll-section]",
        .start = .{ .trigger = .top, .viewport = .top },
        .end = .{ .at = .{ .trigger = .bottom, .viewport = .top } },
        .scrub = .{ .smooth = 0.4 },
    }));

    return ctx.main_().class("home gl-scene-page").children(.{
        ctx.h1("verve.gl — alpha-test cutout"),
        ctx.p().text("A MASK material: the base texture's alpha channel has holes, " ++
            "and the alpha-test shader discards fragments below the cutoff. The " ++
            "background shows through with a HARD edge — a cutout, not a translucent blend."),
        scene_wrap,
        ctx.p().class("hint")
            .text("Keep scrolling — baseColorA fades 1→0 and the cutout silhouette dissolves away."),
        ctx.p().text("Drag to orbit · wheel to zoom · click to pick (verve:glpick-cutout). " ++
            "Cutout renders in the opaque pass — order-independent, no depth sort."),
    });
}

/// /gl-double: doubleSided material demo. An upright MASK quad with
/// doubleSided:true is visible from both sides as the camera auto-rotates
/// past it — back-face normals are flipped by the variant_double_sided shader
/// so the surface stays lit from both directions rather than going dark or
/// vanishing. The floor plane is single-sided (OPAQUE, cull-back default).
///
/// Orbit: the scene auto-rotates so the camera passes through both the front
/// (+Z) and back (-Z) faces of the quad. The back face appears identically
/// colored and lit (normal-flipped PBR). Drag to orbit or wheel to zoom.
pub fn glSceneDouble(ctx: *const verve.Context) !*verve.Node {
    const anim = verve.anim;
    const a = ctx.alloc();

    const scene = ctx.glScene(.{
        .src = "/gl/double.vmesh",
        .env = "/gl/studio.venv",
        .poster = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='640' height='400' viewBox='0 0 640 400'%3E%3Crect width='640' height='400' rx='8' fill='%23121420'/%3E%3Ctext x='320' y='215' font-family='system-ui' font-size='48' font-weight='700' fill='%23f5f5f5' text-anchor='middle'%3EDouble-Sided%3C/text%3E%3C/svg%3E",
    })
        .camera(.{ .distance = 5.0, .pitch = 0.25, .yaw = 0.5 })
        .light(.{ .dir = .{ -0.4, -0.7, -0.6 }, .intensity = 3.0 })
        .autoRotate(0.4)
        .build();

    // Scroll-driven dolly so the user can pull back and see the full quad.
    const dolly_id = comptime (verve.gl.anim_target.resolvePathStatic("camera.distance") orelse unreachable);

    const scene_wrap = ctx.div()
        .children(.{scene})
        .animate(anim.to(a, null)
        .glTargetRange(dolly_id, 0, 5.0, 3.0)
        .duration(1).ease(.linear)
        .scrollTrigger(.{
        .trigger = "section[data-ref^=glscene-scroll-section]",
        .start = .{ .trigger = .top, .viewport = .top },
        .end = .{ .at = .{ .trigger = .bottom, .viewport = .top } },
        .scrub = .{ .smooth = 0.4 },
    }));

    return ctx.main_().class("home gl-scene-page").children(.{
        ctx.h1("verve.gl — doubleSided materials"),
        ctx.p().text("An upright MASK quad with " ++
            "\"doubleSided\":true in its glTF material, beside a translucent " ++
            "doubleSided BLEND card. The variant_double_sided " ++
            "shader flips the surface normal on back faces (gl_FrontFacing / " ++
            "front_facing), so both are correctly lit from both sides as the " ++
            "camera auto-rotates past them — no dark back face, no culled geometry."),
        scene_wrap,
        ctx.p().class("hint")
            .text("Both quads auto-rotate. Back face = same color, different specular " ++
            "direction. The BLEND card draws back faces then front faces (two-pass " ++
            "cull) so it composites correctly from either side. The floor is " ++
            "single-sided (opaque, default cull-back)."),
        ctx.p().text("Drag to orbit · wheel to zoom. Both WebGL2 and WebGPU backends " ++
            "render double-sided surfaces identically."),
    });
}

/// /gl-cull: 7×7 = 49-cube dense grid for frustum-cull stress testing.
/// Cubes are spaced 3 units apart so portions of the grid leave the frustum as
/// the camera orbits/zooms, exercising the per-submesh cull path.
pub fn glSceneCull(ctx: *const verve.Context) !*verve.Node {
    const scene = ctx.glScene(.{
        .src = "/gl/cubegrid.vmesh",
        .env = "/gl/studio.venv",
        .poster = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='640' height='400' viewBox='0 0 640 400'%3E%3Crect width='640' height='400' rx='8' fill='%23121420'/%3E%3Ctext x='320' y='215' font-family='system-ui' font-size='48' font-weight='700' fill='%23f5f5f5' text-anchor='middle'%3EFrustum Cull%3C/text%3E%3C/svg%3E",
    })
        .camera(.{ .distance = 20.0, .pitch = 0.45, .yaw = 0.5 })
        .light(.{ .dir = .{ -0.4, -0.7, -0.6 }, .intensity = 3.0 })
        .autoRotate(0.2)
        .build();

    return ctx.main_().class("home gl-scene-page").children(.{
        ctx.h1("verve.gl — frustum culling"),
        ctx.p().text("A 7×7 grid of 49 unit cubes (spacing 3 units). As the camera orbits " ++
            "or zooms in, cubes outside the view frustum are skipped by the per-submesh " ++
            "frustum-cull pass — no draw call is issued for off-screen geometry."),
        ctx.div().attr("data-ref", "glcull-hud").class("hint"),
        scene,
        ctx.p().text("Drag to orbit · wheel to zoom. Cubes leaving the frustum are culled " ++
            "before any draw call reaches the GPU."),
    });
}

/// /gl-instanced: 16×16 = 256 cubes drawn in a single instanced draw call.
/// The vmesh carries EXT_mesh_gpu_instancing data (TRANSLATION/ROTATION/SCALE/
/// _COLOR_0 per instance). Each instance has a NON-uniform scale (sx/sz thin,
/// sy tall and row-varying) so the inverse-transpose normal correction in the
/// vertex shader is exercised — stretched faces stay correctly lit (three.js parity).
/// GlScene emits one draw_pbr_instanced command; the bridge issues a single
/// drawElementsInstanced (WebGL2) / drawIndexed(count, N) (WebGPU) for all 256.
pub fn glSceneInstanced(ctx: *const verve.Context) !*verve.Node {
    const scene = ctx.glScene(.{
        .src = "/gl/cubefield.vmesh",
        .env = "/gl/studio.venv",
        .poster = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='640' height='400' viewBox='0 0 640 400'%3E%3Crect width='640' height='400' rx='8' fill='%23121420'/%3E%3Ctext x='320' y='215' font-family='system-ui' font-size='48' font-weight='700' fill='%23f5f5f5' text-anchor='middle'%3EGPU Instancing%3C/text%3E%3C/svg%3E",
    })
        .camera(.{ .distance = 30.0, .pitch = 0.55, .yaw = 0.5 })
        .light(.{ .dir = .{ -0.4, -0.7, -0.6 }, .intensity = 3.0 })
        .autoRotate(0.15)
        .build();

    return ctx.main_().class("home gl-scene-page").children(.{
        ctx.h1("verve.gl — GPU instancing"),
        ctx.p().text("A 16×16 field of 256 hue-varied pillars rendered in a single " ++
            "instanced draw call. Each instance has a non-uniform scale (sx/sz thin, " ++
            "sy tall and row-varying), exercising the inverse-transpose normal correction " ++
            "in the vertex shader so stretched faces remain correctly lit. Per-instance " ++
            "TRANSLATION, ROTATION, SCALE, and _COLOR_0 attributes are stored in the " ++
            "vmesh instances section (decoded from EXT_mesh_gpu_instancing in the source GLB). " ++
            "GlScene emits one draw_pbr_instanced command; both WebGL2 and WebGPU backends " ++
            "dispatch a single instanced draw for all 256 cubes."),
        ctx.div().attr("data-ref", "glinstanced-hint").class("hint")
            .text("256 cubes · 1 instanced draw call · non-uniform scale (pillars) · normals corrected via inverse-transpose"),
        scene,
        ctx.p().text("Drag to orbit · wheel to zoom. All 256 cubes are drawn in one " ++
            "GPU call via variant_instanced + draw_pbr_instanced (wire tag 27)."),
    });
}

/// /gl-instanced-cull: 16×16 = 256-instance cube field with per-instance frustum culling.
/// Framed tightly (distance 14) so the field overflows the horizontal frustum; as the
/// camera auto-orbits, edge instances leave/re-enter view and the HUD culled count changes.
pub fn glSceneInstancedCull(ctx: *const verve.Context) !*verve.Node {
    const scene = ctx.glScene(.{
        .src = "/gl/cubefield.vmesh",
        .env = "/gl/studio.venv",
        .poster = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='640' height='400' viewBox='0 0 640 400'%3E%3Crect width='640' height='400' rx='8' fill='%23121420'/%3E%3Ctext x='320' y='215' font-family='system-ui' font-size='48' font-weight='700' fill='%23f5f5f5' text-anchor='middle'%3EInstanced Culling%3C/text%3E%3C/svg%3E",
    })
        .camera(.{ .distance = 14.0, .pitch = 0.5, .yaw = 0.4 })
        .light(.{ .dir = .{ -0.4, -0.7, -0.6 }, .intensity = 3.0 })
        .autoRotate(0.2)
        .build();

    return ctx.main_().class("home gl-scene-page").children(.{
        ctx.h1("verve.gl — per-instance frustum culling"),
        ctx.p().text("A 16×16 field of 256 hue-varied pillars drawn with GPU instancing. " ++
            "Each instance's world-space AABB is tested against the camera frustum every frame; " ++
            "instances fully outside the frustum are skipped before the GPU draw — no draw call " ++
            "overhead and no geometry processed for off-screen instances. The conservative " ++
            "whole-instance AABB test means no popping artefacts. The HUD below shows how many " ++
            "instances are culled as the camera orbits the field."),
        ctx.div().attr("data-ref", "glinstcull-hud").class("hint"),
        scene,
        ctx.p().text("Drag to orbit · wheel to zoom. Edge instances leave/enter the frustum " ++
            "as the camera orbits — watch the culled count in the HUD change."),
    });
}

/// /gl-instanced-multi: 8×8 = 64 instances of a two-material cube model.
/// The model has ONE mesh with TWO primitives (2 glTF materials):
///   primitive 0 = faces 0-2 → warm orange (baseColorFactor 0.9/0.45/0.1)
///   primitive 1 = faces 3-5 → cool blue   (baseColorFactor 0.1/0.45/0.9)
/// EXT_mesh_gpu_instancing carries 64 TRANSLATION/ROTATION/SCALE/_COLOR_0 records,
/// parsed as model-global → both submeshes are drawn for every instance,
/// each with its own material. Proves the slice-2 per-submesh instancing path.
pub fn glSceneInstancedMulti(ctx: *const verve.Context) !*verve.Node {
    const scene = ctx.glScene(.{
        .src = "/gl/cubefieldmulti.vmesh",
        .env = "/gl/studio.venv",
        .poster = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='640' height='400' viewBox='0 0 640 400'%3E%3Crect width='640' height='400' rx='8' fill='%23121420'/%3E%3Ctext x='320' y='215' font-family='system-ui' font-size='48' font-weight='700' fill='%23f5f5f5' text-anchor='middle'%3EMulti-Submesh Instancing%3C/text%3E%3C/svg%3E",
    })
        .camera(.{ .distance = 22.0, .pitch = 0.55, .yaw = 0.5 })
        .light(.{ .dir = .{ -0.4, -0.7, -0.6 }, .intensity = 3.0 })
        .autoRotate(0.15)
        .build();

    return ctx.main_().class("home gl-scene-page").children(.{
        ctx.h1("verve.gl — multi-submesh GPU instancing"),
        ctx.p().text("An 8×8 field of 64 two-material cubes instanced in a single " ++
            "scene command. Each cube model has ONE mesh / TWO primitives: " ++
            "faces 0-2 use a warm-orange material, faces 3-5 use a cool-blue material. " ++
            "EXT_mesh_gpu_instancing supplies 64 TRANSLATION/ROTATION/SCALE/_COLOR_0 " ++
            "records parsed as model-global — both submeshes render on every instance, " ++
            "each with its own PBR material (slice-2 per-submesh instancing)."),
        ctx.div().attr("data-ref", "glinstanced-multi-hint").class("hint")
            .text("64 cubes · 2 submeshes each · 2 materials · per-submesh instanced draw"),
        scene,
        ctx.p().text("Drag to orbit · wheel to zoom. Both submeshes appear on every instance " ++
            "with their respective materials via draw_pbr_instanced (wire tag 27)."),
    });
}

/// /gl-fog: 7×7 = 49-cube receding grid with distance fog enabled.
/// Linear fog from near=8 to far=34 with a soft blue-grey fog colour (0.42,0.5,0.62)
/// so near cubes stay crisp and farther cubes fade into the haze.
/// Fog applies after PBR lighting, before tonemap, on both WebGL2 and WebGPU.
pub fn glSceneFog(ctx: *const verve.Context) !*verve.Node {
    const scene = ctx.glScene(.{
        .src = "/gl/cubegrid.vmesh",
        .env = "/gl/studio.venv",
        .poster = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='640' height='400' viewBox='0 0 640 400'%3E%3Crect width='640' height='400' rx='8' fill='%230d0f17'/%3E%3Ctext x='320' y='215' font-family='system-ui' font-size='48' font-weight='700' fill='%23f5f5f5' text-anchor='middle'%3EFog%3C/text%3E%3C/svg%3E",
    })
        .camera(.{ .distance = 22.0, .pitch = 0.35, .yaw = 0.4 })
        .light(.{ .dir = .{ -0.4, -0.7, -0.6 }, .intensity = 3.0 })
        .fog(.{ .mode = .linear, .color = .{ 0.42, 0.5, 0.62 }, .near = 8.0, .far = 34.0 })
        .autoRotate(0.15)
        .build();

    return ctx.main_().class("home gl-scene-page").children(.{
        ctx.h1("verve.gl — distance fog"),
        ctx.p().text("Linear distance fog: near cubes are fully lit, far cubes dissolve " ++
            "into the fog colour. Fog is applied after PBR lighting, before tonemap — " ++
            "the same result on WebGL2 and WebGPU backends."),
        scene,
        ctx.p().text("Modes: linear (near→far ramp), exp, exp2 (density falloff). " ++
            "Set via .fog(.{ .mode, .color, .near, .far, .density }). " ++
            "Drag to orbit · wheel to zoom."),
    });
}

/// verve.gl wireframe demo — /gl-wireframe.
/// A UV sphere (lodsphere.vmesh, LOD 0 ≈ 2048 triangles) rendered as thin
/// edge lines using `.wireframe(.{ .color })`.  Surface is replaced entirely —
/// no shading, no texture, just the triangle grid.  Both WebGL2 and WebGPU
/// backends draw via the standalone variant_wireframe shader (own U{mvp,color}).
pub fn glSceneWireframe(ctx: *const verve.Context) !*verve.Node {
    const scene = ctx.glScene(.{
        .src = "/gl/lodsphere.vmesh",
        .env = "/gl/studio.venv",
        .poster = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='640' height='400' viewBox='0 0 640 400'%3E%3Crect width='640' height='400' rx='8' fill='%230d0f17'/%3E%3Ctext x='320' y='215' font-family='system-ui' font-size='48' font-weight='700' fill='%2333ff88' text-anchor='middle'%3EWireframe%3C/text%3E%3C/svg%3E",
    })
        .camera(.{ .distance = 2.5, .pitch = 0.35, .yaw = 0.5 })
        .wireframe(.{ .color = .{ 0.2, 1.0, 0.5 } })
        .autoRotate(0.2)
        .build();

    return ctx.main_().class("home gl-scene-page").children(.{
        ctx.h1("verve.gl — wireframe mode"),
        ctx.p().text("Wireframe mode renders the mesh\u{2019}s triangle edges as thin lines, " ++
            "replacing the shaded surface (.wireframe parity with three.js). " ++
            "The UV sphere\u{2019}s latitude\u{2013}longitude grid makes the " ++
            "triangle topology immediately visible. Rendered via the standalone " ++
            "variant_wireframe shader (own MVP+color uniforms, no lighting or tonemap). " ++
            "Both WebGL2 and WebGPU backends."),
        scene,
        ctx.p().text("Enable with .wireframe(.{ .color = .{ r, g, b } }) on any GlScene. " ++
            "Up to 8192 triangles per mesh are supported (edge data pre-computed " ++
            "at asset-build time). Drag to orbit \u{00b7} wheel to zoom."),
    });
}

/// verve.gl morph-targets demo — /gl-morph.
/// A 5×5 subdivided plane with 3 morph targets (Bulge/Wave/Twist) and a
/// baked LINEAR weight animation that cycles through the targets. The
/// GlScene island reads morph.vmesh, decodes the morph texture (RGBA16F,
/// width=vertex_count, height=target_count*2) and plays the baked clip.
/// A runtime weight-slider scrubs target 0 (Bulge) independently of the clip.
pub fn glSceneMorph(ctx: *const verve.Context) !*verve.Node {
    const scene = ctx.glScene(.{
        .src = "/gl/morph.vmesh",
        .env = "/gl/studio.venv",
        .poster = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='640' height='400' viewBox='0 0 640 400'%3E%3Crect width='640' height='400' rx='8' fill='%230d0f17'/%3E%3Ctext x='320' y='215' font-family='system-ui' font-size='48' font-weight='700' fill='%23f5f5f5' text-anchor='middle'%3EMorph%3C/text%3E%3C/svg%3E",
    })
        .camera(.{ .distance = 3.5, .pitch = 0.7, .yaw = 0.4 })
        .light(.{ .dir = .{ -0.4, -0.7, -0.6 }, .intensity = 3.5 })
        .autoRotate(0.2)
        .build();

    // Controls wired to GlScene chunk exports via z-on-click. Must live INSIDE
    // the island subtree (scene IS the <verve-island> node) so the bridge can
    // resolve chunkExports["GlScene"][action].
    // glmorph_bulge_on: locks target 0 to 1.0, overriding the baked clip.
    // glmorph_reset:    releases the runtime lock; baked clip resumes target 0.
    _ = scene.children(.{
        ctx.div().class("gl-controls").children(.{
            ctx.el("button").attr("z-on-click", "glmorph_bulge_on").text("Bulge +"),
            ctx.el("button").attr("z-on-click", "glmorph_reset").text("Reset"),
        }),
    });

    return ctx.main_().class("home gl-scene-page").children(.{
        ctx.h1("verve.gl — morph targets (blend shapes)"),
        ctx.p().text("A 5×5 subdivided plane with three blend shapes: Bulge (centre " ++
            "pushed up), Wave (sine deformation along X), and Twist (rotation around Y " ++
            "proportional to Z). A baked LINEAR weight animation cycles Wave and Twist; " ++
            "Bulge is left to the runtime control below. The morph texture is RGBA16F " ++
            "(width=vertex_count, height=target_count×2), sampled per-vertex in the " ++
            "shader (variant_morph = 1<<14). Renders on WebGL2 and WebGPU."),
        scene,
        ctx.p().text("The baked clip animates Wave and Twist. \u{201c}Bulge +\u{201d} " ++
            "drives target 0 at runtime (morph_runtime_set[0]=true), adding a centre " ++
            "bulge on top of the ongoing animation; \u{201c}Reset\u{201d} releases it. " ++
            "Runtime weights override the baked clip per index. " ++
            "Deferred: skinned+morph, TANGENT deltas."),
    });
}

/// verve.gl 16-target morph demo — /gl-morph16.
/// A 5×5 plane with 16 blend shapes, each deforming a DISTINCT single vertex
/// upward by 1.0. The baked LINEAR clip sets ALL 16 weights to 0.5 at t=1s so
/// all 16 active simultaneously — only possible with cap-32 (was cap-8).
/// CDP differentiator: with old cap-8 only 8 vertices lift; with cap-32 all 16.
pub fn glSceneMorph16(ctx: *const verve.Context) !*verve.Node {
    const scene = ctx.glScene(.{
        .src = "/gl/morph16.vmesh",
        .env = "/gl/studio.venv",
        .poster = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='640' height='400' viewBox='0 0 640 400'%3E%3Crect width='640' height='400' rx='8' fill='%230d0f17'/%3E%3Ctext x='320' y='215' font-family='system-ui' font-size='48' font-weight='700' fill='%23f5f5f5' text-anchor='middle'%3EMorph16%3C/text%3E%3C/svg%3E",
    })
        .camera(.{ .distance = 3.5, .pitch = 0.7, .yaw = 0.4 })
        .light(.{ .dir = .{ -0.4, -0.7, -0.6 }, .intensity = 3.5 })
        .autoRotate(0.2)
        .build();

    return ctx.main_().class("home gl-scene-page").children(.{
        ctx.h1("verve.gl — 16 simultaneous morph targets (cap-32)"),
        ctx.p().text("A 5×5 subdivided plane with 16 blend shapes (T0..T15), each " ++
            "deforming a DISTINCT single vertex upward. A LINEAR clip sets ALL 16 " ++
            "weights to 0.5 simultaneously at t=1s — previously impossible with the " ++
            "old cap-8 active-set limit. With cap-32, all 16 vertices lift at once. " ++
            "Validates the morph active-set widening on both WebGL2 and WebGPU."),
        scene,
    });
}

/// /gl-multi: TWO independent GlScene islands on one page (P7 multi-instance).
/// Each `<verve-island data-name="GlScene">` gets its own per-instance state
/// slot keyed by vid; the bridge selects the right instance before each frame /
/// event. Distinct assets + cameras + opposite auto-rotation make the
/// independence visible — neither scene mirrors or freezes the other.
pub fn glSceneMulti(ctx: *const verve.Context) !*verve.Node {
    const poster = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='640' height='400' viewBox='0 0 640 400'%3E%3Crect width='640' height='400' rx='8' fill='%23121420'/%3E%3Ctext x='320' y='215' font-family='system-ui' font-size='48' font-weight='700' fill='%23f5f5f5' text-anchor='middle'%3E3D%3C/text%3E%3C/svg%3E";

    const scene_a = ctx.glScene(.{ .src = "/gl/demo.vmesh", .env = "/gl/studio.venv", .poster = poster })
        .camera(.{ .distance = 4, .pitch = 0.3, .yaw = 0.6 })
        .light(.{ .dir = .{ -0.4, -0.7, -0.6 }, .intensity = 3.0 })
        .autoRotate(0.5)
        .build();

    const scene_b = ctx.glScene(.{ .src = "/gl/shadow.vmesh", .env = "/gl/studio.venv", .poster = poster })
        .camera(.{ .distance = 9, .pitch = 0.55, .yaw = -0.5 })
        .light(.{ .dir = .{ -0.45, -0.82, -0.35 }, .intensity = 3.2 })
        .autoRotate(-0.35)
        .build();

    const box = struct {
        fn go(c: *const verve.Context, scene: *verve.Node) *verve.Node {
            return c.div().class("gl-wrap").children(.{
                c.div()
                    .attr("style", "width:100%;max-width:420px;aspect-ratio:1/1;display:block;background:#121420;border-radius:8px;margin:0 auto")
                    .children(.{scene}),
            });
        }
    }.go;

    return ctx.main_().class("home gl-scene-page").children(.{
        ctx.h1("verve.gl — two scenes, one page"),
        ctx.p().text("Two independent GlScene islands (P7 multi-instance): a model and " ++
            "a cube-on-floor, each with its own camera, light, and auto-rotation. " ++
            "Each owns a separate per-instance state slot in the one shared chunk."),
        ctx.div()
            .attr("style", "display:grid;grid-template-columns:1fr 1fr;gap:1rem;align-items:start")
            .children(.{ box(ctx, scene_a), box(ctx, scene_b) }),
        ctx.p().class("hint")
            .text("Drag either scene to orbit it independently · they spin opposite ways."),
    });
}

/// /push-multi: TWO PushProbe islands of the same name on one page, each
/// subscribing to the "viz" push channel with its own vid. Both bound `probe`
/// signals must move off "init" — the P7 push-routing regression (pre-fix the
/// bridge delivered every pushed frame to the first DOM instance only).
pub fn pushMulti(ctx: *const verve.Context) !*verve.Node {
    const probe = struct {
        fn go(c: *const verve.Context, label: []const u8) *verve.Node {
            const inner = c.div().attr("style", "padding:1rem;border:1px solid #333;border-radius:8px;margin:.5rem 0").children(.{
                c.span().text(label),
                c.span().bind("probe").attr("style", "display:block;color:#0f0;font:700 28px monospace;padding-top:.25rem").text("init"),
            });
            return verve.island(c, .{ .name = "PushProbe" }, inner);
        }
    }.go;
    return ctx.main_().class("home").children(.{
        ctx.h1("verve.gl — push routing (two instances)"),
        ctx.p().text("Two same-name PushProbe islands subscribe to the same push " ++
            "channel, each with its own vid. Both probes must move off \"init\" to " ++
            "\"GOT N\" — proving pushed frames reach the right instance, not just the first."),
        probe(ctx, "Instance A:"),
        probe(ctx, "Instance B:"),
    }).build();
}

/// /gl-lod: distance-based LOD demo — three UV-sphere LOD levels embedded in a
/// single vmesh v15. The HUD shows active LOD level and submesh count. Zoom out
/// to trigger transitions: LOD 0 (nearest/high-poly) → LOD 1 → LOD 2 (far/low-poly).
/// The scene starts close so LOD 0 is active; scroll/zoom out crosses the thresholds.
pub fn glSceneLod(ctx: *const verve.Context) !*verve.Node {
    const scene = ctx.glScene(.{
        .src = "/gl/lodsphere.vmesh",
        .env = "/gl/studio.venv",
        .poster = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='640' height='400' viewBox='0 0 640 400'%3E%3Crect width='640' height='400' rx='8' fill='%23121420'/%3E%3Ctext x='320' y='215' font-family='system-ui' font-size='48' font-weight='700' fill='%23f5f5f5' text-anchor='middle'%3ELOD%3C/text%3E%3C/svg%3E",
    })
        .camera(.{ .distance = 2.5, .pitch = 0.3, .yaw = 0.5 })
        .light(.{ .dir = .{ -0.4, -0.7, -0.6 }, .intensity = 3.0 })
        .build();

    return ctx.main_().class("home gl-scene-page").children(.{
        ctx.h1("verve.gl — distance-based LOD"),
        ctx.p().text("Three UV-sphere LOD levels packed into a single vmesh v15. " ++
            "The runtime picks the active level by squared camera distance: " ++
            "LOD 0 = ~2048 tri (close), LOD 1 = ~128 tri (medium), LOD 2 = ~32 tri (far)."),
        ctx.div().attr("data-ref", "gllod-hud").class("hint"),
        scene,
        ctx.p().text("Wheel to zoom · watch the HUD. The silhouette visibly coarsens " ++
            "as you zoom out past the LOD 1 and LOD 2 thresholds."),
    });
}

/// /gl-ortho: Orthographic vs. Perspective — 7×7 cube grid shown side by side.
/// Left = perspective (default), right = orthographic. Same camera/light/rotation
/// on both so the only difference is the projection matrix. Under perspective the
/// far rows shrink with distance; under orthographic every row stays the same size
/// (parallel rays — the defining property of ortho projection).
pub fn glSceneOrtho(ctx: *const verve.Context) !*verve.Node {
    const scene_persp = ctx.glScene(.{
        .src = "/gl/cubegrid.vmesh",
        .env = "/gl/studio.venv",
        .poster = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='640' height='400' viewBox='0 0 640 400'%3E%3Crect width='640' height='400' rx='8' fill='%230d0f17'/%3E%3Ctext x='320' y='215' font-family='system-ui' font-size='36' font-weight='700' fill='%23f5f5f5' text-anchor='middle'%3EPerspective%3C/text%3E%3C/svg%3E",
    })
        .camera(.{ .distance = 22.0, .pitch = 0.35, .yaw = 0.4 })
        .light(.{ .dir = .{ -0.4, -0.7, -0.6 }, .intensity = 3.0 })
        .autoRotate(0.15)
        .build();

    const scene_ortho = ctx.glScene(.{
        .src = "/gl/cubegrid.vmesh",
        .env = "/gl/studio.venv",
        .poster = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='640' height='400' viewBox='0 0 640 400'%3E%3Crect width='640' height='400' rx='8' fill='%230d0f17'/%3E%3Ctext x='320' y='215' font-family='system-ui' font-size='36' font-weight='700' fill='%23f5f5f5' text-anchor='middle'%3EOrthographic%3C/text%3E%3C/svg%3E",
    })
        .camera(.{ .distance = 22.0, .pitch = 0.35, .yaw = 0.4 })
        .light(.{ .dir = .{ -0.4, -0.7, -0.6 }, .intensity = 3.0 })
        .projection(.{ .mode = .orthographic, .ortho_height = 12.0 })
        .autoRotate(0.15)
        .build();

    const labeled = struct {
        fn go(c: *const verve.Context, label: []const u8, scene: *verve.Node) *verve.Node {
            return c.div()
                .attr("style", "display:flex;flex-direction:column;gap:.5rem")
                .children(.{
                c.p()
                    .attr("style", "text-align:center;font-weight:600;font-size:.9rem;color:#8b949e;margin:0")
                    .text(label),
                c.div()
                    .attr("style", "width:100%;aspect-ratio:8/5;display:block;background:#0d0f17;border-radius:8px;overflow:hidden")
                    .children(.{scene}),
            });
        }
    }.go;

    return ctx.main_().class("home gl-scene-page").children(.{
        ctx.h1("verve.gl — orthographic projection"),
        ctx.p().text("Same 7×7 cube grid, same camera, same light — only the projection " ++
            "matrix differs. Under perspective (left) far rows shrink with distance. " ++
            "Under orthographic (right) all rows stay the same on-screen size: " ++
            "parallel rays, no foreshortening."),
        ctx.div()
            .attr("style", "display:grid;grid-template-columns:1fr 1fr;gap:1rem;align-items:start;margin:1rem 0")
            .children(.{ labeled(ctx, "Perspective", scene_persp), labeled(ctx, "Orthographic", scene_ortho) }),
        ctx.p().text("Orthographic removes depth cues entirely — useful for CAD, isometric " ++
            "views, and shadow-map passes. Drag to orbit · wheel to zoom."),
    });
}

/// /gl-clip: world-space clipping planes demo.
/// A cube on a floor (shadow.vmesh) cut by a single diagonal clip plane through
/// the origin.  Fragments where dot(normal, worldPos) + constant < 0 are
/// discarded; the surviving half reveals the solid interior cross-section.
/// No fog / morph / point-shadow — those disable clipping in v1.
pub fn glSceneClip(ctx: *const verve.Context) !*verve.Node {
    const scene = ctx.glScene(.{
        .src = "/gl/shadow.vmesh",
        .env = "/gl/studio.venv",
        .poster = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='640' height='400' viewBox='0 0 640 400'%3E%3Crect width='640' height='400' rx='8' fill='%230d0f17'/%3E%3Ctext x='320' y='215' font-family='system-ui' font-size='48' font-weight='700' fill='%23f5f5f5' text-anchor='middle'%3EClip%3C/text%3E%3C/svg%3E",
    })
        .camera(.{ .distance = 9, .pitch = 0.55, .yaw = 0.7 })
        .light(.{ .dir = .{ -0.45, -0.82, -0.35 }, .intensity = 3.2 })
        .clipPlanes(&.{.{ .normal = .{ 1, 0.4, 0 }, .constant = 0 }})
        .autoRotate(0.2)
        .build();

    return ctx.main_().class("home gl-scene-page").children(.{
        ctx.h1("verve.gl — clip planes"),
        ctx.p().text("World-space clipping: fragments where " ++
            "dot(normal, worldPos) + constant \u{2265} 0 are kept; " ++
            "fragments below the plane are discarded. " ++
            "The diagonal cut through the cube reveals its solid interior. " ++
            "Up to 4 global clip planes via " ++
            ".clipPlanes(&.{ ClipPlane{ .normal, .constant } }). " ++
            "Both WebGL2 and WebGPU backends. " ++
            "(v1 note: not combinable with fog / morph / point-shadow yet.)"),
        scene,
        ctx.p().text("Single plane: normal = (1, 0.4, 0), constant = 0. " ++
            "Drag to orbit to inspect the cross-section from different angles."),
    });
}

pub fn page(ctx: *const verve.Context, body: *verve.Node) !*verve.Node {
    // Provide a default title only if the page didn't set one of its own.
    try ctx.setTitleIfUnset("Verve");

    // Drain ctx.head into a static byte buffer that we emit verbatim
    // inside <head>. The accumulator already produces <meta charset>,
    // <title>, plus any meta/link/json-ld the page contributed.
    var aw: std.Io.Writer.Allocating = .init(ctx.alloc());
    try ctx.head.?.render(&aw.writer);
    const head_html = aw.written();

    return ctx.el("html").children(.{
        ctx.el("head").children(.{
            ctx.raw(head_html),
            ctx.style(
                \\body{font:16px system-ui;margin:2rem;background:#0e0e10;color:#f5f5f5}
                \\.counter-card{padding:1.5rem;border:1px solid #333;border-radius:8px;max-width:24rem}
                \\.count{font-size:3rem;display:block;margin:1rem 0;font-variant-numeric:tabular-nums}
                \\button{font:inherit;padding:.5rem 1rem;margin-right:.5rem;background:#1f6feb;color:#fff;border:0;border-radius:4px;cursor:pointer}
                \\button:hover{background:#388bfd}
                \\.counter-form{display:inline}
                \\a{color:#58a6ff;text-decoration:none}
                \\a:hover{text-decoration:underline}
                \\.home{max-width:36rem}
                \\.todo-form{display:flex;gap:.5rem;margin:1rem 0}
                \\.todo-form input[type=text]{flex:1;padding:.5rem;background:#1c1c1f;color:inherit;border:1px solid #333;border-radius:4px;font:inherit}
                \\.todo-list{list-style:none;padding:0;margin:1rem 0}
                \\.todo-list li{display:flex;align-items:center;gap:.5rem;padding:.5rem;border-bottom:1px solid #222}
                \\.todo-list li span{flex:1}
                \\.todo-remove button{background:#3d1d1d;padding:.25rem .5rem}
                \\.todo-remove button:hover{background:#5b2727}
                \\.hint{color:#8b949e;font-size:.85rem;margin:.25rem 0 .75rem}
                \\.anim-deck{display:flex;gap:.5rem;margin:1rem 0;flex-wrap:wrap}
                \\.anim-card{width:3rem;height:3rem;display:flex;align-items:center;justify-content:center;background:#1f6feb;border-radius:8px;font-weight:600}
                \\.anim-controls{display:flex;gap:.25rem;flex-wrap:wrap;margin:.5rem 0}
                \\.anim-controls button{padding:.35rem .7rem}
                \\.anim-pulse{width:.9rem;height:.9rem;border-radius:50%;background:#58a6ff;margin:.5rem 0}
                \\.anim-spacer{height:60vh}
                \\.anim-scroll h2.in-view{color:#58a6ff}
                \\.anim-pin-panel{padding:1rem;border:1px solid #333;border-radius:8px;background:#16161a}
                \\.anim-scrub-bar{height:.5rem;border-radius:4px;background:#1f6feb;transform-origin:left center;margin-bottom:.75rem}
                \\.anim-probe{padding:1rem;border:1px dashed #444;border-radius:8px}
                \\.anim-orbit-wrap{position:relative;margin:1rem 0}
                \\.anim-orbiter{position:absolute;top:-6px;left:-6px;width:12px;height:12px;background:#f59e0b;clip-path:polygon(0 0,100% 50%,0 100%)}
                \\.anim-scrub-dot{position:absolute;top:-5px;left:-5px;width:10px;height:10px;border-radius:50%;background:#58a6ff}
                \\.drag-pen{position:relative;height:200px;border:1px dashed #444;border-radius:8px;margin:1rem 0;overflow:hidden}
                \\.drag-card{cursor:grab;width:4rem;height:4rem}
                \\.drag-card.dragging{box-shadow:0 0 0 2px #58a6ff;opacity:.9}
                \\.st-char,.st-word{display:inline-block;will-change:transform}
                \\.flip-grid{display:flex;gap:.5rem;flex-wrap:wrap;margin:.75rem 0;max-width:18rem}
                \\.fcard{width:3.5rem;height:3.5rem}
                \\.fcard.fcard-big{width:6rem;height:6rem;font-size:1.25rem}
                \\.drop-row{display:flex;gap:.5rem;margin:.75rem 0}
                \\.drop-zone{flex:1;min-height:4rem;display:flex;align-items:center;justify-content:center;border:1px dashed #444;border-radius:8px;color:#8b949e}
                \\.drop-zone.drop-hover{border-color:#58a6ff;color:#58a6ff;background:#11161f}
                \\.smooth-page{max-width:none}
                \\.smooth-hero{position:relative;min-height:100vh;display:flex;flex-direction:column;justify-content:center;overflow:hidden}
                \\.smooth-bg,.smooth-mid{position:absolute;inset:-20% 0;pointer-events:none;will-change:transform}
                \\.smooth-bg{background:radial-gradient(circle at 30% 40%,#16233a 0,transparent 60%)}
                \\.smooth-mid{background:radial-gradient(circle at 70% 60%,#1b2a1f 0,transparent 50%)}
                \\.smooth-badge{display:inline-block;align-self:flex-start;padding:.4rem .8rem;border:1px solid #444;border-radius:999px;background:#16161a;will-change:transform}
                \\.smooth-section{min-height:100vh;display:flex;align-items:center;justify-content:center;border-top:1px dashed #2a2a2e}
                \\.smooth-section h2{font-size:3rem}
                \\#snap-deck{position:relative}
                \\.smooth-deck-bar{position:absolute;top:0;left:0;right:0;height:.4rem;background:#58a6ff;transform-origin:left center;z-index:5}
                \\.viz-card svg{touch-action:none;max-width:100%}
                \\.viz-node{cursor:grab}
                \\.viz-node.selected circle{stroke:#fff;stroke-width:3}
                \\.viz-node.collapsed circle{stroke:#f59e0b;stroke-width:3;stroke-dasharray:3 2}
                \\.viz-controls{display:flex;gap:.5rem;margin-bottom:.5rem}
                \\.viz-controls .live-on{background:#10b981}
            ),
        }),
        ctx.el("body").children(.{
            body,
            ctx.script("/verve.js"),
        }),
    }).build();
}
