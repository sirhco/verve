//! verve.gl per-mesh BVH — build-time builder + freestanding raycast walk.
//!
//! Same dual-target pattern as `vmesh.zig`: `build` is native-only (allocates,
//! sorts a triangle permutation); `walk`, `nodesFromBytes`, `triPermFromBytes`
//! are freestanding-safe (no alloc, fixed stack). Task 4 serializes the FROZEN
//! 32-byte node format below into the .vmesh container.
//!
//! ## Node format (FROZEN, 32 bytes, little-endian)
//!   aabb_min  f32×3 @0
//!   aabb_max  f32×3 @12
//!   left_or_first u32 @24:
//!     interior → index of LEFT child node (right child = left + 1, contiguous)
//!     leaf     → first index into `tri_perm`
//!   count     u32 @28:
//!     0  → interior node
//!     >0 → leaf node, triangle count (slice tri_perm[first .. first+count])
//!
//! `tri_perm` is a permutation of [0, tri_count): a leaf's triangles are
//! `tri_perm[first .. first+count]`, each entry an ORIGINAL triangle index
//! (the index into the source `indices` array, ÷3).
//!
//! ## Build algorithm
//! Median split on the longest axis of the triangle-centroid AABB. Children are
//! reserved contiguously (left, then left+1) so the right child is always
//! left+1. Recursion stops at `leaf_max_tris` triangles or `max_depth`.
//!
//! ## Walk algorithm
//! Slab-method ray/AABB with an explicit `[max_depth]u32` stack. Interior nodes
//! whose entry distance is ≥ the current best hit `t` are pruned. Leaves test
//! every triangle with Möller–Trumbore (`ray.intersectTriangle`); the nearest
//! hit wins. `Hit.point = origin + dir·t`.
//!
//! ## Byte views (consumed by Task 4 / vmesh)
//! `nodesFromBytes` / `triPermFromBytes` are zero-copy reinterprets. The .vmesh
//! layout places the BVH section 16-aligned, so `Node` (4-byte aligned, 32-byte
//! size) and `u32` views are correctly aligned for `@alignCast`.

const std = @import("std");
const math = @import("math.zig");
const ray = @import("ray.zig");

// ── Frozen node format ───────────────────────────────────────────────────────

pub const Node = extern struct {
    aabb_min: [3]f32, // @0
    aabb_max: [3]f32, // @12
    left_or_first: u32, // @24
    count: u32, // @28
};

pub const node_size: u32 = 32;
pub const max_depth: u32 = 64;
pub const leaf_max_tris: u32 = 4;

comptime {
    std.debug.assert(@sizeOf(Node) == node_size);
}

// ── Build (native-only) ──────────────────────────────────────────────────────

pub const BuildResult = struct {
    nodes: []Node,
    tri_perm: []u32,

    pub fn deinit(self: *BuildResult, alloc: std.mem.Allocator) void {
        alloc.free(self.nodes);
        alloc.free(self.tri_perm);
        self.* = undefined;
    }
};

/// Fetch a triangle's three world-space vertices. `positions` holds vertex
/// floats with position xyz at offset 0 of each `stride_f32` group
/// (stride 3 = tightly packed; stride 12 = vmesh interleave). `indices` are
/// u16 triples; `tri` is an ORIGINAL triangle index.
fn triVerts(
    positions: []const f32,
    stride_f32: u32,
    indices: []const u16,
    tri: u32,
) [3]math.Vec3 {
    const base = tri * 3;
    var out: [3]math.Vec3 = undefined;
    inline for (0..3) |k| {
        const vi: usize = indices[base + k];
        const off = vi * stride_f32;
        out[k] = math.Vec3.init(
            positions[off + 0],
            positions[off + 1],
            positions[off + 2],
        );
    }
    return out;
}

fn triCentroid(
    positions: []const f32,
    stride_f32: u32,
    indices: []const u16,
    tri: u32,
) math.Vec3 {
    const v = triVerts(positions, stride_f32, indices, tri);
    return v[0].add(v[1]).add(v[2]).scale(1.0 / 3.0);
}

