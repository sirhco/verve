//! Minimal KTX2 container writer + reader for our BC7 subset (native-only).
//!
//! KTX2 spec: https://registry.khronos.org/KTX/specs/2.0/ktxspec.v2.html
//! KHR Data Format 1.3: https://registry.khronos.org/DataFormat/specs/1.3/dataformat.1.3.html
//!
//! PIN decisions (v1):
//!
//! * Mip storage order: LARGEST-FIRST in file (same order bc7.encodeImage returns).
//!   KTX2 spec recommends smallest-first; we own the reader so order is arbitrary.
//!   Level index entries carry absolute byte offsets pointing to actual data.
//!
//! * No KVD (key/value data). kvdByteOffset=0, kvdByteLength=0.
//! * No supercompression. supercompressionScheme=0.
//! * No inter-level padding. BC7 blocks are always 16-byte multiples, satisfying
//!   the KTX2 alignment requirement of max(typeSize=1, 4) = 4 bytes.
//!
//! Exact DFD emitted (28 bytes; S3 JS parser must mirror these byte offsets):
//!   DFD[0..3]   dfdTotalSize = 28 (u32 LE)        — includes this field
//!   DFD[4..7]   vendorId=0 | descriptorType=0      — u32 LE = 0x00000000
//!   DFD[8..9]   versionNumber = 2 (u16 LE)
//!   DFD[10..11] descriptorBlockSize = 24 (u16 LE)  — size of block from [4..27]
//!   DFD[12]     colorModel = 134 (KHR_DF_MODEL_BC7)
//!   DFD[13]     colorPrimaries = 1 (KHR_DF_PRIMARIES_BT709)
//!   DFD[14]     transferFunction = 2 (sRGB) or 1 (linear/UNORM)
//!   DFD[15]     flags = 0
//!   DFD[16]     texelBlockDimension0 = 3 (block width  - 1 = 4 - 1)
//!   DFD[17]     texelBlockDimension1 = 3 (block height - 1 = 4 - 1)
//!   DFD[18]     texelBlockDimension2 = 0
//!   DFD[19]     texelBlockDimension3 = 0
//!   DFD[20..27] bytesPlane = [16, 0, 0, 0, 0, 0, 0, 0]  — 16 bytes/BC7 block
//!
//! Absolute byte offsets for a file with N mip levels (all u32/u64 LE):
//!   0:             identifier (12 bytes)
//!   12:            header — 9 × u32 (36 bytes)
//!   48:            index  — dfdByteOffset(u32) dfdByteLength(u32)
//!                           kvdByteOffset(u32) kvdByteLength(u32)
//!                           sgdByteOffset(u64) sgdByteLength(u64)  (32 bytes)
//!   80:            level index — N entries × 3×u64 (N×24 bytes)
//!   80 + N×24:     DFD (28 bytes)
//!   80 + N×24 + 28: mip data, level 0 first (largest)
//!   … successive levels follow without padding …

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// KTX2 container identifier — 12 bytes (KTX 2.0 spec §3.1).
pub const ktx2_identifier = [12]u8{
    0xAB, 0x4B, 0x54, 0x58, 0x20, 0x32, 0x30, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A,
};

pub const VkFormat = enum(u32) {
    bc7_unorm = 145, // VK_FORMAT_BC7_UNORM_BLOCK
    bc7_srgb = 146, // VK_FORMAT_BC7_SRGB_BLOCK
};

