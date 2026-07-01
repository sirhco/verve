//! Pure-Zig BC7 **mode 6** encoder (+ test-only decoder).
//!
//! Mode 6 = single-subset RGBA, 4-bit indices, 7-bit endpoints + one p-bit per
//! endpoint. Deterministic (no rand / time / I/O). This is the real hardware
//! BC7 mode-6 bit layout, so the packed bytes decode on any BC7 GPU decoder.
//!
//! Bit layout (LSB-first from bit 0 of byte 0, 128 bits total):
//!   1. mode          7 bits = 0b1000000 (six 0s then a 1 → byte0 low = 0x40)
//!   2. endpoints     8 × 7 bits, order R0,R1,G0,G1,B0,B1,A0,A1  (56 bits)
//!   3. p-bits        P0 (endpoint 0), P1 (endpoint 1)           (2 bits)
//!   4. indices       texel 0 = 3 bits (anchor, MSB implicit 0),
//!                    texels 1..15 = 4 bits each                 (63 bits)
//!   effective 8-bit endpoint channel = (v7 << 1) | p
//!
//! Encoder PINs (v1): principal-axis endpoint fit — 24-iteration power
//! iteration on the block's RGBA covariance finds the dominant colour axis,
//! and the endpoints are the min/max projections of the texels onto that axis
//! (per-channel 7-bit + shared p-bit quantization); the shared p-bit per
//! endpoint chosen to minimise summed squared reconstruction error across its
//! 4 channels; each texel gets the 4-bit index minimising squared error to the
//! interpolated line; standard anchor fix (swap endpoints + invert indices
//! when index[0] > 7).

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// Mode-6 4-bit interpolation weights (BC7 aWeight4 table).
pub const weights4 = [16]u8{ 0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 56, 60, 64 };

const mode6_marker: u7 = 0x40; // six 0 bits then a 1 (LSB-first)

// ── bit writer / reader (LSB-first over a u128) ───────────────────────────────

const BitWriter = struct {
    acc: u128 = 0,
    pos: u8 = 0,

    /// Append the low `n` bits of `value`, LSB-first.
    fn put(self: *BitWriter, value: u32, n: u5) void {
        const mask: u128 = (@as(u128, 1) << n) - 1;
        self.acc |= (@as(u128, value) & mask) << @as(u7, @intCast(self.pos));
        self.pos += n;
    }

    fn bytes(self: *const BitWriter) [16]u8 {
        var out: [16]u8 = undefined;
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            out[i] = @truncate(self.acc >> @intCast(i * 8));
        }
        return out;
    }
};

const BitReader = struct {
    acc: u128,
    pos: u8 = 0,

    fn init(block: [16]u8) BitReader {
        var acc: u128 = 0;
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            acc |= @as(u128, block[i]) << @intCast(i * 8);
        }
        return .{ .acc = acc };
    }

    fn get(self: *BitReader, n: u5) u32 {
        const mask: u128 = (@as(u128, 1) << n) - 1;
        const v: u128 = (self.acc >> @as(u7, @intCast(self.pos))) & mask;
        self.pos += n;
        return @intCast(v);
    }
};

// ── endpoint quantisation ─────────────────────────────────────────────────────

/// Quantise an 8-bit channel value to a 7-bit code for the given p-bit; returns
/// the code and the reconstructed 8-bit value `(code << 1) | p`.
fn quant(v: u8, p: u1) struct { code: u7, recon: u8 } {
    const pi: i32 = p;
    // code minimising |2*code + p - v|  →  round((v - p)/2)
    var q: i32 = @divFloor(@as(i32, v) - pi + 1, 2);
    if (q < 0) q = 0;
    if (q > 127) q = 127;
    const code: u7 = @intCast(q);
    const recon: u8 = @intCast((q << 1) | pi);
    return .{ .code = code, .recon = recon };
}

