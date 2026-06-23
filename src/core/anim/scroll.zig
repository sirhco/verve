//! ScrollTrigger config types for verve.anim. Pure data, target-agnostic:
//! compiles native (SSR) and wasm32-freestanding (anim_core). The JS
//! interpreter in verve.js owns all geometry; this file owns the
//! spec -> fraction math and the validation rules, both unit-tested here.
//!
//! Wire contract (frozen by serialize.zig goldens): start/end specs emit
//! as numeric pairs [triggerFrac, viewportFrac] (+ optional px offset);
//! toggle actions emit as the `Action` enum's integer values.

const std = @import("std");
const types = @import("types.zig");

/// A point on the trigger element or a line in the viewport, as a
/// fraction of the relevant height. 0 = top, 1 = bottom.
pub const Frac = union(enum) {
    top,
    center,
    bottom,
    /// Percent, 0..100 — `.{ .pct = 80 }` is GSAP's "80%".
    pct: f64,
    /// Raw fraction, 0..1.
    frac: f64,

    pub fn value(self: Frac) f64 {
        return switch (self) {
            .top => 0,
            .center => 0.5,
            .bottom => 1,
            .pct => |p| p / 100.0,
            .frac => |f| f,
        };
    }
};

/// "When <trigger point> crosses <viewport line>". GSAP's "top 80%" ==
/// `.{ .trigger = .top, .viewport = .{ .pct = 80 } }`.
pub const ScrollSpec = struct {
    /// Point on the trigger element (fraction of its height).
    trigger: Frac = .top,
    /// Line in the viewport (fraction of viewport height from the top).
    viewport: Frac = .bottom,
    /// Extra signed pixel offset added to the trigger point.
    offset_px: f64 = 0,
};

/// Where the trigger range ends.
pub const EndSpec = union(enum) {
    /// Absolute spec, same semantics as start.
    at: ScrollSpec,
    /// Pixels of scroll past the start position (GSAP "+=500").
    rel_px: f64,
    /// Viewport-heights of scroll past the start ("+=100%" == 1.0).
    rel_vh: f64,
};

/// How animation progress relates to scroll position.
pub const Scrub = union(enum) {
    /// Default: the trigger gates playback via `ToggleActions`.
    off,
    /// Progress locked 1:1 to the scrollbar.
    exact,
    /// Progress eases toward the scrollbar over `seconds`.
    smooth: f64,
};

/// Pin an element in place for the duration of the trigger range.
pub const Pin = union(enum) {
    off,
    /// Pin the trigger element itself.
    self,
    /// Pin another element (CSS selector).
    selector: []const u8,
};

/// Playback action applied at a trigger boundary. The integer values are
/// the wire contract — frozen by serialize.zig goldens.
pub const Action = enum(u3) {
    none = 0,
    play = 1,
    pause = 2,
    /// GSAP-parity name; `resume` is a Zig keyword, hence the quoting.
    @"resume" = 3,
    reverse = 4,
    restart = 5,
    complete = 6,
    reset = 7,
};

/// GSAP's 4-slot "play none none reverse", Zig-shaped. Default matches
/// GSAP's "play none none none".
pub const ToggleActions = struct {
    on_enter: Action = .play,
    on_leave: Action = .none,
    on_enter_back: Action = .none,
    on_leave_back: Action = .none,

    pub fn isDefault(self: ToggleActions) bool {
        return self.on_enter == .play and self.on_leave == .none and
            self.on_enter_back == .none and self.on_leave_back == .none;
    }
};

/// Snap targets in progress space (0..1) over the trigger's start..end
/// span. After scrolling goes idle inside (or near) the span, the engine
/// glides the NATIVE scroll position so progress lands on the nearest
/// point. Disabled entirely under prefers-reduced-motion.
pub const Snap = union(enum) {
    none,
    /// Snap to multiples of `step` (0 < step <= 1). 1.0 = start/end only
    /// — full-section snapping on a viewport-per-section trigger.
    step: f64,
    /// Explicit progress points: strictly ascending, each in [0, 1].
    points: []const f64,
};

