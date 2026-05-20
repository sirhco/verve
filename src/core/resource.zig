//! Reactive async data wrapper. Server-side, the fetcher is invoked
//! synchronously during render — the result is stuffed into a
//! `Signal(ResourceState(T))` that components can read with normal
//! reactive tracking. The state union mirrors Leptos:
//!
//!   - `loading` — fetcher hasn't returned (only seen client-side after
//!     phase-4 hydration; SSR never serializes a loading state).
//!   - `ready(T)` — fetcher returned successfully.
//!   - `err(anyerror)` — fetcher errored; the boundary's UI can render
//!     a fallback.
//!
//! Phase 3 ships the SSR side only. Phase 4 layers `<Suspense>` on top
//! and the streaming pipeline that lets `loading` resources emit a
//! placeholder + swap-in chunk. Phase 8's islands serialize the ready
//! value into the hydration payload so the client doesn't re-fetch.

const std = @import("std");
const Owner = @import("owner.zig").Owner;
const signal_mod = @import("signal.zig");
const suspense_mod = @import("suspense.zig");

pub fn ResourceState(comptime T: type) type {
    return union(enum) {
        loading,
        ready: T,
        err: anyerror,
    };
}

pub fn Resource(comptime T: type) type {
    return struct {
        state: signal_mod.Signal(ResourceState(T)),
        owner: *Owner,

        const Self = @This();

        /// Update the resource's value. Triggers any reactive consumers.
        pub fn set(self: *Self, value: T) void {
            self.state.set(.{ .ready = value });
        }

        /// Record an error. Reactive consumers see the new state and
        /// can render a fallback.
        pub fn fail(self: *Self, e: anyerror) void {
            self.state.set(.{ .err = e });
        }

        /// Read the current value if ready. Subscribes the active
        /// effect (if any) so re-fetches notify. When the resource is
        /// still loading, signals the nearest `<Suspense>` boundary to
        /// emit its fallback in place of the current subtree.
        pub fn get(self: *Self) ?T {
            return switch (self.state.get()) {
                .ready => |v| v,
                .loading => blk: {
                    suspense_mod.markSuspended();
                    break :blk null;
                },
                .err => null,
            };
        }

        /// Non-subscribing read.
        pub fn peek(self: *const Self) ResourceState(T) {
            return self.state.peek();
        }

        pub fn isLoading(self: *Self) bool {
            return switch (self.state.get()) {
                .loading => true,
                else => false,
            };
        }

        pub fn isReady(self: *Self) bool {
            return switch (self.state.get()) {
                .ready => true,
                else => false,
            };
        }

        pub fn isErr(self: *Self) bool {
            return switch (self.state.get()) {
                .err => true,
                else => false,
            };
        }
    };
}

/// Allocate a Resource under `owner` and immediately invoke `fetcher`
/// synchronously. Server-side render only — the result lands in the
/// initial Signal value so the first read is already `.ready` or
/// `.err`. Phase 4/8 will layer async fetch + hydration on top.
pub fn create(
    comptime T: type,
    owner: *Owner,
    ctx_ptr: anytype,
    comptime fetcher: fn (@TypeOf(ctx_ptr)) anyerror!T,
) !*Resource(T) {
    const res = try owner.allocator().create(Resource(T));
    res.* = .{
        .state = signal_mod.Signal(ResourceState(T)).init(.loading, owner.allocator()),
        .owner = owner,
    };

    if (fetcher(ctx_ptr)) |value| {
        res.state.set(.{ .ready = value });
    } else |err| {
        res.state.set(.{ .err = err });
    }
    return res;
}

/// Local resource — declared for API parity with Leptos. On Phase 3
/// server-side, `local` is identical to `create`. Phase 8's island
/// runtime will distinguish them (LocalResource is never serialized
/// into the hydration payload — the client runs the fetcher itself).
pub fn createLocal(
    comptime T: type,
    owner: *Owner,
    ctx_ptr: anytype,
    comptime fetcher: fn (@TypeOf(ctx_ptr)) anyerror!T,
) !*Resource(T) {
    return create(T, owner, ctx_ptr, fetcher);
}

// ---- tests ------------------------------------------------------------

const testing = std.testing;
const effect_mod = @import("effect.zig");

test "Resource runs fetcher synchronously and lands ready" {
    var owner = Owner.init(testing.allocator);
    effect_mod.setPendingAllocator(owner.allocator());
    defer owner.dispose();

    const Fetcher = struct {
        n: u32,
        fn run(self: *@This()) anyerror!u32 {
            return self.n * 2;
        }
    };
    var f: Fetcher = .{ .n = 21 };

    const res = try create(u32, &owner, &f, Fetcher.run);
    try testing.expect(res.isReady());
    try testing.expectEqual(@as(u32, 42), res.get().?);
}

test "Resource captures fetcher error" {
    var owner = Owner.init(testing.allocator);
    effect_mod.setPendingAllocator(owner.allocator());
    defer owner.dispose();

    const Fetcher = struct {
        fn run(_: *@This()) anyerror!u32 {
            return error.SimulatedFailure;
        }
    };
    var f: Fetcher = .{};

    const res = try create(u32, &owner, &f, Fetcher.run);
    try testing.expect(res.isErr());
}

test "Resource notifies effects when set/fail" {
    var owner = Owner.init(testing.allocator);
    effect_mod.setPendingAllocator(owner.allocator());
    defer owner.dispose();

    const Fetcher = struct {
        fn run(_: *@This()) anyerror!u32 {
            return 1;
        }
    };
    var f: Fetcher = .{};
    const res = try create(u32, &owner, &f, Fetcher.run);

    const Tracker = struct {
        var hits: u32 = 0;
        var last: ?u32 = null;
        r: *Resource(u32),
        fn run(self: *@This()) void {
            last = self.r.get();
            hits += 1;
        }
    };
    Tracker.hits = 0;
    Tracker.last = null;
    var tr: Tracker = .{ .r = res };

    _ = try effect_mod.createEffect(&owner, &tr, Tracker.run);
    try testing.expectEqual(@as(u32, 1), Tracker.hits);
    try testing.expectEqual(@as(?u32, 1), Tracker.last);

    res.set(42);
    try testing.expectEqual(@as(u32, 2), Tracker.hits);
    try testing.expectEqual(@as(?u32, 42), Tracker.last);
}
