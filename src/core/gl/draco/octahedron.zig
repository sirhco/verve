//! Faithful pure-Zig port of Draco's octahedral-normal decode math.
//!
//! Ports (Draco `main`):
//!   * `src/draco/compression/attributes/normal_compression_utils.h`
//!     -> `OctahedronToolBox` (quantization, diamond membership/inversion,
//!        ModMax/MakePositive, and the (s,t)->3D unit-vector reconstruction).
//!   * `.../prediction_schemes/prediction_scheme_normal_octahedron_transform_base.h`
//!     `..._decoding_transform.h`
//!     `..._canonicalized_transform_base.h`
//!     `..._canonicalized_decoding_transform.h`
//!     -> `octCanonicalizedOriginalValue` (the NORMAL_OCTAHEDRON_CANONICALIZED
//!        prediction-transform `ComputeOriginalValue`).
//!
//! Integer wrapping/sign handling matches the C++ exactly (unsigned wrap via
//! `@bitCast` + `+%`/`-%`). Build-time only, pure math, no allocator.

const std = @import("std");

/// Port of Draco `OctahedronToolBox`. Constructed for a fixed quantization
/// bit-count `q` (valid Draco range 2..=30; NORMAL attributes use 8).
pub const OctahedronToolBox = struct {
    quantization_bits: i32,
    max_quantized_value: i32,
    max_value: i32,
    dequantization_scale: f32,
    center_value: i32,

    /// Port of `SetQuantizationBits(q)`.
    /// `max_quantized_value = (1<<q)-1` (odd), `max_value = that-1` (even),
    /// `center_value = max_value/2`, `dequantization_scale = 2/max_value`.
    /// `q` is clamped to the valid 2..=30 range so the shift can never
    /// overflow i32 and no division-by-zero is possible (max_value >= 2).
    pub fn init(quantization_bits: u8) OctahedronToolBox {
        const q: i32 = std.math.clamp(@as(i32, quantization_bits), 2, 30);
        const max_quantized_value: i32 = (@as(i32, 1) << @intCast(q)) - 1;
        const max_value: i32 = max_quantized_value - 1;
        return .{
            .quantization_bits = q,
            .max_quantized_value = max_quantized_value,
            .max_value = max_value,
            .dequantization_scale = 2.0 / @as(f32, @floatFromInt(max_value)),
            .center_value = @divTrunc(max_value, 2),
        };
    }

    pub fn maxQuantizedValue(self: OctahedronToolBox) i32 {
        return self.max_quantized_value;
    }

    pub fn centerValue(self: OctahedronToolBox) i32 {
        return self.center_value;
    }

    /// Port of `IsInDiamond`. Expects `s`/`t` already centered at origin
    /// (i.e. in `[-center_value, center_value]`). |s|+|t| <= center_value.
    pub fn isInDiamond(self: OctahedronToolBox, s: i32, t: i32) bool {
        // abs sum fits in i32 (each operand <= center_value); no overflow.
        const st: i64 = @as(i64, @intCast(@abs(s))) + @as(i64, @intCast(@abs(t)));
        return st <= self.center_value;
    }

    /// Port of `InvertDiamond`. Mirrors a point outside the central diamond
    /// (left hemisphere) back inside, in-place. Expects centered coords.
    /// The arithmetic runs in u32 with wraparound, exactly matching the C++
    /// `uint32_t` path used to avoid signed-overflow UB on bad input.
    pub fn invertDiamond(self: OctahedronToolBox, s: *i32, t: *i32) void {
        var sign_s: i32 = 0;
        var sign_t: i32 = 0;
        if (s.* >= 0 and t.* >= 0) {
            sign_s = 1;
            sign_t = 1;
        } else if (s.* <= 0 and t.* <= 0) {
            sign_s = -1;
            sign_t = -1;
        } else {
            sign_s = if (s.* > 0) 1 else -1;
            sign_t = if (t.* > 0) 1 else -1;
        }

        const corner_point_s: u32 = @bitCast(sign_s * self.center_value);
        const corner_point_t: u32 = @bitCast(sign_t * self.center_value);
        var us: u32 = @bitCast(s.*);
        var ut: u32 = @bitCast(t.*);
        us = us +% us -% corner_point_s;
        ut = ut +% ut -% corner_point_t;
        if (sign_s * sign_t >= 0) {
            const temp = us;
            us = 0 -% ut;
            ut = 0 -% temp;
        } else {
            const temp = us;
            us = ut;
            ut = temp;
        }
        us = us +% corner_point_s;
        ut = ut +% corner_point_t;

        s.* = @bitCast(us);
        t.* = @bitCast(ut);
    }

    /// Port of `ModMax`. Wraps a value into `(-center_value, center_value]`
    /// by adding/subtracting the (odd) max_quantized_value.
    pub fn modMax(self: OctahedronToolBox, x: i32) i32 {
        if (x > self.center_value) return x - self.max_quantized_value;
        if (x < -self.center_value) return x + self.max_quantized_value;
        return x;
    }

    /// Port of `MakePositive` (used for correction values): shift negatives up
    /// by max_quantized_value.
    pub fn makePositive(self: OctahedronToolBox, x: i32) i32 {
        if (x < 0) return x + self.max_quantized_value;
        return x;
    }

    /// Port of `QuantizedOctahedralCoordsToUnitVector`: dequantize the integer
    /// octahedral (s,t) into the scaled <-1,1> space, then reconstruct the
    /// 3D unit vector via `OctahedralCoordsToUnitVector`.
    pub fn quantizedOctahedralCoordsToUnitVector(self: OctahedronToolBox, s: i32, t: i32) [3]f32 {
        const s_scaled = @as(f32, @floatFromInt(s)) * self.dequantization_scale - 1.0;
        const t_scaled = @as(f32, @floatFromInt(t)) * self.dequantization_scale - 1.0;
        return octahedralCoordsToUnitVector(s_scaled, t_scaled);
    }
};

