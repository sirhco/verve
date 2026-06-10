//! Stagger delay math. The JS interpreter calls this logic's mirror once at
//! create time to build a per-target delay array; this Zig implementation is
//! the testable source of truth for the distribution semantics.

const std = @import("std");
const types = @import("types.zig");
const ease = @import("ease.zig");

/// Delay in seconds for target `i` of `n` under stagger config `s`.
///
/// Distance model: without a grid, distance is index distance from the
/// focal index (`start` = 0, `end` = n-1, `center` = (n-1)/2). With a
/// grid, indices map row-major to cells and distance is euclidean cell
/// distance from the focal cell (optionally restricted to one `axis`).
/// `edges` inverts the center distance so outermost targets fire first.
/// The normalized distance curve is shaped by `s.ease`, then scaled to
/// `total` seconds (or `each` seconds per distance unit).
pub fn delayFor(i: usize, n: usize, s: types.Stagger) f64 {
    if (n <= 1) return 0;
    const d = rawDist(i, n, s);
    const dmax = maxDist(n, s);
    if (dmax == 0) return 0;
    const norm = d / dmax;
    const shaped = if (s.ease) |e| ease.apply(e, norm) else norm;
    const spread = s.total orelse s.each * dmax;
    return shaped * spread;
}

fn rawDist(i: usize, n: usize, s: types.Stagger) f64 {
    if (s.grid) |g| {
        const cd = cellDist(i, focalCell(n, g, s.from), g, s.axis);
        return switch (s.from) {
            .edges => maxCellDist(n, g, s) - cd,
            else => cd,
        };
    }
    const fi = focalIndex(n, s.from);
    const di = @abs(@as(f64, @floatFromInt(i)) - fi);
    return switch (s.from) {
        .edges => maxLinearDist(n, s) - di,
        else => di,
    };
}

fn maxDist(n: usize, s: types.Stagger) f64 {
    if (s.grid != null) return maxCellDist(n, s.grid.?, s);
    return maxLinearDist(n, s);
}

fn focalIndex(n: usize, from: types.Stagger.From) f64 {
    const last = @as(f64, @floatFromInt(n - 1));
    return switch (from) {
        .start => 0,
        .end => last,
        .center, .edges => last / 2,
        .index => |k| @floatFromInt(@min(k, @as(u32, @intCast(n - 1)))),
    };
}

fn maxLinearDist(n: usize, s: types.Stagger) f64 {
    const fi = focalIndex(n, s.from);
    const last = @as(f64, @floatFromInt(n - 1));
    return @max(fi, last - fi);
}

const Cell = struct { col: f64, row: f64 };

fn indexCell(i: usize, g: types.Stagger.Grid) Cell {
    const cols: usize = @max(g.cols, 1);
    return .{
        .col = @floatFromInt(i % cols),
        .row = @floatFromInt(i / cols),
    };
}

fn focalCell(n: usize, g: types.Stagger.Grid, from: types.Stagger.From) Cell {
    const last_col = @as(f64, @floatFromInt(@max(g.cols, 1) - 1));
    const last_row = @as(f64, @floatFromInt(@max(g.rows, 1) - 1));
    return switch (from) {
        .start => .{ .col = 0, .row = 0 },
        .end => .{ .col = last_col, .row = last_row },
        .center, .edges => .{ .col = last_col / 2, .row = last_row / 2 },
        .index => |k| indexCell(@min(k, @as(u32, @intCast(n - 1))), g),
    };
}

fn cellDist(i: usize, focal: Cell, g: types.Stagger.Grid, axis: ?types.Stagger.Axis) f64 {
    const c = indexCell(i, g);
    const dx = c.col - focal.col;
    const dy = c.row - focal.row;
    if (axis) |a| return switch (a) {
        .x => @abs(dx),
        .y => @abs(dy),
    };
    return @sqrt(dx * dx + dy * dy);
}

fn maxCellDist(n: usize, g: types.Stagger.Grid, s: types.Stagger) f64 {
    const focal = focalCell(n, g, s.from);
    var best: f64 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        best = @max(best, cellDist(i, focal, g, s.axis));
    }
    return best;
}

test "n=1 always zero" {
    try std.testing.expectEqual(@as(f64, 0), delayFor(0, 1, .{ .each = 0.5 }));
}

test "linear from start" {
    const s: types.Stagger = .{ .each = 0.1 };
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), delayFor(0, 5, s), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), delayFor(1, 5, s), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), delayFor(4, 5, s), 1e-12);
}

test "linear from end reverses" {
    const s: types.Stagger = .{ .each = 0.1, .from = .end };
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), delayFor(0, 5, s), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), delayFor(4, 5, s), 1e-12);
}

test "center is symmetric" {
    const s: types.Stagger = .{ .each = 0.1, .from = .center };
    try std.testing.expectApproxEqAbs(delayFor(0, 5, s), delayFor(4, 5, s), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0), delayFor(2, 5, s), 1e-12);
}

test "edges fires outermost first" {
    const s: types.Stagger = .{ .each = 0.1, .from = .edges };
    try std.testing.expectApproxEqAbs(@as(f64, 0), delayFor(0, 5, s), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0), delayFor(4, 5, s), 1e-12);
    // middle has the max delay
    try std.testing.expect(delayFor(2, 5, s) > delayFor(1, 5, s));
}

test "total wins over each" {
    const s: types.Stagger = .{ .each = 99, .total = 1.0 };
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), delayFor(4, 5, s), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), delayFor(1, 5, s), 1e-12);
}

test "grid center symmetry" {
    const s: types.Stagger = .{
        .each = 0.1,
        .from = .center,
        .grid = .{ .cols = 3, .rows = 3 },
    };
    // corners equidistant from center of a 3x3
    const tl = delayFor(0, 9, s);
    const br = delayFor(8, 9, s);
    try std.testing.expectApproxEqAbs(tl, br, 1e-12);
    // center cell zero
    try std.testing.expectApproxEqAbs(@as(f64, 0), delayFor(4, 9, s), 1e-12);
}

test "grid axis restriction" {
    const s: types.Stagger = .{
        .each = 0.1,
        .grid = .{ .cols = 3, .rows = 2 },
        .axis = .x,
    };
    // same column -> same delay regardless of row
    try std.testing.expectApproxEqAbs(delayFor(1, 6, s), delayFor(4, 6, s), 1e-12);
}

test "distribution ease applied" {
    const lin: types.Stagger = .{ .total = 1.0 };
    const eased: types.Stagger = .{ .total = 1.0, .ease = .in_quad };
    // in_quad pulls early delays down
    try std.testing.expect(delayFor(1, 5, eased) < delayFor(1, 5, lin));
    // endpoints unchanged
    try std.testing.expectApproxEqAbs(delayFor(4, 5, eased), delayFor(4, 5, lin), 1e-12);
}
