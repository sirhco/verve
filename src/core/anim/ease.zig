//! Pure-Zig easing functions. The JS interpreter in verve.js owns the
//! runtime math for browser animations; these implementations are the
//! parity reference (constants must match verve.js's EASE table) and serve
//! native consumers (stagger distribution easing, future native renderer).
//!
//! Formulas follow the standard easings.net definitions. All functions map
//! t in [0,1] to a progress value with f(0) = 0 and f(1) = 1; back/elastic
//! overshoot outside [0,1] mid-curve by design.

const std = @import("std");
const types = @import("types.zig");

const pi = std.math.pi;

/// Dispatch an `Ease` enum to its function.
pub fn apply(e: types.Ease, t: f64) f64 {
    return switch (e) {
        .linear => t,
        .in_sine => inSine(t),
        .out_sine => outSine(t),
        .in_out_sine => inOutSine(t),
        .in_quad => inQuad(t),
        .out_quad => outQuad(t),
        .in_out_quad => inOutQuad(t),
        .in_cubic => inCubic(t),
        .out_cubic => outCubic(t),
        .in_out_cubic => inOutCubic(t),
        .in_quart => inQuart(t),
        .out_quart => outQuart(t),
        .in_out_quart => inOutQuart(t),
        .in_quint => inQuint(t),
        .out_quint => outQuint(t),
        .in_out_quint => inOutQuint(t),
        .in_expo => inExpo(t),
        .out_expo => outExpo(t),
        .in_out_expo => inOutExpo(t),
        .in_circ => inCirc(t),
        .out_circ => outCirc(t),
        .in_out_circ => inOutCirc(t),
        .in_back => inBack(t),
        .out_back => outBack(t),
        .in_out_back => inOutBack(t),
        .in_elastic => inElastic(t),
        .out_elastic => outElastic(t),
        .in_out_elastic => inOutElastic(t),
        .in_bounce => inBounce(t),
        .out_bounce => outBounce(t),
        .in_out_bounce => inOutBounce(t),
    };
}

pub fn inSine(t: f64) f64 {
    return 1 - @cos(t * pi / 2);
}

pub fn outSine(t: f64) f64 {
    return @sin(t * pi / 2);
}

pub fn inOutSine(t: f64) f64 {
    return -(@cos(pi * t) - 1) / 2;
}

pub fn inQuad(t: f64) f64 {
    return t * t;
}

pub fn outQuad(t: f64) f64 {
    return 1 - (1 - t) * (1 - t);
}

pub fn inOutQuad(t: f64) f64 {
    return if (t < 0.5) 2 * t * t else 1 - std.math.pow(f64, -2 * t + 2, 2) / 2;
}

pub fn inCubic(t: f64) f64 {
    return t * t * t;
}

pub fn outCubic(t: f64) f64 {
    const i = 1 - t;
    return 1 - i * i * i;
}

pub fn inOutCubic(t: f64) f64 {
    return if (t < 0.5) 4 * t * t * t else 1 - std.math.pow(f64, -2 * t + 2, 3) / 2;
}

pub fn inQuart(t: f64) f64 {
    return t * t * t * t;
}

pub fn outQuart(t: f64) f64 {
    return 1 - std.math.pow(f64, 1 - t, 4);
}

pub fn inOutQuart(t: f64) f64 {
    return if (t < 0.5) 8 * t * t * t * t else 1 - std.math.pow(f64, -2 * t + 2, 4) / 2;
}

pub fn inQuint(t: f64) f64 {
    return t * t * t * t * t;
}

pub fn outQuint(t: f64) f64 {
    return 1 - std.math.pow(f64, 1 - t, 5);
}

pub fn inOutQuint(t: f64) f64 {
    return if (t < 0.5) 16 * t * t * t * t * t else 1 - std.math.pow(f64, -2 * t + 2, 5) / 2;
}

pub fn inExpo(t: f64) f64 {
    return if (t == 0) 0 else std.math.pow(f64, 2, 10 * t - 10);
}

pub fn outExpo(t: f64) f64 {
    return if (t == 1) 1 else 1 - std.math.pow(f64, 2, -10 * t);
}

pub fn inOutExpo(t: f64) f64 {
    if (t == 0) return 0;
    if (t == 1) return 1;
    return if (t < 0.5)
        std.math.pow(f64, 2, 20 * t - 10) / 2
    else
        (2 - std.math.pow(f64, 2, -20 * t + 10)) / 2;
}

pub fn inCirc(t: f64) f64 {
    return 1 - @sqrt(1 - t * t);
}

pub fn outCirc(t: f64) f64 {
    return @sqrt(1 - (t - 1) * (t - 1));
}

