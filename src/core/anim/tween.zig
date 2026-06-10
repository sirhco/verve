//! Tween builder. Mirrors the Node chain pattern: every method returns
//! `*Tween`, allocation failures and misuse are absorbed onto `self.err`
//! and surface at the chain terminus (`Node.animate`, `Timeline.add`, or
//! `verve.animPlay`). Allocator is passed at the factory and never freed —
//! SSR uses the request arena, islands use the chunk arena.

const std = @import("std");
const types = @import("types.zig");

pub const PropEntry = struct {
    /// Wire prop name: "x", "opacity", "background-color", "attr:cx", ...
    name: []const u8,
    /// Primary value (the start value when `kind == .from`).
    to: types.Value,
    /// Explicit start -> per-prop fromTo.
    from: ?types.Value = null,
};

pub const Step = struct {
    /// Offset within the tween, 0..100.
    at_pct: f64,
    /// Ease INTO this step (overrides the tween default for the segment).
    ease_kind: ?types.Ease = null,
    props: std.ArrayList(PropEntry) = .empty,
};

pub const Tween = struct {
    alloc: std.mem.Allocator,
    kind: types.Kind = .to,
    /// CSS selector. SSR: null = the node `.animate()` is called on;
    /// non-null = `querySelectorAll` scoped to that node's descendants.
    /// Island: required (or a ref handle via the island glue).
    target: ?[]const u8 = null,
    /// Optional ref handle target (island surface). Wins over `target`.
    target_handle: ?i32 = null,
    /// Name for cross-surface lookup (`verve_anim_lookup`). Wire: "id".
    id_name: ?[]const u8 = null,

    /// Simple multi-prop mode — exclusive with `steps`.
    props: std.ArrayList(PropEntry) = .empty,
    /// Keyframe mode — opened by `.step(pct)`; subsequent prop calls land
    /// in the last opened step.
    steps: std.ArrayList(Step) = .empty,

    duration_s: f64 = 0.5,
    delay_s: f64 = 0,
    ease_kind: types.Ease = .out_quad,
    /// -1 = infinite.
    repeat_n: i32 = 0,
    repeat_delay_s: f64 = 0,
    yoyo_on: bool = false,
    stagger_opts: ?types.Stagger = null,
    modifiers: std.ArrayList(types.Modifier) = .empty,
    reduced: types.ReducedMotion = .jump_to_end,
    /// false = constructed paused (`animPrepare`); wire "auto":0.
    autoplay: bool = true,

    /// Lifecycle callbacks as event-slot ids (`verve.registerEvent`,
    /// already chunk-table-translated — raw fn-table indices would dangle).
    on_start_slot: ?u32 = null,
    on_complete_slot: ?u32 = null,
    on_repeat_slot: ?u32 = null,
    /// Declarative/SSR callback form: a named export on an island chunk,
    /// dispatched via `callIslandExport(island, name, {"anim": id})`.
    cb_island: ?[]const u8 = null,
    cb_complete_export: ?[]const u8 = null,

    err: ?anyerror = null,

    // ---- timing / shape ---------------------------------------------------

    pub fn duration(self: *Tween, s: f64) *Tween {
        if (self.err != null) return self;
        self.duration_s = s;
        return self;
    }

    pub fn delay(self: *Tween, s: f64) *Tween {
        if (self.err != null) return self;
        self.delay_s = s;
        return self;
    }

    pub fn ease(self: *Tween, e: types.Ease) *Tween {
        if (self.err != null) return self;
        self.ease_kind = e;
        return self;
    }

    pub fn repeat(self: *Tween, n: i32) *Tween {
        if (self.err != null) return self;
        self.repeat_n = n;
        return self;
    }

    pub fn repeatDelay(self: *Tween, s: f64) *Tween {
        if (self.err != null) return self;
        self.repeat_delay_s = s;
        return self;
    }

    pub fn yoyo(self: *Tween, on: bool) *Tween {
        if (self.err != null) return self;
        self.yoyo_on = on;
        return self;
    }

    pub fn stagger(self: *Tween, s: types.Stagger) *Tween {
        if (self.err != null) return self;
        self.stagger_opts = s;
        return self;
    }

    pub fn reducedMotion(self: *Tween, rm: types.ReducedMotion) *Tween {
        if (self.err != null) return self;
        self.reduced = rm;
        return self;
    }

    pub fn modifier(self: *Tween, m: types.Modifier) *Tween {
        if (self.err != null) return self;
        self.modifiers.append(self.alloc, m) catch |e| {
            self.err = e;
        };
        return self;
    }

    /// Name this animation for cross-surface control
    /// (`verve.animLookup("name")` from any island).
    pub fn named(self: *Tween, n: []const u8) *Tween {
        if (self.err != null) return self;
        self.id_name = n;
        return self;
    }

    /// Construct paused; play via the control API.
    pub fn paused(self: *Tween) *Tween {
        if (self.err != null) return self;
        self.autoplay = false;
        return self;
    }

    // ---- properties --------------------------------------------------------

    /// Generic property. `v` accepts numbers, strings, and `anim.Value`
    /// literals (see `types.value`). In keyframe mode (after `.step`),
    /// the prop lands in the last opened step.
    pub fn prop(self: *Tween, prop_name: []const u8, v: anytype) *Tween {
        if (self.err != null) return self;
        const entry: PropEntry = .{ .name = prop_name, .to = types.value(v) };
        if (self.steps.items.len > 0) {
            const last = &self.steps.items[self.steps.items.len - 1];
            last.props.append(self.alloc, entry) catch |e| {
                self.err = e;
            };
            return self;
        }
        self.props.append(self.alloc, entry) catch |e| {
            self.err = e;
        };
        return self;
    }

    /// Explicit start value for the most recently added prop (per-prop
    /// fromTo). Keyframe steps carry absolute values — `propFrom` there is
    /// an error.
    pub fn propFrom(self: *Tween, prop_name: []const u8, v: anytype) *Tween {
        if (self.err != null) return self;
        if (self.steps.items.len > 0) {
            self.err = error.FromInKeyframeStep;
            return self;
        }
        for (self.props.items) |*p| {
            if (std.mem.eql(u8, p.name, prop_name)) {
                p.from = types.value(v);
                return self;
            }
        }
        self.err = error.UnknownProp;
        return self;
    }

    pub fn x(self: *Tween, v: anytype) *Tween {
        return self.prop("x", v);
    }

    pub fn y(self: *Tween, v: anytype) *Tween {
        return self.prop("y", v);
    }

    pub fn scale(self: *Tween, v: anytype) *Tween {
        return self.prop("scale", v);
    }

    pub fn scaleX(self: *Tween, v: anytype) *Tween {
        return self.prop("scaleX", v);
    }

    pub fn scaleY(self: *Tween, v: anytype) *Tween {
        return self.prop("scaleY", v);
    }

    pub fn rotate(self: *Tween, v: anytype) *Tween {
        return self.prop("rotate", v);
    }

    pub fn opacity(self: *Tween, v: anytype) *Tween {
        return self.prop("opacity", v);
    }

    pub fn width(self: *Tween, v: anytype) *Tween {
        return self.prop("width", v);
    }

    pub fn height(self: *Tween, v: anytype) *Tween {
        return self.prop("height", v);
    }

    // ---- keyframes ----------------------------------------------------------

    /// Open a keyframe step at `at_pct` (0..100) — subsequent prop calls
    /// land in it. Exclusive with the simple multi-prop mode: calling
    /// `.step` after plain props is a deferred error.
    pub fn step(self: *Tween, at_pct: f64) *Tween {
        if (self.err != null) return self;
        if (self.props.items.len > 0) {
            self.err = error.StepAfterProps;
            return self;
        }
        self.steps.append(self.alloc, .{ .at_pct = at_pct }) catch |e| {
            self.err = e;
        };
        return self;
    }

    /// Ease into the most recently opened step.
    pub fn stepEase(self: *Tween, e: types.Ease) *Tween {
        if (self.err != null) return self;
        if (self.steps.items.len == 0) {
            self.err = error.EaseWithoutStep;
            return self;
        }
        self.steps.items[self.steps.items.len - 1].ease_kind = e;
        return self;
    }

    // ---- callbacks (raw slot form; island glue provides sugar) -------------

    pub fn onStartSlot(self: *Tween, slot_id: u32) *Tween {
        if (self.err != null) return self;
        self.on_start_slot = slot_id;
        return self;
    }

    pub fn onCompleteSlot(self: *Tween, slot_id: u32) *Tween {
        if (self.err != null) return self;
        self.on_complete_slot = slot_id;
        return self;
    }

    pub fn onRepeatSlot(self: *Tween, slot_id: u32) *Tween {
        if (self.err != null) return self;
        self.on_repeat_slot = slot_id;
        return self;
    }

    /// SSR/declarative completion callback: dispatch a named export on an
    /// island chunk when the animation finishes.
    pub fn onCompleteExport(self: *Tween, island_name: []const u8, export_name: []const u8) *Tween {
        if (self.err != null) return self;
        self.cb_island = island_name;
        self.cb_complete_export = export_name;
        return self;
    }

    // ---- timing math --------------------------------------------------------

    /// Total seconds including delay, repeats, and repeat delays. Infinite
    /// repeat returns +inf. Stagger spread is included only when
    /// `stagger.total` is set — with `each`, the matched element count is
    /// unknown until runtime, so timeline sequencing after a staggered
    /// child should use `total`.
    pub fn totalDuration(self: *const Tween) f64 {
        if (self.repeat_n < 0) return std.math.inf(f64);
        const cycles: f64 = @floatFromInt(self.repeat_n + 1);
        const repeats: f64 = @floatFromInt(self.repeat_n);
        const base = self.delay_s + self.duration_s * cycles + self.repeat_delay_s * repeats;
        const spread = if (self.stagger_opts) |s| (s.total orelse 0) else 0;
        return base + spread;
    }

    // ---- serialization terminus --------------------------------------------

    /// SSR-strict JSON (rejects dynamic values — `error.DynRequiresIsland`).
    /// Duck-typed contract used by `Node.animate`.
    pub fn toJson(self: *const Tween, alloc: std.mem.Allocator) ![]const u8 {
        return @import("serialize.zig").tweenToJson(alloc, self, .ssr);
    }
};

