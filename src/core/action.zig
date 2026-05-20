//! Reactive wrapper around an imperative async operation. An Action
//! holds:
//!
//!   - `pending: Signal(bool)` — true while a dispatch is in flight
//!   - `value: Signal(?Result)` — last completed return value
//!   - `input: Signal(?Args)` — most recent dispatched input
//!   - `version: Signal(u32)` — increments on each completion
//!
//! Components subscribe to these signals normally (no special async
//! machinery in the renderer). On Phase 3 the runtime is synchronous
//! — `dispatch(args)` runs `action.fn(args)` immediately and updates
//! the signals before returning. Phase 4's Suspense + streaming pipe
//! enables genuine asynchrony.

const std = @import("std");
const Owner = @import("owner.zig").Owner;
const Signal = @import("signal.zig").Signal;
const batch = @import("signal.zig").batch;

pub fn Action(comptime Args: type, comptime Result: type) type {
    return struct {
        pending: Signal(bool),
        value: Signal(?Result),
        input: Signal(?Args),
        version: Signal(u32),
        run_fn: *const fn (*anyopaque, Args) anyerror!Result,
        run_ctx: *anyopaque,
        owner: *Owner,

        const Self = @This();

        /// Invoke the wrapped operation. Updates pending/value/input/version
        /// signals in a single batch so subscribers see consistent state.
        pub fn dispatch(self: *Self, args: Args) anyerror!Result {
            const Ctx = struct {
                action: *Self,
                args: Args,
                fn run(c: *@This()) void {
                    c.action.input.set(c.args);
                    c.action.pending.set(true);
                }
            };
            var bctx: Ctx = .{ .action = self, .args = args };
            batch(&bctx, Ctx.run);

            const result = self.run_fn(self.run_ctx, args);

            const FinishCtx = struct {
                action: *Self,
                result: anyerror!Result,
                fn run(c: *@This()) void {
                    c.action.pending.set(false);
                    if (c.result) |v| {
                        c.action.value.set(v);
                    } else |_| {
                        c.action.value.set(null);
                    }
                    c.action.version.set(c.action.version.peek() +% 1);
                }
            };
            var fctx: FinishCtx = .{ .action = self, .result = result };
            batch(&fctx, FinishCtx.run);

            return result;
        }
    };
}

/// Construct an Action wrapping `f`. The owner anchors the signal
/// subscription lifetime; passing the wrong owner means stale
/// subscriptions on the action's signals will be carried until either
/// the owner disposes or the action is reused.
pub fn create(
    comptime Args: type,
    comptime Result: type,
    owner: *Owner,
    ctx_ptr: anytype,
    comptime f: fn (@TypeOf(ctx_ptr), Args) anyerror!Result,
) !*Action(Args, Result) {
    const CtxT = @TypeOf(ctx_ptr);
    const Wrap = struct {
        fn invoke(raw: *anyopaque, args: Args) anyerror!Result {
            const typed: CtxT = @ptrCast(@alignCast(raw));
            return f(typed, args);
        }
    };

    const action = try owner.allocator().create(Action(Args, Result));
    action.* = .{
        .pending = Signal(bool).init(false, owner.allocator()),
        .value = Signal(?Result).init(null, owner.allocator()),
        .input = Signal(?Args).init(null, owner.allocator()),
        .version = Signal(u32).init(0, owner.allocator()),
        .run_fn = Wrap.invoke,
        .run_ctx = @as(*anyopaque, @ptrCast(@constCast(ctx_ptr))),
        .owner = owner,
    };
    return action;
}

// ---- tests ------------------------------------------------------------

const testing = std.testing;
const effect_mod = @import("effect.zig");

test "Action.dispatch updates pending/value/version" {
    var owner = Owner.init(testing.allocator);
    effect_mod.setPendingAllocator(owner.allocator());
    defer owner.dispose();

    const Doubler = struct {
        fn run(_: *@This(), args: u32) anyerror!u32 {
            return args * 2;
        }
    };
    var d: Doubler = .{};
    const action = try create(u32, u32, &owner, &d, Doubler.run);

    try testing.expectEqual(@as(u32, 0), action.version.peek());
    try testing.expectEqual(false, action.pending.peek());

    const r = try action.dispatch(7);
    try testing.expectEqual(@as(u32, 14), r);
    try testing.expectEqual(@as(?u32, 14), action.value.peek());
    try testing.expectEqual(@as(?u32, 7), action.input.peek());
    try testing.expectEqual(@as(u32, 1), action.version.peek());
    try testing.expectEqual(false, action.pending.peek());
}

test "Action notifies subscribed effects" {
    var owner = Owner.init(testing.allocator);
    effect_mod.setPendingAllocator(owner.allocator());
    defer owner.dispose();

    const ArgsT = struct { a: i32, b: i32 };
    const Adder = struct {
        fn run(_: *@This(), args: ArgsT) anyerror!i32 {
            return args.a + args.b;
        }
    };
    var ad: Adder = .{};
    const action = try create(ArgsT, i32, &owner, &ad, Adder.run);

    const Watcher = struct {
        var hits: u32 = 0;
        var last_value: ?i32 = null;
        action: *Action(ArgsT, i32),
        fn run(self: *@This()) void {
            last_value = self.action.value.get();
            hits += 1;
        }
    };
    Watcher.hits = 0;
    Watcher.last_value = null;
    var w: Watcher = .{ .action = action };
    _ = try effect_mod.createEffect(&owner, &w, Watcher.run);

    try testing.expectEqual(@as(u32, 1), Watcher.hits);
    try testing.expectEqual(@as(?i32, null), Watcher.last_value);

    _ = try action.dispatch(.{ .a = 2, .b = 3 });
    try testing.expectEqual(@as(u32, 2), Watcher.hits);
    try testing.expectEqual(@as(?i32, 5), Watcher.last_value);
}