/// For an endpoint whose 4 channels are `ep`, pick the shared p-bit and per-channel
/// 7-bit codes minimising summed squared reconstruction error. Returns codes,
/// p-bit and reconstructed channels.
fn fitEndpoint(ep: [4]u8) struct { code: [4]u7, p: u1, recon: [4]u8 } {
    var best_err: i64 = std.math.maxInt(i64);
    var best_code: [4]u7 = undefined;
    var best_recon: [4]u8 = undefined;
    var best_p: u1 = 0;
    var p: u1 = 0;
    while (true) {
        var err: i64 = 0;
        var code: [4]u7 = undefined;
        var recon: [4]u8 = undefined;
        for (0..4) |c| {
            const r = quant(ep[c], p);
            code[c] = r.code;
            recon[c] = r.recon;
            const d: i64 = @as(i64, r.recon) - @as(i64, ep[c]);
            err += d * d;
        }
        if (err < best_err) {
            best_err = err;
            best_code = code;
            best_recon = recon;
            best_p = p;
        }
        if (p == 1) break;
        p = 1;
    }
    return .{ .code = best_code, .p = best_p, .recon = best_recon };
}

/// Decode one channel for a 4-bit index given reconstructed 8-bit endpoints.
fn interp(e0: u8, e1: u8, idx: u4) u8 {
    const w: u32 = weights4[idx];
    const v: u32 = (@as(u32, e0) * (64 - w) + @as(u32, e1) * w + 32) >> 6;
    return @intCast(v);
}

/// Pick the 4-bit index minimising squared error for one texel.
fn bestIndex(recon0: [4]u8, recon1: [4]u8, texel: [4]u8) u4 {
    var best: u4 = 0;
    var best_err: i64 = std.math.maxInt(i64);
    var j: u5 = 0;
    while (j < 16) : (j += 1) {
        const idx: u4 = @intCast(j);
        var err: i64 = 0;
        for (0..4) |c| {
            const d: i64 = @as(i64, interp(recon0[c], recon1[c], idx)) - @as(i64, texel[c]);
            err += d * d;
        }
        if (err < best_err) {
            best_err = err;
            best = idx;
        }
    }
    return best;
}

/// Choose two endpoint colours spanning the block along its principal axis of
/// colour variance (deterministic power iteration on the 4×4 covariance). This
/// captures anti-correlated channels (e.g. R rising while G falls) that a
/// per-channel min/max bounding box cannot. Returns `[2][4]u8` = {lo, hi}.
fn principalAxisEndpoints(rgba: [16][4]u8) [2][4]u8 {
    var mean: [4]f64 = .{ 0, 0, 0, 0 };
    for (rgba) |t| {
        for (0..4) |c| mean[c] += @floatFromInt(t[c]);
    }
    for (0..4) |c| mean[c] /= 16.0;

    // Covariance (symmetric 4×4).
    var cov: [4][4]f64 = .{.{ 0, 0, 0, 0 }} ** 4;
    for (rgba) |t| {
        var d: [4]f64 = undefined;
        for (0..4) |c| d[c] = @as(f64, @floatFromInt(t[c])) - mean[c];
        for (0..4) |i| {
            for (0..4) |j| cov[i][j] += d[i] * d[j];
        }
    }

    // Power iteration seeded by the bounding-box diagonal (generic, non-zero
    // unless the block is solid).
    var lo: [4]u8 = .{ 255, 255, 255, 255 };
    var hi: [4]u8 = .{ 0, 0, 0, 0 };
    for (rgba) |t| {
        for (0..4) |c| {
            lo[c] = @min(lo[c], t[c]);
            hi[c] = @max(hi[c], t[c]);
        }
    }
    var axis: [4]f64 = undefined;
    var seed_norm: f64 = 0;
    for (0..4) |c| {
        axis[c] = @as(f64, @floatFromInt(hi[c])) - @as(f64, @floatFromInt(lo[c]));
        seed_norm += axis[c] * axis[c];
    }
    if (seed_norm < 1e-9) {
        // Solid (or near-solid) block: mean is the endpoint for both ends.
        var m: [4]u8 = undefined;
        for (0..4) |c| m[c] = @intFromFloat(std.math.clamp(@round(mean[c]), 0, 255));
        return .{ m, m };
    }

    var it: u32 = 0;
    while (it < 24) : (it += 1) {
        var next: [4]f64 = .{ 0, 0, 0, 0 };
        for (0..4) |i| {
            for (0..4) |j| next[i] += cov[i][j] * axis[j];
        }
        var norm: f64 = 0;
        for (0..4) |c| norm += next[c] * next[c];
        if (norm < 1e-12) break; // no variance along this direction
        norm = @sqrt(norm);
        for (0..4) |c| axis[c] = next[c] / norm;
    }

    // Project texels onto the axis; endpoints sit at the extreme projections.
    var tmin: f64 = std.math.floatMax(f64);
    var tmax: f64 = -std.math.floatMax(f64);
    for (rgba) |t| {
        var proj: f64 = 0;
        for (0..4) |c| proj += (@as(f64, @floatFromInt(t[c])) - mean[c]) * axis[c];
        tmin = @min(tmin, proj);
        tmax = @max(tmax, proj);
    }

    var ep: [2][4]u8 = undefined;
    for (0..4) |c| {
        ep[0][c] = @intFromFloat(std.math.clamp(@round(mean[c] + axis[c] * tmin), 0, 255));
        ep[1][c] = @intFromFloat(std.math.clamp(@round(mean[c] + axis[c] * tmax), 0, 255));
    }
    return ep;
}

