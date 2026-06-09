//! Layered (Sugiyama) layout for directed acyclic graphs — flowcharts,
//! dependency graphs, pipelines. Four phases:
//!
//!   1. **Layering** — longest-path: each node sits one layer below its deepest
//!      predecessor. Cycles are tolerated (relaxation bounded to `n` passes).
//!   2. **Virtual nodes** — every forward edge spanning >1 layer is split into a
//!      chain of dummy nodes, one per intermediate layer, so the edge is a run
//!      of span-1 segments. They reserve routing channels and let ordering +
//!      crossing-counting account for long edges at every layer boundary.
//!   3. **Ordering** — crossing minimization: alternating down/up barycenter
//!      sweeps over real + virtual nodes, keeping the ordering with the fewest
//!      crossings (`crossing_iterations`, 0 = stable id-order).
//!   4. **Positioning** — depth → y, in-layer slot → x (each layer centered).
//!
//! `layoutRouted` returns real-node positions plus a polyline per input edge
//! (bending through its virtual nodes); `layout` is the positions-only form.

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

/// Layout result with routed edges. `positions` has one entry per real node
/// (indices 0..n); `paths[i]` is the polyline for `edges[i]` — `[from, bend…,
/// to]` for routed long edges, `[from, to]` otherwise. Caller owns it.
pub const Routed = struct {
    positions: []Vec2,
    paths: [][]Vec2,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *Routed) void {
        for (self.paths) |p| self.alloc.free(p);
        self.alloc.free(self.paths);
        self.alloc.free(self.positions);
    }
};

/// Positions-only form (back-compat). Routed paths are computed then dropped.
pub fn layout(alloc: std.mem.Allocator, n: usize, edges: []const common.Edge, opts: Opts) ![]Vec2 {
    const routed = try layoutRouted(alloc, n, edges, opts);
    for (routed.paths) |p| alloc.free(p);
    alloc.free(routed.paths);
    return routed.positions;
}

/// Full layout with virtual-node edge routing.
pub fn layoutRouted(alloc: std.mem.Allocator, n: usize, edges: []const common.Edge, opts: Opts) !Routed {
    const positions = try alloc.alloc(Vec2, n);
    errdefer alloc.free(positions);
    if (n == 0) {
        const paths = try alloc.alloc([]Vec2, edges.len);
        for (paths) |*p| p.* = try alloc.alloc(Vec2, 0);
        return .{ .positions = positions, .paths = paths, .alloc = alloc };
    }

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

    // --- 2. Virtual nodes: split forward long edges into span-1 chains ---
    const chains = try a.alloc([]usize, edges.len);
    @memset(chains, &.{});
    var vlayers: std.ArrayList(usize) = .empty; // layer of virtual node n+idx
    var segs: std.ArrayList([2]usize) = .empty; // all span-1 segments
    var total = n;
    for (edges, 0..) |e, i| {
        if (e[0] >= n or e[1] >= n) continue;
        const lu = layer[e[0]];
        const lv = layer[e[1]];
        if (lv > lu + 1) {
            const chain = try a.alloc(usize, lv - lu - 1);
            var prev = e[0];
            var l = lu + 1;
            var k: usize = 0;
            while (l < lv) : (l += 1) {
                const vn = total;
                total += 1;
                try vlayers.append(a, l);
                chain[k] = vn;
                k += 1;
                try segs.append(a, .{ prev, vn });
                prev = vn;
            }
            try segs.append(a, .{ prev, e[1] });
            chains[i] = chain;
        } else {
            try segs.append(a, .{ e[0], e[1] });
        }
    }

    // Node layer for real + virtual.
    const nlayer = try a.alloc(usize, total);
    for (0..n) |i| nlayer[i] = layer[i];
    for (vlayers.items, 0..) |vl, idx| nlayer[n + idx] = vl;

    // --- per-layer node lists + node→in-layer position ---
    const width = try a.alloc(usize, max_layer + 1);
    @memset(width, 0);
    for (0..total) |i| width[nlayer[i]] += 1;
    const layers = try a.alloc([]usize, max_layer + 1);
    for (0..max_layer + 1) |l| layers[l] = try a.alloc(usize, width[l]);
    const fill = try a.alloc(usize, max_layer + 1);
    @memset(fill, 0);
    const order_pos = try a.alloc(usize, total);
    for (0..total) |i| {
        const l = nlayer[i];
        layers[l][fill[l]] = i;
        order_pos[i] = fill[l];
        fill[l] += 1;
    }

    // --- 3. Crossing minimization over real + virtual nodes ---
    if (opts.crossing_iterations > 0 and max_layer > 0) {
        var adj = try a.alloc(std.ArrayList(usize), total);
        for (adj) |*x| x.* = .empty;
        for (segs.items) |s| {
            try adj[s[0]].append(a, s[1]);
            try adj[s[1]].append(a, s[0]);
        }
        var max_width: usize = 0;
        for (width) |w| max_width = @max(max_width, w);
        const items = try a.alloc(Item, max_width);
        const recs = try a.alloc(Rec, segs.items.len);
        const best_pos = try a.alloc(usize, total);
        @memcpy(best_pos, order_pos);
        var best_cross = countCrossings(segs.items, nlayer, order_pos, recs);
        var it: usize = 0;
        while (it < opts.crossing_iterations) : (it += 1) {
            var l: usize = 1;
            while (l <= max_layer) : (l += 1) orderLayer(layers[l], order_pos, nlayer, adj, l - 1, items);
            l = max_layer;
            while (l > 0) {
                l -= 1;
                orderLayer(layers[l], order_pos, nlayer, adj, l + 1, items);
            }
            const c = countCrossings(segs.items, nlayer, order_pos, recs);
            if (c < best_cross) {
                best_cross = c;
                @memcpy(best_pos, order_pos);
            }
            if (best_cross == 0) break;
        }
        @memcpy(order_pos, best_pos);
    }

    // --- 4. Positioning (all nodes) ---
    const allpos = try a.alloc(Vec2, total);
    for (0..total) |i| {
        const count = width[nlayer[i]];
        const offset = (@as(f64, @floatFromInt(count)) - 1.0) / 2.0;
        allpos[i] = .{
            .x = opts.origin.x + (@as(f64, @floatFromInt(order_pos[i])) - offset) * opts.x_gap,
            .y = opts.origin.y + @as(f64, @floatFromInt(nlayer[i])) * opts.y_gap,
        };
    }
    for (0..n) |i| positions[i] = allpos[i];

    // --- edge polylines (caller-owned) ---
    const paths = try alloc.alloc([]Vec2, edges.len);
    var built: usize = 0;
    errdefer {
        for (paths[0..built]) |p| alloc.free(p);
        alloc.free(paths);
    }
    for (edges, 0..) |e, i| {
        if (e[0] >= n or e[1] >= n) {
            paths[i] = try alloc.alloc(Vec2, 0);
            built = i + 1;
            continue;
        }
        const chain = chains[i];
        const p = try alloc.alloc(Vec2, chain.len + 2);
        p[0] = allpos[e[0]];
        for (chain, 0..) |vn, k| p[k + 1] = allpos[vn];
        p[chain.len + 1] = allpos[e[1]];
        paths[i] = p;
        built = i + 1;
    }

    return .{ .positions = positions, .paths = paths, .alloc = alloc };
}

