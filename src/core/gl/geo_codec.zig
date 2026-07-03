//! Verve-native geometry compression codec for `.vmesh` (index + vertex buffers).
//!
//! Verve owns both ends (build-time encode in `vmesh.packCompressed`, runtime
//! decode in `vmesh.Reader.initAlloc`), so the wire is NOT bit-compatible with
//! upstream meshoptimizer / Draco and needs no interop guarantee.
//!
//! - **Indices** (`encode/decodeIndices`): LOSSLESS delta + zigzag + LEB128
//!   varint of the u16 stream. Cache-optimized meshes have small consecutive
//!   deltas → ~1 byte each. Decoded bytes are byte-identical → a native
//!   round-trip golden is the definitive gate, no GPU verification needed.
//! - **Vertices** (`encode/decodeVertices`): LOSSY quantization — pos u16 over
//!   the mesh AABB, normal/tangent i8 snorm, uv u16 over the UV AABB (48 B → 17 B
//!   base). Gate = a within-epsilon round-trip PLUS a browser visual check.

const std = @import("std");

/// ZigZag-encode a signed delta into an unsigned magnitude (small |x| => small).
fn zigzag(n: i32) u32 {
    return @bitCast((n << 1) ^ (n >> 31));
}

fn unzigzag(u: u32) i32 {
    const s: i32 = @bitCast(u);
    return (s >> 1) ^ -(s & 1);
}

/// Append `v` as an unsigned LEB128 varint (7 bits/byte, high bit = continue).
fn putVarint(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u32) !void {
    var x = v;
    while (true) {
        const byte: u8 = @intCast(x & 0x7f);
        x >>= 7;
        if (x != 0) {
            try buf.append(alloc, byte | 0x80);
        } else {
            try buf.append(alloc, byte);
            break;
        }
    }
}

/// Read one unsigned LEB128 varint from `blob` at `*pos`, advancing `*pos`.
fn getVarint(blob: []const u8, pos: *usize) !u32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    while (true) {
        if (pos.* >= blob.len) return error.Truncated;
        const byte = blob[pos.*];
        pos.* += 1;
        result |= @as(u32, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) break;
        shift = std.math.add(u5, shift, 7) catch return error.Corrupt;
    }
    return result;
}

/// Encode a u16 index slice to a compressed byte blob. Caller owns the result.
pub fn encodeIndices(alloc: std.mem.Allocator, indices: []const u16) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    var prev: i32 = 0;
    for (indices) |idx| {
        const cur: i32 = idx;
        try putVarint(&buf, alloc, zigzag(cur - prev));
        prev = cur;
    }
    return buf.toOwnedSlice(alloc);
}

/// Decode a compressed blob back to `count` u16 indices. Caller owns the result.
pub fn decodeIndices(alloc: std.mem.Allocator, blob: []const u8, count: usize) ![]u16 {
    const out = try alloc.alloc(u16, count);
    errdefer alloc.free(out);
    var pos: usize = 0;
    var prev: i32 = 0;
    for (out) |*slot| {
        const cur = prev + unzigzag(try getVarint(blob, &pos));
        if (cur < 0 or cur > 65535) return error.Corrupt;
        slot.* = @intCast(cur);
        prev = cur;
    }
    return out;
}

fn expectRoundTrip(indices: []const u16) !void {
    const a = std.testing.allocator;
    const blob = try encodeIndices(a, indices);
    defer a.free(blob);
    const out = try decodeIndices(a, blob, indices.len);
    defer a.free(out);
    try std.testing.expectEqualSlices(u16, indices, out);
}

test "round-trip: empty" {
    try expectRoundTrip(&[_]u16{});
}

test "round-trip: single" {
    try expectRoundTrip(&[_]u16{7});
}

test "round-trip: sequential" {
    try expectRoundTrip(&[_]u16{ 0, 1, 2, 3, 4, 5 });
}

test "round-trip: repeated" {
    try expectRoundTrip(&[_]u16{ 5, 5, 5, 5 });
}

test "round-trip: random permutation" {
    try expectRoundTrip(&[_]u16{ 3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5 });
}

test "round-trip: u16 boundaries" {
    try expectRoundTrip(&[_]u16{ 0, 65535, 0, 65535, 32768, 1 });
}

test "round-trip: descending" {
    try expectRoundTrip(&[_]u16{ 100, 90, 80, 0, 65535 });
}