const Aabb = struct {
    min: math.Vec3,
    max: math.Vec3,

    fn empty() Aabb {
        const inf = std.math.inf(f32);
        return .{
            .min = math.Vec3.init(inf, inf, inf),
            .max = math.Vec3.init(-inf, -inf, -inf),
        };
    }

    fn expand(self: *Aabb, p: math.Vec3) void {
        self.min = math.Vec3.init(
            @min(self.min.x, p.x),
            @min(self.min.y, p.y),
            @min(self.min.z, p.z),
        );
        self.max = math.Vec3.init(
            @max(self.max.x, p.x),
            @max(self.max.y, p.y),
            @max(self.max.z, p.z),
        );
    }

    fn axisExtent(self: Aabb, axis: u2) f32 {
        return switch (axis) {
            0 => self.max.x - self.min.x,
            1 => self.max.y - self.min.y,
            else => self.max.z - self.min.z,
        };
    }
};

fn vecAxis(v: math.Vec3, axis: u2) f32 {
    return switch (axis) {
        0 => v.x,
        1 => v.y,
        else => v.z,
    };
}

const Builder = struct {
    alloc: std.mem.Allocator,
    positions: []const f32,
    stride_f32: u32,
    indices: []const u16,
    perm: []u32,
    nodes: std.ArrayListUnmanaged(Node),

    /// Triangle AABB over perm[first .. first+count].
    fn triRangeAabb(self: *Builder, first: u32, count: u32) Aabb {
        var box = Aabb.empty();
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const v = triVerts(self.positions, self.stride_f32, self.indices, self.perm[first + i]);
            box.expand(v[0]);
            box.expand(v[1]);
            box.expand(v[2]);
        }
        return box;
    }

    /// Centroid AABB over perm[first .. first+count].
    fn centroidAabb(self: *Builder, first: u32, count: u32) Aabb {
        var box = Aabb.empty();
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            box.expand(triCentroid(self.positions, self.stride_f32, self.indices, self.perm[first + i]));
        }
        return box;
    }

    /// Recursively fill the PRE-RESERVED slot `node_index` with the subtree for
    /// perm[first .. first+count]. Children are reserved contiguously so the
    /// right child is always (left child index) + 1.
    fn buildNodeAt(self: *Builder, node_index: u32, first: u32, count: u32, depth: u32) !void {
        std.debug.assert(depth <= max_depth);

        const tri_box = self.triRangeAabb(first, count);

        // Leaf: small enough, or we hit the depth cap.
        if (count <= leaf_max_tris or depth == max_depth) {
            self.nodes.items[node_index] = .{
                .aabb_min = .{ tri_box.min.x, tri_box.min.y, tri_box.min.z },
                .aabb_max = .{ tri_box.max.x, tri_box.max.y, tri_box.max.z },
                .left_or_first = first,
                .count = count,
            };
            return;
        }

        // Choose the longest axis of the centroid bounds.
        const cbox = self.centroidAabb(first, count);
        var axis: u2 = 0;
        if (cbox.axisExtent(1) > cbox.axisExtent(axis)) axis = 1;
        if (cbox.axisExtent(2) > cbox.axisExtent(axis)) axis = 2;

        // Degenerate centroid spread (all centroids coincide on every axis):
        // can't split meaningfully → make a leaf even if count > leaf_max_tris.
        if (cbox.axisExtent(axis) == 0) {
            self.nodes.items[node_index] = .{
                .aabb_min = .{ tri_box.min.x, tri_box.min.y, tri_box.min.z },
                .aabb_max = .{ tri_box.max.x, tri_box.max.y, tri_box.max.z },
                .left_or_first = first,
                .count = count,
            };
            return;
        }

        // Median split: sort perm[first..first+count] by centroid on `axis`.
        const SortCtx = struct {
            positions: []const f32,
            stride_f32: u32,
            indices: []const u16,
            axis: u2,
            fn lessThan(ctx: @This(), a: u32, b: u32) bool {
                const ca = triCentroid(ctx.positions, ctx.stride_f32, ctx.indices, a);
                const cb = triCentroid(ctx.positions, ctx.stride_f32, ctx.indices, b);
                return vecAxis(ca, ctx.axis) < vecAxis(cb, ctx.axis);
            }
        };
        std.sort.pdq(u32, self.perm[first .. first + count], SortCtx{
            .positions = self.positions,
            .stride_f32 = self.stride_f32,
            .indices = self.indices,
            .axis = axis,
        }, SortCtx.lessThan);

        const left_count = count / 2; // ≥1 (count > leaf_max_tris ≥ 1)
        const right_count = count - left_count;

        // Reserve BOTH child slots contiguously up front so the right child is
        // always left_index + 1, independent of subtree sizes.
        const left_index: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.alloc, undefined);
        try self.nodes.append(self.alloc, undefined);

        try self.buildNodeAt(left_index, first, left_count, depth + 1);
        try self.buildNodeAt(left_index + 1, first + left_count, right_count, depth + 1);

        self.nodes.items[node_index] = .{
            .aabb_min = .{ tri_box.min.x, tri_box.min.y, tri_box.min.z },
            .aabb_max = .{ tri_box.max.x, tri_box.max.y, tri_box.max.z },
            .left_or_first = left_index,
            .count = 0, // interior
        };
    }
};