const Item = struct { key: f64, ord: usize, node: usize };

/// Reorder `nodes` (one layer) by the barycenter of each node's neighbors in
/// `adj_layer`. No-neighbor nodes keep their position; ties break by prior
/// order → stable + deterministic.
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

/// Total edge crossings between adjacent layers for the current ordering. With
/// virtual nodes every segment is span-1, so all are counted.
fn countCrossings(segments: []const common.Edge, layer: []const usize, order_pos: []const usize, recs: []Rec) usize {
    var m: usize = 0;
    for (segments) |e| {
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
    const edges = [_]common.Edge{ .{ 0, 3 }, .{ 1, 2 } };
    const pos = try layout(testing.allocator, 4, &edges, .{ .x_gap = 100 });
    defer testing.allocator.free(pos);
    try testing.expect(pos[3].x < pos[2].x);
    try testing.expect(pos[0].x < pos[1].x);
}

test "crossing_iterations = 0 keeps stable id-order (still crossed)" {
    const edges = [_]common.Edge{ .{ 0, 3 }, .{ 1, 2 } };
    const pos = try layout(testing.allocator, 4, &edges, .{ .x_gap = 100, .crossing_iterations = 0 });
    defer testing.allocator.free(pos);
    try testing.expect(pos[2].x < pos[3].x);
}

test "countCrossings: zero when untangled, positive when crossed" {
    var recs: [4]Rec = undefined;
    const edges = [_]common.Edge{ .{ 0, 3 }, .{ 1, 2 } };
    const layer = [_]usize{ 0, 0, 1, 1 };
    const crossed = [_]usize{ 0, 1, 0, 1 };
    try testing.expectEqual(@as(usize, 1), countCrossings(&edges, &layer, &crossed, &recs));
    const clean = [_]usize{ 0, 1, 1, 0 };
    try testing.expectEqual(@as(usize, 0), countCrossings(&edges, &layer, &clean, &recs));
}

test "long edge routes through a virtual bend at each intermediate layer" {
    // 0→1→2 plus the long edge 0→2 (spans layers 0..2).
    const edges = [_]common.Edge{ .{ 0, 1 }, .{ 1, 2 }, .{ 0, 2 } };
    var routed = try layoutRouted(testing.allocator, 3, &edges, .{ .y_gap = 100 });
    defer routed.deinit();
    // span-1 edges: straight (2 points).
    try testing.expectEqual(@as(usize, 2), routed.paths[0].len);
    try testing.expectEqual(@as(usize, 2), routed.paths[1].len);
    // long edge 0→2: one bend → 3 points, the bend on layer 1 (y = 100).
    try testing.expectEqual(@as(usize, 3), routed.paths[2].len);
    try testing.expectEqual(@as(f64, 0), routed.paths[2][0].y); // from, layer 0
    try testing.expectEqual(@as(f64, 100), routed.paths[2][1].y); // bend, layer 1
    try testing.expectEqual(@as(f64, 200), routed.paths[2][2].y); // to, layer 2
}

test "virtual node reserves a channel: real node shifts to make room" {
    // Without the long edge 0→2, node 1 is alone on layer 1 (x=0). With it, a
    // virtual node shares layer 1, so node 1 is pushed off-center.
    const straight = [_]common.Edge{ .{ 0, 1 }, .{ 1, 2 } };
    const p1 = try layout(testing.allocator, 3, &straight, .{ .x_gap = 100 });
    defer testing.allocator.free(p1);
    try testing.expectEqual(@as(f64, 0), p1[1].x);

    const withlong = [_]common.Edge{ .{ 0, 1 }, .{ 1, 2 }, .{ 0, 2 } };
    const p2 = try layout(testing.allocator, 3, &withlong, .{ .x_gap = 100 });
    defer testing.allocator.free(p2);
    try testing.expect(p2[1].x != 0); // layer 1 now has 2 nodes → node 1 off-center
}
