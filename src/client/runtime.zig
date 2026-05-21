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
const client_alloc = @import("allocator.zig");

const MAX_SLOTS = 64;

const Slot = struct {
    name: []const u8,
    sig_ptr: *anyopaque,
    type_tag: TypeTag,
};

const TypeTag = enum { i32 };

const BindBoxI32 = struct {
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

/// Wipe runtime state. ONLY for use from unit tests on the native build.
pub fn resetForTesting() void {
    if (root_owner) |o| {
        o.dispose();
        root_owner = null;
    }
    slot_count = 0;
    client_alloc.reset();
}
