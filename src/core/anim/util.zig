//! Math and color utilities for verve.anim. Self-contained (no viz
//! dependency — anim_core and viz_core are separate chunk modules) and
//! freestanding-safe: no allocation, no Writer.Allocating.

const std = @import("std");

pub fn clamp(v: f64, lo: f64, hi: f64) f64 {
    return @max(lo, @min(hi, v));
}

pub fn lerp(a: f64, b: f64, t: f64) f64 {
    return a + (b - a) * t;
}

/// GSAP-compatible alias of `lerp`.
pub fn interpolate(a: f64, b: f64, t: f64) f64 {
    return lerp(a, b, t);
}

/// Map `v` from [in_lo, in_hi] to [out_lo, out_hi]. Unclamped
/// (GSAP-compatible); compose with `clamp` when needed.
pub fn mapRange(in_lo: f64, in_hi: f64, out_lo: f64, out_hi: f64, v: f64) f64 {
    if (in_hi == in_lo) return out_lo;
    return out_lo + (v - in_lo) / (in_hi - in_lo) * (out_hi - out_lo);
}

/// Snap `v` to the nearest multiple of `increment`. Zero increment is the
/// identity.
pub fn snap(v: f64, increment: f64) f64 {
    if (increment == 0) return v;
    return @round(v / increment) * increment;
}

/// Wrap `v` into [min, max). Degenerate range returns `min`.
pub fn wrap(v: f64, min: f64, max: f64) f64 {
    const range = max - min;
    if (range <= 0) return min;
    return min + @mod(v - min, range);
}

/// Comptime function composition over f64:
/// `pipe(.{ f, g, h })(x) == h(g(f(x)))`.
pub fn pipe(comptime fns: anytype) fn (f64) f64 {
    return struct {
        fn call(v: f64) f64 {
            var x = v;
            inline for (fns) |f| x = f(x);
            return x;
        }
    }.call;
}

pub const Color = struct {
    r: f64,
    g: f64,
    b: f64,
    a: f64 = 1,
};

/// Parse `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb(r,g,b)`, and
/// `rgba(r,g,b,a)`. Returns null on anything else — the serializer then
/// treats the value as an opaque CSS string.
pub fn parseColor(s: []const u8) ?Color {
    if (s.len == 0) return null;
    if (s[0] == '#') {
        const hex = s[1..];
        switch (hex.len) {
            3 => {
                const r = hexNibble(hex[0]) orelse return null;
                const g = hexNibble(hex[1]) orelse return null;
                const b = hexNibble(hex[2]) orelse return null;
                return .{
                    .r = @floatFromInt(r * 17),
                    .g = @floatFromInt(g * 17),
                    .b = @floatFromInt(b * 17),
                };
            },
            6, 8 => {
                const r = hexByte(hex[0], hex[1]) orelse return null;
                const g = hexByte(hex[2], hex[3]) orelse return null;
                const b = hexByte(hex[4], hex[5]) orelse return null;
                var c: Color = .{
                    .r = @floatFromInt(r),
                    .g = @floatFromInt(g),
                    .b = @floatFromInt(b),
                };
                if (hex.len == 8) {
                    const a = hexByte(hex[6], hex[7]) orelse return null;
                    c.a = @as(f64, @floatFromInt(a)) / 255.0;
                }
                return c;
            },
            else => return null,
        }
    }
    const is_rgba = std.mem.startsWith(u8, s, "rgba(");
    const is_rgb = !is_rgba and std.mem.startsWith(u8, s, "rgb(");
    if (!is_rgb and !is_rgba) return null;
    if (s[s.len - 1] != ')') return null;
    const body = s[(if (is_rgba) "rgba(".len else "rgb(".len) .. s.len - 1];
    var parts: [4]f64 = .{ 0, 0, 0, 1 };
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, body, ',');
    while (it.next()) |part| {
        if (n >= 4) return null;
        const trimmed = std.mem.trim(u8, part, " \t");
        parts[n] = std.fmt.parseFloat(f64, trimmed) catch return null;
        n += 1;
    }
    if (is_rgba and n != 4) return null;
    if (is_rgb and n != 3) return null;
    return .{ .r = parts[0], .g = parts[1], .b = parts[2], .a = parts[3] };
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn hexByte(hi: u8, lo: u8) ?u8 {
    const h = hexNibble(hi) orelse return null;
    const l = hexNibble(lo) orelse return null;
    return h * 16 + l;
}

