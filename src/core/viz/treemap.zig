//! Squarified treemap (Bruls, Huizing, van Wijk 2000): a hierarchy of values
//! tiled into nested rectangles whose areas are proportional to the values,
//! with rows chosen greedily to keep cells near-square. Pure layout
//! (`treemapLayout`) + a chart-style renderer (`treemap`).
//!
//! The hierarchy is a flat parent-index array: `items[i].parent` must be
//! `null` (root) or `< i` — validated, so internal sums compute in one
//! reverse pass and the layout can run top-down without recursion hazards.

const std = @import("std");
const Node = @import("../node.zig").Node;
const Context = @import("../context.zig").Context;
const scene = @import("scene.zig");
const geom = @import("geom.zig");
const chart = @import("chart.zig");

pub const TreemapItem = struct {
    label: []const u8,
    /// Leaf weight. Internal nodes (anything with children) use the sum of
    /// their descendants; their own `value` is ignored.
    value: f64 = 0,
    parent: ?u32 = null,
};

pub const TreemapOpts = struct {
    width: f64 = 800,
    height: f64 = 500,
    padding: f64 = 2,
    colors: []const []const u8 = &chart.palette,
    label_size: f64 = 11,
    label_color: []const u8 = "#f5f5f5",
    stroke: []const u8 = "#0e0e10",
};

/// Compute one rect per item (internal nodes get their container rect).
/// Returns `error.BadHierarchy` when any `parent >= i`. Caller owns the slice.
pub fn treemapLayout(a: std.mem.Allocator, items: []const TreemapItem, bounds: geom.Rect, padding: f64) ![]geom.Rect {
    const n = items.len;
    const rects = try a.alloc(geom.Rect, n);
    if (n == 0) return rects;

    for (items, 0..) |it, i| {
        if (it.parent) |p| if (p >= i) return error.BadHierarchy;
    }

    // Totals: leaves carry their value; one reverse pass accumulates into
    // parents (valid because parent < child).
    const total = try a.alloc(f64, n);
    const child_count = try a.alloc(usize, n);
    @memset(child_count, 0);
    for (items) |it| {
        if (it.parent) |p| child_count[p] += 1;
    }
    for (0..n) |i| total[i] = if (child_count[i] == 0) @max(items[i].value, 0) else 0;
    var ri: usize = n;
    while (ri > 0) {
        ri -= 1;
        if (items[ri].parent) |p| total[p] += total[ri];
    }

    // Child lists (index order — sorting happens per squarify call).
    const child_start = try a.alloc(usize, n + 1);
    {
        @memset(child_start, 0);
        for (items) |it| {
            if (it.parent) |p| child_start[p + 1] += 1;
        }
        var roots: usize = 0;
        for (items) |it| {
            if (it.parent == null) roots += 1;
        }
        // prefix sums offset by the virtual root's children (roots first)
        child_start[0] = roots;
        for (0..n) |i| child_start[i + 1] += child_start[i];
    }
    const children = try a.alloc(usize, child_start[n]);
    {
        const cursor = try a.alloc(usize, n + 1);
        var root_cursor: usize = 0;
        @memcpy(cursor[1..], child_start[0..n]);
        cursor[0] = 0;
        for (items, 0..) |it, i| {
            if (it.parent) |p| {
                children[cursor[p + 1]] = i;
                cursor[p + 1] += 1;
            } else {
                children[root_cursor] = i;
                root_cursor += 1;
            }
        }
    }
    const roots = children[0..child_start[0]];

    // Top-down: tile each container's children into its (padded) rect.
    // Iterative with an explicit stack; parent rects are final before their
    // children are processed (parent < child + stack discipline).
    const scratch = try a.alloc(usize, n); // sorted children per call
    var stack: std.ArrayList(usize) = .empty; // container item index; maxInt = virtual root
    const VIRTUAL_ROOT = std.math.maxInt(usize);
    try stack.append(a, VIRTUAL_ROOT);
    while (stack.pop()) |container| {
        const kids = if (container == VIRTUAL_ROOT)
            roots
        else
            children[child_start[container]..child_start[container + 1]];
        if (kids.len == 0) continue;
        const outer = if (container == VIRTUAL_ROOT) bounds else rects[container];
        const inner = geom.Rect{
            .x = outer.x + padding,
            .y = outer.y + padding,
            .w = @max(outer.w - 2 * padding, 0),
            .h = @max(outer.h - 2 * padding, 0),
        };
        squarify(kids, total, inner, rects, scratch);
        for (kids) |c| {
            if (child_count[c] != 0) try stack.append(a, c);
        }
    }

    return rects;
}

