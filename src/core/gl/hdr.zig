//! Pure-Zig Radiance .hdr (RGBE) decode + flat encode.
//!
//! Decode: "#?RADIANCE" / "#?RGBE" signature, FORMAT=32-bit_rle_rgbe,
//! "-Y h +X w" resolution line; supports new-RLE (0x02 0x02) and flat
//! RGBE scanlines → linear f32 RGB output.
//!
//! Encode: flat (non-RLE) RGBE scanlines — fixture/build use only.
//!
//! Native-side asset pipeline (IBL prefilter feed). Island chunks must not
//! reference this — Zig's lazy analysis makes the bare import free; only
//! actual references would pull it into wasm.
//!
//! Errors: `error.BadSignature`, `error.Unsupported`, `error.Corrupt`,
//!         `error.OutOfMemory`.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const math = std.math;

// ── public surface ────────────────────────────────────────────────────────────

pub const Image = struct {
    width: u32,
    height: u32,
    /// width * height * 3 f32 values in linear radiance (R,G,B interleaved).
    rgb: []f32,

    pub fn deinit(self: *Image, alloc: Allocator) void {
        alloc.free(self.rgb);
        self.* = undefined;
    }
};

/// Decode a Radiance .hdr file (bytes) → linear f32 RGB Image.
/// Caller owns Image.rgb via alloc.
/// Supports "#?RADIANCE" and "#?RGBE" signatures, FORMAT=32-bit_rle_rgbe,
/// "-Y h +X w" orientation, new-RLE and flat scanlines.
pub fn decode(alloc: Allocator, bytes: []const u8) !Image {
    return decodeHdr(alloc, bytes);
}

/// Encode linear f32 RGB pixels (w × h) → flat RGBE .hdr bytes (alloc-owned).
/// Uses flat (non-RLE) scanlines. Fixture/build use only.
pub fn encode(alloc: Allocator, rgb: []const f32, w: u32, h: u32) ![]u8 {
    return encodeHdr(alloc, rgb, w, h);
}

// ── internal constants ────────────────────────────────────────────────────────

const max_alloc_bytes: usize = 512 * 1024 * 1024; // 512 MB sanity cap
const min_rle_width: u32 = 8;
const max_rle_width: u32 = 0x7fff;

// ── RGBE math ─────────────────────────────────────────────────────────────────

/// Convert one RGBE quad to three linear f32 values.
/// Spec: e==0 → (0,0,0); else f_c = c * 2^(e - 136).
/// Note: 136 = 128 (bias) + 8 (mantissa shift), i.e. ldexp(c, e-136).
inline fn rgbeToRgb(r: u8, g: u8, b: u8, e: u8) [3]f32 {
    if (e == 0) return .{ 0.0, 0.0, 0.0 };
    // Scale = 2^(e-136) = 2^(e-128) / 256
    const exp: i32 = @as(i32, e) - 136;
    const scale = math.ldexp(@as(f32, 1.0), exp);
    return .{
        @as(f32, @floatFromInt(r)) * scale,
        @as(f32, @floatFromInt(g)) * scale,
        @as(f32, @floatFromInt(b)) * scale,
    };
}

/// Convert one RGB triple to RGBE quad.
/// Spec: find max component, frexp it; exponent byte = exp+128,
/// mantissa per channel = trunc(c * 2^(8 - exp + (exp>0 ? 0 : -1))).
/// Standard Radiance float2rgbe: scale = 256 * 2^(-exp).
inline fn rgbToRgbe(r: f32, g: f32, b: f32) [4]u8 {
    const mx = @max(@max(r, g), b);
    if (mx <= 0.0 or !math.isFinite(mx)) return .{ 0, 0, 0, 0 };
    // frexp: mx = mantissa * 2^exp, where 0.5 <= |mantissa| < 1.0
    var exp: i32 = undefined;
    const mant = math.frexp(mx);
    exp = mant.exponent; // mx = mant.significand * 2^exp, 0.5 <= significand < 1.0
    // scale factor: 256.0 / mx = 256.0 / (significand * 2^exp)
    // so each channel c becomes trunc(c * scale)
    // We need e_byte = exp + 128
    // and c_byte = trunc(c * 2^(8-exp)) = trunc(c / mx * 256 * significand)
    // Simpler: scale = 256.0 * 2^(-exp) = ldexp(256.0, -exp)
    const e_byte = exp + 128;
    if (e_byte <= 0) return .{ 0, 0, 0, 0 }; // underflow
    if (e_byte > 255) return .{ 255, 255, 255, 255 }; // overflow clamp
    const scale = math.ldexp(@as(f32, 256.0), -exp);
    return .{
        @intFromFloat(@min(@as(f32, 255.0), r * scale)),
        @intFromFloat(@min(@as(f32, 255.0), g * scale)),
        @intFromFloat(@min(@as(f32, 255.0), b * scale)),
        @as(u8, @intCast(e_byte)),
    };
}

