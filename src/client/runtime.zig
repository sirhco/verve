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
const scratch = @import("scratch.zig");

const MAX_SLOTS = 256;

const Slot = struct {
    name: []const u8,
    sig_ptr: *anyopaque,
    type_tag: TypeTag,
};

pub const TypeTag = enum { i32, str, bool, f32 };

const BindBoxI32 = struct {
    name: []const u8,
};

const BindBoxStr = struct {
    name: []const u8,
};

const BindBoxBool = struct {
    name: []const u8,
    class_name: []const u8,
};

const BindBoxF32 = struct {
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
///
/// Idempotent on the name: a second call with the same name returns
/// the existing slot's pointer and discards the new initial. Lets
/// multi-instance islands and hot-reloaded chunks call `register*`
/// without piling up duplicate slots. Callers that need a fresh slot
/// per instance must namespace the name themselves (e.g. encode the
/// `root_id` the chunk's `hydrate` receives into the bind-name).
pub fn registerI32(name: []const u8, initial: i32) *verve.Signal(i32) {
    if (signalI32(name)) |existing| return existing;
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
/// the bridge's `set_text_by_bind_str` primitive. Idempotent on the
/// name — see `registerI32` for the contract.
pub fn registerStr(name: []const u8, initial: []const u8) *verve.Signal([]const u8) {
    if (signalStr(name)) |existing| return existing;
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

/// Register a reactive bool that drives a single CSS class on every
/// `[data-vh="<name>"]` element. The class is added when the Signal
/// holds `true`, removed when false — the common idiom for `.active`
/// / `.is-open` toggles without re-render. Idempotent on the name —
/// see `registerI32` for the contract.
pub fn registerBool(name: []const u8, class_name: []const u8, initial: bool) *verve.Signal(bool) {
    if (signalBool(name)) |existing| return existing;
    if (slot_count >= MAX_SLOTS) @panic("verve client: signal slot capacity exceeded");
    const owner = ensureOwner();
    const gpa = owner.allocator();

    const sig = gpa.create(verve.Signal(bool)) catch @panic("verve client: OOM allocating Signal");
    sig.* = verve.Signal(bool).init(initial, gpa);

    const box = gpa.create(BindBoxBool) catch @panic("verve client: OOM allocating bind box");
    box.* = .{ .name = name, .class_name = class_name };
    sig.on_set = onSetBool;
    sig.on_set_ctx = box;

    slots[slot_count] = .{ .name = name, .sig_ptr = sig, .type_tag = .bool };
    slot_count += 1;

    return sig;
}

pub fn signalBool(name: []const u8) ?*verve.Signal(bool) {
    for (slots[0..slot_count]) |s| {
        if (s.type_tag != .bool) continue;
        if (std.mem.eql(u8, s.name, name)) {
            return @ptrCast(@alignCast(s.sig_ptr));
        }
    }
    return null;
}

fn onSetBool(ctx: *anyopaque, value: bool) void {
    const box: *BindBoxBool = @ptrCast(@alignCast(ctx));
    dom.set_class_present_by_bind(
        box.name.ptr,
        box.name.len,
        box.class_name.ptr,
        box.class_name.len,
        if (value) 1 else 0,
    );
}

/// Register a reactive f32 keyed by its bind-name. on_set pushes the
/// new float into every `[data-vh="<name>"]` element via the bridge's
/// `set_text_by_bind_f32` primitive (JS formats with its default
/// stringification). Idempotent on the name — see `registerI32` for
/// the contract.
pub fn registerF32(name: []const u8, initial: f32) *verve.Signal(f32) {
    if (signalF32(name)) |existing| return existing;
    if (slot_count >= MAX_SLOTS) @panic("verve client: signal slot capacity exceeded");
    const owner = ensureOwner();
    const gpa = owner.allocator();

    const sig = gpa.create(verve.Signal(f32)) catch @panic("verve client: OOM allocating Signal");
    sig.* = verve.Signal(f32).init(initial, gpa);

    const box = gpa.create(BindBoxF32) catch @panic("verve client: OOM allocating bind box");
    box.* = .{ .name = name };
    sig.on_set = onSetF32;
    sig.on_set_ctx = box;

    slots[slot_count] = .{ .name = name, .sig_ptr = sig, .type_tag = .f32 };
    slot_count += 1;

    return sig;
}

pub fn signalF32(name: []const u8) ?*verve.Signal(f32) {
    for (slots[0..slot_count]) |s| {
        if (s.type_tag != .f32) continue;
        if (std.mem.eql(u8, s.name, name)) {
            return @ptrCast(@alignCast(s.sig_ptr));
        }
    }
    return null;
}

fn onSetF32(ctx: *anyopaque, value: f32) void {
    const box: *BindBoxF32 = @ptrCast(@alignCast(ctx));
    dom.set_text_by_bind_f32(box.name.ptr, box.name.len, value);
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

test "ForEachHandle.update advances the cached key list" {
    resetForTesting();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const initial = [_][]const u8{ "a", "b", "c" };
    const handle = try registerForEach("items", &initial);

    try testing.expectEqual(@as(usize, 3), handle.current_keys.len);
    try testing.expectEqualStrings("a", handle.current_keys[0]);

    const next = [_][]const u8{ "c", "a", "d" };
    const next_html = [_][]const u8{ "<li data-vkey=\"c\">C</li>", "<li data-vkey=\"a\">A</li>", "<li data-vkey=\"d\">D</li>" };
    try handle.update(arena.allocator(), &next, &next_html);

    try testing.expectEqual(@as(usize, 3), handle.current_keys.len);
    try testing.expectEqualStrings("c", handle.current_keys[0]);
    try testing.expectEqualStrings("a", handle.current_keys[1]);
    try testing.expectEqualStrings("d", handle.current_keys[2]);
}

test "bindForEach scratch stays bounded across many re-runs" {
    resetForTesting();

    const initial = [_][]const u8{};
    const handle = try registerForEach("items", &initial);
    const sig = registerI32("n", 0);

    const State = struct {
        s: *verve.Signal(i32),
        fn render(self: *@This(), alloc: std.mem.Allocator) anyerror!ForEachData {
            const n: usize = @intCast(self.s.get());
            const ks = try alloc.alloc([]const u8, n);
            const hs = try alloc.alloc([]const u8, n);
            for (0..n) |i| {
                ks[i] = try std.fmt.allocPrint(alloc, "row{d}", .{i});
                hs[i] = try std.fmt.allocPrint(alloc, "<li>{d}</li>", .{i});
            }
            return .{ .keys = ks, .html = hs };
        }
    };
    var state: State = .{ .s = sig };
    _ = try bindForEach(handle, &state, State.render);

    scratch.reset();
    // Same workload size across many re-runs — scratch usage after
    // each tick stays under a small constant (function of the list
    // size, not the iteration count).
    var i: i32 = 0;
    var peak: usize = 0;
    while (i < 64) : (i += 1) {
        sig.set(8);
        sig.set(0);
        peak = @max(peak, scratch.bytesUsed());
    }
    // A few hundred bytes per list-of-8 frame is the rough order. Cap
    // generously to absorb compiler/layout variance — the load-bearing
    // assertion is that the value doesn't scale with iteration count.
    try testing.expect(peak < 8 * 1024);
}

test "bindForEach re-runs handle.update when a tracked signal changes" {
    resetForTesting();

    const initial = [_][]const u8{ "a", "b" };
    const handle = try registerForEach("items", &initial);

    // Tracked signal: number of items to render. Render fn produces
    // keys "k0".."k(n-1)" each tick.
    const sig = registerI32("len", 2);

    const State = struct {
        s: *verve.Signal(i32),
        var render_hits: u32 = 0;
        fn render(self: *@This(), alloc: std.mem.Allocator) anyerror!ForEachData {
            const n: usize = @intCast(self.s.get());
            const ks = try alloc.alloc([]const u8, n);
            const hs = try alloc.alloc([]const u8, n);
            for (0..n) |i| {
                ks[i] = try std.fmt.allocPrint(alloc, "k{d}", .{i});
                hs[i] = try std.fmt.allocPrint(alloc, "<li>i{d}</li>", .{i});
            }
            render_hits += 1;
            return .{ .keys = ks, .html = hs };
        }
    };
    State.render_hits = 0;
    var state: State = .{ .s = sig };

    _ = try bindForEach(handle, &state, State.render);

    // First eager run set the cache to ["k0","k1"].
    try testing.expectEqual(@as(u32, 1), State.render_hits);
    try testing.expectEqual(@as(usize, 2), handle.current_keys.len);
    try testing.expectEqualStrings("k0", handle.current_keys[0]);
    try testing.expectEqualStrings("k1", handle.current_keys[1]);

    // Bump the signal → effect re-runs → cache extends to k0..k3.
    sig.set(4);
    try testing.expectEqual(@as(u32, 2), State.render_hits);
    try testing.expectEqual(@as(usize, 4), handle.current_keys.len);
    try testing.expectEqualStrings("k3", handle.current_keys[3]);

    // Shrink back → cache shrinks.
    sig.set(1);
    try testing.expectEqual(@as(u32, 3), State.render_hits);
    try testing.expectEqual(@as(usize, 1), handle.current_keys.len);
    try testing.expectEqualStrings("k0", handle.current_keys[0]);
}

test "ForEachHandle survives multiple updates including empty list" {
    resetForTesting();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const initial = [_][]const u8{"only"};
    const handle = try registerForEach("items", &initial);

    // Remove everything.
    try handle.update(arena.allocator(), &.{}, &.{});
    try testing.expectEqual(@as(usize, 0), handle.current_keys.len);

    // Add two fresh items.
    const after = [_][]const u8{ "x", "y" };
    const after_html = [_][]const u8{ "<li>x</li>", "<li>y</li>" };
    try handle.update(arena.allocator(), &after, &after_html);
    try testing.expectEqual(@as(usize, 2), handle.current_keys.len);
    try testing.expectEqualStrings("x", handle.current_keys[0]);
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

test "registerBool toggles its CSS class via the on_set hook" {
    resetForTesting();

    const sig = registerBool("panel", "open", false);
    try testing.expect(!sig.peek());
    try testing.expectEqual(sig, signalBool("panel").?);
    try testing.expect(sig.on_set != null);

    // signalI32 / signalStr / signalF32 don't see the bool slot.
    try testing.expect(signalI32("panel") == null);
    try testing.expect(signalStr("panel") == null);
    try testing.expect(signalF32("panel") == null);

    // set fires on_set (no-op on native, just exercise the path).
    sig.set(true);
    try testing.expect(sig.peek());
}

test "registerF32 stores and updates a float Signal" {
    resetForTesting();

    const sig = registerF32("ratio", 0.25);
    try testing.expectApproxEqAbs(@as(f32, 0.25), sig.peek(), 1e-6);
    try testing.expectEqual(sig, signalF32("ratio").?);

    sig.set(0.875);
    try testing.expectApproxEqAbs(@as(f32, 0.875), sig.peek(), 1e-6);
}

test "registerResponseHandler + dispatchResponse fan replies by route" {
    resetForTesting();

    const State = struct {
        var ping_hits: u32 = 0;
        var ping_last_len: u32 = 0;
        var other_hits: u32 = 0;
        fn ping(_: [*]const u8, len: u32) void {
            ping_hits += 1;
            ping_last_len = len;
        }
        fn other(_: [*]const u8, _: u32) void {
            other_hits += 1;
        }
    };
    State.ping_hits = 0;
    State.ping_last_len = 0;
    State.other_hits = 0;

    registerResponseHandler("ping", State.ping);
    registerResponseHandler("other", State.other);
    try testing.expectEqual(@as(u32, 2), responseSlotCount());

    const body = "{\"ok\":true}";
    dispatchResponse("ping", body);
    try testing.expectEqual(@as(u32, 1), State.ping_hits);
    try testing.expectEqual(@as(u32, body.len), State.ping_last_len);
    try testing.expectEqual(@as(u32, 0), State.other_hits);

    // Unknown route drops silently.
    dispatchResponse("never_registered", "");
    try testing.expectEqual(@as(u32, 1), State.ping_hits);

    // Multiple handlers per route fan out in registration order.
    registerResponseHandler("ping", State.other);
    dispatchResponse("ping", body);
    try testing.expectEqual(@as(u32, 2), State.ping_hits);
    try testing.expectEqual(@as(u32, 1), State.other_hits);
}

test "cleanup runs registered handlers on owner dispose" {
    resetForTesting();

    const State = struct {
        var ran_a: u32 = 0;
        var ran_b: u32 = 0;
        fn a() void { ran_a += 1; }
        fn b() void { ran_b += 1; }
    };
    State.ran_a = 0;
    State.ran_b = 0;

    try cleanup(State.a);
    try cleanup(State.b);

    try testing.expectEqual(@as(u32, 0), State.ran_a);
    try testing.expectEqual(@as(u32, 0), State.ran_b);

    // resetForTesting disposes the root owner — handlers fire LIFO.
    resetForTesting();
    try testing.expectEqual(@as(u32, 1), State.ran_a);
    try testing.expectEqual(@as(u32, 1), State.ran_b);
}

test "slot introspection helpers track register* calls" {
    resetForTesting();

    try testing.expectEqual(@as(u32, 0), slotCount());
    try testing.expectEqual(@as(u32, 0), eventSlotCount());
    try testing.expect(slotCapacity() >= 256);
    try testing.expect(eventSlotCapacity() >= 1024);

    _ = registerI32("alpha", 1);
    _ = registerStr("beta", "x");
    _ = registerBool("gamma", "on", false);
    try testing.expectEqual(@as(u32, 3), slotCount());

    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("alpha", slotName(0, &buf));
    try testing.expectEqualStrings("beta", slotName(1, &buf));
    try testing.expectEqualStrings("gamma", slotName(2, &buf));
    try testing.expectEqualStrings("", slotName(99, &buf));

    try testing.expectEqual(TypeTag.i32, slotKind(0).?);
    try testing.expectEqual(TypeTag.str, slotKind(1).?);
    try testing.expectEqual(TypeTag.bool, slotKind(2).?);
    try testing.expectEqual(@as(?TypeTag, null), slotKind(99));
}

test "registerI32 is idempotent on the name" {
    resetForTesting();

    const first = registerI32("dup", 7);
    try testing.expectEqual(@as(i32, 7), first.peek());

    // Second call returns the existing slot pointer — initial value 99
    // is discarded, the live value stays at 7.
    const second = registerI32("dup", 99);
    try testing.expectEqual(first, second);
    try testing.expectEqual(@as(i32, 7), second.peek());

    // Mutate via either pointer — both observe the new value.
    first.set(42);
    try testing.expectEqual(@as(i32, 42), second.peek());
}

test "registerEvent + dispatchEvent invoke the matching slot" {
    resetForTesting();

    const State = struct {
        var hits_a: u32 = 0;
        var hits_b: u32 = 0;
        fn a() void { hits_a += 1; }
        fn b() void { hits_b += 1; }
    };
    State.hits_a = 0;
    State.hits_b = 0;

    const id_a = registerEvent(State.a);
    const id_b = registerEvent(State.b);

    try testing.expectEqual(@as(u32, 0), id_a);
    try testing.expectEqual(@as(u32, 1), id_b);

    dispatchEvent(id_a);
    dispatchEvent(id_a);
    dispatchEvent(id_b);
    try testing.expectEqual(@as(u32, 2), State.hits_a);
    try testing.expectEqual(@as(u32, 1), State.hits_b);

    // Out-of-range id is a no-op — keeps the bridge resilient to a
    // stale click against a hot-swapped wasm build.
    dispatchEvent(999);
    try testing.expectEqual(@as(u32, 2), State.hits_a);
    try testing.expectEqual(@as(u32, 1), State.hits_b);
}

test "autoHydrate registers mixed-type bindings under the root owner" {
    resetForTesting();

    autoHydrate(&.{
        .{ .name = "score", .initial = .{ .i32 = 42 } },
        .{ .name = "label", .initial = .{ .str = "hello" } },
        .{ .name = "open", .initial = .{ .bool = .{ .class = "is-open", .value = true } } },
        .{ .name = "ratio", .initial = .{ .f32 = 0.5 } },
    });

    try testing.expectEqual(@as(i32, 42), signalI32("score").?.peek());
    try testing.expectEqualStrings("hello", signalStr("label").?.peek());
    try testing.expect(signalBool("open").?.peek());
    try testing.expectApproxEqAbs(@as(f32, 0.5), signalF32("ratio").?.peek(), 1e-6);

    // type-tag separation: looking up a name under the wrong type returns null
    try testing.expect(signalI32("label") == null);
    try testing.expect(signalStr("score") == null);
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

// ---- Closure-style event dispatch ----------------------------------------
//
// Apps register a `*const fn () void` handler against the runtime and
// receive a `u32` id. The renderer stamps `z-on-click-id="<id>"` onto
// the matching node; the bridge JS click delegate calls
// `verve_event_dispatch(id)` which invokes the registered fn pointer.
//
// Modeled on the island chunk dispatch pattern at `src/client/island.zig`
// — a flat slot table with sequential ids, no allocation per registration,
// 256 entries enough for typical apps (one slot per visually-distinct
// handler, not per render).

const MAX_EVENT_SLOTS: u32 = 1024;

var event_slots: [MAX_EVENT_SLOTS]?*const fn () void = [_]?*const fn () void{null} ** MAX_EVENT_SLOTS;
var event_slot_count: u32 = 0;

/// Register a closure-style click handler. Returns the slot id the
/// renderer should stamp on the node via `Node.onClickFn(id)`. Panics
/// when capacity is exhausted — the cap is enforced because the slot
/// table is statically sized; raise `MAX_EVENT_SLOTS` if a real app
/// needs more.
pub fn registerEvent(handler: *const fn () void) u32 {
    if (event_slot_count >= MAX_EVENT_SLOTS) @panic("verve client: event slot capacity exceeded");
    const id = event_slot_count;
    event_slots[id] = handler;
    event_slot_count += 1;
    return id;
}

/// Invoke the registered handler at `id`. Out-of-range or unregistered
/// ids are silently ignored — keeps the bridge resilient to a stale
/// click against a hot-swapped wasm build. Exported as
/// `verve_event_dispatch` so the JS bridge can reach it.
pub fn dispatchEvent(id: u32) void {
    if (id >= event_slot_count) return;
    if (event_slots[id]) |fn_ptr| fn_ptr();
}

export fn verve_event_dispatch(id: u32) void {
    dispatchEvent(id);
}

// ---- Slot-table introspection -------------------------------------------
//
// Read-only views over the live signal + event slot tables. Useful
// for in-page debug overlays, log lines that pin down which bindings
// got registered during hydration, and capacity-watch dashboards.

/// Number of signal slots currently allocated (across all type tags).
pub fn slotCount() u32 {
    return @intCast(slot_count);
}

/// Static cap on signal slots — raises `@panic` past this. Bump
/// `MAX_SLOTS` if a real app needs more.
pub fn slotCapacity() u32 {
    return MAX_SLOTS;
}

/// Number of closure-style event handlers currently registered.
pub fn eventSlotCount() u32 {
    return event_slot_count;
}

/// Static cap on event slots. Bump `MAX_EVENT_SLOTS` if needed.
pub fn eventSlotCapacity() u32 {
    return MAX_EVENT_SLOTS;
}

/// Copy the name of the signal at `idx` into `buf`. Returns the
/// slice of `buf` actually filled — empty when `idx` is out of range
/// or the name doesn't fit. Useful for debug dumps walking
/// `0..slotCount()`.
pub fn slotName(idx: u32, buf: []u8) []const u8 {
    if (idx >= slot_count) return &[_]u8{};
    const name = slots[idx].name;
    const to_copy = @min(name.len, buf.len);
    @memcpy(buf[0..to_copy], name[0..to_copy]);
    return buf[0..to_copy];
}

/// Kind tag of the signal at `idx`. `null` when out of range.
pub fn slotKind(idx: u32) ?TypeTag {
    if (idx >= slot_count) return null;
    return slots[idx].type_tag;
}

// ---- IPC response handlers (G3) -----------------------------------------
//
// Per-route subscription model: chunks (and main client code) register
// a `*const fn ([*]const u8, u32) void` against a route name. When the
// bridge JS observes an inbound reply with `type == <route>`, it
// stages the reply body bytes into the runtime's island scratch
// buffer and calls `verve_dispatch_response(route, body_ptr, body_len)`
// which walks the slot table and fires every matching handler. Pairs
// with the existing `server_fn_post` / `post_json_i32` outbound
// externs to close the request → reply loop.

const ResponseSlot = struct {
    route: []const u8,
    fn_ptr: *const fn ([*]const u8, u32) void,
};

const MAX_RESPONSE_SLOTS: u32 = 256;
var response_slots: [MAX_RESPONSE_SLOTS]?ResponseSlot = [_]?ResponseSlot{null} ** MAX_RESPONSE_SLOTS;
var response_slot_count: u32 = 0;

/// Register a per-route reply handler. Multiple handlers per route
/// are allowed — they fire in registration order. Names live for the
/// lifetime of the slot table (typically the page lifetime); chunks
/// should pass static string literals.
pub fn registerResponseHandler(route: []const u8, handler: *const fn ([*]const u8, u32) void) void {
    if (response_slot_count >= MAX_RESPONSE_SLOTS) @panic("verve client: response slot capacity exceeded");
    response_slots[response_slot_count] = .{ .route = route, .fn_ptr = handler };
    response_slot_count += 1;
}

/// Fire every handler registered against `route`. Called from the
/// bridge JS once it has staged the body bytes into shared memory.
/// Out-of-table or zero-handler routes are silently dropped.
pub fn dispatchResponse(route: []const u8, body: []const u8) void {
    for (response_slots[0..response_slot_count]) |maybe_slot| {
        const slot = maybe_slot orelse continue;
        if (std.mem.eql(u8, slot.route, route)) {
            slot.fn_ptr(body.ptr, @intCast(body.len));
        }
    }
}

pub fn responseSlotCount() u32 {
    return response_slot_count;
}

// ---- Cleanup hooks -------------------------------------------------------
//
// `cleanup(handler)` registers a `*const fn() void` against the
// runtime's root Owner. When the Owner disposes (today: only via
// `resetForTesting`; future SPA navigation will dispose per-route
// owners) every registered handler runs in LIFO order. Chunks reach
// this through the matching `verve_cleanup` extern in
// `island_runtime.zig` — the cross-module function table sharing
// wired in Phase 13G makes the fn pointer resolve cleanly.

pub fn cleanup(handler: *const fn () void) !void {
    const owner = ensureOwner();
    const Wrap = struct {
        fn run(h: *const fn () void) void {
            h();
        }
    };
    try owner.onCleanup(handler, Wrap.run);
}

/// Initial value carried by a `Binding` — picks which `register*`
/// variant the runtime should dispatch to.
pub const BindingInitial = union(enum) {
    i32: i32,
    str: []const u8,
    bool: struct { class: []const u8, value: bool },
    f32: f32,
};

/// Single entry in the `autoHydrate` declarative bindings list.
pub const Binding = struct {
    name: []const u8,
    initial: BindingInitial,
};

/// Register every binding in `bindings` against the runtime's root
/// Owner. Dispatches to the matching `register*` based on the union
/// tag — `bindings` can mix i32 / str / bool / f32 entries freely.
/// Return values discarded; the caller can still look slots up by
/// name via `signalI32` / `signalStr` / `signalBool` / `signalF32`.
///
/// Initial values are caller-supplied. The bridge's
/// `verve_init_<name>(value)` walker stays the recommended way to
/// source those from the server-rendered DOM — capture each value
/// into a module-level `var initial_<name>: T` and pass it through
/// here from `verve_hydrate`. Hard-coded initials work too when the
/// app's starting state is fully known at compile time.
pub fn autoHydrate(bindings: []const Binding) void {
    for (bindings) |b| {
        switch (b.initial) {
            .i32 => |v| _ = registerI32(b.name, v),
            .str => |v| _ = registerStr(b.name, v),
            .bool => |s| _ = registerBool(b.name, s.class, s.value),
            .f32 => |v| _ = registerF32(b.name, v),
        }
    }
}

/// Resolve a server-rendered `NodeRef` to a JS-owned element handle.
/// Returns null when the bridge can't find a matching `[data-ref="<id>"]`.
/// Accepts any value that exposes `.id: []const u8` — typically a
/// `verve.NodeRef(.tag)` instance.
pub fn queryRef(ref: anytype) ?i32 {
    const id = ref.id;
    const handle = dom.query_ref(id.ptr, id.len);
    return if (handle <= 0) null else handle;
}

// ---- Named templates (Phase 16, G2) -------------------------------------
//
// Wasm-side composition flow: server stamps prototypes via
// `ctx.template("<name>", inner)` + `Node.slot(name)`; chunks clone
// at runtime, fill slots, append to a bound parent.

/// Look up `[data-vt="<name>"]`, clone its content, return a handle
/// to the cloned root element. `null` when no template matches.
/// The clone is detached — append with `appendToBind` (or any
/// future NodeRef-keyed insert) to make it visible.
pub fn cloneTemplate(name: []const u8) ?i32 {
    const h = dom.clone_template(name.ptr, name.len);
    return if (h <= 0) null else h;
}

/// Fill `[data-vt-slot="<slot>"]` inside the cloned subtree with
/// `text` (replaces `textContent`).
pub fn slotText(handle: i32, slot: []const u8, text: []const u8) void {
    dom.slot_text(handle, slot.ptr, slot.len, text.ptr, text.len);
}

/// Set `attr_name = attr_value` on `[data-vt-slot="<slot>"]` inside
/// the cloned subtree.
pub fn slotAttr(handle: i32, slot: []const u8, attr_name: []const u8, attr_value: []const u8) void {
    dom.slot_attr(handle, slot.ptr, slot.len, attr_name.ptr, attr_name.len, attr_value.ptr, attr_value.len);
}

/// Append the cloned fragment as the last child of every element
/// matching `[z-bind="<parent_bind>"]` (and `[data-vh]`). The
/// fragment is re-cloned per parent so multiple bound parents
/// don't share the same node reference.
pub fn appendToBind(parent_bind: []const u8, child_handle: i32) void {
    dom.append_to_bind(parent_bind.ptr, parent_bind.len, child_handle);
}

// ---- Per-handle NodeRef ops --------------------------------------------
//
// Once `queryRef` has resolved a handle, downstream code reaches into
// the live element through these wrappers. Each thin-wraps the matching
// `dom.ref_*` extern; the bridge JS does the actual DOM work.

pub fn setRefText(handle: i32, text: []const u8) void {
    dom.ref_set_text(handle, text.ptr, text.len);
}

pub fn setRefTextI32(handle: i32, value: i32) void {
    dom.ref_set_text_i32(handle, value);
}

pub fn setRefAttr(handle: i32, name: []const u8, value: []const u8) void {
    dom.ref_set_attr(handle, name.ptr, name.len, value.ptr, value.len);
}

pub fn setRefValue(handle: i32, value: []const u8) void {
    dom.ref_set_value(handle, value.ptr, value.len);
}

pub fn setRefClass(handle: i32, class: []const u8, on: bool) void {
    dom.ref_set_class(handle, class.ptr, class.len, if (on) 1 else 0);
}

pub fn focusRef(handle: i32) void {
    dom.ref_focus(handle);
}

pub fn removeRef(handle: i32) void {
    dom.ref_remove(handle);
}

pub fn refValueI32(handle: i32) i32 {
    return dom.ref_get_value_i32(handle);
}

pub fn refValueF32(handle: i32) f32 {
    return dom.ref_get_value_f32(handle);
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

/// Persistent handle over a keyed parent. Holds the last-known key
/// order in the runtime's owner-allocated storage so subsequent
/// `update` calls can diff against the live DOM without the caller
/// having to track the previous order themselves. Constructed via
/// `registerForEach` — the initial keys must match what the server
/// rendered into the parent, so the very first `update` only emits
/// ops for the actual delta.
pub const ForEachHandle = struct {
    parent_bind: []const u8,
    current_keys: [][]const u8,
    allocator: std.mem.Allocator,

    /// Reconcile against a new key/html pairing. `new_html[i]` is the
    /// child markup for `new_keys[i]`. Inserted children are anchored
    /// against the next surviving key; removed children are detached;
    /// surviving children keep their DOM nodes intact across moves.
    ///
    /// `arena` is scratch for the planner — it can be the caller's
    /// per-frame allocator. The handle's own slot stays on the runtime
    /// owner.
    pub fn update(
        self: *ForEachHandle,
        arena: std.mem.Allocator,
        new_keys: []const []const u8,
        new_html: []const []const u8,
    ) !void {
        try applyReconcile(arena, self.parent_bind, self.current_keys, new_keys, new_html);
        // Replace the cached key list with owner-allocated copies so
        // the caller can reuse `new_keys`' backing memory.
        const owned = try self.allocator.alloc([]const u8, new_keys.len);
        for (new_keys, 0..) |k, i| {
            owned[i] = try self.allocator.dupe(u8, k);
        }
        // Free the previous cache slot. Bump allocator is a no-op
        // free; native fallback skip is harmless.
        self.allocator.free(self.current_keys);
        self.current_keys = owned;
    }
};

/// Build a `ForEachHandle` keyed against `parent_bind`. `initial_keys`
/// is the key order the server rendered — supplying it correctly is
/// the contract that makes the first `update` emit ops for only the
/// real delta (rather than treating every existing child as new).
pub fn registerForEach(parent_bind: []const u8, initial_keys: []const []const u8) !*ForEachHandle {
    const owner = ensureOwner();
    const gpa = owner.allocator();

    const handle = try gpa.create(ForEachHandle);
    const owned = try gpa.alloc([]const u8, initial_keys.len);
    for (initial_keys, 0..) |k, i| {
        owned[i] = try gpa.dupe(u8, k);
    }
    handle.* = .{
        .parent_bind = parent_bind,
        .current_keys = owned,
        .allocator = gpa,
    };
    return handle;
}

/// Snapshot returned by a `bindForEach` render fn — parallel slices of
/// keys + per-key HTML markup. `keys.len` must equal `html.len`.
pub const ForEachData = struct {
    keys: []const []const u8,
    html: []const []const u8,
};

/// Wire a list-valued computation into the reactive graph: every
/// signal `render_fn` reads becomes a dependency, and any subsequent
/// `set` re-runs the closure → calls `handle.update(...)` against the
/// new keys. The first invocation runs eagerly under the runtime's
/// Owner so the initial dependency set is recorded.
///
/// `render_fn` allocates its returned slices from the per-frame
/// scratch bump allocator (`src/client/scratch.zig`). The runtime
/// resets scratch at the top of each re-run so memory usage stays
/// bounded by the largest single-frame render, not the page's
/// lifetime. Long-lived state (the handle's key cache, Signals, the
/// reactive graph itself) lives on the separate `client/allocator.zig`
/// heap and is untouched by the reset.
pub fn bindForEach(
    handle: *ForEachHandle,
    ctx_ptr: anytype,
    comptime render_fn: fn (@TypeOf(ctx_ptr), std.mem.Allocator) anyerror!ForEachData,
) !*verve.Effect {
    const CtxT = @TypeOf(ctx_ptr);
    comptime std.debug.assert(@typeInfo(CtxT) == .pointer);

    const owner = ensureOwner();
    const gpa = owner.allocator();

    const Wrapper = struct {
        h: *ForEachHandle,
        outer: CtxT,

        fn run(self: *@This()) void {
            scratch.reset();
            const a = scratch.allocator();
            const data = render_fn(self.outer, a) catch return;
            self.h.update(a, data.keys, data.html) catch return;
        }
    };

    const wrap = try gpa.create(Wrapper);
    wrap.* = .{ .h = handle, .outer = ctx_ptr };

    return try verve.createEffect(owner, wrap, Wrapper.run);
}

/// Wipe runtime state. ONLY for use from unit tests on the native build.
pub fn resetForTesting() void {
    if (root_owner) |o| {
        o.dispose();
        root_owner = null;
    }
    slot_count = 0;
    event_slot_count = 0;
    @memset(event_slots[0..], null);
    response_slot_count = 0;
    @memset(response_slots[0..], null);
    client_alloc.reset();
}
