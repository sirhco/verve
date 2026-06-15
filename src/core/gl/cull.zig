//! verve.gl frustum culling — CPU-side, freestanding-safe (no allocator).
//! Conservative per-object visibility: an AABB is kept unless it lies fully
//! outside the view frustum. Reuses `math.zig` (column-major Mat4, RH camera,
//! WebGL clip space z in [-1, 1]). This module is invisible to the wire
//! contract — it only suppresses draw records the encoder would otherwise emit.

const std = @import("std");
const math = @import("math.zig");

/// Axis-aligned bounding box. `min`/`max` are component-wise extremes.
pub const Aabb = struct {
    min: math.Vec3,
    max: math.Vec3,
};

/// A plane in the form `n·p + d`. A point is inside (in front of) the plane
/// when `n·p + d >= 0`. `n` is unit length after `frustumPlanes` normalizes.
pub const Plane = struct {
    n: math.Vec3,
    d: f32,
};

/// Row `r` of a column-major matrix as homogeneous coefficients
/// (a, b, c, d) = (m[r], m[4+r], m[8+r], m[12+r]).
fn row(m: [16]f32, r: usize) [4]f32 {
    return .{ m[r], m[4 + r], m[8 + r], m[12 + r] };
}

/// Combine two matrix rows (`row3 + sign*rowN`) into a normalized plane.
fn planeFrom(r3: [4]f32, rn: [4]f32, sign: f32) Plane {
    const a = r3[0] + sign * rn[0];
    const b = r3[1] + sign * rn[1];
    const c = r3[2] + sign * rn[2];
    const d = r3[3] + sign * rn[3];
    var n = math.Vec3.init(a, b, c);
    const len = n.length();
    const inv: f32 = if (len == 0) 0 else 1.0 / len;
    n = n.scale(inv);
    return .{ .n = n, .d = d * inv };
}

/// Extract the 6 frustum planes from a `proj * view` matrix
/// (Gribb–Hartmann). Inward-facing, normalized. Order:
/// left, right, bottom, top, near, far. Near uses `row3 + row2`
/// (WebGL clip convention, z in [-1, 1]).
pub fn frustumPlanes(pv: math.Mat4) [6]Plane {
    const r0 = row(pv.m, 0);
    const r1 = row(pv.m, 1);
    const r2 = row(pv.m, 2);
    const r3 = row(pv.m, 3);
    return .{
        planeFrom(r3, r0, 1), // left:   x >= -w
        planeFrom(r3, r0, -1), // right:  x <=  w
        planeFrom(r3, r1, 1), // bottom: y >= -w
        planeFrom(r3, r1, -1), // top:    y <=  w
        planeFrom(r3, r2, 1), // near:   z >= -w
        planeFrom(r3, r2, -1), // far:    z <=  w
    };
}

/// Enclosing world-space AABB of a local AABB transformed by `world`.
/// Transforms all 8 corners (rotation-safe) and takes the extremes.
pub fn worldAabb(local: Aabb, world: math.Mat4) Aabb {
    var min = math.Vec3.init(
        std.math.inf(f32),
        std.math.inf(f32),
        std.math.inf(f32),
    );
    var max = math.Vec3.init(
        -std.math.inf(f32),
        -std.math.inf(f32),
        -std.math.inf(f32),
    );
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const corner = math.Vec3.init(
            if (i & 1 == 0) local.min.x else local.max.x,
            if (i & 2 == 0) local.min.y else local.max.y,
            if (i & 4 == 0) local.min.z else local.max.z,
        );
        const w = math.transformPoint(world, corner);
        min = math.Vec3.init(@min(min.x, w.x), @min(min.y, w.y), @min(min.z, w.z));
        max = math.Vec3.init(@max(max.x, w.x), @max(max.y, w.y), @max(max.z, w.z));
    }
    return .{ .min = min, .max = max };
}

