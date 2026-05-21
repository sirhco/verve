//! Phase 12 — client-side reactive runtime.
//!
//! Hosts the same `Signal`/`Effect`/`Owner` graph from `src/core/` inside
//! the wasm32-freestanding client. Server-rendered nodes carry their
//! `bind()` name on a `data-vh` attribute (stamped by the renderer);
//! the runtime walks that registry, allocates one Signal per bind, and
//! wires its `on_set` hook to a DOM update extern. After hydration the
//! WASM module owns the reactive graph end-to-end — DOM mutations are
//! a consequence of `Signal.set`, not a parallel write path.
//!
//! The pre-Phase-12 `ClientSignal(T)` wrapper survives as the legacy
//! single-binding shortcut. New code should reach for `registerI32`
//! (and friends, as they land) so it picks up effect tracking, batch,
//! owner lifetimes, and the future reconciler for keyed lists.

const std = @import("std");
const verve = @import("verve");
const dom = @import("dom.zig");
const reconciler = @import("reconciler.zig");
const client_alloc = @import("allocator.zig");

const MAX_SLOTS = 64;

const Slot = struct {
    name: []const u8,
    sig_ptr: *anyopaque,
    type_tag: TypeTag,
};

const TypeTag = enum { i32, str };

const BindBoxI32 = struct {
    name: []const u8,
};

const BindBoxStr = struct {
    name: []const u8,
};

var slots: [MAX_SLOTS]Slot = undefined;
var slot_count: usize = 0;
var root_owner: ?*verve.Owner = null;

/// Lazily build a root Owner backed by the client's bump allocator and
/// hook it up as the pending-effects sink. Subsequent calls return the
/// same Owner.
pub fn ensureOwner() *verve.Owner {
    if (root_owner) |o| return o;
    const gpa = client_alloc.allocator();
    verve.setReactivePendingAllocator(gpa);
    const owner = gpa.create(verve.Owner) catch @panic("verve client: OOM allocating root Owner");
    owner.* = verve.Owner.init(gpa);
    root_owner = owner;
    return owner;
}

/// Register a reactive `i32` keyed by its DOM bind-name. Allocates a
/// `verve.Signal(i32)` under the root Owner and wires its `on_set` hook
/// to push the new value into every `[data-vh="<name>"]` (and the
/// legacy `[z-bind="<name>"]`) element via the JS bridge.
pub fn registerI32(name: []const u8, initial: i32) *verve.Signal(i32) {
    if (slot_count >= MAX_SLOTS) @panic("verve client: signal slot capacity exceeded");
    const owner = ensureOwner();
    const gpa = owner.allocator();

    const sig = gpa.create(verve.Signal(i32)) catch @panic("verve client: OOM allocating Signal");
    sig.* = verve.Signal(i32).init(initial, gpa);

    const box = gpa.create(BindBoxI32) catch @panic("verve client: OOM allocating bind box");
    box.* = .{ .name = name };
    sig.on_set = onSetI32;
    sig.on_set_ctx = box;

    slots[slot_count] = .{ .name = name, .sig_ptr = sig, .type_tag = .i32 };
    slot_count += 1;

    return sig;
}

/// Look up a previously registered i32 signal by its bind-name. Returns
/// null when no slot matches.
pub fn signalI32(name: []const u8) ?*verve.Signal(i32) {
    for (slots[0..slot_count]) |s| {
        if (s.type_tag != .i32) continue;
        if (std.mem.eql(u8, s.name, name)) {
            return @ptrCast(@alignCast(s.sig_ptr));
        }
    }
    return null;
}

fn onSetI32(ctx: *anyopaque, value: i32) void {
    const box: *BindBoxI32 = @ptrCast(@alignCast(ctx));
    dom.set_text_by_bind_i32(box.name.ptr, box.name.len, value);
}

/// Register a reactive string keyed by its bind-name. Allocates a
/// `verve.Signal([]const u8)` under the root Owner and wires on_set
/// to push the new text into every `[data-vh="<name>"]` element via
/// the bridge's `set_text_by_bind_str` primitive.
pub fn registerStr(name: []const u8, initial: []const u8) *verve.Signal([]const u8) {
    if (slot_count >= MAX_SLOTS) @panic("verve client: signal slot capacity exceeded");
    const owner = ensureOwner();
    const gpa = owner.allocator();

    const sig = gpa.create(verve.Signal([]const u8)) catch @panic("verve client: OOM allocating Signal");
    sig.* = verve.Signal([]const u8).init(initial, gpa);

    const box = gpa.create(BindBoxStr) catch @panic("verve client: OOM allocating bind box");
    box.* = .{ .name = name };
    sig.on_set = onSetStr;
    sig.on_set_ctx = box;

    slots[slot_count] = .{ .name = name, .sig_ptr = sig, .type_tag = .str };
    slot_count += 1;

    return sig;
}

