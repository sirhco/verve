//! Tangent generation — Lengyel's method.
//! Per-triangle tangents from UV deltas, accumulated per vertex,
//! Gram-Schmidt orthogonalized against the normal; w = handedness (+1/−1).
//! Degenerate uv/position triangles contribute nothing; vertices with a
//! zero accumulator get an arbitrary tangent perpendicular to the normal.
//! Returns 4 f32 per vertex (positions.len/3 vertices).

const std = @import("std");
const math = std.math;

pub const Error = error{
    /// positions.len%3≠0, normals count mismatch, uvs 2/vertex mismatch,
    /// indices.len%3≠0, or any index ≥ vertex count.
    InvalidInput,
    OutOfMemory,
};

/// Generate per-vertex tangents (4 f32: xyz=tangent, w=handedness ±1).
/// positions: 3 f32/vertex, normals: 3 f32/vertex, uvs: 2 f32/vertex,
/// indices: u16 index triples.
pub fn generate(
    alloc: std.mem.Allocator,
    positions: []const f32, // 3/vertex
    normals: []const f32, // 3/vertex
    uvs: []const f32, // 2/vertex
    indices: []const u16,
) Error![]f32 {
    // ── Validate inputs ────────────────────────────────────────────────────────
    if (positions.len % 3 != 0) return error.InvalidInput;
    const vertex_count = positions.len / 3;
    if (normals.len != vertex_count * 3) return error.InvalidInput;
    if (uvs.len != vertex_count * 2) return error.InvalidInput;
    if (indices.len % 3 != 0) return error.InvalidInput;
    for (indices) |idx| {
        if (@as(usize, idx) >= vertex_count) return error.InvalidInput;
    }

    // ── Accumulate T and B per vertex ─────────────────────────────────────────
    const t_acc = try alloc.alloc(f32, vertex_count * 3);
    defer alloc.free(t_acc);
    const b_acc = try alloc.alloc(f32, vertex_count * 3);
    defer alloc.free(b_acc);
    @memset(t_acc, 0);
    @memset(b_acc, 0);

    var tri: usize = 0;
    while (tri < indices.len / 3) : (tri += 1) {
        const vi0: usize = indices[tri * 3 + 0];
        const vi1: usize = indices[tri * 3 + 1];
        const vi2: usize = indices[tri * 3 + 2];

        const p0x = positions[vi0 * 3 + 0];
        const p0y = positions[vi0 * 3 + 1];
        const p0z = positions[vi0 * 3 + 2];
        const p1x = positions[vi1 * 3 + 0];
        const p1y = positions[vi1 * 3 + 1];
        const p1z = positions[vi1 * 3 + 2];
        const p2x = positions[vi2 * 3 + 0];
        const p2y = positions[vi2 * 3 + 1];
        const p2z = positions[vi2 * 3 + 2];

        const e1x = p1x - p0x;
        const e1y = p1y - p0y;
        const e1z = p1z - p0z;
        const e2x = p2x - p0x;
        const e2y = p2y - p0y;
        const e2z = p2z - p0z;

        const uv0u = uvs[vi0 * 2 + 0];
        const uv0v = uvs[vi0 * 2 + 1];
        const uv1u = uvs[vi1 * 2 + 0];
        const uv1v = uvs[vi1 * 2 + 1];
        const uv2u = uvs[vi2 * 2 + 0];
        const uv2v = uvs[vi2 * 2 + 1];

        const du1 = uv1u - uv0u;
        const dv1 = uv1v - uv0v;
        const du2 = uv2u - uv0u;
        const dv2 = uv2v - uv0v;

        const r = du1 * dv2 - du2 * dv1;
        if (@abs(r) < 1e-12) continue; // degenerate UV triangle → skip
        const inv = 1.0 / r;

        // T = (e1*dv2 - e2*dv1) * inv
        const ttx = (e1x * dv2 - e2x * dv1) * inv;
        const tty = (e1y * dv2 - e2y * dv1) * inv;
        const ttz = (e1z * dv2 - e2z * dv1) * inv;

        // B = (e2*du1 - e1*du2) * inv
        const tbx = (e2x * du1 - e1x * du2) * inv;
        const tby = (e2y * du1 - e1y * du2) * inv;
        const tbz = (e2z * du1 - e1z * du2) * inv;

        // Accumulate into all three vertices of the triangle.
        for ([_]usize{ vi0, vi1, vi2 }) |vi| {
            t_acc[vi * 3 + 0] += ttx;
            t_acc[vi * 3 + 1] += tty;
            t_acc[vi * 3 + 2] += ttz;
            b_acc[vi * 3 + 0] += tbx;
            b_acc[vi * 3 + 1] += tby;
            b_acc[vi * 3 + 2] += tbz;
        }
    }

    // ── Final pass: Gram-Schmidt orthogonalize, compute handedness ────────────
    const out = try alloc.alloc(f32, vertex_count * 4);

    for (0..vertex_count) |vi| {
        const nx = normals[vi * 3 + 0];
        const ny = normals[vi * 3 + 1];
        const nz = normals[vi * 3 + 2];

        const tax = t_acc[vi * 3 + 0];
        const tay = t_acc[vi * 3 + 1];
        const taz = t_acc[vi * 3 + 2];
        const t_len2 = tax * tax + tay * tay + taz * taz;

        var out_tx: f32 = 0;
        var out_ty: f32 = 0;
        var out_tz: f32 = 0;
        var w: f32 = 1.0;

        if (t_len2 < 1e-8 * 1e-8) {
            // Zero accumulator — arbitrary tangent perpendicular to N.
            // Same up-select trick as ibl.zig tangentFrame.
            const up_x: f32 = if (@abs(nz) < 0.999) 0.0 else 1.0;
            const up_y: f32 = 0.0;
            const up_z: f32 = if (@abs(nz) < 0.999) 1.0 else 0.0;
            // cross(up, n)
            var cx = up_y * nz - up_z * ny;
            var cy = up_z * nx - up_x * nz;
            var cz = up_x * ny - up_y * nx;
            const clen = @sqrt(cx * cx + cy * cy + cz * cz);
            if (clen > 1e-12) {
                cx /= clen;
                cy /= clen;
                cz /= clen;
            }
            out_tx = cx;
            out_ty = cy;
            out_tz = cz;
            w = 1.0;
        } else {
            // Gram-Schmidt: T' = normalize(T - N * dot(N,T))
            const dot_nt = nx * tax + ny * tay + nz * taz;
            var gx = tax - nx * dot_nt;
            var gy = tay - ny * dot_nt;
            var gz = taz - nz * dot_nt;
            const glen = @sqrt(gx * gx + gy * gy + gz * gz);
            if (glen > 1e-12) {
                gx /= glen;
                gy /= glen;
                gz /= glen;
            }
            out_tx = gx;
            out_ty = gy;
            out_tz = gz;

            // Handedness: w = sign(dot(cross(N, T'), B_acc))
            // cross(N, T')
            const cx = ny * gz - nz * gy;
            const cy = nz * gx - nx * gz;
            const cz = nx * gy - ny * gx;
            const bax = b_acc[vi * 3 + 0];
            const bay = b_acc[vi * 3 + 1];
            const baz = b_acc[vi * 3 + 2];
            w = if (cx * bax + cy * bay + cz * baz < 0.0) -1.0 else 1.0;
        }

        out[vi * 4 + 0] = out_tx;
        out[vi * 4 + 1] = out_ty;
        out[vi * 4 + 2] = out_tz;
        out[vi * 4 + 3] = w;
    }

    return out;
}

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

