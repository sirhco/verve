//! verve.gl math — column-major f32 linear algebra.
//! Conventions: right-handed, camera looks down -Z, WebGL clip space
//! (z in [-1, 1]). Mat4 is column-major (`m[col * 4 + row]`), matching
//! WebGL `uniformMatrix4fv(..., transpose=false, ...)` directly.
//! Freestanding-safe: no allocator, no std.io.

const std = @import("std");

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn init(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }
    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return init(a.x + b.x, a.y + b.y, a.z + b.z);
    }
    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return init(a.x - b.x, a.y - b.y, a.z - b.z);
    }
    pub fn scale(v: Vec3, s: f32) Vec3 {
        return init(v.x * s, v.y * s, v.z * s);
    }
    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }
    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return init(
            a.y * b.z - a.z * b.y,
            a.z * b.x - a.x * b.z,
            a.x * b.y - a.y * b.x,
        );
    }
    pub fn length(v: Vec3) f32 {
        return @sqrt(v.dot(v));
    }
    /// Zero-length input returns the zero vector unchanged — callers
    /// (lookAt, fromAxisAngle) must ensure non-degenerate input.
    pub fn normalize(v: Vec3) Vec3 {
        const len = v.length();
        return if (len == 0) v else v.scale(1.0 / len);
    }
};

pub const Quat = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    pub const identity = Quat{ .x = 0, .y = 0, .z = 0, .w = 1 };

    pub fn fromAxisAngle(axis: Vec3, angle: f32) Quat {
        const a = axis.normalize();
        const half = angle * 0.5;
        const s = @sin(half);
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s, .w = @cos(half) };
    }

    pub fn mul(a: Quat, b: Quat) Quat {
        return .{
            .x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            .y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            .z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
            .w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
        };
    }
};

pub const Mat4 = struct {
    m: [16]f32,

    pub const identity = Mat4{ .m = .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    } };

    pub fn mul(a: Mat4, b: Mat4) Mat4 {
        var out: Mat4 = undefined;
        var c: usize = 0;
        while (c < 4) : (c += 1) {
            var r: usize = 0;
            while (r < 4) : (r += 1) {
                var sum: f32 = 0;
                var k: usize = 0;
                while (k < 4) : (k += 1) sum += a.m[k * 4 + r] * b.m[c * 4 + k];
                out.m[c * 4 + r] = sum;
            }
        }
        return out;
    }

    pub fn perspective(fovy_rad: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const f = 1.0 / @tan(fovy_rad * 0.5);
        var out = Mat4{ .m = [_]f32{0} ** 16 };
        out.m[0] = f / aspect;
        out.m[5] = f;
        out.m[10] = (far + near) / (near - far);
        out.m[11] = -1;
        out.m[14] = (2.0 * far * near) / (near - far);
        return out;
    }

    /// `up` must not be parallel to `eye - target` (degenerate basis).
    pub fn lookAt(eye: Vec3, target: Vec3, up: Vec3) Mat4 {
        const zaxis = eye.sub(target).normalize();
        const xaxis = up.cross(zaxis).normalize();
        const yaxis = zaxis.cross(xaxis);
        return .{ .m = .{
            xaxis.x,         yaxis.x,         zaxis.x,         0,
            xaxis.y,         yaxis.y,         zaxis.y,         0,
            xaxis.z,         yaxis.z,         zaxis.z,         0,
            -xaxis.dot(eye), -yaxis.dot(eye), -zaxis.dot(eye), 1,
        } };
    }

    pub fn fromTrs(t: Vec3, r: Quat, s: Vec3) Mat4 {
        const x2 = r.x + r.x;
        const y2 = r.y + r.y;
        const z2 = r.z + r.z;
        const xx = r.x * x2;
        const xy = r.x * y2;
        const xz = r.x * z2;
        const yy = r.y * y2;
        const yz = r.y * z2;
        const zz = r.z * z2;
        const wx = r.w * x2;
        const wy = r.w * y2;
        const wz = r.w * z2;
        return .{ .m = .{
            (1 - (yy + zz)) * s.x, (xy + wz) * s.x,       (xz - wy) * s.x,       0,
            (xy - wz) * s.y,       (1 - (xx + zz)) * s.y, (yz + wx) * s.y,       0,
            (xz + wy) * s.z,       (yz - wx) * s.z,       (1 - (xx + yy)) * s.z, 0,
            t.x,                   t.y,                   t.z,                   1,
        } };
    }
};

const testing = std.testing;
const eps = 1e-5;

fn expectVec(expected: [3]f32, v: Vec3) !void {
    try testing.expectApproxEqAbs(expected[0], v.x, eps);
    try testing.expectApproxEqAbs(expected[1], v.y, eps);
    try testing.expectApproxEqAbs(expected[2], v.z, eps);
}

test "vec3 basics" {
    const a = Vec3.init(1, 2, 3);
    const b = Vec3.init(4, 5, 6);
    try expectVec(.{ 5, 7, 9 }, a.add(b));
    try expectVec(.{ -3, -3, -3 }, a.sub(b));
    try testing.expectApproxEqAbs(@as(f32, 32), a.dot(b), eps);
    try expectVec(.{ -3, 6, -3 }, a.cross(b));
    try testing.expectApproxEqAbs(@as(f32, 1), Vec3.init(0, 3, 4).normalize().length(), eps);
}

