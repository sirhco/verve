//! Draggable config types for verve.anim (phase 4). Pure data, target-
//! agnostic: compiles native (SSR) and wasm32-freestanding (anim_core).
//! The JS engine owns pointer capture, the drag state machine, inertia
//! integration, and snap resolution; this file owns the spec and the
//! validation rules.
//!
//! Wire contract (frozen by serialize.zig goldens): root key "dr";
//! Axis integer values; bounds rect as [minX,maxX,minY,maxY]
//! (translate-space px relative to the start position); snap grid /
//! flattened point pairs; inertia as velocity retention per second.

const std = @import("std");

/// Axis lock. Integer values are the wire contract.
pub const Axis = enum(u2) {
    /// Wire default — omitted.
    both = 0,
    x = 1,
    y = 2,
};

/// Where dragging is allowed.
pub const Bounds = union(enum) {
    none,
    /// Confine within a container element (CSS selector). Geometry is
    /// re-measured at the start of every gesture.
    selector: []const u8,
    /// Explicit translate-space box, px relative to the start position.
    rect: struct {
        min_x: f64 = 0,
        max_x: f64 = 0,
        min_y: f64 = 0,
        max_y: f64 = 0,
    },
};

/// Momentum after release.
pub const Inertia = union(enum) {
    off,
    /// Engine default retention (0.05/s — GSAP-ish feel).
    on,
    /// Velocity kept per second, exclusive (0, 1). Higher = coasts
    /// further.
    retention: f64,
};

/// Where the element settles (drag end, or thrown endpoint with inertia).
pub const Snap = union(enum) {
    none,
    /// Snap x/y to multiples of grid.x / grid.y px.
    grid: struct { x: f64, y: f64 },
    /// Snap to the nearest [x, y] point (translate-space).
    points: []const [2]f64,
};

/// Draggable config — the option struct for `node.draggable(...)` (SSR)
/// and `verve.draggable(cfg, cbs)` (island).
pub const Draggable = struct {
    /// CSS selector for the dragged element(s). null = the carrying node
    /// (SSR). Matching multiple elements makes each independently
    /// draggable. Island surface requires an explicit target.
    target: ?[]const u8 = null,
    /// Island-only: ref-handle target; wins over `target`.
    target_handle: ?i32 = null,
    /// Grip sub-selector — only pointerdowns inside it start a drag
    /// (".card .titlebar"). null = the whole element.
    handle: ?[]const u8 = null,

    axis: Axis = .both,
    bounds: Bounds = .none,
    inertia: Inertia = .off,
    snap: Snap = .none,

    /// Class applied to the target while dragging or throwing.
    /// SSR-legal, zero-wasm.
    toggle_class: ?[]const u8 = null,
    /// Pixels of pointer travel before the drag engages — clicks inside
    /// draggables survive below this. Must be > 0.
    threshold_px: f64 = 3,
    /// Engine sets grab/grabbing cursors on the grip.
    manage_cursor: bool = true,
    /// Create disabled; enable via the handle.
    disabled: bool = false,

    /// Island-only lifecycle callbacks: event-slot ids (registerEvent,
    /// already chunk-table-translated). SSR serialize rejects these.
    on_start_slot: ?u32 = null,
    /// Fires per move tick; read position/velocity via the handle.
    on_drag_slot: ?u32 = null,
    on_end_slot: ?u32 = null,
    /// Fires when an inertia throw settles. Requires inertia.
    on_throw_complete_slot: ?u32 = null,

    pub fn hasSlots(self: *const Draggable) bool {
        return self.on_start_slot != null or self.on_drag_slot != null or
            self.on_end_slot != null or self.on_throw_complete_slot != null;
    }

    /// Deferred-error validation, run by the `draggable` builder /
    /// `verve.draggable`. Axis-locked configs may carry degenerate
    /// other-axis bounds components (they are simply ignored).
    pub fn validate(self: *const Draggable) ?anyerror {
        switch (self.bounds) {
            .rect => |r| {
                if (!std.math.isFinite(r.min_x) or !std.math.isFinite(r.max_x) or
                    !std.math.isFinite(r.min_y) or !std.math.isFinite(r.max_y))
                    return error.NonFiniteBounds;
                if (r.min_x > r.max_x or r.min_y > r.max_y)
                    return error.InvertedBounds;
            },
            .none, .selector => {},
        }
        switch (self.snap) {
            .grid => |g| {
                if (!(g.x > 0) or !(g.y > 0) or
                    !std.math.isFinite(g.x) or !std.math.isFinite(g.y))
                    return error.SnapGridNonPositive;
            },
            .points => |p| if (p.len == 0) return error.SnapPointsEmpty,
            .none => {},
        }
        switch (self.inertia) {
            .retention => |r| if (!(r > 0) or !(r < 1) or !std.math.isFinite(r))
                return error.BadRetention,
            .off, .on => {},
        }
        if (!(self.threshold_px > 0) or !std.math.isFinite(self.threshold_px))
            return error.BadThreshold;
        if (self.on_throw_complete_slot != null and self.inertia == .off)
            return error.ThrowCallbackWithoutInertia;
        return null;
    }
};

