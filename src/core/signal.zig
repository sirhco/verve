//! Reactive value holder. Reads inside an Effect record the effect as a
//! subscriber; writes notify every subscribed effect. Signals carry an
//! optional `on_set` hook so the WASM client can mirror writes into the
//! DOM bind layer without the framework knowing about DOM types.
//!
//! Signals are typically allocated under an Owner's arena via
//! `ctx.useSignal(T, initial)` so they live exactly as long as the
//! enclosing reactive scope.

const std = @import("std");
const effect_mod = @import("effect.zig");

pub const SubscriberList = effect_mod.SubscriberList;
pub const Effect = effect_mod.Effect;

pub fn Signal(comptime T: type) type {
    return struct {
        value: T,
        subs: SubscriberList,
        /// Optional post-write hook. The client passes
        /// `dom.set_text_by_bind_*` here so server-rendered Signal
        /// values stay synced with the DOM.
        on_set: ?*const fn (*anyopaque, T) void = null,
        on_set_ctx: ?*anyopaque = null,

        const Self = @This();

        pub fn init(initial: T, allocator: std.mem.Allocator) Self {
            return .{
                .value = initial,
                .subs = SubscriberList.init(allocator),
            };
        }

        /// Read the value AND subscribe the current effect (if any).
        /// Components that just want the latest value without tracking
        /// should call `peek()`.
        pub fn get(self: *Self) T {
            if (effect_mod.current_effect) |e| {
                self.subs.subscribe(e) catch {};
            }
            return self.value;
        }

        /// Read without tracking.
        pub fn peek(self: *const Self) T {
            return self.value;
        }

        /// Set + notify. No-op if the new value equals the old (avoids
        /// spurious re-runs). Flush happens when no batch is active.
        pub fn set(self: *Self, new_value: T) void {
            if (std.meta.eql(self.value, new_value)) return;
            self.value = new_value;
            if (self.on_set) |f| f(self.on_set_ctx.?, new_value);
            self.subs.notifyAll();
            effect_mod.flushIfNotBatched();
        }

        /// Convenience for numeric T.
        pub fn increment(self: *Self) void {
            comptime if (@typeInfo(T) != .int and @typeInfo(T) != .float) {
                @compileError("Signal.increment only valid for numeric T");
            };
            self.set(self.value + 1);
        }

        pub fn decrement(self: *Self) void {
            comptime if (@typeInfo(T) != .int and @typeInfo(T) != .float) {
                @compileError("Signal.decrement only valid for numeric T");
            };
            self.set(self.value - 1);
        }
    };
}

// ---- escape hatches --------------------------------------------------

/// Run `f` without subscribing the current effect to any signals read
/// inside it. Useful when reading a signal solely for a side-effect
/// (logging, condition checks) where the effect should *not* re-run on
/// changes.
pub fn untrack(comptime R: type, ctx_ptr: anytype, comptime f: fn (@TypeOf(ctx_ptr)) R) R {
    const prev = effect_mod.current_effect;
    effect_mod.current_effect = null;
    defer effect_mod.current_effect = prev;
    return f(ctx_ptr);
}

/// Coalesce a sequence of writes into a single flush. Effects scheduled
/// inside `f` run once after `f` returns, no matter how many of their
/// deps were touched.
pub fn batch(ctx_ptr: anytype, comptime f: fn (@TypeOf(ctx_ptr)) void) void {
    effect_mod.batch_depth += 1;
    f(ctx_ptr);
    effect_mod.batch_depth -= 1;
    if (effect_mod.batch_depth == 0) effect_mod.flush();
}

// ---- tests -----------------------------------------------------------

const testing = std.testing;
const Owner = @import("owner.zig").Owner;
const createEffect = effect_mod.createEffect;
const setPendingAllocator = effect_mod.setPendingAllocator;

test "Signal subscribers re-run on set" {
    var owner = Owner.init(testing.allocator);
    setPendingAllocator(owner.allocator());
    defer owner.dispose();

    var sig = Signal(i32).init(0, owner.allocator());

    const Counter = struct {
        var hits: u32 = 0;
        var last: i32 = 0;
        s: *Signal(i32),
        fn run(self: *@This()) void {
            last = self.s.get();
            hits += 1;
        }
    };
    Counter.hits = 0;
    Counter.last = 0;
    var c: Counter = .{ .s = &sig };

    _ = try createEffect(&owner, &c, Counter.run);
    try testing.expectEqual(@as(u32, 1), Counter.hits);
    try testing.expectEqual(@as(i32, 0), Counter.last);

    sig.set(7);
    try testing.expectEqual(@as(u32, 2), Counter.hits);
    try testing.expectEqual(@as(i32, 7), Counter.last);

    // No-op set should not re-run.
    sig.set(7);
    try testing.expectEqual(@as(u32, 2), Counter.hits);
}

