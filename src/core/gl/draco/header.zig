const std = @import("std");
const draco = @import("draco.zig");
const DecoderBuffer = draco.DecoderBuffer;
pub const Error = draco.Error;

pub const GeometryType = enum(u8) { point_cloud = 0, triangular_mesh = 1 };
pub const EncoderMethod = enum(u8) { sequential = 0, edgebreaker = 1 };
pub const metadata_flag: u16 = 0x8000;

// Supported bitstream version range (inclusive). Only 2.2 (the version we
// decode) is accepted — the edgebreaker connectivity code hard-codes the
// >= 2.2 field layout with no per-call version check, so anything below 2.2
// must be rejected here or it would silently misparse downstream. Bump
// max_version only once a >2.2 fixture is ported; bump min_version only if
// pre-2.2 field-layout support is added to edgebreaker.zig.
const min_version: u16 = 0x0202; // 2.2
const max_version: u16 = 0x0202; // 2.2 (draco3dgltf current)

pub const Header = struct {
    version_major: u8,
    version_minor: u8,
    encoder_type: GeometryType,
    encoder_method: EncoderMethod,
    flags: u16,

    pub fn bitstreamVersion(self: Header) u16 {
        return (@as(u16, self.version_major) << 8) | self.version_minor;
    }
};

pub fn parseHeader(buf: *DecoderBuffer) Error!Header {
    const magic = try buf.readBytes(5);
    if (!std.mem.eql(u8, magic, "DRACO")) return Error.BadMagic;
    const vmaj = try buf.readInt(u8);
    const vmin = try buf.readInt(u8);
    const etype_raw = try buf.readInt(u8);
    const method_raw = try buf.readInt(u8);
    const flags = try buf.readInt(u16);

    const ver = (@as(u16, vmaj) << 8) | vmin;
    if (ver < min_version or ver > max_version) return Error.UnsupportedDracoVersion;
    const etype: GeometryType = switch (etype_raw) {
        0 => .point_cloud,
        1 => .triangular_mesh,
        else => return Error.Corrupt,
    };
    if (etype != .triangular_mesh) return Error.UnsupportedGeometry;
    const method: EncoderMethod = switch (method_raw) {
        0 => .sequential,
        1 => .edgebreaker,
        else => return Error.Corrupt,
    };
    return .{ .version_major = vmaj, .version_minor = vmin, .encoder_type = etype, .encoder_method = method, .flags = flags };
}

/// When the metadata flag is set, a metadata section follows the header; advance
/// past it (contents unused by the decoder). Draco metadata layout: a varint
/// byte-size prefix — skip that many bytes. (Matched to Draco `MetadataDecoder`
/// section framing; validated against a metadata-bearing fixture when one exists.)
pub fn skipMetadata(buf: *DecoderBuffer, header: Header) Error!void {
    if (header.flags & metadata_flag == 0) return;
    const size = try buf.decodeVarint(u32);
    try buf.skip(size);
}

test "parseHeader on real fixture bytes (bitstream v2.2, MESH, EDGEBREAKER)" {
    // Confirmed from a draco3dgltf-encoded glb: DRACO 02 02 01 01 00 00
    const bytes = [_]u8{ 'D', 'R', 'A', 'C', 'O', 0x02, 0x02, 0x01, 0x01, 0x00, 0x00 };
    var b = DecoderBuffer.init(&bytes);
    const h = try parseHeader(&b);
    try std.testing.expectEqual(@as(u8, 2), h.version_major);
    try std.testing.expectEqual(@as(u8, 2), h.version_minor);
    try std.testing.expectEqual(GeometryType.triangular_mesh, h.encoder_type);
    try std.testing.expectEqual(EncoderMethod.edgebreaker, h.encoder_method);
    try std.testing.expectEqual(@as(u16, 0x0202), h.bitstreamVersion());
    try std.testing.expectEqual(@as(u16, 0), h.flags);
}

test "parseHeader rejects bad magic / non-mesh / bad version" {
    {
        const bad = [_]u8{ 'X', 'R', 'A', 'C', 'O', 2, 2, 1, 1, 0, 0 };
        var b = DecoderBuffer.init(&bad);
        try std.testing.expectError(Error.BadMagic, parseHeader(&b));
    }
    {
        const pc = [_]u8{ 'D', 'R', 'A', 'C', 'O', 2, 2, 0, 1, 0, 0 }; // encoder_type 0 = point cloud
        var b = DecoderBuffer.init(&pc);
        try std.testing.expectError(Error.UnsupportedGeometry, parseHeader(&b));
    }
    {
        const old = [_]u8{ 'D', 'R', 'A', 'C', 'O', 1, 0, 1, 1, 0, 0 }; // v1.0 unsupported
        var b = DecoderBuffer.init(&old);
        try std.testing.expectError(Error.UnsupportedDracoVersion, parseHeader(&b));
    }
}

test "parseHeader rejects bitstream 2.1 (only 2.2 field layout is ported)" {
    // v2.1 would misparse under the edgebreaker >= 2.2 field layout if
    // accepted here, so parseHeader must narrow the accepted range to 2.2
    // only. bytes: DRACO 02 01 01 01 00 00
    const v21 = [_]u8{ 'D', 'R', 'A', 'C', 'O', 0x02, 0x01, 0x01, 0x01, 0x00, 0x00 };
    var b = DecoderBuffer.init(&v21);
    try std.testing.expectError(Error.UnsupportedDracoVersion, parseHeader(&b));
}

test "skipMetadata no-op when flag clear" {
    const bytes = [_]u8{ 'D', 'R', 'A', 'C', 'O', 2, 2, 1, 1, 0, 0, 0xAB };
    var b = DecoderBuffer.init(&bytes);
    const h = try parseHeader(&b);
    try skipMetadata(&b, h); // flags == 0 -> no advance
    try std.testing.expectEqual(@as(u8, 0xAB), try b.readInt(u8));
}
