//! Resolution-independent SVG scene model. Layouts and charts emit a `Scene`
//! (a flat list of `Shape`s); `toNode` walks it once and produces the SVG
//! `*Node` tree via the standard `ctx.el(...)` chain, so the output drops
//! straight into any route's returned tree and serializes through the normal
//! renderer (SSR, no-JS-friendly).
//!
//! Shapes may carry a stable `ref` id, stamped as `data-ref="<id>"`. Phase 1
//! client hydration resolves those ids and mutates element attributes in
//! place (e.g. animating a node group's `transform`) without re-creating the
//! element set — keeping the client path free of new bridge primitives.

const std = @import("std");
const Node = @import("../node.zig").Node;
const Context = @import("../context.zig").Context;
const geom = @import("geom.zig");

const Vec2 = geom.Vec2;

/// Presentation attributes shared by all shapes. Only the set fields are
/// emitted, so the SVG stays compact.
pub const Style = struct {
    fill: ?[]const u8 = null,
    stroke: ?[]const u8 = null,
    stroke_width: ?f64 = null,
    opacity: ?f64 = null,
    class: ?[]const u8 = null,
};

pub const Circle = struct { cx: f64, cy: f64, r: f64, style: Style = .{}, ref: ?[]const u8 = null };
pub const RectShape = struct { x: f64, y: f64, w: f64, h: f64, rx: ?f64 = null, style: Style = .{}, ref: ?[]const u8 = null };
pub const Line = struct { x1: f64, y1: f64, x2: f64, y2: f64, style: Style = .{}, ref: ?[]const u8 = null };
pub const Polyline = struct { points: []const Vec2, closed: bool = false, style: Style = .{}, ref: ?[]const u8 = null };
pub const Path = struct { d: []const u8, style: Style = .{}, ref: ?[]const u8 = null };

pub const TextAnchor = enum { start, middle, end };

pub const Text = struct {
    x: f64,
    y: f64,
    content: []const u8,
    anchor: TextAnchor = .start,
    font_size: ?f64 = null,
    style: Style = .{},
    ref: ?[]const u8 = null,
};

pub const Group = struct {
    transform: ?[]const u8 = null,
    children: []const Shape,
    style: Style = .{},
    ref: ?[]const u8 = null,
};

/// A drawable. `polyline` doubles as a polygon when `closed` is set.
pub const Shape = union(enum) {
    circle: Circle,
    rect: RectShape,
    line: Line,
    polyline: Polyline,
    path: Path,
    text: Text,
    group: Group,
};

/// A complete scene with its coordinate extent. `width`/`height` become the
/// SVG viewBox so the drawing scales to whatever box the page gives it.
pub const Scene = struct {
    width: f64,
    height: f64,
    shapes: []const Shape,
};

/// Render `scene` into an `<svg>` `*Node` tree. Allocation failures surface at
/// the chain terminus (`.build()`) like any other node chain.
pub fn toNode(ctx: *const Context, scene: Scene) *Node {
    const svg = ctx.el("svg")
        .attr("xmlns", "http://www.w3.org/2000/svg")
        .attrFmt("viewBox", "0 0 {d} {d}", .{ scene.width, scene.height })
        .attrFmt("width", "{d}", .{scene.width})
        .attrFmt("height", "{d}", .{scene.height});
    for (scene.shapes) |*shape| {
        _ = svg.children(.{shapeToNode(ctx, shape)});
        if (svg.err != null) return svg;
    }
    return svg;
}

fn shapeToNode(ctx: *const Context, shape: *const Shape) *Node {
    return switch (shape.*) {
        .circle => |c| applyCommon(ctx.el("circle")
            .attrFmt("cx", "{d}", .{c.cx})
            .attrFmt("cy", "{d}", .{c.cy})
            .attrFmt("r", "{d}", .{c.r}), c.style, c.ref),
        .rect => |r| blk: {
            const n = ctx.el("rect")
                .attrFmt("x", "{d}", .{r.x})
                .attrFmt("y", "{d}", .{r.y})
                .attrFmt("width", "{d}", .{r.w})
                .attrFmt("height", "{d}", .{r.h});
            if (r.rx) |rx| _ = n.attrFmt("rx", "{d}", .{rx});
            break :blk applyCommon(n, r.style, r.ref);
        },
        .line => |l| applyCommon(ctx.el("line")
            .attrFmt("x1", "{d}", .{l.x1})
            .attrFmt("y1", "{d}", .{l.y1})
            .attrFmt("x2", "{d}", .{l.x2})
            .attrFmt("y2", "{d}", .{l.y2}), l.style, l.ref),
        .polyline => |pl| blk: {
            const tag = if (pl.closed) "polygon" else "polyline";
            const pts = pointsAttr(ctx, pl.points) catch |e| {
                const poisoned = ctx.el(tag);
                poisoned.err = e;
                break :blk poisoned;
            };
            break :blk applyCommon(ctx.el(tag).attr("points", pts), pl.style, pl.ref);
        },
        .path => |p| applyCommon(ctx.el("path").attr("d", p.d), p.style, p.ref),
        .text => |t| blk: {
            const n = ctx.el("text")
                .attrFmt("x", "{d}", .{t.x})
                .attrFmt("y", "{d}", .{t.y})
                .attr("text-anchor", anchorName(t.anchor))
                .text(t.content);
            if (t.font_size) |fs| _ = n.attrFmt("font-size", "{d}", .{fs});
            break :blk applyCommon(n, t.style, t.ref);
        },
        .group => |g| blk: {
            const n = ctx.el("g");
            if (g.transform) |tr| _ = n.attr("transform", tr);
            _ = applyCommon(n, g.style, g.ref);
            for (g.children) |*child| {
                _ = n.children(.{shapeToNode(ctx, child)});
                if (n.err != null) break;
            }
            break :blk n;
        },
    };
}