/// Per-channel rgb lerp (matches the JS interpreter's color math).
pub fn interpolateColor(a: Color, b: Color, t: f64) Color {
    return .{
        .r = lerp(a.r, b.r, t),
        .g = lerp(a.g, b.g, t),
        .b = lerp(a.b, b.b, t),
        .a = lerp(a.a, b.a, t),
    };
}

test "clamp / lerp / mapRange" {
    try std.testing.expectEqual(@as(f64, 5), clamp(9, 0, 5));
    try std.testing.expectEqual(@as(f64, 0), clamp(-1, 0, 5));
    try std.testing.expectEqual(@as(f64, 15), lerp(10, 20, 0.5));
    try std.testing.expectEqual(@as(f64, 50), mapRange(0, 10, 0, 100, 5));
    // unclamped beyond the input range
    try std.testing.expectEqual(@as(f64, 200), mapRange(0, 10, 0, 100, 20));
    // round-trip
    const fwd = mapRange(0, 1, 100, 200, 0.25);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), mapRange(100, 200, 0, 1, fwd), 1e-12);
    // degenerate input range
    try std.testing.expectEqual(@as(f64, 7), mapRange(3, 3, 7, 9, 3));
}

test "snap / wrap" {
    try std.testing.expectEqual(@as(f64, 10), snap(12, 5));
    try std.testing.expectEqual(@as(f64, 15), snap(13, 5));
    try std.testing.expectEqual(@as(f64, 12), snap(12, 0));
    try std.testing.expectEqual(@as(f64, 10), wrap(370, 0, 360));
    try std.testing.expectEqual(@as(f64, 350), wrap(-10, 0, 360));
    try std.testing.expectEqual(@as(f64, 0), wrap(5, 0, 0));
}

test "pipe comptime composition" {
    const double = struct {
        fn f(v: f64) f64 {
            return v * 2;
        }
    }.f;
    const inc = struct {
        fn f(v: f64) f64 {
            return v + 1;
        }
    }.f;
    const both = pipe(.{ double, inc });
    try std.testing.expectEqual(@as(f64, 7), both(3)); // (3*2)+1
}

test "parseColor syntaxes" {
    const short = parseColor("#3af").?;
    try std.testing.expectEqual(@as(f64, 51), short.r);
    try std.testing.expectEqual(@as(f64, 170), short.g);
    try std.testing.expectEqual(@as(f64, 255), short.b);

    const full = parseColor("#ff8800").?;
    try std.testing.expectEqual(@as(f64, 255), full.r);
    try std.testing.expectEqual(@as(f64, 136), full.g);
    try std.testing.expectEqual(@as(f64, 0), full.b);
    try std.testing.expectEqual(@as(f64, 1), full.a);

    const with_alpha = parseColor("#ff880080").?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.502), with_alpha.a, 0.001);

    const rgb = parseColor("rgb(10, 20, 30)").?;
    try std.testing.expectEqual(@as(f64, 20), rgb.g);

    const rgba = parseColor("rgba(10, 20, 30, 0.5)").?;
    try std.testing.expectEqual(@as(f64, 0.5), rgba.a);

    try std.testing.expectEqual(@as(?Color, null), parseColor("blue"));
    try std.testing.expectEqual(@as(?Color, null), parseColor("#12345"));
    try std.testing.expectEqual(@as(?Color, null), parseColor("rgb(1,2)"));
}

test "interpolateColor endpoints" {
    const a: Color = .{ .r = 0, .g = 100, .b = 200, .a = 0 };
    const b: Color = .{ .r = 255, .g = 0, .b = 0, .a = 1 };
    const at0 = interpolateColor(a, b, 0);
    try std.testing.expectEqual(a.r, at0.r);
    const at1 = interpolateColor(a, b, 1);
    try std.testing.expectEqual(b.b, at1.b);
    const mid = interpolateColor(a, b, 0.5);
    try std.testing.expectEqual(@as(f64, 50), mid.g);
}
