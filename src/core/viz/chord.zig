//! Chord diagram: an n×n flow matrix drawn as annular group arcs around a
//! circle with quadratic ribbons connecting each nonzero (i, j) flow. Pure
//! layout (`chordLayout`) + a chart-style renderer (`chord`). Follows the d3
//! convention: group i's angular span ∝ its row sum; sub-arcs within a group
//! are ordered by column index.

const std = @import("std");
const Node = @import("../node.zig").Node;
const Context = @import("../context.zig").Context;
const scene = @import("scene.zig");
const chart = @import("chart.zig");

pub const ChordOpts = struct {
    width: f64 = 600,
    height: f64 = 600,
    /// Angular gap between adjacent groups (radians).
    pad_angle: f64 = 0.03,
    /// Group arc thickness as a fraction of the outer radius.
    arc_thickness: f64 = 0.08,
    /// Ribbon opacity (filled with the source group's color).
    ribbon_opacity: f64 = 0.6,
    colors: []const []const u8 = &chart.palette,
    label_size: f64 = 11,
    label_color: []const u8 = "#1e293b",
    stroke: []const u8 = "#0e0e10",
};

pub const ChordLayout = struct {
    /// Group angular extents (radians, start at 12 o'clock, clockwise).
    group_start: []f64,
    group_end: []f64,
    /// Per-cell sub-arc extents, row-major `[i*n + j]`: the slice of group
    /// i's arc carrying the flow `matrix[i][j]`. Zero-width when the cell is
    /// zero.
    sub_start: []f64,
    sub_end: []f64,
};

/// Pure chord layout over a row-major n×n `matrix`. Groups with a zero row
/// sum get a zero-width arc (their pad is still reserved, keeping group
/// positions stable as values change). Caller owns the slices.
pub fn chordLayout(a: std.mem.Allocator, matrix: []const f64, n: usize, pad_angle: f64) !ChordLayout {
    if (matrix.len != n * n) return error.BadMatrix;
    const group_start = try a.alloc(f64, n);
    const group_end = try a.alloc(f64, n);
    const sub_start = try a.alloc(f64, n * n);
    const sub_end = try a.alloc(f64, n * n);
    if (n == 0) return .{ .group_start = group_start, .group_end = group_end, .sub_start = sub_start, .sub_end = sub_end };

    var grand: f64 = 0;
    for (matrix) |v| grand += @max(v, 0);
    const span_total = 2.0 * std.math.pi - @as(f64, @floatFromInt(n)) * pad_angle;
    const k = if (grand > 0) span_total / grand else 0;

    var ang: f64 = -std.math.pi / 2.0; // 12 o'clock
    for (0..n) |i| {
        group_start[i] = ang;
        for (0..n) |j| {
            const cell = @max(matrix[i * n + j], 0);
            sub_start[i * n + j] = ang;
            ang += cell * k;
            sub_end[i * n + j] = ang;
        }
        group_end[i] = ang;
        ang += pad_angle;
    }
    return .{ .group_start = group_start, .group_end = group_end, .sub_start = sub_start, .sub_end = sub_end };
}

