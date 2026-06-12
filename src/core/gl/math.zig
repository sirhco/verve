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

/// Inverse-transpose of the upper 3×3 of `m`, column-major [9]f32
/// (col*3+row). Shipped per-draw to PBR shaders as 9 f32.
/// Asserts non-singular (|det| > 1e-12) in debug builds.
pub fn normalMatrix(m: Mat4) [9]f32 {
    // Extract upper 3×3 in row,col notation (column-major storage: m[col*4+row]).
    const a00 = m.m[0]; // [row0,col0]
    const a10 = m.m[1]; // [row1,col0]
    const a20 = m.m[2]; // [row2,col0]
    const a01 = m.m[4]; // [row0,col1]
    const a11 = m.m[5]; // [row1,col1]
    const a21 = m.m[6]; // [row2,col1]
    const a02 = m.m[8]; // [row0,col2]
    const a12 = m.m[9]; // [row1,col2]
    const a22 = m.m[10]; // [row2,col2]

    // Cofactors C[i,j] = (-1)^(i+j) * det(minor removing row i, col j).
    const c00 = a11 * a22 - a21 * a12;
    const c10 = -(a01 * a22 - a21 * a02);
    const c20 = a01 * a12 - a11 * a02;
    const c01 = -(a10 * a22 - a20 * a12);
    const c11 = a00 * a22 - a20 * a02;
    const c21 = -(a00 * a12 - a10 * a02);
    const c02 = a10 * a21 - a20 * a11;
    const c12 = -(a00 * a21 - a20 * a01);
    const c22 = a00 * a11 - a10 * a01;

    // det = first row dotted with its cofactors.
    const det = a00 * c00 + a01 * c01 + a02 * c02;
    std.debug.assert(@abs(det) > 1e-12); // non-singular guard

    const inv_det = 1.0 / det;

    // normalMatrix = A^{-T} = (adj/det)^T = cofactor/det.
    // (adj = cofactor^T, so adj^T = cofactor.)
    // Output column-major [col*3+row] = C[row,col]/det:
    //   col0: C[0,0],C[1,0],C[2,0] = c00,c10,c20
    //   col1: C[0,1],C[1,1],C[2,1] = c01,c11,c21
    //   col2: C[0,2],C[1,2],C[2,2] = c02,c12,c22
    return .{
        c00 * inv_det, c10 * inv_det, c20 * inv_det, // col 0
        c01 * inv_det, c11 * inv_det, c21 * inv_det, // col 1
        c02 * inv_det, c12 * inv_det, c22 * inv_det, // col 2
    };
}

