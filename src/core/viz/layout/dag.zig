//! Layered (Sugiyama) layout for directed acyclic graphs — flowcharts,
//! dependency graphs, pipelines. Three phases:
//!
//!   1. **Layering** — longest-path: each node sits one layer below its deepest
//!      predecessor. Cycles are tolerated (relaxation bounded to `n` passes).
//!   2. **Ordering** — crossing minimization: alternating down/up sweeps reorder
//!      each layer by the barycenter (mean position) of its neighbors in the
//!      adjacent layer; the ordering with the fewest edge crossings across the
//!      sweeps is kept. Set `Opts.crossing_iterations = 0` to skip (stable
//!      id-order). Long edges spanning >1 layer are not yet split into virtual
//!      nodes — crossings are reduced over edges between adjacent layers.
//!   3. **Positioning** — depth → y, in-layer slot → x (each layer centered).

const std = @import("std");
const geom = @import("../geom.zig");
const common = @import("common.zig");

const Vec2 = geom.Vec2;

pub const Opts = struct {
    x_gap: f64 = 90,
    y_gap: f64 = 90,
    origin: Vec2 = .{ .x = 0, .y = 0 },
    /// Crossing-minimization sweeps. 0 disables (keeps stable id-order).
    crossing_iterations: usize = 8,
};

/// Compute a position per node from directed edges. Caller owns the slice.
pub fn layout(alloc: std.mem.Allocator, n: usize, edges: []const common.Edge, opts: Opts) ![]Vec2 {
    const out = try alloc.alloc(Vec2, n);
    errdefer alloc.free(out);
    if (n == 0) return out;

    // All scratch lives in a child arena — freed in one shot at return.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // --- 1. Longest-path layering (bounded for cycles) ---
    const layer = try a.alloc(usize, n);
    @memset(layer, 0);
    var pass: usize = 0;
    while (pass < n) : (pass += 1) {
        var changed = false;
        for (edges) |e| {
            if (e[0] >= n or e[1] >= n) continue;
            if (layer[e[1]] < layer[e[0]] + 1) {
                layer[e[1]] = layer[e[0]] + 1;
                changed = true;
            }
        }
        if (!changed) break;
    }

    var max_layer: usize = 0;
    for (layer) |l| max_layer = @max(max_layer, l);
    const width = try a.alloc(usize, max_layer + 1);
    @memset(width, 0);
    for (0..n) |i| width[layer[i]] += 1;

    // --- per-layer node lists + node→in-layer position ---
    const layers = try a.alloc([]usize, max_layer + 1);
    for (0..max_layer + 1) |l| layers[l] = try a.alloc(usize, width[l]);
    const fill = try a.alloc(usize, max_layer + 1);
    @memset(fill, 0);
    const order_pos = try a.alloc(usize, n);
    for (0..n) |i| {
        const l = layer[i];
        layers[l][fill[l]] = i;
        order_pos[i] = fill[l];
        fill[l] += 1;
    }

    // --- 2. Crossing minimization ---
    if (opts.crossing_iterations > 0 and max_layer > 0) {
        // Undirected adjacency.
        var adj = try a.alloc(std.ArrayList(usize), n);
        for (adj) |*x| x.* = .empty;
        for (edges) |e| {
            if (e[0] >= n or e[1] >= n or e[0] == e[1]) continue;
            try adj[e[0]].append(a, e[1]);
            try adj[e[1]].append(a, e[0]);
        }

        var max_width: usize = 0;
        for (width) |w| max_width = @max(max_width, w);
        const items = try a.alloc(Item, max_width);
        const recs = try a.alloc(Rec, edges.len);
        const best_pos = try a.alloc(usize, n);
        @memcpy(best_pos, order_pos);
        var best_cross = countCrossings(edges, layer, order_pos, recs);

        var it: usize = 0;
        while (it < opts.crossing_iterations) : (it += 1) {
            var l: usize = 1; // down sweep: order each layer by the one above
            while (l <= max_layer) : (l += 1) orderLayer(layers[l], order_pos, layer, adj, l - 1, items);
            l = max_layer; // up sweep: order each layer by the one below
            while (l > 0) {
                l -= 1;
                orderLayer(layers[l], order_pos, layer, adj, l + 1, items);
            }
            const c = countCrossings(edges, layer, order_pos, recs);
            if (c < best_cross) {
                best_cross = c;
                @memcpy(best_pos, order_pos);
            }
            if (best_cross == 0) break;
        }
        @memcpy(order_pos, best_pos);
    }

    // --- 3. Positioning ---
    for (0..n) |i| {
        const count = width[layer[i]];
        const offset = (@as(f64, @floatFromInt(count)) - 1.0) / 2.0;
        out[i] = .{
            .x = opts.origin.x + (@as(f64, @floatFromInt(order_pos[i])) - offset) * opts.x_gap,
            .y = opts.origin.y + @as(f64, @floatFromInt(layer[i])) * opts.y_gap,
        };
    }
    return out;
}

const Item = struct { key: f64, ord: usize, node: usize };

