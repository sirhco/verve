//! .venv prefiltered-environment format — writer + freestanding reader.
//! Carries build-time IBL data: irradiance cube, specular mip-chain, BRDF LUT.
//! Header layout (40 bytes, all integers little-endian u32):
//!   [0..4]   magic "VENV"
//!   [4..8]   version u32 = 1
//!   [8..12]  irr_size       (irradiance cube face edge length)
//!   [12..16] spec_size      (specular cube base face edge)
//!   [16..20] spec_mip_count
//!   [20..24] lut_size       (BRDF LUT face edge, square)
//!   [24..28] irr_off        (16-aligned, from file start)
//!   [28..32] spec_off       (16-aligned)
//!   [32..36] lut_off        (16-aligned)
//!   [36..40] reserved = 0
//! Texel format: RGBA16F — 8 bytes per texel (4 × u16 LE, half-float).
//! Run order:
//!   irradiance: 6 faces × irr_size² texels  (+X,−X,+Y,−Y,+Z,−Z)
//!   specular:   mip-major — for mip 0..spec_mip_count { 6 faces × (spec_size>>mip)² }
//!   lut:        lut_size² texels, row-major
//! Layout: header → pad16 → irr → pad16 → spec → pad16 → lut

const std = @import("std");

pub const magic = "VENV";
pub const version: u32 = 1;
pub const header_size: u32 = 40;
pub const texel_size: u32 = 8; // RGBA16F: 4 channels × 2 bytes

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn alignUp16(x: u32) u32 {
    return (x + 15) & ~@as(u32, 15);
}

/// Compute the byte length of the full specular mip-chain in u64 (no wrap).
/// Returns error.SizeMismatch if spec_size or spec_mip_count are zero,
/// or if any mip level shrinks to 0 (spec_size >> mip == 0).
fn specByteLen(spec_size: u32, spec_mip_count: u32) error{SizeMismatch}!u64 {
    if (spec_size == 0 or spec_mip_count == 0) return error.SizeMismatch;
    var total: u64 = 0;
    for (0..spec_mip_count) |mip| {
        const edge = spec_size >> @intCast(mip);
        if (edge == 0) return error.SizeMismatch; // absurd mip count
        total += @as(u64, edge) * @as(u64, edge) * 6 * @as(u64, texel_size);
    }
    return total;
}

/// Same computation for Reader (maps SizeMismatch → Truncated).
/// Uses checked arithmetic throughout to avoid u64 overflow panics.
fn specByteLenReader(spec_size: u32, spec_mip_count: u32) error{Truncated}!u64 {
    if (spec_size == 0 or spec_mip_count == 0) return error.Truncated;
    var total: u64 = 0;
    for (0..spec_mip_count) |mip| {
        const shift: u5 = if (mip < 32) @intCast(mip) else return error.Truncated;
        const edge = spec_size >> shift;
        if (edge == 0) return error.Truncated;
        const face_bytes = std.math.mul(u64, @as(u64, edge), @as(u64, edge)) catch return error.Truncated;
        const mip_bytes = std.math.mul(u64, face_bytes, 6 * @as(u64, texel_size)) catch return error.Truncated;
        total = std.math.add(u64, total, mip_bytes) catch return error.Truncated;
    }
    return total;
}

// ---------------------------------------------------------------------------
// pack — native-side writer
// ---------------------------------------------------------------------------