/// Full 4×4 inverse via cofactor (adjugate / det) expansion.
/// Column-major storage: m[col*4+row]. Uses 2×2 sub-determinant
/// factorization: each cofactor of the 4×4 is expressed as a sum of
/// products of 2×2 sub-dets extracted from the remaining rows/cols.
/// Asserts non-singular (|det| > 1e-12) in debug builds.
pub fn invert(m: Mat4) Mat4 {
    // Extract all 16 elements in [row,col] notation (column-major storage).
    const a00 = m.m[0];
    const a01 = m.m[4];
    const a02 = m.m[8];
    const a03 = m.m[12];
    const a10 = m.m[1];
    const a11 = m.m[5];
    const a12 = m.m[9];
    const a13 = m.m[13];
    const a20 = m.m[2];
    const a21 = m.m[6];
    const a22 = m.m[10];
    const a23 = m.m[14];
    const a30 = m.m[3];
    const a31 = m.m[7];
    const a32 = m.m[11];
    const a33 = m.m[15];

    // 2×2 sub-determinants for the lower-right 3 columns of each cofactor.
    // Named s<row_a><row_b>_<col_a><col_b> = a[row_a,col_a]*a[row_b,col_b] - ...
    const s22_33 = a22 * a33 - a32 * a23;
    const s21_33 = a21 * a33 - a31 * a23;
    const s21_32 = a21 * a32 - a31 * a22;
    const s20_33 = a20 * a33 - a30 * a23;
    const s20_32 = a20 * a32 - a30 * a22;
    const s20_31 = a20 * a31 - a30 * a21;

    // Cofactors C[row, col] of the 4×4 (sign = (-1)^(row+col)).
    // Expanded along columns of the adjugate (= transposed cofactor matrix).
    // Adj[row,col] = C[col,row], so adj[row,col*4] in column-major output.
    const c00 = (a11 * s22_33 - a12 * s21_33 + a13 * s21_32);
    const c10 = -(a10 * s22_33 - a12 * s20_33 + a13 * s20_32);
    const c20 = (a10 * s21_33 - a11 * s20_33 + a13 * s20_31);
    const c30 = -(a10 * s21_32 - a11 * s20_32 + a12 * s20_31);

    // det via first row × its cofactors (cofactor of element [0,j] = C[0,j]).
    const det = a00 * c00 + a01 * c10 + a02 * c20 + a03 * c30;
    std.debug.assert(@abs(det) > 1e-12); // non-singular guard

    const s12_33 = a12 * a33 - a32 * a13;
    const s11_33 = a11 * a33 - a31 * a13;
    const s11_32 = a11 * a32 - a31 * a12;
    const s10_33 = a10 * a33 - a30 * a13;
    const s10_32 = a10 * a32 - a30 * a12;
    const s10_31 = a10 * a31 - a30 * a11;

    const s12_23 = a12 * a23 - a22 * a13;
    const s11_23 = a11 * a23 - a21 * a13;
    const s11_22 = a11 * a22 - a21 * a12;
    const s10_23 = a10 * a23 - a20 * a13;
    const s10_22 = a10 * a22 - a20 * a12;
    const s10_21 = a10 * a21 - a20 * a11;

    const c01 = -(a01 * s22_33 - a02 * s21_33 + a03 * s21_32);
    const c11 = (a00 * s22_33 - a02 * s20_33 + a03 * s20_32);
    const c21 = -(a00 * s21_33 - a01 * s20_33 + a03 * s20_31);
    const c31 = (a00 * s21_32 - a01 * s20_32 + a02 * s20_31);

    const c02 = (a01 * s12_33 - a02 * s11_33 + a03 * s11_32);
    const c12 = -(a00 * s12_33 - a02 * s10_33 + a03 * s10_32);
    const c22 = (a00 * s11_33 - a01 * s10_33 + a03 * s10_31);
    const c32 = -(a00 * s11_32 - a01 * s10_32 + a02 * s10_31);

    const c03 = -(a01 * s12_23 - a02 * s11_23 + a03 * s11_22);
    const c13 = (a00 * s12_23 - a02 * s10_23 + a03 * s10_22);
    const c23 = -(a00 * s11_23 - a01 * s10_23 + a03 * s10_21);
    const c33 = (a00 * s11_22 - a01 * s10_22 + a02 * s10_21);

    const inv_det = 1.0 / det;

    // inv = adj / det. adj[i,j] = C[j,i], so column-major output [col*4+row]:
    //   col 0: adj[0..3, 0] = C[0,0..3]/det = c00,c10,c20,c30
    //   col 1: adj[0..3, 1] = C[1,0..3]/det = c01,c11,c21,c31
    //   col 2: adj[0..3, 2] = C[2,0..3]/det = c02,c12,c22,c32
    //   col 3: adj[0..3, 3] = C[3,0..3]/det = c03,c13,c23,c33
    return .{
        .m = .{
            c00 * inv_det, c10 * inv_det, c20 * inv_det, c30 * inv_det, // col 0
            c01 * inv_det, c11 * inv_det, c21 * inv_det, c31 * inv_det, // col 1
            c02 * inv_det, c12 * inv_det, c22 * inv_det, c32 * inv_det, // col 2
            c03 * inv_det, c13 * inv_det, c23 * inv_det, c33 * inv_det, // col 3
        },
    };
}

/// Transform a point by `m` with implicit w=1 (translation applies).
/// Column-major: result[row] = sum_col( m[col*4+row] * v[col] ) + m[3*4+row].
pub fn transformPoint(m: Mat4, v: Vec3) Vec3 {
    return Vec3.init(
        m.m[0] * v.x + m.m[4] * v.y + m.m[8] * v.z + m.m[12],
        m.m[1] * v.x + m.m[5] * v.y + m.m[9] * v.z + m.m[13],
        m.m[2] * v.x + m.m[6] * v.y + m.m[10] * v.z + m.m[14],
    );
}

/// Transform a direction by `m` with implicit w=0 (translation ignored).
pub fn transformDir(m: Mat4, v: Vec3) Vec3 {
    return Vec3.init(
        m.m[0] * v.x + m.m[4] * v.y + m.m[8] * v.z,
        m.m[1] * v.x + m.m[5] * v.y + m.m[9] * v.z,
        m.m[2] * v.x + m.m[6] * v.y + m.m[10] * v.z,
    );
}

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