/// True if `a` is at least partially inside the frustum. Conservative
/// positive-vertex (n-vertex) test: for each plane pick the AABB corner
/// farthest along the plane normal; if that corner is behind the plane the
/// box is fully outside. May keep some boxes that are outside (a corner of
/// the box is inside every plane's half-space yet the box misses the frustum
/// near edges), but never culls a visible box.
pub fn aabbInFrustum(planes: [6]Plane, a: Aabb) bool {
    for (planes) |p| {
        const px = if (p.n.x >= 0) a.max.x else a.min.x;
        const py = if (p.n.y >= 0) a.max.y else a.min.y;
        const pz = if (p.n.z >= 0) a.max.z else a.min.z;
        if (p.n.x * px + p.n.y * py + p.n.z * pz + p.d < 0) return false;
    }
    return true;
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const eps = 1e-4;

fn unitBoxAt(cx: f32, cy: f32, cz: f32, half: f32) Aabb {
    return .{
        .min = math.Vec3.init(cx - half, cy - half, cz - half),
        .max = math.Vec3.init(cx + half, cy + half, cz + half),
    };
}

test "golden: frustum planes are unit-normalized and inward-facing" {
    // Camera at +z=5 looking at origin, RH, 90° vertical FOV, square aspect.
    const proj = math.Mat4.perspective(std.math.pi / 2.0, 1.0, 0.1, 100.0);
    const view = math.Mat4.lookAt(
        math.Vec3.init(0, 0, 5),
        math.Vec3.init(0, 0, 0),
        math.Vec3.init(0, 1, 0),
    );
    const planes = frustumPlanes(proj.mul(view));

    // All plane normals are unit length.
    for (planes) |p| try testing.expectApproxEqAbs(@as(f32, 1), p.n.length(), eps);

    // Camera looks down -Z, so the near plane's inward normal is ≈ (0,0,-1)
    // and the far plane's is ≈ (0,0,+1).
    try testing.expectApproxEqAbs(@as(f32, -1), planes[4].n.z, eps);
    try testing.expectApproxEqAbs(@as(f32, 1), planes[5].n.z, eps);
}

test "aabbInFrustum: origin in, behind-camera out, off-axis out" {
    const proj = math.Mat4.perspective(std.math.pi / 2.0, 1.0, 0.1, 100.0);
    const view = math.Mat4.lookAt(
        math.Vec3.init(0, 0, 5),
        math.Vec3.init(0, 0, 0),
        math.Vec3.init(0, 1, 0),
    );
    const planes = frustumPlanes(proj.mul(view));

    try testing.expect(aabbInFrustum(planes, unitBoxAt(0, 0, 0, 0.5))); // centered
    try testing.expect(!aabbInFrustum(planes, unitBoxAt(0, 0, 20, 0.5))); // behind camera
    try testing.expect(!aabbInFrustum(planes, unitBoxAt(100, 0, 0, 0.5))); // far right
    try testing.expect(!aabbInFrustum(planes, unitBoxAt(0, 100, 0, 0.5))); // far up
}

test "golden: worldAabb of 45°-Y-rotated unit cube, translated +x10" {
    const local = unitBoxAt(0, 0, 0, 0.5);
    const world = math.Mat4.fromTrs(
        math.Vec3.init(10, 0, 0),
        math.Quat.fromAxisAngle(math.Vec3.init(0, 1, 0), std.math.pi / 4.0),
        math.Vec3.init(1, 1, 1),
    );
    const wb = worldAabb(local, world);
    // 45° about Y spreads the ±0.5 x/z extent to ±0.5·(cos+sin)=±0.7071; y unchanged.
    const ext: f32 = 0.5 * (@cos(std.math.pi / 4.0) + @sin(std.math.pi / 4.0));
    try testing.expectApproxEqAbs(10 - ext, wb.min.x, eps);
    try testing.expectApproxEqAbs(10 + ext, wb.max.x, eps);
    try testing.expectApproxEqAbs(@as(f32, -0.5), wb.min.y, eps);
    try testing.expectApproxEqAbs(@as(f32, 0.5), wb.max.y, eps);
    try testing.expectApproxEqAbs(-ext, wb.min.z, eps);
    try testing.expectApproxEqAbs(ext, wb.max.z, eps);
}