// Unit quad in XY plane (z=0), normal +Z, uv maps XY.
//   v0=(0,0,0) uv=(0,0)
//   v1=(1,0,0) uv=(1,0)
//   v2=(1,1,0) uv=(1,1)
//   v3=(0,1,0) uv=(0,1)
//   tri0: 0,1,2  tri1: 0,2,3
const quad_positions = [_]f32{
    0, 0, 0,
    1, 0, 0,
    1, 1, 0,
    0, 1, 0,
};
const quad_normals = [_]f32{
    0, 0, 1,
    0, 0, 1,
    0, 0, 1,
    0, 0, 1,
};
const quad_uvs = [_]f32{
    0, 0,
    1, 0,
    1, 1,
    0, 1,
};
const quad_indices = [_]u16{ 0, 1, 2, 0, 2, 3 };

test "tangent: quad XY plane → tangent ≈ (1,0,0,+1)" {
    const alloc = testing.allocator;
    const tans = try generate(alloc, &quad_positions, &quad_normals, &quad_uvs, &quad_indices);
    defer alloc.free(tans);

    try testing.expectEqual(@as(usize, 16), tans.len); // 4 vertices × 4 floats
    for (0..4) |vi| {
        try testing.expectApproxEqAbs(@as(f32, 1.0), tans[vi * 4 + 0], 1e-5);
        try testing.expectApproxEqAbs(@as(f32, 0.0), tans[vi * 4 + 1], 1e-5);
        try testing.expectApproxEqAbs(@as(f32, 0.0), tans[vi * 4 + 2], 1e-5);
        try testing.expectApproxEqAbs(@as(f32, 1.0), tans[vi * 4 + 3], 1e-5);
    }
}