/// Write a minimal KTX2 container wrapping already-encoded BC7 mip levels
/// (largest first, matching bc7.encodeImage output). `srgb` selects vkFormat
/// (146 sRGB / 145 UNORM) AND the DFD transfer function. Caller owns the
/// returned bytes (free with `alloc.free(result)`).
pub fn write(alloc: Allocator, levels: []const []const u8, w: u32, h: u32, srgb: bool) ![]u8 {
    const level_count: u32 = @intCast(levels.len);
    const vk_format: u32 = if (srgb) 146 else 145;
    const transfer: u8 = if (srgb) 2 else 1; // KHR_DF_TRANSFER_SRGB=2 / LINEAR=1

    // Fixed-size sections.
    const dfd_size: u32 = 28; // 4-byte dfdTotalSize + 24-byte descriptor block
    const level_index_size: usize = @as(usize, level_count) * 24; // 3×u64 per level

    // Sum mip data.
    var mip_total: usize = 0;
    for (levels) |lvl| mip_total += lvl.len;

    // Absolute offsets (see module doc).
    const off_ident: usize = 0;
    const off_header: usize = 12;
    const off_index: usize = 48;
    const off_level_idx: usize = 80;
    const off_dfd: usize = 80 + level_index_size;
    const off_mip: usize = off_dfd + dfd_size;
    const total: usize = off_mip + mip_total;

    var out = try alloc.alloc(u8, total);
    errdefer alloc.free(out);
    @memset(out, 0);

    // ── 1. Identifier ────────────────────────────────────────────────────────
    @memcpy(out[off_ident .. off_ident + 12], &ktx2_identifier);

    // ── 2. Header (9 × u32 LE) ───────────────────────────────────────────────
    var p: usize = off_header;
    std.mem.writeInt(u32, out[p..][0..4], vk_format, .little);
    p += 4;
    std.mem.writeInt(u32, out[p..][0..4], 1, .little); // typeSize
    p += 4;
    std.mem.writeInt(u32, out[p..][0..4], w, .little);
    p += 4;
    std.mem.writeInt(u32, out[p..][0..4], h, .little);
    p += 4;
    std.mem.writeInt(u32, out[p..][0..4], 0, .little); // pixelDepth
    p += 4;
    std.mem.writeInt(u32, out[p..][0..4], 0, .little); // layerCount
    p += 4;
    std.mem.writeInt(u32, out[p..][0..4], 1, .little); // faceCount
    p += 4;
    std.mem.writeInt(u32, out[p..][0..4], level_count, .little);
    p += 4;
    std.mem.writeInt(u32, out[p..][0..4], 0, .little); // supercompressionScheme
    p += 4;
    // p == 48

    // ── 3. Index (2×u32 + 2×u32 + 2×u64 = 32 bytes) ─────────────────────────
    p = off_index;
    std.mem.writeInt(u32, out[p..][0..4], @intCast(off_dfd), .little); // dfdByteOffset
    p += 4;
    std.mem.writeInt(u32, out[p..][0..4], dfd_size, .little); // dfdByteLength
    p += 4;
    std.mem.writeInt(u32, out[p..][0..4], 0, .little); // kvdByteOffset
    p += 4;
    std.mem.writeInt(u32, out[p..][0..4], 0, .little); // kvdByteLength
    p += 4;
    std.mem.writeInt(u64, out[p..][0..8], 0, .little); // sgdByteOffset
    p += 8;
    std.mem.writeInt(u64, out[p..][0..8], 0, .little); // sgdByteLength
    p += 8;
    // p == 80

    // ── 4. Level index (N × 3×u64) ───────────────────────────────────────────
    p = off_level_idx;
    var mip_off: usize = off_mip;
    for (levels) |lvl| {
        std.mem.writeInt(u64, out[p..][0..8], mip_off, .little); // byteOffset
        p += 8;
        std.mem.writeInt(u64, out[p..][0..8], lvl.len, .little); // byteLength
        p += 8;
        std.mem.writeInt(u64, out[p..][0..8], lvl.len, .little); // uncompressedByteLength
        p += 8;
        mip_off += lvl.len;
    }

    // ── 5. DFD (28 bytes; see module doc for offsets) ────────────────────────
    p = off_dfd;
    std.mem.writeInt(u32, out[p..][0..4], dfd_size, .little); // dfdTotalSize
    p += 4;
    std.mem.writeInt(u32, out[p..][0..4], 0, .little); // vendorId=0 | descriptorType=0
    p += 4;
    std.mem.writeInt(u16, out[p..][0..2], 2, .little); // versionNumber
    p += 2;
    std.mem.writeInt(u16, out[p..][0..2], 24, .little); // descriptorBlockSize (bytes [4..27])
    p += 2;
    out[p] = 134;
    p += 1; // colorModel = KHR_DF_MODEL_BC7
    out[p] = 1;
    p += 1; // colorPrimaries = KHR_DF_PRIMARIES_BT709
    out[p] = transfer;
    p += 1; // transferFunction
    out[p] = 0;
    p += 1; // flags
    out[p] = 3;
    p += 1; // texelBlockDimension0 (4x4 block width  - 1)
    out[p] = 3;
    p += 1; // texelBlockDimension1 (4x4 block height - 1)
    out[p] = 0;
    p += 1; // texelBlockDimension2
    out[p] = 0;
    p += 1; // texelBlockDimension3
    out[p] = 16;
    p += 1; // bytesPlane[0] = 16 (bytes per BC7 4×4 block)
    out[p] = 0;
    p += 1;
    out[p] = 0;
    p += 1;
    out[p] = 0;
    p += 1;
    out[p] = 0;
    p += 1;
    out[p] = 0;
    p += 1;
    out[p] = 0;
    p += 1;
    out[p] = 0;
    p += 1;
    // p == off_dfd + 28 == off_mip

    // ── 6. Mip data (largest-first) ──────────────────────────────────────────
    mip_off = off_mip;
    for (levels) |lvl| {
        @memcpy(out[mip_off .. mip_off + lvl.len], lvl);
        mip_off += lvl.len;
    }

    return out;
}

