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

/// Reads `num_components` `min_values_` floats (`AttributeQuantizationTransform::
/// DecodeParameters` writes exactly `num_components` of them — 3 for POSITION,
/// 2 for TEXCOORD). `min` is a fixed `[3]f32`; components beyond `num_components`
/// stay zero (never read by `dequantize`, whose `comp` index is `< num_components`).
/// `num_components` must be in `[1, 3]`.
pub fn parseQuantParams(buf: *DecoderBuffer, num_components: usize) Error!QuantParams {
    if (num_components == 0 or num_components > 3) return Error.UnsupportedDracoFeature;
    var min: [3]f32 = .{ 0, 0, 0 };
    for (min[0..num_components]) |*m| {
        const bits = try buf.readInt(u32);
        m.* = @bitCast(bits);
    }
    const range_bits = try buf.readInt(u32);
    const range: f32 = @bitCast(range_bits);
    const bits = try buf.readInt(u8);
    if (bits < 1 or bits > 30) return Error.UnsupportedDracoFeature; // IsQuantizationValid
    return .{ .min = min, .range = range, .bits = bits };
}

/// Dequantize a single component value per Draco `AttributeQuantizationTransform::DequantizeValues`.
/// Formula: `max_q = (1 << bits) - 1; delta = range / max_q; value = min[comp] + q * delta`.
/// Matches Draco's exact operation order for byte-exact f32 output.
pub fn dequantize(q: u32, comp: usize, p: QuantParams) f32 {
    const max_q: f32 = @floatFromInt((@as(u32, 1) << @intCast(p.bits)) - 1);
    const delta: f32 = p.range / max_q;
    return p.min[comp] + @as(f32, @floatFromInt(q)) * delta;
}

test "dequantize matches Draco formula min + q*(range/max)" {
    const p = QuantParams{ .min = .{ -1.0, 0.0, 2.0 }, .range = 4.0, .bits = 8 };
    // max quantized = (1<<8)-1 = 255; delta = 4/255.
    try std.testing.expectEqual(@as(f32, -1.0), dequantize(0, 0, p));
    try std.testing.expectEqual(@as(f32, 3.0), dequantize(255, 0, p)); // -1 + 255*(4/255) = 3
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 + 4.0 * (128.0 / 255.0)), dequantize(128, 2, p), 1e-6);
}