pub fn signalStr(name: []const u8) ?*verve.Signal([]const u8) {
    for (slots[0..slot_count]) |s| {
        if (s.type_tag != .str) continue;
        if (std.mem.eql(u8, s.name, name)) {
            return @ptrCast(@alignCast(s.sig_ptr));
        }
    }
    return null;
}

fn onSetStr(ctx: *anyopaque, value: []const u8) void {
    const box: *BindBoxStr = @ptrCast(@alignCast(ctx));
    dom.set_text_by_bind_str(box.name.ptr, box.name.len, value.ptr, value.len);
}

// ---- testing ---------------------------------------------------------------

const testing = std.testing;

test "registerI32 allocates a Signal under the root owner" {
    // Tests run on the native target, so the bump allocator falls back
    // to its static buffer. Reset between tests to keep slots fresh.
    resetForTesting();

    const sig = registerI32("count", 7);
    try testing.expectEqual(@as(i32, 7), sig.peek());

    // Look-up by name returns the same pointer.
    const looked = signalI32("count");
    try testing.expectEqual(sig, looked.?);

    // on_set is wired (calls into the DOM stub on native — see
    // `dom.zig`'s native fallback; we only verify the hook is non-null).
    try testing.expect(sig.on_set != null);
}

test "registerI32 distinct names share the owner allocator" {
    resetForTesting();

    const a = registerI32("a", 1);
    const b = registerI32("b", 2);

    try testing.expectEqual(@as(i32, 1), a.peek());
    try testing.expectEqual(@as(i32, 2), b.peek());
    try testing.expect(a != b);
}

test "applyReconcile runs against native dom stubs without crashing" {
    resetForTesting();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const old_keys = [_][]const u8{ "a", "b", "c" };
    const new_keys = [_][]const u8{ "c", "a", "d" };
    const new_html = [_][]const u8{ "<li data-vkey=\"c\">C</li>", "<li data-vkey=\"a\">A</li>", "<li data-vkey=\"d\">D</li>" };

    // Native dom stubs are no-ops; this exercises the planner +
    // dispatch glue end-to-end without a real DOM.
    try applyReconcile(arena.allocator(), "items", &old_keys, &new_keys, &new_html);
}

test "registerStr allocates a string Signal" {
    resetForTesting();

    const sig = registerStr("title", "hello");
    try testing.expectEqualStrings("hello", sig.peek());
    try testing.expectEqual(sig, signalStr("title").?);
    try testing.expect(sig.on_set != null);

    // i32 and str slots coexist by tag.
    const counter = registerI32("count", 0);
    try testing.expectEqual(counter, signalI32("count").?);
    try testing.expect(signalStr("count") == null);
    try testing.expect(signalI32("title") == null);
}

/// Reconcile a keyed parent against a new key/html pairing. Calls
/// `reconciler.plan` to compute the minimum (insert | move | remove)
/// op sequence then dispatches each op through the matching DOM
/// primitive. `new_html` is parallel to `new_keys` — entry `i` is the
/// child markup for `new_keys[i]`. Existing children keep their DOM
/// nodes intact across moves so reactive state on their descendants
/// survives.
pub fn applyReconcile(
    arena: std.mem.Allocator,
    parent_bind: []const u8,
    old_keys: []const []const u8,
    new_keys: []const []const u8,
    new_html: []const []const u8,
) !void {
    std.debug.assert(new_keys.len == new_html.len);
    const ops = try reconciler.plan(arena, old_keys, new_keys);
    for (ops) |op| switch (op.kind) {
        .insert => {
            const html = htmlForKey(new_keys, new_html, op.key);
            const anchor = op.anchor orelse "";
            dom.create_keyed_child(
                parent_bind.ptr,
                parent_bind.len,
                op.key.ptr,
                op.key.len,
                html.ptr,
                html.len,
                anchor.ptr,
                anchor.len,
            );
        },
        .move => {
            const anchor = op.anchor orelse "";
            dom.move_keyed_child(
                parent_bind.ptr,
                parent_bind.len,
                op.key.ptr,
                op.key.len,
                anchor.ptr,
                anchor.len,
            );
        },
        .remove => {
            dom.remove_keyed_child(
                parent_bind.ptr,
                parent_bind.len,
                op.key.ptr,
                op.key.len,
            );
        },
    };
}

fn htmlForKey(
    keys: []const []const u8,
    htmls: []const []const u8,
    target: []const u8,
) []const u8 {
    for (keys, htmls) |k, h| {
        if (std.mem.eql(u8, k, target)) return h;
    }
    return "";
}

/// Wipe runtime state. ONLY for use from unit tests on the native build.
pub fn resetForTesting() void {
    if (root_owner) |o| {
        o.dispose();
        root_owner = null;
    }
    slot_count = 0;
    client_alloc.reset();
}