/// Port of the private `OctahedralCoordsToUnitVector`. Inputs are already
/// scaled to the <-1,1> range (central point at (0,0)). Projects onto the
/// octahedron, wraps left-hemisphere points along the diamond edges, and
/// normalizes to a unit vector (returns (0,0,0) for a degenerate norm).
fn octahedralCoordsToUnitVector(in_s_scaled: f32, in_t_scaled: f32) [3]f32 {
    var y = in_s_scaled;
    var z = in_t_scaled;
    const x = 1.0 - @abs(y) - @abs(z);

    var x_offset = -x;
    x_offset = if (x_offset < 0) 0 else x_offset;

    y += if (y < 0) x_offset else -x_offset;
    z += if (z < 0) x_offset else -x_offset;

    const norm_squared = x * x + y * y + z * z;
    if (norm_squared < 1e-6) return .{ 0, 0, 0 };
    const d = 1.0 / @sqrt(norm_squared);
    return .{ x * d, y * d, z * d };
}

/// Port of the `NORMAL_OCTAHEDRON_CANONICALIZED` decoding transform
/// `ComputeOriginalValue(pred, corr)`: undo the canonicalized octahedral
/// prediction transform, returning the original quantized (s,t).
///
/// `pred`/`corr` are the (non-negative) quantized prediction and correction
/// components; `box` supplies center/max_quantized geometry.
pub fn octCanonicalizedOriginalValue(pred: [2]i32, corr: [2]i32, box: *const OctahedronToolBox) [2]i32 {
    const center = box.center_value;

    // pred = pred - t  (plain signed subtract, per the canonicalized transform)
    var p0 = pred[0] - center;
    var p1 = pred[1] - center;

    const pred_is_in_diamond = box.isInDiamond(p0, p1);
    if (!pred_is_in_diamond) box.invertDiamond(&p0, &p1);

    const pred_is_in_bottom_left = isInBottomLeft(p0, p1);
    const rotation_count = getRotationCount(p0, p1);
    if (!pred_is_in_bottom_left) {
        const r = rotatePoint(p0, p1, rotation_count);
        p0 = r[0];
        p1 = r[1];
    }

    var o0 = box.modMax(addAsUnsigned(p0, corr[0]));
    var o1 = box.modMax(addAsUnsigned(p1, corr[1]));

    if (!pred_is_in_bottom_left) {
        const reverse: i32 = @mod(4 - rotation_count, 4);
        const r = rotatePoint(o0, o1, reverse);
        o0 = r[0];
        o1 = r[1];
    }
    if (!pred_is_in_diamond) box.invertDiamond(&o0, &o1);

    return .{ o0 + center, o1 + center };
}

/// Port of `AddAsUnsigned`: signed add with u32 wraparound (no UB on overflow).
fn addAsUnsigned(a: i32, b: i32) i32 {
    const ua: u32 = @bitCast(a);
    const ub: u32 = @bitCast(b);
    return @bitCast(ua +% ub);
}

/// Port of `IsInBottomLeft` (canonicalized transform base).
fn isInBottomLeft(x: i32, y: i32) bool {
    if (x == 0 and y == 0) return true;
    return x < 0 and y <= 0;
}

