//! Declarative node-link graph rendering. The developer hands a `Graph`
//! (nodes + edges + a layout choice); this runs the chosen layout, fits the
//! result to the viewport, and emits an SVG `*Node` tree. Each node is a `<g>`
//! with a stable `data-ref` so the client island can animate its `transform`
//! in place (force layout) without re-creating elements.

const std = @import("std");
const Node = @import("../node.zig").Node;
const Context = @import("../context.zig").Context;
const scene = @import("scene.zig");
const geom = @import("geom.zig");
const tree_layout = @import("layout/tree.zig");
const radial_layout = @import("layout/radial.zig");
const force_layout = @import("layout/force.zig");
const dag_layout = @import("layout/dag.zig");
const common = @import("layout/common.zig");

const Vec2 = geom.Vec2;

pub const GraphNode = struct { id: []const u8, label: []const u8 = "" };
pub const GraphEdge = struct { from: []const u8, to: []const u8 };

pub const Layout = enum { tree, radial, force, dag };

pub const Graph = struct {
    nodes: []const GraphNode,
    edges: []const GraphEdge,
    layout: Layout = .force,
};

pub const Opts = struct {
    width: f64 = 800,
    height: f64 = 600,
    margin: f64 = 40,
    node_radius: f64 = 14,
    node_color: []const u8 = "#4f46e5",
    edge_color: []const u8 = "#cbd5e1",
    label_color: []const u8 = "#1e293b",
    label_size: f64 = 11,
    /// `data-ref` prefix for node groups: "<prefix>-<index>".
    ref_prefix: []const u8 = "viz-node",
    force_iterations: usize = 300,
    /// `.dag` only: crossing-minimization sweeps (0 = stable id-order).
    dag_crossing_iterations: usize = 8,
    /// Hint that callers want the interactive scaffold. `renderGraph` ignores
    /// it (static); use `renderInteractive` (or the app-layer island wrapper).
    interactive: bool = false,
};

/// Resolve the graph's string-id edges to node-index pairs, dropping any edge
/// that references an unknown id. Caller owns the slice (request arena).
pub fn buildEdgePairs(ctx: *const Context, g: Graph) ![]common.Edge {
    const a = ctx.allocator;
    var index = std.StringHashMap(usize).init(a);
    for (g.nodes, 0..) |node, i| try index.put(node.id, i);
    var edge_pairs: std.ArrayList(common.Edge) = .empty;
    for (g.edges) |e| {
        const fi = index.get(e.from) orelse continue;
        const ti = index.get(e.to) orelse continue;
        try edge_pairs.append(a, .{ fi, ti });
    }
    return edge_pairs.toOwnedSlice(a);
}

/// Run the chosen layout and fit the result to the viewport. Returns one
/// position per node (request arena). Exposed so island wrappers can reuse the
/// exact SSR positions as hydration props.
pub fn computePositions(ctx: *const Context, g: Graph, opts: Opts) ![]Vec2 {
    const a = ctx.allocator;
    const n = g.nodes.len;
    const edges = try buildEdgePairs(ctx, g);
    const center = Vec2{ .x = opts.width / 2.0, .y = opts.height / 2.0 };
    const positions = switch (g.layout) {
        .tree => try tree_layout.layout(a, n, edges, .{}),
        .radial => try radial_layout.layout(a, n, edges, .{ .center = center }),
        .force => try force_layout.run(a, n, edges, .{ .iterations = opts.force_iterations, .center = center }),
        .dag => try dag_layout.layout(a, n, edges, .{ .crossing_iterations = opts.dag_crossing_iterations }),
    };
    fitPositions(positions, opts);
    return positions;
}

/// Render `g` to an SVG `*Node` tree. Uses the request arena (`ctx.allocator`).
/// The `.dag` layout routes long edges through virtual-node bends (polylines);
/// other layouts draw straight edges.
pub fn render(ctx: *const Context, g: Graph, opts: Opts) *Node {
    if (g.layout == .dag) return renderDag(ctx, g, opts);
    const positions = computePositions(ctx, g, opts) catch return errNode(ctx);
    return renderWithPositions(ctx, g, opts, positions);
}

