//! Reactive Effect: a closure that re-runs whenever any signal it read
//! during its previous execution changes. Effects live under an Owner;
//! disposing the owner unsubscribes the effect from every signal it
//! tracked.
//!
//! Scheduling is synchronous: `Signal.set` walks the subscribers and
//! pushes them into a thread-local pending queue. When the outermost
//! `set` returns (or `batch` exits), the queue is drained — each
//! effect runs at most once per flush regardless of how many of its
//! deps changed.

const std = @import("std");
const Owner = @import("owner.zig").Owner;

/// Type-erased subscriber list owned by a `Signal(T)`. Pulled out into
/// a non-generic struct so `Effect.deps` can be a heterogeneous list of
/// `*SubscriberList` regardless of the source signal's T.
pub const SubscriberList = struct {
    subscribers: std.ArrayListUnmanaged(*Effect),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SubscriberList {
        return .{ .subscribers = .empty, .allocator = allocator };
    }

    pub fn subscribe(self: *SubscriberList, effect: *Effect) !void {
        for (self.subscribers.items) |s| if (s == effect) return;
        try self.subscribers.append(self.allocator, effect);
        try effect.deps.append(effect.owner.allocator(), self);
    }

    pub fn unsubscribe(self: *SubscriberList, effect: *Effect) void {
        var i: usize = 0;
        while (i < self.subscribers.items.len) : (i += 1) {
            if (self.subscribers.items[i] == effect) {
                _ = self.subscribers.swapRemove(i);
                return;
            }
        }
    }

    /// Schedule every subscribed effect for re-run. Caller is responsible
    /// for flushing the queue.
    pub fn notifyAll(self: *SubscriberList) void {
        for (self.subscribers.items) |e| scheduleEffect(e);
    }
};

pub const Effect = struct {
    owner: *Owner,
    callback: *const fn (*anyopaque) void,
    ctx: *anyopaque,
    deps: std.ArrayListUnmanaged(*SubscriberList),
    scheduled: bool,
    disposed: bool,

    pub fn run(self: *Effect) void {
        if (self.disposed) return;
        // Drop old subscriptions before re-collecting — a branch the
        // effect doesn't read anymore shouldn't keep waking it up.
        for (self.deps.items) |list| list.unsubscribe(self);
        self.deps.clearRetainingCapacity();

        const prev = current_effect;
        current_effect = self;
        defer current_effect = prev;
        self.callback(self.ctx);
    }

    /// Owner cleanup target: walks deps, unsubscribes from each signal,
    /// marks the effect dead so any in-flight schedule entry is a no-op
    /// when drained.
    pub fn dispose(self: *Effect) void {
        if (self.disposed) return;
        self.disposed = true;
        for (self.deps.items) |list| list.unsubscribe(self);
        self.deps.clearRetainingCapacity();
    }
};

// ---- thread-local reactive state -------------------------------------

/// Current running effect, or null when reading happens outside any
/// reactive scope. Signal.get() reads this to decide whether to add a
/// subscription.
pub threadlocal var current_effect: ?*Effect = null;

/// Batching depth. Each `batch(fn)` increments on entry and decrements
/// on exit; the flush happens when the depth drops back to zero.
pub threadlocal var batch_depth: u32 = 0;

/// Pending re-run queue. Initialized lazily on first use.
pub threadlocal var pending: std.ArrayListUnmanaged(*Effect) = .empty;
pub threadlocal var pending_alloc: ?std.mem.Allocator = null;

/// Set the allocator used to grow the pending queue. The server calls
/// this once per request with the per-request arena so the queue's
/// scratch memory lives the right lifetime. Resets the queue's internal
/// slice so the previous arena's freed memory doesn't get reused as a
/// stale items.ptr.
pub fn setPendingAllocator(a: std.mem.Allocator) void {
    pending = .empty;
    pending_alloc = a;
}

pub fn scheduleEffect(effect: *Effect) void {
    if (effect.disposed or effect.scheduled) return;
    effect.scheduled = true;
    if (pending_alloc) |a| {
        pending.append(a, effect) catch {
            effect.scheduled = false;
        };
    }
}

/// Drain the pending queue. Called at the bottom of the outermost
/// `Signal.set` and on `batch` exit.
pub fn flush() void {
    while (pending.items.len > 0) {
        const effect = pending.orderedRemove(0);
        effect.scheduled = false;
        effect.run();
    }
}

/// Drain only when no batch is active.
pub fn flushIfNotBatched() void {
    if (batch_depth == 0) flush();
}

// ---- API ---------------------------------------------------------------

/// Create an Effect attached to `owner`. The effect runs once eagerly
/// to collect its dependencies, then again whenever any tracked signal
/// changes. Disposing `owner` cleans the effect up.
pub fn createEffect(owner: *Owner, ctx_ptr: anytype, comptime f: fn (@TypeOf(ctx_ptr)) void) !*Effect {
    const CtxT = @TypeOf(ctx_ptr);
    comptime std.debug.assert(@typeInfo(CtxT) == .pointer);

    const effect = try owner.allocator().create(Effect);
    effect.* = .{
        .owner = owner,
        .callback = EffectWrap(CtxT, f).invoke,
        .ctx = @as(*anyopaque, @ptrCast(@constCast(ctx_ptr))),
        .deps = .empty,
        .scheduled = false,
        .disposed = false,
    };

    try owner.onCleanup(effect, Effect.dispose);

    // Eager first run — collects deps.
    effect.run();
    return effect;
}

/// Generic callback trampoline factory. Mirrors `owner.CleanupWrap` —
/// declared outside `createEffect` to keep each (CtxT, f) instantiation
/// distinct.
fn EffectWrap(comptime CtxT: type, comptime f: fn (CtxT) void) type {
    return struct {
        pub fn invoke(raw: *anyopaque) void {
            const typed: CtxT = @ptrCast(@alignCast(raw));
            f(typed);
        }
    };
}

// ---- tests ------------------------------------------------------------

const testing = std.testing;

test "createEffect runs eagerly once" {
    var owner = Owner.init(testing.allocator);
    setPendingAllocator(owner.allocator());
    defer owner.dispose();

    const Counter = struct {
        var count: u32 = 0;
        var ptr_self: *@This() = undefined;
        fn run(_: *@This()) void {
            count += 1;
        }
    };
    Counter.count = 0;
    var self: Counter = .{};

    _ = try createEffect(&owner, &self, Counter.run);
    try testing.expectEqual(@as(u32, 1), Counter.count);
}