// ── Vertex quantization codec (lossy) ────────────────────────────────────────
//
// The GPU-uploadable base vertex is 48 B of f32 (stride, layout):
//   pos f32×3 @0, normal f32×3 @12, tangent f32×4 @24 (w = ±1 handedness),
//   uv f32×2 @40.
// Quantized to 17 B:
//   pos u16×3 over the mesh AABB, normal i8×3 snorm, tangent i8×3 snorm (xyz)
//   + tan_w i8 (±127 = handedness ±1), uv u16×2 over the UV AABB.
// Skinned meshes append the raw joints u8×4 + weights u8×4 (NOT quantized) → 25 B.
// Blob = [dequant header 40 B: pos_min f32×3, pos_ext f32×3, uv_min f32×2,
//   uv_ext f32×2][vertex_count × (17 | 25) B]. decodeVertices reconstructs the
// exact stride-48/56 f32(+u8) section that the raw pack path would have written.
//
// LOSSY (quantization rounding) → the native gate is a within-epsilon round-trip
// plus a browser visual check, NOT a byte-exact golden.

pub const vq_dequant_hdr: usize = 40; // 10 f32
pub const vq_quant_base: usize = 17; // per-vertex quantized base bytes
pub const vq_skin_extra: usize = 8; // joints u8×4 + weights u8×4 (raw)

fn quantU16(v: f32, min: f32, ext: f32) u16 {
    const t = (v - min) / ext; // ext already guarded != 0
    const s = std.math.clamp(t, 0.0, 1.0) * 65535.0;
    return @intFromFloat(@round(s));
}

fn dequantU16(q: u16, min: f32, ext: f32) f32 {
    return min + (@as(f32, @floatFromInt(q)) / 65535.0) * ext;
}

fn snormI8(v: f32) i8 {
    const s = std.math.clamp(v, -1.0, 1.0) * 127.0;
    return @intFromFloat(@round(s));
}

fn snormF32(b: i8) f32 {
    return @max(@as(f32, @floatFromInt(b)) / 127.0, -1.0);
}

/// Quantize a base-f32 vertex array (12 f32/vertex) + optional skin data into a
/// compressed blob. Caller owns the result.
pub fn encodeVertices(
    alloc: std.mem.Allocator,
    vertices: []const f32, // len % 12 == 0
    skinned: bool,
    joints: []const [4]u8,
    weights: []const [4]u8,
) ![]u8 {
    const vc = vertices.len / 12;
    // Position + UV AABB.
    var pmin = [3]f32{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) };
    var pmax = [3]f32{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
    var umin = [2]f32{ std.math.inf(f32), std.math.inf(f32) };
    var umax = [2]f32{ -std.math.inf(f32), -std.math.inf(f32) };
    for (0..vc) |v| {
        const f = vertices[v * 12 ..][0..12];
        inline for (0..3) |k| {
            pmin[k] = @min(pmin[k], f[k]);
            pmax[k] = @max(pmax[k], f[k]);
        }
        inline for (0..2) |k| {
            umin[k] = @min(umin[k], f[10 + k]);
            umax[k] = @max(umax[k], f[10 + k]);
        }
    }
    var pext: [3]f32 = undefined;
    var uext: [2]f32 = undefined;
    inline for (0..3) |k| pext[k] = if (pmax[k] > pmin[k]) pmax[k] - pmin[k] else 1.0;
    inline for (0..2) |k| uext[k] = if (umax[k] > umin[k]) umax[k] - umin[k] else 1.0;
    if (vc == 0) {
        inline for (0..3) |k| {
            pmin[k] = 0;
            pext[k] = 1;
        }
        inline for (0..2) |k| {
            umin[k] = 0;
            uext[k] = 1;
        }
    }

    const stride = vq_quant_base + if (skinned) vq_skin_extra else 0;
    const out = try alloc.alloc(u8, vq_dequant_hdr + vc * stride);
    errdefer alloc.free(out);
    inline for (0..3) |k| std.mem.writeInt(u32, out[k * 4 ..][0..4], @bitCast(pmin[k]), .little);
    inline for (0..3) |k| std.mem.writeInt(u32, out[12 + k * 4 ..][0..4], @bitCast(pext[k]), .little);
    inline for (0..2) |k| std.mem.writeInt(u32, out[24 + k * 4 ..][0..4], @bitCast(umin[k]), .little);
    inline for (0..2) |k| std.mem.writeInt(u32, out[32 + k * 4 ..][0..4], @bitCast(uext[k]), .little);

    for (0..vc) |v| {
        const f = vertices[v * 12 ..][0..12];
        const o = vq_dequant_hdr + v * stride;
        inline for (0..3) |k| std.mem.writeInt(u16, out[o + k * 2 ..][0..2], quantU16(f[k], pmin[k], pext[k]), .little);
        inline for (0..3) |k| std.mem.writeInt(i8, out[o + 6 + k ..][0..1], snormI8(f[3 + k]), .little);
        inline for (0..3) |k| std.mem.writeInt(i8, out[o + 9 + k ..][0..1], snormI8(f[6 + k]), .little);
        std.mem.writeInt(i8, out[o + 12 ..][0..1], if (f[9] >= 0) @as(i8, 127) else @as(i8, -127), .little);
        inline for (0..2) |k| std.mem.writeInt(u16, out[o + 13 + k * 2 ..][0..2], quantU16(f[10 + k], umin[k], uext[k]), .little);
        if (skinned) {
            @memcpy(out[o + 17 ..][0..4], &joints[v]);
            @memcpy(out[o + 21 ..][0..4], &weights[v]);
        }
    }
    return out;
}