/// ScrollTrigger config — the option struct for `.scrollTrigger(.{...})`
/// on tweens/timelines and for `reveal`/`verve.scrollTrigger`.
/// v1 scope: vertical scroll (window or a scrollable container element).
pub const ScrollTrigger = struct {
    /// CSS selector for the trigger element. null = the animation's own
    /// target (SSR: the node `.animate()` is called on).
    trigger: ?[]const u8 = null,
    /// Island-only: ref-handle trigger; wins over `trigger`.
    trigger_handle: ?i32 = null,

    /// CSS selector for the scroll container. null = window (default).
    /// When set, trigger geometry is computed relative to the scroller's
    /// scroll position and client rect, not the window. SSR-legal.
    scroller: ?[]const u8 = null,
    /// Island-only: ref-handle for the scroller; wins over `scroller`.
    scroller_handle: ?i32 = null,

    /// GSAP default "top bottom": trigger top meets viewport bottom.
    start: ScrollSpec = .{},
    /// GSAP default "bottom top".
    end: EndSpec = .{ .at = .{ .trigger = .bottom, .viewport = .top } },

    scrub: Scrub = .off,
    pin: Pin = .off,
    /// Settle the native scroll on progress points when input goes idle.
    /// Legal on any trigger (not just scrubbed ones).
    snap: Snap = .none,
    /// Snap glide duration, seconds.
    snap_duration: f64 = 0.4,
    /// Easing curve for the snap glide animation. Defaults to outCubic.
    snap_ease: types.Ease = .out_cubic,
    /// When true, snap biases toward the snap target in the direction of
    /// scroll travel rather than the nearest target. Falls back to nearest
    /// if no target exists in the travel direction.
    snap_directional: bool = false,
    actions: ToggleActions = .{},
    /// Fire on_enter once, then self-kill (toggle class stays applied).
    once: bool = false,
    /// Dev visualization: start/end lines drawn by the JS side.
    markers: bool = false,

    /// Class toggled while inside the range. SSR-legal, zero-wasm.
    toggle_class: ?[]const u8 = null,
    /// Selector receiving `toggle_class` (null = the trigger element).
    class_target: ?[]const u8 = null,

    /// Island-only lifecycle callbacks: event-slot ids (registerEvent,
    /// already chunk-table-translated). SSR serialize rejects these.
    on_enter_slot: ?u32 = null,
    on_leave_slot: ?u32 = null,
    on_enter_back_slot: ?u32 = null,
    on_leave_back_slot: ?u32 = null,
    /// Fires per scroll tick while active; read progress via the handle.
    on_update_slot: ?u32 = null,
    /// SSR named-export callbacks: dispatch `<export>` on island `isl`
    /// with `{"h":handle,"progress":p,"dir":d}` at enter / leave.
    cb_island: ?[]const u8 = null,
    cb_enter_export: ?[]const u8 = null,
    cb_leave_export: ?[]const u8 = null,

    pub fn hasSlots(self: *const ScrollTrigger) bool {
        return self.on_enter_slot != null or self.on_leave_slot != null or
            self.on_enter_back_slot != null or self.on_leave_back_slot != null or
            self.on_update_slot != null;
    }

    pub fn hasExports(self: *const ScrollTrigger) bool {
        return self.cb_island != null and
            (self.cb_enter_export != null or self.cb_leave_export != null);
    }

    /// Deferred-error validation, run by `.scrollTrigger(...)` / `reveal`.
    pub fn validate(self: *const ScrollTrigger) ?anyerror {
        if (self.scrub != .off and !self.actions.isDefault())
            return error.ScrubWithToggleActions;
        if (fracOutOfRange(self.start.trigger) or fracOutOfRange(self.start.viewport))
            return error.SpecOutOfRange;
        switch (self.end) {
            .at => |e| if (fracOutOfRange(e.trigger) or fracOutOfRange(e.viewport))
                return error.SpecOutOfRange,
            .rel_px, .rel_vh => {},
        }
        switch (self.snap) {
            .none => {},
            .step => |s| if (!(s > 0 and s <= 1)) return error.SnapStepOutOfRange,
            .points => |pts| {
                if (pts.len == 0) return error.SnapPointsEmpty;
                var prev: f64 = -1;
                for (pts) |p| {
                    if (!(p >= 0 and p <= 1)) return error.SnapPointOutOfRange;
                    if (p <= prev) return error.SnapPointsUnsorted;
                    prev = p;
                }
            },
        }
        if (self.snap != .none and
            !(self.snap_duration > 0 and std.math.isFinite(self.snap_duration)))
            return error.SnapDurationOutOfRange;
        return null;
    }

    /// Stricter check for the tween-less form (`reveal` / standalone
    /// trigger): with no animation attached, the trigger must DO
    /// something — toggle a class or fire a callback.
    pub fn validateStandalone(self: *const ScrollTrigger) ?anyerror {
        if (self.validate()) |e| return e;
        if (self.toggle_class == null and !self.hasSlots() and !self.hasExports())
            return error.TriggerDoesNothing;
        return null;
    }
};