/// Squarified row tiling of `kids` (weights `total[kid]`) into `rect`,
/// writing each kid's rect. Children sorted descending (index tie-break).
fn squarify(kids: []const usize, total: []const f64, rect: geom.Rect, rects: []geom.Rect, scratch: []usize) void {
    const sorted = scratch[0..kids.len];
    @memcpy(sorted, kids);
    std.sort.pdq(usize, sorted, SortByTotal{ .total = total }, SortByTotal.lessThan);

    var sum: f64 = 0;
    for (sorted) |k| sum = sum + @max(total[k], 0);
    var rest = geom.Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
    if (sum <= 0 or rect.w <= 0 or rect.h <= 0) {
        for (sorted) |k| rects[k] = .{ .x = rect.x, .y = rect.y, .w = 0, .h = 0 };
        return;
    }
    const area_scale = (rect.w * rect.h) / sum;

    var start: usize = 0;
    while (start < sorted.len) {
        const short = @min(rest.w, rest.h);
        // Greedy row: extend while the worst aspect ratio doesn't worsen.
        var row_area: f64 = @max(total[sorted[start]], 0) * area_scale;
        var row_max = row_area;
        var row_min = row_area;
        var end = start + 1;
        var worst = rowWorst(row_area, row_max, row_min, short);
        while (end < sorted.len) {
            const a_next = @max(total[sorted[end]], 0) * area_scale;
            const cand_area = row_area + a_next;
            const cand_max = @max(row_max, a_next);
            const cand_min = @min(row_min, a_next);
            const cand_worst = rowWorst(cand_area, cand_max, cand_min, short);
            if (cand_worst > worst) break;
            row_area = cand_area;
            row_max = cand_max;
            row_min = cand_min;
            worst = cand_worst;
            end += 1;
        }
        // Lay the row along the shorter side of the remaining rect.
        const thick = if (short <= 0) 0 else row_area / short;
        if (rest.w >= rest.h) {
            // vertical strip on the left, items stacked top-to-bottom
            var y = rest.y;
            for (sorted[start..end]) |k| {
                const h = if (row_area <= 0) 0 else @max(total[k], 0) * area_scale / @max(thick, 1e-12);
                rects[k] = .{ .x = rest.x, .y = y, .w = thick, .h = h };
                y += h;
            }
            rest.x += thick;
            rest.w = @max(rest.w - thick, 0);
        } else {
            // horizontal strip on top, items laid left-to-right
            var x = rest.x;
            for (sorted[start..end]) |k| {
                const w = if (row_area <= 0) 0 else @max(total[k], 0) * area_scale / @max(thick, 1e-12);
                rects[k] = .{ .x = x, .y = rest.y, .w = w, .h = thick };
                x += w;
            }
            rest.y += thick;
            rest.h = @max(rest.h - thick, 0);
        }
        start = end;
    }
}

const SortByTotal = struct {
    total: []const f64,

    fn lessThan(ctx: SortByTotal, a: usize, b: usize) bool {
        if (ctx.total[a] != ctx.total[b]) return ctx.total[a] > ctx.total[b]; // descending
        return a < b; // deterministic tie-break
    }
};

/// Worst aspect ratio of a row with the given area extremes laid along a side
/// of length `short` (Bruls eq. — max(w²·a⁺/s², s²/(w²·a⁻))).
fn rowWorst(row_area: f64, row_max: f64, row_min: f64, short: f64) f64 {
    if (row_area <= 0 or short <= 0) return std.math.floatMax(f64);
    const s2 = row_area * row_area;
    const w2 = short * short;
    return @max(w2 * row_max / s2, s2 / (w2 * row_min));
}

/// Render a treemap. Leaves draw as rounded rects colored by their root
/// ancestor; labels render on leaves big enough to hold them.
pub fn treemap(ctx: *const Context, items: []const TreemapItem, opts: TreemapOpts) *Node {
    const a = ctx.allocator;
    const rects = treemapLayout(a, items, .{ .x = 0, .y = 0, .w = opts.width, .h = opts.height }, opts.padding) catch return errNode(ctx);

    // Root-ancestor index per item, for stable color grouping.
    const root_of = a.alloc(usize, items.len) catch return errNode(ctx);
    var root_seq: usize = 0;
    for (items, 0..) |it, i| {
        if (it.parent) |p| {
            root_of[i] = root_of[p];
        } else {
            root_of[i] = root_seq;
            root_seq += 1;
        }
    }
    const has_children = a.alloc(bool, items.len) catch return errNode(ctx);
    @memset(has_children, false);
    for (items) |it| {
        if (it.parent) |p| has_children[p] = true;
    }

    var shapes: std.ArrayList(scene.Shape) = .empty;
    for (items, 0..) |it, i| {
        if (has_children[i]) continue; // draw leaves only
        const r = rects[i];
        if (r.w <= 0 or r.h <= 0) continue;
        shapes.append(a, .{ .rect = .{
            .x = r.x,
            .y = r.y,
            .w = r.w,
            .h = r.h,
            .rx = 2,
            .style = .{ .fill = opts.colors[root_of[i] % opts.colors.len], .stroke = opts.stroke, .stroke_width = 1 },
        } }) catch return errNode(ctx);
        const fits = r.h >= opts.label_size + 6 and r.w >= @as(f64, @floatFromInt(it.label.len)) * opts.label_size * 0.62;
        if (it.label.len != 0 and fits) {
            shapes.append(a, .{ .text = .{
                .x = r.x + r.w / 2,
                .y = r.y + r.h / 2 + opts.label_size / 3,
                .content = it.label,
                .anchor = .middle,
                .font_size = opts.label_size,
                .style = .{ .fill = opts.label_color },
            } }) catch return errNode(ctx);
        }
    }
    return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = shapes.items });
}