/// Decode a quantized blob into the GPU-uploadable vertex section: stride-48 f32
/// (non-skinned) or stride-56 f32+u8 (skinned), matching the raw pack layout.
/// Returns `[]u32` (4-aligned) — downstream reads vertex positions as f32, so the
/// buffer must be ≥4-aligned (the raw path aliases the 16-aligned file section).
/// View the bytes with `std.mem.sliceAsBytes`. Caller owns + frees the []u32.
pub fn decodeVertices(alloc: std.mem.Allocator, blob: []const u8, vertex_count: usize, skinned: bool) ![]u32 {
    const qstride = vq_quant_base + if (skinned) vq_skin_extra else 0;
    if (blob.len < vq_dequant_hdr or blob.len - vq_dequant_hdr < vertex_count * qstride) return error.Truncated;
    var pmin: [3]f32 = undefined;
    var pext: [3]f32 = undefined;
    var umin: [2]f32 = undefined;
    var uext: [2]f32 = undefined;
    inline for (0..3) |k| pmin[k] = @bitCast(std.mem.readInt(u32, blob[k * 4 ..][0..4], .little));
    inline for (0..3) |k| pext[k] = @bitCast(std.mem.readInt(u32, blob[12 + k * 4 ..][0..4], .little));
    inline for (0..2) |k| umin[k] = @bitCast(std.mem.readInt(u32, blob[24 + k * 4 ..][0..4], .little));
    inline for (0..2) |k| uext[k] = @bitCast(std.mem.readInt(u32, blob[32 + k * 4 ..][0..4], .little));

    const ostride: usize = if (skinned) 56 else 48; // both divisible by 4
    const words = try alloc.alloc(u32, vertex_count * ostride / 4);
    errdefer alloc.free(words);
    const out = std.mem.sliceAsBytes(words);
    for (0..vertex_count) |v| {
        const i = vq_dequant_hdr + v * qstride;
        const o = v * ostride;
        inline for (0..3) |k| {
            const q = std.mem.readInt(u16, blob[i + k * 2 ..][0..2], .little);
            std.mem.writeInt(u32, out[o + k * 4 ..][0..4], @bitCast(dequantU16(q, pmin[k], pext[k])), .little);
        }
        inline for (0..3) |k| std.mem.writeInt(u32, out[o + 12 + k * 4 ..][0..4], @bitCast(snormF32(@bitCast(blob[i + 6 + k]))), .little);
        inline for (0..3) |k| std.mem.writeInt(u32, out[o + 24 + k * 4 ..][0..4], @bitCast(snormF32(@bitCast(blob[i + 9 + k]))), .little);
        const wsign: i8 = @bitCast(blob[i + 12]);
        std.mem.writeInt(u32, out[o + 36 ..][0..4], @bitCast(@as(f32, if (wsign >= 0) 1.0 else -1.0)), .little);
        inline for (0..2) |k| {
            const q = std.mem.readInt(u16, blob[i + 13 + k * 2 ..][0..2], .little);
            std.mem.writeInt(u32, out[o + 40 + k * 4 ..][0..4], @bitCast(dequantU16(q, umin[k], uext[k])), .little);
        }
        if (skinned) {
            @memcpy(out[o + 48 ..][0..4], blob[i + 17 ..][0..4]);
            @memcpy(out[o + 52 ..][0..4], blob[i + 21 ..][0..4]);
        }
    }
    return words;
}