/// Shared sentinel returned by factories when allocation fails. Methods on
/// a poisoned tween short-circuit via the `err` check, so the poison is
/// never mutated after init.
pub var poison: Tween = .{
    .alloc = undefined,
    .err = error.OutOfMemory,
};

pub fn to(alloc: std.mem.Allocator, target: ?[]const u8) *Tween {
    const t = alloc.create(Tween) catch return &poison;
    t.* = .{ .alloc = alloc, .kind = .to, .target = target };
    return t;
}

pub fn from(alloc: std.mem.Allocator, target: ?[]const u8) *Tween {
    const t = alloc.create(Tween) catch return &poison;
    t.* = .{ .alloc = alloc, .kind = .from, .target = target };
    return t;
}

test "chain builds props" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = to(arena.allocator(), ".card").x(120).opacity(0.5).duration(0.8).ease(.out_back);
    try std.testing.expect(t.err == null);
    try std.testing.expectEqual(@as(usize, 2), t.props.items.len);
    try std.testing.expectEqualStrings("x", t.props.items[0].name);
    try std.testing.expectEqual(@as(f64, 120), t.props.items[0].to.num);
    try std.testing.expectEqual(types.Ease.out_back, t.ease_kind);
}

test "step after props is a deferred error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = to(arena.allocator(), ".x").opacity(1).step(50);
    try std.testing.expectEqual(@as(?anyerror, error.StepAfterProps), t.err);
}

