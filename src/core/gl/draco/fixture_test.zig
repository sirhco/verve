const std = @import("std");
const draco = @import("draco.zig");
const draco_fixtures = @import("draco_fixtures");

const quad_drc = draco_fixtures.quad_drc;

test "parseHeader on the committed real Draco stream" {
    var buf = draco.DecoderBuffer.init(quad_drc);
    const h = try draco.parseHeader(&buf);
    try std.testing.expectEqual(draco.GeometryType.triangular_mesh, h.encoder_type);
    try std.testing.expectEqual(draco.EncoderMethod.edgebreaker, h.encoder_method);
    try std.testing.expectEqual(@as(u16, 0x0202), h.bitstreamVersion());
}
