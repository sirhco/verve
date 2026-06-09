//! Declarative statistical charts. Each entry point takes data + options and
//! returns an SVG `*Node` tree (via the scene model) ready to drop into a
//! route. Built on `scale`, `axis`, and `scene`. Allocation uses the request
//! arena (`ctx.allocator`), so there is nothing to free.

const std = @import("std");
const Node = @import("../node.zig").Node;
const Context = @import("../context.zig").Context;
const scale = @import("scale.zig");
const axis = @import("axis.zig");
const scene = @import("scene.zig");
const geom = @import("geom.zig");

const Vec2 = geom.Vec2;

pub const Datum = struct { label: []const u8, value: f64 };
pub const Point = struct { x: f64, y: f64 };

pub const Margin = struct {
    top: f64 = 20,
    right: f64 = 20,
    bottom: f64 = 40,
    left: f64 = 48,
};

pub const Opts = struct {
    width: f64 = 600,
    height: f64 = 400,
    margin: Margin = .{},
    color: []const u8 = "#4f46e5",
    axis_color: []const u8 = "#888",
    tick_count: usize = 5,
};

const Plot = struct {
    x0: f64, // left edge of plot area (abs)
    x1: f64, // right edge
    y0: f64, // bottom edge (abs, larger y)
    y1: f64, // top edge (abs, smaller y)

    fn of(opts: Opts) Plot {
        return .{
            .x0 = opts.margin.left,
            .x1 = opts.width - opts.margin.right,
            .y0 = opts.height - opts.margin.bottom,
            .y1 = opts.margin.top,
        };
    }
};

fn maxValue(values: []const f64) f64 {
    var m: f64 = 0;
    for (values) |v| m = @max(m, v);
    return if (m == 0) 1 else m;
}

/// Vertical bar chart over labeled categories.
pub fn bar(ctx: *const Context, data: []const Datum, opts: Opts) *Node {
    const a = ctx.allocator;
    const plot = Plot.of(opts);
    var shapes: std.ArrayList(scene.Shape) = .empty;

    var top: f64 = 0;
    for (data) |d| top = @max(top, d.value);
    if (top == 0) top = 1;

    const y = scale.Linear{ .domain = .{ 0, top }, .range = .{ plot.y0, plot.y1 } };
    const band = scale.Band{ .count = data.len, .range = .{ plot.x0, plot.x1 }, .padding = 0.2 };

    appendAxis(&shapes, a, .{ .orient = .left, .scale = y, .cross = plot.x0, .tick_count = opts.tick_count, .color = opts.axis_color });

    for (data, 0..) |d, i| {
        const bx = band.map(i);
        const by = y.map(d.value);
        shapes.append(a, .{ .rect = .{
            .x = bx,
            .y = by,
            .w = band.bandwidth(),
            .h = plot.y0 - by,
            .style = .{ .fill = opts.color },
        } }) catch return errNode(ctx);
        // Category label under the band.
        shapes.append(a, .{ .text = .{
            .x = band.center(i),
            .y = plot.y0 + 16,
            .content = d.label,
            .anchor = .middle,
            .font_size = 10,
            .style = .{ .fill = opts.axis_color },
        } }) catch return errNode(ctx);
    }

    return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = shapes.items });
}

/// One series in a stacked bar chart. `values[c]` is this series' contribution
/// to category `c` (so `values.len` should equal `categories.len`). `color`
/// defaults to the palette entry for the series' index.
pub const StackSeries = struct {
    name: []const u8,
    values: []const f64,
    color: ?[]const u8 = null,
};