fn expectVertRoundTrip(vertices: []const f32, skinned: bool, joints: []const [4]u8, weights: []const [4]u8) !void {
    const a = std.testing.allocator;
    const blob = try encodeVertices(a, vertices, skinned, joints, weights);
    defer a.free(blob);
    const vc = vertices.len / 12;
    const words = try decodeVertices(a, blob, vc, skinned);
    defer a.free(words);
    const out = std.mem.sliceAsBytes(words);
    const ostride: usize = if (skinned) 56 else 48;
    // AABB extents drive position/uv tolerance (2 quantization steps).
    var pmax = [3]f32{ 0, 0, 0 };
    for (0..vc) |v| inline for (0..3) |k| {
        pmax[k] = @max(pmax[k], @abs(vertices[v * 12 + k]));
    };
    for (0..vc) |v| {
        const f = vertices[v * 12 ..][0..12];
        const of = std.mem.bytesAsSlice(f32, out[v * ostride ..][0..48]);
        inline for (0..3) |k| try std.testing.expect(@abs(of[k] - f[k]) <= (2.0 * pmax[k] + 1.0) / 65535.0 + 1e-5);
        inline for (3..9) |k| try std.testing.expect(@abs(of[k] - f[k]) <= 2.0 / 127.0 + 1e-4); // normal + tangent xyz
        try std.testing.expectEqual(f[9], of[9]); // tangent w = exact ±1
        inline for (10..12) |k| try std.testing.expect(@abs(of[k] - f[k]) <= 2.0 / 65535.0 + 1e-4);
        if (skinned) {
            try std.testing.expectEqualSlices(u8, &joints[v], out[v * ostride + 48 ..][0..4]);
            try std.testing.expectEqualSlices(u8, &weights[v], out[v * ostride + 52 ..][0..4]);
        }
    }
}

test "vertex codec: non-skinned round-trip within epsilon" {
    const verts = [_]f32{
        // pos            normal      tangent(w=1)    uv
        0.0,  0.0,  0.0, 0, 0, 1, 1, 0, 0, 1,  0.0,  0.0,
        1.5,  -2.0, 3.0, 1, 0, 0, 0, 1, 0, -1, 0.25, 0.75,
        -4.0, 2.5,  0.5, 0, 1, 0, 0, 0, 1, 1,  1.0,  0.5,
    };
    try expectVertRoundTrip(&verts, false, &.{}, &.{});
}

test "vertex codec: skinned round-trip preserves joints/weights exactly" {
    const verts = [_]f32{
        0.0, 0.0, 0.0, 0, 0, 1, 1, 0, 0, 1, 0.0, 0.0,
        2.0, 1.0, 0.0, 0, 1, 0, 1, 0, 0, 1, 1.0, 1.0,
    };
    const joints = [_][4]u8{ .{ 0, 1, 2, 3 }, .{ 4, 0, 0, 0 } };
    const weights = [_][4]u8{ .{ 255, 0, 0, 0 }, .{ 128, 127, 0, 0 } };
    try expectVertRoundTrip(&verts, true, &joints, &weights);
}

test "vertex codec: degenerate (zero-extent axis) does not divide by zero" {
    // All verts share x=5 (flat plane) → pext[0] guarded to 1, decodes to 5.
    const verts = [_]f32{
        5.0, 0.0, 0.0, 0, 0, 1, 1, 0, 0, 1, 0.0, 0.0,
        5.0, 1.0, 0.0, 0, 0, 1, 1, 0, 0, 1, 0.0, 0.0,
    };
    try expectVertRoundTrip(&verts, false, &.{}, &.{});
}

test "vertex codec: shrinks the vertex section" {
    const verts = [_]f32{0} ** (12 * 100); // 100 verts × 48 B = 4800 raw
    const blob = try encodeVertices(std.testing.allocator, &verts, false, &.{}, &.{});
    defer std.testing.allocator.free(blob);
    // 40 B header + 100 × 17 B = 1740 vs 4800 raw.
    try std.testing.expect(blob.len < verts.len / 12 * 48);
}

