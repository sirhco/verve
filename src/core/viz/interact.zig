//! Pure coordinate + zoom math for interactive graphs. No DOM, no allocator —
//! the interactive island calls these to translate pointer input into a view
//! transform. Target-agnostic, fully unit-tested; the client chunk mirrors a
//! copy of these functions (Zig forbids importing across the island module
//! boundary).

const std = @import("std");
const geom = @import("geom.zig");

const Vec2 = geom.Vec2;

/// The current zoom/pan of the root group: svg = graph * z + (tx, ty).
pub const View = struct {
    z: f64 = 1,
    tx: f64 = 0,
    ty: f64 = 0,
};

/// Map a browser client-space point to svg user-space, given the svg element's
/// bounding rect and its viewBox extent.
pub fn clientToSvg(rect: geom.Rect, vb_w: f64, vb_h: f64, cx: f64, cy: f64) Vec2 {
    const sx = if (rect.w == 0) 0 else (cx - rect.x) / rect.w * vb_w;
    const sy = if (rect.h == 0) 0 else (cy - rect.y) / rect.h * vb_h;
    return .{ .x = sx, .y = sy };
}

/// Invert the view transform: svg user-space → graph-space.
pub fn svgToGraph(view: View, svg: Vec2) Vec2 {
    return .{ .x = (svg.x - view.tx) / view.z, .y = (svg.y - view.ty) / view.z };
}

/// Zoom by `factor` about an svg-space cursor point, keeping the graph point
/// under the cursor fixed. `z` is clamped to [min_z, max_z].
pub fn zoomToward(view: View, svg_cursor: Vec2, factor: f64, min_z: f64, max_z: f64) View {
    const new_z = geom.clamp(view.z * factor, min_z, max_z);
    const g = svgToGraph(view, svg_cursor);
    return .{ .z = new_z, .tx = svg_cursor.x - g.x * new_z, .ty = svg_cursor.y - g.y * new_z };
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

test "clientToSvg maps rect to viewBox" {
    const r = geom.Rect{ .x = 100, .y = 50, .w = 400, .h = 300 };
    const p = clientToSvg(r, 800, 600, 300, 200); // halfway in x, half in y
    try testing.expectApproxEqAbs(@as(f64, 400), p.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 300), p.y, 1e-9);
}

test "svgToGraph inverts the view" {
    const v = View{ .z = 2, .tx = 10, .ty = 20 };
    const g = svgToGraph(v, .{ .x = 50, .y = 60 });
    try testing.expectApproxEqAbs(@as(f64, 20), g.x, 1e-9); // (50-10)/2
    try testing.expectApproxEqAbs(@as(f64, 20), g.y, 1e-9); // (60-20)/2
}

test "zoomToward keeps the cursor point invariant" {
    const v = View{ .z = 1, .tx = 0, .ty = 0 };
    const cursor = Vec2{ .x = 120, .y = 80 };
    const v2 = zoomToward(v, cursor, 1.5, 0.1, 10);
    try testing.expectApproxEqAbs(@as(f64, 1.5), v2.z, 1e-9);
    const g_before = svgToGraph(v, cursor);
    const g_after = svgToGraph(v2, cursor);
    try testing.expectApproxEqAbs(g_before.x, g_after.x, 1e-9);
    try testing.expectApproxEqAbs(g_before.y, g_after.y, 1e-9);
}

test "zoom clamps to max" {
    const v = View{ .z = 9, .tx = 0, .ty = 0 };
    const v2 = zoomToward(v, .{ .x = 0, .y = 0 }, 4, 0.1, 10);
    try testing.expectEqual(@as(f64, 10), v2.z);
}
