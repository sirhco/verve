//! viz-live page components.

const std = @import("std");
const verve = @import("verve");
const islands = @import("islands.zig");

// ---------------------------------------------------------------------------
// Shared island builder — VizGraphInteractive
// ---------------------------------------------------------------------------

/// Build one VizGraphInteractive island (SSR graph + controls). Shared by
/// index() and vizMulti() so the island-wiring is not duplicated.
fn vizGraphIsland(
    ctx: *const verve.Context,
    nodes: []const verve.viz.GraphNode,
    edges: []const verve.viz.GraphEdge,
    layout: verve.viz.Layout,
    gopts: verve.viz.GraphOpts,
) !*verve.Node {
    const g = verve.viz.Graph{ .nodes = nodes, .edges = edges, .layout = layout };
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
        .layout = @intFromEnum(layout),
        .margin = gopts.margin,
        .edge_routing = @intFromEnum(gopts.edge_routing),
    });
    const graph_svg = verve.viz.renderGraphInteractive(ctx, g, gopts);
    const controls = ctx.div().class("viz-controls").children(.{
        ctx.el("button").attr("z-on-click", "viz_toggle_live").attr("data-ref", "viz-live-btn").text("● live"),
        ctx.el("button").attr("z-on-click", "viz_layout_cycle").attr("data-ref", "viz-layout-btn").text("⟳ force"),
        ctx.el("button").attr("z-on-click", "viz_add_node").text("+ node"),
        ctx.el("button").attr("z-on-click", "viz_remove_node").text("− node"),
    });
    const graph_inner = ctx.div().children(.{ controls, graph_svg });
    return verve.island(ctx, .{ .name = "VizGraphInteractive", .props = props }, graph_inner);
}

// ---------------------------------------------------------------------------
// Route: / — single live SVG graph
// ---------------------------------------------------------------------------

pub fn index(ctx: *const verve.Context) !*verve.Node {
    // Mirror of api.zig's `vizBuild(0, ...)` base model: 3 stable nodes, 2 edges.
    const nodes = [_]verve.viz.GraphNode{
        .{ .id = "core", .label = "core" },
        .{ .id = "io", .label = "io" },
        .{ .id = "ui", .label = "ui" },
    };
    const edges = [_]verve.viz.GraphEdge{
        .{ .from = "core", .to = "io" },
        .{ .from = "core", .to = "ui" },
    };
    const gopts = verve.viz.GraphOpts{
        .width = 640,
        .height = 420,
        .node_color = "#1f6feb",
        .edge_color = "#30363d",
        .label_color = "#f5f5f5",
    };
    const island = try vizGraphIsland(ctx, &nodes, &edges, .force, gopts);

    return ctx.main_().children(.{
        ctx.h1("Live graph over SSE push"),
        ctx.p().text("Click ● live: the server starts mutating its graph once per second and broadcasts seq-ordered wire deltas on the `viz` push channel (GET /push?channel=viz). The island applies each delta in order and resyncs from the pull snapshot (/api/vizGraph) on any gap — kill and restart the server to watch EventSource reconnect and recover."),
        ctx.section().class("card").children(.{island}),
        ctx.p().class("hint").text("Also wired: scroll to zoom, drag to pan, drag a node (pointer-captured — works past the svg edge), hover for a label, click to select, double-click to collapse a subtree (+N badge), ⟳ cycles tree/radial/force/dag with a tween, +/− mutates locally. Zoom, selection, and collapse all survive every live tick."),
        ctx.p().class("hint").children(.{
            ctx.span().text("Watch the wire: "),
            ctx.code("curl -N 'http://127.0.0.1:8080/push?channel=viz'"),
            ctx.span().text(" while live is on."),
        }),
        ctx.p().children(.{
            ctx.a("/multi", "Multi-instance →"),
            ctx.span().text(" | "),
            ctx.a("/canvas", "Canvas →"),
        }),
    }).build();
}