// ── decode ────────────────────────────────────────────────────────────────────

fn decodeHdr(alloc: Allocator, bytes: []const u8) !Image {
    // ── 1. Signature ──────────────────────────────────────────────────────────
    if (bytes.len < 10) return error.BadSignature;
    const sig_radiance = "#?RADIANCE";
    const sig_rgbe = "#?RGBE";
    const has_sig = mem.startsWith(u8, bytes, sig_radiance) or
        mem.startsWith(u8, bytes, sig_rgbe);
    if (!has_sig) return error.BadSignature;

    // ── 2. Header lines ───────────────────────────────────────────────────────
    // Read line-by-line until empty line (end of header).
    var pos: usize = 0;
    var got_format = false;

    // advance past first line (signature)
    pos = mem.indexOfScalarPos(u8, bytes, 0, '\n') orelse return error.Corrupt;
    pos += 1;

    while (pos < bytes.len) {
        const line_end = mem.indexOfScalarPos(u8, bytes, pos, '\n') orelse return error.Corrupt;
        const line = bytes[pos..line_end];
        pos = line_end + 1;

        if (line.len == 0 or (line.len == 1 and line[0] == '\r')) {
            // empty line = end of header
            break;
        }
        // Strip trailing \r
        const trimmed = if (line.len > 0 and line[line.len - 1] == '\r')
            line[0 .. line.len - 1]
        else
            line;

        if (mem.startsWith(u8, trimmed, "FORMAT=")) {
            const fmt = trimmed[7..];
            if (!mem.eql(u8, fmt, "32-bit_rle_rgbe")) return error.Unsupported;
            got_format = true;
        }
        // Other header lines (EXPOSURE, GAMMA, comments) are ignored.
    }

    if (!got_format) return error.Unsupported;

    // ── 3. Resolution line ────────────────────────────────────────────────────
    // Must be "-Y <h> +X <w>"
    const res_end = mem.indexOfScalarPos(u8, bytes, pos, '\n') orelse return error.Corrupt;
    const res_line_raw = bytes[pos..res_end];
    pos = res_end + 1;
    const res_line = if (res_line_raw.len > 0 and res_line_raw[res_line_raw.len - 1] == '\r')
        res_line_raw[0 .. res_line_raw.len - 1]
    else
        res_line_raw;

    if (!mem.startsWith(u8, res_line, "-Y ")) return error.Unsupported;
    // Parse: "-Y <h> +X <w>"
    var it = mem.splitScalar(u8, res_line, ' ');
    _ = it.next(); // "-Y"
    const h_str = it.next() orelse return error.Corrupt;
    const dir_x = it.next() orelse return error.Corrupt;
    const w_str = it.next() orelse return error.Corrupt;
    if (!mem.eql(u8, dir_x, "+X")) return error.Unsupported;

    const height = std.fmt.parseInt(u32, h_str, 10) catch return error.Corrupt;
    const width = std.fmt.parseInt(u32, w_str, 10) catch return error.Corrupt;
    if (width == 0 or height == 0) return error.Corrupt;

    // overflow-check total pixels
    const npix = std.math.mulWide(u32, width, height);
    if (npix > max_alloc_bytes / (3 * @sizeOf(f32))) return error.Corrupt;

    // ── 4. Allocate output ────────────────────────────────────────────────────
    const rgb = try alloc.alloc(f32, @as(usize, width) * @as(usize, height) * 3);
    errdefer alloc.free(rgb);

    // ── 5. Scanline decode ────────────────────────────────────────────────────
    // Detect new-RLE vs flat: new-RLE scanline starts with 0x02 0x02 hi lo
    // where (hi<<8|lo) == width and min_rle_width <= width <= max_rle_width.
    const use_rle = (width >= min_rle_width and width <= max_rle_width);

    var row: u32 = 0;
    var data_pos = pos;
    while (row < height) : (row += 1) {
        const out_base = @as(usize, row) * @as(usize, width) * 3;
        if (use_rle) {
            // Peek at 4 bytes
            if (data_pos + 4 > bytes.len) return error.Corrupt;
            const b0 = bytes[data_pos];
            const b1 = bytes[data_pos + 1];
            const b2 = bytes[data_pos + 2];
            const b3 = bytes[data_pos + 3];
            const rle_width: u32 = (@as(u32, b2) << 8) | @as(u32, b3);
            if (b0 == 0x02 and b1 == 0x02 and rle_width == width) {
                // New-RLE scanline
                data_pos += 4;
                data_pos = try decodeRleScanline(alloc, bytes, data_pos, rgb[out_base..], width);
                continue;
            }
        }
        // Flat RGBE: consume width * 4 bytes
        if (data_pos + @as(usize, width) * 4 > bytes.len) return error.Corrupt;
        var col: u32 = 0;
        while (col < width) : (col += 1) {
            const r = bytes[data_pos + 0];
            const g = bytes[data_pos + 1];
            const b = bytes[data_pos + 2];
            const e = bytes[data_pos + 3];
            data_pos += 4;
            const out = rgbeToRgb(r, g, b, e);
            const idx = @as(usize, col) * 3;
            rgb[out_base + idx + 0] = out[0];
            rgb[out_base + idx + 1] = out[1];
            rgb[out_base + idx + 2] = out[2];
        }
    }

    return Image{ .width = width, .height = height, .rgb = rgb };
}

