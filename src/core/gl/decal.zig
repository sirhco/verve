//! verve.gl decal — forward DecalGeometry projector (pure math, no GPU/wire/JS).
//!
//! A decal is an oriented box in world space. Every target triangle is clipped
//! against the box's 6 faces (Sutherland–Hodgman); surviving convex polygons are
//! UV-projected onto the box's xy face and fan-triangulated into a small decal
//! mesh that conforms to the surface. This mirrors three.js `DecalGeometry`.
//!
//! Allocation-free: the caller owns the output buffers and clipping happens in
//! fixed local scratch. Freestanding-safe (runs in a wasm island chunk).
//!
//! Output vertex layout — interleaved, stride 32 bytes (8 f32/vert):
//!   pos.xyz   @  0 (3 f32)
//!   normal.xyz@ 12 (3 f32)
//!   uv.xy     @ 24 (2 f32)
//! Indices are u16, fan-triangulated per surviving polygon.

const std = @import("std");
const math = @import("math.zig");
const Vec3 = math.Vec3;

/// Floats per output vertex (pos3 + normal3 + uv2). Stride = 32 bytes.
pub const floats_per_vert = 8;

/// Output caps. `out_verts` must hold >= max_decal_verts * floats_per_vert
/// floats; `out_indices` must hold >= max_decal_indices u16. When projection
/// would exceed a cap, projection stops and returns the counts written so far
/// (no panic, no OOB write). Demo decals stay well under these bounds.
pub const max_decal_verts = 1024;
pub const max_decal_indices = 2048;

/// Max vertices a single triangle (3 verts) can have after clipping against 6
/// planes: each convex-polygon/plane clip adds at most one vertex (3+6 = 9).
const max_poly = 9;

pub const DecalResult = struct { vert_count: u32, index_count: u32 };

/// Decode the orientation basis. `basis` is a row-major 3x3 whose columns are
/// the decal's right / up / forward (projection) axes.
const Basis = struct {
    right: Vec3,
    up: Vec3,
    forward: Vec3,

    fn fromArray(b: [9]f32) Basis {
        return .{
            // column 0 = right, column 1 = up, column 2 = forward
            .right = Vec3.init(b[0], b[3], b[6]),
            .up = Vec3.init(b[1], b[4], b[7]),
            .forward = Vec3.init(b[2], b[5], b[8]),
        };
    }
};

