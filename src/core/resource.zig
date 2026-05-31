//! Reactive async data wrapper. The fetcher is launched asynchronously via
//! `std.Io` at creation time. The resource starts in `.loading` state until
//! `resolve(io)` is called, which awaits the `Future` and transitions the
//! Signal to `.ready` or `.err`.
//!
//!   - `loading` — fetcher hasn't resolved yet.
//!   - `ready(T)` — fetcher returned successfully.
//!   - `err(anyerror)` — fetcher errored; the boundary's UI can render
//!     a fallback.
//!
//! Phase 3 ships the SSR side. Phase 4 layers `<Suspense>` on top and the
//! streaming drain loop that drives `resolve` for pending boundaries. Phase 8's
//! islands serialize the ready value into the hydration payload so the client
//! doesn't re-fetch.

const std = @import("std");
const Owner = @import("owner.zig").Owner;
const signal_mod = @import("signal.zig");
const suspense_mod = @import("suspense.zig");
const stream_context = @import("stream_context.zig");

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
        /// The in-flight async future. Non-null from `create` until the first
        /// call to `resolve`/`awaitFuture`. Set to null afterwards (idempotent).
        future: ?std.Io.Future(anyerror!T) = null,
        /// Staging slot written by `awaitFuture` on a worker thread and read
        /// by `applyStaged` on the main thread. Splitting await from apply lets
        /// the concurrent streaming drain block on the future off-thread while
        /// keeping all Signal mutation on the main thread.
        staged: ?(anyerror!T) = null,

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
                    // Register an await/apply resolver into the active capture
                    // (if any) so the enclosing suspense boundary learns which
                    // resources its drain must await. No-op when no capture is
                    // active (non-streaming renders). Done BEFORE markSuspended.
                    stream_context.captureResolver(.{
                        .ctx = self,
                        .awaitFn = struct {
                            fn f(p: *anyopaque, io: std.Io) void {
                                const r: *Self = @ptrCast(@alignCast(p));
                                r.awaitFuture(io);
                            }
                        }.f,
                        .applyFn = struct {
                            fn f(p: *anyopaque) void {
                                const r: *Self = @ptrCast(@alignCast(p));
                                r.applyStaged();
                            }
                        }.f,
                    });
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

        /// WORKER-SAFE. Block on the in-flight future (if any) and stash the
        /// result into `staged`. Touches ONLY `self.staged` and `self.future` —
        /// no Signal mutation, no arena allocation — so it is safe to call on a
        /// concurrent worker thread. No-op when the future is already cleared.
        pub fn awaitFuture(self: *Self, io: std.Io) void {
            const f = &(self.future orelse return);
            self.staged = f.await(io);
            self.future = null;
        }

        /// MAIN THREAD. Settle the resource Signal from a previously staged
        /// result. Must run on the thread that owns the reactive system. No-op
        /// when nothing has been staged.
        pub fn applyStaged(self: *Self) void {
            const result = self.staged orelse return;
            self.staged = null;
            if (result) |value| {
                self.state.set(.{ .ready = value });
            } else |err| {
                self.state.set(.{ .err = err });
            }
        }

        /// Await the in-flight future (if any) and settle the resource state.
        /// Idempotent: calling resolve a second time is a no-op because the
        /// future is cleared on first await. Equivalent to `awaitFuture`
        /// followed by `applyStaged` — kept for the synchronous (non-streaming)
        /// drain path.
        pub fn resolve(self: *Self, io: std.Io) void {
            self.awaitFuture(io);
            self.applyStaged();
        }
    };
}

/// Allocate a Resource under `owner` and launch `fetcher` asynchronously via
/// `io`. The resource starts in `.loading` state. Call `res.resolve(io)` to
/// await the future and settle the state to `.ready` or `.err`.
pub fn create(
    comptime T: type,
    io: std.Io,
    owner: *Owner,
    ctx_ptr: anytype,
    comptime fetcher: fn (@TypeOf(ctx_ptr)) anyerror!T,
) !*Resource(T) {
    const res = try owner.allocator().create(Resource(T));
    res.* = .{
        .state = signal_mod.Signal(ResourceState(T)).init(.loading, owner.allocator()),
        .owner = owner,
        .future = io.async(fetcher, .{ctx_ptr}),
    };
    return res;
}