// ---------------------------------------------------------------------------
// Route: /multi — two VizGraphInteractive islands (multi-parent + orthogonal)
// ---------------------------------------------------------------------------

/// Multi-instance viz demo: two independent VizGraphInteractive islands on one
/// page, proving per-instance reactive dispatch. Graph 1 has a multi-parent
/// node topology (dblclick a parent to collapse — the child stays via the other
/// parent). Graph 2 uses edge_routing=.orthogonal so edges route as Manhattan
/// runs with rounded corners.
pub fn vizMulti(ctx: *const verve.Context) !*verve.Node {
    // --- Graph 1: Framework dependency graph (force layout, blue) -----------
    // Multi-parent topology: both "server" and "viz" feed into "client",
    // so dblclick-collapsing "server" leaves "client" visible via "viz".
    const nodes1 = [_]verve.viz.GraphNode{
        .{ .id = "core", .label = "core" },
        .{ .id = "server", .label = "server" },
        .{ .id = "client", .label = "client" },
        .{ .id = "desktop", .label = "desktop" },
        .{ .id = "viz", .label = "viz" },
        .{ .id = "cli", .label = "cli" },
    };
    const edges1 = [_]verve.viz.GraphEdge{
        .{ .from = "core", .to = "server" },
        .{ .from = "core", .to = "client" },
        .{ .from = "core", .to = "desktop" },
        .{ .from = "core", .to = "viz" },
        .{ .from = "viz", .to = "client" },
        .{ .from = "server", .to = "cli" },
    };
    const gopts1 = verve.viz.GraphOpts{
        .width = 560,
        .height = 380,
        .node_color = "#1f6feb",
        .edge_color = "#30363d",
        .label_color = "#f5f5f5",
    };
    const island1 = try vizGraphIsland(ctx, &nodes1, &edges1, .force, gopts1);

    // --- Graph 2: CI/CD pipeline (dag layout, amber, orthogonal edges) ------
    const nodes2 = [_]verve.viz.GraphNode{
        .{ .id = "source", .label = "source" },
        .{ .id = "build", .label = "build" },
        .{ .id = "test", .label = "test" },
        .{ .id = "lint", .label = "lint" },
        .{ .id = "package", .label = "package" },
        .{ .id = "deploy", .label = "deploy" },
        .{ .id = "monitor", .label = "monitor" },
    };
    const edges2 = [_]verve.viz.GraphEdge{
        .{ .from = "source", .to = "build" },
        .{ .from = "build", .to = "test" },
        .{ .from = "build", .to = "lint" },
        .{ .from = "test", .to = "package" },
        .{ .from = "lint", .to = "package" },
        .{ .from = "package", .to = "deploy" },
        .{ .from = "deploy", .to = "monitor" },
    };
    const gopts2 = verve.viz.GraphOpts{
        .width = 560,
        .height = 380,
        .node_color = "#d97706",
        .edge_color = "#44403c",
        .label_color = "#fef3c7",
        .edge_routing = .orthogonal,
    };
    const island2 = try vizGraphIsland(ctx, &nodes2, &edges2, .dag, gopts2);

    return ctx.main_().children(.{
        ctx.h1("Multi-Instance Viz Demo"),
        ctx.p().text("Two independent VizGraphInteractive islands — each has its own " ++
            "reactive state. +/− node, ● live, and ⟳ layout controls on each " ++
            "panel affect only that instance."),
        ctx.section().class("card viz-card").children(.{
            ctx.h2("Graph 1 — Framework deps (force, multi-parent)"),
            ctx.p().class("hint").text("\"client\" has two parents (core + viz). Dblclick \"core\" → subtree collapses but client stays visible via viz."),
            island1,
        }),
        ctx.section().class("card viz-card").children(.{
            ctx.h2("Graph 2 — CI/CD Pipeline (dag, orthogonal edges)"),
            ctx.p().class("hint").text("edge_routing = .orthogonal — Manhattan runs through reserved virtual-node channels, corners rounded."),
            island2,
        }),
        ctx.p().children(.{
            ctx.a("/", "← Home"),
            ctx.span().text(" | "),
            ctx.a("/canvas", "Canvas →"),
        }),
    }).build();
}