/// Project a decal onto target geometry. Writes interleaved vertices into
/// `out_verts` (8 f32/vert: pos.xyz, normal.xyz, uv.xy) and u16 indices into
/// `out_indices`. Returns the counts. Never allocates.
pub fn projectDecal(
    target_pos: []const f32, // N*3 world-space positions
    target_idx: []const u16, // M indices (triangles)
    center: [3]f32, // decal box center, world space
    basis: [9]f32, // decal orientation, 3x3 row-major (cols = right,up,forward)
    size: [3]f32, // decal box full extents (w,h,d) world units
    out_verts: []f32, // caller buffer >= max_decal_verts*8
    out_indices: []u16, // caller buffer >= max_decal_indices
) DecalResult {
    const b = Basis.fromArray(basis);
    const c = Vec3.init(center[0], center[1], center[2]);
    const half = Vec3.init(size[0] * 0.5, size[1] * 0.5, size[2] * 0.5);

    // Defensive bounds: never write past either the documented cap or the
    // actual buffer the caller handed us.
    const max_v: u32 = @intCast(@min(@as(usize, max_decal_verts), out_verts.len / floats_per_vert));
    const max_i: u32 = @intCast(@min(@as(usize, max_decal_indices), out_indices.len));

    var result = DecalResult{ .vert_count = 0, .index_count = 0 };

    // Two ping-pong scratch buffers for Sutherland–Hodgman clipping. Verts are
    // stored in decal-LOCAL space; the polygon normal is constant per triangle.
    var buf_a: [max_poly]Vec3 = undefined;
    var buf_b: [max_poly]Vec3 = undefined;

    var tri: usize = 0;
    while (tri + 3 <= target_idx.len) : (tri += 3) {
        const ia: usize = target_idx[tri];
        const ib: usize = target_idx[tri + 1];
        const ic: usize = target_idx[tri + 2];
        if (ia * 3 + 2 >= target_pos.len or ib * 3 + 2 >= target_pos.len or ic * 3 + 2 >= target_pos.len) continue;

        const p0 = Vec3.init(target_pos[ia * 3], target_pos[ia * 3 + 1], target_pos[ia * 3 + 2]);
        const p1 = Vec3.init(target_pos[ib * 3], target_pos[ib * 3 + 1], target_pos[ib * 3 + 2]);
        const p2 = Vec3.init(target_pos[ic * 3], target_pos[ic * 3 + 1], target_pos[ic * 3 + 2]);

        // Geometric normal (world). Skip degenerate (zero-area) triangles.
        const gn = p1.sub(p0).cross(p2.sub(p0));
        if (gn.length() == 0) continue;
        const n = gn.normalize();

        // Back-face cull: decals project only onto surfaces facing the decal's
        // forward axis (forward · triNormal > 0).
        if (b.forward.dot(n) <= 0) continue;

        // To decal-local space: local = basis^T * (world - center).
        var src = &buf_a;
        var dst = &buf_b;
        src[0] = toLocal(b, c, p0);
        src[1] = toLocal(b, c, p1);
        src[2] = toLocal(b, c, p2);
        var n_poly: usize = 3;

        // Clip against the 6 box planes. For axis a: inside means
        // -half[a] <= local[a] <= +half[a].
        inline for (.{ 0, 1, 2 }) |axis| {
            const lim = axisHalf(half, axis);
            // upper plane: keep local[axis] <= +lim  (d = lim - coord)
            n_poly = clipPlane(src[0..n_poly], dst, axis, lim, true);
            std.mem.swap(*[max_poly]Vec3, &src, &dst);
            if (n_poly < 3) break;
            // lower plane: keep local[axis] >= -lim  (d = coord + lim)
            n_poly = clipPlane(src[0..n_poly], dst, axis, lim, false);
            std.mem.swap(*[max_poly]Vec3, &src, &dst);
            if (n_poly < 3) break;
        }
        if (n_poly < 3) continue;

        // Emit. Cap-check: appending this polygon must not overflow either
        // buffer; if it would, stop and return what fits.
        const tris_added: u32 = @intCast(n_poly - 2);
        if (result.vert_count + n_poly > max_v) break;
        if (result.index_count + tris_added * 3 > max_i) break;

        const base = result.vert_count;
        var k: usize = 0;
        while (k < n_poly) : (k += 1) {
            const lp = src[k];
            const world = toWorld(b, c, lp);
            const o = (result.vert_count) * floats_per_vert;
            out_verts[o + 0] = world.x;
            out_verts[o + 1] = world.y;
            out_verts[o + 2] = world.z;
            out_verts[o + 3] = n.x;
            out_verts[o + 4] = n.y;
            out_verts[o + 5] = n.z;
            // UV: map the box xy face to [0,1]^2.
            out_verts[o + 6] = lp.x / size[0] + 0.5;
            out_verts[o + 7] = lp.y / size[1] + 0.5;
            result.vert_count += 1;
        }
        // Fan triangulation: (base, base+i, base+i+1).
        var t: u32 = 1;
        while (t + 1 < n_poly) : (t += 1) {
            out_indices[result.index_count + 0] = @intCast(base);
            out_indices[result.index_count + 1] = @intCast(base + t);
            out_indices[result.index_count + 2] = @intCast(base + t + 1);
            result.index_count += 3;
        }
    }

    return result;
}

fn axisHalf(half: Vec3, comptime axis: usize) f32 {
    return switch (axis) {
        0 => half.x,
        1 => half.y,
        2 => half.z,
        else => unreachable,
    };
}

fn axisCoord(v: Vec3, comptime axis: usize) f32 {
    return switch (axis) {
        0 => v.x,
        1 => v.y,
        2 => v.z,
        else => unreachable,
    };
}

fn toLocal(b: Basis, c: Vec3, world: Vec3) Vec3 {
    const d = world.sub(c);
    return Vec3.init(b.right.dot(d), b.up.dot(d), b.forward.dot(d));
}

fn toWorld(b: Basis, c: Vec3, local: Vec3) Vec3 {
    return c.add(b.right.scale(local.x)).add(b.up.scale(local.y)).add(b.forward.scale(local.z));
}

/// Clip convex polygon `in_poly` (decal-local) against one box plane along
/// `axis`. `upper` true keeps coord <= +lim, false keeps coord >= -lim.
/// Writes kept + intersection verts into `out` and returns the new count.
fn clipPlane(in_poly: []const Vec3, out: *[max_poly]Vec3, comptime axis: usize, lim: f32, comptime upper: bool) usize {
    const n = in_poly.len;
    if (n == 0) return 0;
    var count: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const cur = in_poly[i];
        const nxt = in_poly[(i + 1) % n];
        const dc = signedDist(cur, axis, lim, upper);
        const dn = signedDist(nxt, axis, lim, upper);
        const cur_in = dc >= 0;
        const nxt_in = dn >= 0;
        if (cur_in) {
            out[count] = cur;
            count += 1;
        }
        // Edge crosses the plane: insert the intersection point.
        if (cur_in != nxt_in) {
            const t = dc / (dc - dn);
            out[count] = cur.lerp(nxt, t);
            count += 1;
        }
    }
    return count;
}

