//! verve.gl pick-ray construction and triangle intersection.
//!
//! ## NDC convention
//! ndc_x, ndc_y ∈ [−1, 1]; +x = right on screen, +y = up on screen (matches
//! WebGL/NDC where bottom-left = (−1,−1)). This matches the verve.gl coord
//! system: right-handed, Y-up, camera looks down −Z.
//!
//! ## Camera basis (no matrix inverse)
//! Given eye, target, up, fov_y (vertical, radians), aspect (w/h):
//!   forward  = normalize(target − eye)
//!   right    = normalize(cross(forward, up))
//!   cam_up   = cross(right, forward)          ← re-orthogonalised
//!   half_h   = tan(fov_y / 2)
//!   half_w   = half_h * aspect
//!   dir      = normalize(forward + right*ndc_x*half_w + cam_up*ndc_y*half_h)
//!
//! ## Triangle intersection
//! Möller–Trumbore (no backface culling — picking hits either side).
//! Returns t (world-space distance along ray) or null when:
//!   • ray is parallel to triangle plane  (|det| < epsilon)
//!   • t ≤ epsilon (behind or on the origin plane)
//!   • barycentric coordinates outside [0, 1]

const std = @import("std");
const math = @import("math.zig");

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub const Ray = struct {
    origin: math.Vec3,
    /// Guaranteed normalised by rayFromCamera / callers.
    dir: math.Vec3,
};

// ---------------------------------------------------------------------------
// Ray from perspective camera
// ---------------------------------------------------------------------------

/// Build the pick ray through NDC point (ndc_x, ndc_y) ∈ [−1, 1]² (y up).
/// fov_y is vertical field-of-view in radians.  aspect = width / height.
/// No matrix inverse needed — builds camera basis analytically.
pub fn rayFromCamera(
    eye: math.Vec3,
    target: math.Vec3,
    up: math.Vec3,
    fov_y: f32,
    aspect: f32,
    ndc_x: f32,
    ndc_y: f32,
) Ray {
    const forward = target.sub(eye).normalize();
    const right = forward.cross(up).normalize();
    const cam_up = right.cross(forward); // already unit-length; no renorm needed

    const half_h = @tan(fov_y * 0.5);
    const half_w = half_h * aspect;

    const dir = forward
        .add(right.scale(ndc_x * half_w))
        .add(cam_up.scale(ndc_y * half_h))
        .normalize();

    return .{ .origin = eye, .dir = dir };
}

// ---------------------------------------------------------------------------
// Ray transform
// ---------------------------------------------------------------------------

/// Transform a ray by `m` (origin as a point, direction as a vector).
/// The direction is NOT renormalized — valid for rigid transforms
/// (rotation + translation, scale 1), where parameter t remains
/// comparable across differently-transformed rays.
pub fn transformRay(r: Ray, m: math.Mat4) Ray {
    return .{
        .origin = math.transformPoint(m, r.origin),
        .dir = math.transformDir(m, r.dir),
    };
}

// ---------------------------------------------------------------------------
// Möller–Trumbore triangle intersection
// ---------------------------------------------------------------------------

const mt_epsilon: f32 = 1e-6;