/// Inputs are complete RGBA16F runs in the exact on-disk order
/// (irr: face-major; spec: mip-major then face-major; lut: row-major).
/// Lengths are validated against the dimension fields (error.SizeMismatch).
pub fn pack(
    alloc: std.mem.Allocator,
    irr_size: u32,
    irr_rgba16f: []const u16,
    spec_size: u32,
    spec_mip_count: u32,
    spec_rgba16f: []const u16,
    lut_size: u32,
    lut_rgba16f: []const u16,
) ![]u8 {
    // -- Validate input run lengths -----------------------------------------
    if (irr_size == 0) return error.SizeMismatch;
    const irr_texels: u64 = @as(u64, irr_size) * @as(u64, irr_size) * 6;
    const irr_u16s: u64 = irr_texels * 4; // 4 u16 per RGBA16F texel
    if (irr_rgba16f.len != irr_u16s) return error.SizeMismatch;

    const spec_bytes = try specByteLen(spec_size, spec_mip_count);
    const spec_u16s: u64 = spec_bytes / 2;
    if (spec_rgba16f.len != spec_u16s) return error.SizeMismatch;

    if (lut_size == 0) return error.SizeMismatch;
    const lut_texels: u64 = @as(u64, lut_size) * @as(u64, lut_size);
    const lut_u16s: u64 = lut_texels * 4;
    if (lut_rgba16f.len != lut_u16s) return error.SizeMismatch;

    // -- Compute layout (16-aligned offsets) --------------------------------
    const irr_off: u32 = alignUp16(header_size);
    const irr_byte_len: u32 = @intCast(irr_texels * @as(u64, texel_size));
    const spec_off: u32 = alignUp16(irr_off + irr_byte_len);
    const spec_byte_len: u32 = @intCast(spec_bytes);
    const lut_off: u32 = alignUp16(spec_off + spec_byte_len);
    const lut_byte_len: u32 = @intCast(lut_texels * @as(u64, texel_size));
    const total_size: u32 = lut_off + lut_byte_len;

    // -- Allocate and zero --------------------------------------------------
    const buf = try alloc.alloc(u8, total_size);
    @memset(buf, 0);

    // -- Write header -------------------------------------------------------
    @memcpy(buf[0..4], magic);
    std.mem.writeInt(u32, buf[4..8], version, .little);
    std.mem.writeInt(u32, buf[8..12], irr_size, .little);
    std.mem.writeInt(u32, buf[12..16], spec_size, .little);
    std.mem.writeInt(u32, buf[16..20], spec_mip_count, .little);
    std.mem.writeInt(u32, buf[20..24], lut_size, .little);
    std.mem.writeInt(u32, buf[24..28], irr_off, .little);
    std.mem.writeInt(u32, buf[28..32], spec_off, .little);
    std.mem.writeInt(u32, buf[32..36], lut_off, .little);
    std.mem.writeInt(u32, buf[36..40], 0, .little); // reserved

    // -- Write runs ---------------------------------------------------------
    @memcpy(buf[irr_off..][0..irr_byte_len], std.mem.sliceAsBytes(irr_rgba16f));
    @memcpy(buf[spec_off..][0..spec_byte_len], std.mem.sliceAsBytes(spec_rgba16f));
    @memcpy(buf[lut_off..][0..lut_byte_len], std.mem.sliceAsBytes(lut_rgba16f));

    return buf;
}

// ---------------------------------------------------------------------------
// Reader — freestanding zero-copy view
// ---------------------------------------------------------------------------