pub const LevelRef = struct { offset: usize, len: usize };

pub const Info = struct {
    w: u32,
    h: u32,
    srgb: bool,
    vk_format: VkFormat,
    level_count: u32,
    /// Mip levels in LARGEST-FIRST order. Each `LevelRef` indexes into the
    /// `bytes` slice passed to `read`. Caller must free this slice:
    /// `alloc.free(info.levels)`.
    levels: []LevelRef,
};

/// Parse our KTX2 subset. Validates the identifier and rejects
/// supercompressionScheme != 0 or unknown vkFormat. Returns `Info` whose
/// `.levels` slice is allocated from `alloc` (caller frees); the referenced
/// data lives inside `bytes`. Level refs are ordered LARGEST-FIRST (matching
/// the storage order we write).
pub fn read(alloc: Allocator, bytes: []const u8) !Info {
    // ── Identifier ────────────────────────────────────────────────────────────
    if (bytes.len < 12) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..12], &ktx2_identifier)) return error.InvalidIdentifier;

    // ── Header ────────────────────────────────────────────────────────────────
    const min_header: usize = 12 + 36 + 32; // ident + header + index
    if (bytes.len < min_header) return error.Truncated;

    var p: usize = 12;
    const vk_fmt_raw = std.mem.readInt(u32, bytes[p..][0..4], .little);
    p += 4;
    _ = std.mem.readInt(u32, bytes[p..][0..4], .little); // typeSize
    p += 4;
    const pw = std.mem.readInt(u32, bytes[p..][0..4], .little);
    p += 4;
    const ph = std.mem.readInt(u32, bytes[p..][0..4], .little);
    p += 4;
    _ = std.mem.readInt(u32, bytes[p..][0..4], .little); // pixelDepth
    p += 4;
    _ = std.mem.readInt(u32, bytes[p..][0..4], .little); // layerCount
    p += 4;
    _ = std.mem.readInt(u32, bytes[p..][0..4], .little); // faceCount
    p += 4;
    const level_count = std.mem.readInt(u32, bytes[p..][0..4], .little);
    p += 4;
    const super = std.mem.readInt(u32, bytes[p..][0..4], .little);
    p += 4;
    // p == 48

    if (super != 0) return error.SupercompressionNotSupported;

    const vk_format: VkFormat = switch (vk_fmt_raw) {
        145 => .bc7_unorm,
        146 => .bc7_srgb,
        else => return error.UnsupportedFormat,
    };
    const srgb = (vk_format == .bc7_srgb);

    // ── Index (skip — offsets are deterministic from our writer) ─────────────
    // Skip dfdByteOffset(u32) dfdByteLength(u32) kvd*(u32×2) sgd*(u64×2) = 32 bytes
    p += 32;
    // p == 80

    // ── Level index ───────────────────────────────────────────────────────────
    const level_idx_end: usize = 80 + @as(usize, level_count) * 24;
    if (bytes.len < level_idx_end) return error.Truncated;

    var level_refs = try alloc.alloc(LevelRef, level_count);
    errdefer alloc.free(level_refs);

    for (0..level_count) |i| {
        const byte_off = std.mem.readInt(u64, bytes[p..][0..8], .little);
        p += 8;
        const byte_len = std.mem.readInt(u64, bytes[p..][0..8], .little);
        p += 8;
        _ = std.mem.readInt(u64, bytes[p..][0..8], .little); // uncompressedByteLength
        p += 8;

        // Bounds-check the referenced region.
        if (byte_off > bytes.len or byte_len > bytes.len - byte_off)
            return error.Truncated;

        level_refs[i] = .{
            .offset = @intCast(byte_off),
            .len = @intCast(byte_len),
        };
    }

    return Info{
        .w = pw,
        .h = ph,
        .srgb = srgb,
        .vk_format = vk_format,
        .level_count = level_count,
        .levels = level_refs,
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

/// Build fake BC7-shaped mip levels for a w×h image (arbitrary content;
/// sizes match real BC7: ((w+3)/4)×((h+3)/4)×16 bytes). Fills with a
/// deterministic pattern so round-trip equality is meaningful.
fn fakeChain(alloc: Allocator, w: u32, h: u32, levels: u32) ![]const []const u8 {
    const chain = try alloc.alloc([]const u8, levels);
    var cw = w;
    var ch = h;
    for (0..levels) |i| {
        const bpr = (cw + 3) / 4;
        const bpc = (ch + 3) / 4;
        const sz: usize = @as(usize, bpr) * @as(usize, bpc) * 16;
        const lvl = try alloc.alloc(u8, sz);
        for (lvl, 0..) |*b, j| b.* = @truncate(j + i * 7);
        chain[i] = lvl;
        cw = @max(cw / 2, 1);
        ch = @max(ch / 2, 1);
    }
    return chain;
}

fn freeChain(alloc: Allocator, chain: []const []const u8) void {
    for (chain) |lvl| alloc.free(lvl);
    alloc.free(chain);
}

// ── (a) Round-trip tests ──────────────────────────────────────────────────────

test "round-trip srgb=false (bc7_unorm)" {
    const alloc = testing.allocator;
    const chain = try fakeChain(alloc, 8, 8, 3);
    defer freeChain(alloc, chain);

    const blob = try write(alloc, chain, 8, 8, false);
    defer alloc.free(blob);

    const info = try read(alloc, blob);
    defer alloc.free(info.levels);

    try testing.expectEqual(@as(u32, 8), info.w);
    try testing.expectEqual(@as(u32, 8), info.h);
    try testing.expectEqual(false, info.srgb);
    try testing.expectEqual(VkFormat.bc7_unorm, info.vk_format);
    try testing.expectEqual(@as(u32, 3), info.level_count);
    try testing.expectEqual(@as(usize, 3), info.levels.len);
    for (chain, 0..) |expected, i| {
        const ref = info.levels[i];
        try testing.expectEqualSlices(u8, expected, blob[ref.offset .. ref.offset + ref.len]);
    }
}

test "round-trip srgb=true (bc7_srgb)" {
    const alloc = testing.allocator;
    const chain = try fakeChain(alloc, 4, 8, 2);
    defer freeChain(alloc, chain);

    const blob = try write(alloc, chain, 4, 8, true);
    defer alloc.free(blob);

    const info = try read(alloc, blob);
    defer alloc.free(info.levels);

    try testing.expectEqual(@as(u32, 4), info.w);
    try testing.expectEqual(@as(u32, 8), info.h);
    try testing.expectEqual(true, info.srgb);
    try testing.expectEqual(VkFormat.bc7_srgb, info.vk_format);
    try testing.expectEqual(@as(u32, 2), info.level_count);
    for (chain, 0..) |expected, i| {
        const ref = info.levels[i];
        try testing.expectEqualSlices(u8, expected, blob[ref.offset .. ref.offset + ref.len]);
    }
}

// ── (b) Golden test ───────────────────────────────────────────────────────────
//
// Input: 1 mip level of 16 bytes (0x00..0x0F), w=4, h=4, srgb=false.
// File structure:
//   [0..11]   identifier
//   [12..47]  header  (vkFormat=145, typeSize=1, w=4, h=4, depth=0, layers=0,
//                       faces=1, levels=1, supercompression=0)
//   [48..79]  index   (dfdByteOffset=104, dfdByteLength=28, kvd=0/0, sgd=0/0)
//   [80..103] level[0] entry: byteOffset=132, byteLength=16, uncompressed=16
//   [104..131] DFD   (dfdTotalSize=28, …, colorModel=134, primaries=1,
//                      transfer=1 (linear), …, bytesPlane[0]=16)
//   [132..147] mip data (0x00..0x0F)
//
test "golden: 1-level 4×4 srgb=false matches frozen bytes" {
    const alloc = testing.allocator;
    const mip = [16]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    const levels = [_][]const u8{&mip};

    const got = try write(alloc, &levels, 4, 4, false);
    defer alloc.free(got);

    // Frozen expected bytes (148 total).
    // 0x91 = 145 (bc7_unorm), 0x68 = 104 (off_dfd), 0x84 = 132 (off_mip),
    // 0x86 = 134 (KHR_DF_MODEL_BC7), 0x18 = 24 (descBlockSize), 0x1C = 28.
    const expected = [_]u8{
        // Identifier [0..11]
        0xAB, 0x4B, 0x54, 0x58, 0x20, 0x32, 0x30, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A,
        // Header [12..47] — 9 × u32 LE
        0x91, 0x00, 0x00, 0x00, // vkFormat=145
        0x01, 0x00, 0x00, 0x00, // typeSize=1
        0x04, 0x00, 0x00, 0x00, // pixelWidth=4
        0x04, 0x00, 0x00, 0x00, // pixelHeight=4
        0x00, 0x00, 0x00, 0x00, // pixelDepth=0
        0x00, 0x00, 0x00, 0x00, // layerCount=0
        0x01, 0x00, 0x00, 0x00, // faceCount=1
        0x01, 0x00, 0x00, 0x00, // levelCount=1
        0x00, 0x00, 0x00, 0x00, // supercompressionScheme=0
        // Index [48..79]
        0x68, 0x00, 0x00, 0x00, // dfdByteOffset=104=0x68
        0x1C, 0x00, 0x00, 0x00, // dfdByteLength=28=0x1C
        0x00, 0x00, 0x00, 0x00, // kvdByteOffset=0
        0x00, 0x00, 0x00, 0x00, // kvdByteLength=0
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // sgdByteOffset=0
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // sgdByteLength=0
        // Level index entry[0] [80..103] — 3 × u64 LE
        0x84, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // byteOffset=132=0x84
        0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // byteLength=16
        0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // uncompressedByteLength=16
        // DFD [104..131] — 28 bytes
        0x1C, 0x00, 0x00, 0x00, // dfdTotalSize=28
        0x00, 0x00, 0x00, 0x00, // vendorId=0 | descriptorType=0
        0x02, 0x00, // versionNumber=2
        0x18, 0x00, // descriptorBlockSize=24
        0x86, // colorModel=134 (KHR_DF_MODEL_BC7)
        0x01, // colorPrimaries=1 (BT.709)
        0x01, // transferFunction=1 (linear/UNORM, srgb=false)
        0x00, // flags=0
        0x03, // texelBlockDimension0=3
        0x03, // texelBlockDimension1=3
        0x00, // texelBlockDimension2=0
        0x00, // texelBlockDimension3=0
        0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // bytesPlane=[16,0,0,0,0,0,0,0]
        // Mip data [132..147]
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
    };
    try testing.expectEqualSlices(u8, &expected, got);
}

// ── (c) Integration with bc7 ─────────────────────────────────────────────────

test "bc7 compose: encodeImage output wraps and round-trips through ktx2" {
    const alloc = testing.allocator;
    const bc7 = @import("bc7.zig");

    // 8×4 RGBA image with a ramp pattern.
    const w: u32 = 8;
    const h: u32 = 4;
    const img = try alloc.alloc(u8, w * h * 4);
    defer alloc.free(img);
    for (img, 0..) |*b, i| b.* = @truncate(i);

    const chain = try bc7.encodeImage(alloc, img, w, h);
    defer {
        for (chain) |lvl| alloc.free(lvl);
        alloc.free(chain);
    }

    const blob = try write(alloc, chain, w, h, true);
    defer alloc.free(blob);

    const info = try read(alloc, blob);
    defer alloc.free(info.levels);

    try testing.expectEqual(w, info.w);
    try testing.expectEqual(h, info.h);
    try testing.expectEqual(true, info.srgb);
    try testing.expectEqual(@as(u32, @intCast(chain.len)), info.level_count);
    for (chain, 0..) |expected, i| {
        const ref = info.levels[i];
        try testing.expectEqual(expected.len, ref.len);
        try testing.expectEqualSlices(u8, expected, blob[ref.offset .. ref.offset + ref.len]);
    }
}

// ── (d) Reject tests ──────────────────────────────────────────────────────────

test "reject: empty bytes → error.Truncated" {
    const result = read(testing.allocator, &[_]u8{});
    try testing.expectError(error.Truncated, result);
}

test "reject: bad identifier → error.InvalidIdentifier" {
    var bad: [80]u8 = .{0} ** 80;
    bad[0] = 0xFF; // corrupt first byte
    const result = read(testing.allocator, &bad);
    try testing.expectError(error.InvalidIdentifier, result);
}

test "reject: truncated after identifier → error.Truncated" {
    // Provide valid identifier but no header.
    const result = read(testing.allocator, &ktx2_identifier);
    try testing.expectError(error.Truncated, result);
}