/// Render the `.dag` layout with virtual-node edge routing: each edge is a
/// polyline bending through its intermediate-layer virtual nodes.
fn renderDag(ctx: *const Context, g: Graph, opts: Opts) *Node {
    const a = ctx.allocator;
    const edges = buildEdgePairs(ctx, g) catch return errNode(ctx);
    const routed = dag_layout.layoutRouted(a, g.nodes.len, edges, .{ .crossing_iterations = opts.dag_crossing_iterations }) catch return errNode(ctx);
    if (routed.positions.len == 0) {
        return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = &.{} });
    }

    // Fit real positions to the viewport, then apply the SAME transform to the
    // edge bend points so routed edges line up with the nodes.
    const f = computeFit(routed.positions, opts);
    for (routed.positions) |*p| p.* = applyFit(p.*, f);
    for (routed.paths) |path| for (path) |*pp| {
        pp.* = applyFit(pp.*, f);
    };

    var shapes: std.ArrayList(scene.Shape) = .empty;
    for (routed.paths) |path| {
        if (path.len < 2) continue;
        shapes.append(a, .{ .polyline = .{
            .points = path,
            .style = .{ .stroke = opts.edge_color, .stroke_width = 1.5, .fill = "none" },
        } }) catch return errNode(ctx);
    }
    for (g.nodes, 0..) |node, i| {
        const grp = nodeGroupShape(ctx, opts, node, routed.positions[i], i) catch return errNode(ctx);
        shapes.append(a, grp) catch return errNode(ctx);
    }
    return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = shapes.items });
}

/// Render with caller-supplied positions (one per node). Lets an island reuse
/// the same positions it encoded as hydration props, keeping SSR and client in
/// exact agreement.
pub fn renderWithPositions(ctx: *const Context, g: Graph, opts: Opts, positions: []const Vec2) *Node {
    const a = ctx.allocator;
    const edges = buildEdgePairs(ctx, g) catch return errNode(ctx);

    var shapes: std.ArrayList(scene.Shape) = .empty;

    // Edges first so nodes draw on top.
    for (edges) |e| {
        shapes.append(a, .{ .line = .{
            .x1 = positions[e[0]].x,
            .y1 = positions[e[0]].y,
            .x2 = positions[e[1]].x,
            .y2 = positions[e[1]].y,
            .style = .{ .stroke = opts.edge_color, .stroke_width = 1.5 },
        } }) catch return errNode(ctx);
    }

    // Node groups (translate to position; ref for hydration).
    for (g.nodes, 0..) |node, i| {
        const grp = nodeGroupShape(ctx, opts, node, positions[i], i) catch return errNode(ctx);
        shapes.append(a, grp) catch return errNode(ctx);
    }

    return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = shapes.items });
}

/// A node as a `<g translate(x,y)>` carrying a circle + optional label and a
/// `data-ref` (for hydration). Shared by the straight and routed renderers.
fn nodeGroupShape(ctx: *const Context, opts: Opts, node: GraphNode, pos: Vec2, i: usize) !scene.Shape {
    const a = ctx.allocator;
    const ref = try std.fmt.allocPrint(a, "{s}-{d}", .{ opts.ref_prefix, i });
    const transform = try std.fmt.allocPrint(a, "translate({d},{d})", .{ pos.x, pos.y });
    var kids: std.ArrayList(scene.Shape) = .empty;
    try kids.append(a, .{ .circle = .{ .cx = 0, .cy = 0, .r = opts.node_radius, .style = .{ .fill = opts.node_color } } });
    if (node.label.len != 0) {
        try kids.append(a, .{ .text = .{
            .x = 0,
            .y = opts.node_radius + opts.label_size,
            .content = node.label,
            .anchor = .middle,
            .font_size = opts.label_size,
            .style = .{ .fill = opts.label_color },
        } });
    }
    return .{ .group = .{ .transform = transform, .children = kids.items, .ref = ref } };
}

