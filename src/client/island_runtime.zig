//! Chunk-side wrapper around the main `client.wasm`'s reactive
//! runtime. Each declaration is `extern "verve_runtime" fn ...` — the
//! bridge JS resolves the imports against the main client's matching
//! exports at chunk instantiation time (see `src/bridge/verve.js`
//! island loader).
//!
//! Per-island chunks `@import("verve")` (the build module name) and
//! call the Zig wrappers below. The wrappers exist so chunks write
//! `verve.registerI32("count", 0)` instead of fussing with
//! `(name.ptr, @intCast(name.len), 0)` at every call site.
//!
//! This file is wasm-only — the `extern` declarations link against
//! imports that don't exist on the native target. The build wires it
//! exclusively into the per-island chunk modules (wasm32-freestanding).

// ---- Imported from the main client runtime ------------------------------
// One-to-one mapping with the `export fn verve_*` declarations in
// `src/client/runtime_exports.zig`. Keep the two files in sync —
// dropping or renaming an export here causes `WebAssembly.instantiate`
// to throw `LinkError` when the chunk loads.

extern "verve_runtime" fn verve_register_i32(name_ptr: [*]const u8, name_len: u32, initial: i32) void;
extern "verve_runtime" fn verve_register_str(name_ptr: [*]const u8, name_len: u32, initial_ptr: [*]const u8, initial_len: u32) void;
extern "verve_runtime" fn verve_register_bool(name_ptr: [*]const u8, name_len: u32, class_ptr: [*]const u8, class_len: u32, initial: u32) void;
extern "verve_runtime" fn verve_register_f32(name_ptr: [*]const u8, name_len: u32, initial: f32) void;

extern "verve_runtime" fn verve_signal_set_i32(name_ptr: [*]const u8, name_len: u32, value: i32) void;
extern "verve_runtime" fn verve_signal_set_str(name_ptr: [*]const u8, name_len: u32, value_ptr: [*]const u8, value_len: u32) void;
extern "verve_runtime" fn verve_signal_set_bool(name_ptr: [*]const u8, name_len: u32, value: u32) void;
extern "verve_runtime" fn verve_signal_set_f32(name_ptr: [*]const u8, name_len: u32, value: f32) void;

extern "verve_runtime" fn verve_signal_get_i32(name_ptr: [*]const u8, name_len: u32) i32;
extern "verve_runtime" fn verve_signal_get_bool(name_ptr: [*]const u8, name_len: u32) u32;
extern "verve_runtime" fn verve_signal_get_f32(name_ptr: [*]const u8, name_len: u32) f32;
extern "verve_runtime" fn verve_signal_get_str_len(name_ptr: [*]const u8, name_len: u32) u32;
extern "verve_runtime" fn verve_signal_get_str(name_ptr: [*]const u8, name_len: u32, buf_ptr: [*]u8, buf_cap: u32) u32;

extern "verve_runtime" fn verve_query_ref(id_ptr: [*]const u8, id_len: u32) i32;
extern "verve_runtime" fn verve_ref_set_text(handle: i32, ptr: [*]const u8, len: u32) void;
extern "verve_runtime" fn verve_ref_set_text_i32(handle: i32, value: i32) void;
extern "verve_runtime" fn verve_ref_set_attr(handle: i32, name_ptr: [*]const u8, name_len: u32, val_ptr: [*]const u8, val_len: u32) void;
extern "verve_runtime" fn verve_ref_set_value(handle: i32, val_ptr: [*]const u8, val_len: u32) void;
extern "verve_runtime" fn verve_ref_set_class(handle: i32, class_ptr: [*]const u8, class_len: u32, on: u32) void;
extern "verve_runtime" fn verve_ref_focus(handle: i32) void;
extern "verve_runtime" fn verve_ref_remove(handle: i32) void;
extern "verve_runtime" fn verve_ref_get_value_i32(handle: i32) i32;
extern "verve_runtime" fn verve_ref_get_value_f32(handle: i32) f32;

// Closure event registration. Requires the chunk's indirect function
// table to be the same one the main runtime uses — build.zig sets
// `import_table = true` on chunks + `export_table = true` on the main
// client, and the bridge JS passes the table through as
// `env.__indirect_function_table` at chunk instantiation.
extern "verve_runtime" fn verve_register_event(handler_idx: u32) u32;
extern "verve_runtime" fn verve_dispatch_event(id: u32) void;
extern "verve_runtime" fn verve_cleanup(handler_idx: u32) void;

extern "verve_runtime" fn verve_register_response_handler(
    route_ptr: [*]const u8,
    route_len: u32,
    handler_idx: u32,
) void;