test "tangent: quad with U mirrored → tangent ≈ (−1,0,0), w=−1" {
    // u → 1−u: uv = (1,0),(0,0),(0,1),(1,1)
    const mirrored_uvs = [_]f32{
        1, 0,
        0, 0,
        0, 1,
        1, 1,
    };
    const alloc = testing.allocator;
    const tans = try generate(alloc, &quad_positions, &quad_normals, &mirrored_uvs, &quad_indices);
    defer alloc.free(tans);

    for (0..4) |vi| {
        try testing.expectApproxEqAbs(@as(f32, -1.0), tans[vi * 4 + 0], 1e-5);
        try testing.expectApproxEqAbs(@as(f32, 0.0), tans[vi * 4 + 1], 1e-5);
        try testing.expectApproxEqAbs(@as(f32, 0.0), tans[vi * 4 + 2], 1e-5);
        try testing.expectApproxEqAbs(@as(f32, -1.0), tans[vi * 4 + 3], 1e-5);
    }
}

test "tangent: degenerate uv (all same) → finite, unit-length, perpendicular to normal" {
    // All four UVs identical → every triangle has r=0 → zero accumulator → fallback path.
    const degen_uvs = [_]f32{
        0.5, 0.5,
        0.5, 0.5,
        0.5, 0.5,
        0.5, 0.5,
    };
    const alloc = testing.allocator;
    const tans = try generate(alloc, &quad_positions, &quad_normals, &degen_uvs, &quad_indices);
    defer alloc.free(tans);

    for (0..4) |vi| {
        const tx = tans[vi * 4 + 0];
        const ty = tans[vi * 4 + 1];
        const tz = tans[vi * 4 + 2];
        // No NaN.
        try testing.expect(!math.isNan(tx));
        try testing.expect(!math.isNan(ty));
        try testing.expect(!math.isNan(tz));
        // Unit length (1e-5).
        const len = @sqrt(tx * tx + ty * ty + tz * tz);
        try testing.expectApproxEqAbs(@as(f32, 1.0), len, 1e-5);
        // Perpendicular to normal (0,0,1): dot must be ~0.
        const nx = quad_normals[vi * 3 + 0];
        const ny = quad_normals[vi * 3 + 1];
        const nz = quad_normals[vi * 3 + 2];
        const dot = tx * nx + ty * ny + tz * nz;
        try testing.expectApproxEqAbs(@as(f32, 0.0), dot, 1e-5);
    }
}

test "tangent: invalid input rejected" {
    const alloc = testing.allocator;
    // positions.len % 3 != 0
    try testing.expectError(error.InvalidInput, generate(alloc, &.{ 0, 0 }, &.{ 0, 0, 1 }, &.{ 0, 0 }, &.{ 0, 1, 2 }));
    // normals count mismatch
    try testing.expectError(error.InvalidInput, generate(alloc, &quad_positions, &.{ 0, 0, 1 }, &quad_uvs, &quad_indices));
    // uvs count mismatch
    try testing.expectError(error.InvalidInput, generate(alloc, &quad_positions, &quad_normals, &.{ 0, 0 }, &quad_indices));
    // indices.len % 3 != 0
    try testing.expectError(error.InvalidInput, generate(alloc, &quad_positions, &quad_normals, &quad_uvs, &.{ 0, 1 }));
    // out-of-range index
    try testing.expectError(error.InvalidInput, generate(alloc, &quad_positions, &quad_normals, &quad_uvs, &.{ 0, 1, 99 }));
}
