//! viz-live page: one interactive graph island, SSR'd with the SAME graph the
//! server's evolving model starts from — so the first pushed delta mutates
//! exactly what's on screen (no resync jump on toggle).

const std = @import("std");
const verve = @import("verve");
const islands = @import("islands.zig");

pub fn index(ctx: *const verve.Context) !*verve.Node {
    // Mirror of api.zig's `vizBuild(0, ...)` base model: 3 stable nodes,
    // 2 edges. The live deltas add/remove the ephemeral e0..e2 around it.
    const nodes = [_]verve.viz.GraphNode{
        .{ .id = "core", .label = "core" },
        .{ .id = "io", .label = "io" },
        .{ .id = "ui", .label = "ui" },
    };
    const edges = [_]verve.viz.GraphEdge{
        .{ .from = "core", .to = "io" },
        .{ .from = "core", .to = "ui" },
    };
    const g = verve.viz.Graph{ .nodes = &nodes, .edges = &edges, .layout = .force };
    const gopts = verve.viz.GraphOpts{
        .width = 640,
        .height = 420,
        .node_color = "#1f6feb",
        .edge_color = "#30363d",
        .label_color = "#f5f5f5",
    };

    // Compute the fitted positions ONCE and reuse them for both the SSR tree
    // and the hydration props, so the chunk's model lands exactly on the
    // server-rendered pixels.
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
        ctx.el("button").attr("z-on-click", "viz_toggle_live").attr("data-ref", "viz-live-btn").text("● live"),
        ctx.el("button").attr("z-on-click", "viz_layout_cycle").attr("data-ref", "viz-layout-btn").text("⟳ force"),
        ctx.el("button").attr("z-on-click", "viz_add_node").text("+ node"),
        ctx.el("button").attr("z-on-click", "viz_remove_node").text("− node"),
    });
    const island = verve.island(
        ctx,
        .{ .name = "VizGraphInteractive", .props = props },
        ctx.div().children(.{ controls, graph_svg }),
    );

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
    }).build();
}

pub fn page(ctx: *const verve.Context, body: *verve.Node) !*verve.Node {
    return ctx.el("html").children(.{
        ctx.el("head").children(.{
            ctx.meta("charset", "utf-8"),
            ctx.title("Verve viz-live"),
            ctx.style(
                \\body{font:16px/1.6 system-ui;margin:0;background:#0e0e10;color:#e6e6e6}
                \\main{max-width:46rem;margin:2rem auto;padding:0 1.5rem}
                \\h1{margin-top:0}
                \\.card{background:#15151a;border:1px solid #30363d;border-radius:10px;padding:1.25rem}
                \\.card svg{touch-action:none;max-width:100%}
                \\button{font:inherit;padding:.4rem .8rem;background:#21262d;color:#e6e6e6;border:1px solid #30363d;border-radius:6px;cursor:pointer}
                \\button:hover{filter:brightness(1.2)}
                \\.viz-controls{display:flex;gap:.5rem;margin-bottom:.75rem}
                \\.viz-controls .live-on{background:#10b981;color:#04110c}
                \\.viz-node{cursor:grab}
                \\.viz-node.selected circle{stroke:#fff;stroke-width:3}
                \\.viz-node.collapsed circle{stroke:#f59e0b;stroke-width:3;stroke-dasharray:3 2}
                \\.hint{color:#9aa0a6;font-size:.9em}
                \\code{background:#15151a;border:1px solid #30363d;border-radius:4px;padding:.1rem .35rem}
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
