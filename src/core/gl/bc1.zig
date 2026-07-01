//! Pure-Zig BC1 (DXT1) + BC3 (DXT5) S3TC encoder (+ test-only decoders).
//!
//! Deterministic (no rand / time / I/O). The packed bytes are the real S3TC
//! hardware block layouts, so they decode on any S3TC GPU decoder. This mirrors
//! `bc7.zig`'s structure (mip chain, edge-clamp padding, principal-axis escape
//! hatch, in-file PSNR round-trip tests) — the only differences are the DXT
//! block codecs and the per-block byte size (BC1 = 8 bytes, BC3 = 16 bytes).
//!
//! Block layouts (all fields little-endian, LSB-first):
//!   BC1 (8 bytes):  u16 color0(RGB565), u16 color1(RGB565), u32 indices(16×2-bit)
//!   BC3 (16 bytes): BC4 alpha sub-block (8 bytes) then a BC1 color block (8 bytes)
//!     BC4 alpha:    u8 alpha0, u8 alpha1, u48 indices(16×3-bit, 6 bytes LE)
//!
//! Encoder PINs (v1):
//!   * Endpoints = the block's per-channel min/max (RGB) / min/max (alpha),
//!     quantized to RGB565 (colour) / kept 8-bit (alpha). Min/max is the
//!     accepted v1 fit (same escape hatch bc7 documents; principal-axis is
//!     unused here — the round-trip PSNR bars are met without it).
//!   * We fit the LOW endpoint into color0/alpha0 and the HIGH endpoint into
//!     color1/alpha1, then NORMALISE to the required always-4-colour /
//!     always-8-alpha ordering (color0 > color1, alpha0 > alpha1) via a single
//!     swap + index remap. Keeping the normalise step on the hot path means the
//!     swap-and-remap is exercised by every non-solid block (so the round-trip
//!     tests prove it), not dead code.
//!   * 4-colour index remap on a c0<->c1 swap: idx ^= 1 (palette is
//!     [c0,c1,(2c0+c1)/3,(c0+2c1)/3]; swapping maps 0<->1 and 2<->3).
//!   * 8-alpha index remap on an a0<->a1 swap: 0->1, 1->0, else 9-idx.
//!   * Solid / constant blocks quantise to color0==color1 (alpha0==alpha1);
//!     4-colour / 8-alpha require a STRICT >, so we nudge the low endpoint down
//!     one LSB (or the high endpoint up if already at 0). Solid blocks index to
//!     entry 0, which stays the exact quantised colour after the nudge.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const Mode = enum { bc1, bc3 };

// ── RGB565 quantise / expand ──────────────────────────────────────────────────

fn quant5(v: u8) u5 {
    return @intCast(std.math.clamp((@as(u32, v) * 31 + 15) / 255, 0, 31));
}
fn quant6(v: u8) u6 {
    return @intCast(std.math.clamp((@as(u32, v) * 63 + 31) / 255, 0, 63));
}

/// Pack an 8-bit RGB triple to a little-endian RGB565 u16. Monotonic per
/// channel, so componentwise ordering of the inputs is preserved in the packed
/// value (relied on by the normalise step).
fn pack565(rgb: [3]u8) u16 {
    const r: u16 = quant5(rgb[0]);
    const g: u16 = quant6(rgb[1]);
    const b: u16 = quant5(rgb[2]);
    return (r << 11) | (g << 5) | b;
}

/// Expand an RGB565 u16 to an 8-bit RGB triple via bit replication.
fn unpack565(c: u16) [3]u8 {
    const r5: u8 = @intCast((c >> 11) & 0x1f);
    const g6: u8 = @intCast((c >> 5) & 0x3f);
    const b5: u8 = @intCast(c & 0x1f);
    return .{ (r5 << 3) | (r5 >> 2), (g6 << 2) | (g6 >> 4), (b5 << 3) | (b5 >> 2) };
}

/// (2*a + b)/3 rounded — the two 1/3 lerp points of a 4-colour palette.
fn lerp2(a: u8, b: u8) u8 {
    return @intCast((2 * @as(u32, a) + @as(u32, b) + 1) / 3);
}