test "mat4 identity mul" {
    const t = Mat4.fromTrs(Vec3.init(2, 3, 4), Quat.identity, Vec3.init(1, 1, 1));
    const r = Mat4.identity.mul(t);
    try testing.expectEqualSlices(f32, &t.m, &r.m);
}

test "golden: perspective fovy=pi/2 aspect=1 near=1 far=10" {
    const p = Mat4.perspective(std.math.pi / 2.0, 1.0, 1.0, 10.0);
    try testing.expectApproxEqAbs(@as(f32, 1), p.m[0], eps);
    try testing.expectApproxEqAbs(@as(f32, 1), p.m[5], eps);
    try testing.expectApproxEqAbs(@as(f32, -11.0 / 9.0), p.m[10], eps);
    try testing.expectApproxEqAbs(@as(f32, -1), p.m[11], eps);
    try testing.expectApproxEqAbs(@as(f32, -20.0 / 9.0), p.m[14], eps);
    try testing.expectApproxEqAbs(@as(f32, 0), p.m[15], eps);
}

test "golden: lookAt from +z" {
    const v = Mat4.lookAt(Vec3.init(0, 0, 5), Vec3.init(0, 0, 0), Vec3.init(0, 1, 0));
    // axes stay world-aligned; translation moves eye to origin
    try testing.expectApproxEqAbs(@as(f32, 1), v.m[0], eps); // right.x
    try testing.expectApproxEqAbs(@as(f32, 1), v.m[5], eps); // up.y
    try testing.expectApproxEqAbs(@as(f32, 1), v.m[10], eps); // back.z
    try testing.expectApproxEqAbs(@as(f32, 0), v.m[12], eps);
    try testing.expectApproxEqAbs(@as(f32, 0), v.m[13], eps);
    try testing.expectApproxEqAbs(@as(f32, -5), v.m[14], eps);
}

test "fromTrs: +90deg about Y maps +X to -Z, then translates" {
    const q = Quat.fromAxisAngle(Vec3.init(0, 1, 0), std.math.pi / 2.0);
    const m = Mat4.fromTrs(Vec3.init(10, 0, 0), q, Vec3.init(1, 1, 1));
    // column 0 = image of +X basis vector = (0, 0, -1)
    try testing.expectApproxEqAbs(@as(f32, 0), m.m[0], eps);
    try testing.expectApproxEqAbs(@as(f32, 0), m.m[1], eps);
    try testing.expectApproxEqAbs(@as(f32, -1), m.m[2], eps);
    // translation column
    try testing.expectApproxEqAbs(@as(f32, 10), m.m[12], eps);
}

test "fromTrs: scale applies per-axis" {
    const m = Mat4.fromTrs(Vec3.init(0, 0, 0), Quat.identity, Vec3.init(2, 3, 4));
    try testing.expectApproxEqAbs(@as(f32, 2), m.m[0], eps);
    try testing.expectApproxEqAbs(@as(f32, 3), m.m[5], eps);
    try testing.expectApproxEqAbs(@as(f32, 4), m.m[10], eps);
}

test "quat mul: two 90deg Y rotations compose to 180deg" {
    const q = Quat.fromAxisAngle(Vec3.init(0, 1, 0), std.math.pi / 2.0);
    const q2 = q.mul(q);
    try testing.expectApproxEqAbs(@as(f32, 0), q2.x, eps);
    try testing.expectApproxEqAbs(@as(f32, 1), q2.y, eps);
    try testing.expectApproxEqAbs(@as(f32, 0), q2.z, eps);
    try testing.expectApproxEqAbs(@as(f32, 0), q2.w, eps);
}

test "lookAt off-axis eye maps eye to origin" {
    const eye = Vec3.init(1, 2, 5);
    const v = Mat4.lookAt(eye, Vec3.init(0, 0, 0), Vec3.init(0, 1, 0));
    // bottom row of the rotation columns stays homogeneous
    try testing.expectApproxEqAbs(@as(f32, 0), v.m[3], eps);
    try testing.expectApproxEqAbs(@as(f32, 0), v.m[7], eps);
    try testing.expectApproxEqAbs(@as(f32, 0), v.m[11], eps);
    try testing.expectApproxEqAbs(@as(f32, 1), v.m[15], eps);
    // V * (eye, 1) = origin — the defining invariant of a view matrix
    var r: usize = 0;
    while (r < 3) : (r += 1) {
        const out = v.m[r] * eye.x + v.m[4 + r] * eye.y + v.m[8 + r] * eye.z + v.m[12 + r];
        try testing.expectApproxEqAbs(@as(f32, 0), out, eps);
    }
}

test "fromTrs: +90deg about Y, all three basis columns" {
    const q = Quat.fromAxisAngle(Vec3.init(0, 1, 0), std.math.pi / 2.0);
    const m = Mat4.fromTrs(Vec3.init(0, 0, 0), q, Vec3.init(1, 1, 1));
    // +Y stays +Y
    try testing.expectApproxEqAbs(@as(f32, 0), m.m[4], eps);
    try testing.expectApproxEqAbs(@as(f32, 1), m.m[5], eps);
    try testing.expectApproxEqAbs(@as(f32, 0), m.m[6], eps);
    // +Z maps to +X
    try testing.expectApproxEqAbs(@as(f32, 1), m.m[8], eps);
    try testing.expectApproxEqAbs(@as(f32, 0), m.m[9], eps);
    try testing.expectApproxEqAbs(@as(f32, 0), m.m[10], eps);
}