/// Freestanding zero-copy view over a .venv byte buffer.
/// Validates magic/version/bounds; all slices point into `bytes`.
/// u64-widened size math throughout; errors never panic.
pub const Reader = struct {
    irr_size: u32,
    spec_size: u32,
    spec_mip_count: u32,
    lut_size: u32,
    irradiance: []const u8, // full 6-face run, GPU-uploadable as-is
    specular: []const u8, // full mip-major run
    lut: []const u8,

    pub fn init(bytes: []const u8) error{ BadMagic, BadVersion, Truncated }!Reader {
        // -- Header present? ------------------------------------------------
        if (bytes.len < header_size) return error.Truncated;

        // -- Magic / version ------------------------------------------------
        if (!std.mem.eql(u8, bytes[0..4], magic)) return error.BadMagic;
        const ver = std.mem.readInt(u32, bytes[4..8], .little);
        if (ver != version) return error.BadVersion;

        // -- Read dimension fields ------------------------------------------
        const irr_size = std.mem.readInt(u32, bytes[8..12], .little);
        const spec_size = std.mem.readInt(u32, bytes[12..16], .little);
        const spec_mip_count = std.mem.readInt(u32, bytes[16..20], .little);
        const lut_size = std.mem.readInt(u32, bytes[20..24], .little);
        const irr_off = std.mem.readInt(u32, bytes[24..28], .little);
        const spec_off = std.mem.readInt(u32, bytes[28..32], .little);
        const lut_off = std.mem.readInt(u32, bytes[32..36], .little);

        // -- Reject zero sizes ----------------------------------------------
        if (irr_size == 0 or spec_size == 0 or lut_size == 0) return error.Truncated;

        // -- Validate spec mip_count: ≥1 AND spec_size>>(mip_count-1) ≥1 ---
        if (spec_mip_count == 0) return error.Truncated;
        {
            const last_mip = spec_mip_count - 1;
            // If last_mip ≥ 32 then shift is UB; also edge would be 0
            if (last_mip >= 32) return error.Truncated;
            const last_edge = spec_size >> @intCast(last_mip);
            if (last_edge == 0) return error.Truncated;
        }

        const blen: u64 = bytes.len;

        // -- Bounds-check irradiance run (u64 checked mul — no panic) ------
        // irr_size² × 6 × 8: use std.math.mul to catch u64 overflow cleanly.
        const irr_sq = std.math.mul(u64, @as(u64, irr_size), @as(u64, irr_size)) catch return error.Truncated;
        const irr_len = std.math.mul(u64, irr_sq, 6 * @as(u64, texel_size)) catch return error.Truncated;
        if (@as(u64, irr_off) > blen or irr_len > blen - @as(u64, irr_off)) return error.Truncated;
        const irr_bytes: usize = @intCast(irr_len);

        // -- Bounds-check specular run (u64 mip-chain sum) ------------------
        const spec_len: u64 = specByteLenReader(spec_size, spec_mip_count) catch return error.Truncated;
        if (@as(u64, spec_off) > blen or spec_len > blen - @as(u64, spec_off)) return error.Truncated;
        const spec_bytes: usize = @intCast(spec_len);

        // -- Bounds-check LUT run (u64 checked mul — no panic) -------------
        const lut_sq = std.math.mul(u64, @as(u64, lut_size), @as(u64, lut_size)) catch return error.Truncated;
        const lut_len = std.math.mul(u64, lut_sq, @as(u64, texel_size)) catch return error.Truncated;
        if (@as(u64, lut_off) > blen or lut_len > blen - @as(u64, lut_off)) return error.Truncated;
        const lut_bytes: usize = @intCast(lut_len);

        return Reader{
            .irr_size = irr_size,
            .spec_size = spec_size,
            .spec_mip_count = spec_mip_count,
            .lut_size = lut_size,
            .irradiance = bytes[irr_off..][0..irr_bytes],
            .specular = bytes[spec_off..][0..spec_bytes],
            .lut = bytes[lut_off..][0..lut_bytes],
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "round-trip: irr=2 spec=4/2mips lut=2" {
    // Build minimal RGBA16F runs (all channels = 0x3C00 = 1.0 in f16)
    const irr_u16s = 2 * 2 * 6 * 4; // irr_size=2 → 4 texels/face × 6 faces × 4 u16
    const spec_u16s_mip0 = 4 * 4 * 6 * 4; // spec_size=4 mip0
    const spec_u16s_mip1 = 2 * 2 * 6 * 4; // spec_size=4>>1=2 mip1
    const lut_u16s = 2 * 2 * 4; // lut_size=2

    var irr_data: [irr_u16s]u16 = undefined;
    var spec_data: [spec_u16s_mip0 + spec_u16s_mip1]u16 = undefined;
    var lut_data: [lut_u16s]u16 = undefined;

    for (&irr_data, 0..) |*v, i| v.* = @intCast(i % 0xFFFF + 1);
    for (&spec_data, 0..) |*v, i| v.* = @intCast((i + 1) % 0xFFFF);
    for (&lut_data, 0..) |*v, i| v.* = @intCast((i + 2) % 0xFFFF);

    const bytes = try pack(
        testing.allocator,
        2,
        &irr_data,
        4,
        2,
        &spec_data,
        2,
        &lut_data,
    );
    defer testing.allocator.free(bytes);

    const r = try Reader.init(bytes);

    // Scalar fields
    try testing.expectEqual(@as(u32, 2), r.irr_size);
    try testing.expectEqual(@as(u32, 4), r.spec_size);
    try testing.expectEqual(@as(u32, 2), r.spec_mip_count);
    try testing.expectEqual(@as(u32, 2), r.lut_size);

    // Run slices byte-identical to input
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&irr_data), r.irradiance);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&spec_data), r.specular);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&lut_data), r.lut);

    // Offsets 16-aligned (read from raw header bytes)
    const irr_off = std.mem.readInt(u32, bytes[24..28], .little);
    const spec_off = std.mem.readInt(u32, bytes[28..32], .little);
    const lut_off = std.mem.readInt(u32, bytes[32..36], .little);
    try testing.expectEqual(@as(u32, 0), irr_off % 16);
    try testing.expectEqual(@as(u32, 0), spec_off % 16);
    try testing.expectEqual(@as(u32, 0), lut_off % 16);
}

test "hostile: irr_size wraps u32 multiply" {
    // 0x4000_0000: 6 × size² × 8 = 6 × 2^58 → wraps u32, must error via u64
    var buf = [_]u8{0} ** 64;
    @memcpy(buf[0..4], magic);
    std.mem.writeInt(u32, buf[4..8], version, .little);
    std.mem.writeInt(u32, buf[8..12], 0x4000_0000, .little); // irr_size
    std.mem.writeInt(u32, buf[12..16], 4, .little); // spec_size
    std.mem.writeInt(u32, buf[16..20], 1, .little); // spec_mip_count
    std.mem.writeInt(u32, buf[20..24], 2, .little); // lut_size
    std.mem.writeInt(u32, buf[24..28], 48, .little); // irr_off
    std.mem.writeInt(u32, buf[28..32], 48, .little); // spec_off
    std.mem.writeInt(u32, buf[32..36], 48, .little); // lut_off
    try testing.expectError(error.Truncated, Reader.init(&buf));
}

