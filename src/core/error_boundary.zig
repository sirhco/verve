//! Reactive ErrorBoundary. Holds a `Signal(?anyerror)` so a component
//! subtree can sequester failures without bubbling them past the
//! boundary: a child catches the error, stores it on the boundary,
//! and renders a fallback; sibling subtrees keep working. A
//! `boundary.reset()` clears the captured error — the user can wire
//! that to a "Try again" button.
//!
//! Phase 0's `ctx.errorBoundary(inner, fallback)` helper remains the
//! shorthand for build-time errors caught via `inner.err`. This module
//! provides the long-form reactive variant that observers can read.

const std = @import("std");
const Owner = @import("owner.zig").Owner;
const Signal = @import("signal.zig").Signal;

pub const ErrorBoundary = struct {
    error_signal: Signal(?anyerror),

    const Self = @This();

    /// Capture an error onto the boundary. Reactive consumers see the
    /// new state and can render a fallback.
    pub fn captureError(self: *Self, err: anyerror) void {
        self.error_signal.set(err);
    }

    /// Reactive read — subscribes the active effect. Returns null
    /// when the boundary hasn't captured anything (or after reset).
    pub fn captured(self: *Self) ?anyerror {
        return self.error_signal.get();
    }

    /// Non-tracking read.
    pub fn peek(self: *const Self) ?anyerror {
        return self.error_signal.peek();
    }

    /// Clear the captured error. Components that observe `captured()`
    /// re-run, presumably showing the recovered subtree.
    pub fn reset(self: *Self) void {
        self.error_signal.set(null);
    }
};

/// Allocate a fresh ErrorBoundary under `owner`. Cleanup is handled
/// automatically when the owner disposes.
pub fn create(owner: *Owner) !*ErrorBoundary {
    const eb = try owner.allocator().create(ErrorBoundary);
    eb.* = .{
        .error_signal = Signal(?anyerror).init(null, owner.allocator()),
    };
    return eb;
}

// ---- tests ------------------------------------------------------------

const testing = std.testing;
const effect_mod = @import("effect.zig");

test "ErrorBoundary captures + resets" {
    var owner = Owner.init(testing.allocator);
    effect_mod.setPendingAllocator(owner.allocator());
    defer owner.dispose();

    const eb = try create(&owner);
    try testing.expect(eb.peek() == null);

    eb.captureError(error.SimulatedFailure);
    try testing.expectEqual(@as(?anyerror, error.SimulatedFailure), eb.peek());

    eb.reset();
    try testing.expect(eb.peek() == null);
}

test "ErrorBoundary fires effect on capture and reset" {
    var owner = Owner.init(testing.allocator);
    effect_mod.setPendingAllocator(owner.allocator());
    defer owner.dispose();

    const eb = try create(&owner);

    const Watcher = struct {
        var hits: u32 = 0;
        var last: ?anyerror = null;
        eb: *ErrorBoundary,
        fn run(self: *@This()) void {
            last = self.eb.captured();
            hits += 1;
        }
    };
    Watcher.hits = 0;
    Watcher.last = null;
    var w: Watcher = .{ .eb = eb };
    _ = try effect_mod.createEffect(&owner, &w, Watcher.run);
    try testing.expectEqual(@as(u32, 1), Watcher.hits);

    eb.captureError(error.A);
    try testing.expectEqual(@as(u32, 2), Watcher.hits);
    try testing.expectEqual(@as(?anyerror, error.A), Watcher.last);

    eb.reset();
    try testing.expectEqual(@as(u32, 3), Watcher.hits);
    try testing.expect(Watcher.last == null);
}