test "normalMatrix: pure rotation preserves upper 3x3" {
    // For an orthogonal matrix R, (R^{-T}) == R, so normalMatrix == upper 3x3.
    const q = Quat.fromAxisAngle(Vec3.init(0, 1, 0), std.math.pi / 2.0);
    const m = Mat4.fromTrs(Vec3.init(0, 0, 0), q, Vec3.init(1, 1, 1));
    const n = normalMatrix(m);
    // upper 3x3 in col-major [col*3+row]; compare to m[col*4+row]
    var col: usize = 0;
    while (col < 3) : (col += 1) {
        var row: usize = 0;
        while (row < 3) : (row += 1) {
            try testing.expectApproxEqAbs(m.m[col * 4 + row], n[col * 3 + row], eps);
        }
    }
}

test "normalMatrix: non-uniform scale diag(2,1,0.5) inverts scales" {
    // M = diag(2,1,0.5) → upper 3x3 A = diag(2,1,0.5)
    // A^{-T} = diag(1/2, 1, 2) = diag(0.5, 1, 2)
    const m = Mat4.fromTrs(Vec3.init(0, 0, 0), Quat.identity, Vec3.init(2, 1, 0.5));
    const n = normalMatrix(m);
    try testing.expectApproxEqAbs(@as(f32, 0.5), n[0], eps); // col0 row0
    try testing.expectApproxEqAbs(@as(f32, 0), n[1], eps); // col0 row1
    try testing.expectApproxEqAbs(@as(f32, 0), n[2], eps); // col0 row2
    try testing.expectApproxEqAbs(@as(f32, 0), n[3], eps); // col1 row0
    try testing.expectApproxEqAbs(@as(f32, 1), n[4], eps); // col1 row1
    try testing.expectApproxEqAbs(@as(f32, 0), n[5], eps); // col1 row2
    try testing.expectApproxEqAbs(@as(f32, 0), n[6], eps); // col2 row0
    try testing.expectApproxEqAbs(@as(f32, 0), n[7], eps); // col2 row1
    try testing.expectApproxEqAbs(@as(f32, 2), n[8], eps); // col2 row2
}

test "golden: normalMatrix rotation×non-uniform-scale" {
    // M = R(+90°Y) × S(2,1,0.5). Upper 3×3 A in A[row,col] notation:
    //   A[0,0]=0   A[0,1]=0    A[0,2]=0.5
    //   A[1,0]=0   A[1,1]=1    A[1,2]=0
    //   A[2,0]=-2  A[2,1]=0   A[2,2]=0
    // det(A) via first row: 0 + 0 + 0.5*(0*0 - 1*(-2)) = 0.5*2 = 1
    // Cofactors C[i,j] = (-1)^(i+j) * minor(row i, col j):
    //   C[0,0]=+(1*0-0*0)=0    C[0,1]=-(0*0-0*(-2))=0    C[0,2]=+(0*0-1*(-2))=2
    //   C[1,0]=-(0*0-0*0.5)=0  C[1,1]=+(0*0-(-2)*0.5)=1  C[1,2]=-(0*0-(-2)*0)=0
    //   C[2,0]=+(0*0-0.5*1)=-0.5 C[2,1]=-(0*0-0.5*0)=0   C[2,2]=+(0*1-0*0)=0
    // normalMatrix = A^{-T} = cofactor / det, col-major [col*3+row] = C[row,col]/det:
    //   col0: C[0,0]=0   C[1,0]=0    C[2,0]=-0.5  → n[0,1,2]
    //   col1: C[0,1]=0   C[1,1]=1    C[2,1]=0     → n[3,4,5]
    //   col2: C[0,2]=2   C[1,2]=0    C[2,2]=0     → n[6,7,8]
    const eps4 = 1e-4;
    const q = Quat.fromAxisAngle(Vec3.init(0, 1, 0), std.math.pi / 2.0);
    const m = Mat4.fromTrs(Vec3.init(0, 0, 0), q, Vec3.init(2, 1, 0.5));
    const n = normalMatrix(m);
    try testing.expectApproxEqAbs(@as(f32, 0), n[0], eps4);
    try testing.expectApproxEqAbs(@as(f32, 0), n[1], eps4);
    try testing.expectApproxEqAbs(@as(f32, -0.5), n[2], eps4);
    try testing.expectApproxEqAbs(@as(f32, 0), n[3], eps4);
    try testing.expectApproxEqAbs(@as(f32, 1), n[4], eps4);
    try testing.expectApproxEqAbs(@as(f32, 0), n[5], eps4);
    try testing.expectApproxEqAbs(@as(f32, 2), n[6], eps4);
    try testing.expectApproxEqAbs(@as(f32, 0), n[7], eps4);
    try testing.expectApproxEqAbs(@as(f32, 0), n[8], eps4);
}