// ── GPU-resident quantized vertex codec (slice 3, half-float + snorm8) ────────
//
// DISTINCT from the u16/AABB `encodeVertices` blob above (which decodes back to
// full f32 host-side — a disk-only win). This encoding is uploaded to the GPU
// VERBATIM and the fixed-function vertex-fetch hardware converts it to float for
// free — NO vertex-shader dequant, NO UBO uniforms (so it dodges the PBR-UBO
// offset-sync trap entirely). GPU stride 20 B (non-skinned) / 28 B (skinned) vs
// 48/56 f32 → ~58% VRAM + upload-bandwidth win.
//
//   pos     float16x4 @0  (8 B; xyz + pad w=0, GPU reads as vec3 float)
//   normal  snorm8x4  @8  (4 B; xyz + pad w=0, snorm8 ±127 → [-1,1])
//   tangent snorm8x4  @12 (4 B; xyz + w = ±127 handedness → ±1)
//   uv      float16x2 @16 (4 B)
//   skinned: joints uint8x4 @20 (4 B) + weights unorm8x4 @24 (4 B) → stride 28
//
// Half precision (~2^-10 relative) suits normalized-scale meshes; worse than
// u16-over-AABB for very large meshes → an acceptable medium quant. There is NO
// on-disk dequant header (unlike `encodeVertices`): the GPU formats are
// self-describing. Native gate = an f32→half→f32 round-trip within epsilon plus
// a browser (WebGL2 CDP + WebGPU) visual check of the actual GPU vertex fetch.

pub const vgpu_stride: usize = 20; // non-skinned GPU vertex stride
pub const vgpu_skin_stride: usize = 28; // skinned GPU vertex stride

/// Encode an f32 (IEEE-754 binary32) to a half (binary16). Round-to-nearest-even
/// on the normal path; subnormal-half magnitudes are flushed to signed zero;
/// overflow / ±inf → ±inf; NaN → a quiet NaN. Mesh attributes never hit the
/// subnormal range meaningfully, so the flush is loss-free in practice.
pub fn f32ToHalf(f: f32) u16 {
    const x: u32 = @bitCast(f);
    const sign: u16 = @intCast((x >> 16) & 0x8000);
    const biased: u32 = (x >> 23) & 0xff;
    const mant: u32 = x & 0x7fffff;
    if (biased == 0xff) return sign | (if (mant != 0) @as(u16, 0x7e00) else 0x7c00); // NaN / Inf
    const exp: i32 = @as(i32, @intCast(biased)) - 127 + 15;
    if (exp >= 0x1f) return sign | 0x7c00; // overflow → Inf
    if (exp <= 0) return sign; // subnormal-half or underflow → signed zero
    // Normal: 5-bit exp + top 10 mantissa bits, round-to-nearest-even on the 13
    // dropped bits. A rounding carry into the exponent propagates correctly (and
    // an all-ones mantissa carrying to exp 0x1f yields Inf, the desired overflow).
    var h: u16 = @intCast((@as(u32, @intCast(exp)) << 10) | (mant >> 13));
    const dropped: u32 = mant & 0x1fff;
    if (dropped > 0x1000 or (dropped == 0x1000 and (h & 1) == 1)) h +%= 1;
    return sign | h;
}

/// Decode a half (binary16) back to f32. Inverse of `f32ToHalf` for the values
/// it produces (subnormal halves are handled too, for completeness).
pub fn halfToF32(h: u16) f32 {
    const sign: u32 = @as(u32, h & 0x8000) << 16;
    const exp: u32 = (h >> 10) & 0x1f;
    const mant: u32 = h & 0x3ff;
    if (exp == 0) {
        if (mant == 0) return @bitCast(sign); // ±0
        // Subnormal half → normalized f32: shift the leading 1 out of the mantissa.
        var m = mant;
        var e: u32 = 0;
        while (m & 0x400 == 0) {
            m <<= 1;
            e += 1;
        }
        const fe: u32 = 127 - 15 - e + 1;
        return @bitCast(sign | (fe << 23) | ((m & 0x3ff) << 13));
    }
    if (exp == 0x1f) return @bitCast(sign | 0x7f800000 | (mant << 13)); // Inf / NaN
    const fe: u32 = @intCast(@as(i32, @intCast(exp)) - 15 + 127);
    return @bitCast(sign | (fe << 23) | (mant << 13));
}