/// Build the interactive scaffold: an `<svg>` with view-level pointer/wheel
/// handlers, a single `viz-root` `<g>` (the zoom/pan target) holding ref'd edges
/// + `data-node` node groups + a hidden tooltip. The named handlers
/// (`viz_wheel`, `viz_pointerdown`, …) are exported by the `VizGraphInteractive`
/// island chunk. Returns the bare svg; the app layer wraps it with
/// `verve.island` and the encoded props. Built with `ctx.el(...)` directly (not
/// the scene model) because it needs custom attrs the scene model doesn't carry.
pub fn renderInteractive(ctx: *const Context, g: Graph, opts: Opts) *Node {
    const a = ctx.allocator;
    const positions = computePositions(ctx, g, opts) catch return errNode(ctx);
    const edges = buildEdgePairs(ctx, g) catch return errNode(ctx);

    const root = ctx.el("g").attr("data-ref", "viz-root");

    // Edges (each ref'd so a node drag can rewrite its endpoints).
    for (edges, 0..) |e, i| {
        const ref = std.fmt.allocPrint(a, "viz-edge-{d}", .{i}) catch return errNode(ctx);
        _ = root.children(.{ctx.el("line")
            .attrFmt("x1", "{d}", .{positions[e[0]].x})
            .attrFmt("y1", "{d}", .{positions[e[0]].y})
            .attrFmt("x2", "{d}", .{positions[e[1]].x})
            .attrFmt("y2", "{d}", .{positions[e[1]].y})
            .attr("stroke", opts.edge_color)
            .attr("stroke-width", "1.5")
            .attr("data-ref", ref)});
        if (root.err != null) return root;
    }

    // Node groups: ref + data-node index + pointer/click handlers.
    for (g.nodes, 0..) |node, i| {
        const ref = std.fmt.allocPrint(a, "{s}-{d}", .{ opts.ref_prefix, i }) catch return errNode(ctx);
        const transform = std.fmt.allocPrint(a, "translate({d},{d})", .{ positions[i].x, positions[i].y }) catch return errNode(ctx);
        const idx = std.fmt.allocPrint(a, "{d}", .{i}) catch return errNode(ctx);
        const grp = ctx.el("g")
            .attr("data-ref", ref)
            .attr("data-node", idx)
            .attr("transform", transform)
            .class("viz-node")
            .onPointerDown("viz_pointerdown")
            .onPointerOver("viz_node_over")
            .onPointerOut("viz_node_out")
            .onClick("viz_node_click");
        _ = grp.children(.{ctx.el("circle").attr("cx", "0").attr("cy", "0").attrFmt("r", "{d}", .{opts.node_radius}).attr("fill", opts.node_color)});
        if (node.label.len != 0) {
            _ = grp.children(.{ctx.el("text")
                .attr("x", "0")
                .attrFmt("y", "{d}", .{opts.node_radius + opts.label_size})
                .attr("text-anchor", "middle")
                .attrFmt("font-size", "{d}", .{opts.label_size})
                .attr("fill", opts.label_color)
                .text(node.label)});
        }
        _ = root.children(.{grp});
        if (root.err != null) return root;
    }

    // Hidden tooltip — inside viz-root so it rides the zoom/pan transform.
    _ = root.children(.{ctx.el("g")
        .attr("data-ref", "viz-tooltip")
        .attr("style", "display:none")
        .attr("pointer-events", "none")
        .children(.{
        ctx.el("rect").attr("x", "0").attr("y", "-16").attr("width", "84").attr("height", "20").attr("rx", "3").attr("fill", "rgba(0,0,0,0.8)"),
        ctx.el("text").attr("data-ref", "viz-tooltip-text").attr("x", "6").attr("y", "-2").attr("font-size", "11").attr("fill", "#fff").text(""),
    })});
    if (root.err != null) return root;

    return ctx.el("svg")
        .attr("xmlns", "http://www.w3.org/2000/svg")
        .attr("data-ref", "viz-svg")
        .attrFmt("viewBox", "0 0 {d} {d}", .{ opts.width, opts.height })
        .attrFmt("width", "{d}", .{opts.width})
        .attrFmt("height", "{d}", .{opts.height})
        .onWheel("viz_wheel")
        .onPointerDown("viz_pointerdown")
        .onPointerMove("viz_pointermove")
        .onPointerUp("viz_pointerup")
        .onPointerOut("viz_pointerup")
        .children(.{root});
}

/// Uniform scale + translate that fits a point set into the margin box,
/// centered. Computed from the real-node bbox so routed edge bends can reuse it.
const Fit = struct { s: f64, cx: f64, cy: f64, bx: f64, by: f64 };

fn computeFit(positions: []const Vec2, opts: Opts) Fit {
    const box = geom.Rect.bounds(positions);
    const avail_w = opts.width - 2 * opts.margin;
    const avail_h = opts.height - 2 * opts.margin;
    var s: f64 = 1;
    if (box.w > 1e-9 and box.h > 1e-9) {
        s = @min(avail_w / box.w, avail_h / box.h);
    } else if (box.w > 1e-9) {
        s = avail_w / box.w;
    } else if (box.h > 1e-9) {
        s = avail_h / box.h;
    }
    return .{ .s = s, .cx = opts.width / 2.0, .cy = opts.height / 2.0, .bx = box.x + box.w / 2.0, .by = box.y + box.h / 2.0 };
}

fn applyFit(p: Vec2, f: Fit) Vec2 {
    return .{ .x = f.cx + (p.x - f.bx) * f.s, .y = f.cy + (p.y - f.by) * f.s };
}

