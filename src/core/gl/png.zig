//! Pure-Zig PNG decode + store-mode encode.
//!
//! Decode: 8-bit-depth, color type 2 (RGB) or 6 (RGBA), non-interlaced,
//! filter types 0-4 per scanline → RGBA8 output.
//!
//! Encode: RGBA8 → valid PNG using adaptive per-scanline filters (MSAD) + real zlib DEFLATE (std flate).
//! Fixture/demo + compressed-texture asset use.
//!
//! Errors: `error.Unsupported`, `error.BadSignature`, `error.Corrupt`.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── public surface ────────────────────────────────────────────────────────────

pub const Image = struct {
    width: u32,
    height: u32,
    rgba: []u8,

    pub fn deinit(self: *Image, alloc: Allocator) void {
        alloc.free(self.rgba);
        self.* = undefined;
    }
};

/// Decode a PNG file (bytes) → RGBA8 Image.  Caller owns Image.rgba via alloc.
pub fn decode(alloc: Allocator, bytes: []const u8) !Image {
    return decodePng(alloc, bytes);
}

/// Encode RGBA8 pixels (w × h) → PNG bytes (alloc-owned).
/// Uses adaptive per-scanline filters (MSAD) + real zlib DEFLATE (std flate).
pub fn encodeRgba(alloc: Allocator, rgba: []const u8, w: u32, h: u32) ![]u8 {
    const stride: usize = @as(usize, w) * 4;
    // filtered stream: 1 filter byte + stride residual bytes per row
    const filtered_len = @as(usize, h) * (1 + stride);
    const filtered = try alloc.alloc(u8, filtered_len);
    defer alloc.free(filtered);
    // Zero "previous row" for scanline 0 (Up/Average/Paeth reference above=0).
    const zero_row = try alloc.alloc(u8, stride);
    defer alloc.free(zero_row);
    @memset(zero_row, 0);

    var fi: usize = 0;
    for (0..@as(usize, h)) |row| {
        const cur = rgba[row * stride .. row * stride + stride];
        const prev = if (row == 0) zero_row else rgba[(row - 1) * stride .. (row - 1) * stride + stride];
        // Adaptive per-scanline filter (MSAD): write residual after the filter byte.
        filtered[fi] = chooseScanlineFilter(cur, prev, 4, filtered[fi + 1 .. fi + 1 + stride]);
        fi += 1 + stride;
    }
    return buildPng(alloc, filtered, w, h, 6); // color type 6 = RGBA
}

/// Test/fixture helper: wrap pre-filtered RGB scanlines in a valid PNG.
/// `filtered` must be exactly `h * (1 + w*3)` bytes (filter byte + RGB data
/// per row — no expansion, caller supplies filter bytes).
pub fn rawPngRgb(alloc: Allocator, filtered: []const u8, w: u32, h: u32) ![]u8 {
    return buildPng(alloc, filtered, w, h, 2); // color type 2 = RGB
}

// ── internal constants ────────────────────────────────────────────────────────

const png_signature = [8]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };
const max_alloc_bytes: usize = 64 * 1024 * 1024; // 64 MB sanity cap

// ── decode ────────────────────────────────────────────────────────────────────

