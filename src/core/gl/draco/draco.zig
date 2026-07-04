//! Pure-Zig Draco (KHR_draco_mesh_compression) decode — build-time only.
//! Slice A: container + entropy foundation. No mesh output yet.
pub const Error = error{ BadMagic, Truncated, UnsupportedDracoVersion, UnsupportedGeometry, Corrupt, OutOfMemory };

pub const DecoderBuffer = @import("buffer.zig").DecoderBuffer;