/// Translate + uniformly scale positions in place to fit the margin box.
fn fitPositions(positions: []Vec2, opts: Opts) void {
    if (positions.len == 0) return;
    const f = computeFit(positions, opts);
    for (positions) |*p| p.* = applyFit(p.*, f);
}

fn errNode(ctx: *const Context) *Node {
    const n = ctx.el("svg");
    n.err = error.OutOfMemory;
    return n;
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;
const Renderer = @import("../renderer.zig").Renderer;

fn renderGraph(arena: *std.heap.ArenaAllocator, g: Graph, opts: Opts, buf: []u8) ![]const u8 {
    const ctx = Context.init(arena);
    var w: std.Io.Writer = .fixed(buf);
    try Renderer.render(&w, try render(&ctx, g, opts).build());
    return w.buffered();
}

test "force graph renders edges and node groups with refs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [16384]u8 = undefined;
    const nodes = [_]GraphNode{ .{ .id = "a", .label = "A" }, .{ .id = "b", .label = "B" }, .{ .id = "c", .label = "C" } };
    const edges = [_]GraphEdge{ .{ .from = "a", .to = "b" }, .{ .from = "b", .to = "c" } };
    const out = try renderGraph(&arena, .{ .nodes = &nodes, .edges = &edges, .layout = .force }, .{ .force_iterations = 50 }, &buf);
    try testing.expect(std.mem.indexOf(u8, out, "<svg") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<line") != null);
    try testing.expect(std.mem.indexOf(u8, out, "data-ref=\"viz-node-0\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "data-ref=\"viz-node-2\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, ">A</text>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "translate(") != null);
}

test "tree layout graph stays within viewport" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [16384]u8 = undefined;
    const nodes = [_]GraphNode{ .{ .id = "r" }, .{ .id = "x" }, .{ .id = "y" } };
    const edges = [_]GraphEdge{ .{ .from = "r", .to = "x" }, .{ .from = "r", .to = "y" } };
    const out = try renderGraph(&arena, .{ .nodes = &nodes, .edges = &edges, .layout = .tree }, .{ .width = 400, .height = 300 }, &buf);
    try testing.expect(std.mem.indexOf(u8, out, "<svg") != null);
    try testing.expect(std.mem.indexOf(u8, out, "viewBox=\"0 0 400 300\"") != null);
}

test "dag layout renders a layered graph" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [16384]u8 = undefined;
    const nodes = [_]GraphNode{ .{ .id = "a", .label = "A" }, .{ .id = "b", .label = "B" }, .{ .id = "c", .label = "C" } };
    const edges = [_]GraphEdge{ .{ .from = "a", .to = "b" }, .{ .from = "b", .to = "c" }, .{ .from = "a", .to = "c" } };
    const out = try renderGraph(&arena, .{ .nodes = &nodes, .edges = &edges, .layout = .dag }, .{ .width = 400, .height = 400 }, &buf);
    try testing.expect(std.mem.indexOf(u8, out, "<svg") != null);
    try testing.expect(std.mem.indexOf(u8, out, "data-ref=\"viz-node-2\"") != null);
    // a→c spans 2 layers → routed as a bent polyline (3 points).
    try testing.expect(std.mem.indexOf(u8, out, "<polyline") != null);
}

test "interactive graph stamps root, edge refs, data-node, pointer handlers, tooltip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [16384]u8 = undefined;
    const nodes = [_]GraphNode{ .{ .id = "a", .label = "A" }, .{ .id = "b", .label = "B" } };
    const edges = [_]GraphEdge{.{ .from = "a", .to = "b" }};
    const ctx = Context.init(&arena);
    const tree = try renderInteractive(&ctx, .{ .nodes = &nodes, .edges = &edges, .layout = .force }, .{ .width = 400, .height = 300, .force_iterations = 30 }).build();
    var w: std.Io.Writer = .fixed(&buf);
    try Renderer.render(&w, tree);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "data-ref=\"viz-svg\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "data-ref=\"viz-root\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "data-ref=\"viz-edge-0\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "data-node=\"0\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "z-on-wheel=\"viz_wheel\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "z-on-pointerover=\"viz_node_over\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "data-ref=\"viz-tooltip\"") != null);
}

test "unknown edge endpoints are skipped, not fatal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [8192]u8 = undefined;
    const nodes = [_]GraphNode{.{ .id = "a", .label = "A" }};
    const edges = [_]GraphEdge{.{ .from = "a", .to = "ghost" }};
    const out = try renderGraph(&arena, .{ .nodes = &nodes, .edges = &edges, .layout = .force }, .{}, &buf);
    try testing.expect(std.mem.indexOf(u8, out, "data-ref=\"viz-node-0\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<line") == null);
}
