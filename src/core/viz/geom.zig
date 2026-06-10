//! Geometry primitives for the visualization library. Pure, target-agnostic
//! math (f64) shared by scales, layouts, and the SVG scene model. Runs
//! identically on the native server and in wasm32-freestanding.

const std = @import("std");

/// 2D point / vector.
pub const Vec2 = struct {
    x: f64 = 0,
    y: f64 = 0,

    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    pub fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }

    pub fn scale(a: Vec2, k: f64) Vec2 {
        return .{ .x = a.x * k, .y = a.y * k };
    }

    pub fn dot(a: Vec2, b: Vec2) f64 {
        return a.x * b.x + a.y * b.y;
    }

    pub fn len(a: Vec2) f64 {
        return @sqrt(a.x * a.x + a.y * a.y);
    }

    pub fn dist(a: Vec2, b: Vec2) f64 {
        return a.sub(b).len();
    }

    /// Unit vector in the same direction; the zero vector maps to itself.
    pub fn normalize(a: Vec2) Vec2 {
        const l = a.len();
        if (l == 0) return a;
        return a.scale(1.0 / l);
    }
};

/// Axis-aligned bounding box / rectangle. `w`/`h` are non-negative by
/// convention.
pub const Rect = struct {
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,

    pub fn contains(r: Rect, p: Vec2) bool {
        return p.x >= r.x and p.x <= r.x + r.w and p.y >= r.y and p.y <= r.y + r.h;
    }

    pub fn center(r: Rect) Vec2 {
        return .{ .x = r.x + r.w / 2.0, .y = r.y + r.h / 2.0 };
    }

    /// Smallest box covering all points. Returns a zero box for an empty
    /// slice.
    pub fn bounds(points: []const Vec2) Rect {
        if (points.len == 0) return .{};
        var min_x = points[0].x;
        var min_y = points[0].y;
        var max_x = points[0].x;
        var max_y = points[0].y;
        for (points[1..]) |p| {
            if (p.x < min_x) min_x = p.x;
            if (p.y < min_y) min_y = p.y;
            if (p.x > max_x) max_x = p.x;
            if (p.y > max_y) max_y = p.y;
        }
        return .{ .x = min_x, .y = min_y, .w = max_x - min_x, .h = max_y - min_y };
    }
};

/// Linear interpolation between `a` and `b` at parameter `t` (0..1).
pub fn lerp(a: f64, b: f64, t: f64) f64 {
    return a + (b - a) * t;
}

/// Clamp `v` to the inclusive range [lo, hi].
pub fn clamp(v: f64, lo: f64, hi: f64) f64 {
    return @max(lo, @min(hi, v));
}

/// Uniform scale + translate that centers a point set inside a `w`×`h`
/// viewport with `margin` on every side. This is the SSR↔client position
/// contract: a chunk recomputing a layout reproduces the server's pixel
/// positions exactly by applying the same fit.
pub const Fit = struct { s: f64, cx: f64, cy: f64, bx: f64, by: f64 };

pub fn fitBox(positions: []const Vec2, w: f64, h: f64, margin: f64) Fit {
    const box = Rect.bounds(positions);
    const avail_w = w - 2 * margin;
    const avail_h = h - 2 * margin;
    var s: f64 = 1;
    if (box.w > 1e-9 and box.h > 1e-9) {
        s = @min(avail_w / box.w, avail_h / box.h);
    } else if (box.w > 1e-9) {
        s = avail_w / box.w;
    } else if (box.h > 1e-9) {
        s = avail_h / box.h;
    }
    return .{ .s = s, .cx = w / 2.0, .cy = h / 2.0, .bx = box.x + box.w / 2.0, .by = box.y + box.h / 2.0 };
}

pub fn applyFit(p: Vec2, f: Fit) Vec2 {
    return .{ .x = f.cx + (p.x - f.bx) * f.s, .y = f.cy + (p.y - f.by) * f.s };
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

test "vec2 arithmetic and length" {
    const a = Vec2{ .x = 3, .y = 4 };
    try testing.expectEqual(@as(f64, 5), a.len());
    const b = a.add(.{ .x = 1, .y = 1 });
    try testing.expectEqual(@as(f64, 4), b.x);
    try testing.expectEqual(@as(f64, 5), b.y);
    try testing.expectEqual(@as(f64, 5), Vec2.dist(.{ .x = 0, .y = 0 }, .{ .x = 3, .y = 4 }));
}

test "vec2 normalize zero is safe" {
    const z = Vec2{ .x = 0, .y = 0 };
    const n = z.normalize();
    try testing.expectEqual(@as(f64, 0), n.x);
    try testing.expectEqual(@as(f64, 0), n.y);
    const u = (Vec2{ .x = 10, .y = 0 }).normalize();
    try testing.expectApproxEqAbs(@as(f64, 1), u.x, 1e-12);
}

test "rect bounds and contains" {
    const pts = [_]Vec2{ .{ .x = -1, .y = 2 }, .{ .x = 5, .y = -3 }, .{ .x = 0, .y = 0 } };
    const r = Rect.bounds(&pts);
    try testing.expectEqual(@as(f64, -1), r.x);
    try testing.expectEqual(@as(f64, -3), r.y);
    try testing.expectEqual(@as(f64, 6), r.w);
    try testing.expectEqual(@as(f64, 5), r.h);
    try testing.expect(r.contains(.{ .x = 0, .y = 0 }));
    try testing.expect(!r.contains(.{ .x = 100, .y = 0 }));
}

test "lerp and clamp" {
    try testing.expectEqual(@as(f64, 15), lerp(10, 20, 0.5));
    try testing.expectEqual(@as(f64, 5), clamp(-3, 5, 9));
    try testing.expectEqual(@as(f64, 9), clamp(42, 5, 9));
    try testing.expectEqual(@as(f64, 7), clamp(7, 5, 9));
}

test "fitBox centers and uniformly scales into the margin box" {
    const pts = [_]Vec2{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 5 } };
    const f = fitBox(&pts, 220, 120, 10);
    // 10×5 box into 200×100 avail → s limited by both = 20
    try testing.expectApproxEqAbs(@as(f64, 20), f.s, 1e-9);
    const a = applyFit(pts[0], f);
    const b = applyFit(pts[1], f);
    // Centered: midpoint of mapped points is the viewport center.
    try testing.expectApproxEqAbs(@as(f64, 110), (a.x + b.x) / 2, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 60), (a.y + b.y) / 2, 1e-9);
    // Uniform: aspect preserved (dx/dy ratio unchanged).
    try testing.expectApproxEqAbs((b.x - a.x) / (b.y - a.y), 10.0 / 5.0, 1e-9);
}

test "fitBox degenerate point set keeps scale 1 and centers" {
    const pts = [_]Vec2{.{ .x = 7, .y = 7 }};
    const f = fitBox(&pts, 100, 80, 10);
    try testing.expectEqual(@as(f64, 1), f.s);
    const p = applyFit(pts[0], f);
    try testing.expectApproxEqAbs(@as(f64, 50), p.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 40), p.y, 1e-9);
}