fn fracOutOfRange(f: Frac) bool {
    const v = f.value();
    return !(v >= 0 and v <= 1);
}

/// Tween-less reveal trigger: class toggle and/or callbacks with NO
/// animation — zero wasm, zero rAF. Duck-types through `Node.animate`
/// (exposes `err` + `toJson`), so node.zig needs no change.
pub const Trigger = struct {
    alloc: std.mem.Allocator,
    config: ScrollTrigger,
    err: ?anyerror = null,

    pub fn toJson(self: *const Trigger, alloc: std.mem.Allocator) ![]const u8 {
        return @import("serialize.zig").triggerToJson(alloc, self, .ssr);
    }
};

pub var poison: Trigger = .{
    .alloc = undefined,
    .config = .{},
    .err = error.OutOfMemory,
};

/// Zero-wasm reveal: `ctx.h2("Pricing").animate(anim.reveal(a, "in-view",
/// .{ .start = .{ .viewport = .{ .pct = 85 } }, .once = true }))`.
/// `class` fills `cfg.toggle_class`. Pair with CSS transitions. Note:
/// CSS that hides content pending the class blanks no-JS users — prefer
/// `.from` tweens for essential content.
pub fn reveal(alloc: std.mem.Allocator, class: []const u8, cfg: ScrollTrigger) *Trigger {
    const t = alloc.create(Trigger) catch return &poison;
    var c = cfg;
    c.toggle_class = class;
    t.* = .{ .alloc = alloc, .config = c, .err = c.validateStandalone() };
    return t;
}

/// Standalone trigger builder for the island surface (callbacks-only ok).
pub fn trigger(alloc: std.mem.Allocator, cfg: ScrollTrigger) *Trigger {
    const t = alloc.create(Trigger) catch return &poison;
    t.* = .{ .alloc = alloc, .config = cfg, .err = cfg.validateStandalone() };
    return t;
}

test "Frac.value all variants" {
    try std.testing.expectEqual(@as(f64, 0), Frac.value(.top));
    try std.testing.expectEqual(@as(f64, 0.5), Frac.value(.center));
    try std.testing.expectEqual(@as(f64, 1), Frac.value(.bottom));
    try std.testing.expectEqual(@as(f64, 0.8), Frac.value(.{ .pct = 80 }));
    try std.testing.expectEqual(@as(f64, 0.33), Frac.value(.{ .frac = 0.33 }));
}

test "ToggleActions defaults and wire ints" {
    const def: ToggleActions = .{};
    try std.testing.expect(def.isDefault());
    try std.testing.expect(!(ToggleActions{ .on_leave_back = .reverse }).isDefault());
    // wire-int stability — the frozen contract
    try std.testing.expectEqual(@as(u3, 0), @intFromEnum(Action.none));
    try std.testing.expectEqual(@as(u3, 1), @intFromEnum(Action.play));
    try std.testing.expectEqual(@as(u3, 2), @intFromEnum(Action.pause));
    try std.testing.expectEqual(@as(u3, 3), @intFromEnum(Action.@"resume"));
    try std.testing.expectEqual(@as(u3, 4), @intFromEnum(Action.reverse));
    try std.testing.expectEqual(@as(u3, 5), @intFromEnum(Action.restart));
    try std.testing.expectEqual(@as(u3, 6), @intFromEnum(Action.complete));
    try std.testing.expectEqual(@as(u3, 7), @intFromEnum(Action.reset));
}