/// Build a BVH over the mesh's triangles. Native-only (allocates, sorts).
/// `positions`: vertex floats, position xyz at offset 0 of each `stride_f32`
/// group. `indices`: u16 triples. Caller owns the returned `BuildResult`
/// (call `deinit`).
pub fn build(
    alloc: std.mem.Allocator,
    positions: []const f32,
    stride_f32: u32,
    indices: []const u16,
) !BuildResult {
    std.debug.assert(stride_f32 >= 3);
    std.debug.assert(indices.len % 3 == 0);
    const tri_count: u32 = @intCast(indices.len / 3);

    const perm = try alloc.alloc(u32, tri_count);
    errdefer alloc.free(perm);
    for (perm, 0..) |*p, i| p.* = @intCast(i);

    var builder = Builder{
        .alloc = alloc,
        .positions = positions,
        .stride_f32 = stride_f32,
        .indices = indices,
        .perm = perm,
        .nodes = .empty,
    };
    errdefer builder.nodes.deinit(alloc);

    if (tri_count == 0) {
        // Empty mesh: single empty leaf so `walk` always has a root.
        try builder.nodes.append(alloc, .{
            .aabb_min = .{ 0, 0, 0 },
            .aabb_max = .{ 0, 0, 0 },
            .left_or_first = 0,
            .count = 0,
        });
    } else {
        try builder.nodes.append(alloc, undefined); // reserve root slot 0
        try builder.buildNodeAt(0, 0, tri_count, 0);
    }

    const nodes = try builder.nodes.toOwnedSlice(alloc);
    return .{ .nodes = nodes, .tri_perm = perm };
}

// ── Walk (freestanding) ──────────────────────────────────────────────────────

pub const Hit = struct {
    tri_index: u32,
    t: f32,
    point: math.Vec3,
};

/// Slab-method ray/AABB. Returns the near entry distance (clamped to ≥0 so an
/// origin inside the box returns 0), or null on miss. Handles dir component 0
/// via IEEE inf semantics; rejects NaN.
fn rayAabb(r: ray.Ray, lo: [3]f32, hi: [3]f32) ?f32 {
    const o = [3]f32{ r.origin.x, r.origin.y, r.origin.z };
    const d = [3]f32{ r.dir.x, r.dir.y, r.dir.z };

    var tmin: f32 = -std.math.inf(f32);
    var tmax: f32 = std.math.inf(f32);

    inline for (0..3) |i| {
        const inv = 1.0 / d[i]; // ±inf when d[i] == 0
        var t1 = (lo[i] - o[i]) * inv;
        var t2 = (hi[i] - o[i]) * inv;
        if (t1 > t2) {
            const tmp = t1;
            t1 = t2;
            t2 = tmp;
        }
        // 0*inf → NaN when origin sits exactly on a slab plane and dir‖slab;
        // @max/@min with NaN here would poison the interval, so guard it.
        if (!std.math.isNan(t1)) tmin = @max(tmin, t1);
        if (!std.math.isNan(t2)) tmax = @min(tmax, t2);
    }

    if (std.math.isNan(tmin) or std.math.isNan(tmax)) return null;
    if (tmin > tmax) return null;
    if (tmax < 0) return null; // box entirely behind the origin
    return @max(tmin, 0);
}