/// 4-colour palette for RGB565 endpoints c0,c1 (888 reconstructed).
fn bc1Palette(c0: u16, c1: u16) [4][3]u8 {
    const e0 = unpack565(c0);
    const e1 = unpack565(c1);
    var p: [4][3]u8 = undefined;
    p[0] = e0;
    p[1] = e1;
    for (0..3) |c| {
        p[2][c] = lerp2(e0[c], e1[c]);
        p[3][c] = lerp2(e1[c], e0[c]);
    }
    return p;
}

fn bestBc1Index(pal: [4][3]u8, texel: [4]u8) u2 {
    var best: u2 = 0;
    var best_err: i32 = std.math.maxInt(i32);
    for (0..4) |k| {
        var err: i32 = 0;
        for (0..3) |c| {
            const d: i32 = @as(i32, pal[k][c]) - @as(i32, texel[c]);
            err += d * d;
        }
        if (err < best_err) {
            best_err = err;
            best = @intCast(k);
        }
    }
    return best;
}

// ── BC1 (DXT1) colour block ───────────────────────────────────────────────────

/// One 4x4 RGBA block → 8-byte BC1 (DXT1) block. Opaque; always 4-colour mode.
pub fn encodeBlockBc1(rgba: [16][4]u8) [8]u8 {
    // Per-channel RGB min/max.
    var lo: [3]u8 = .{ 255, 255, 255 };
    var hi: [3]u8 = .{ 0, 0, 0 };
    for (rgba) |t| {
        for (0..3) |c| {
            lo[c] = @min(lo[c], t[c]);
            hi[c] = @max(hi[c], t[c]);
        }
    }

    // Fit low→c0, high→c1 (pack565 is monotonic so c0 <= c1); assign indices for
    // this ordering, then normalise below.
    var c0 = pack565(lo);
    var c1 = pack565(hi);
    var idx: [16]u2 = undefined;
    {
        const pal = bc1Palette(c0, c1);
        for (rgba, 0..) |t, i| idx[i] = bestBc1Index(pal, t);
    }

    // Normalise to 4-colour: color0 > color1 (strict). Swap + remap (idx ^= 1).
    if (c0 < c1) {
        const tmp = c0;
        c0 = c1;
        c1 = tmp;
        for (&idx) |*ix| ix.* ^= 1;
    }
    if (c0 == c1) {
        // Solid: keep strict >. Indices are all 0 (palette entries identical),
        // which decode to c0 — unchanged by nudging c1 down.
        if (c1 > 0) c1 -= 1 else c0 += 1;
    }

    var out: [8]u8 = undefined;
    out[0] = @truncate(c0);
    out[1] = @truncate(c0 >> 8);
    out[2] = @truncate(c1);
    out[3] = @truncate(c1 >> 8);
    var bits: u32 = 0;
    for (0..16) |i| bits |= @as(u32, idx[i]) << @intCast(i * 2);
    out[4] = @truncate(bits);
    out[5] = @truncate(bits >> 8);
    out[6] = @truncate(bits >> 16);
    out[7] = @truncate(bits >> 24);
    return out;
}

/// Test-only BC1 decoder (4-colour; our encoder always emits color0 > color1).
pub fn decodeBlockBc1(block: [8]u8) [16][4]u8 {
    const c0: u16 = @as(u16, block[0]) | (@as(u16, block[1]) << 8);
    const c1: u16 = @as(u16, block[2]) | (@as(u16, block[3]) << 8);
    const bits: u32 = @as(u32, block[4]) |
        (@as(u32, block[5]) << 8) |
        (@as(u32, block[6]) << 16) |
        (@as(u32, block[7]) << 24);
    const pal = bc1Palette(c0, c1);
    var out: [16][4]u8 = undefined;
    for (0..16) |i| {
        const ix: u2 = @intCast((bits >> @intCast(i * 2)) & 3);
        out[i] = .{ pal[ix][0], pal[ix][1], pal[ix][2], 255 };
    }
    return out;
}

// ── BC4 alpha sub-block (8-alpha mode) ────────────────────────────────────────

/// 8 interpolated alphas for endpoints a0,a1 (index 0=a0, 1=a1, 2..7 = 6 lerps).
fn alphaPalette(a0: u8, a1: u8) [8]u8 {
    var p: [8]u8 = undefined;
    p[0] = a0;
    p[1] = a1;
    // p[1+i] = ((7-i)*a0 + i*a1)/7 for i = 1..6.
    for (1..7) |i| {
        p[1 + i] = @intCast(((7 - i) * @as(u32, a0) + i * @as(u32, a1) + 3) / 7);
    }
    return p;
}