/// Encode a base-f32 vertex array (12 f32/vertex) + optional skin data into the
/// GPU-ready half/snorm8 interleaved blob (stride 20 / 28). Uploaded verbatim;
/// the GPU vertex fetch converts each attribute to float. Caller owns the result.
pub fn encodeVerticesGpu(
    alloc: std.mem.Allocator,
    vertices: []const f32, // len % 12 == 0
    skinned: bool,
    joints: []const [4]u8,
    weights: []const [4]u8,
) ![]u8 {
    const vc = vertices.len / 12;
    const stride = if (skinned) vgpu_skin_stride else vgpu_stride;
    const out = try alloc.alloc(u8, vc * stride);
    errdefer alloc.free(out);
    for (0..vc) |v| {
        const f = vertices[v * 12 ..][0..12];
        const o = v * stride;
        inline for (0..3) |k| std.mem.writeInt(u16, out[o + k * 2 ..][0..2], f32ToHalf(f[k]), .little);
        std.mem.writeInt(u16, out[o + 6 ..][0..2], 0, .little); // pos.w pad
        inline for (0..3) |k| std.mem.writeInt(i8, out[o + 8 + k ..][0..1], snormI8(f[3 + k]), .little);
        std.mem.writeInt(i8, out[o + 11 ..][0..1], 0, .little); // normal.w pad
        inline for (0..3) |k| std.mem.writeInt(i8, out[o + 12 + k ..][0..1], snormI8(f[6 + k]), .little);
        std.mem.writeInt(i8, out[o + 15 ..][0..1], if (f[9] >= 0) @as(i8, 127) else @as(i8, -127), .little);
        inline for (0..2) |k| std.mem.writeInt(u16, out[o + 16 + k * 2 ..][0..2], f32ToHalf(f[10 + k]), .little);
        if (skinned) {
            @memcpy(out[o + 20 ..][0..4], &joints[v]);
            @memcpy(out[o + 24 ..][0..4], &weights[v]);
        }
    }
    return out;
}

/// Decode positions (only) from a GPU-quantized blob into an f32 xyz array,
/// `vertex_count * 3` floats. The host-side pick/BVH raycast reads float
/// positions the GPU-format vertex buffer no longer exposes to Zig, so the
/// Reader keeps this alongside the upload blob. Caller owns the result.
pub fn decodeGpuPositions(alloc: std.mem.Allocator, blob: []const u8, vertex_count: usize, skinned: bool) ![]f32 {
    const stride = if (skinned) vgpu_skin_stride else vgpu_stride;
    if (blob.len < vertex_count * stride) return error.Truncated;
    const out = try alloc.alloc(f32, vertex_count * 3);
    errdefer alloc.free(out);
    for (0..vertex_count) |v| {
        const o = v * stride;
        inline for (0..3) |k| out[v * 3 + k] = halfToF32(std.mem.readInt(u16, blob[o + k * 2 ..][0..2], .little));
    }
    return out;
}

test "half round-trip: representative values within relative epsilon" {
    const cases = [_]f32{ 0.0, 1.0, -1.0, 0.5, -0.25, 2.0, 100.0, -3.14159, 0.001, 65504.0 };
    for (cases) |c| {
        const back = halfToF32(f32ToHalf(c));
        if (c == 0.0) {
            try std.testing.expectEqual(@as(f32, 0.0), back);
        } else {
            try std.testing.expect(@abs(back - c) <= @abs(c) * (1.0 / 1024.0) + 1e-6);
        }
    }
}

test "half: signed zero, inf, overflow, NaN" {
    try std.testing.expectEqual(@as(u16, 0x0000), f32ToHalf(0.0));
    try std.testing.expectEqual(@as(u16, 0x8000), f32ToHalf(-0.0));
    try std.testing.expectEqual(@as(u16, 0x7c00), f32ToHalf(std.math.inf(f32)));
    try std.testing.expectEqual(@as(u16, 0xfc00), f32ToHalf(-std.math.inf(f32)));
    try std.testing.expectEqual(@as(u16, 0x7c00), f32ToHalf(1.0e30)); // overflow → Inf
    try std.testing.expect(std.math.isNan(halfToF32(f32ToHalf(std.math.nan(f32)))));
    try std.testing.expect(std.math.isInf(halfToF32(0x7c00)));
}