/// Render a chord diagram. One annular arc per group, one ribbon per nonzero
/// unordered pair {i, j} (self-flows ribbon within their own group), filled
/// with the dominant source's color.
pub fn chord(ctx: *const Context, labels: []const []const u8, matrix: []const f64, opts: ChordOpts) *Node {
    const a = ctx.allocator;
    const n = labels.len;
    const lay = chordLayout(a, matrix, n, opts.pad_angle) catch return errNode(ctx);

    const cx = opts.width / 2;
    const cy = opts.height / 2;
    const r_outer = @min(opts.width, opts.height) / 2 - opts.label_size * 2 - 8;
    const r_inner = r_outer * (1 - opts.arc_thickness);

    var shapes: std.ArrayList(scene.Shape) = .empty;

    // Ribbons first so the group arcs draw on top.
    for (0..n) |i| {
        for (i..n) |j| {
            const forward = @max(matrix[i * n + j], 0);
            const backward = if (i == j) 0 else @max(matrix[j * n + i], 0);
            if (forward <= 0 and backward <= 0) continue;
            // The ribbon spans sub-arc (i,j) and sub-arc (j,i); the heavier
            // direction picks the color.
            const src: usize = if (forward >= backward) i else j;
            const d = ribbonPath(
                a,
                cx,
                cy,
                r_inner,
                lay.sub_start[i * n + j],
                lay.sub_end[i * n + j],
                lay.sub_start[j * n + i],
                lay.sub_end[j * n + i],
            ) catch return errNode(ctx);
            shapes.append(a, .{ .path = .{ .d = d, .style = .{
                .fill = opts.colors[src % opts.colors.len],
                .opacity = opts.ribbon_opacity,
            } } }) catch return errNode(ctx);
        }
    }

    for (0..n) |i| {
        if (lay.group_end[i] - lay.group_start[i] <= 0) continue;
        const d = annularArcPath(a, cx, cy, r_inner, r_outer, lay.group_start[i], lay.group_end[i]) catch return errNode(ctx);
        shapes.append(a, .{ .path = .{ .d = d, .style = .{
            .fill = opts.colors[i % opts.colors.len],
            .stroke = opts.stroke,
            .stroke_width = 1,
        } } }) catch return errNode(ctx);

        const mid = (lay.group_start[i] + lay.group_end[i]) / 2;
        const lr = r_outer + opts.label_size * 0.8;
        const on_right = @cos(mid) >= 0;
        shapes.append(a, .{ .text = .{
            .x = cx + lr * @cos(mid),
            .y = cy + lr * @sin(mid) + opts.label_size / 3,
            .content = labels[i],
            .anchor = if (on_right) .start else .end,
            .font_size = opts.label_size,
            .style = .{ .fill = opts.label_color },
        } }) catch return errNode(ctx);
    }

    return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = shapes.items });
}

/// Donut-segment path: outer arc forward, inner arc back, closed.
fn annularArcPath(a: std.mem.Allocator, cx: f64, cy: f64, ir: f64, or_: f64, a0: f64, a1: f64) ![]const u8 {
    const large: u8 = if (a1 - a0 > std.math.pi) 1 else 0;
    const ox0 = cx + or_ * @cos(a0);
    const oy0 = cy + or_ * @sin(a0);
    const ox1 = cx + or_ * @cos(a1);
    const oy1 = cy + or_ * @sin(a1);
    const ix0 = cx + ir * @cos(a0);
    const iy0 = cy + ir * @sin(a0);
    const ix1 = cx + ir * @cos(a1);
    const iy1 = cy + ir * @sin(a1);
    return std.fmt.allocPrint(
        a,
        "M {d},{d} A {d},{d} 0 {d} 1 {d},{d} L {d},{d} A {d},{d} 0 {d} 0 {d},{d} Z",
        .{ ox0, oy0, or_, or_, large, ox1, oy1, ix1, iy1, ir, ir, large, ix0, iy0 },
    );
}

/// Ribbon between sub-arc [s0, e0] and sub-arc [s1, e1] at radius `r`: arc
/// along the source slice, a quadratic through the center to the target
/// slice, arc along it, and a quadratic back. Degenerates cleanly for
/// self-flows (both slices in the same group).
fn ribbonPath(a: std.mem.Allocator, cx: f64, cy: f64, r: f64, s0: f64, e0: f64, s1: f64, e1: f64) ![]const u8 {
    const l0: u8 = if (e0 - s0 > std.math.pi) 1 else 0;
    const l1: u8 = if (e1 - s1 > std.math.pi) 1 else 0;
    return std.fmt.allocPrint(
        a,
        "M {d},{d} A {d},{d} 0 {d} 1 {d},{d} Q {d},{d} {d},{d} A {d},{d} 0 {d} 1 {d},{d} Q {d},{d} {d},{d} Z",
        .{
            cx + r * @cos(s0), cy + r * @sin(s0),
            r,                 r,
            l0,                cx + r * @cos(e0),
            cy + r * @sin(e0), cx,
            cy,                cx + r * @cos(s1),
            cy + r * @sin(s1), r,
            r,                 l1,
            cx + r * @cos(e1), cy + r * @sin(e1),
            cx,                cy,
            cx + r * @cos(s0), cy + r * @sin(s0),
        },
    );
}