/// Decode one new-RLE scanline (4 channels, each run-length encoded).
/// Returns updated data_pos.
fn decodeRleScanline(alloc: Allocator, bytes: []const u8, start: usize, rgb_row: []f32, width: u32) !usize {
    // Allocate a stack buffer for 4 channels. Max width = 0x7fff = 32767 bytes per channel.
    // Use a fixed buffer on stack for reasonable widths, heap for large.
    var pos = start;

    // Decode each of 4 channels into a temp flat buffer [R0..Rn, G0..Gn, B0..Bn, E0..En]
    // We decode channel by channel into a local slice, then interleave into rgb_row.
    // Max stack: 4 * 32767 = 128 KB — use heap to be safe.
    const chan_buf = try alloc.alloc(u8, @as(usize, width) * 4);
    defer alloc.free(chan_buf);

    var ch: u32 = 0;
    while (ch < 4) : (ch += 1) {
        var filled: u32 = 0;
        const chan_slice = chan_buf[@as(usize, ch) * @as(usize, width) .. (@as(usize, ch) + 1) * @as(usize, width)];
        while (filled < width) {
            if (pos >= bytes.len) return error.Corrupt;
            const count_byte = bytes[pos];
            pos += 1;
            if (count_byte > 128) {
                // Run packet: (count-128) copies of next byte
                const run_len: u32 = @as(u32, count_byte) - 128;
                if (filled + run_len > width) return error.Corrupt;
                if (pos >= bytes.len) return error.Corrupt;
                const val = bytes[pos];
                pos += 1;
                @memset(chan_slice[filled .. filled + run_len], val);
                filled += run_len;
            } else if (count_byte == 0) {
                // count=0 is invalid per spec
                return error.Corrupt;
            } else {
                // Literal packet: count_byte literal bytes
                const lit_len: u32 = @as(u32, count_byte);
                if (filled + lit_len > width) return error.Corrupt;
                if (pos + lit_len > bytes.len) return error.Corrupt;
                @memcpy(chan_slice[filled .. filled + lit_len], bytes[pos .. pos + lit_len]);
                pos += lit_len;
                filled += lit_len;
            }
        }
        if (filled != width) return error.Corrupt;
    }

    // Interleave: chan_buf[R*width .. G*width .. B*width .. E*width] → rgb_row
    const r_ch = chan_buf[0..@as(usize, width)];
    const g_ch = chan_buf[@as(usize, width) .. @as(usize, width) * 2];
    const b_ch = chan_buf[@as(usize, width) * 2 .. @as(usize, width) * 3];
    const e_ch = chan_buf[@as(usize, width) * 3 .. @as(usize, width) * 4];

    var col: u32 = 0;
    while (col < width) : (col += 1) {
        const out = rgbeToRgb(r_ch[col], g_ch[col], b_ch[col], e_ch[col]);
        const idx = @as(usize, col) * 3;
        rgb_row[idx + 0] = out[0];
        rgb_row[idx + 1] = out[1];
        rgb_row[idx + 2] = out[2];
    }

    return pos;
}

