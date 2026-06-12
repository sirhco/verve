//! verve.gl orbit camera controller — damped, constrained.
//!
//! ## Coordinate convention
//! Spherical coordinates around `target` (right-handed, Y-up, camera looks down -Z):
//!   eye = target + (distance·cos(pitch)·sin(yaw),
//!                   distance·sin(pitch),
//!                   distance·cos(pitch)·cos(yaw))
//! At yaw=0, pitch=0: eye = target + (0, 0, distance) — camera behind along +Z.
//!
//! ## Integration model (discrete impulse → exponential decay)
//! Each tick receives accumulated pointer/wheel deltas (OrbitInput).  The model:
//!   vel += input.delta        — inject impulse
//!   a    = 1 − exp(−k·dt_s)  — approach factor (frame-rate independent)
//!   pos += vel · a            — apply fraction of remaining velocity
//!   vel *= (1 − a)            — decay remainder
//! Total displacement for one impulse I sums to I·Σ a·(1−a)^n = I (geometric series
//! sum = 1), so the full impulse is always applied regardless of step count — the
//! controller is frame-rate independent for a fixed total input.
//! After integration: pitch clamped to [min_pitch, max_pitch], distance to
//! [min_distance, max_distance]; velocity zeroed on clamp (no wind-up).

const std = @import("std");
const math = @import("math.zig");

/// Accumulated pointer/wheel deltas for one tick.
pub const OrbitInput = struct {
    dyaw: f32 = 0,
    dpitch: f32 = 0,
    dzoom: f32 = 0,
};

