//! Layered (Sugiyama-style) layout for directed acyclic graphs — flowcharts,
//! dependency graphs, pipelines. Edges are treated as **directed** (`from →
//! to`); each node is placed in the layer one below its deepest predecessor
//! (longest-path layering), and nodes within a layer are spread evenly.
//!
//! This is the "lite" variant: it does longest-path layering and stable
//! in-layer ordering, but skips the crossing-minimization (barycenter) sweep a
//! full Sugiyama pipeline runs. Cycles in the input are tolerated — the
//! relaxation is bounded to `n` passes so a back-edge can't loop forever; it
//! just won't produce a clean layering.

const std = @import("std");
const geom = @import("../geom.zig");
const common = @import("common.zig");

const Vec2 = geom.Vec2;

pub const Opts = struct {
    x_gap: f64 = 90,
    y_gap: f64 = 90,
    origin: Vec2 = .{ .x = 0, .y = 0 },
};

/// Compute a position per node from directed edges. Caller owns the slice.
pub fn layout(alloc: std.mem.Allocator, n: usize, edges: []const common.Edge, opts: Opts) ![]Vec2 {
    const out = try alloc.alloc(Vec2, n);
    errdefer alloc.free(out);
    if (n == 0) return out;

    // Longest-path layering: relax layer[to] = max(layer[to], layer[from]+1)
    // until stable, bounded to n passes to survive cycles.
    const layer = try alloc.alloc(usize, n);
    defer alloc.free(layer);
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

    // Count nodes per layer and assign each an in-layer slot (stable: node-id
    // order within a layer).
    var max_layer: usize = 0;
    for (layer) |l| max_layer = @max(max_layer, l);
    const width = try alloc.alloc(usize, max_layer + 1);
    defer alloc.free(width);
    @memset(width, 0);
    const slot = try alloc.alloc(usize, n);
    defer alloc.free(slot);
    for (0..n) |i| {
        slot[i] = width[layer[i]];
        width[layer[i]] += 1;
    }

    // Center each layer's row horizontally around x=0 so fitPositions can
    // recenter the whole drawing cleanly.
    for (0..n) |i| {
        const count = width[layer[i]];
        const offset = (@as(f64, @floatFromInt(count)) - 1.0) / 2.0;
        out[i] = .{
            .x = opts.origin.x + (@as(f64, @floatFromInt(slot[i])) - offset) * opts.x_gap,
            .y = opts.origin.y + @as(f64, @floatFromInt(layer[i])) * opts.y_gap,
        };
    }
    return out;
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

test "longest-path layering assigns correct depths" {
    // 0→1→2 and 0→2 : node 2 must sit below node 1 (longest path), not beside it.
    const edges = [_]common.Edge{ .{ 0, 1 }, .{ 1, 2 }, .{ 0, 2 } };
    const pos = try layout(testing.allocator, 3, &edges, .{ .y_gap = 100 });
    defer testing.allocator.free(pos);
    try testing.expectEqual(@as(f64, 0), pos[0].y); // layer 0
    try testing.expectEqual(@as(f64, 100), pos[1].y); // layer 1
    try testing.expectEqual(@as(f64, 200), pos[2].y); // layer 2 (longest path wins)
}

test "siblings share a layer and spread horizontally" {
    // 0→1, 0→2, 0→3 : three children all on layer 1, centered around x=0.
    const edges = [_]common.Edge{ .{ 0, 1 }, .{ 0, 2 }, .{ 0, 3 } };
    const pos = try layout(testing.allocator, 4, &edges, .{ .x_gap = 50, .y_gap = 80 });
    defer testing.allocator.free(pos);
    try testing.expectEqual(@as(f64, 80), pos[1].y);
    try testing.expectEqual(@as(f64, 80), pos[2].y);
    try testing.expectEqual(@as(f64, 80), pos[3].y);
    // slots 0,1,2 with offset 1 → x = -50, 0, +50
    try testing.expectEqual(@as(f64, -50), pos[1].x);
    try testing.expectEqual(@as(f64, 0), pos[2].x);
    try testing.expectEqual(@as(f64, 50), pos[3].x);
}

test "cycle does not hang and stays finite" {
    const edges = [_]common.Edge{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 0 } };
    const pos = try layout(testing.allocator, 3, &edges, .{});
    defer testing.allocator.free(pos);
    for (pos) |p| {
        try testing.expect(!std.math.isNan(p.x) and !std.math.isNan(p.y));
    }
}