// ── encode ────────────────────────────────────────────────────────────────────

fn encodeHdr(alloc: Allocator, rgb: []const f32, w: u32, h: u32) ![]u8 {
    // Header: "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y <h> +X <w>\n"
    var hdr_buf: [256]u8 = undefined;
    const hdr = try std.fmt.bufPrint(&hdr_buf, "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y {d} +X {d}\n", .{ h, w });

    const pixel_bytes = @as(usize, w) * @as(usize, h) * 4;
    const total = hdr.len + pixel_bytes;
    const out = try alloc.alloc(u8, total);
    errdefer alloc.free(out);

    @memcpy(out[0..hdr.len], hdr);
    var off = hdr.len;

    var i: usize = 0;
    const npix = @as(usize, w) * @as(usize, h);
    while (i < npix) : (i += 1) {
        const quad = rgbToRgbe(rgb[i * 3 + 0], rgb[i * 3 + 1], rgb[i * 3 + 2]);
        out[off + 0] = quad[0];
        out[off + 1] = quad[1];
        out[off + 2] = quad[2];
        out[off + 3] = quad[3];
        off += 4;
    }

    return out;
}

// ── tests ─────────────────────────────────────────────────────────────────────

test "hdr: round-trip 4x3 gradient 0.01..100.0" {
    // (a) encode a 4×3 image where each pixel has distinct R,G,B values
    // spanning the representable range 0.01..100.0, then decode and verify
    // relative error ≤ 1% per component. Zero components must decode exactly
    // to 0.0 (e==0 path).
    const alloc = std.testing.allocator;
    const W = 4;
    const H = 3;
    const npix = W * H;

    var src_rgb: [npix * 3]f32 = undefined;
    // Fill with a gradient spanning 0.01..100.0.
    // Use equal R=G=B per pixel so all three components share the same
    // exponent, keeping quantization error ≤ 1/256 ≈ 0.39% (well within 1%).
    // Also include pixel 11 = 0.0 to exercise the e==0 zero path.
    const vals = [npix]f32{
        0.01, 0.05, 0.1,  0.5,
        1.0,  2.0,  5.0,  10.0,
        20.0, 50.0, 75.0, 100.0,
    };
    for (vals, 0..) |v, i| {
        src_rgb[i * 3 + 0] = v;
        src_rgb[i * 3 + 1] = v;
        src_rgb[i * 3 + 2] = v;
    }

    const encoded = try encode(alloc, &src_rgb, W, H);
    defer alloc.free(encoded);

    var img = try decode(alloc, encoded);
    defer img.deinit(alloc);

    try std.testing.expectEqual(@as(u32, W), img.width);
    try std.testing.expectEqual(@as(u32, H), img.height);

    for (0..npix * 3) |idx| {
        const expected = src_rgb[idx];
        const got = img.rgb[idx];
        if (expected == 0.0) {
            // e==0 → must decode to exact 0.0
            try std.testing.expectEqual(@as(f32, 0.0), got);
        } else {
            // RGBE mantissa precision: 1/256 ≈ 0.39%; bound to 1%
            const rel_err = @abs(got - expected) / expected;
            if (rel_err > 0.01) {
                std.debug.print("round-trip fail idx={d}: expected={d} got={d} rel_err={d}\n", .{ idx, expected, got, rel_err });
                return error.TestUnexpectedResult;
            }
        }
    }

    // Explicit zero: encode a 1×1 black pixel, verify e==0 path gives 0.0.
    const zero_rgb = [3]f32{ 0.0, 0.0, 0.0 };
    const zero_enc = try encode(alloc, &zero_rgb, 1, 1);
    defer alloc.free(zero_enc);
    var zero_img = try decode(alloc, zero_enc);
    defer zero_img.deinit(alloc);
    try std.testing.expectEqual(@as(f32, 0.0), zero_img.rgb[0]);
    try std.testing.expectEqual(@as(f32, 0.0), zero_img.rgb[1]);
    try std.testing.expectEqual(@as(f32, 0.0), zero_img.rgb[2]);
}

