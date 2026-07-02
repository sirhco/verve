//! SVG path construction for routed graph edges. Takes the via-point
//! polyline a layout produced (e.g. `dag.layoutRouted` bends through virtual
//! nodes) and emits the `d` attribute for a scene `path` shape — straight
//! segments, a smooth spline, or orthogonal (Manhattan) runs with rounded
//! corners. Pure: `std` + geometry only, so it is usable both server-side
//! and inside wasm island chunks.

const std = @import("std");
const geom = @import("geom.zig");

const Vec2 = geom.Vec2;

pub const Routing = enum { straight, curved, orthogonal };

pub const PathOpts = struct {
    /// Orthogonal corners are rounded with this radius, clamped per corner
    /// so short segments never overlap (`min(r, |dx|/2, |dy|/4)`).
    corner_radius: f64 = 8,
};

/// Write the path body (starting with `M`) into `w`. Used by both `pathD` and
/// `pathDBuf` so the formatting logic lives in one place.
fn writePath(w: *std.Io.Writer, pts: []const Vec2, routing: Routing, opts: PathOpts) !void {
    try w.print("M {d},{d}", .{ pts[0].x, pts[0].y });
    switch (routing) {
        .straight => for (pts[1..]) |p| try w.print(" L {d},{d}", .{ p.x, p.y }),
        .curved => try writeCurved(w, pts),
        .orthogonal => try writeOrthogonal(w, pts, opts.corner_radius),
    }
}

/// Build an SVG path `d` for the via-point chain `pts`. Caller owns the
/// returned slice (typically the request arena / chunk arena).
pub fn pathD(a: std.mem.Allocator, pts: []const Vec2, routing: Routing, opts: PathOpts) ![]const u8 {
    if (pts.len < 2) return error.TooFewPoints;
    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    try writePath(&aw.writer, pts, routing, opts);
    return aw.toOwnedSlice();
}

/// Fixed-buffer variant of `pathD`. Uses `std.Io.Writer.fixed` (no
/// address-taken drain fn) so it is safe to call from wasm island chunks
/// where an Allocating writer's drain would collide in the function table.
/// Returns the sub-slice of `buf` that was written.
pub fn pathDBuf(buf: []u8, pts: []const Vec2, routing: Routing, opts: PathOpts) ![]const u8 {
    if (pts.len < 2) return error.TooFewPoints;
    var w: std.Io.Writer = .fixed(buf);
    try writePath(&w, pts, routing, opts);
    return w.buffered();
}

/// Uniform Catmull-Rom through every via-point, converted segment-wise to
/// cubic Béziers (endpoints duplicated as phantom neighbors). Deterministic;
/// a 2-point chain degenerates to a near-straight cubic.
fn writeCurved(w: *std.Io.Writer, pts: []const Vec2) !void {
    const n = pts.len;
    for (0..n - 1) |i| {
        const p0 = if (i == 0) pts[0] else pts[i - 1];
        const p1 = pts[i];
        const p2 = pts[i + 1];
        const p3 = if (i + 2 < n) pts[i + 2] else pts[n - 1];
        const c1 = Vec2{ .x = p1.x + (p2.x - p0.x) / 6.0, .y = p1.y + (p2.y - p0.y) / 6.0 };
        const c2 = Vec2{ .x = p2.x - (p3.x - p1.x) / 6.0, .y = p2.y - (p3.y - p1.y) / 6.0 };
        try w.print(" C {d},{d} {d},{d} {d},{d}", .{ c1.x, c1.y, c2.x, c2.y, p2.x, p2.y });
    }
}

/// Manhattan routing: each consecutive via-point pair descends vertically to
/// the midline between their layers, jogs horizontally, then descends to the
/// target — virtual nodes already reserve the x-channels, so segments stay in
/// their lanes. Corners are rounded with quadratics.
fn writeOrthogonal(w: *std.Io.Writer, pts: []const Vec2, corner_radius: f64) !void {
    const eps = 1e-9;
    for (0..pts.len - 1) |i| {
        const p = pts[i];
        const q = pts[i + 1];
        const dx = q.x - p.x;
        const dy = q.y - p.y;
        if (@abs(dx) < eps) {
            try w.print(" V {d}", .{q.y});
            continue;
        }
        if (@abs(dy) < eps) {
            try w.print(" H {d}", .{q.x});
            continue;
        }
        const mid = (p.y + q.y) / 2.0;
        const sx: f64 = if (dx > 0) 1 else -1;
        const sy: f64 = if (dy > 0) 1 else -1;
        const r = @min(corner_radius, @min(@abs(dx) / 2.0, @abs(dy) / 4.0));
        if (r < eps) {
            try w.print(" V {d} H {d} V {d}", .{ mid, q.x, q.y });
            continue;
        }
        try w.print(" V {d}", .{mid - sy * r});
        try w.print(" Q {d},{d} {d},{d}", .{ p.x, mid, p.x + sx * r, mid });
        try w.print(" H {d}", .{q.x - sx * r});
        try w.print(" Q {d},{d} {d},{d}", .{ q.x, mid, q.x, mid + sy * r });
        try w.print(" V {d}", .{q.y});
    }
}

// ---- tests ---------------------------------------------------------------