/// Returns t > epsilon of the nearest hit, or null.
/// No backface culling: reversed-winding triangles are hit identically.
pub fn intersectTriangle(
    ray: Ray,
    v0: math.Vec3,
    v1: math.Vec3,
    v2: math.Vec3,
) ?f32 {
    const edge1 = v1.sub(v0);
    const edge2 = v2.sub(v0);

    const h = ray.dir.cross(edge2);
    const det = edge1.dot(h);

    // Parallel check (handles both backface and front — we keep both).
    if (@abs(det) < mt_epsilon) return null;

    const inv_det = 1.0 / det;
    const s = ray.origin.sub(v0);
    const u = s.dot(h) * inv_det;
    if (u < 0.0 or u > 1.0) return null;

    const q = s.cross(edge1);
    const v = ray.dir.dot(q) * inv_det;
    if (v < 0.0 or u + v > 1.0) return null;

    const t = edge2.dot(q) * inv_det;
    if (t <= mt_epsilon) return null;

    return t;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const eps6: f32 = 1e-6;
const eps5: f32 = 1e-5;

test "rayFromCamera center → dir ≈ (0,0,−1)" {
    // eye at (0,0,5) looking at origin with +Y up; NDC (0,0) = screen centre.
    // forward = (0,0,−1); any fov / aspect leaves dir = forward at NDC origin.
    const r = rayFromCamera(
        math.Vec3.init(0, 0, 5),
        math.Vec3.init(0, 0, 0),
        math.Vec3.init(0, 1, 0),
        std.math.pi / 3.0,
        16.0 / 9.0,
        0,
        0,
    );
    try testing.expectApproxEqAbs(@as(f32, 0), r.origin.x, eps6);
    try testing.expectApproxEqAbs(@as(f32, 0), r.origin.y, eps6);
    try testing.expectApproxEqAbs(@as(f32, 5), r.origin.z, eps6);
    try testing.expectApproxEqAbs(@as(f32, 0), r.dir.x, eps6);
    try testing.expectApproxEqAbs(@as(f32, 0), r.dir.y, eps6);
    try testing.expectApproxEqAbs(@as(f32, -1), r.dir.z, eps6);
}

test "rayFromCamera corner hand-derivation" {
    // eye=(0,0,5), target=origin, up=+Y, fov_y=π/3, aspect=16/9, ndc=(1,1).
    //
    // forward  = (0, 0, −1)
    // right    = normalize(cross(forward, up)) = normalize(cross((0,0,−1),(0,1,0)))
    //          = normalize((0*0−(−1)*1,  (−1)*0−0*0,  0*1−0*0))
    //          = normalize((1, 0, 0)) = (1, 0, 0)
    // cam_up   = cross(right, forward) = cross((1,0,0),(0,0,−1))
    //          = (0*(−1)−0*0,  0*1−1*(−1),  1*0−0*1) = (0, 1, 0)
    // half_h   = tan(π/6) ≈ 0.57735
    // half_w   = half_h * 16/9 ≈ 1.02754
    // raw      = (0,0,−1) + (1,0,0)*half_w + (0,1,0)*half_h
    //          = (half_w, half_h, −1)
    // len      = sqrt(half_w² + half_h² + 1)
    //          = sqrt(1.05583 + 0.33333 + 1) = sqrt(2.38916) ≈ 1.54569
    // dir      ≈ (0.66481, 0.37372, −0.64703)
    const fov_y: f32 = std.math.pi / 3.0;
    const aspect: f32 = 16.0 / 9.0;
    const half_h = @tan(fov_y * 0.5);
    const half_w = half_h * aspect;
    const raw_x = half_w;
    const raw_y = half_h;
    const raw_z: f32 = -1.0;
    const len = @sqrt(raw_x * raw_x + raw_y * raw_y + raw_z * raw_z);

    const r = rayFromCamera(
        math.Vec3.init(0, 0, 5),
        math.Vec3.init(0, 0, 0),
        math.Vec3.init(0, 1, 0),
        fov_y,
        aspect,
        1,
        1,
    );
    try testing.expectApproxEqAbs(raw_x / len, r.dir.x, eps5);
    try testing.expectApproxEqAbs(raw_y / len, r.dir.y, eps5);
    try testing.expectApproxEqAbs(raw_z / len, r.dir.z, eps5);
}

test "rayFromCamera +y NDC → dir.y > 0" {
    // Moving ndc_y above centre must tilt the ray upward (cam_up = +Y here).
    const r = rayFromCamera(
        math.Vec3.init(0, 0, 5),
        math.Vec3.init(0, 0, 0),
        math.Vec3.init(0, 1, 0),
        std.math.pi / 3.0,
        16.0 / 9.0,
        0,
        0.5,
    );
    try testing.expect(r.dir.y > 0);
}

test "intersectTriangle basic hit t==5" {
    // Ray from (0,0,5) toward (0,0,−1); triangle in z=0 plane around origin.
    const ray = Ray{
        .origin = math.Vec3.init(0, 0, 5),
        .dir = math.Vec3.init(0, 0, -1),
    };
    const v0 = math.Vec3.init(-1, -1, 0);
    const v1 = math.Vec3.init(1, -1, 0);
    const v2 = math.Vec3.init(0, 1, 0);
    const t = intersectTriangle(ray, v0, v1, v2);
    try testing.expect(t != null);
    try testing.expectApproxEqAbs(@as(f32, 5), t.?, eps5);
}

test "intersectTriangle parallel ray → null" {
    // Ray travelling in the z=0 plane — parallel to the triangle.
    const ray = Ray{
        .origin = math.Vec3.init(-5, 0, 0),
        .dir = math.Vec3.init(1, 0, 0),
    };
    const v0 = math.Vec3.init(-1, -1, 0);
    const v1 = math.Vec3.init(1, -1, 0);
    const v2 = math.Vec3.init(0, 1, 0);
    try testing.expect(intersectTriangle(ray, v0, v1, v2) == null);
}

test "intersectTriangle backface hit (no culling)" {
    // Reverse winding of the z=0 triangle — must still return t == 5.
    const ray = Ray{
        .origin = math.Vec3.init(0, 0, 5),
        .dir = math.Vec3.init(0, 0, -1),
    };
    const v0 = math.Vec3.init(-1, -1, 0);
    const v1 = math.Vec3.init(0, 1, 0); // swapped v1/v2
    const v2 = math.Vec3.init(1, -1, 0);
    const t = intersectTriangle(ray, v0, v1, v2);
    try testing.expect(t != null);
    try testing.expectApproxEqAbs(@as(f32, 5), t.?, eps5);
}

test "intersectTriangle ray pointing away → null" {
    // Ray from (0,0,5) pointing +Z away from the z=0 triangle.
    const ray = Ray{
        .origin = math.Vec3.init(0, 0, 5),
        .dir = math.Vec3.init(0, 0, 1),
    };
    const v0 = math.Vec3.init(-1, -1, 0);
    const v1 = math.Vec3.init(1, -1, 0);
    const v2 = math.Vec3.init(0, 1, 0);
    try testing.expect(intersectTriangle(ray, v0, v1, v2) == null);
}

test "transformRay identity → ray unchanged" {
    const r = Ray{
        .origin = math.Vec3.init(1, 2, 3),
        .dir = math.Vec3.init(0, 0, -1),
    };
    const out = transformRay(r, math.Mat4.identity);
    try testing.expectApproxEqAbs(@as(f32, 1), out.origin.x, eps6);
    try testing.expectApproxEqAbs(@as(f32, 2), out.origin.y, eps6);
    try testing.expectApproxEqAbs(@as(f32, 3), out.origin.z, eps6);
    try testing.expectApproxEqAbs(@as(f32, 0), out.dir.x, eps6);
    try testing.expectApproxEqAbs(@as(f32, 0), out.dir.y, eps6);
    try testing.expectApproxEqAbs(@as(f32, -1), out.dir.z, eps6);
}

test "transformRay rotated-geometry parity (rotation)" {
    // Bind-pose triangle in the XY plane (z = 0) around the origin.
    const v0 = math.Vec3.init(-1, -1, 0);
    const v1 = math.Vec3.init(1, -1, 0);
    const v2 = math.Vec3.init(0, 1, 0);

    // World = +90° rotation about Y. Rotated triangle lies in the ZY plane
    // (plane x = 0): (x,y,z) → (z, y, −x).
    const w = math.Mat4.fromTrs(
        math.Vec3.init(0, 0, 0),
        math.Quat.fromAxisAngle(math.Vec3.init(0, 1, 0), std.math.pi / 2.0),
        math.Vec3.init(1, 1, 1),
    );

    // World-space ray aimed at the ROTATED triangle: from (5,0,0) along −X.
    const r = Ray{
        .origin = math.Vec3.init(5, 0, 0),
        .dir = math.Vec3.init(-1, 0, 0),
    };

    // The raw ray travels in the z=0 plane — parallel to the BIND-POSE
    // triangle's plane — so direct intersection MISSES.
    try testing.expect(intersectTriangle(r, v0, v1, v2) == null);

    // Inverse-transform the ray into bind space and hit the bind triangle.
    const local = transformRay(r, math.invert(w));
    const t_local = intersectTriangle(local, v0, v1, v2);
    try testing.expect(t_local != null);

    // Cross-check: rotate the verts into world space and hit with the raw ray.
    const t_world = intersectTriangle(
        r,
        math.transformPoint(w, v0),
        math.transformPoint(w, v1),
        math.transformPoint(w, v2),
    );
    try testing.expect(t_world != null);

    // Rigid transform → t is comparable across spaces; both must agree.
    try testing.expectApproxEqAbs(t_world.?, t_local.?, 1e-4);
    // Rotated triangle lies in plane x = 0; ray starts at x = 5 with dir −X,
    // so t = 5.0 exactly.
    try testing.expectApproxEqAbs(@as(f32, 5.0), t_local.?, 1e-4);
}

test "transformRay rotated-geometry parity (translation)" {
    const v0 = math.Vec3.init(-1, -1, 0);
    const v1 = math.Vec3.init(1, -1, 0);
    const v2 = math.Vec3.init(0, 1, 0);

    // World = pure translation (3, 0, 0).
    const w = math.Mat4.fromTrs(
        math.Vec3.init(3, 0, 0),
        math.Quat.identity,
        math.Vec3.init(1, 1, 1),
    );

    // World-space ray over the translated triangle's centre, looking down −Z.
    const r = Ray{
        .origin = math.Vec3.init(3, 0, 5),
        .dir = math.Vec3.init(0, 0, -1),
    };

    // Direct hit on the translated triangle.
    const t_world = intersectTriangle(
        r,
        math.transformPoint(w, v0),
        math.transformPoint(w, v1),
        math.transformPoint(w, v2),
    );
    try testing.expect(t_world != null);

    // Inverse-transformed ray against the bind-pose triangle: same t.
    const local = transformRay(r, math.invert(w));
    const t_local = intersectTriangle(local, v0, v1, v2);
    try testing.expect(t_local != null);
    try testing.expectApproxEqAbs(t_world.?, t_local.?, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 5.0), t_local.?, 1e-4);
}

test "intersectTriangle edge graze through vertex" {
    // Ray aimed precisely at v2 = (0,1,0) from (0,1,5).
    // Barycentric: u≈0, v≈0, u+v≈0 — on the boundary; implementation hits it.
    const ray = Ray{
        .origin = math.Vec3.init(0, 1, 5),
        .dir = math.Vec3.init(0, 0, -1),
    };
    const v0 = math.Vec3.init(-1, -1, 0);
    const v1 = math.Vec3.init(1, -1, 0);
    const v2 = math.Vec3.init(0, 1, 0);
    const t = intersectTriangle(ray, v0, v1, v2);
    // At the exact vertex the barycentrics land on the boundary.
    // Behaviour is pinned: this implementation returns a hit (t ≈ 5).
    try testing.expect(t != null);
    try testing.expectApproxEqAbs(@as(f32, 5), t.?, eps5);
}