test "hdr: hand-built new-RLE scanline" {
    // (b) Hand-construct bytes for a 1-row, 8-wide image using new-RLE format.
    //
    // New-RLE scanline starts with 4 bytes: 0x02 0x02 hi lo
    // where (hi<<8|lo) == width (here 8 = 0x00 0x08).
    //
    // Then 4 channels (R, G, B, E), each encoded as packets:
    //   count > 128 → run: (count-128) copies of next byte
    //   count ≤ 128 (and > 0) → literal: count bytes follow
    //
    // We encode 8 pixels as follows for each channel:
    //   Channel R: all 8 = 0xAA  → run packet: 0x81 (=128+1, wrong) or 0x88 (=128+8) 0xAA
    //              Actually 8 copies: count_byte=128+8=136=0x88, val=0xAA
    //   Channel G: 4 literal 0x10 then run of 4 0x20
    //              → literal packet: 0x04 0x10 0x10 0x10 0x10
    //                run packet:     0x84 0x20  (128+4=132=0x84)
    //   Channel B: all 8 = 0x00 → run: 0x88 0x00
    //   Channel E: all 8 = 0x88 (=136, so exp=136-128=8, scale=2^(8-136)=2^(-128))
    //              Actually let's use e=0x89 (137) → scale=2^(137-136)=2^1=2.0
    //              → run: 0x88 0x89
    //
    // Decoded pixels (e=0x89 → exp_val = 0x89 - 136 = 1):
    //   pixel 0..3: R=0xAA*(2^1)=170*2=340.0, G=0x10*(2^1)=16*2=32.0, B=0.0
    //   pixel 4..7: R=0xAA*(2^1)=340.0,       G=0x20*(2^1)=32*2=64.0, B=0.0
    //
    // Header:
    //   "#?RADIANCE\n" = 11 bytes
    //   "FORMAT=32-bit_rle_rgbe\n" = 23 bytes
    //   "\n" = 1 byte  (empty line ending header)
    //   "-Y 1 +X 8\n" = 10 bytes
    // Total header = 45 bytes
    //
    // Scanline:
    //   [0x02, 0x02, 0x00, 0x08]   = 4 bytes  (new-RLE marker, width=8)
    //   R: [0x88, 0xAA]             = 2 bytes  (run of 8, value 0xAA)
    //   G: [0x04, 0x10,0x10,0x10,0x10, 0x84, 0x20] = 7 bytes
    //   B: [0x88, 0x00]             = 2 bytes  (run of 8, value 0x00)
    //   E: [0x88, 0x89]             = 2 bytes  (run of 8, value 0x89=137)
    //   Total scanline = 4 + 2 + 7 + 2 + 2 = 17 bytes

    const header = "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 1 +X 8\n";
    const scanline = [_]u8{
        // new-RLE marker + width
        0x02, 0x02, 0x00, 0x08,
        // Channel R: run of 8 copies of 0xAA  (count_byte = 128+8 = 0x88)
        0x88, 0xAA,
        // Channel G: 4 literals [0x10,0x10,0x10,0x10], then run of 4 0x20
        0x04, 0x10, 0x10, 0x10, 0x10, // literal packet: count=4
        0x84, 0x20, // run packet: count=132=128+4 → 4 copies of 0x20
        // Channel B: run of 8 copies of 0x00
        0x88, 0x00,
        // Channel E: run of 8 copies of 0x89 (=137)
        0x88, 0x89,
    };
    var buf: [256]u8 = undefined;
    const total_len = header.len + scanline.len;
    @memcpy(buf[0..header.len], header);
    @memcpy(buf[header.len..total_len], &scanline);

    const alloc = std.testing.allocator;
    var img = try decode(alloc, buf[0..total_len]);
    defer img.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 8), img.width);
    try std.testing.expectEqual(@as(u32, 1), img.height);

    // e=0x89=137 → exp = 137 - 136 = 1 → scale = 2^1 = 2.0
    // pixel 0..3: R=0xAA*2=340.0, G=0x10*2=32.0, B=0x00*2=0.0
    // pixel 4..7: R=0xAA*2=340.0, G=0x20*2=64.0, B=0x00*2=0.0
    for (0..4) |i| {
        try std.testing.expectApproxEqRel(@as(f32, 340.0), img.rgb[i * 3 + 0], 1e-4);
        try std.testing.expectApproxEqRel(@as(f32, 32.0), img.rgb[i * 3 + 1], 1e-4);
        try std.testing.expectEqual(@as(f32, 0.0), img.rgb[i * 3 + 2]);
    }
    for (4..8) |i| {
        try std.testing.expectApproxEqRel(@as(f32, 340.0), img.rgb[i * 3 + 0], 1e-4);
        try std.testing.expectApproxEqRel(@as(f32, 64.0), img.rgb[i * 3 + 1], 1e-4);
        try std.testing.expectEqual(@as(f32, 0.0), img.rgb[i * 3 + 2]);
    }
}