test "keyframe steps collect props" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = to(arena.allocator(), ".pulse")
        .step(0).scale(1.0)
        .step(50).stepEase(.in_out_sine).scale(1.15)
        .step(100).scale(1.0);
    try std.testing.expect(t.err == null);
    try std.testing.expectEqual(@as(usize, 3), t.steps.items.len);
    try std.testing.expectEqual(types.Ease.in_out_sine, t.steps.items[1].ease_kind.?);
    try std.testing.expectEqual(@as(usize, 1), t.steps.items[1].props.items.len);
}

test "propFrom targets an existing prop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = to(arena.allocator(), null).opacity(1).propFrom("opacity", 0);
    try std.testing.expect(t.err == null);
    try std.testing.expectEqual(@as(f64, 0), t.props.items[0].from.?.num);

    const bad = to(arena.allocator(), null).propFrom("nope", 0);
    try std.testing.expectEqual(@as(?anyerror, error.UnknownProp), bad.err);
}

test "poison chain survives" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const t = to(failing.allocator(), ".x").x(1).duration(2).step(0).yoyo(true);
    try std.testing.expectEqual(@as(?anyerror, error.OutOfMemory), t.err);
    try std.testing.expect(t == &poison);
}

test "totalDuration with repeat and repeatDelay" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = to(arena.allocator(), ".x").duration(1.0).delay(0.5).repeat(2).repeatDelay(0.25);
    // 0.5 + 3*1.0 + 2*0.25 = 4.0
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), t.totalDuration(), 1e-12);

    const inf = to(arena.allocator(), ".x").repeat(-1);
    try std.testing.expect(std.math.isInf(inf.totalDuration()));

    const st = to(arena.allocator(), ".x").duration(1.0).stagger(.{ .total = 0.6 });
    try std.testing.expectApproxEqAbs(@as(f64, 1.6), st.totalDuration(), 1e-12);
}