test "invert: identity round-trips" {
    const inv = invert(Mat4.identity);
    try testing.expectEqualSlices(f32, &Mat4.identity.m, &inv.m);
}

test "invert: M*invert(M) ≈ I and invert(M)*M ≈ I (TRS with non-uniform scale)" {
    // M = fromTrs(t=(1,2,3), q=+90°Y, s=(2,1,0.5)) — translate+rotate+non-uniform scale.
    const eps4 = 1e-4;
    const q = Quat.fromAxisAngle(Vec3.init(0, 1, 0), std.math.pi / 2.0);
    const m = Mat4.fromTrs(Vec3.init(1, 2, 3), q, Vec3.init(2, 1, 0.5));
    const mi = invert(m);
    const id1 = m.mul(mi); // M * M^{-1}
    const id2 = mi.mul(m); // M^{-1} * M
    // Identity reference
    const id = Mat4.identity;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        try testing.expectApproxEqAbs(id.m[i], id1.m[i], eps4);
        try testing.expectApproxEqAbs(id.m[i], id2.m[i], eps4);
    }
}

test "invert: perspective matrix round-trips" {
    // P = perspective(pi/2, 1.0, 1.0, 10.0); invert(P)*P ≈ I.
    const eps4 = 1e-4;
    const p = Mat4.perspective(std.math.pi / 2.0, 1.0, 1.0, 10.0);
    const pi_ = invert(p);
    const id1 = p.mul(pi_);
    const id2 = pi_.mul(p);
    const id = Mat4.identity;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        try testing.expectApproxEqAbs(id.m[i], id1.m[i], eps4);
        try testing.expectApproxEqAbs(id.m[i], id2.m[i], eps4);
    }
}

test "transformPoint: identity returns input unchanged" {
    const v = Vec3.init(3, 5, 7);
    const r = transformPoint(Mat4.identity, v);
    try testing.expectApproxEqAbs(v.x, r.x, eps);
    try testing.expectApproxEqAbs(v.y, r.y, eps);
    try testing.expectApproxEqAbs(v.z, r.z, eps);
}

test "golden: transformPoint — +90°Y rotation then translate (10,0,0)" {
    // M = fromTrs(t=(10,0,0), q=+90°Y, s=(1,1,1)).
    // +90°Y maps: +X→-Z, +Y→+Y, +Z→+X (column 0 of M = (0,0,-1)).
    // transformPoint(M, (1,0,0)):
    //   rotation part: R*(1,0,0) = col0 of rotation = (0, 0, -1)
    //   add translation (10,0,0) → (10, 0, -1).
    const eps4 = 1e-4;
    const q = Quat.fromAxisAngle(Vec3.init(0, 1, 0), std.math.pi / 2.0);
    const m = Mat4.fromTrs(Vec3.init(10, 0, 0), q, Vec3.init(1, 1, 1));
    const r = transformPoint(m, Vec3.init(1, 0, 0));
    try testing.expectApproxEqAbs(@as(f32, 10), r.x, eps4);
    try testing.expectApproxEqAbs(@as(f32, 0), r.y, eps4);
    try testing.expectApproxEqAbs(@as(f32, -1), r.z, eps4);
}

test "golden: transformDir — +90°Y rotation, translation ignored" {
    // Same M. transformDir(M, (1,0,0)):
    //   R*(1,0,0) = (0, 0, -1) — translation (10,0,0) not added.
    const eps4 = 1e-4;
    const q = Quat.fromAxisAngle(Vec3.init(0, 1, 0), std.math.pi / 2.0);
    const m = Mat4.fromTrs(Vec3.init(10, 0, 0), q, Vec3.init(1, 1, 1));
    const r = transformDir(m, Vec3.init(1, 0, 0));
    try testing.expectApproxEqAbs(@as(f32, 0), r.x, eps4);
    try testing.expectApproxEqAbs(@as(f32, 0), r.y, eps4);
    try testing.expectApproxEqAbs(@as(f32, -1), r.z, eps4);
}