fn decodePng(alloc: Allocator, bytes: []const u8) !Image {
    if (bytes.len < 8) return error.BadSignature;
    if (!mem.eql(u8, bytes[0..8], &png_signature)) return error.BadSignature;

    var pos: usize = 8;
    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;
    var interlace: u8 = 0;
    var bpp: u32 = 0;
    var got_ihdr = false;

    // Accumulate IDAT payloads using Io.Writer.Allocating
    var idat_aw: std.Io.Writer.Allocating = .init(alloc);
    defer idat_aw.deinit();

    while (pos + 12 <= bytes.len) {
        if (pos + 4 > bytes.len) return error.Corrupt;
        const chunk_len = mem.readInt(u32, bytes[pos..][0..4], .big);
        pos += 4;
        // bounds check: type(4) + data(chunk_len) + crc(4) must fit
        if (chunk_len > bytes.len or pos + 4 + @as(usize, chunk_len) + 4 > bytes.len) return error.Corrupt;
        const chunk_type = bytes[pos .. pos + 4];
        pos += 4;
        const chunk_data = bytes[pos .. pos + chunk_len];
        pos += chunk_len;
        const stored_crc = mem.readInt(u32, bytes[pos..][0..4], .big);
        pos += 4;

        // Verify CRC32 over type + data
        var crc = std.hash.Crc32.init();
        crc.update(chunk_type);
        crc.update(chunk_data);
        if (crc.final() != stored_crc) return error.Corrupt;

        if (mem.eql(u8, chunk_type, "IHDR")) {
            if (chunk_len != 13) return error.Corrupt;
            width = mem.readInt(u32, chunk_data[0..4], .big);
            height = mem.readInt(u32, chunk_data[4..8], .big);
            bit_depth = chunk_data[8];
            color_type = chunk_data[9];
            const compression = chunk_data[10];
            const filter_method = chunk_data[11];
            interlace = chunk_data[12];
            if (bit_depth != 8) return error.Unsupported;
            if (color_type != 2 and color_type != 6) return error.Unsupported;
            if (compression != 0 or filter_method != 0) return error.Unsupported;
            if (interlace != 0) return error.Unsupported;
            bpp = if (color_type == 6) 4 else 3;
            got_ihdr = true;
        } else if (mem.eql(u8, chunk_type, "IDAT")) {
            if (!got_ihdr) return error.Corrupt;
            _ = idat_aw.writer.writeAll(chunk_data) catch return error.Corrupt;
        } else if (mem.eql(u8, chunk_type, "IEND")) {
            break;
        }
        // ancillary chunks silently skipped
    }

    if (!got_ihdr) return error.Corrupt;
    if (width == 0 or height == 0) return error.Corrupt;

    // Sanity-cap: reject images that would need >64 MB RGBA
    const rgba_size = @as(u64, width) * @as(u64, height) * 4;
    if (rgba_size > max_alloc_bytes) return error.Unsupported;

    // Inflate IDAT (zlib container)
    // API (Zig 0.16): std.compress.flate.Decompress.init(*std.Io.Reader, Container, []u8)
    // Decompress via decomp.reader.streamRemaining(&writer)
    const idat_bytes = idat_aw.written();
    var in: std.Io.Reader = .fixed(idat_bytes);
    var decomp_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp = std.compress.flate.Decompress.init(&in, .zlib, &decomp_buf);

    // Expected raw size: height * (1 + width * bpp)
    const expected_raw: usize = @as(usize, height) * (1 + @as(usize, width) * @as(usize, bpp));
    var raw_aw: std.Io.Writer.Allocating = .init(alloc);
    defer raw_aw.deinit();
    _ = decomp.reader.streamRemaining(&raw_aw.writer) catch return error.Corrupt;
    const raw = raw_aw.written();
    if (raw.len != expected_raw) return error.Corrupt;

    // Allocate RGBA output
    const rgba = try alloc.alloc(u8, @intCast(rgba_size));
    errdefer alloc.free(rgba);

    // Unfilter scanlines: reconstruct each pixel channel
    // bpp_uz = bytes per pixel in source (3 for RGB, 4 for RGBA)
    const bpp_uz: usize = @as(usize, bpp);
    const src_stride: usize = 1 + @as(usize, width) * bpp_uz;
    const dst_stride: usize = @as(usize, width) * 4;

    for (0..@as(usize, height)) |row| {
        const filter_byte = raw[row * src_stride];
        const filt_data = raw[row * src_stride + 1 .. row * src_stride + 1 + @as(usize, width) * bpp_uz];

        var col: usize = 0;
        while (col < @as(usize, width)) : (col += 1) {
            for (0..bpp_uz) |c| {
                const fi = col * bpp_uz + c; // index in filtered data
                const x = filt_data[fi];

                // left reconstructed value (same row, previous pixel)
                const left: u8 = if (col == 0) 0 else blk: {
                    const prev_off = row * dst_stride + (col - 1) * 4 + c;
                    break :blk rgba[prev_off];
                };
                // above reconstructed value (row above, same column)
                const above: u8 = if (row == 0) 0 else blk: {
                    const up_off = (row - 1) * dst_stride + col * 4 + c;
                    break :blk rgba[up_off];
                };
                // upper-left
                const upleft: u8 = if (row == 0 or col == 0) 0 else blk: {
                    const ul_off = (row - 1) * dst_stride + (col - 1) * 4 + c;
                    break :blk rgba[ul_off];
                };

                const recon: u8 = switch (filter_byte) {
                    0 => x, // None
                    1 => x +% left, // Sub
                    2 => x +% above, // Up
                    3 => x +% @as(u8, @intCast((@as(u16, left) + @as(u16, above)) / 2)), // Average
                    4 => x +% paethPredictor(left, above, upleft), // Paeth
                    else => return error.Corrupt,
                };

                rgba[row * dst_stride + col * 4 + c] = recon;
            }
            // For RGB source, fill alpha = 255
            if (bpp_uz == 3) {
                rgba[row * dst_stride + col * 4 + 3] = 255;
            }
        }
    }

    return Image{ .width = width, .height = height, .rgba = rgba };
}