extern "verve_runtime" fn verve_list_diff(
    parent_ptr: [*]const u8,
    parent_len: u32,
    old_keys_ptr: [*]const []const u8,
    old_keys_count: u32,
    new_keys_ptr: [*]const []const u8,
    new_keys_count: u32,
    new_html_ptr: [*]const []const u8,
    new_html_count: u32,
) void;

extern "verve_runtime" fn verve_slot_count() u32;
extern "verve_runtime" fn verve_slot_capacity() u32;
extern "verve_runtime" fn verve_event_slot_count() u32;
extern "verve_runtime" fn verve_event_slot_capacity() u32;
extern "verve_runtime" fn verve_slot_name(idx: u32, buf_ptr: [*]u8, buf_cap: u32) u32;
extern "verve_runtime" fn verve_slot_kind(idx: u32) u32;

// ---- Friendly Zig wrappers ----------------------------------------------

pub fn registerI32(name: []const u8, initial: i32) void {
    verve_register_i32(name.ptr, @intCast(name.len), initial);
}

pub fn registerStr(name: []const u8, initial: []const u8) void {
    verve_register_str(name.ptr, @intCast(name.len), initial.ptr, @intCast(initial.len));
}

pub fn registerBool(name: []const u8, class: []const u8, initial: bool) void {
    verve_register_bool(
        name.ptr,
        @intCast(name.len),
        class.ptr,
        @intCast(class.len),
        if (initial) 1 else 0,
    );
}

pub fn registerF32(name: []const u8, initial: f32) void {
    verve_register_f32(name.ptr, @intCast(name.len), initial);
}

pub fn signalSetI32(name: []const u8, value: i32) void {
    verve_signal_set_i32(name.ptr, @intCast(name.len), value);
}

pub fn signalSetStr(name: []const u8, value: []const u8) void {
    verve_signal_set_str(name.ptr, @intCast(name.len), value.ptr, @intCast(value.len));
}

pub fn signalSetBool(name: []const u8, value: bool) void {
    verve_signal_set_bool(name.ptr, @intCast(name.len), if (value) 1 else 0);
}

pub fn signalSetF32(name: []const u8, value: f32) void {
    verve_signal_set_f32(name.ptr, @intCast(name.len), value);
}

pub fn signalGetI32(name: []const u8) i32 {
    return verve_signal_get_i32(name.ptr, @intCast(name.len));
}

pub fn signalGetBool(name: []const u8) bool {
    return verve_signal_get_bool(name.ptr, @intCast(name.len)) != 0;
}

pub fn signalGetF32(name: []const u8) f32 {
    return verve_signal_get_f32(name.ptr, @intCast(name.len));
}

/// Read a string signal's current value into a caller-supplied buffer.
/// Returns the slice of `buf` that was actually filled — may be shorter
/// than the underlying value when `buf` is too small. Probe the size
/// first via `signalGetStrLen` if the caller needs an exactly-sized
/// allocation.
pub fn signalGetStr(name: []const u8, buf: []u8) []const u8 {
    const wrote = verve_signal_get_str(
        name.ptr,
        @intCast(name.len),
        buf.ptr,
        @intCast(buf.len),
    );
    return buf[0..wrote];
}

pub fn signalGetStrLen(name: []const u8) u32 {
    return verve_signal_get_str_len(name.ptr, @intCast(name.len));
}

/// Resolve a `data-ref="<id>"` to a JS-owned element handle. Returns
/// null when the bridge can't find a matching element. Accepts any
/// value exposing `.id: []const u8` — typically a `verve.NodeRef(.tag)`
/// instance — or a raw `[]const u8`.
pub fn queryRef(ref: anytype) ?i32 {
    const id: []const u8 = if (@TypeOf(ref) == []const u8) ref else ref.id;
    const handle = verve_query_ref(id.ptr, @intCast(id.len));
    return if (handle <= 0) null else handle;
}

pub fn setRefText(handle: i32, text: []const u8) void {
    verve_ref_set_text(handle, text.ptr, @intCast(text.len));
}

pub fn setRefTextI32(handle: i32, value: i32) void {
    verve_ref_set_text_i32(handle, value);
}

pub fn setRefAttr(handle: i32, name: []const u8, value: []const u8) void {
    verve_ref_set_attr(
        handle,
        name.ptr,
        @intCast(name.len),
        value.ptr,
        @intCast(value.len),
    );
}

pub fn setRefValue(handle: i32, value: []const u8) void {
    verve_ref_set_value(handle, value.ptr, @intCast(value.len));
}