pub const Orbit = struct {
    target: math.Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    distance: f32 = 4,
    min_distance: f32 = 1,
    max_distance: f32 = 20,
    yaw: f32 = 0,
    pitch: f32 = 0.3,
    min_pitch: f32 = -1.4,
    max_pitch: f32 = 1.4,
    /// Per-second exponential-approach rate.  Higher = snappier.
    damping: f32 = 12.0,
    vel_yaw: f32 = 0,
    vel_pitch: f32 = 0,
    vel_dist: f32 = 0,

    /// Advance the controller by `dt_ms` milliseconds using accumulated input deltas.
    /// Input deltas are added to the respective velocity once, then the state
    /// approaches the implied target via exponential damping.
    pub fn tick(self: *Orbit, dt_ms: f32, input: OrbitInput) void {
        const dt_s = dt_ms / 1000.0;
        const a = 1.0 - @exp(-self.damping * dt_s);

        // Inject impulses into velocities.
        self.vel_yaw += input.dyaw;
        self.vel_pitch += input.dpitch;
        self.vel_dist += input.dzoom;

        // Integrate: apply fraction, decay remainder.
        self.yaw += self.vel_yaw * a;
        self.vel_yaw *= (1.0 - a);

        self.pitch += self.vel_pitch * a;
        self.vel_pitch *= (1.0 - a);

        self.distance += self.vel_dist * a;
        self.vel_dist *= (1.0 - a);

        // Clamp pitch — zero velocity to prevent wind-up.
        if (self.pitch > self.max_pitch) {
            self.pitch = self.max_pitch;
            self.vel_pitch = 0;
        } else if (self.pitch < self.min_pitch) {
            self.pitch = self.min_pitch;
            self.vel_pitch = 0;
        }

        // Clamp distance — zero velocity to prevent wind-up.
        if (self.distance > self.max_distance) {
            self.distance = self.max_distance;
            self.vel_dist = 0;
        } else if (self.distance < self.min_distance) {
            self.distance = self.min_distance;
            self.vel_dist = 0;
        }
    }

    /// Cartesian eye position derived from spherical coordinates.
    /// Convention: yaw=0, pitch=0 → eye = target + (0, 0, distance).
    pub fn eye(self: *const Orbit) math.Vec3 {
        const cos_p = @cos(self.pitch);
        const sin_p = @sin(self.pitch);
        const sin_y = @sin(self.yaw);
        const cos_y = @cos(self.yaw);
        return .{
            .x = self.target.x + self.distance * cos_p * sin_y,
            .y = self.target.y + self.distance * sin_p,
            .z = self.target.z + self.distance * cos_p * cos_y,
        };
    }

    /// View matrix: math.Mat4.lookAt(eye(), target, up).
    /// `up` must not be parallel to the eye-to-target vector.
    pub fn viewMatrix(self: *const Orbit, up: math.Vec3) math.Mat4 {
        return math.Mat4.lookAt(self.eye(), self.target, up);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const eps = 1e-4;
const pi = std.math.pi;

test "zero input leaves state unchanged" {
    var o = Orbit{};
    const yaw0 = o.yaw;
    const pitch0 = o.pitch;
    const dist0 = o.distance;
    o.tick(16.7, .{});
    try testing.expectApproxEqAbs(yaw0, o.yaw, eps);
    try testing.expectApproxEqAbs(pitch0, o.pitch, eps);
    try testing.expectApproxEqAbs(dist0, o.distance, eps);
    try testing.expectApproxEqAbs(@as(f32, 0), o.vel_yaw, eps);
    try testing.expectApproxEqAbs(@as(f32, 0), o.vel_pitch, eps);
    try testing.expectApproxEqAbs(@as(f32, 0), o.vel_dist, eps);
}

test "single dyaw impulse converges — 60 x 16.7ms" {
    // Impulse of 1.0 in dyaw; after enough ticks the total applied yaw ≈ 1.0.
    var o = Orbit{ .yaw = 0, .pitch = 0, .damping = 12.0 };
    o.tick(16.7, .{ .dyaw = 1.0 });
    var i: usize = 1;
    while (i < 60) : (i += 1) o.tick(16.7, .{});
    try testing.expectApproxEqAbs(@as(f32, 1.0), o.yaw, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0), o.vel_yaw, 1e-3);
}

test "single dyaw impulse frame-rate independence — 10 x 100ms" {
    // Same impulse but coarser steps; should still converge to ≈1.0 within 5e-3.
    var o = Orbit{ .yaw = 0, .pitch = 0, .damping = 12.0 };
    o.tick(100, .{ .dyaw = 1.0 });
    var i: usize = 1;
    while (i < 10) : (i += 1) o.tick(100, .{});
    try testing.expectApproxEqAbs(@as(f32, 1.0), o.yaw, 5e-3);
}

test "pitch clamp: large positive dpitch saturates at max_pitch, vel zeroed" {
    var o = Orbit{ .pitch = 0, .damping = 12.0 };
    // Inject large impulse.
    o.tick(16.7, .{ .dpitch = 100.0 });
    var i: usize = 1;
    while (i < 60) : (i += 1) o.tick(16.7, .{});
    try testing.expectApproxEqAbs(o.max_pitch, o.pitch, eps);
    try testing.expectApproxEqAbs(@as(f32, 0), o.vel_pitch, eps);
}

test "distance clamp: large negative dzoom saturates at min_distance, vel zeroed" {
    var o = Orbit{ .distance = 4, .damping = 12.0 };
    o.tick(16.7, .{ .dzoom = -100.0 });
    var i: usize = 1;
    while (i < 60) : (i += 1) o.tick(16.7, .{});
    try testing.expectApproxEqAbs(o.min_distance, o.distance, eps);
    try testing.expectApproxEqAbs(@as(f32, 0), o.vel_dist, eps);
}

test "eye: yaw=0 pitch=0 distance=5 target=(1,2,3) → (1,2,8)" {
    const o = Orbit{
        .target = .{ .x = 1, .y = 2, .z = 3 },
        .distance = 5,
        .yaw = 0,
        .pitch = 0,
    };
    const e = o.eye();
    try testing.expectApproxEqAbs(@as(f32, 1), e.x, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 2), e.y, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 8), e.z, 1e-5);
}

test "eye: pitch near pi/2 places eye above target" {
    const o = Orbit{
        .target = .{ .x = 0, .y = 0, .z = 0 },
        .distance = 5,
        .yaw = 0,
        .pitch = pi / 2.0 - 1e-3,
    };
    const e = o.eye();
    // Y component ≈ distance (mostly up), X/Z small.
    try testing.expect(e.y > 4.99);
    try testing.expect(@abs(e.x) < 0.01);
    try testing.expect(@abs(e.z) < 0.01);
}

test "viewMatrix maps eye to origin" {
    const o = Orbit{
        .target = .{ .x = 0, .y = 0, .z = 0 },
        .distance = 5,
        .yaw = 0.5,
        .pitch = 0.3,
    };
    const e = o.eye();
    const v = o.viewMatrix(.{ .x = 0, .y = 1, .z = 0 });
    // V * (eye, 1) must yield (0, 0, ?, 1); test X and Y only (Z = -distance).
    var r: usize = 0;
    while (r < 3) : (r += 1) {
        const out = v.m[r] * e.x + v.m[4 + r] * e.y + v.m[8 + r] * e.z + v.m[12 + r];
        try testing.expectApproxEqAbs(@as(f32, 0), out, 1e-4);
    }
}
