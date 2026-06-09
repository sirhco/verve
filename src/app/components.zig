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
    });
    const graph_svg = verve.viz.renderGraphInteractive(ctx, g, gopts);
    const controls = ctx.div().class("viz-controls").children(.{
        ctx.el("button").attr("z-on-click", "viz_add_node").text("+ node"),
        ctx.el("button").attr("z-on-click", "viz_remove_node").text("− node"),
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
        ctx.section().class("card viz-card").children(.{ ctx.h2("Force-directed graph — interactive"), ctx.p().class("hint").text("Scroll to zoom, drag to pan, drag a node, hover for a label, click to select. +/− node mutate the graph at runtime — zoom + selection survive."), graph_island }),
        ctx.section().class("card viz-card").children(.{ ctx.h2("Layered DAG"), ctx.p().class("hint").text("The src→emit skip edge spans 3 layers — it routes through virtual-node bends rather than cutting straight across."), dag_svg }),
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
        ctx.p().children(.{verve.link(ctx, "/", "← Home", .{})}),
    }).build();
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
        ctx.p().children(.{verve.link(ctx, "/work/hello-world", "Path-param demo (/work/:slug) →", .{})}),
    }).build();
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
                \\.viz-card svg{touch-action:none;max-width:100%}
                \\.viz-node{cursor:grab}
                \\.viz-node.selected circle{stroke:#fff;stroke-width:3}
                \\.viz-controls{display:flex;gap:.5rem;margin-bottom:.5rem}
            ),
        }),
        ctx.el("body").children(.{
            body,
            ctx.script("/verve.js"),
        }),
    }).build();
}