/// Walk the BVH for the nearest triangle hit along `r`. Freestanding: no alloc,
/// fixed `[max_depth]u32` traversal stack. `tri_index` in the result is the
/// ORIGINAL triangle index. Returns null on miss.
pub fn walk(
    nodes: []const Node,
    tri_perm: []const u32,
    positions: []const f32,
    stride_f32: u32,
    indices: []const u16,
    r: ray.Ray,
) ?Hit {
    if (nodes.len == 0) return null;

    // A node-cap of `max_depth` means leaves sit at most at tree depth
    // `max_depth`, so the leftmost-path DFS peak is `max_depth + 1` entries
    // (each interior pop nets +1: pushes two children, one already popped).
    var stack: [max_depth + 1]u32 = undefined;
    var sp: usize = 0;
    stack[sp] = 0;
    sp += 1;

    var best_t: f32 = std.math.inf(f32);
    var best_tri: u32 = undefined;
    var found = false;

    while (sp > 0) {
        sp -= 1;
        const ni = stack[sp];
        const node = nodes[ni];

        const enter = rayAabb(r, node.aabb_min, node.aabb_max) orelse continue;
        if (enter >= best_t) continue; // whole subtree is farther than best hit

        if (node.count > 0) {
            // Leaf: test each triangle.
            var i: u32 = 0;
            while (i < node.count) : (i += 1) {
                const tri = tri_perm[node.left_or_first + i];
                const v = triVerts(positions, stride_f32, indices, tri);
                if (ray.intersectTriangle(r, v[0], v[1], v[2])) |t| {
                    if (t < best_t) {
                        best_t = t;
                        best_tri = tri;
                        found = true;
                    }
                }
            }
        } else {
            // Interior: push both children (stack sized max_depth+1).
            const left = node.left_or_first;
            std.debug.assert(sp + 2 <= stack.len);
            stack[sp] = left;
            sp += 1;
            stack[sp] = left + 1;
            sp += 1;
        }
    }

    if (!found) return null;
    return .{
        .tri_index = best_tri,
        .t = best_t,
        .point = r.origin.add(r.dir.scale(best_t)),
    };
}

// ── Byte views (vmesh-provided sections, 16-aligned per vmesh layout) ─────────

/// Reinterpret a byte slice as a `Node` view. The slice must hold a whole
/// number of nodes and be 16-aligned (vmesh BVH section alignment guarantees
/// `Node`'s 4-byte requirement). Trailing bytes < node_size are ignored.
pub fn nodesFromBytes(bytes: []const u8) []const Node {
    const n = bytes.len / node_size;
    const ptr: [*]const Node = @ptrCast(@alignCast(bytes.ptr));
    return ptr[0..n];
}