/// Stacked bar chart: each category band stacks the series bottom-to-top. A
/// small legend (swatch + name) is drawn along the top of the plot.
pub fn stackedBar(ctx: *const Context, categories: []const []const u8, series: []const StackSeries, opts: Opts) *Node {
    const a = ctx.allocator;
    const plot = Plot.of(opts);
    var shapes: std.ArrayList(scene.Shape) = .empty;

    // Tallest stack sets the y domain.
    var top: f64 = 0;
    for (categories, 0..) |_, c| {
        var sum: f64 = 0;
        for (series) |s| if (c < s.values.len) {
            sum += s.values[c];
        };
        top = @max(top, sum);
    }
    if (top == 0) top = 1;

    const y = scale.Linear{ .domain = .{ 0, top }, .range = .{ plot.y0, plot.y1 } };
    const band = scale.Band{ .count = categories.len, .range = .{ plot.x0, plot.x1 }, .padding = 0.2 };

    appendAxis(&shapes, a, .{ .orient = .left, .scale = y, .cross = plot.x0, .tick_count = opts.tick_count, .color = opts.axis_color });

    for (categories, 0..) |label, c| {
        const bx = band.map(c);
        var cum: f64 = 0;
        for (series, 0..) |s, si| {
            const v = if (c < s.values.len) s.values[c] else 0;
            if (v <= 0) continue;
            const y_top = y.map(cum + v);
            const y_bot = y.map(cum);
            shapes.append(a, .{ .rect = .{
                .x = bx,
                .y = y_top,
                .w = band.bandwidth(),
                .h = y_bot - y_top,
                .style = .{ .fill = s.color orelse palette[si % palette.len] },
            } }) catch return errNode(ctx);
            cum += v;
        }
        shapes.append(a, .{ .text = .{
            .x = band.center(c),
            .y = plot.y0 + 16,
            .content = label,
            .anchor = .middle,
            .font_size = 10,
            .style = .{ .fill = opts.axis_color },
        } }) catch return errNode(ctx);
    }

    // Legend: swatch + name per series, left-aligned along the top.
    var lx: f64 = plot.x0;
    const ly = opts.margin.top - 12;
    for (series, 0..) |s, si| {
        const color = s.color orelse palette[si % palette.len];
        shapes.append(a, .{ .rect = .{ .x = lx, .y = ly, .w = 10, .h = 10, .rx = 2, .style = .{ .fill = color } } }) catch return errNode(ctx);
        shapes.append(a, .{ .text = .{ .x = lx + 14, .y = ly + 9, .content = s.name, .font_size = 10, .style = .{ .fill = opts.axis_color } } }) catch return errNode(ctx);
        // Advance by swatch + gap + an approximate text width (~6px/char).
        lx += 24 + @as(f64, @floatFromInt(s.name.len)) * 6.0 + 16;
    }

    return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = shapes.items });
}

/// Line chart over continuous (x, y) points (drawn in given order).
pub fn line(ctx: *const Context, data: []const Point, opts: Opts) *Node {
    const a = ctx.allocator;
    const plot = Plot.of(opts);
    var shapes: std.ArrayList(scene.Shape) = .empty;

    const sx, const sy = continuousScales(data, plot);
    appendAxis(&shapes, a, .{ .orient = .bottom, .scale = sx, .cross = plot.y0, .tick_count = opts.tick_count, .color = opts.axis_color });
    appendAxis(&shapes, a, .{ .orient = .left, .scale = sy, .cross = plot.x0, .tick_count = opts.tick_count, .color = opts.axis_color });

    const pts = a.alloc(Vec2, data.len) catch return errNode(ctx);
    for (data, 0..) |d, i| pts[i] = .{ .x = sx.map(d.x), .y = sy.map(d.y) };
    shapes.append(a, .{ .polyline = .{
        .points = pts,
        .style = .{ .stroke = opts.color, .stroke_width = 2, .fill = "none" },
    } }) catch return errNode(ctx);

    return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = shapes.items });
}

/// Scatter plot of (x, y) points.
pub fn scatter(ctx: *const Context, data: []const Point, opts: Opts) *Node {
    const a = ctx.allocator;
    const plot = Plot.of(opts);
    var shapes: std.ArrayList(scene.Shape) = .empty;

    const sx, const sy = continuousScales(data, plot);
    appendAxis(&shapes, a, .{ .orient = .bottom, .scale = sx, .cross = plot.y0, .tick_count = opts.tick_count, .color = opts.axis_color });
    appendAxis(&shapes, a, .{ .orient = .left, .scale = sy, .cross = plot.x0, .tick_count = opts.tick_count, .color = opts.axis_color });

    for (data) |d| {
        shapes.append(a, .{ .circle = .{
            .cx = sx.map(d.x),
            .cy = sy.map(d.y),
            .r = 4,
            .style = .{ .fill = opts.color },
        } }) catch return errNode(ctx);
    }

    return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = shapes.items });
}

/// Filled area chart: a line with the region down to the y=0 baseline filled.
pub fn area(ctx: *const Context, data: []const Point, opts: Opts) *Node {
    const a = ctx.allocator;
    const plot = Plot.of(opts);
    var shapes: std.ArrayList(scene.Shape) = .empty;

    const sx, const sy = continuousScales(data, plot);
    appendAxis(&shapes, a, .{ .orient = .bottom, .scale = sx, .cross = plot.y0, .tick_count = opts.tick_count, .color = opts.axis_color });
    appendAxis(&shapes, a, .{ .orient = .left, .scale = sy, .cross = plot.x0, .tick_count = opts.tick_count, .color = opts.axis_color });

    if (data.len != 0) {
        // Polygon: the curve, then back along the baseline to close.
        const poly = a.alloc(Vec2, data.len + 2) catch return errNode(ctx);
        for (data, 0..) |d, i| poly[i] = .{ .x = sx.map(d.x), .y = sy.map(d.y) };
        poly[data.len] = .{ .x = sx.map(data[data.len - 1].x), .y = plot.y0 };
        poly[data.len + 1] = .{ .x = sx.map(data[0].x), .y = plot.y0 };
        shapes.append(a, .{ .polyline = .{
            .points = poly,
            .closed = true,
            .style = .{ .fill = opts.color, .opacity = 0.25, .stroke = opts.color, .stroke_width = 2 },
        } }) catch return errNode(ctx);
    }

    return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = shapes.items });
}