/// Builder wrapper. Duck-types through `Node.draggable` (exposes `err`
/// + `toJson`), so node.zig needs no anim import — same stance as
/// scroll.Trigger.
pub const Drag = struct {
    alloc: std.mem.Allocator,
    config: Draggable,
    err: ?anyerror = null,

    pub fn toJson(self: *const Drag, alloc: std.mem.Allocator) ![]const u8 {
        return @import("serialize.zig").dragToJson(alloc, self, .ssr);
    }
};

pub var poison: Drag = .{
    .alloc = undefined,
    .config = .{},
    .err = error.OutOfMemory,
};

/// `ctx.div().draggable(anim.draggable(a, .{ .axis = .x, .inertia = .on }))`.
pub fn draggable(alloc: std.mem.Allocator, cfg: Draggable) *Drag {
    const d = alloc.create(Drag) catch return &poison;
    d.* = .{ .alloc = alloc, .config = cfg, .err = cfg.validate() };
    return d;
}

test "axis wire ints frozen" {
    try std.testing.expectEqual(@as(u2, 0), @intFromEnum(Axis.both));
    try std.testing.expectEqual(@as(u2, 1), @intFromEnum(Axis.x));
    try std.testing.expectEqual(@as(u2, 2), @intFromEnum(Axis.y));
}

test "validate matrix" {
    const ok: Draggable = .{};
    try std.testing.expectEqual(@as(?anyerror, null), ok.validate());

    const inverted: Draggable = .{ .bounds = .{ .rect = .{ .min_x = 10, .max_x = 0 } } };
    try std.testing.expectEqual(@as(?anyerror, error.InvertedBounds), inverted.validate());

    const nan_b: Draggable = .{ .bounds = .{ .rect = .{ .max_x = std.math.nan(f64) } } };
    try std.testing.expectEqual(@as(?anyerror, error.NonFiniteBounds), nan_b.validate());

    const zero_grid: Draggable = .{ .snap = .{ .grid = .{ .x = 0, .y = 40 } } };
    try std.testing.expectEqual(@as(?anyerror, error.SnapGridNonPositive), zero_grid.validate());

    const neg_grid: Draggable = .{ .snap = .{ .grid = .{ .x = 40, .y = -1 } } };
    try std.testing.expectEqual(@as(?anyerror, error.SnapGridNonPositive), neg_grid.validate());

    const empty_pts: Draggable = .{ .snap = .{ .points = &.{} } };
    try std.testing.expectEqual(@as(?anyerror, error.SnapPointsEmpty), empty_pts.validate());

    const r_high: Draggable = .{ .inertia = .{ .retention = 1.0 } };
    try std.testing.expectEqual(@as(?anyerror, error.BadRetention), r_high.validate());
    const r_zero: Draggable = .{ .inertia = .{ .retention = 0 } };
    try std.testing.expectEqual(@as(?anyerror, error.BadRetention), r_zero.validate());
    const r_ok: Draggable = .{ .inertia = .{ .retention = 0.3 } };
    try std.testing.expectEqual(@as(?anyerror, null), r_ok.validate());

    const bad_th: Draggable = .{ .threshold_px = 0 };
    try std.testing.expectEqual(@as(?anyerror, error.BadThreshold), bad_th.validate());

    const orphan_throw: Draggable = .{ .on_throw_complete_slot = 5 };
    try std.testing.expectEqual(@as(?anyerror, error.ThrowCallbackWithoutInertia), orphan_throw.validate());
    const throw_ok: Draggable = .{ .inertia = .on, .on_throw_complete_slot = 5 };
    try std.testing.expectEqual(@as(?anyerror, null), throw_ok.validate());

    // axis lock + degenerate other-axis rect is legal
    const locked: Draggable = .{ .axis = .x, .bounds = .{ .rect = .{ .min_x = 0, .max_x = 600 } } };
    try std.testing.expectEqual(@as(?anyerror, null), locked.validate());
}

test "builder validates and poisons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ok = draggable(a, .{ .inertia = .on });
    try std.testing.expect(ok.err == null);

    const bad = draggable(a, .{ .bounds = .{ .rect = .{ .min_y = 5, .max_y = 1 } } });
    try std.testing.expectEqual(@as(?anyerror, error.InvertedBounds), bad.err);
}