/// Build a Resource already in `.ready(value)` WITHOUT launching a fetcher.
/// Used client-side to hydrate from serialized SSR state.
pub fn ready(comptime T: type, owner: *Owner, value: T) !*Resource(T) {
    const res = try owner.allocator().create(Resource(T));
    res.* = .{
        .state = signal_mod.Signal(ResourceState(T)).init(.{ .ready = value }, owner.allocator()),
        .owner = owner,
    };
    return res;
}

/// Local resource — declared for API parity with Leptos. On Phase 3
/// server-side, `local` is identical to `create`. Phase 8's island
/// runtime will distinguish them (LocalResource is never serialized
/// into the hydration payload — the client runs the fetcher itself).
pub fn createLocal(
    comptime T: type,
    io: std.Io,
    owner: *Owner,
    ctx_ptr: anytype,
    comptime fetcher: fn (@TypeOf(ctx_ptr)) anyerror!T,
) !*Resource(T) {
    return create(T, io, owner, ctx_ptr, fetcher);
}

// ---- tests ------------------------------------------------------------

const testing = std.testing;
const effect_mod = @import("effect.zig");

fn makeTestIo(allocator: std.mem.Allocator) std.Io.Threaded {
    return std.Io.Threaded.init(allocator, .{});
}

test "Resource runs fetcher asynchronously and lands ready after resolve" {
    var threaded = makeTestIo(testing.allocator);
    defer threaded.deinit();
    const io = threaded.io();

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

    const res = try create(u32, io, &owner, &f, Fetcher.run);
    // Before resolve: still loading (future in flight).
    res.resolve(io);
    try testing.expect(res.isReady());
    try testing.expectEqual(@as(u32, 42), res.get().?);
}

test "Resource captures fetcher error after resolve" {
    var threaded = makeTestIo(testing.allocator);
    defer threaded.deinit();
    const io = threaded.io();

    var owner = Owner.init(testing.allocator);
    effect_mod.setPendingAllocator(owner.allocator());
    defer owner.dispose();

    const Fetcher = struct {
        fn run(_: *@This()) anyerror!u32 {
            return error.SimulatedFailure;
        }
    };
    var f: Fetcher = .{};

    const res = try create(u32, io, &owner, &f, Fetcher.run);
    res.resolve(io);
    try testing.expect(res.isErr());
}

test "Resource notifies effects when set/fail" {
    var threaded = makeTestIo(testing.allocator);
    defer threaded.deinit();
    const io = threaded.io();

    var owner = Owner.init(testing.allocator);
    effect_mod.setPendingAllocator(owner.allocator());
    defer owner.dispose();

    const Fetcher = struct {
        fn run(_: *@This()) anyerror!u32 {
            return 1;
        }
    };
    var f: Fetcher = .{};
    const res = try create(u32, io, &owner, &f, Fetcher.run);
    // Resolve so the resource is ready before the effect subscribes.
    res.resolve(io);

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

test "resolve is idempotent" {
    var threaded = makeTestIo(testing.allocator);
    defer threaded.deinit();
    const io = threaded.io();

    var owner = Owner.init(testing.allocator);
    effect_mod.setPendingAllocator(owner.allocator());
    defer owner.dispose();

    const Fetcher = struct {
        n: u32,
        fn run(self: *@This()) anyerror!u32 {
            return self.n * 3;
        }
    };
    var f: Fetcher = .{ .n = 7 };

    const res = try create(u32, io, &owner, &f, Fetcher.run);
    res.resolve(io); // first resolve — awaits future
    res.resolve(io); // second resolve — must be a no-op
    try testing.expect(res.isReady());
    try testing.expectEqual(@as(u32, 21), res.get().?);
}

test "ready builds a ready resource without a fetcher" {
    var owner = Owner.init(testing.allocator);
    effect_mod.setPendingAllocator(owner.allocator());
    defer owner.dispose();
    const res = try ready(i32, &owner, 42);
    try testing.expect(res.isReady());
    try testing.expectEqual(@as(i32, 42), res.get().?);
}