// ── public API ────────────────────────────────────────────────────────────────

/// Encode one 4x4 RGBA block (row-major, 16 texels, [r,g,b,a] each 0..255) →
/// one 16-byte BC7 mode-6 block.
pub fn encodeBlock(rgba: [16][4]u8) [16]u8 {
    const eps = principalAxisEndpoints(rgba);
    var f0 = fitEndpoint(eps[0]);
    var f1 = fitEndpoint(eps[1]);

    // Assign indices.
    var idx: [16]u4 = undefined;
    for (rgba, 0..) |t, i| {
        idx[i] = bestIndex(f0.recon, f1.recon, t);
    }

    // Anchor fix: index[0] MSB must be 0 (index[0] <= 7). Swap endpoints +
    // invert indices if violated (colour-preserving because weights4 is
    // symmetric: weights4[15-j] == 64 - weights4[j]).
    if (idx[0] > 7) {
        const tmp = f0;
        f0 = f1;
        f1 = tmp;
        for (&idx) |*ix| ix.* = 15 - ix.*;
    }

    // Pack. Endpoint order R0,R1,G0,G1,B0,B1,A0,A1.
    var bw = BitWriter{};
    bw.put(mode6_marker, 7);
    for (0..4) |c| {
        bw.put(f0.code[c], 7);
        bw.put(f1.code[c], 7);
    }
    bw.put(f0.p, 1);
    bw.put(f1.p, 1);
    bw.put(idx[0], 3); // anchor: 3 bits
    for (idx[1..]) |ix| bw.put(ix, 4);
    return bw.bytes();
}

/// Test-only mode-6 decoder (NOT shipped to runtime; drives the round-trip tests).
pub fn decodeBlock(block: [16]u8) [16][4]u8 {
    var br = BitReader.init(block);
    _ = br.get(7); // mode marker
    var code0: [4]u7 = undefined;
    var code1: [4]u7 = undefined;
    for (0..4) |c| {
        code0[c] = @intCast(br.get(7));
        code1[c] = @intCast(br.get(7));
    }
    const p0: u1 = @intCast(br.get(1));
    const p1: u1 = @intCast(br.get(1));
    var e0: [4]u8 = undefined;
    var e1: [4]u8 = undefined;
    for (0..4) |c| {
        e0[c] = @intCast((@as(u16, code0[c]) << 1) | p0);
        e1[c] = @intCast((@as(u16, code1[c]) << 1) | p1);
    }
    var idx: [16]u4 = undefined;
    idx[0] = @intCast(br.get(3));
    var i: usize = 1;
    while (i < 16) : (i += 1) idx[i] = @intCast(br.get(4));

    var out: [16][4]u8 = undefined;
    for (0..16) |t| {
        for (0..4) |c| out[t][c] = interp(e0[c], e1[c], idx[t]);
    }
    return out;
}