/// Reorder `nodes` (one layer) by the barycenter of each node's neighbors in
/// `adj_layer`. Nodes with no neighbor there keep their current position (so
/// they don't drift). Ties break by prior order → stable + deterministic.
fn orderLayer(
    nodes: []usize,
    order_pos: []usize,
    layer: []const usize,
    adj: []std.ArrayList(usize),
    adj_layer: usize,
    items: []Item,
) void {
    if (nodes.len <= 1) return;
    for (nodes, 0..) |v, idx| {
        var sum: f64 = 0;
        var cnt: usize = 0;
        for (adj[v].items) |u| {
            if (layer[u] == adj_layer) {
                sum += @floatFromInt(order_pos[u]);
                cnt += 1;
            }
        }
        const key: f64 = if (cnt == 0) @floatFromInt(order_pos[v]) else sum / @as(f64, @floatFromInt(cnt));
        items[idx] = .{ .key = key, .ord = idx, .node = v };
    }
    const slice = items[0..nodes.len];
    std.sort.pdq(Item, slice, {}, lessItem);
    for (slice, 0..) |item, idx| {
        nodes[idx] = item.node;
        order_pos[item.node] = idx;
    }
}

fn lessItem(_: void, x: Item, y: Item) bool {
    if (x.key != y.key) return x.key < y.key;
    return x.ord < y.ord;
}

const Rec = struct { boundary: usize, up: usize, low: usize };

/// Total edge crossings between adjacent layers, for the current ordering. Only
/// span-1 edges (endpoints in consecutive layers) are counted.
fn countCrossings(edges: []const common.Edge, layer: []const usize, order_pos: []const usize, recs: []Rec) usize {
    var m: usize = 0;
    for (edges) |e| {
        if (e[0] >= layer.len or e[1] >= layer.len) continue;
        const la = layer[e[0]];
        const lb = layer[e[1]];
        const diff = if (la > lb) la - lb else lb - la;
        if (diff != 1) continue;
        const upper = if (la < lb) e[0] else e[1];
        const lower = if (la < lb) e[1] else e[0];
        recs[m] = .{ .boundary = @min(la, lb), .up = order_pos[upper], .low = order_pos[lower] };
        m += 1;
    }
    var crossings: usize = 0;
    for (0..m) |i| {
        for (i + 1..m) |j| {
            if (recs[i].boundary != recs[j].boundary) continue;
            const du = @as(i64, @intCast(recs[i].up)) - @as(i64, @intCast(recs[j].up));
            const dl = @as(i64, @intCast(recs[i].low)) - @as(i64, @intCast(recs[j].low));
            if (du * dl < 0) crossings += 1;
        }
    }
    return crossings;
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

test "longest-path layering assigns correct depths" {
    const edges = [_]common.Edge{ .{ 0, 1 }, .{ 1, 2 }, .{ 0, 2 } };
    const pos = try layout(testing.allocator, 3, &edges, .{ .y_gap = 100 });
    defer testing.allocator.free(pos);
    try testing.expectEqual(@as(f64, 0), pos[0].y);
    try testing.expectEqual(@as(f64, 100), pos[1].y);
    try testing.expectEqual(@as(f64, 200), pos[2].y);
}

test "siblings share a layer and spread horizontally" {
    // 0→1, 0→2, 0→3 : all children share parent 0 → equal barycenters → stable
    // id-order preserved (no spurious reordering).
    const edges = [_]common.Edge{ .{ 0, 1 }, .{ 0, 2 }, .{ 0, 3 } };
    const pos = try layout(testing.allocator, 4, &edges, .{ .x_gap = 50, .y_gap = 80 });
    defer testing.allocator.free(pos);
    try testing.expectEqual(@as(f64, 80), pos[1].y);
    try testing.expectEqual(@as(f64, -50), pos[1].x);
    try testing.expectEqual(@as(f64, 0), pos[2].x);
    try testing.expectEqual(@as(f64, 50), pos[3].x);
}

test "cycle does not hang and stays finite" {
    const edges = [_]common.Edge{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 0 } };
    const pos = try layout(testing.allocator, 3, &edges, .{});
    defer testing.allocator.free(pos);
    for (pos) |p| try testing.expect(!std.math.isNan(p.x) and !std.math.isNan(p.y));
}

test "crossing minimization untangles a crossed bipartite pair" {
    // 0,1 on layer 0; 2,3 on layer 1. Edges 0→3 and 1→2 cross under id-order
    // (layer 1 = [2,3]); the sweep reorders layer 1 to [3,2] so 3 sits under 0.
    const edges = [_]common.Edge{ .{ 0, 3 }, .{ 1, 2 } };
    const pos = try layout(testing.allocator, 4, &edges, .{ .x_gap = 100 });
    defer testing.allocator.free(pos);
    // node 3 placed left of node 2 → no crossing.
    try testing.expect(pos[3].x < pos[2].x);
    // node 0 stays left of node 1.
    try testing.expect(pos[0].x < pos[1].x);
}

test "crossing_iterations = 0 keeps stable id-order (still crossed)" {
    const edges = [_]common.Edge{ .{ 0, 3 }, .{ 1, 2 } };
    const pos = try layout(testing.allocator, 4, &edges, .{ .x_gap = 100, .crossing_iterations = 0 });
    defer testing.allocator.free(pos);
    // id-order layer 1 = [2,3] → node 2 left of node 3.
    try testing.expect(pos[2].x < pos[3].x);
}

test "countCrossings: zero when untangled, positive when crossed" {
    var recs: [4]Rec = undefined;
    const edges = [_]common.Edge{ .{ 0, 3 }, .{ 1, 2 } };
    const layer = [_]usize{ 0, 0, 1, 1 };
    // crossed ordering: 0@0,1@1 (upper), 2@0,3@1 (lower)
    const crossed = [_]usize{ 0, 1, 0, 1 };
    try testing.expectEqual(@as(usize, 1), countCrossings(&edges, &layer, &crossed, &recs));
    // untangled: swap lower so 3@0, 2@1
    const clean = [_]usize{ 0, 1, 1, 0 };
    try testing.expectEqual(@as(usize, 0), countCrossings(&edges, &layer, &clean, &recs));
}
