//! Deterministic wind-farm telemetry simulator.
//!
//! `sample(turbine, tick)` returns smooth, bounded, physics-inspired
//! readings for each turbine. No RNG — same inputs always give same output.

const std = @import("std");
const math = std.math;

pub const Telemetry = struct {
    power_kw: f32,
    rpm: f32,
    wind_ms: f32,
};

/// Return deterministic telemetry for `turbine` (0..3) at `tick`.
/// wind_ms = 8 + 4*sin(tick*0.05 + turbine)
/// rpm     = clamp(wind_ms*1.6, 0, 30)
/// power_kw = clamp(rpm*rpm*5, 0, 5000)
pub fn sample(turbine: u8, tick: u64) Telemetry {
    const t: f32 = @floatFromInt(tick);
    const tr: f32 = @floatFromInt(turbine);

    const wind_ms: f32 = 8.0 + 4.0 * @sin(t * 0.05 + tr);
    const rpm: f32 = @max(0.0, @min(wind_ms * 1.6, 30.0));
    const power_kw: f32 = @max(0.0, @min(rpm * rpm * 5.0, 5000.0));

    return .{
        .wind_ms = wind_ms,
        .rpm = rpm,
        .power_kw = power_kw,
    };
}

// ---- tests ---------------------------------------------------------------

const testing = std.testing;

test "sim.sample is deterministic + bounded" {
    const a = sample(0, 100);
    const b = sample(0, 100);
    try testing.expectEqual(a.power_kw, b.power_kw); // deterministic
    try testing.expect(a.power_kw >= 0 and a.power_kw <= 5000);
    try testing.expect(a.rpm >= 0 and a.rpm <= 30);
    // different turbines differ in phase
    try testing.expect(sample(1, 100).power_kw != a.power_kw);
}