fn paethPredictor(a: u8, b: u8, c: u8) u8 {
    // PNG spec §9.4 Paeth predictor
    const ia = @as(i16, a);
    const ib = @as(i16, b);
    const ic = @as(i16, c);
    const p = ia + ib - ic;
    const pa = @abs(p - ia);
    const pb = @abs(p - ib);
    const pc = @abs(p - ic);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// Signed magnitude of a residual byte (libpng MSAD metric): a small +/- value
/// near 0 or 256 scores low, mid-range scores high.
fn sad(b: u8) u16 {
    const u: u16 = b;
    return @min(u, 256 - u);
}

/// Residual of byte `i` of scanline `cur` under PNG filter `f` (0..4), given the
/// previous ORIGINAL row `prev` and bytes-per-pixel `bpp`. Inverse of the
/// decoder's reconstruction (png.zig:185). All arithmetic wraps.
fn filterByte(f: u8, cur: []const u8, prev: []const u8, i: usize, bpp: usize) u8 {
    const x = cur[i];
    const left: u8 = if (i >= bpp) cur[i - bpp] else 0;
    const above: u8 = prev[i];
    const upleft: u8 = if (i >= bpp) prev[i - bpp] else 0;
    return switch (f) {
        0 => x, // None
        1 => x -% left, // Sub
        2 => x -% above, // Up
        3 => x -% @as(u8, @intCast((@as(u16, left) + @as(u16, above)) / 2)), // Average
        4 => x -% paethPredictor(left, above, upleft), // Paeth
        else => unreachable,
    };
}

/// Choose the PNG filter (0..4) for one scanline by Minimum Sum of Absolute
/// Differences, write the chosen residual into `out` (out.len == cur.len), and
/// return the filter type. `prev` = previous original row (zero slice on row 0).
/// Tie → lowest filter index (deterministic).
fn chooseScanlineFilter(cur: []const u8, prev: []const u8, bpp: usize, out: []u8) u8 {
    var best_f: u8 = 0;
    var best_score: u64 = std.math.maxInt(u64);
    var f: u8 = 0;
    while (f < 5) : (f += 1) {
        var score: u64 = 0;
        var i: usize = 0;
        while (i < cur.len) : (i += 1) score += sad(filterByte(f, cur, prev, i, bpp));
        if (score < best_score) {
            best_score = score;
            best_f = f;
        }
    }
    var i: usize = 0;
    while (i < cur.len) : (i += 1) out[i] = filterByte(best_f, cur, prev, i, bpp);
    return best_f;
}

// ── encode ────────────────────────────────────────────────────────────────────

/// Build a PNG from pre-filtered scanline data.
/// `filtered`: h rows of (1 filter-byte + row-bytes), ready for zlib.
/// `color_type`: 2=RGB, 6=RGBA.
fn buildPng(alloc: Allocator, filtered: []const u8, w: u32, h: u32, color_type: u8) ![]u8 {
    // zlib-wrap the filtered data with real DEFLATE compression (std flate).
    const compressed = try zlibDeflate(alloc, filtered);
    defer alloc.free(compressed);

    // Build PNG using Io.Writer.Allocating
    var out_aw: std.Io.Writer.Allocating = .init(alloc);
    defer out_aw.deinit();
    const w_out = &out_aw.writer;

    // PNG signature
    try w_out.writeAll(&png_signature);

    // IHDR chunk
    {
        var ihdr_data: [13]u8 = undefined;
        mem.writeInt(u32, ihdr_data[0..4], w, .big);
        mem.writeInt(u32, ihdr_data[4..8], h, .big);
        ihdr_data[8] = 8; // bit depth
        ihdr_data[9] = color_type;
        ihdr_data[10] = 0; // compression
        ihdr_data[11] = 0; // filter method
        ihdr_data[12] = 0; // interlace
        try writeChunk(w_out, "IHDR", &ihdr_data);
    }

    // IDAT chunk
    try writeChunk(w_out, "IDAT", compressed);

    // IEND chunk
    try writeChunk(w_out, "IEND", &.{});

    return out_aw.toOwnedSlice();
}

fn writeChunk(w: *std.Io.Writer, chunk_type: *const [4]u8, data: []const u8) !void {
    const len: u32 = @intCast(data.len);
    try w.writeInt(u32, len, .big);
    try w.writeAll(chunk_type);
    try w.writeAll(data);
    // CRC over type + data
    var crc = std.hash.Crc32.init();
    crc.update(chunk_type);
    crc.update(data);
    try w.writeInt(u32, crc.final(), .big);
}

/// Compress `data` into a zlib stream with real DEFLATE (std.compress.flate,
/// `.zlib` container → 2-byte header + deflate body + adler32 footer). Mirrors
/// the server's gzip helper; zero-dep (Zig std). png.decode already inflates this.
fn zlibDeflate(alloc: Allocator, data: []const u8) ![]u8 {
    const flate = std.compress.flate;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    try aw.ensureUnusedCapacity(64);
    const window = try alloc.alloc(u8, flate.max_window_len);
    defer alloc.free(window);
    var comp = try flate.Compress.init(&aw.writer, window, .zlib, flate.Compress.Options.default);
    try comp.writer.writeAll(data);
    try comp.finish();
    return aw.toOwnedSlice();
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "round-trip 4x3 RGBA through deflate encode" {
    var pixels: [4 * 3 * 4]u8 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @intCast((i * 7) % 256);
    const png_bytes = try encodeRgba(testing.allocator, &pixels, 4, 3);
    defer testing.allocator.free(png_bytes);
    var img = try decode(testing.allocator, png_bytes);
    defer img.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 4), img.width);
    try testing.expectEqual(@as(u32, 3), img.height);
    try testing.expectEqualSlices(u8, &pixels, img.rgba);
}