fn errNode(ctx: *const Context) *Node {
    const node = ctx.el("svg");
    node.err = error.OutOfMemory;
    return node;
}

// ---- tests ---------------------------------------------------------------

const testing = std.testing;

test "treemap rejects forward parent references" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bad = [_]TreemapItem{
        .{ .label = "child", .value = 1, .parent = 1 },
        .{ .label = "root" },
    };
    try testing.expectError(error.BadHierarchy, treemapLayout(arena.allocator(), &bad, .{ .w = 100, .h = 100 }, 0));
}

test "treemap leaf areas are proportional to values and tile exactly (zero padding)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const items = [_]TreemapItem{
        .{ .label = "a", .value = 6 },
        .{ .label = "b", .value = 3 },
        .{ .label = "c", .value = 1 },
    };
    const rects = try treemapLayout(arena.allocator(), &items, .{ .w = 200, .h = 100 }, 0);
    const total_area: f64 = 200 * 100;
    try testing.expectApproxEqAbs(total_area * 0.6, rects[0].w * rects[0].h, 1e-6);
    try testing.expectApproxEqAbs(total_area * 0.3, rects[1].w * rects[1].h, 1e-6);
    try testing.expectApproxEqAbs(total_area * 0.1, rects[2].w * rects[2].h, 1e-6);
    var sum: f64 = 0;
    for (rects) |r| sum += r.w * r.h;
    try testing.expectApproxEqAbs(total_area, sum, 1e-6);
}

test "treemap children tile inside their parent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const items = [_]TreemapItem{
        .{ .label = "root" },
        .{ .label = "a", .value = 4, .parent = 0 },
        .{ .label = "b", .value = 4, .parent = 0 },
        .{ .label = "other", .value = 8 },
    };
    const rects = try treemapLayout(arena.allocator(), &items, .{ .w = 300, .h = 200 }, 2);
    const parent = rects[0];
    for (rects[1..3]) |r| {
        try testing.expect(r.x >= parent.x - 1e-9);
        try testing.expect(r.y >= parent.y - 1e-9);
        try testing.expect(r.x + r.w <= parent.x + parent.w + 1e-9);
        try testing.expect(r.y + r.h <= parent.y + parent.h + 1e-9);
    }
}

test "squarify keeps the canonical example near-square (worst aspect <= 4)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Bruls et al. canonical weights {6,6,4,3,2,2,1} in a 6×4 rect.
    const items = [_]TreemapItem{
        .{ .label = "", .value = 6 }, .{ .label = "", .value = 6 },
        .{ .label = "", .value = 4 }, .{ .label = "", .value = 3 },
        .{ .label = "", .value = 2 }, .{ .label = "", .value = 2 },
        .{ .label = "", .value = 1 },
    };
    const rects = try treemapLayout(arena.allocator(), &items, .{ .w = 600, .h = 400 }, 0);
    for (rects) |r| {
        try testing.expect(r.w > 0 and r.h > 0);
        const aspect = @max(r.w / r.h, r.h / r.w);
        try testing.expect(aspect <= 4.0 + 1e-9);
    }
}

test "treemap layout is deterministic with equal values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const items = [_]TreemapItem{
        .{ .label = "x", .value = 5 },
        .{ .label = "y", .value = 5 },
        .{ .label = "z", .value = 5 },
    };
    const r1 = try treemapLayout(arena.allocator(), &items, .{ .w = 300, .h = 300 }, 0);
    const r2 = try treemapLayout(arena.allocator(), &items, .{ .w = 300, .h = 300 }, 0);
    for (r1, r2) |a_r, b_r| {
        try testing.expectEqual(a_r.x, b_r.x);
        try testing.expectEqual(a_r.y, b_r.y);
        try testing.expectEqual(a_r.w, b_r.w);
        try testing.expectEqual(a_r.h, b_r.h);
    }
}
