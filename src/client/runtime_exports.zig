//! Phase 13F — chunk-callable wrapper surface.
//!
//! Per-island WASM chunks share the main client's linear memory at
//! instantiation but live in their own wasm module. They can't reach
//! `runtime.registerI32` etc. directly (those are `pub fn` not
//! `export fn` — not in the main client's export table). The bridge
//! JS resolves each chunk's `extern "verve_runtime" fn verve_*` import
//! against the matching export on the main `client.wasm` instance, so
//! we re-emit every chunk-needed function here as an exported wrapper.
//!
//! Name-keyed dispatch on the registration surface keeps the chunk
//! side simple — chunks pass `(name_ptr, name_len, value)` for every
//! call; the lookup cost is `O(slot_count <= 64)` which is acceptable
//! for non-hot-path use (hydrate runs once per <verve-island> + click
//! handlers fire on user input).
//!
//! Closure-style event registration (passing a `*const fn () void`
//! across the chunk boundary) is deferred — cross-module function-table
//! sharing is significant scope. Chunks needing handlers stamp
//! `z-on-click="<exportName>"` and the bridge JS string-name delegate
//! routes into the chunk's own exported function.

const runtime = @import("runtime.zig");
const dom = @import("dom.zig");

// ---- Signal registration (register-and-forget) ---------------------------

export fn verve_register_i32(name_ptr: [*]const u8, name_len: u32, initial: i32) void {
    const name = name_ptr[0..name_len];
    _ = runtime.registerI32(name, initial);
}

export fn verve_register_str(
    name_ptr: [*]const u8,
    name_len: u32,
    initial_ptr: [*]const u8,
    initial_len: u32,
) void {
    const name = name_ptr[0..name_len];
    const initial = initial_ptr[0..initial_len];
    _ = runtime.registerStr(name, initial);
}

export fn verve_register_bool(
    name_ptr: [*]const u8,
    name_len: u32,
    class_ptr: [*]const u8,
    class_len: u32,
    initial: u32,
) void {
    const name = name_ptr[0..name_len];
    const class = class_ptr[0..class_len];
    _ = runtime.registerBool(name, class, initial != 0);
}

export fn verve_register_f32(name_ptr: [*]const u8, name_len: u32, initial: f32) void {
    const name = name_ptr[0..name_len];
    _ = runtime.registerF32(name, initial);
}

// ---- Signal write (lookup-by-name + Signal.set) --------------------------

export fn verve_signal_set_i32(name_ptr: [*]const u8, name_len: u32, value: i32) void {
    const name = name_ptr[0..name_len];
    if (runtime.signalI32(name)) |sig| sig.set(value);
}

export fn verve_signal_set_str(
    name_ptr: [*]const u8,
    name_len: u32,
    value_ptr: [*]const u8,
    value_len: u32,
) void {
    const name = name_ptr[0..name_len];
    if (runtime.signalStr(name)) |sig| sig.set(value_ptr[0..value_len]);
}

export fn verve_signal_set_bool(name_ptr: [*]const u8, name_len: u32, value: u32) void {
    const name = name_ptr[0..name_len];
    if (runtime.signalBool(name)) |sig| sig.set(value != 0);
}

export fn verve_signal_set_f32(name_ptr: [*]const u8, name_len: u32, value: f32) void {
    const name = name_ptr[0..name_len];
    if (runtime.signalF32(name)) |sig| sig.set(value);
}

// ---- Signal read (lookup-by-name + Signal.peek) --------------------------

export fn verve_signal_get_i32(name_ptr: [*]const u8, name_len: u32) i32 {
    const name = name_ptr[0..name_len];
    if (runtime.signalI32(name)) |sig| return sig.peek();
    return 0;
}

export fn verve_signal_get_bool(name_ptr: [*]const u8, name_len: u32) u32 {
    const name = name_ptr[0..name_len];
    if (runtime.signalBool(name)) |sig| return if (sig.peek()) 1 else 0;
    return 0;
}

