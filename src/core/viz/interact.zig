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

/// The easing used for layout-transition tweens (and the VizGraph reveal).
pub fn easeOutCubic(t: f64) f64 {
    const inv = 1.0 - t;
    return 1.0 - inv * inv * inv;
}

/// One tween step: position at eased parameter `t` (0..1) between start and
/// target.
pub fn tweenPos(start: Vec2, target: Vec2, t: f64) Vec2 {
    const s = easeOutCubic(t);
    return .{ .x = geom.lerp(start.x, target.x, s), .y = geom.lerp(start.y, target.y, s) };
}

/// Subtree collapse visibility: recompute `hidden` from the `collapsed` flags.
/// A node is hidden iff it is reachable from a collapsed subtree
/// (collapseReachable) AND not reachable from any visible root
/// (visibleFromRoots). Collapsed roots always stay visible as re-expand
/// handles.
///
/// collapseReachable (H): for each collapsed root, forward-BFS the directed
/// out-edges (`ef[i]` → `et[i]`) and mark everything reached except the root
/// itself. Cycles terminate via the visited set.
///
/// visibleFromRoots (V): forward-BFS from every in-degree-0 root. Each
/// dequeued node is marked visible; out-edges are only expanded for
/// non-collapsed nodes — a collapsed node is marked visible (it stays visible
/// as the re-expand handle) but blocks descent through it. Graphs with no
/// in-degree-0 roots (pure cycles) produce V=∅, so the only invariant keeping
/// the collapsed root visible is H[root]=false (the BFS never marks its own
/// root).
///
/// Final: `hidden[v] = H[v] and !V[v]`.
pub fn collapseHidden(
    a: std.mem.Allocator,
    node_count: usize,
    ef: []const usize,
    et: []const usize,
    collapsed: []const bool,
    hidden: []bool,
) !void {
    @memset(hidden[0..node_count], false);
    if (node_count == 0) return;

    // --- Pass 1: compute H (collapseReachable) ---
    const h = try a.alloc(bool, node_count);
    @memset(h, false);
    const visited = try a.alloc(bool, node_count);
    const queue = try a.alloc(usize, node_count);

    for (0..node_count) |root| {
        if (!collapsed[root]) continue;
        @memset(visited, false);
        visited[root] = true;
        var head: usize = 0;
        var tail: usize = 0;
        queue[tail] = root;
        tail += 1;
        while (head < tail) {
            const cur = queue[head];
            head += 1;
            for (ef, et) |f, t| {
                if (f != cur or t >= node_count) continue;
                if (visited[t]) continue;
                visited[t] = true;
                h[t] = true;
                if (tail < node_count) {
                    queue[tail] = t;
                    tail += 1;
                }
            }
        }
    }

    // --- Pass 2: compute V (visibleFromRoots) ---
    const vv = try a.alloc(bool, node_count);
    @memset(vv, false);

    // Compute in-degrees from edge targets.
    const indeg = try a.alloc(usize, node_count);
    @memset(indeg, 0);
    for (et) |t| {
        if (t < node_count) indeg[t] += 1;
    }

    // BFS from all in-degree-0 roots; reuse queue/visited scratch.
    @memset(visited, false);
    var head: usize = 0;
    var tail: usize = 0;
    for (0..node_count) |i| {
        if (indeg[i] == 0 and !visited[i]) {
            visited[i] = true;
            queue[tail] = i;
            tail += 1;
        }
    }
    while (head < tail) {
        const cur = queue[head];
        head += 1;
        vv[cur] = true;
        if (collapsed[cur]) continue; // visible but blocks descent
        for (ef, et) |f, t| {
            if (f != cur or t >= node_count) continue;
            if (visited[t]) continue;
            visited[t] = true;
            if (tail < node_count) {
                queue[tail] = t;
                tail += 1;
            }
        }
    }

    // --- Combine: hidden[v] = H[v] and !V[v] ---
    for (0..node_count) |i| {
        hidden[i] = h[i] and !vv[i];
    }
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

test "tween eases from start to target, exact at the ends" {
    const a = Vec2{ .x = 0, .y = 100 };
    const b = Vec2{ .x = 200, .y = 0 };
    const p0 = tweenPos(a, b, 0);
    try testing.expectEqual(a.x, p0.x);
    try testing.expectEqual(a.y, p0.y);
    const p1 = tweenPos(a, b, 1);
    try testing.expectEqual(b.x, p1.x);
    try testing.expectEqual(b.y, p1.y);
    // easeOutCubic front-loads motion: at t=0.5 we're past the midpoint.
    const mid = tweenPos(a, b, 0.5);
    try testing.expect(mid.x > 100);
}

fn collapseCase(collapsed: []const bool, ef: []const usize, et: []const usize, expect_hidden: []const bool) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var hidden: [8]bool = undefined;
    try collapseHidden(arena.allocator(), collapsed.len, ef, et, collapsed, hidden[0..collapsed.len]);
    for (expect_hidden, 0..) |want, i| try testing.expectEqual(want, hidden[i]);
}