fn errNode(ctx: *const Context) *Node {
    const node = ctx.el("svg");
    node.err = error.OutOfMemory;
    return node;
}

// ---- tests ---------------------------------------------------------------

const testing = std.testing;

test "chord group spans sum to the padded circle" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const m = [_]f64{
        0, 5, 2,
        3, 0, 4,
        1, 6, 0,
    };
    const lay = try chordLayout(arena.allocator(), &m, 3, 0.05);
    var span: f64 = 0;
    for (0..3) |i| span += lay.group_end[i] - lay.group_start[i];
    try testing.expectApproxEqAbs(2.0 * std.math.pi - 3 * 0.05, span, 1e-9);
}

test "chord sub-arc spans tile their group exactly and scale with the cell" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const m = [_]f64{
        0, 4, 4,
        1, 0, 1,
        2, 2, 0,
    };
    const lay = try chordLayout(arena.allocator(), &m, 3, 0.02);
    for (0..3) |i| {
        var sub: f64 = 0;
        for (0..3) |j| sub += lay.sub_end[i * 3 + j] - lay.sub_start[i * 3 + j];
        try testing.expectApproxEqAbs(lay.group_end[i] - lay.group_start[i], sub, 1e-9);
    }
    // row 0: cells 4 and 4 → equal sub-spans
    const s01 = lay.sub_end[1] - lay.sub_start[1];
    const s02 = lay.sub_end[2] - lay.sub_start[2];
    try testing.expectApproxEqAbs(s01, s02, 1e-9);
}

test "chord rejects a mis-sized matrix and tolerates an all-zero one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const wrong = [_]f64{ 1, 2, 3 };
    try testing.expectError(error.BadMatrix, chordLayout(arena.allocator(), &wrong, 2, 0.02));
    const zeros = [_]f64{ 0, 0, 0, 0 };
    const lay = try chordLayout(arena.allocator(), &zeros, 2, 0.02);
    for (0..2) |i| try testing.expectApproxEqAbs(@as(f64, 0), lay.group_end[i] - lay.group_start[i], 1e-9);
}

test "chord render emits one arc per nonzero group and one ribbon per nonzero pair" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Renderer = @import("../renderer.zig").Renderer;
    const ctx = Context.init(&arena);
    const labels = [_][]const u8{ "a", "b", "c" };
    // pairs with flow: {a,b} (both ways), {b,c} (one way) → 2 ribbons; all
    // three groups have nonzero rows except c? c row = {0,3,0} nonzero → 3 arcs.
    const m = [_]f64{
        0, 5, 0,
        2, 0, 0,
        0, 3, 0,
    };
    const tree = try chord(&ctx, &labels, &m, .{}).build();
    var buf: [16384]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try Renderer.render(&w, tree);
    const out = w.buffered();
    var paths: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, out, i, "<path")) |at| {
        paths += 1;
        i = at + 5;
    }
    // 2 ribbons + 3 group arcs
    try testing.expectEqual(@as(usize, 5), paths);
}

test "chord with an empty matrix renders an empty svg without crashing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Renderer = @import("../renderer.zig").Renderer;
    const ctx = Context.init(&arena);
    const tree = try chord(&ctx, &.{}, &.{}, .{}).build();
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try Renderer.render(&w, tree);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "<svg") != null);
}