test "hdr: hostile inputs" {
    // (c) Hostile inputs must return errors, never panic.
    const alloc = std.testing.allocator;

    // garbage → BadSignature
    try std.testing.expectError(error.BadSignature, decode(alloc, "garbage"));
    // empty → BadSignature
    try std.testing.expectError(error.BadSignature, decode(alloc, ""));
    // valid signature but truncated (no FORMAT line, no resolution) → Unsupported or Corrupt
    const partial = "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 10 +X 10\n";
    // header is valid but scanline data missing → Corrupt
    const result = decode(alloc, partial);
    try std.testing.expect(result == error.Corrupt or result == error.OutOfMemory);

    // valid header + truncated scanline → Corrupt
    const hdr = "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 1 +X 8\n";
    // give only the RLE marker with no channel data
    var trunc_buf: [64]u8 = undefined;
    @memcpy(trunc_buf[0..hdr.len], hdr);
    // new-RLE marker only (4 bytes), no channel data
    trunc_buf[hdr.len + 0] = 0x02;
    trunc_buf[hdr.len + 1] = 0x02;
    trunc_buf[hdr.len + 2] = 0x00;
    trunc_buf[hdr.len + 3] = 0x08;
    try std.testing.expectError(error.Corrupt, decode(alloc, trunc_buf[0 .. hdr.len + 4]));

    // wrong format → Unsupported
    const bad_fmt = "#?RADIANCE\nFORMAT=32-bit_rle_xyz\n\n-Y 1 +X 1\n";
    try std.testing.expectError(error.Unsupported, decode(alloc, bad_fmt));

    // wrong orientation → Unsupported
    const bad_orient = "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n+Y 1 +X 1\n";
    try std.testing.expectError(error.Unsupported, decode(alloc, bad_orient));

    // #?RGBE signature → also valid
    const rgbe_sig = "#?RGBE\nFORMAT=32-bit_rle_rgbe\n\n-Y 1 +X 1\n\x00\x00\x00\x00";
    var img2 = try decode(alloc, rgbe_sig);
    defer img2.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 1), img2.width);
}