pub fn inOutCirc(t: f64) f64 {
    return if (t < 0.5)
        (1 - @sqrt(1 - std.math.pow(f64, 2 * t, 2))) / 2
    else
        (@sqrt(1 - std.math.pow(f64, -2 * t + 2, 2)) + 1) / 2;
}

const back_c1: f64 = 1.70158;
const back_c2: f64 = back_c1 * 1.525;
const back_c3: f64 = back_c1 + 1;

pub fn inBack(t: f64) f64 {
    return back_c3 * t * t * t - back_c1 * t * t;
}

pub fn outBack(t: f64) f64 {
    const i = t - 1;
    return 1 + back_c3 * i * i * i + back_c1 * i * i;
}

pub fn inOutBack(t: f64) f64 {
    return if (t < 0.5)
        (std.math.pow(f64, 2 * t, 2) * ((back_c2 + 1) * 2 * t - back_c2)) / 2
    else
        (std.math.pow(f64, 2 * t - 2, 2) * ((back_c2 + 1) * (t * 2 - 2) + back_c2) + 2) / 2;
}

const elastic_c4: f64 = 2 * pi / 3.0;
const elastic_c5: f64 = 2 * pi / 4.5;

pub fn inElastic(t: f64) f64 {
    if (t == 0) return 0;
    if (t == 1) return 1;
    return -std.math.pow(f64, 2, 10 * t - 10) * @sin((t * 10 - 10.75) * elastic_c4);
}

pub fn outElastic(t: f64) f64 {
    if (t == 0) return 0;
    if (t == 1) return 1;
    return std.math.pow(f64, 2, -10 * t) * @sin((t * 10 - 0.75) * elastic_c4) + 1;
}

pub fn inOutElastic(t: f64) f64 {
    if (t == 0) return 0;
    if (t == 1) return 1;
    return if (t < 0.5)
        -(std.math.pow(f64, 2, 20 * t - 10) * @sin((20 * t - 11.125) * elastic_c5)) / 2
    else
        (std.math.pow(f64, 2, -20 * t + 10) * @sin((20 * t - 11.125) * elastic_c5)) / 2 + 1;
}

pub fn outBounce(t: f64) f64 {
    const n1: f64 = 7.5625;
    const d1: f64 = 2.75;
    if (t < 1 / d1) return n1 * t * t;
    if (t < 2 / d1) {
        const u = t - 1.5 / d1;
        return n1 * u * u + 0.75;
    }
    if (t < 2.5 / d1) {
        const u = t - 2.25 / d1;
        return n1 * u * u + 0.9375;
    }
    const u = t - 2.625 / d1;
    return n1 * u * u + 0.984375;
}

pub fn inBounce(t: f64) f64 {
    return 1 - outBounce(1 - t);
}

pub fn inOutBounce(t: f64) f64 {
    return if (t < 0.5)
        (1 - outBounce(1 - 2 * t)) / 2
    else
        (1 + outBounce(2 * t - 1)) / 2;
}

test "endpoints: f(0) == 0 and f(1) == 1 for all eases" {
    inline for (std.meta.fields(types.Ease)) |f| {
        const e: types.Ease = @enumFromInt(f.value);
        try std.testing.expectApproxEqAbs(@as(f64, 0), apply(e, 0), 1e-12);
        try std.testing.expectApproxEqAbs(@as(f64, 1), apply(e, 1), 1e-12);
    }
}

test "monotonicity for non-overshoot families" {
    const monotone = [_]types.Ease{
        .linear,       .in_sine,  .out_sine,  .in_out_sine,  .in_quad,  .out_quad,
        .in_out_quad,  .in_cubic, .out_cubic, .in_out_cubic, .in_quart, .out_quart,
        .in_out_quart, .in_quint, .out_quint, .in_out_quint, .in_expo,  .out_expo,
        .in_out_expo,  .in_circ,  .out_circ,  .in_out_circ,
    };
    for (monotone) |e| {
        var prev: f64 = 0;
        var i: usize = 1;
        while (i <= 100) : (i += 1) {
            const v = apply(e, @as(f64, @floatFromInt(i)) / 100);
            try std.testing.expect(v >= prev - 1e-12);
            prev = v;
        }
    }
}

test "known midpoints" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.875), outCubic(0.5), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), inOutQuad(0.5), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), inQuad(0.5), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), inOutSine(0.5), 1e-12);
}

test "overshoot signs" {
    // back eases dip below 0 going in, overshoot above 1 coming out
    try std.testing.expect(inBack(0.2) < 0);
    try std.testing.expect(outBack(0.8) > 1);
    // elastic oscillates past 1 near the end of out (sin peak at t=0.75)
    try std.testing.expect(outElastic(0.75) > 1);
}