export fn verve_signal_get_f32(name_ptr: [*]const u8, name_len: u32) f32 {
    const name = name_ptr[0..name_len];
    if (runtime.signalF32(name)) |sig| return sig.peek();
    return 0;
}

/// Step 1 of the string-read protocol: probe the value length so the
/// caller can size a buffer before the second call. Returns 0 when no
/// signal matches the name.
export fn verve_signal_get_str_len(name_ptr: [*]const u8, name_len: u32) u32 {
    const name = name_ptr[0..name_len];
    if (runtime.signalStr(name)) |sig| return @intCast(sig.peek().len);
    return 0;
}

/// Step 2 of the string-read protocol: copy up to `buf_cap` bytes of
/// the current value into the caller-supplied buffer. Returns the
/// number of bytes written (which may be less than `buf_cap` when the
/// value is shorter, or less than the value length when the buffer is
/// too small). Returns 0 when no signal matches.
export fn verve_signal_get_str(
    name_ptr: [*]const u8,
    name_len: u32,
    buf_ptr: [*]u8,
    buf_cap: u32,
) u32 {
    const name = name_ptr[0..name_len];
    if (runtime.signalStr(name)) |sig| {
        const v = sig.peek();
        const to_copy: u32 = @min(@as(u32, @intCast(v.len)), buf_cap);
        @memcpy(buf_ptr[0..to_copy], v[0..to_copy]);
        return to_copy;
    }
    return 0;
}

// ---- NodeRef ops (thin wrappers around dom.* externs) --------------------

export fn verve_query_ref(id_ptr: [*]const u8, id_len: u32) i32 {
    return dom.query_ref(id_ptr, @as(usize, id_len));
}

export fn verve_ref_set_text(handle: i32, ptr: [*]const u8, len: u32) void {
    dom.ref_set_text(handle, ptr, @as(usize, len));
}

export fn verve_ref_set_text_i32(handle: i32, value: i32) void {
    dom.ref_set_text_i32(handle, value);
}

export fn verve_ref_set_attr(
    handle: i32,
    name_ptr: [*]const u8,
    name_len: u32,
    val_ptr: [*]const u8,
    val_len: u32,
) void {
    dom.ref_set_attr(handle, name_ptr, @as(usize, name_len), val_ptr, @as(usize, val_len));
}

export fn verve_ref_set_value(handle: i32, val_ptr: [*]const u8, val_len: u32) void {
    dom.ref_set_value(handle, val_ptr, @as(usize, val_len));
}

export fn verve_ref_set_class(
    handle: i32,
    class_ptr: [*]const u8,
    class_len: u32,
    on: u32,
) void {
    dom.ref_set_class(handle, class_ptr, @as(usize, class_len), on);
}

export fn verve_ref_focus(handle: i32) void {
    dom.ref_focus(handle);
}

export fn verve_ref_remove(handle: i32) void {
    dom.ref_remove(handle);
}

export fn verve_ref_get_value_i32(handle: i32) i32 {
    return dom.ref_get_value_i32(handle);
}

export fn verve_ref_get_value_f32(handle: i32) f32 {
    return dom.ref_get_value_f32(handle);
}

// ---- Closure event registration (Phase 13G) ------------------------------
//
// Chunks pass a `*const fn () void` taken via `&chunk_handler`. The
// pointer is an index into the indirect function table — main runtime
// shares its table with chunks via wasm-ld's `--import-table` /
// `--export-table` flags wired in build.zig, so the index resolves to
// the right function whether dispatch fires from main or chunk code.

export fn verve_register_event(handler_idx: u32) u32 {
    // wasm MVP function ABI doesn't carry `*const fn () void`
    // arguments across module boundaries; chunks pass the indirect-
    // function-table index as a plain u32 and we cast it back here.
    // Sharing the table via build.zig's `import_table` / `export_table`
    // flags is what makes this index meaningful on both sides.
    const handler: *const fn () void = @ptrFromInt(@as(usize, handler_idx));
    return runtime.registerEvent(handler);
}

