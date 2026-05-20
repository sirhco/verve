//! `<Suspense>` boundary. Wraps a subtree that may read a not-yet-ready
//! `Resource`. Server-side flow:
//!
//!   - The child render is invoked under a thread-local "suspend" flag.
//!   - If any descendant calls `markSuspended()` (typically because a
//!     Resource is still `.loading`), the boundary discards the partial
//!     child output and emits the fallback HTML instead. Later phases
//!     register a continuation that emits a `<template>` chunk and a
//!     swap `<script>` once the resource resolves.
//!   - Otherwise the child is rendered inline as if `Suspense` weren't
//!     there.
//!
//! Phase 3's Resource is synchronous on the server, so today no
//! production render actually suspends — the boundary just emits child
//! HTML. The API matches the eventual Phase 8 behavior so user code
//! doesn't have to change.
//!
//! `Transition` is a thin alias of `Suspense` for now. Phase 4-client
//! work will differentiate them (Transition keeps old DOM live during
//! refetch; Suspense replaces with fallback).

const std = @import("std");
const Context = @import("context.zig").Context;
const Node = @import("node.zig").Node;
const create_node = @import("node.zig").create;

/// Thread-local flag set by Resource (and other suspendable primitives)
/// during render to signal the nearest enclosing `<Suspense>` boundary
/// that fallback HTML should be emitted instead of the child's partial
/// output.
pub threadlocal var suspended: bool = false;

/// Mark the current render as suspended. The next `<Suspense>` boundary
/// up the stack will emit its fallback. Components rarely call this
/// directly — it's invoked by primitives like `Resource.get` when they
/// detect `.loading` state.
pub fn markSuspended() void {
    suspended = true;
}

pub const SuspenseOpts = struct {
    fallback: *Node,
    /// Optional id used to name the boundary in the streaming wire
    /// format. Phase 4-future: the server emits `<div data-vs="{id}">`
    /// for the fallback and ships a `<template id="verve-s-{id}">`
    /// chunk later with the real content.
    id: ?[]const u8 = null,
};

/// Build a Suspense boundary. The child closure is invoked once during
/// render; if it (or any nested component) marks the render suspended,
/// `fallback` is emitted instead.
pub fn suspense(
    ctx: *const Context,
    opts: SuspenseOpts,
    ctx_ptr: anytype,
    comptime render_child: fn (@TypeOf(ctx_ptr)) anyerror!*Node,
) !*Node {
    _ = ctx;
    const prev = suspended;
    suspended = false;
    defer suspended = prev;

    const child = render_child(ctx_ptr) catch {
        // Render error short-circuits to the fallback the same way an
        // error boundary would. Phase 4-future: distinguish "suspend"
        // from "fail" via a richer state.
        return opts.fallback;
    };

    if (suspended) {
        // Phase 4-future: emit `<div data-vs="{id}">{fallback}</div>` and
        // register a continuation. For now we just return the fallback
        // directly since no Resource is genuinely async.
        return opts.fallback;
    }

    return child;
}

/// `<Transition>` — same shape as `<Suspense>` on the server. Client-
/// side semantics differ (Transition keeps the previous DOM while
/// `pending` flips true) but those live in the WASM runtime.
pub fn transition(
    ctx: *const Context,
    opts: SuspenseOpts,
    ctx_ptr: anytype,
    comptime render_child: fn (@TypeOf(ctx_ptr)) anyerror!*Node,
) !*Node {
    return suspense(ctx, opts, ctx_ptr, render_child);
}

// ---- tests ------------------------------------------------------------

const testing = std.testing;

test "suspense emits child when no suspend flag set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const Inner = struct {
        fn render(c: *const Context) anyerror!*Node {
            return c.div().class("real-content").build();
        }
    };

    const fallback = ctx.div().class("fallback");
    const result = try suspense(&ctx, .{ .fallback = fallback }, &ctx, Inner.render);
    try testing.expectEqualStrings("real-content", result.attrs.items[0].value);
}

test "suspense falls back when markSuspended called" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const Inner = struct {
        fn render(c: *const Context) anyerror!*Node {
            markSuspended();
            return c.div().class("real-content").build();
        }
    };

    const fallback = ctx.div().class("fallback");
    const result = try suspense(&ctx, .{ .fallback = fallback }, &ctx, Inner.render);
    try testing.expectEqualStrings("fallback", result.attrs.items[0].value);
}

test "suspense fallback survives child render error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const Inner = struct {
        fn render(_: *const Context) anyerror!*Node {
            return error.SimulatedFailure;
        }
    };

    const fallback = ctx.div().class("err-fallback");
    const result = try suspense(&ctx, .{ .fallback = fallback }, &ctx, Inner.render);
    try testing.expectEqualStrings("err-fallback", result.attrs.items[0].value);
}
