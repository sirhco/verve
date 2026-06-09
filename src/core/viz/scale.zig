//! Scales map data values (the *domain*) onto pixel positions (the *range*),
//! the d3-scale equivalent. Pure, target-agnostic. Phase 1 ships:
//!
//!   * `Linear` — continuous numeric domain → continuous range, with "nice"
//!     tick generation.
//!   * `Band`   — discrete/ordinal domain (N categories) → evenly spaced
//!     bands with padding, for bar charts and categorical axes.
//!   * `Log`    — base-10 logarithmic continuous scale (positive domains).
//!   * `Time`   — thin alias over `Linear` for f64 timestamps; tick stepping
//!     is numeric, not calendar-aware (deferred).

const std = @import("std");

/// A single axis tick: the domain value plus its mapped pixel position.
pub const Tick = struct {
    value: f64,
    pos: f64,
};

/// Continuous linear scale. `domain` and `range` are each [start, end] and may
/// be inverted (end < start) to flip direction — useful for SVG's
/// top-down y-axis where the range is [height, 0].
pub const Linear = struct {
    domain: [2]f64 = .{ 0, 1 },
    range: [2]f64 = .{ 0, 1 },

    pub fn map(self: Linear, v: f64) f64 {
        const d0 = self.domain[0];
        const d1 = self.domain[1];
        if (d1 == d0) return self.range[0];
        const t = (v - d0) / (d1 - d0);
        return self.range[0] + t * (self.range[1] - self.range[0]);
    }

    pub fn invert(self: Linear, p: f64) f64 {
        const r0 = self.range[0];
        const r1 = self.range[1];
        if (r1 == r0) return self.domain[0];
        const t = (p - r0) / (r1 - r0);
        return self.domain[0] + t * (self.domain[1] - self.domain[0]);
    }

    /// Generate up to ~`count` evenly spaced "nice" ticks across the domain.
    /// Caller owns the returned slice. Step is rounded to a 1/2/5×10ⁿ value
    /// so labels read cleanly.
    pub fn ticks(self: Linear, alloc: std.mem.Allocator, count: usize) ![]Tick {
        const lo = @min(self.domain[0], self.domain[1]);
        const hi = @max(self.domain[0], self.domain[1]);
        if (hi == lo or count == 0) {
            const one = try alloc.alloc(Tick, 1);
            one[0] = .{ .value = lo, .pos = self.map(lo) };
            return one;
        }
        const step = niceStep(hi - lo, count);
        const start = @ceil(lo / step) * step;
        var list: std.ArrayList(Tick) = .empty;
        defer list.deinit(alloc);
        var v = start;
        // Guard against fp drift adding a spurious final tick.
        while (v <= hi + step * 1e-9) : (v += step) {
            try list.append(alloc, .{ .value = v, .pos = self.map(v) });
        }
        return list.toOwnedSlice(alloc);
    }
};

/// Round a raw step up to the nearest 1, 2, or 5 times a power of ten.
pub fn niceStep(span: f64, count: usize) f64 {
    const raw = span / @as(f64, @floatFromInt(count));
    const mag = std.math.pow(f64, 10, @floor(std.math.log10(raw)));
    const norm = raw / mag;
    const factor: f64 = if (norm < 1.5) 1 else if (norm < 3) 2 else if (norm < 7) 5 else 10;
    return factor * mag;
}

/// Discrete band scale: N categories laid out across `range` with proportional
/// inner padding. `bandwidth()` is the width of one band; `map(i)` is the band
/// start position for category index `i`.
pub const Band = struct {
    count: usize,
    range: [2]f64 = .{ 0, 1 },
    /// Fraction of each step consumed by the gap between bands (0..1).
    padding: f64 = 0.1,

    fn step(self: Band) f64 {
        if (self.count == 0) return 0;
        const total = self.range[1] - self.range[0];
        return total / @as(f64, @floatFromInt(self.count));
    }

    pub fn bandwidth(self: Band) f64 {
        return self.step() * (1.0 - self.padding);
    }

    /// Start (left/top) position of band `i`, gap-centered within its step.
    pub fn map(self: Band, i: usize) f64 {
        const s = self.step();
        const pad = s * self.padding / 2.0;
        return self.range[0] + @as(f64, @floatFromInt(i)) * s + pad;
    }

    /// Center position of band `i` — where a tick label or point belongs.
    pub fn center(self: Band, i: usize) f64 {
        return self.map(i) + self.bandwidth() / 2.0;
    }
};

/// Base-10 logarithmic scale over a strictly positive domain.
pub const Log = struct {
    domain: [2]f64 = .{ 1, 10 },
    range: [2]f64 = .{ 0, 1 },

    pub fn map(self: Log, v: f64) f64 {
        const l0 = std.math.log10(self.domain[0]);
        const l1 = std.math.log10(self.domain[1]);
        if (l1 == l0) return self.range[0];
        const t = (std.math.log10(v) - l0) / (l1 - l0);
        return self.range[0] + t * (self.range[1] - self.range[0]);
    }
};

/// Numeric time scale over f64 timestamps. Calendar-aware tick intervals are
/// deferred; ticks step uniformly like `Linear`.
pub const Time = Linear;

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

test "linear map and invert round-trip" {
    const s = Linear{ .domain = .{ 0, 100 }, .range = .{ 0, 500 } };
    try testing.expectEqual(@as(f64, 250), s.map(50));
    try testing.expectEqual(@as(f64, 50), s.invert(250));
}

test "linear range can be inverted for svg y-axis" {
    const s = Linear{ .domain = .{ 0, 10 }, .range = .{ 200, 0 } };
    try testing.expectEqual(@as(f64, 200), s.map(0));
    try testing.expectEqual(@as(f64, 0), s.map(10));
    try testing.expectEqual(@as(f64, 100), s.map(5));
}

test "linear nice ticks" {
    const s = Linear{ .domain = .{ 0, 100 }, .range = .{ 0, 100 } };
    const t = try s.ticks(testing.allocator, 5);
    defer testing.allocator.free(t);
    // span 100 / 5 ≈ 20 → nice step 20: 0,20,40,60,80,100
    try testing.expectEqual(@as(usize, 6), t.len);
    try testing.expectEqual(@as(f64, 0), t[0].value);
    try testing.expectEqual(@as(f64, 20), t[1].value);
    try testing.expectEqual(@as(f64, 100), t[t.len - 1].value);
}

test "nice step rounds to 1/2/5" {
    try testing.expectEqual(@as(f64, 20), niceStep(100, 5));
    try testing.expectEqual(@as(f64, 0.5), niceStep(2, 5));
    try testing.expectEqual(@as(f64, 2), niceStep(13, 5));
}

test "band layout and bandwidth" {
    const b = Band{ .count = 4, .range = .{ 0, 400 }, .padding = 0.2 };
    try testing.expectEqual(@as(f64, 100), b.step());
    try testing.expectEqual(@as(f64, 80), b.bandwidth());
    // first band offset by half the padding gap (10)
    try testing.expectEqual(@as(f64, 10), b.map(0));
    try testing.expectEqual(@as(f64, 110), b.map(1));
    try testing.expectEqual(@as(f64, 50), b.center(0));
}

test "log scale maps decades evenly" {
    const s = Log{ .domain = .{ 1, 1000 }, .range = .{ 0, 300 } };
    try testing.expectApproxEqAbs(@as(f64, 0), s.map(1), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 100), s.map(10), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 200), s.map(100), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 300), s.map(1000), 1e-9);
}
