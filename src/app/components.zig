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
        dragSection(ctx),
        scrollSection(ctx),
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
        _ = grid.children(.{
            ctx.div().class("anim-card fcard").attr("data-vkey", k).textInt(i + 1),
        });
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
    });
}

/// Draggable demo (phase 4): a zero-wasm bounded drag card with inertia
/// + grid snap — pure data-drag, no island.
fn dragSection(ctx: *const verve.Context) *verve.Node {
    const anim = verve.anim;
    const a = ctx.alloc();

    return ctx.el("section").class("anim-drag").children(.{
        ctx.h2("Draggable: bounds + inertia + grid snap"),
        ctx.p().class("hint").text("Pure data-drag — no island, no wasm. Flick the card; it coasts and settles on the 40px grid inside the pen."),
        ctx.div().class("drag-pen").children(.{
            ctx.div().class("anim-card drag-card").text("drag")
                .draggable(anim.draggable(a, .{
                .bounds = .{ .selector = ".drag-pen" },
                .inertia = .on,
                .snap = .{ .grid = .{ .x = 40, .y = 40 } },
                .toggle_class = "dragging",
            })),
        }),
    });
}

/// ScrollTrigger demo (phase 2): scroll-gated stagger, zero-wasm class
/// reveal, and a pinned scrubbed panel (markers on for DX show-off).
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
