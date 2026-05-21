//! Phase 14 — out-of-order Suspense streaming (groundwork).
//!
//! Tracks the Suspense boundaries a render is currently waiting on so
//! the server can emit a `<div data-vs="N">{fallback}</div>` placeholder
//! in the shell and stream `<template id="verve-vs-N">{real}</template>`
//! + `<script>verveSwap(N)</script>` chunks once the upstream resolves.
//!
//! Scope of this commit is the data structure and registration API —
//! the actual `streamRender` writer-side variant and the chunked HTTP
//! response path land alongside the async `ctx.fetch` rewrite (deferred
//! until Zig 0.16's std.Io.async story is more settled). With the
//! current synchronous Resource, no boundary genuinely suspends past
//! the first render pass, so today the registry stays empty in
//! production renders. The API matches what the async path will need
//! so user code doesn't have to change again.

const std = @import("std");
const Node = @import("node.zig").Node;

/// Thread-local pointer to the active stream registry, or null when
/// the render is going through the legacy single-shot path. Set by
/// `Renderer.streamRender` for the lifetime of a chunked response.
pub threadlocal var current: ?*Registry = null;

/// One parked boundary. `id` matches the `data-vs` attribute on the
/// fallback placeholder; `render_real` is invoked by the drain pump
/// after the boundary's upstream finishes.
pub const Slot = struct {
    id: u32,
    render_real: *const fn (*anyopaque) anyerror!*Node,
    ctx: *anyopaque,
};

pub const Registry = struct {
    next_id: u32 = 0,
    slots: std.ArrayListUnmanaged(Slot) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        self.slots.deinit(self.allocator);
    }

    /// Reserve a new `data-vs` id and stash the continuation. Returns
    /// the id the caller stamps on the placeholder div.
    pub fn registerSuspended(
        self: *Registry,
        ctx_ptr: anytype,
        comptime render_real: fn (@TypeOf(ctx_ptr)) anyerror!*Node,
    ) !u32 {
        const CtxT = @TypeOf(ctx_ptr);
        comptime std.debug.assert(@typeInfo(CtxT) == .pointer);

        const Adapter = struct {
            fn invoke(opaque_ctx: *anyopaque) anyerror!*Node {
                const typed: CtxT = @ptrCast(@alignCast(opaque_ctx));
                return render_real(typed);
            }
        };

        const id = self.next_id;
        self.next_id += 1;
        try self.slots.append(self.allocator, .{
            .id = id,
            .render_real = Adapter.invoke,
            .ctx = @ptrCast(@constCast(ctx_ptr)),
        });
        return id;
    }

    /// Drain helper for the chunked-response loop. Yields slots in
    /// registration order so chunks ship as soon as their boundary's
    /// upstream is ready — the order on the wire is intentionally
    /// independent of where the boundary lives in the document.
    pub fn pending(self: *const Registry) []const Slot {
        return self.slots.items;
    }
};

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

test "register assigns sequential ids and exposes the slot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reg = Registry.init(arena.allocator());
    defer reg.deinit();

    var ctx_val: u32 = 42;

    const Real = struct {
        fn run(p: *u32) anyerror!*Node {
            _ = p;
            return error.NotImplemented;
        }
    };

    const id_a = try reg.registerSuspended(&ctx_val, Real.run);
    const id_b = try reg.registerSuspended(&ctx_val, Real.run);
    try testing.expectEqual(@as(u32, 0), id_a);
    try testing.expectEqual(@as(u32, 1), id_b);
    try testing.expectEqual(@as(usize, 2), reg.pending().len);
}

test "registered continuation invokes its callback" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reg = Registry.init(arena.allocator());
    defer reg.deinit();

    const Counter = struct {
        var hits: u32 = 0;
        fn run(c: *@This()) anyerror!*Node {
            _ = c;
            hits += 1;
            return error.IntentionalStop;
        }
    };
    Counter.hits = 0;

    var ctx_val: Counter = .{};
    _ = try reg.registerSuspended(&ctx_val, Counter.run);
    const slot = reg.pending()[0];
    try testing.expectError(error.IntentionalStop, slot.render_real(slot.ctx));
    try testing.expectEqual(@as(u32, 1), Counter.hits);
}