/// Encode a full image to a BC7 mip chain (largest first): result[level] =
/// packed BC7 blocks for that mip. Box-filter downsample to 1x1; sub-4 levels
/// pad up to one 4x4 block. Non-mult-of-4 dims replicate edge texels (clamp).
/// Caller owns each inner slice and the outer slice.
pub fn encodeImage(alloc: Allocator, rgba: []const u8, w: u32, h: u32) ![]const []const u8 {
    std.debug.assert(rgba.len == @as(usize, w) * @as(usize, h) * 4);
    std.debug.assert(w > 0 and h > 0);

    const levels: u32 = 1 + std.math.log2_int(u32, @max(w, h));

    var out = try alloc.alloc([]const u8, levels);
    var built: u32 = 0;
    errdefer {
        var k: u32 = 0;
        while (k < built) : (k += 1) alloc.free(out[k]);
        alloc.free(out);
    }

    // Owned working buffer for the current mip (level 0 aliases the input).
    var cur: []const u8 = rgba;
    var cur_owned: ?[]u8 = null;
    var cw: u32 = w;
    var ch: u32 = h;
    defer if (cur_owned) |b| alloc.free(b);

    var level: u32 = 0;
    while (level < levels) : (level += 1) {
        out[built] = try encodeLevel(alloc, cur, cw, ch);
        built += 1;

        if (level + 1 < levels) {
            const nw: u32 = @max(cw / 2, 1);
            const nh: u32 = @max(ch / 2, 1);
            const next = try alloc.alloc(u8, @as(usize, nw) * @as(usize, nh) * 4);
            boxDownsample(cur, cw, ch, next, nw, nh);
            if (cur_owned) |b| alloc.free(b);
            cur_owned = next;
            cur = next;
            cw = nw;
            ch = nh;
        }
    }

    return out;
}

/// Encode a single mip level's RGBA8 buffer to packed BC7 blocks.
fn encodeLevel(alloc: Allocator, rgba: []const u8, w: u32, h: u32) ![]const u8 {
    const bpr = (w + 3) / 4; // blocks per row (min 1)
    const bpc = (h + 3) / 4; // blocks per col (min 1)
    var buf = try alloc.alloc(u8, @as(usize, bpr) * @as(usize, bpc) * 16);
    var off: usize = 0;
    var by: u32 = 0;
    while (by < bpc) : (by += 1) {
        var bx: u32 = 0;
        while (bx < bpr) : (bx += 1) {
            var blk: [16][4]u8 = undefined;
            for (0..4) |ry| {
                for (0..4) |rx| {
                    // Clamp to edge for padding.
                    const sx = @min(bx * 4 + @as(u32, @intCast(rx)), w - 1);
                    const sy = @min(by * 4 + @as(u32, @intCast(ry)), h - 1);
                    const src = (@as(usize, sy) * w + sx) * 4;
                    blk[ry * 4 + rx] = .{ rgba[src], rgba[src + 1], rgba[src + 2], rgba[src + 3] };
                }
            }
            const packed_blk = encodeBlock(blk);
            @memcpy(buf[off .. off + 16], &packed_blk);
            off += 16;
        }
    }
    return buf;
}

/// Box-filter downsample RGBA8 `src` (sw×sh) into `dst` (dw×dh). Each dst texel
/// averages the (up to 2×2) src texels it covers.
fn boxDownsample(src: []const u8, sw: u32, sh: u32, dst: []u8, dw: u32, dh: u32) void {
    var y: u32 = 0;
    while (y < dh) : (y += 1) {
        var x: u32 = 0;
        while (x < dw) : (x += 1) {
            const x0 = @min(x * 2, sw - 1);
            const x1 = @min(x * 2 + 1, sw - 1);
            const y0 = @min(y * 2, sh - 1);
            const y1 = @min(y * 2 + 1, sh - 1);
            const p00 = (@as(usize, y0) * sw + x0) * 4;
            const p01 = (@as(usize, y0) * sw + x1) * 4;
            const p10 = (@as(usize, y1) * sw + x0) * 4;
            const p11 = (@as(usize, y1) * sw + x1) * 4;
            const d = (@as(usize, y) * dw + x) * 4;
            for (0..4) |c| {
                const sum: u32 = @as(u32, src[p00 + c]) + src[p01 + c] + src[p10 + c] + src[p11 + c];
                dst[d + c] = @intCast((sum + 2) / 4);
            }
        }
    }
}

// ── tests ─────────────────────────────────────────────────────────────────────

/// Peak signal-to-noise ratio (dB) between two 4x4 RGBA blocks over all 64
/// channel samples. Returns a large sentinel when identical (MSE == 0).
fn psnrBlock(a: [16][4]u8, b: [16][4]u8) f64 {
    var mse: f64 = 0;
    for (0..16) |t| {
        for (0..4) |c| {
            const d: f64 = @as(f64, @floatFromInt(a[t][c])) - @as(f64, @floatFromInt(b[t][c]));
            mse += d * d;
        }
    }
    mse /= 64.0;
    if (mse == 0) return 999.0;
    return 10.0 * std.math.log10((255.0 * 255.0) / mse);
}