// ---------------------------------------------------------------------------
// Route: /canvas — VizGraphCanvas island (canvas2d fetch + live)
// ---------------------------------------------------------------------------

/// Shared builder: one VizGraphCanvas island (canvas + controls wrapper).
fn vizCanvasIsland(ctx: *const verve.Context, heading: []const u8) !*verve.Node {
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
    const controls = ctx.div().class("viz-controls").children(.{
        ctx.el("button").attr("z-on-click", "vizcanvas_toggle_live").attr("data-ref", "vizcanvas-live-btn").text("● live"),
    });
    const inner = ctx.section().class("card").children(.{
        ctx.h2(heading),
        controls,
        canvas,
    });
    return verve.island(ctx, .{ .name = "VizGraphCanvas" }, inner);
}

/// Canvas render path demo — /canvas. A ~1500-node server-authored graph
/// fetched from /viz/graph.bin and drawn via the VizGraphCanvas island.
/// Click ● live to subscribe to the vizcanvas push channel (256-node live model).
pub fn vizCanvas(ctx: *const verve.Context) !*verve.Node {
    const island = try vizCanvasIsland(ctx, "Large graph — canvas2d render path");
    return ctx.main_().children(.{
        ctx.h1("verve.viz — canvas render"),
        ctx.p().text("A ~1500-node server-authored graph fetched from /viz/graph.bin " ++
            "and drawn to a single canvas2d (vs the SVG-DOM path): one batched draw " ++
            "call per frame. Drag to pan, wheel to zoom, hover/click a node to highlight. " ++
            "Click ● live to subscribe to live streaming (256-node graph, updates each tick)."),
        island,
        ctx.p().children(.{
            ctx.a("/", "← Home"),
            ctx.span().text(" | "),
            ctx.a("/multi", "Multi-instance →"),
        }),
    }).build();
}

// ---------------------------------------------------------------------------
// Page shell
// ---------------------------------------------------------------------------

pub fn page(ctx: *const verve.Context, body: *verve.Node) !*verve.Node {
    return ctx.el("html").children(.{
        ctx.el("head").children(.{
            ctx.meta("charset", "utf-8"),
            ctx.title("Verve viz-live"),
            ctx.style(
                \\body{font:16px/1.6 system-ui;margin:0;background:#0e0e10;color:#e6e6e6}
                \\main{max-width:52rem;margin:2rem auto;padding:0 1.5rem}
                \\h1{margin-top:0}
                \\.card{background:#15151a;border:1px solid #30363d;border-radius:10px;padding:1.25rem}
                \\.card svg{touch-action:none;max-width:100%}
                \\.viz-card{margin-bottom:1.5rem}
                \\button{font:inherit;padding:.4rem .8rem;background:#21262d;color:#e6e6e6;border:1px solid #30363d;border-radius:6px;cursor:pointer}
                \\button:hover{filter:brightness(1.2)}
                \\.viz-controls{display:flex;gap:.5rem;margin-bottom:.75rem}
                \\.viz-controls .live-on{background:#10b981;color:#04110c}
                \\.viz-node{cursor:grab}
                \\.viz-node.selected circle{stroke:#fff;stroke-width:3}
                \\.viz-node.collapsed circle{stroke:#f59e0b;stroke-width:3;stroke-dasharray:3 2}
                \\.hint{color:#9aa0a6;font-size:.9em}
                \\code{background:#15151a;border:1px solid #30363d;border-radius:4px;padding:.1rem .35rem}
                \\.gl-wrap{position:relative}
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
