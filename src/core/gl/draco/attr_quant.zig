//! Quantization-parameter parse — faithful port of Draco
//! `AttributeQuantizationTransform::DecodeParameters`
//! (`src/draco/attributes/attribute_quantization_transform.cc`).
//!
//! Wire layout (read in this exact order): `min_values_[num_components]` as
//! `float`, then `range_` as `float`, then `quantization_bits_` as `uint8_t`.
//! `IsQuantizationValid` bounds `quantization_bits` to `[1, 30]` — anything
//! outside that range is rejected as `Error.UnsupportedDracoFeature` (the
//! upstream decoder returns `false`/DRACO_ERROR here, which this port maps to
//! the same "we cannot safely proceed" bucket used everywhere else).
const std = @import("std");
const draco = @import("draco.zig");
const DecoderBuffer = draco.DecoderBuffer;
pub const Error = draco.Error;

/// Position always has exactly 3 components in our fixtures, so `min` is
/// fixed-size per the brief's exact struct shape (Tasks 3-4 depend on this
/// name/shape verbatim).
pub const QuantParams = struct {
    min: [3]f32,
    range: f32,
    bits: u8,
};

/// `num_components` is fixed at 3 (position-only scope of this slice); the
/// caller (`attributes.parseAttrHeader`) has already validated
/// `header.num_components == 3` before calling this.
pub fn parseQuantParams(buf: *DecoderBuffer) Error!QuantParams {
    var min: [3]f32 = undefined;
    for (&min) |*m| {
        const bits = try buf.readInt(u32);
        m.* = @bitCast(bits);
    }
    const range_bits = try buf.readInt(u32);
    const range: f32 = @bitCast(range_bits);
    const bits = try buf.readInt(u8);
    if (bits < 1 or bits > 30) return Error.UnsupportedDracoFeature; // IsQuantizationValid
    return .{ .min = min, .range = range, .bits = bits };
}