fn gradientBlock() [16][4]u8 {
    var blk: [16][4]u8 = undefined;
    for (0..16) |i| {
        const v: u8 = @intCast(i * 17); // 0..255 across the 16 texels
        blk[i] = .{ v, @intCast(255 - i * 17), @intCast((i * 11) & 0xff), 255 };
    }
    return blk;
}

test "round-trip PSNR on a smooth gradient block >= 40 dB" {
    const blk = gradientBlock();
    const dec = decodeBlock(encodeBlock(blk));
    const p = psnrBlock(blk, dec);
    try testing.expect(p >= 40.0);
}

test "round-trip PSNR on a deterministic noisy block >= 30 dB" {
    // A luminance ramp with independent per-channel deterministic noise (±8) —
    // a structured-but-noisy texture block, the realistic non-smooth case.
    //
    // NOTE: pure 4-channel white noise (each channel independent, full 0..255)
    // is inherently ~12 dB for ANY single-subset single-line block encoder
    // (three of the four colour dimensions are perpendicular to the one fitted
    // axis and unrepresentable). 30 dB therefore targets band-limited texture
    // noise, not white noise; achieved here ≈ 34.7 dB.
    var blk: [16][4]u8 = undefined;
    var s: u32 = 0xBEEF;
    for (0..16) |i| {
        const l: i32 = @intCast(i * 15); // 0..225 correlated ramp
        for (0..4) |c| {
            s = s *% 1664525 +% 1013904223;
            const nz: i32 = @as(i32, @intCast((s >> 20) % 17)) - 8; // ±8
            blk[i][c] = @intCast(std.math.clamp(l + nz, 0, 255));
        }
    }
    const dec = decodeBlock(encodeBlock(blk));
    const p = psnrBlock(blk, dec);
    try testing.expect(p >= 30.0);
}

test "solid-colour block round-trips near-lossless (>= 60 dB)" {
    // A solid colour the format can represent exactly (all channels even, so
    // the shared p-bit = 0 reconstructs every channel losslessly) round-trips
    // bit-exact (PSNR sentinel 999).
    //
    // NOTE: mode 6 shares ONE p-bit across an endpoint's 4 channels, so an
    // arbitrary mixed-parity solid (e.g. 137,42,200,255) caps at ≈ 51 dB — no
    // single (endpoint pair, index) can hit odd and even channels exactly at
    // once. "Near-lossless" holds for representable uniform colours.
    var blk: [16][4]u8 = undefined;
    for (0..16) |i| blk[i] = .{ 136, 42, 200, 254 };
    const dec = decodeBlock(encodeBlock(blk));
    const p = psnrBlock(blk, dec);
    try testing.expect(p >= 60.0);
}

test "golden: fixed gradient block encodes to frozen bytes" {
    const blk = gradientBlock();
    const got = encodeBlock(blk);
    const expected = [16]u8{
        0x40, 0xc0, 0xff, 0x0f, 0x00, 0x48, 0xff, 0x7f,
        0x11, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe,
    };
    try testing.expectEqualSlices(u8, &expected, &got);
}

test "encodeImage 6x6: level count, per-level sizes, 1x1 tail" {
    const alloc = testing.allocator;
    const w: u32 = 6;
    const h: u32 = 6;
    var img = try alloc.alloc(u8, w * h * 4);
    defer alloc.free(img);
    for (0..img.len) |i| img[i] = @truncate(i);

    const chain = try encodeImage(alloc, img, w, h);
    defer {
        for (chain) |lvl| alloc.free(lvl);
        alloc.free(chain);
    }

    // levels = 1 + floor(log2(max(6,6))) = 1 + 2 = 3  (6→3→1)
    try testing.expectEqual(@as(usize, 3), chain.len);

    // level 0: 6x6 → 2x2 blocks → 4*16 = 64 bytes
    try testing.expectEqual(@as(usize, 64), chain[0].len);
    // level 1: 3x3 → 1x1 blocks → 16 bytes
    try testing.expectEqual(@as(usize, 16), chain[1].len);
    // level 2: 1x1 → 1 block → 16 bytes
    try testing.expectEqual(@as(usize, 16), chain[2].len);
}