test "decode applies sub/up/average/paeth filters" {
    // 2x4 RGB image, one scanline per filter type 1..4. Build the raw
    // (filtered) stream by hand, wrap in a valid PNG via rawPngRgb helper
    // (same chunk plumbing as encodeRgba but accepts pre-filtered bytes).
    // Expected unfiltered pixels computed per the PNG spec (bpp=3, 2 pixels/row):
    //
    //   line0 filter=1 (Sub):    filtered=[10,20,30, 5,5,5]
    //     px0: (0+10, 0+20, 0+30) = (10,20,30)
    //     px1: (10+5, 20+5, 30+5) = (15,25,35)
    //
    //   line1 filter=2 (Up):     filtered=[1,1,1, 1,1,1], above=(10,20,30,15,25,35)
    //     px0: (1+10, 1+20, 1+30) = (11,21,31)
    //     px1: (1+15, 1+25, 1+35) = (16,26,36)
    //
    //   line2 filter=3 (Average): filtered=[0,0,0, 0,0,0], above=(11,21,31,16,26,36)
    //     px0 R: 0 + floor((left=0 + above=11)/2) = 5
    //     px0 G: 0 + floor((0+21)/2)              = 10
    //     px0 B: 0 + floor((0+31)/2)              = 15
    //     px1 R: 0 + floor((left=5 + above=16)/2) = 10
    //     px1 G: 0 + floor((10+26)/2)             = 18
    //     px1 B: 0 + floor((15+36)/2)             = 25
    //
    //   line3 filter=4 (Paeth):   filtered=[0,0,0, 0,0,0], above=(5,10,15,10,18,25)
    //     px0 R: paeth(a=0,b=5,c=0): pa=5,pb=0,pc=5 → b=5;    0+5  = 5
    //     px0 G: paeth(a=0,b=10,c=0): pa=10,pb=0,pc=10 → b=10; 0+10 = 10
    //     px0 B: paeth(a=0,b=15,c=0): pa=15,pb=0,pc=15 → b=15; 0+15 = 15
    //     px1 R: paeth(a=5,b=10,c=5): pa=5,pb=0,pc=10 → b=10;  0+10 = 10
    //     px1 G: paeth(a=10,b=18,c=10): pa=8,pb=0,pc=18 → b=18; 0+18 = 18
    //     px1 B: paeth(a=15,b=25,c=15): pa=10,pb=0,pc=25 → b=25; 0+25 = 25
    //
    // RGBA layout: 2 pixels/row × 4 bytes/pixel = 8 bytes/row.
    //   row 0 starts at byte 0,   row 1 at byte 8,
    //   row 2 at byte 16,         row 3 at byte 24.
    //
    // NOTE: the spec draft had `img.rgba[2 * 4 * 4 / 2]` for row-1 px-0 R.
    // That evaluates to 16 (row 2 start), not 8 (row 1 start).
    // Corrected to `img.rgba[1 * 2 * 4 + 0]` = img.rgba[8] per derivation above.
    const filtered = [_]u8{
        1, 10, 20, 30, 5, 5, 5,
        2, 1,  1,  1,  1, 1, 1,
        3, 0,  0,  0,  0, 0, 0,
        4, 0,  0,  0,  0, 0, 0,
    };
    const png_bytes = try rawPngRgb(testing.allocator, &filtered, 2, 4);
    defer testing.allocator.free(png_bytes);
    var img = try decode(testing.allocator, png_bytes);
    defer img.deinit(testing.allocator);
    // row 0, px 0, R = 10
    try testing.expectEqual(@as(u8, 10), img.rgba[0]);
    // row 0, px 1, R = 15  (offset = 1*4 = 4)
    try testing.expectEqual(@as(u8, 15), img.rgba[4]);
    // row 1, px 0, R = 11  (offset = 1 * 2 * 4 + 0 = 8)
    // spec draft had `img.rgba[2 * 4 * 4 / 2 + 0]` = img.rgba[16] which is row 2;
    // fixed to img.rgba[8] per the PNG spec derivation above.
    try testing.expectEqual(@as(u8, 11), img.rgba[1 * 2 * 4 + 0]);
    // row 0, px 0, A = 255 (RGB expanded to RGBA)
    try testing.expectEqual(@as(u8, 255), img.rgba[3]);
}

