//! Radial (concentric) hierarchy layout. Depth maps to ring radius; leaves are
//! distributed evenly by angle around the circle and each parent is placed at
//! the mean angle of its children. Deterministic.

const std = @import("std");
const geom = @import("../geom.zig");
const common = @import("common.zig");

const Vec2 = geom.Vec2;

pub const Opts = struct {
    root: usize = 0,
    ring_gap: f64 = 80,
    center: Vec2 = .{ .x = 0, .y = 0 },
};

const Assign = struct {
    angle: []f64,
    children: [][]usize,
    leaf_step: f64,
    next_leaf: f64 = 0,

    fn visit(self: *Assign, node: usize) void {
        const kids = self.children[node];
        if (kids.len == 0) {
            self.angle[node] = self.next_leaf * self.leaf_step;
            self.next_leaf += 1;
            return;
        }
        var sum: f64 = 0;
        for (kids) |c| {
            self.visit(c);
            sum += self.angle[c];
        }
        self.angle[node] = sum / @as(f64, @floatFromInt(kids.len));
    }
};

/// Compute a position per node. Caller owns the returned slice.
pub fn layout(alloc: std.mem.Allocator, n: usize, edges: []const common.Edge, opts: Opts) ![]Vec2 {
    const out = try alloc.alloc(Vec2, n);
    errdefer alloc.free(out);
    if (n == 0) return out;

    var h = try common.buildHierarchy(alloc, n, edges, opts.root);
    defer h.deinit();

    // Count leaves to spread angles over the full circle.
    var leaves: usize = 0;
    for (h.children) |c| {
        if (c.len == 0) leaves += 1;
    }
    const leaf_step = if (leaves == 0) 0 else (2.0 * std.math.pi) / @as(f64, @floatFromInt(leaves));

    const angle = try alloc.alloc(f64, n);
    defer alloc.free(angle);
    var asn = Assign{ .angle = angle, .children = h.children, .leaf_step = leaf_step };
    for (h.order) |node| {
        if (h.parent[node] == common.Hierarchy.no_parent) asn.visit(node);
    }

    for (0..n) |i| {
        const r = @as(f64, @floatFromInt(h.depth[i])) * opts.ring_gap;
        out[i] = .{
            .x = opts.center.x + r * @cos(angle[i]),
            .y = opts.center.y + r * @sin(angle[i]),
        };
    }
    return out;
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

test "root at center, children on first ring" {
    const edges = [_]common.Edge{ .{ 0, 1 }, .{ 0, 2 }, .{ 0, 3 } };
    const pos = try layout(testing.allocator, 4, &edges, .{ .ring_gap = 50, .center = .{ .x = 100, .y = 100 } });
    defer testing.allocator.free(pos);

    // Root is depth 0 → radius 0 → exactly at center.
    try testing.expectApproxEqAbs(@as(f64, 100), pos[0].x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 100), pos[0].y, 1e-9);
    // Three leaves all sit on the depth-1 ring at radius 50.
    for ([_]usize{ 1, 2, 3 }) |i| {
        const dx = pos[i].x - 100;
        const dy = pos[i].y - 100;
        try testing.expectApproxEqAbs(@as(f64, 50), @sqrt(dx * dx + dy * dy), 1e-9);
    }
}