/// Reinterpret a byte slice as a `u32` tri_perm view. Slice must be 4-aligned
/// (guaranteed by the 16-aligned vmesh section). Trailing bytes < 4 ignored.
pub fn triPermFromBytes(bytes: []const u8) []const u32 {
    const n = bytes.len / 4;
    const ptr: [*]const u32 = @ptrCast(@alignCast(bytes.ptr));
    return ptr[0..n];
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const eps5: f32 = 1e-5;

/// A unit quad in z=0: verts (0,0)(1,0)(1,1)(0,1); two tris (0,1,2),(0,2,3).
const quad_pos_s3 = [_]f32{
    0, 0, 0,
    1, 0, 0,
    1, 1, 0,
    0, 1, 0,
};
const quad_idx = [_]u16{ 0, 1, 2, 0, 2, 3 };

test "(a) 2-tri quad → root leaf, count==2, exact AABB" {
    var res = try build(testing.allocator, &quad_pos_s3, 3, &quad_idx);
    defer res.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), res.nodes.len);
    const root = res.nodes[0];
    try testing.expectEqual(@as(u32, 2), root.count);
    try testing.expectEqual(@as(u32, 0), root.left_or_first);
    try testing.expectEqual(@as(usize, 2), res.tri_perm.len);

    try testing.expectApproxEqAbs(@as(f32, 0), root.aabb_min[0], eps5);
    try testing.expectApproxEqAbs(@as(f32, 0), root.aabb_min[1], eps5);
    try testing.expectApproxEqAbs(@as(f32, 0), root.aabb_min[2], eps5);
    try testing.expectApproxEqAbs(@as(f32, 1), root.aabb_max[0], eps5);
    try testing.expectApproxEqAbs(@as(f32, 1), root.aabb_max[1], eps5);
    try testing.expectApproxEqAbs(@as(f32, 0), root.aabb_max[2], eps5);
}

/// Build an n×n grid of cells in z=0 spanning [0,n]×[0,n]. Each cell (cx,cy)
/// has corners and is split into two triangles:
///   lower tri = (bl, br, tr), upper tri = (bl, tr, tl)
/// Triangle index = (cy*n + cx)*2 + {0 lower, 1 upper}.
/// Returns positions (stride 3) and indices, both heap-owned.
fn buildGrid(alloc: std.mem.Allocator, n: u32) !struct { pos: []f32, idx: []u16 } {
    const vside = n + 1;
    const pos = try alloc.alloc(f32, @as(usize, vside) * vside * 3);
    var vy: u32 = 0;
    while (vy < vside) : (vy += 1) {
        var vx: u32 = 0;
        while (vx < vside) : (vx += 1) {
            const vi = (vy * vside + vx) * 3;
            pos[vi + 0] = @floatFromInt(vx);
            pos[vi + 1] = @floatFromInt(vy);
            pos[vi + 2] = 0;
        }
    }
    const idx = try alloc.alloc(u16, @as(usize, n) * n * 6);
    var cy: u32 = 0;
    while (cy < n) : (cy += 1) {
        var cx: u32 = 0;
        while (cx < n) : (cx += 1) {
            const bl: u16 = @intCast(cy * vside + cx);
            const br: u16 = @intCast(cy * vside + cx + 1);
            const tl: u16 = @intCast((cy + 1) * vside + cx);
            const tr: u16 = @intCast((cy + 1) * vside + cx + 1);
            const ci = (cy * n + cx) * 6;
            idx[ci + 0] = bl;
            idx[ci + 1] = br;
            idx[ci + 2] = tr; // lower tri
            idx[ci + 3] = bl;
            idx[ci + 4] = tr;
            idx[ci + 5] = tl; // upper tri
        }
    }
    return .{ .pos = pos, .idx = idx };
}

test "(b) 8×8 grid: interior count==0, children in range, depth & perm" {
    const n: u32 = 8;
    const grid = try buildGrid(testing.allocator, n);
    defer testing.allocator.free(grid.pos);
    defer testing.allocator.free(grid.idx);

    var res = try build(testing.allocator, grid.pos, 3, grid.idx);
    defer res.deinit(testing.allocator);

    const tri_count: u32 = @intCast(grid.idx.len / 3); // 128
    try testing.expectEqual(@as(u32, 128), tri_count);

    // Interior nodes: count==0 and both children indices in range.
    for (res.nodes) |node| {
        if (node.count == 0) {
            try testing.expect(node.left_or_first < res.nodes.len);
            try testing.expect(node.left_or_first + 1 < res.nodes.len);
        }
    }

    // Observed depth ≤ ⌈log2 128⌉ + 8 = 7 + 8 = 15. Measure via re-walk of tree.
    const observed = treeDepth(res.nodes, 0, 0);
    const cap = std.math.log2_int_ceil(u32, tri_count) + 8;
    try testing.expect(observed <= cap);

    // Every triangle index appears EXACTLY once in tri_perm.
    const seen = try testing.allocator.alloc(bool, tri_count);
    defer testing.allocator.free(seen);
    @memset(seen, false);
    try testing.expectEqual(@as(usize, tri_count), res.tri_perm.len);
    for (res.tri_perm) |t| {
        try testing.expect(t < tri_count);
        try testing.expect(!seen[t]); // not seen before
        seen[t] = true;
    }
    for (seen) |s| try testing.expect(s);
}