test "decode rejects garbage" {
    try testing.expectError(error.BadSignature, decode(testing.allocator, "notapng"));
}

test "chooseScanlineFilter: Sub wins on a horizontal ramp (row 0)" {
    // 4 RGBA pixels, R=G=B stepping +10, A=255; prev row all zeros (row 0).
    // None residual grows (10..40); Sub residual is the constant +10 delta
    // (and Paeth degenerates to Sub when above/upleft are 0) → Sub (index 1)
    // wins the tie by lowest index.
    const cur = [_]u8{ 10, 10, 10, 255, 20, 20, 20, 255, 30, 30, 30, 255, 40, 40, 40, 255 };
    const prev = [_]u8{0} ** 16;
    var out: [16]u8 = undefined;
    const f = chooseScanlineFilter(&cur, &prev, 4, &out);
    try testing.expectEqual(@as(u8, 1), f); // Sub
    // Sub residual: px0 = cur (left=0); px1.. = cur - left = (10,10,10,0)
    try testing.expectEqual(@as(u8, 10), out[4]); // px1 R = 20 - 10
    try testing.expectEqual(@as(u8, 0), out[7]); // px1 A = 255 - 255 (wrap)
}

test "chooseScanlineFilter: Up wins + zero residual on a vertically-constant row" {
    // row 1 identical to row 0 → both Up and Paeth residuals are all zeros
    // (score 0); the lowest-index tie-break picks Up (2) over Paeth (4).
    const prev = [_]u8{ 5, 9, 13, 255, 6, 10, 14, 255 };
    const cur = prev;
    var out: [8]u8 = undefined;
    const f = chooseScanlineFilter(&cur, &prev, 4, &out);
    try testing.expectEqual(@as(u8, 2), f); // Up
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 8), &out);
}

