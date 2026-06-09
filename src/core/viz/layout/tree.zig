//! Tidy hierarchical tree layout. Leaves are placed left-to-right at evenly
//! spaced x slots; each internal node is centered over its children; depth maps
//! to y. Deterministic and O(V+E) — a good pipeline-proving layout and the
//! right default for hierarchies. (A full Reingold–Tilford sibling-subtree
//! contour pass is deferred; this parent-centering variant is tidy for the
//! common, non-overlapping cases.)

const std = @import("std");
const geom = @import("../geom.zig");
const common = @import("common.zig");

const Vec2 = geom.Vec2;

pub const Opts = struct {
    root: usize = 0,
    x_gap: f64 = 60,
    y_gap: f64 = 80,
    origin: Vec2 = .{ .x = 0, .y = 0 },
};

/// Recursive x-assignment state: leaves consume slots left-to-right, parents
/// center over their children.
const Assign = struct {
    xs: []f64,
    children: [][]usize,
    x_gap: f64,
    next_leaf: f64 = 0,

    fn visit(self: *Assign, node: usize) void {
        const kids = self.children[node];
        if (kids.len == 0) {
            self.xs[node] = self.next_leaf * self.x_gap;
            self.next_leaf += 1;
            return;
        }
        var sum: f64 = 0;
        for (kids) |c| {
            self.visit(c);
            sum += self.xs[c];
        }
        self.xs[node] = sum / @as(f64, @floatFromInt(kids.len));
    }
};

/// Compute a position per node. Caller owns the returned slice.
pub fn layout(alloc: std.mem.Allocator, n: usize, edges: []const common.Edge, opts: Opts) ![]Vec2 {
    const out = try alloc.alloc(Vec2, n);
    errdefer alloc.free(out);
    if (n == 0) return out;

    var h = try common.buildHierarchy(alloc, n, edges, opts.root);
    defer h.deinit();

    const xs = try alloc.alloc(f64, n);
    defer alloc.free(xs);

    // DFS post-order from each component root, visiting children in natural
    // order so leaves take x slots left-to-right; each parent centers over its
    // children once they are placed.
    var asn = Assign{ .xs = xs, .children = h.children, .x_gap = opts.x_gap };
    for (h.order) |node| {
        if (h.parent[node] == common.Hierarchy.no_parent) asn.visit(node);
    }

    for (0..n) |i| {
        out[i] = .{
            .x = opts.origin.x + xs[i],
            .y = opts.origin.y + @as(f64, @floatFromInt(h.depth[i])) * opts.y_gap,
        };
    }
    return out;
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

test "balanced binary tree centers parents over children" {
    // 0 -> {1,2}; 1 -> {3,4}; 2 -> {5,6}
    const edges = [_]common.Edge{ .{ 0, 1 }, .{ 0, 2 }, .{ 1, 3 }, .{ 1, 4 }, .{ 2, 5 }, .{ 2, 6 } };
    const pos = try layout(testing.allocator, 7, &edges, .{ .x_gap = 10, .y_gap = 20 });
    defer testing.allocator.free(pos);

    // Leaves 3,4,5,6 at x = 0,10,20,30; y = depth 2 * 20 = 40.
    try testing.expectEqual(@as(f64, 0), pos[3].x);
    try testing.expectEqual(@as(f64, 30), pos[6].x);
    try testing.expectEqual(@as(f64, 40), pos[3].y);
    // Internal 1 centered over {3,4} = 5; 2 over {5,6} = 25; depth 1 → y=20.
    try testing.expectEqual(@as(f64, 5), pos[1].x);
    try testing.expectEqual(@as(f64, 25), pos[2].x);
    try testing.expectEqual(@as(f64, 20), pos[1].y);
    // Root centered over {1,2} = 15; depth 0 → y=0.
    try testing.expectEqual(@as(f64, 15), pos[0].x);
    try testing.expectEqual(@as(f64, 0), pos[0].y);
}

test "disconnected node still placed" {
    const edges = [_]common.Edge{.{ 0, 1 }};
    const pos = try layout(testing.allocator, 3, &edges, .{ .x_gap = 10, .y_gap = 20 });
    defer testing.allocator.free(pos);
    // node 2 unreachable → treated as its own root leaf at depth 0
    try testing.expectEqual(@as(f64, 0), pos[2].y);
    for (pos) |p| {
        try testing.expect(!std.math.isNan(p.x));
        try testing.expect(!std.math.isNan(p.y));
    }
}