const testing = std.testing;

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, i, needle)) |at| {
        count += 1;
        i = at + needle.len;
    }
    return count;
}

test "straight emits M + L per remaining point" {
    const pts = [_]Vec2{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 20 }, .{ .x = 30, .y = 40 } };
    const d = try pathD(testing.allocator, &pts, .straight, .{});
    defer testing.allocator.free(d);
    try testing.expect(std.mem.startsWith(u8, d, "M 0,0"));
    try testing.expectEqual(@as(usize, 2), countOccurrences(d, " L "));
}

test "curved emits one cubic per segment, anchored at endpoints" {
    const pts = [_]Vec2{ .{ .x = 0, .y = 0 }, .{ .x = 40, .y = 60 }, .{ .x = 10, .y = 120 }, .{ .x = 50, .y = 180 } };
    const d = try pathD(testing.allocator, &pts, .curved, .{});
    defer testing.allocator.free(d);
    try testing.expect(std.mem.startsWith(u8, d, "M 0,0"));
    try testing.expectEqual(@as(usize, 3), countOccurrences(d, " C "));
    // path ends exactly at the last via-point
    try testing.expect(std.mem.endsWith(u8, d, "50,180"));
}

test "orthogonal uses only M/V/H/Q commands and ends on the target row" {
    const pts = [_]Vec2{ .{ .x = 0, .y = 0 }, .{ .x = 60, .y = 80 }, .{ .x = 20, .y = 160 } };
    const d = try pathD(testing.allocator, &pts, .orthogonal, .{});
    defer testing.allocator.free(d);
    for (d) |c| {
        const cmd = switch (c) {
            'M', 'V', 'H', 'Q' => true,
            else => false,
        };
        const allowed = cmd or std.ascii.isDigit(c) or c == ' ' or c == ',' or c == '.' or c == '-';
        try testing.expect(allowed);
    }
    try testing.expect(std.mem.endsWith(u8, d, "V 160"));
}

test "orthogonal corner radius clamps on short segments" {
    // dx = 4 → r clamps to 2 even with the default radius of 8
    const pts = [_]Vec2{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 100 } };
    const d = try pathD(testing.allocator, &pts, .orthogonal, .{ .corner_radius = 8 });
    defer testing.allocator.free(d);
    try testing.expect(std.mem.indexOf(u8, d, "Q 0,50 2,50") != null);
}

test "orthogonal degenerates to V / H on axis-aligned segments" {
    const vertical = [_]Vec2{ .{ .x = 5, .y = 0 }, .{ .x = 5, .y = 90 } };
    const dv = try pathD(testing.allocator, &vertical, .orthogonal, .{});
    defer testing.allocator.free(dv);
    try testing.expectEqualStrings("M 5,0 V 90", dv);

    const horizontal = [_]Vec2{ .{ .x = 0, .y = 7 }, .{ .x = 80, .y = 7 } };
    const dh = try pathD(testing.allocator, &horizontal, .orthogonal, .{});
    defer testing.allocator.free(dh);
    try testing.expectEqualStrings("M 0,7 H 80", dh);
}

test "output is deterministic" {
    const pts = [_]Vec2{ .{ .x = 1, .y = 2 }, .{ .x = 33, .y = 44 }, .{ .x = 5, .y = 99 } };
    const d1 = try pathD(testing.allocator, &pts, .curved, .{});
    defer testing.allocator.free(d1);
    const d2 = try pathD(testing.allocator, &pts, .curved, .{});
    defer testing.allocator.free(d2);
    try testing.expectEqualStrings(d1, d2);
}

test "fewer than two points is an error" {
    const one = [_]Vec2{.{ .x = 0, .y = 0 }};
    try testing.expectError(error.TooFewPoints, pathD(testing.allocator, &one, .straight, .{}));
}

test "pathDBuf produces the same d string as pathD" {
    // 2-point orthogonal
    const two = [_]Vec2{ .{ .x = 0, .y = 0 }, .{ .x = 50, .y = 100 } };
    const two_d = try pathD(testing.allocator, &two, .orthogonal, .{});
    defer testing.allocator.free(two_d);
    var two_buf: [256]u8 = undefined;
    const two_buf_d = try pathDBuf(&two_buf, &two, .orthogonal, .{});
    try testing.expectEqualStrings(two_d, two_buf_d);

    // 3-point curved
    const three = [_]Vec2{ .{ .x = 0, .y = 0 }, .{ .x = 40, .y = 60 }, .{ .x = 10, .y = 120 } };
    const three_d = try pathD(testing.allocator, &three, .curved, .{});
    defer testing.allocator.free(three_d);
    var three_buf: [512]u8 = undefined;
    const three_buf_d = try pathDBuf(&three_buf, &three, .curved, .{});
    try testing.expectEqualStrings(three_d, three_buf_d);

    // 2-point straight
    const str = [_]Vec2{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 20 } };
    const str_d = try pathD(testing.allocator, &str, .straight, .{});
    defer testing.allocator.free(str_d);
    var str_buf: [64]u8 = undefined;
    const str_buf_d = try pathDBuf(&str_buf, &str, .straight, .{});
    try testing.expectEqualStrings(str_d, str_buf_d);
}