fn bestAlphaIndex(pal: [8]u8, a: u8) u3 {
    var best: u3 = 0;
    var best_err: i32 = std.math.maxInt(i32);
    for (0..8) |k| {
        const d: i32 = @as(i32, pal[k]) - @as(i32, a);
        const err = d * d;
        if (err < best_err) {
            best_err = err;
            best = @intCast(k);
        }
    }
    return best;
}

// ── BC3 (DXT5) block = BC4 alpha (8B) + BC1 colour (8B) ────────────────────────

/// One 4x4 RGBA block → 16-byte BC3 (DXT5) block.
pub fn encodeBlockBc3(rgba: [16][4]u8) [16]u8 {
    // Alpha min/max.
    var amin: u8 = 255;
    var amax: u8 = 0;
    for (rgba) |t| {
        amin = @min(amin, t[3]);
        amax = @max(amax, t[3]);
    }

    // Fit low→a0, high→a1; assign indices, then normalise to 8-alpha (a0 > a1).
    var a0 = amin;
    var a1 = amax;
    var aidx: [16]u3 = undefined;
    {
        const pal = alphaPalette(a0, a1);
        for (rgba, 0..) |t, i| aidx[i] = bestAlphaIndex(pal, t[3]);
    }
    if (a0 < a1) {
        const tmp = a0;
        a0 = a1;
        a1 = tmp;
        // 8-alpha remap: 0->1, 1->0, else 9-idx.
        for (&aidx) |*ix| {
            ix.* = switch (ix.*) {
                0 => 1,
                1 => 0,
                else => @intCast(9 - @as(u32, ix.*)),
            };
        }
    }
    if (a0 == a1) {
        if (a1 > 0) a1 -= 1 else a0 += 1;
    }

    var out: [16]u8 = undefined;
    out[0] = a0;
    out[1] = a1;
    var abits: u64 = 0;
    for (0..16) |i| abits |= @as(u64, aidx[i]) << @intCast(i * 3);
    for (0..6) |b| out[2 + b] = @truncate(abits >> @intCast(b * 8));

    const color = encodeBlockBc1(rgba);
    @memcpy(out[8..16], &color);
    return out;
}

/// Test-only BC3 decoder (8-alpha for A, 4-colour BC1 for RGB).
pub fn decodeBlockBc3(block: [16]u8) [16][4]u8 {
    const a0 = block[0];
    const a1 = block[1];
    const apal = alphaPalette(a0, a1);
    var abits: u64 = 0;
    for (0..6) |b| abits |= @as(u64, block[2 + b]) << @intCast(b * 8);

    var color: [8]u8 = undefined;
    @memcpy(&color, block[8..16]);
    var out = decodeBlockBc1(color);
    for (0..16) |i| {
        const ix: u3 = @intCast((abits >> @intCast(i * 3)) & 7);
        out[i][3] = apal[ix];
    }
    return out;
}

// ── image / mip chain ─────────────────────────────────────────────────────────

fn blockBytes(mode: Mode) usize {
    return switch (mode) {
        .bc1 => 8,
        .bc3 => 16,
    };
}