fn treeDepth(nodes: []const Node, ni: u32, depth: u32) u32 {
    const node = nodes[ni];
    if (node.count > 0) return depth;
    const l = treeDepth(nodes, node.left_or_first, depth + 1);
    const r = treeDepth(nodes, node.left_or_first + 1, depth + 1);
    return @max(l, r);
}

test "(c) nearest hit: z=2 tri beats z=0 tri, t==3" {
    // Two single tris: one at z=2 (tri 0), one at z=0 (tri 1). Ray from
    // (0.25,0.25,5) straight down −Z. Hits z=2 first at t = 5-2 = 3.
    const pos = [_]f32{
        // tri 0 @ z=2
        0, 0, 2,
        1, 0, 2,
        0, 1, 2,
        // tri 1 @ z=0
        0, 0, 0,
        1, 0, 0,
        0, 1, 0,
    };
    const idx = [_]u16{ 0, 1, 2, 3, 4, 5 };
    var res = try build(testing.allocator, &pos, 3, &idx);
    defer res.deinit(testing.allocator);

    const r = ray.Ray{
        .origin = math.Vec3.init(0.25, 0.25, 5),
        .dir = math.Vec3.init(0, 0, -1),
    };
    const hit = walk(res.nodes, res.tri_perm, &pos, 3, &idx, r) orelse return error.NoHit;
    try testing.expectEqual(@as(u32, 0), hit.tri_index);
    try testing.expectApproxEqAbs(@as(f32, 3), hit.t, eps5);
    try testing.expectApproxEqAbs(@as(f32, 0.25), hit.point.x, eps5);
    try testing.expectApproxEqAbs(@as(f32, 0.25), hit.point.y, eps5);
    try testing.expectApproxEqAbs(@as(f32, 2), hit.point.z, eps5);
}

test "(d) miss → null" {
    var res = try build(testing.allocator, &quad_pos_s3, 3, &quad_idx);
    defer res.deinit(testing.allocator);
    // Ray well outside the quad, pointing away.
    const r = ray.Ray{
        .origin = math.Vec3.init(10, 10, 5),
        .dir = math.Vec3.init(0, 0, -1),
    };
    try testing.expect(walk(res.nodes, res.tri_perm, &quad_pos_s3, 3, &quad_idx, r) == null);
}

test "(e) 1-tri degenerate: root leaf, walk hits" {
    const pos = [_]f32{
        -1, -1, 0,
        1,  -1, 0,
        0,  1,  0,
    };
    const idx = [_]u16{ 0, 1, 2 };
    var res = try build(testing.allocator, &pos, 3, &idx);
    defer res.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), res.nodes.len);
    try testing.expectEqual(@as(u32, 1), res.nodes[0].count);

    const r = ray.Ray{
        .origin = math.Vec3.init(0, 0, 5),
        .dir = math.Vec3.init(0, 0, -1),
    };
    const hit = walk(res.nodes, res.tri_perm, &pos, 3, &idx, r) orelse return error.NoHit;
    try testing.expectEqual(@as(u32, 0), hit.tri_index);
    try testing.expectApproxEqAbs(@as(f32, 5), hit.t, eps5);
}