/// Port of `GetRotationCount` (canonicalized transform base): number of 90°
/// rotations that bring the point into the bottom-left quadrant.
fn getRotationCount(x: i32, y: i32) i32 {
    if (x == 0) {
        if (y == 0) return 0;
        return if (y > 0) 3 else 1;
    } else if (x > 0) {
        return if (y >= 0) 2 else 1;
    } else {
        return if (y <= 0) 0 else 3;
    }
}

/// Port of `RotatePoint` (canonicalized transform base).
fn rotatePoint(x: i32, y: i32, rotation_count: i32) [2]i32 {
    return switch (rotation_count) {
        1 => .{ y, -x },
        2 => .{ -x, -y },
        3 => .{ -y, x },
        else => .{ x, y },
    };
}

test "octahedral center + poles map to canonical axes (unit-length, concrete xyz)" {
    const box = OctahedronToolBox.init(8); // 8-bit: max_quantized=255, max_value=254, center=127
    const eps: f32 = 1e-4;

    // center (127,127) -> right-most vertex (1,0,0)
    {
        const v = box.quantizedOctahedralCoordsToUnitVector(box.centerValue(), box.centerValue());
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), v[0] * v[0] + v[1] * v[1] + v[2] * v[2], eps);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), v[0], eps);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), v[1], eps);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), v[2], eps);
    }
    // corner (0,0) -> left-most vertex (-1,0,0)
    {
        const v = box.quantizedOctahedralCoordsToUnitVector(0, 0);
        try std.testing.expectApproxEqAbs(@as(f32, -1.0), v[0], eps);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), v[1], eps);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), v[2], eps);
    }
    // edge midpoint (127,0) -> (0,0,-1)
    {
        const v = box.quantizedOctahedralCoordsToUnitVector(127, 0);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), v[0], eps);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), v[1], eps);
        try std.testing.expectApproxEqAbs(@as(f32, -1.0), v[2], eps);
    }
    // off-axis (190,127) -> (0.712652, 0.701517, 0) -- exercises the normalize path
    {
        const v = box.quantizedOctahedralCoordsToUnitVector(190, 127);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), v[0] * v[0] + v[1] * v[1] + v[2] * v[2], eps);
        try std.testing.expectApproxEqAbs(@as(f32, 0.712652), v[0], eps);
        try std.testing.expectApproxEqAbs(@as(f32, 0.701517), v[1], eps);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), v[2], eps);
    }
}

test "diamond ops: isInDiamond / invertDiamond / modMax on known values" {
    const box = OctahedronToolBox.init(8); // center=127, max_quantized=255

    try std.testing.expect(box.isInDiamond(73, 0)); // 73 <= 127
    try std.testing.expect(!box.isInDiamond(100, 100)); // 200 > 127

    // invertDiamond maps the outside point (100,100) back inside to (54,54)
    var s: i32 = 100;
    var t: i32 = 100;
    box.invertDiamond(&s, &t);
    try std.testing.expectEqual(@as(i32, 54), s);
    try std.testing.expectEqual(@as(i32, 54), t);
    try std.testing.expect(box.isInDiamond(s, t)); // now inside

    try std.testing.expectEqual(@as(i32, -55), box.modMax(200)); // 200 - 255
    try std.testing.expectEqual(@as(i32, 55), box.modMax(-200)); // -200 + 255
    try std.testing.expectEqual(@as(i32, 5), box.modMax(5)); // unchanged
    try std.testing.expectEqual(@as(i32, 255), box.maxQuantizedValue());
    try std.testing.expectEqual(@as(i32, 127), box.centerValue());
}

test "octCanonicalizedOriginalValue wraps known prediction+correction into the diamond" {
    const box = OctahedronToolBox.init(8);

    // pred inside diamond & bottom-left (center): plain add of corr
    try std.testing.expectEqual(
        [2]i32{ 132, 130 },
        octCanonicalizedOriginalValue(.{ 127, 127 }, .{ 5, 3 }, &box),
    );
    // pred not in bottom-left -> exercises rotate/reverse-rotate path
    try std.testing.expectEqual(
        [2]i32{ 196, 127 },
        octCanonicalizedOriginalValue(.{ 200, 127 }, .{ 4, 0 }, &box),
    );
    // zero correction round-trips to the prediction
    try std.testing.expectEqual(
        [2]i32{ 200, 127 },
        octCanonicalizedOriginalValue(.{ 200, 127 }, .{ 0, 0 }, &box),
    );
}