/// Signed distance to a box plane; >= 0 means inside the half-space.
fn signedDist(p: Vec3, comptime axis: usize, lim: f32, comptime upper: bool) f32 {
    const coord = axisCoord(p, axis);
    return if (upper) lim - coord else coord + lim;
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------
const testing = std.testing;

// Identity basis: right=+X, up=+Y, forward=+Z (row-major 3x3 = identity).
const identity_basis = [9]f32{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };

test "golden: box fully inside one large +Z triangle yields the unit-square front face" {
    // One large triangle facing +Z at z=0, containing the [-0.5,0.5]^2 region.
    const pos = [_]f32{
        -2, -2, 0,
        2,  -2, 0,
        0,  3,  0,
    };
    const idx = [_]u16{ 0, 1, 2 };
    var verts: [max_decal_verts * floats_per_vert]f32 = undefined;
    var inds: [max_decal_indices]u16 = undefined;

    const r = projectDecal(&pos, &idx, .{ 0, 0, 0 }, identity_basis, .{ 1, 1, 2 }, &verts, &inds);

    // 4 unique verts forming the unit square, 6 indices (a quad → 2 tris).
    try testing.expectEqual(@as(u32, 4), r.vert_count);
    try testing.expectEqual(@as(u32, 6), r.index_count);

    // Frozen golden: positions (pos.xyz), normals, uvs per vertex.
    const eps = 1e-5;
    var seen_corner = [_]bool{ false, false, false, false }; // (-,-)(-,+)(+,+)(+,-)
    var v: usize = 0;
    while (v < r.vert_count) : (v += 1) {
        const o = v * floats_per_vert;
        const x = verts[o + 0];
        const y = verts[o + 1];
        const z = verts[o + 2];
        // All positions on the target plane z=0.
        try testing.expectApproxEqAbs(@as(f32, 0), z, eps);
        // Square corners at ±0.5.
        try testing.expectApproxEqAbs(@as(f32, 0.5), @abs(x), eps);
        try testing.expectApproxEqAbs(@as(f32, 0.5), @abs(y), eps);
        // Normal = +Z.
        try testing.expectApproxEqAbs(@as(f32, 0), verts[o + 3], eps);
        try testing.expectApproxEqAbs(@as(f32, 0), verts[o + 4], eps);
        try testing.expectApproxEqAbs(@as(f32, 1), verts[o + 5], eps);
        // UVs at the 4 corners ∈ {0,1}: uv = local.xy/size.xy + 0.5 = pos/1 + 0.5.
        const u = verts[o + 6];
        const vv = verts[o + 7];
        try testing.expectApproxEqAbs(x + 0.5, u, eps);
        try testing.expectApproxEqAbs(y + 0.5, vv, eps);
        try testing.expect((@abs(u) < eps or @abs(u - 1) < eps));
        try testing.expect((@abs(vv) < eps or @abs(vv - 1) < eps));
        // Tag the corner.
        const ci: usize = (if (x > 0) @as(usize, 2) else 0) + (if (y > 0) @as(usize, 1) else 0);
        seen_corner[ci] = true;
    }
    // All four distinct corners present.
    for (seen_corner) |s| try testing.expect(s);
}

test "uv bounds: arbitrary rotated decal over a dense target stays in [0,1]" {
    // Dense grid of triangles on the z=0 plane facing +Z.
    var pos: [11 * 11 * 3]f32 = undefined;
    {
        var gy: usize = 0;
        var n: usize = 0;
        while (gy < 11) : (gy += 1) {
            var gx: usize = 0;
            while (gx < 11) : (gx += 1) {
                pos[n] = @as(f32, @floatFromInt(gx)) * 0.4 - 2.0;
                pos[n + 1] = @as(f32, @floatFromInt(gy)) * 0.4 - 2.0;
                pos[n + 2] = 0;
                n += 3;
            }
        }
    }
    var idx_buf: [10 * 10 * 6]u16 = undefined;
    {
        var ny: usize = 0;
        var m: usize = 0;
        while (ny < 10) : (ny += 1) {
            var nx: usize = 0;
            while (nx < 10) : (nx += 1) {
                const a: u16 = @intCast(ny * 11 + nx);
                const bb: u16 = @intCast(ny * 11 + nx + 1);
                const cc: u16 = @intCast((ny + 1) * 11 + nx);
                const d: u16 = @intCast((ny + 1) * 11 + nx + 1);
                // CCW from +Z.
                idx_buf[m] = a;
                idx_buf[m + 1] = bb;
                idx_buf[m + 2] = cc;
                idx_buf[m + 3] = bb;
                idx_buf[m + 4] = d;
                idx_buf[m + 5] = cc;
                m += 6;
            }
        }
    }

    // Decal rotated 30° about Z so it is not axis-aligned, forward still +Z.
    const ang: f32 = 0.5235987756; // 30°
    const cs = @cos(ang);
    const sn = @sin(ang);
    const basis = [9]f32{
        cs, -sn, 0,
        sn, cs,  0,
        0,  0,   1,
    };
    var verts: [max_decal_verts * floats_per_vert]f32 = undefined;
    var inds: [max_decal_indices]u16 = undefined;
    const r = projectDecal(&pos, &idx_buf, .{ 0.1, -0.2, 0 }, basis, .{ 1.5, 0.8, 2 }, &verts, &inds);

    try testing.expect(r.vert_count > 0);
    const eps = 1e-4;
    var v: usize = 0;
    while (v < r.vert_count) : (v += 1) {
        const o = v * floats_per_vert;
        try testing.expect(verts[o + 6] >= -eps and verts[o + 6] <= 1 + eps);
        try testing.expect(verts[o + 7] >= -eps and verts[o + 7] <= 1 + eps);
    }
}

test "clipping: a triangle straddling a box plane gets verts ON the plane" {
    // Triangle extends in +X past the box bound x = +0.5 (size.x=1 → half=0.5).
    const pos = [_]f32{
        0,   -0.2, 0,
        1.0, -0.2, 0,
        0.5, 0.2,  0,
    };
    const idx = [_]u16{ 0, 1, 2 };
    var verts: [max_decal_verts * floats_per_vert]f32 = undefined;
    var inds: [max_decal_indices]u16 = undefined;
    const r = projectDecal(&pos, &idx, .{ 0, 0, 0 }, identity_basis, .{ 1, 1, 2 }, &verts, &inds);

    try testing.expect(r.vert_count >= 3);
    // With identity basis local.x == world.x. Some emitted vert must sit exactly
    // on the x = +0.5 clip plane.
    const eps = 1e-5;
    var on_plane = false;
    var max_x: f32 = -1e9;
    var v: usize = 0;
    while (v < r.vert_count) : (v += 1) {
        const x = verts[v * floats_per_vert];
        if (@abs(x - 0.5) < eps) on_plane = true;
        if (x > max_x) max_x = x;
    }
    try testing.expect(on_plane);
    // Nothing survived past the bound.
    try testing.expect(max_x <= 0.5 + eps);
}

test "back-face cull: a triangle facing away from forward emits nothing" {
    // Triangle wound CW from +Z → normal = -Z, opposite the decal forward (+Z).
    const pos = [_]f32{
        -2, -2, 0,
        0,  3,  0,
        2,  -2, 0,
    };
    const idx = [_]u16{ 0, 1, 2 };
    var verts: [max_decal_verts * floats_per_vert]f32 = undefined;
    var inds: [max_decal_indices]u16 = undefined;
    const r = projectDecal(&pos, &idx, .{ 0, 0, 0 }, identity_basis, .{ 1, 1, 2 }, &verts, &inds);
    try testing.expectEqual(@as(u32, 0), r.vert_count);
    try testing.expectEqual(@as(u32, 0), r.index_count);
}

test "cap safety: more geometry than the cap returns counts <= caps, no OOB" {
    // 500 small front-facing triangles fully inside the box → 1500 verts before
    // capping, well over max_decal_verts (1024).
    const tri_count = 500;
    var pos: [tri_count * 9]f32 = undefined;
    var idx_buf: [tri_count * 3]u16 = undefined;
    {
        var i: usize = 0;
        while (i < tri_count) : (i += 1) {
            const b = i * 9;
            // Tiny CCW (+Z) triangle inside [-0.4,0.4]^2 at z=0.
            pos[b + 0] = -0.1;
            pos[b + 1] = -0.1;
            pos[b + 2] = 0;
            pos[b + 3] = 0.1;
            pos[b + 4] = -0.1;
            pos[b + 5] = 0;
            pos[b + 6] = 0.0;
            pos[b + 7] = 0.1;
            pos[b + 8] = 0;
            idx_buf[i * 3 + 0] = @intCast(i * 3 + 0);
            idx_buf[i * 3 + 1] = @intCast(i * 3 + 1);
            idx_buf[i * 3 + 2] = @intCast(i * 3 + 2);
        }
    }
    // Buffers sized exactly to the caps — any OOB write would corrupt/trap.
    var verts: [max_decal_verts * floats_per_vert]f32 = undefined;
    var inds: [max_decal_indices]u16 = undefined;
    const r = projectDecal(&pos, &idx_buf, .{ 0, 0, 0 }, identity_basis, .{ 1, 1, 2 }, &verts, &inds);
    try testing.expect(r.vert_count <= max_decal_verts);
    try testing.expect(r.index_count <= max_decal_indices);
    // It must have stopped at the cap (each tri = 3 verts, 1024/3 = 341 tris).
    try testing.expect(r.vert_count > max_decal_verts - 3);
}