test "(f) grid: ray through chosen cell center hits expected tri" {
    // 8×8 grid, [0,8]². Pick cell (cx=3, cy=5). Aim at the LOWER triangle's
    // interior. Lower tri of a cell = (bl, br, tr) = corners
    //   bl=(3,5), br=(4,5), tr=(4,6). Its centroid = ((3+4+4)/3,(5+5+6)/3)
    //   = (3.6667, 5.3333) — inside the lower tri (below the bl→tr diagonal
    //   y - 5 = (x - 3), i.e. y-5 < x-3 ⇒ 0.3333 < 0.6667 ✓ lower).
    // Expected tri index = (cy*n + cx)*2 + 0 = (5*8 + 3)*2 = 86.
    const n: u32 = 8;
    const grid = try buildGrid(testing.allocator, n);
    defer testing.allocator.free(grid.pos);
    defer testing.allocator.free(grid.idx);

    var res = try build(testing.allocator, grid.pos, 3, grid.idx);
    defer res.deinit(testing.allocator);

    const r = ray.Ray{
        .origin = math.Vec3.init(3.0 + 2.0 / 3.0, 5.0 + 1.0 / 3.0, 5),
        .dir = math.Vec3.init(0, 0, -1),
    };
    const hit = walk(res.nodes, res.tri_perm, grid.pos, 3, grid.idx, r) orelse return error.NoHit;
    try testing.expectEqual(@as(u32, 86), hit.tri_index);
    try testing.expectApproxEqAbs(@as(f32, 5), hit.t, eps5);
}

test "(g) bytes round-trip: views feed walk identically to (c)" {
    const pos = [_]f32{
        0, 0, 2,
        1, 0, 2,
        0, 1, 2,
        0, 0, 0,
        1, 0, 0,
        0, 1, 0,
    };
    const idx = [_]u16{ 0, 1, 2, 3, 4, 5 };
    var res = try build(testing.allocator, &pos, 3, &idx);
    defer res.deinit(testing.allocator);

    const node_bytes = std.mem.sliceAsBytes(res.nodes);
    const perm_bytes = std.mem.sliceAsBytes(res.tri_perm);
    const nodes_view = nodesFromBytes(node_bytes);
    const perm_view = triPermFromBytes(perm_bytes);

    try testing.expectEqual(res.nodes.len, nodes_view.len);
    try testing.expectEqual(res.tri_perm.len, perm_view.len);

    const r = ray.Ray{
        .origin = math.Vec3.init(0.25, 0.25, 5),
        .dir = math.Vec3.init(0, 0, -1),
    };
    const hit = walk(nodes_view, perm_view, &pos, 3, &idx, r) orelse return error.NoHit;
    try testing.expectEqual(@as(u32, 0), hit.tri_index);
    try testing.expectApproxEqAbs(@as(f32, 3), hit.t, eps5);
}

test "(h) stride 12 parity: same quad, pos@0 + garbage padding" {
    // Quad verts at stride 12 (vmesh interleave): pos@0, junk in [3..12).
    var pos12 = [_]f32{
        0, 0, 0, 9, 9, 9, 9, 9, 9, 9, 9, 9,
        1, 0, 0, 8, 8, 8, 8, 8, 8, 8, 8, 8,
        1, 1, 0, 7, 7, 7, 7, 7, 7, 7, 7, 7,
        0, 1, 0, 6, 6, 6, 6, 6, 6, 6, 6, 6,
    };

    var res3 = try build(testing.allocator, &quad_pos_s3, 3, &quad_idx);
    defer res3.deinit(testing.allocator);
    var res12 = try build(testing.allocator, &pos12, 12, &quad_idx);
    defer res12.deinit(testing.allocator);

    const r = ray.Ray{
        .origin = math.Vec3.init(0.3, 0.3, 5),
        .dir = math.Vec3.init(0, 0, -1),
    };
    const h3 = walk(res3.nodes, res3.tri_perm, &quad_pos_s3, 3, &quad_idx, r) orelse return error.NoHit;
    const h12 = walk(res12.nodes, res12.tri_perm, &pos12, 12, &quad_idx, r) orelse return error.NoHit;

    try testing.expectEqual(h3.tri_index, h12.tri_index);
    try testing.expectApproxEqAbs(h3.t, h12.t, eps5);
    try testing.expectApproxEqAbs(h3.point.x, h12.point.x, eps5);
    try testing.expectApproxEqAbs(h3.point.y, h12.point.y, eps5);
    try testing.expectApproxEqAbs(h3.point.z, h12.point.z, eps5);
}