fn expectGpuRoundTrip(vertices: []const f32, skinned: bool, joints: []const [4]u8, weights: []const [4]u8) !void {
    const a = std.testing.allocator;
    const blob = try encodeVerticesGpu(a, vertices, skinned, joints, weights);
    defer a.free(blob);
    const vc = vertices.len / 12;
    const stride = if (skinned) vgpu_skin_stride else vgpu_stride;
    try std.testing.expectEqual(vc * stride, blob.len);
    // Decode every attribute the way the GPU vertex fetch would and compare.
    for (0..vc) |v| {
        const f = vertices[v * 12 ..][0..12];
        const o = v * stride;
        inline for (0..3) |k| { // pos: half
            const got = halfToF32(std.mem.readInt(u16, blob[o + k * 2 ..][0..2], .little));
            try std.testing.expect(@abs(got - f[k]) <= @abs(f[k]) * (1.0 / 1024.0) + 1e-4);
        }
        inline for (0..3) |k| { // normal: snorm8
            const got = snormF32(@bitCast(blob[o + 8 + k]));
            try std.testing.expect(@abs(got - f[3 + k]) <= 1.0 / 127.0 + 1e-4);
        }
        inline for (0..3) |k| { // tangent xyz: snorm8
            const got = snormF32(@bitCast(blob[o + 12 + k]));
            try std.testing.expect(@abs(got - f[6 + k]) <= 1.0 / 127.0 + 1e-4);
        }
        const tw: i8 = @bitCast(blob[o + 15]); // tangent w handedness → exact ±1
        try std.testing.expectEqual(f[9] >= 0, tw >= 0);
        inline for (0..2) |k| { // uv: half
            const got = halfToF32(std.mem.readInt(u16, blob[o + 16 + k * 2 ..][0..2], .little));
            try std.testing.expect(@abs(got - f[10 + k]) <= @abs(f[10 + k]) * (1.0 / 1024.0) + 1e-4);
        }
        if (skinned) {
            try std.testing.expectEqualSlices(u8, &joints[v], blob[o + 20 ..][0..4]);
            try std.testing.expectEqualSlices(u8, &weights[v], blob[o + 24 ..][0..4]);
        }
    }
    // Position-only decode (pick path) matches the in-blob half positions.
    const pos = try decodeGpuPositions(a, blob, vc, skinned);
    defer a.free(pos);
    try std.testing.expectEqual(vc * 3, pos.len);
    for (0..vc) |v| inline for (0..3) |k| {
        const f = vertices[v * 12 ..][0..12];
        try std.testing.expect(@abs(pos[v * 3 + k] - f[k]) <= @abs(f[k]) * (1.0 / 1024.0) + 1e-4);
    };
}

test "gpu vertex codec: non-skinned round-trip within epsilon" {
    const verts = [_]f32{
        0.0,  0.0,  0.0, 0, 0, 1, 1, 0, 0, 1,  0.0,  0.0,
        1.5,  -2.0, 3.0, 1, 0, 0, 0, 1, 0, -1, 0.25, 0.75,
        -4.0, 2.5,  0.5, 0, 1, 0, 0, 0, 1, 1,  1.0,  0.5,
    };
    try expectGpuRoundTrip(&verts, false, &.{}, &.{});
}

test "gpu vertex codec: skinned round-trip preserves joints/weights exactly" {
    const verts = [_]f32{
        0.0, 0.0, 0.0, 0, 0, 1, 1, 0, 0, 1, 0.0, 0.0,
        2.0, 1.0, 0.0, 0, 1, 0, 1, 0, 0, 1, 1.0, 1.0,
    };
    const joints = [_][4]u8{ .{ 0, 1, 2, 3 }, .{ 4, 0, 0, 0 } };
    const weights = [_][4]u8{ .{ 255, 0, 0, 0 }, .{ 128, 127, 0, 0 } };
    try expectGpuRoundTrip(&verts, true, &joints, &weights);
}

test "gpu vertex codec: stride is 20 non-skinned / 28 skinned" {
    const a = std.testing.allocator;
    const verts = [_]f32{0} ** (12 * 10);
    const b0 = try encodeVerticesGpu(a, &verts, false, &.{}, &.{});
    defer a.free(b0);
    try std.testing.expectEqual(@as(usize, 200), b0.len); // 10 × 20
    const joints = [_][4]u8{.{ 0, 0, 0, 0 }} ** 10;
    const weights = [_][4]u8{.{ 255, 0, 0, 0 }} ** 10;
    const b1 = try encodeVerticesGpu(a, &verts, true, &joints, &weights);
    defer a.free(b1);
    try std.testing.expectEqual(@as(usize, 280), b1.len); // 10 × 28
}