/// Default categorical palette for pie/donut slices.
pub const palette = [_][]const u8{
    "#1f6feb", "#10b981", "#f59e0b", "#ef4444", "#8b5cf6",
    "#06b6d4", "#ec4899", "#84cc16", "#f97316", "#14b8a6",
};

pub const PieOpts = struct {
    width: f64 = 360,
    height: f64 = 360,
    /// Inner radius as a fraction of the outer radius (0 = full pie, 0.5 = donut).
    inner_ratio: f64 = 0,
    pad: f64 = 8,
    colors: []const []const u8 = &palette,
    stroke: []const u8 = "#0e0e10",
};

/// Pie or donut chart. Slice angle is proportional to each datum's value.
pub fn pie(ctx: *const Context, data: []const Datum, opts: PieOpts) *Node {
    const a = ctx.allocator;
    var shapes: std.ArrayList(scene.Shape) = .empty;

    const cx = opts.width / 2.0;
    const cy = opts.height / 2.0;
    const r = @min(cx, cy) - opts.pad;
    const ir = r * opts.inner_ratio;

    var total: f64 = 0;
    for (data) |d| total += d.value;
    if (total <= 0) return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = shapes.items });

    var ang0: f64 = -std.math.pi / 2.0; // start at 12 o'clock
    for (data, 0..) |d, i| {
        const frac = d.value / total;
        const ang1 = ang0 + frac * 2.0 * std.math.pi;
        const color = opts.colors[i % opts.colors.len];
        const d_str = slicePath(a, cx, cy, r, ir, ang0, ang1) catch return errNode(ctx);
        shapes.append(a, .{ .path = .{ .d = d_str, .style = .{ .fill = color, .stroke = opts.stroke, .stroke_width = 1 } } }) catch return errNode(ctx);
        ang0 = ang1;
    }

    return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = shapes.items });
}

/// SVG path data for one wedge (pie when `ir == 0`) or ring segment (donut).
fn slicePath(a: std.mem.Allocator, cx: f64, cy: f64, r: f64, ir: f64, a0: f64, a1: f64) ![]const u8 {
    const large: u8 = if (a1 - a0 > std.math.pi) 1 else 0;
    const ox0 = cx + r * @cos(a0);
    const oy0 = cy + r * @sin(a0);
    const ox1 = cx + r * @cos(a1);
    const oy1 = cy + r * @sin(a1);
    if (ir <= 0) {
        return std.fmt.allocPrint(a, "M {d},{d} L {d},{d} A {d},{d} 0 {d} 1 {d},{d} Z", .{ cx, cy, ox0, oy0, r, r, large, ox1, oy1 });
    }
    const ix0 = cx + ir * @cos(a0);
    const iy0 = cy + ir * @sin(a0);
    const ix1 = cx + ir * @cos(a1);
    const iy1 = cy + ir * @sin(a1);
    return std.fmt.allocPrint(
        a,
        "M {d},{d} A {d},{d} 0 {d} 1 {d},{d} L {d},{d} A {d},{d} 0 {d} 0 {d},{d} Z",
        .{ ox0, oy0, r, r, large, ox1, oy1, ix1, iy1, ir, ir, large, ix0, iy0 },
    );
}

fn continuousScales(data: []const Point, plot: Plot) struct { scale.Linear, scale.Linear } {
    var min_x: f64 = 0;
    var max_x: f64 = 1;
    var max_y: f64 = 1;
    if (data.len != 0) {
        min_x = data[0].x;
        max_x = data[0].x;
        max_y = data[0].y;
        for (data) |d| {
            min_x = @min(min_x, d.x);
            max_x = @max(max_x, d.x);
            max_y = @max(max_y, d.y);
        }
        if (max_x == min_x) max_x = min_x + 1;
        if (max_y == 0) max_y = 1;
    }
    return .{
        scale.Linear{ .domain = .{ min_x, max_x }, .range = .{ plot.x0, plot.x1 } },
        scale.Linear{ .domain = .{ 0, max_y }, .range = .{ plot.y0, plot.y1 } },
    };
}