fn applyCommon(n: *Node, style: Style, ref: ?[]const u8) *Node {
    if (style.fill) |v| _ = n.attr("fill", v);
    if (style.stroke) |v| _ = n.attr("stroke", v);
    if (style.stroke_width) |v| _ = n.attrFmt("stroke-width", "{d}", .{v});
    if (style.opacity) |v| _ = n.attrFmt("opacity", "{d}", .{v});
    if (style.class) |v| _ = n.class(v);
    if (ref) |v| _ = n.attr("data-ref", v);
    return n;
}

fn anchorName(a: TextAnchor) []const u8 {
    return switch (a) {
        .start => "start",
        .middle => "middle",
        .end => "end",
    };
}

fn pointsAttr(ctx: *const Context, points: []const Vec2) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(ctx.allocator);
    for (points, 0..) |p, i| {
        if (i != 0) try buf.append(ctx.allocator, ' ');
        const s = try std.fmt.allocPrint(ctx.allocator, "{d},{d}", .{ p.x, p.y });
        try buf.appendSlice(ctx.allocator, s);
    }
    return buf.toOwnedSlice(ctx.allocator);
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;
const Renderer = @import("../renderer.zig").Renderer;

fn renderScene(arena: *std.heap.ArenaAllocator, scene: Scene, buf: []u8) ![]const u8 {
    const ctx = Context.init(arena);
    const n = try toNode(&ctx, scene).build();
    var w: std.Io.Writer = .fixed(buf);
    try Renderer.render(&w, n);
    return w.buffered();
}

test "scene renders svg root with viewBox and shapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [2048]u8 = undefined;
    const shapes = [_]Shape{
        .{ .circle = .{ .cx = 10, .cy = 20, .r = 5, .style = .{ .fill = "red" }, .ref = "n0" } },
        .{ .line = .{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 20, .style = .{ .stroke = "black" } } },
        .{ .text = .{ .x = 10, .y = 20, .content = "A", .anchor = .middle } },
    };
    const out = try renderScene(&arena, .{ .width = 100, .height = 50, .shapes = &shapes }, &buf);
    try testing.expect(std.mem.indexOf(u8, out, "<svg") != null);
    try testing.expect(std.mem.indexOf(u8, out, "viewBox=\"0 0 100 50\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<circle") != null);
    try testing.expect(std.mem.indexOf(u8, out, "fill=\"red\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "data-ref=\"n0\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<line") != null);
    try testing.expect(std.mem.indexOf(u8, out, "text-anchor=\"middle\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, ">A</text>") != null);
}

test "group emits transform and nests children" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [1024]u8 = undefined;
    const kids = [_]Shape{.{ .circle = .{ .cx = 0, .cy = 0, .r = 3 } }};
    const shapes = [_]Shape{.{ .group = .{ .transform = "translate(5,5)", .children = &kids, .ref = "g0" } }};
    const out = try renderScene(&arena, .{ .width = 20, .height = 20, .shapes = &shapes }, &buf);
    try testing.expect(std.mem.indexOf(u8, out, "<g transform=\"translate(5,5)\" data-ref=\"g0\">") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<circle") != null);
}

test "closed polyline becomes polygon" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [1024]u8 = undefined;
    const pts = [_]Vec2{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 5, .y = 8 } };
    const shapes = [_]Shape{.{ .polyline = .{ .points = &pts, .closed = true } }};
    const out = try renderScene(&arena, .{ .width = 20, .height = 20, .shapes = &shapes }, &buf);
    try testing.expect(std.mem.indexOf(u8, out, "<polygon") != null);
    try testing.expect(std.mem.indexOf(u8, out, "points=\"0,0 10,0 5,8\"") != null);
}