/// Full image → S3TC mip chain (largest first). Box-filter downsample to 1x1;
/// sub-4 levels pad up to one 4x4 block; non-mult-of-4 dims replicate edge
/// texels (clamp). Caller owns each inner slice and the outer slice.
pub fn encodeImage(alloc: Allocator, rgba: []const u8, w: u32, h: u32, mode: Mode) ![]const []const u8 {
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

    var cur: []const u8 = rgba;
    var cur_owned: ?[]u8 = null;
    var cw: u32 = w;
    var ch: u32 = h;
    defer if (cur_owned) |b| alloc.free(b);

    var level: u32 = 0;
    while (level < levels) : (level += 1) {
        out[built] = try encodeLevel(alloc, cur, cw, ch, mode);
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

/// Encode a single mip level's RGBA8 buffer to packed S3TC blocks.
fn encodeLevel(alloc: Allocator, rgba: []const u8, w: u32, h: u32, mode: Mode) ![]const u8 {
    const bb = blockBytes(mode);
    const bpr = (w + 3) / 4; // blocks per row (min 1)
    const bpc = (h + 3) / 4; // blocks per col (min 1)
    var buf = try alloc.alloc(u8, @as(usize, bpr) * @as(usize, bpc) * bb);
    var off: usize = 0;
    var by: u32 = 0;
    while (by < bpc) : (by += 1) {
        var bx: u32 = 0;
        while (bx < bpr) : (bx += 1) {
            var blk: [16][4]u8 = undefined;
            for (0..4) |ry| {
                for (0..4) |rx| {
                    const sx = @min(bx * 4 + @as(u32, @intCast(rx)), w - 1);
                    const sy = @min(by * 4 + @as(u32, @intCast(ry)), h - 1);
                    const src = (@as(usize, sy) * w + sx) * 4;
                    blk[ry * 4 + rx] = .{ rgba[src], rgba[src + 1], rgba[src + 2], rgba[src + 3] };
                }
            }
            switch (mode) {
                .bc1 => {
                    const packed_blk = encodeBlockBc1(blk);
                    @memcpy(buf[off .. off + 8], &packed_blk);
                },
                .bc3 => {
                    const packed_blk = encodeBlockBc3(blk);
                    @memcpy(buf[off .. off + 16], &packed_blk);
                },
            }
            off += bb;
        }
    }
    return buf;
}

/// Box-filter downsample RGBA8 `src` (sw×sh) into `dst` (dw×dh).
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

/// PSNR (dB) over selected channels of two 4x4 RGBA blocks. `chans` = list of
/// channel indices (0=R,1=G,2=B,3=A). Returns a large sentinel when identical.
fn psnrChans(a: [16][4]u8, b: [16][4]u8, comptime chans: []const usize) f64 {
    var mse: f64 = 0;
    for (0..16) |t| {
        inline for (chans) |c| {
            const d: f64 = @as(f64, @floatFromInt(a[t][c])) - @as(f64, @floatFromInt(b[t][c]));
            mse += d * d;
        }
    }
    mse /= @floatFromInt(16 * chans.len);
    if (mse == 0) return 999.0;
    return 10.0 * std.math.log10((255.0 * 255.0) / mse);
}

/// 4 collinear RGB levels (one per row) on the line (20,40,60)->(200,160,240) —
/// a smooth linear RGB gradient BC1's 4-colour palette represents well.
fn gradientBlockRgb() [16][4]u8 {
    const lvl = [4][3]u8{ .{ 20, 40, 60 }, .{ 80, 80, 120 }, .{ 140, 120, 180 }, .{ 200, 160, 240 } };
    var blk: [16][4]u8 = undefined;
    for (0..16) |i| {
        const r = i / 4;
        blk[i] = .{ lvl[r][0], lvl[r][1], lvl[r][2], 255 };
    }
    return blk;
}

test "BC1 round-trip PSNR on a smooth RGB gradient >= 38 dB" {
    const blk = gradientBlockRgb();
    const dec = decodeBlockBc1(encodeBlockBc1(blk));
    const p = psnrChans(blk, dec, &.{ 0, 1, 2 });
    try testing.expect(p >= 38.0);
}

test "BC1 round-trip PSNR on a deterministic noisy block >= 30 dB" {
    // The collinear gradient with gentle deterministic per-channel noise (±6):
    // a structured-but-noisy block. BC1's 2-bit index (4 levels) caps a full
    // 16-step ramp near ~22 dB, so this uses a 4-level gradient + small noise.
    var blk = gradientBlockRgb();
    var s: u32 = 0xBEEF;
    for (0..16) |i| {
        for (0..3) |c| {
            s = s *% 1664525 +% 1013904223;
            const nz: i32 = @as(i32, @intCast((s >> 20) % 13)) - 6; // ±6
            blk[i][c] = @intCast(std.math.clamp(@as(i32, blk[i][c]) + nz, 0, 255));
        }
    }
    const dec = decodeBlockBc1(encodeBlockBc1(blk));
    const p = psnrChans(blk, dec, &.{ 0, 1, 2 });
    try testing.expect(p >= 30.0);
}

test "BC1 solid-colour block round-trips near-lossless (>= 40 dB)" {
    // (132,40,198) is exactly representable in RGB565 → bit-exact round-trip.
    var blk: [16][4]u8 = undefined;
    for (0..16) |i| blk[i] = .{ 132, 40, 198, 255 };
    const dec = decodeBlockBc1(encodeBlockBc1(blk));
    const p = psnrChans(blk, dec, &.{ 0, 1, 2 });
    try testing.expect(p >= 40.0);
}

/// A block whose alpha is an 8-step ramp (0..255, 2 texels/step) — BC4's 8-alpha
/// palette reproduces it near-losslessly; RGB carries the smooth gradient.
fn bc3RampBlock() [16][4]u8 {
    var blk = gradientBlockRgb();
    for (0..16) |i| blk[i][3] = @intCast(((i / 2) * 255) / 7);
    return blk;
}

test "BC3 alpha ramp round-trips near-lossless (>= 45 dB), RGB >= 38 dB" {
    const blk = bc3RampBlock();
    const dec = decodeBlockBc3(encodeBlockBc3(blk));
    const pa = psnrChans(blk, dec, &.{3});
    const prgb = psnrChans(blk, dec, &.{ 0, 1, 2 });
    try testing.expect(pa >= 45.0);
    try testing.expect(prgb >= 38.0);
}

test "BC3 solid block: constant alpha exact, RGB near-lossless" {
    var blk: [16][4]u8 = undefined;
    for (0..16) |i| blk[i] = .{ 132, 40, 198, 173 };
    const dec = decodeBlockBc3(encodeBlockBc3(blk));
    const pa = psnrChans(blk, dec, &.{3});
    const prgb = psnrChans(blk, dec, &.{ 0, 1, 2 });
    try testing.expect(pa >= 60.0);
    try testing.expect(prgb >= 40.0);
}

test "golden: fixed BC1 block encodes to frozen bytes" {
    const blk = gradientBlockRgb();
    const got = encodeBlockBc1(blk);
    const expected = [8]u8{ 0xFD, 0xC4, 0x47, 0x11, 0x55, 0xFF, 0xAA, 0x00 };
    try testing.expectEqualSlices(u8, &expected, &got);
}

test "golden: fixed BC3 block encodes to frozen bytes" {
    const blk = bc3RampBlock();
    const got = encodeBlockBc3(blk);
    const expected = [16]u8{
        0xFF, 0x00, 0xC9, 0x6F, 0xB7, 0xE4, 0x26, 0x01,
        0xFD, 0xC4, 0x47, 0x11, 0x55, 0xFF, 0xAA, 0x00,
    };
    try testing.expectEqualSlices(u8, &expected, &got);
}

test "encodeImage 6x6: level count, per-level sizes, 1x1 tail (both modes)" {
    const alloc = testing.allocator;
    const w: u32 = 6;
    const h: u32 = 6;
    var img = try alloc.alloc(u8, w * h * 4);
    defer alloc.free(img);
    for (0..img.len) |i| img[i] = @truncate(i);

    // BC1: 8 bytes/block.
    {
        const chain = try encodeImage(alloc, img, w, h, .bc1);
        defer {
            for (chain) |lvl| alloc.free(lvl);
            alloc.free(chain);
        }
        // levels = 1 + floor(log2(6)) = 3  (6→3→1)
        try testing.expectEqual(@as(usize, 3), chain.len);
        try testing.expectEqual(@as(usize, 4 * 8), chain[0].len); // 6x6 → 2x2 blocks
        try testing.expectEqual(@as(usize, 8), chain[1].len); // 3x3 → 1 block
        try testing.expectEqual(@as(usize, 8), chain[2].len); // 1x1 → 1 block
    }

    // BC3: 16 bytes/block.
    {
        const chain = try encodeImage(alloc, img, w, h, .bc3);
        defer {
            for (chain) |lvl| alloc.free(lvl);
            alloc.free(chain);
        }
        try testing.expectEqual(@as(usize, 3), chain.len);
        try testing.expectEqual(@as(usize, 4 * 16), chain[0].len);
        try testing.expectEqual(@as(usize, 16), chain[1].len);
        try testing.expectEqual(@as(usize, 16), chain[2].len);
    }
}