fn appendAxis(shapes: *std.ArrayList(scene.Shape), a: std.mem.Allocator, opts: axis.Opts) void {
    const ax = axis.build(a, opts) catch return;
    shapes.appendSlice(a, ax) catch return;
}

fn errNode(ctx: *const Context) *Node {
    const n = ctx.el("svg");
    n.err = error.OutOfMemory;
    return n;
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;
const Renderer = @import("../renderer.zig").Renderer;

fn renderToBuf(node: *Node, buf: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try Renderer.render(&w, try node.build());
    return w.buffered();
}

test "bar chart renders rects, y-axis, and category labels" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    var buf: [8192]u8 = undefined;
    const data = [_]Datum{ .{ .label = "Jan", .value = 10 }, .{ .label = "Feb", .value = 14 }, .{ .label = "Mar", .value = 6 } };
    const out = try renderToBuf(bar(&ctx, &data, .{ .width = 600, .height = 400 }), &buf);
    try testing.expect(std.mem.indexOf(u8, out, "<svg") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<rect") != null);
    try testing.expect(std.mem.indexOf(u8, out, ">Jan</text>") != null);
    try testing.expect(std.mem.indexOf(u8, out, ">Mar</text>") != null);
}

test "stacked bar renders a rect per non-zero segment, labels, and legend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    var buf: [16384]u8 = undefined;
    const cats = [_][]const u8{ "Q1", "Q2" };
    const series = [_]StackSeries{
        .{ .name = "web", .values = &.{ 5, 8 }, .color = "#1f6feb" },
        .{ .name = "api", .values = &.{ 3, 0 }, .color = "#10b981" }, // Q2 api = 0 → no rect
    };
    const out = try renderToBuf(stackedBar(&ctx, &cats, &series, .{ .width = 480, .height = 300 }), &buf);
    try testing.expect(std.mem.indexOf(u8, out, "<svg") != null);
    // category labels + legend names
    try testing.expect(std.mem.indexOf(u8, out, ">Q1</text>") != null);
    try testing.expect(std.mem.indexOf(u8, out, ">web</text>") != null);
    try testing.expect(std.mem.indexOf(u8, out, ">api</text>") != null);
    // both series colors present
    try testing.expect(std.mem.indexOf(u8, out, "fill=\"#1f6feb\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "fill=\"#10b981\"") != null);
    // 3 stacked segments (web Q1, web Q2, api Q1) + 2 legend swatches = 5 rects.
    try testing.expectEqual(@as(usize, 5), std.mem.count(u8, out, "<rect"));
}

test "line chart renders a polyline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    var buf: [8192]u8 = undefined;
    const data = [_]Point{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 4 }, .{ .x = 2, .y = 2 } };
    const out = try renderToBuf(line(&ctx, &data, .{}), &buf);
    try testing.expect(std.mem.indexOf(u8, out, "<polyline") != null);
    try testing.expect(std.mem.indexOf(u8, out, "fill=\"none\"") != null);
}

test "scatter chart renders circles" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    var buf: [8192]u8 = undefined;
    const data = [_]Point{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 5 } };
    const out = try renderToBuf(scatter(&ctx, &data, .{}), &buf);
    try testing.expect(std.mem.indexOf(u8, out, "<circle") != null);
}

test "area chart renders a filled closed polygon" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    var buf: [8192]u8 = undefined;
    const data = [_]Point{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 4 }, .{ .x = 2, .y = 2 } };
    const out = try renderToBuf(area(&ctx, &data, .{}), &buf);
    try testing.expect(std.mem.indexOf(u8, out, "<polygon") != null);
    try testing.expect(std.mem.indexOf(u8, out, "opacity=\"0.25\"") != null);
}

test "pie chart renders one path per slice" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    var buf: [8192]u8 = undefined;
    const data = [_]Datum{ .{ .label = "a", .value = 1 }, .{ .label = "b", .value = 2 }, .{ .label = "c", .value = 1 } };
    const out = try renderToBuf(pie(&ctx, &data, .{}), &buf);
    try testing.expect(std.mem.indexOf(u8, out, "<path") != null);
    // three slices → three path elements
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, out, "<path"));
}

test "donut chart uses inner radius (two arcs per slice)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    var buf: [8192]u8 = undefined;
    const data = [_]Datum{ .{ .label = "a", .value = 1 }, .{ .label = "b", .value = 1 } };
    const out = try renderToBuf(pie(&ctx, &data, .{ .inner_ratio = 0.5 }), &buf);
    // each donut slice has two arc commands ("A"); 2 slices → ≥4 total.
    try testing.expect(std.mem.count(u8, out, " A ") >= 4);
}
