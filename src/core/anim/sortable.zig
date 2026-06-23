//! Sortable config types for verve.anim (phase 7). Pure data, target-
//! agnostic: compiles native (SSR) and wasm32-freestanding (anim_core).
//! The JS engine owns pointer capture, the drag state machine, FLIP
//! sibling animation, cross-list group transfer, and edge autoscroll;
//! this file owns the spec and the validation rules.
//!
//! Wire contract (frozen by serialize.zig goldens): root key "so";
//! sub-keys {"it","hd","ax","grp","an","as","ase","cls","dis","cb":{"sR","sG"}}.
//! Axis reuses drag.Axis integer values; Sortable default is .y (wire 2,
//! omitted at default). Booleans animate/autoscroll default true → emitted
//! only when false ("an":0 / "as":0). autoscroll_edge_px omitted when 40.
//! Callback slots ("cb") emitted only on .island surface; SSR rejects them
//! with error.CallbackSlotRequiresIsland.

const std = @import("std");
const drag = @import("drag.zig");

/// Re-export for callers that only import sortable.zig.
pub const Axis = drag.Axis;

/// Sortable config — the option struct for `node.sortable(...)` (SSR)
/// and `verve.sortable(cfg)` (island).
pub const Sortable = struct {
    /// CSS selector for sortable children (required, must be non-empty).
    items: []const u8,
    /// Grip sub-selector — only pointerdowns inside it start a drag.
    /// null = the whole item.
    handle: ?[]const u8 = null,
    /// Constrain drag movement to one axis. Default .y (vertical lists).
    axis: Axis = .y,
    /// Shared name enabling cross-list transfer between same-group
    /// containers. null = no group transfer.
    group: ?[]const u8 = null,
    /// FLIP-animate sibling shifts while dragging. Default true.
    animate: bool = true,
    /// Scroll the container when the pointer nears its edges. Default true.
    autoscroll: bool = true,
    /// Edge band width in pixels for autoscroll trigger. Must be > 0 and
    /// finite. Only validated (and only meaningful) when autoscroll true;
    /// checked unconditionally so callers get an error even if autoscroll
    /// is later toggled on.
    autoscroll_edge_px: f64 = 40,
    /// Class toggled on the dragged item while dragging. SSR-legal.
    toggle_class: ?[]const u8 = null,
    /// Start disabled; enable via verve.sortableEnable().
    disabled: bool = false,

    /// Island-only callback: fires on settle with {from, to[, fromGroup, toGroup]}.
    on_reorder_slot: ?u32 = null,
    /// Island-only callback: fires when the dragged item enters a new
    /// group container. Requires group != null.
    on_enter_group_slot: ?u32 = null,

    pub fn hasSlots(self: *const Sortable) bool {
        return self.on_reorder_slot != null or self.on_enter_group_slot != null;
    }

    /// Deferred-error validation, run by the `sortable` builder.
    pub fn validate(self: *const Sortable) ?anyerror {
        if (self.items.len == 0) return error.SortableNoItems;
        if (self.on_enter_group_slot != null and self.group == null)
            return error.GroupCallbackWithoutGroup;
        if (!std.math.isFinite(self.autoscroll_edge_px) or !(self.autoscroll_edge_px > 0))
            return error.BadAutoscrollEdge;
        return null;
    }
};

/// Builder wrapper. Duck-types through `Node.sortable` (exposes `err`
/// + `toJson`), so node.zig needs no anim import — same stance as
/// drag.Drag.
pub const Sort = struct {
    alloc: std.mem.Allocator,
    config: Sortable,
    err: ?anyerror = null,

    pub fn toJson(self: *const Sort, alloc: std.mem.Allocator) ![]const u8 {
        return @import("serialize.zig").sortableToJson(alloc, self, .ssr);
    }
};

pub var poison: Sort = .{
    .alloc = undefined,
    .config = .{ .items = "" },
    .err = error.OutOfMemory,
};

/// `ctx.ul().sortable(anim.sortable(a, .{ .items = "li", .group = "board" }))`.
pub fn sortable(alloc: std.mem.Allocator, cfg: Sortable) *Sort {
    const s = alloc.create(Sort) catch return &poison;
    s.* = .{ .alloc = alloc, .config = cfg, .err = cfg.validate() };
    return s;
}

test "validate matrix" {
    // empty items → error
    const empty: Sortable = .{ .items = "" };
    try std.testing.expectEqual(@as(?anyerror, error.SortableNoItems), empty.validate());

    // on_enter_group_slot without group → error
    const orphan_cb: Sortable = .{ .items = "li", .on_enter_group_slot = 5 };
    try std.testing.expectEqual(@as(?anyerror, error.GroupCallbackWithoutGroup), orphan_cb.validate());

    // group + on_enter_group_slot is legal
    const group_ok: Sortable = .{ .items = "li", .group = "board", .on_enter_group_slot = 5 };
    try std.testing.expectEqual(@as(?anyerror, null), group_ok.validate());

    // bad autoscroll_edge_px: zero
    const edge_zero: Sortable = .{ .items = "li", .autoscroll_edge_px = 0 };
    try std.testing.expectEqual(@as(?anyerror, error.BadAutoscrollEdge), edge_zero.validate());

    // bad autoscroll_edge_px: negative
    const edge_neg: Sortable = .{ .items = "li", .autoscroll_edge_px = -5 };
    try std.testing.expectEqual(@as(?anyerror, error.BadAutoscrollEdge), edge_neg.validate());

    // bad autoscroll_edge_px: NaN
    const edge_nan: Sortable = .{ .items = "li", .autoscroll_edge_px = std.math.nan(f64) };
    try std.testing.expectEqual(@as(?anyerror, error.BadAutoscrollEdge), edge_nan.validate());

    // bad autoscroll_edge_px: inf
    const edge_inf: Sortable = .{ .items = "li", .autoscroll_edge_px = std.math.inf(f64) };
    try std.testing.expectEqual(@as(?anyerror, error.BadAutoscrollEdge), edge_inf.validate());

    // valid minimal config → null
    const ok: Sortable = .{ .items = "li" };
    try std.testing.expectEqual(@as(?anyerror, null), ok.validate());

    // valid with all optional fields → null
    const full: Sortable = .{
        .items = ".card",
        .handle = ".grip",
        .axis = .x,
        .group = "board",
        .animate = false,
        .autoscroll = false,
        .autoscroll_edge_px = 20,
        .toggle_class = "dragging",
        .disabled = true,
        .on_reorder_slot = 1,
        .on_enter_group_slot = 2,
    };
    try std.testing.expectEqual(@as(?anyerror, null), full.validate());
}

test "hasSlots" {
    const no_slots: Sortable = .{ .items = "li" };
    try std.testing.expect(!no_slots.hasSlots());

    const with_reorder: Sortable = .{ .items = "li", .on_reorder_slot = 3 };
    try std.testing.expect(with_reorder.hasSlots());

    const with_enter: Sortable = .{ .items = "li", .group = "g", .on_enter_group_slot = 4 };
    try std.testing.expect(with_enter.hasSlots());
}

test "builder validates and poisons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ok = sortable(a, .{ .items = "li" });
    try std.testing.expect(ok.err == null);

    const bad = sortable(a, .{ .items = "" });
    try std.testing.expectEqual(@as(?anyerror, error.SortableNoItems), bad.err);

    const bad2 = sortable(a, .{ .items = "li", .on_enter_group_slot = 5 });
    try std.testing.expectEqual(@as(?anyerror, error.GroupCallbackWithoutGroup), bad2.err);
}