test "Signal.peek reads without subscribing" {
    var owner = Owner.init(testing.allocator);
    setPendingAllocator(owner.allocator());
    defer owner.dispose();

    var sig = Signal(i32).init(0, owner.allocator());

    const Counter = struct {
        var hits: u32 = 0;
        s: *Signal(i32),
        fn run(self: *@This()) void {
            _ = self.s.peek();
            hits += 1;
        }
    };
    Counter.hits = 0;
    var c: Counter = .{ .s = &sig };

    _ = try createEffect(&owner, &c, Counter.run);
    try testing.expectEqual(@as(u32, 1), Counter.hits);

    sig.set(42);
    // Peek didn't track, so the effect must not have re-run.
    try testing.expectEqual(@as(u32, 1), Counter.hits);
}

test "untrack skips subscription for the wrapped read" {
    var owner = Owner.init(testing.allocator);
    setPendingAllocator(owner.allocator());
    defer owner.dispose();

    var tracked = Signal(i32).init(0, owner.allocator());
    var untracked_sig = Signal(i32).init(0, owner.allocator());

    const Counter = struct {
        var hits: u32 = 0;
        t: *Signal(i32),
        u: *Signal(i32),
        fn run(self: *@This()) void {
            _ = self.t.get();
            const Inner = struct {
                fn read(s: *Signal(i32)) void {
                    _ = s.get();
                }
            };
            untrack(void, self.u, Inner.read);
            hits += 1;
        }
    };
    Counter.hits = 0;
    var c: Counter = .{ .t = &tracked, .u = &untracked_sig };

    _ = try createEffect(&owner, &c, Counter.run);
    try testing.expectEqual(@as(u32, 1), Counter.hits);

    tracked.set(1);
    try testing.expectEqual(@as(u32, 2), Counter.hits);

    untracked_sig.set(1);
    // Untracked write should NOT have triggered a re-run.
    try testing.expectEqual(@as(u32, 2), Counter.hits);
}

test "batch coalesces multiple writes into one effect run" {
    var owner = Owner.init(testing.allocator);
    setPendingAllocator(owner.allocator());
    defer owner.dispose();

    var a = Signal(i32).init(0, owner.allocator());
    var b = Signal(i32).init(0, owner.allocator());

    const Counter = struct {
        var hits: u32 = 0;
        a: *Signal(i32),
        b: *Signal(i32),
        fn run(self: *@This()) void {
            _ = self.a.get();
            _ = self.b.get();
            hits += 1;
        }
    };
    Counter.hits = 0;
    var c: Counter = .{ .a = &a, .b = &b };

    _ = try createEffect(&owner, &c, Counter.run);
    try testing.expectEqual(@as(u32, 1), Counter.hits);

    const Updater = struct {
        a: *Signal(i32),
        b: *Signal(i32),
        fn run(self: *@This()) void {
            self.a.set(1);
            self.b.set(2);
        }
    };
    var u: Updater = .{ .a = &a, .b = &b };
    batch(&u, Updater.run);

    // Both writes occurred under a batch → exactly one re-run.
    try testing.expectEqual(@as(u32, 2), Counter.hits);
}

test "owner.dispose unsubscribes effects from signals" {
    var outer = Owner.init(testing.allocator);
    setPendingAllocator(outer.allocator());
    defer outer.dispose();

    var sig = Signal(i32).init(0, outer.allocator());

    var inner_owner = try outer.createChild();

    const Counter = struct {
        var hits: u32 = 0;
        s: *Signal(i32),
        fn run(self: *@This()) void {
            _ = self.s.get();
            hits += 1;
        }
    };
    Counter.hits = 0;
    var c: Counter = .{ .s = &sig };

    _ = try createEffect(inner_owner, &c, Counter.run);
    try testing.expectEqual(@as(u32, 1), Counter.hits);

    sig.set(1);
    try testing.expectEqual(@as(u32, 2), Counter.hits);

    inner_owner.dispose();
    sig.set(2);
    // Effect should be detached from sig — no further runs.
    try testing.expectEqual(@as(u32, 2), Counter.hits);
}