/// Programmatically fire a previously-registered event slot. The bridge
/// JS click delegate already invokes `verve_event_dispatch(id)` directly
/// off the main runtime's exports; this wrapper exists so a chunk can
/// trigger its own handler synchronously without going through the DOM.
export fn verve_dispatch_event(id: u32) void {
    runtime.dispatchEvent(id);
}

/// Register a cleanup handler on the runtime's root Owner. Same
/// fn-pointer-as-u32 ABI as `verve_register_event`. Handler runs in
/// LIFO order when the Owner disposes; silently dropped if the
/// `onCleanup` allocation fails (owners are arena-backed, so this is
/// effectively OOM territory).
export fn verve_cleanup(handler_idx: u32) void {
    const handler: *const fn () void = @ptrFromInt(@as(usize, handler_idx));
    runtime.cleanup(handler) catch return;
}

// ---- Slot-table introspection (chunk-callable) --------------------------

export fn verve_slot_count() u32 {
    return runtime.slotCount();
}

export fn verve_slot_capacity() u32 {
    return runtime.slotCapacity();
}

export fn verve_event_slot_count() u32 {
    return runtime.eventSlotCount();
}

export fn verve_event_slot_capacity() u32 {
    return runtime.eventSlotCapacity();
}

export fn verve_slot_name(idx: u32, buf_ptr: [*]u8, buf_cap: u32) u32 {
    const filled = runtime.slotName(idx, buf_ptr[0..buf_cap]);
    return @intCast(filled.len);
}

/// Returns 0 = i32, 1 = str, 2 = bool, 3 = f32, 0xFFFFFFFF = out of range.
export fn verve_slot_kind(idx: u32) u32 {
    const kind = runtime.slotKind(idx) orelse return 0xFFFFFFFF;
    return switch (kind) {
        .i32 => 0,
        .str => 1,
        .bool => 2,
        .f32 => 3,
    };
}

// ---- Tests ---------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "verve_register_i32 + verve_signal_set_i32 + verve_signal_get_i32 round-trip" {
    runtime.resetForTesting();

    const name = "chunk_count";
    verve_register_i32(name.ptr, name.len, 7);
    try testing.expectEqual(@as(i32, 7), verve_signal_get_i32(name.ptr, name.len));

    verve_signal_set_i32(name.ptr, name.len, 42);
    try testing.expectEqual(@as(i32, 42), verve_signal_get_i32(name.ptr, name.len));

    // miss → 0
    const missing = "no_such_slot";
    try testing.expectEqual(@as(i32, 0), verve_signal_get_i32(missing.ptr, missing.len));
}

test "verve_register_str + verve_signal_get_str two-call read" {
    runtime.resetForTesting();

    const name = "chunk_label";
    const initial = "hello";
    verve_register_str(name.ptr, name.len, initial.ptr, initial.len);

    const len = verve_signal_get_str_len(name.ptr, name.len);
    try testing.expectEqual(@as(u32, 5), len);

    var buf: [16]u8 = undefined;
    const wrote = verve_signal_get_str(name.ptr, name.len, &buf, buf.len);
    try testing.expectEqual(@as(u32, 5), wrote);
    try testing.expectEqualStrings("hello", buf[0..wrote]);

    // write-back via the exported setter
    const next = "world!";
    verve_signal_set_str(name.ptr, name.len, next.ptr, next.len);
    const wrote2 = verve_signal_get_str(name.ptr, name.len, &buf, buf.len);
    try testing.expectEqualStrings("world!", buf[0..wrote2]);
}

test "verve_register_bool + verve_signal_set_bool + verve_signal_get_bool" {
    runtime.resetForTesting();

    const name = "chunk_open";
    const class = "is-open";
    verve_register_bool(name.ptr, name.len, class.ptr, class.len, 0);
    try testing.expectEqual(@as(u32, 0), verve_signal_get_bool(name.ptr, name.len));

    verve_signal_set_bool(name.ptr, name.len, 1);
    try testing.expectEqual(@as(u32, 1), verve_signal_get_bool(name.ptr, name.len));
}