test "hostile: spec_mip_count = 0xFFFF_FFFF → Truncated" {
    var buf = [_]u8{0} ** 64;
    @memcpy(buf[0..4], magic);
    std.mem.writeInt(u32, buf[4..8], version, .little);
    std.mem.writeInt(u32, buf[8..12], 2, .little); // irr_size
    std.mem.writeInt(u32, buf[12..16], 4, .little); // spec_size
    std.mem.writeInt(u32, buf[16..20], 0xFFFF_FFFF, .little); // spec_mip_count
    std.mem.writeInt(u32, buf[20..24], 2, .little); // lut_size
    std.mem.writeInt(u32, buf[24..28], 48, .little);
    std.mem.writeInt(u32, buf[28..32], 48, .little);
    std.mem.writeInt(u32, buf[32..36], 48, .little);
    try testing.expectError(error.Truncated, Reader.init(&buf));
}

test "hostile: spec_mip_count > log2(spec_size)+1 → Truncated" {
    // spec_size=4 → log2=2, so mip_count=4 means spec_size>>3 = 0
    var buf = [_]u8{0} ** 64;
    @memcpy(buf[0..4], magic);
    std.mem.writeInt(u32, buf[4..8], version, .little);
    std.mem.writeInt(u32, buf[8..12], 2, .little); // irr_size
    std.mem.writeInt(u32, buf[12..16], 4, .little); // spec_size
    std.mem.writeInt(u32, buf[16..20], 4, .little); // spec_mip_count=4 → last_edge=4>>3=0
    std.mem.writeInt(u32, buf[20..24], 2, .little); // lut_size
    std.mem.writeInt(u32, buf[24..28], 48, .little);
    std.mem.writeInt(u32, buf[28..32], 48, .little);
    std.mem.writeInt(u32, buf[32..36], 48, .little);
    try testing.expectError(error.Truncated, Reader.init(&buf));
}

test "hostile: offsets past EOF → Truncated" {
    var buf = [_]u8{0} ** 64;
    @memcpy(buf[0..4], magic);
    std.mem.writeInt(u32, buf[4..8], version, .little);
    std.mem.writeInt(u32, buf[8..12], 2, .little); // irr_size
    std.mem.writeInt(u32, buf[12..16], 4, .little); // spec_size
    std.mem.writeInt(u32, buf[16..20], 1, .little); // spec_mip_count
    std.mem.writeInt(u32, buf[20..24], 2, .little); // lut_size
    std.mem.writeInt(u32, buf[24..28], 0xFFFF_FFF0, .little); // irr_off past EOF
    std.mem.writeInt(u32, buf[28..32], 48, .little);
    std.mem.writeInt(u32, buf[32..36], 48, .little);
    try testing.expectError(error.Truncated, Reader.init(&buf));
}

test "hostile: bad magic → BadMagic" {
    var buf = [_]u8{0} ** 64;
    try testing.expectError(error.BadMagic, Reader.init(&buf));
}

test "hostile: version 99 → BadVersion" {
    var buf = [_]u8{0} ** 64;
    @memcpy(buf[0..4], magic);
    std.mem.writeInt(u32, buf[4..8], 99, .little);
    try testing.expectError(error.BadVersion, Reader.init(&buf));
}

test "hostile: 10-byte buffer → Truncated" {
    var buf = [_]u8{0} ** 10;
    try testing.expectError(error.Truncated, Reader.init(&buf));
}

test "pack rejects mismatched irr run length → SizeMismatch" {
    // Correct: irr_size=2 → 2*2*6*4=96 u16s; supply 1
    var irr: [1]u16 = .{0};
    var spec: [4 * 4 * 6 * 4]u16 = undefined;
    @memset(&spec, 0);
    var lut: [2 * 2 * 4]u16 = undefined;
    @memset(&lut, 0);
    try testing.expectError(
        error.SizeMismatch,
        pack(testing.allocator, 2, &irr, 4, 1, &spec, 2, &lut),
    );
}

test "pack rejects mismatched spec run length → SizeMismatch" {
    var irr: [2 * 2 * 6 * 4]u16 = undefined;
    @memset(&irr, 0);
    var spec: [1]u16 = .{0}; // wrong — need 4*4*6*4=384 u16s
    var lut: [2 * 2 * 4]u16 = undefined;
    @memset(&lut, 0);
    try testing.expectError(
        error.SizeMismatch,
        pack(testing.allocator, 2, &irr, 4, 1, &spec, 2, &lut),
    );
}

test "pack rejects mismatched lut run length → SizeMismatch" {
    var irr: [2 * 2 * 6 * 4]u16 = undefined;
    @memset(&irr, 0);
    var spec: [4 * 4 * 6 * 4]u16 = undefined;
    @memset(&spec, 0);
    var lut: [1]u16 = .{0}; // wrong — need 2*2*4=16 u16s
    try testing.expectError(
        error.SizeMismatch,
        pack(testing.allocator, 2, &irr, 4, 1, &spec, 2, &lut),
    );
}