test "validate matrix" {
    // scrub + non-default actions conflict
    const bad: ScrollTrigger = .{
        .scrub = .exact,
        .actions = .{ .on_leave_back = .reverse },
    };
    try std.testing.expectEqual(@as(?anyerror, error.ScrubWithToggleActions), bad.validate());

    // scrub with default actions fine
    const ok: ScrollTrigger = .{ .scrub = .{ .smooth = 0.4 } };
    try std.testing.expectEqual(@as(?anyerror, null), ok.validate());

    // out-of-range fractions
    const oor: ScrollTrigger = .{ .start = .{ .viewport = .{ .pct = 150 } } };
    try std.testing.expectEqual(@as(?anyerror, error.SpecOutOfRange), oor.validate());
    const oor2: ScrollTrigger = .{ .end = .{ .at = .{ .trigger = .{ .frac = -0.1 } } } };
    try std.testing.expectEqual(@as(?anyerror, error.SpecOutOfRange), oor2.validate());

    // standalone must do something
    const nothing: ScrollTrigger = .{};
    try std.testing.expectEqual(@as(?anyerror, error.TriggerDoesNothing), nothing.validateStandalone());
    const cls: ScrollTrigger = .{ .toggle_class = "in-view" };
    try std.testing.expectEqual(@as(?anyerror, null), cls.validateStandalone());
    const slot: ScrollTrigger = .{ .on_enter_slot = 4 };
    try std.testing.expectEqual(@as(?anyerror, null), slot.validateStandalone());

    // container scroller: selector and handle both validate OK
    const sc_sel: ScrollTrigger = .{ .toggle_class = "in-view", .scroller = ".panel" };
    try std.testing.expectEqual(@as(?anyerror, null), sc_sel.validate());
    try std.testing.expectEqualStrings(".panel", sc_sel.scroller.?);
    const sc_h: ScrollTrigger = .{ .toggle_class = "in-view", .scroller_handle = 7 };
    try std.testing.expectEqual(@as(?anyerror, null), sc_h.validate());
    try std.testing.expectEqual(@as(?i32, 7), sc_h.scroller_handle.?);
}

test "snap validate matrix" {
    const ok_step: ScrollTrigger = .{ .scrub = .exact, .snap = .{ .step = 1 } };
    try std.testing.expectEqual(@as(?anyerror, null), ok_step.validate());
    // snap legal without scrub (toggle trigger snapping to its start)
    const ok_toggle: ScrollTrigger = .{ .snap = .{ .step = 0.5 } };
    try std.testing.expectEqual(@as(?anyerror, null), ok_toggle.validate());

    const big: ScrollTrigger = .{ .snap = .{ .step = 1.5 } };
    try std.testing.expectEqual(@as(?anyerror, error.SnapStepOutOfRange), big.validate());
    const zero: ScrollTrigger = .{ .snap = .{ .step = 0 } };
    try std.testing.expectEqual(@as(?anyerror, error.SnapStepOutOfRange), zero.validate());

    const empty: ScrollTrigger = .{ .snap = .{ .points = &.{} } };
    try std.testing.expectEqual(@as(?anyerror, error.SnapPointsEmpty), empty.validate());
    const oor: ScrollTrigger = .{ .snap = .{ .points = &.{ 0, 1.2 } } };
    try std.testing.expectEqual(@as(?anyerror, error.SnapPointOutOfRange), oor.validate());
    const unsorted: ScrollTrigger = .{ .snap = .{ .points = &.{ 0.5, 0.25 } } };
    try std.testing.expectEqual(@as(?anyerror, error.SnapPointsUnsorted), unsorted.validate());

    const bad_dur: ScrollTrigger = .{ .snap = .{ .step = 1 }, .snap_duration = 0 };
    try std.testing.expectEqual(@as(?anyerror, error.SnapDurationOutOfRange), bad_dur.validate());
    // duration ignored when snap off
    const off: ScrollTrigger = .{ .snap_duration = 0 };
    try std.testing.expectEqual(@as(?anyerror, null), off.validate());

    // snap_ease + snap_directional: any Ease is valid, bool is valid
    const snap_ease_dir: ScrollTrigger = .{
        .snap = .{ .step = 0.5 },
        .snap_ease = .in_out_sine,
        .snap_directional = true,
    };
    try std.testing.expectEqual(@as(?anyerror, null), snap_ease_dir.validate());
}

test "reveal builder fills class and validates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const t = reveal(a, "in-view", .{ .once = true });
    try std.testing.expect(t.err == null);
    try std.testing.expectEqualStrings("in-view", t.config.toggle_class.?);
    try std.testing.expect(t.config.once);

    const bad = reveal(a, "x", .{ .start = .{ .viewport = .{ .pct = 200 } } });
    try std.testing.expectEqual(@as(?anyerror, error.SpecOutOfRange), bad.err);
}