test "collapse chain hides all descendants, root stays visible" {
    // 0 → 1 → 2 → 3, collapse 1 → 2 and 3 hide
    try collapseCase(
        &.{ false, true, false, false },
        &.{ 0, 1, 2 },
        &.{ 1, 2, 3 },
        &.{ false, false, true, true },
    );
}

test "collapse diamond hides the join node once" {
    // 0 → {1, 2} → 3, collapse 0 → everything but 0 hides
    try collapseCase(
        &.{ true, false, false, false },
        &.{ 0, 0, 1, 2 },
        &.{ 1, 2, 3, 3 },
        &.{ false, true, true, true },
    );
}

test "collapse terminates on cycles and never hides the root via its own cycle" {
    // 0 → 1 → 2 → 0 (cycle), collapse 0 → 1, 2 hide; 0 stays visible
    try collapseCase(
        &.{ true, false, false },
        &.{ 0, 1, 2 },
        &.{ 1, 2, 0 },
        &.{ false, true, true },
    );
}

test "nested collapsed subtree hides with its collapsed ancestor" {
    // 0 → 1 → 2, both 0 and 1 collapsed → 1 and 2 hide (1 reached from 0)
    try collapseCase(
        &.{ true, true, false },
        &.{ 0, 1 },
        &.{ 1, 2 },
        &.{ false, true, true },
    );
}

test "multi-parent node stays visible via a visible parent" {
    // 0 → 2 and 1 → 2; collapsing 0 only — non-collapsed root 1 reaches 2,
    // so 2 stays visible (H[2]=true but V[2]=true via root 1 → 2).
    try collapseCase(
        &.{ true, false, false },
        &.{ 0, 1 },
        &.{ 2, 2 },
        &.{ false, false, false },
    );
}

test "multi-parent node hides when ALL its parents subtrees are collapsed" {
    // 0 → 2 and 1 → 2; both 0 and 1 collapsed → neither root expands → V[2]=false
    // → 2 hides.
    try collapseCase(
        &.{ true, true, false },
        &.{ 0, 1 },
        &.{ 2, 2 },
        &.{ false, false, true },
    );
}

test "diamond with one arm collapsed keeps the join visible via the other arm" {
    // 0 → {1, 2} → 3; collapse 1 only. H[3]=true (via 1→3). V BFS from root 0:
    // 0 not collapsed → expands → enqueues 1 (collapsed, stops) and 2 (not
    // collapsed → enqueues 3). So V={0,1,2,3}. hidden[3]=true&&!true=false.
    try collapseCase(
        &.{ false, true, false, false },
        &.{ 0, 0, 1, 2 },
        &.{ 1, 2, 3, 3 },
        &.{ false, false, false, false },
    );
}

test "child of a collapsed node with no other parent hides" {
    // 0 → 1, collapse 0. H[1]=true. V BFS from root 0: 0 IS collapsed → stop.
    // V[1]=false → hidden[1]=true.
    try collapseCase(
        &.{ true, false },
        &.{0},
        &.{1},
        &.{ false, true },
    );
}