test "chooseScanlineFilter: deterministic (same input → same filter + residual)" {
    const cur = [_]u8{ 3, 200, 17, 255, 40, 12, 99, 255 };
    const prev = [_]u8{ 1, 190, 20, 255, 35, 30, 80, 255 };
    var a: [8]u8 = undefined;
    var b: [8]u8 = undefined;
    const fa = chooseScanlineFilter(&cur, &prev, 4, &a);
    const fb = chooseScanlineFilter(&cur, &prev, 4, &b);
    try testing.expectEqual(fa, fb);
    try testing.expectEqualSlices(u8, &a, &b);
}

test "encodeRgba round-trips a 16x16 gradient" {
    var px: [16 * 16 * 4]u8 = undefined;
    for (0..16) |y| for (0..16) |x| {
        const o = (y * 16 + x) * 4;
        px[o + 0] = @intCast(x * 16);
        px[o + 1] = @intCast(y * 16);
        px[o + 2] = @intCast((x + y) * 8);
        px[o + 3] = 255;
    };
    const bytes = try encodeRgba(testing.allocator, &px, 16, 16);
    defer testing.allocator.free(bytes);
    var img = try decode(testing.allocator, bytes);
    defer img.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &px, img.rgba);
}

test "encodeRgba adaptive output is smaller than forced filter-None" {
    // A 64x8 image whose rows are smooth horizontal ramps: Sub/Paeth filtering
    // collapses each row to a near-constant residual, which DEFLATE crushes far
    // better than the raw filter-None bytes.
    const w: u32 = 64;
    const h: u32 = 8;
    const stride: usize = @as(usize, w) * 4;
    var px = try testing.allocator.alloc(u8, @as(usize, h) * stride);
    defer testing.allocator.free(px);
    for (0..h) |y| for (0..w) |x| {
        const o = y * stride + x * 4;
        px[o + 0] = @intCast((x * 3) % 256);
        px[o + 1] = @intCast((x * 3 + 40) % 256);
        px[o + 2] = @intCast((x * 3 + 80) % 256);
        px[o + 3] = 255;
    };
    const adaptive = try encodeRgba(testing.allocator, px, w, h);
    defer testing.allocator.free(adaptive);

    // Build the filter-None baseline via the same buildPng plumbing.
    const none_stream = try testing.allocator.alloc(u8, @as(usize, h) * (1 + stride));
    defer testing.allocator.free(none_stream);
    var fi: usize = 0;
    for (0..h) |row| {
        none_stream[fi] = 0;
        fi += 1;
        @memcpy(none_stream[fi .. fi + stride], px[row * stride .. row * stride + stride]);
        fi += stride;
    }
    const none = try buildPng(testing.allocator, none_stream, w, h, 6);
    defer testing.allocator.free(none);

    try testing.expect(adaptive.len < none.len);
}

test "encodeRgba is deterministic" {
    var px: [8 * 8 * 4]u8 = undefined;
    for (&px, 0..) |*p, i| p.* = @intCast((i * 13 + 7) % 256);
    const a = try encodeRgba(testing.allocator, &px, 8, 8);
    defer testing.allocator.free(a);
    const b = try encodeRgba(testing.allocator, &px, 8, 8);
    defer testing.allocator.free(b);
    try testing.expectEqualSlices(u8, a, b);
}
