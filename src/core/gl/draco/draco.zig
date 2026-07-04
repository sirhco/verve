//! Pure-Zig Draco (KHR_draco_mesh_compression) decode — build-time only.
//! Slice A: container + entropy foundation. No mesh output yet.
pub const Error = error{ BadMagic, Truncated, UnsupportedDracoVersion, UnsupportedGeometry, Corrupt, OutOfMemory };

pub const DecoderBuffer = @import("buffer.zig").DecoderBuffer;

pub const RAnsBitDecoder = @import("rans.zig").RAnsBitDecoder;
pub const decodeSymbols = @import("rans.zig").decodeSymbols;

pub const header = @import("header.zig");
pub const GeometryType = header.GeometryType;
pub const EncoderMethod = header.EncoderMethod;
pub const Header = header.Header;
pub const parseHeader = header.parseHeader;

test {
    _ = @import("buffer.zig");
    _ = @import("header.zig");
    _ = @import("rans.zig"); // pulls in rans_test_encoder.zig transitively
}