pub fn setRefClass(handle: i32, class: []const u8, on: bool) void {
    verve_ref_set_class(handle, class.ptr, @intCast(class.len), if (on) 1 else 0);
}

pub fn focusRef(handle: i32) void {
    verve_ref_focus(handle);
}

pub fn removeRef(handle: i32) void {
    verve_ref_remove(handle);
}

pub fn refValueI32(handle: i32) i32 {
    return verve_ref_get_value_i32(handle);
}

pub fn refValueF32(handle: i32) f32 {
    return verve_ref_get_value_f32(handle);
}

/// Register a closure-style event handler in the main runtime's
/// `event_slots` table. Returns the slot id to stamp on the
/// rendered HTML via `Node.onClickFn(id)` / `onSubmitFn` / etc.
/// Handler runs in the chunk's wasm with whatever state it captured
/// at registration; the indirect function table is shared with the
/// main runtime so `call_indirect` from `verve_event_dispatch` reaches
/// chunk code without extra hops.
pub fn registerEvent(handler: *const fn () void) u32 {
    return verve_register_event(@intCast(@intFromPtr(handler)));
}

pub fn dispatchEvent(id: u32) void {
    verve_dispatch_event(id);
}

/// Register a cleanup handler on the runtime's root Owner from a
/// chunk. The handler runs when the Owner disposes (today: only on
/// test reset; future SPA navigation will dispose per-route owners).
/// Fn pointer crosses the chunk boundary via the shared indirect
/// function table wired in Phase 13G.
pub fn cleanup(handler: *const fn () void) void {
    verve_cleanup(@intCast(@intFromPtr(handler)));
}

/// Register a per-route IPC reply handler. When the bridge JS
/// observes an inbound message whose `type` matches `route`, the
/// runtime fires `handler` with a pointer + length into shared
/// memory pointing at the reply body bytes (typically JSON). The
/// pointer is only valid for the duration of the call — copy into
/// caller storage before returning if longer life is needed.
///
/// Pairs with the outbound `server_fn_post` extern so chunks can
/// implement full request → response loops over the desktop IPC
/// channel (or the web `/api/<name>` POST) without going through
/// JS Promise correlation.
pub fn registerResponseHandler(
    route: []const u8,
    handler: *const fn ([*]const u8, u32) void,
) void {
    verve_register_response_handler(
        route.ptr,
        @intCast(route.len),
        @intCast(@intFromPtr(handler)),
    );
}

/// Reconcile a keyed list against the live DOM. `parent_bind` names
/// the `[z-bind]` / `[data-vh]` parent element; `old_keys` is the
/// key order the parent currently holds; `new_keys` + `new_html` are
/// parallel slices for the target order. The runtime plans the
/// minimum (insert | move | remove) op sequence and dispatches each
/// op through the bridge JS's keyed-child primitives.
///
/// Callers typically render `new_html[i]` for each `new_keys[i]` into
/// their own buffer before this call. `new_keys.len` must equal
/// `new_html.len` (mismatched lengths short-circuit to a no-op).
pub fn listDiff(
    parent_bind: []const u8,
    old_keys: []const []const u8,
    new_keys: []const []const u8,
    new_html: []const []const u8,
) void {
    verve_list_diff(
        parent_bind.ptr,
        @intCast(parent_bind.len),
        old_keys.ptr,
        @intCast(old_keys.len),
        new_keys.ptr,
        @intCast(new_keys.len),
        new_html.ptr,
        @intCast(new_html.len),
    );
}

/// Slot-table introspection from a chunk. Useful for in-chunk
/// hydration sanity checks ("did the main client register the slot
/// I expected before I tried to mutate it?").
pub fn slotCount() u32 {
    return verve_slot_count();
}

pub fn slotCapacity() u32 {
    return verve_slot_capacity();
}

pub fn eventSlotCount() u32 {
    return verve_event_slot_count();
}

pub fn eventSlotCapacity() u32 {
    return verve_event_slot_capacity();
}

pub fn slotName(idx: u32, buf: []u8) []const u8 {
    const wrote = verve_slot_name(idx, buf.ptr, @intCast(buf.len));
    return buf[0..wrote];
}

/// Kind tag of the signal at `idx`. 0=i32, 1=str, 2=bool, 3=f32,
/// null when out of range.
pub const SlotKind = enum(u32) { i32 = 0, str = 1, bool = 2, f32 = 3 };
pub fn slotKind(idx: u32) ?SlotKind {
    const raw = verve_slot_kind(idx);
    if (raw == 0xFFFFFFFF) return null;
    return @enumFromInt(raw);
}
