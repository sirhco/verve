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

const std = @import("std");
const serialize = @import("serialize");
const island_state = @import("island_state");

// Shared-memory access to the island state blob the main client staged before
// this chunk's hydrate (see `verve_current_state_ptr`/`_len` in runtime_exports).
extern "verve_runtime" fn verve_current_state_ptr() u32;
extern "verve_runtime" fn verve_current_state_len() u32;

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

// Closure event registration. The chunk passes a fn-pointer index into its
// own PRIVATE function table; the bridge's `makeChunkRuntime` wrapper copies
// the funcref into a freshly grown slot of the main client's table and
// forwards that slot index, so the main runtime's `event_slots` +
// `call_indirect` dispatch works unchanged (table isolation — chunk element
// segments can't clobber main's entries).
extern "verve_runtime" fn verve_register_event(handler_idx: u32) u32;
extern "verve_runtime" fn verve_dispatch_event(id: u32) void;
extern "verve_runtime" fn verve_cleanup(handler_idx: u32) void;

extern "verve_runtime" fn verve_register_response_handler(
    route_ptr: [*]const u8,
    route_len: u32,
    handler_idx: u32,
) void;

// Phase 17 — outbound typed POST + shared JSON value service. The
// parser lives once in the main client (`json_service.zig`); chunks
// reach it through these accessors instead of linking their own.
extern "verve_runtime" fn verve_server_fn_post(
    name_ptr: [*]const u8,
    name_len: u32,
    body_ptr: [*]const u8,
    body_len: u32,
) void;
extern "verve_runtime" fn verve_next_req_id() u32;
extern "verve_runtime" fn verve_register_response_handler_once(
    route_ptr: [*]const u8,
    route_len: u32,
    rid: u32,
    handler_idx: u32,
) void;
extern "verve_runtime" fn verve_server_fn_post_rid(
    name_ptr: [*]const u8,
    name_len: u32,
    body_ptr: [*]const u8,
    body_len: u32,
    rid: u32,
) void;
extern "verve_runtime" fn verve_json_parse(ptr: [*]const u8, len: u32) u32;
extern "verve_runtime" fn verve_json_free(handle: u32) void;
extern "verve_runtime" fn verve_json_get(handle: u32, key_ptr: [*]const u8, key_len: u32) u32;
extern "verve_runtime" fn verve_json_at(handle: u32, index: u32) u32;
extern "verve_runtime" fn verve_json_len(handle: u32) i32;
extern "verve_runtime" fn verve_json_kind(handle: u32) u32;
extern "verve_runtime" fn verve_json_i64(handle: u32) i64;
extern "verve_runtime" fn verve_json_f64(handle: u32) f64;
extern "verve_runtime" fn verve_json_bool(handle: u32) u32;
extern "verve_runtime" fn verve_json_str_len(handle: u32) u32;
extern "verve_runtime" fn verve_json_str(handle: u32, buf_ptr: [*]u8, buf_cap: u32) u32;

// Phase 18 — current-event accessors. Valid only inside a closure
// event handler (between the bridge's stage + dispatch).
extern "verve_runtime" fn verve_event_mods() u32;
extern "verve_runtime" fn verve_event_coord_x() f64;
extern "verve_runtime" fn verve_event_coord_y() f64;
extern "verve_runtime" fn verve_event_delta_y() f64;
extern "verve_runtime" fn verve_event_button() i32;
extern "verve_runtime" fn verve_event_key(buf_ptr: [*]u8, buf_cap: u32) u32;
extern "verve_runtime" fn verve_event_target_attr(
    name_ptr: [*]const u8,
    name_len: u32,
    buf_ptr: [*]u8,
    buf_cap: u32,
) u32;
extern "verve_runtime" fn verve_event_prevent_default() void;
extern "verve_runtime" fn verve_event_stop_propagation() void;
extern "verve_runtime" fn verve_event_capture_pointer() void;

// Phase 19 — timers, storage, clipboard. Timer handlers cross as
// function-table indices (same ABI as registerEvent).
extern "verve_runtime" fn verve_set_timeout(ms: u32, handler_idx: u32) u32;
extern "verve_runtime" fn verve_set_interval(ms: u32, handler_idx: u32) u32;
extern "verve_runtime" fn verve_request_animation_frame(handler_idx: u32) u32;
extern "verve_runtime" fn verve_queue_microtask(handler_idx: u32) void;
extern "verve_runtime" fn verve_clear_timer(id: u32) void;
extern "verve_runtime" fn verve_storage_len(key_ptr: [*]const u8, key_len: u32) u32;
extern "verve_runtime" fn verve_storage_get(
    key_ptr: [*]const u8,
    key_len: u32,
    buf_ptr: [*]u8,
    buf_cap: u32,
) u32;
extern "verve_runtime" fn verve_storage_set(
    key_ptr: [*]const u8,
    key_len: u32,
    val_ptr: [*]const u8,
    val_len: u32,
) void;
extern "verve_runtime" fn verve_storage_remove(key_ptr: [*]const u8, key_len: u32) void;
extern "verve_runtime" fn verve_clipboard_write(text_ptr: [*]const u8, text_len: u32) void;

// Phase 20 — forms + DOM measurement. Ref ops take a `query_ref`
// handle; `verve_ref_rect` / `verve_viewport` write f64s into a
// caller-provided buffer (8-byte aligned).
extern "verve_runtime" fn verve_ref_get_value_str(handle: i32, buf_ptr: [*]u8, buf_cap: u32) u32;
extern "verve_runtime" fn verve_ref_attr_len(handle: i32, name_ptr: [*]const u8, name_len: u32) u32;
extern "verve_runtime" fn verve_ref_get_attr(handle: i32, name_ptr: [*]const u8, name_len: u32, buf_ptr: [*]u8, buf_cap: u32) u32;
extern "verve_runtime" fn verve_ref_request_submit(handle: i32) void;
extern "verve_runtime" fn verve_ref_select(handle: i32) void;
extern "verve_runtime" fn verve_ref_blur(handle: i32) void;
extern "verve_runtime" fn verve_ref_rect(handle: i32, out_ptr: [*]f64) void;
extern "verve_runtime" fn verve_ref_scroll_into_view(handle: i32) void;
extern "verve_runtime" fn verve_viewport(out_ptr: [*]f64) void;
extern "verve_runtime" fn verve_match_media(query_ptr: [*]const u8, query_len: u32) u32;
extern "verve_runtime" fn verve_form_collect(
    bind_ptr: [*]const u8,
    bind_len: u32,
    buf_ptr: [*]u8,
    buf_cap: u32,
) u32;

// Phase 21 — generic JS interop. `verve_host_call` is synchronous;
// `verve_host_call_async` replies through the response-handler path.
extern "verve_runtime" fn verve_host_call(
    name_ptr: [*]const u8,
    name_len: u32,
    args_ptr: [*]const u8,
    args_len: u32,
    out_ptr: [*]u8,
    out_cap: u32,
) u32;
extern "verve_runtime" fn verve_host_call_async(
    name_ptr: [*]const u8,
    name_len: u32,
    args_ptr: [*]const u8,
    args_len: u32,
    route_ptr: [*]const u8,
    route_len: u32,
) void;

// Phase 22 — chunk arena + drag-drop.
extern "verve_runtime" fn verve_chunk_alloc(len: u32, alignment: u32) u32;
extern "verve_runtime" fn verve_chunk_arena_mark() u32;
extern "verve_runtime" fn verve_chunk_arena_reset(m: u32) void;

// gl asset region — page-scoped bump region for fetched GPU assets.
extern "verve_runtime" fn verve_asset_reset() void;
extern "verve_runtime" fn verve_register_drop(
    bind_ptr: [*]const u8,
    bind_len: u32,
    handler_idx: u32,
) void;
extern "verve_runtime" fn verve_drop_name(buf_ptr: [*]u8, buf_cap: u32) u32;
extern "verve_runtime" fn verve_drop_ptr() u32;
extern "verve_runtime" fn verve_drop_len() u32;

extern "verve_runtime" fn verve_clone_template(name_ptr: [*]const u8, name_len: u32) i32;
extern "verve_runtime" fn verve_slot_text(
    handle: i32,
    slot_ptr: [*]const u8,
    slot_len: u32,
    text_ptr: [*]const u8,
    text_len: u32,
) void;
extern "verve_runtime" fn verve_slot_attr(
    handle: i32,
    slot_ptr: [*]const u8,
    slot_len: u32,
    name_ptr: [*]const u8,
    name_len: u32,
    value_ptr: [*]const u8,
    value_len: u32,
) void;
extern "verve_runtime" fn verve_append_to_bind(
    parent_bind_ptr: [*]const u8,
    parent_bind_len: u32,
    child_handle: i32,
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
/// Resolve a `data-ref` to a live element handle. Pass the RAW id —
/// the runtime auto-scopes it to the current island's vid (matching
/// the SSR's rewriteBindings suffix). Do NOT suffix `__v{vid}` yourself;
/// that double-suffixes and misses. (Contrast: `listDiff` bind names
/// are NOT auto-scoped.)
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

/// Set an inline style property (`el.style.setProperty(name, value)`).
/// Use hyphenated CSS names ("background-color"). For transform pieces
/// (x/y/scale/rotate) prefer the anim engine — it owns `style.transform`
/// composition for elements it animates.
pub fn setRefStyle(handle: i32, name: []const u8, value: []const u8) void {
    verve_ref_set_style(
        handle,
        name.ptr,
        @intCast(name.len),
        value.ptr,
        @intCast(value.len),
    );
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

// ---- Typed props + island state (P3 / P1.5) ------------------------------

/// Decode this island's typed props from the `props_ptr` bytes the bridge
/// staged (base64-decoded `data-props`, in shared memory). Allocations live on
/// `alloc`. Panic-free on arbitrary bytes (see `serialize.decode`).
pub fn decodeProps(comptime T: type, bytes: []const u8, alloc: std.mem.Allocator) !T {
    return serialize.decode(T, bytes, alloc);
}

/// Read a primitive value (`i32`/`[]const u8`/`bool`/`f32`) from this island's
/// server-staged state blob, keyed by `key`. Returns null when absent or the
/// stored tag doesn't match `T`. String results are slices into the shared
/// state buffer — valid only during `hydrate`; copy (e.g. seed a `registerStr`)
/// to keep them past this call.
pub fn islandStateValue(comptime T: type, key: []const u8) ?T {
    const len = verve_current_state_len();
    if (len == 0) return null;
    const ptr = verve_current_state_ptr();
    const blob = @as([*]const u8, @ptrFromInt(ptr))[0..len];
    return island_state.valueAs(T, blob, key) catch null;
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

// ---- Typed IPC: outbound POST + shared JSON reader (Phase 17) -----------
//
// The full request → typed-reply loop for a chunk:
//
//   1. register a `fn ([*]const u8, u32) void` handler for the route via
//      `registerResponseHandler` (the bytes it receives are the raw
//      reply body, valid only for the call).
//   2. `serverFnPost(route, body)` to fire the request.
//   3. inside the handler: `parseJson(bytes)` → `JsonDoc`, read typed
//      fields (or `readStruct`), then `doc.free()`.
//
// This replaces a hand-rolled per-chunk JSON scanner: the parser lives
// once in the main client and the chunk only carries these thin externs.

/// POST `body` to `/api/<name>`. The reply (if any) fans back to the
/// handler registered for `name` via `registerResponseHandler`.
pub fn serverFnPost(name: []const u8, body: []const u8) void {
    verve_server_fn_post(name.ptr, @intCast(name.len), body.ptr, @intCast(body.len));
}

/// Allocate a monotonic, non-zero request correlation id (main-client scoped).
pub fn nextReqId() u32 {
    return verve_next_req_id();
}

/// Register a one-shot reply handler correlated by `rid`. Fires once when a reply
/// arrives whose `"rid"` matches, then is removed. The handler runs with the
/// registering island's vid restored (so name-keyed signal sets resolve that
/// island's signals).
pub fn registerResponseHandlerOnce(
    route: []const u8,
    rid: u32,
    handler: *const fn ([*]const u8, u32) void,
) void {
    verve_register_response_handler_once(
        route.ptr,
        @intCast(route.len),
        rid,
        @intCast(@intFromPtr(handler)),
    );
}

/// POST `body` to `/api/<name>` with correlation id `rid` (sent as the
/// `x-verve-rid` header). The reply fans back through `dispatchResponse`.
pub fn serverFnPostRid(name: []const u8, body: []const u8, rid: u32) void {
    verve_server_fn_post_rid(name.ptr, @intCast(name.len), body.ptr, @intCast(body.len), rid);
}

/// Comptime-monomorphic per (T, signal_name). Registered as the one-shot
/// (route, rid) reply handler; fires exactly once, for this call's reply.
/// Decodes the reply's `value` via the chunk JSON service and sets the named
/// signal. A reply missing `value` (e.g. a server error reshaped upstream)
/// leaves the signal at its current value.
fn Settler(comptime T: type, comptime name: []const u8) type {
    return struct {
        fn handle(ptr: [*]const u8, len: u32) void {
            const doc = parseJson(ptr[0..len]) orelse return;
            defer doc.free();
            const v = doc.get("value") orelse return;
            switch (T) {
                i32 => signalSetI32(name, @intCast(v.int())),
                bool => signalSetBool(name, v.boolean()),
                f32 => signalSetF32(name, @floatCast(v.float())),
                []const u8 => {
                    // Size the buffer from the actual value length so long
                    // strings aren't silently truncated. `signalSetStr` copies
                    // the bytes into the signal, so the arena scratch is freed
                    // immediately after.
                    const m = chunkArenaMark();
                    defer chunkArenaReset(m);
                    const buf = chunkArena().alloc(u8, v.strLen()) catch return;
                    signalSetStr(name, v.str(buf));
                },
                else => @compileError("fetchSignal: unsupported T " ++ @typeName(T)),
            }
        }
    };
}

/// Fetch `action_name(args)` from the server and set the already-registered,
/// vid-scoped signal `signal_name` from the typed reply `value`. The signal
/// must be registered first (e.g. `registerI32(signal_name, loading_default)`)
/// so the DOM binds; this updates it when the reply lands.
///
/// `T` is the signal type: `i32` | `[]const u8` | `bool` | `f32`. On server
/// error / no reply the signal keeps its loading value (no error path).
pub fn fetchSignal(
    comptime T: type,
    comptime action_name: []const u8,
    args: anytype,
    comptime signal_name: []const u8,
) void {
    const m = chunkArenaMark();
    defer chunkArenaReset(m);
    // Serialize args to a JSON object for the POST body. The bridge reads the
    // body synchronously inside `serverFnPostRid`, so the arena is still live.
    const json = std.json.Stringify.valueAlloc(chunkArena(), args, .{}) catch return;
    const rid = nextReqId();
    registerResponseHandlerOnce(action_name, rid, &Settler(T, signal_name).handle);
    serverFnPostRid(action_name, json, rid);
}

/// A handle into the main client's shared JSON value table. Non-owning
/// child handles from `get`/`at` stay valid until the root `free`s —
/// free the root last.
pub const JsonDoc = struct {
    handle: u32,

    pub const Kind = enum(u32) {
        null = 0,
        bool = 1,
        int = 2,
        float = 3,
        string = 4,
        array = 5,
        object = 6,
        invalid = 0xFFFFFFFF,
    };

    /// Object field by key. Null when the field is absent or this isn't
    /// an object.
    pub fn get(self: JsonDoc, key: []const u8) ?JsonDoc {
        const h = verve_json_get(self.handle, key.ptr, @intCast(key.len));
        return if (h == 0) null else .{ .handle = h };
    }

    /// Array element by index. Null when out of range or not an array.
    pub fn at(self: JsonDoc, index: u32) ?JsonDoc {
        const h = verve_json_at(self.handle, index);
        return if (h == 0) null else .{ .handle = h };
    }

    /// Array length, or -1 when not an array.
    pub fn len(self: JsonDoc) i32 {
        return verve_json_len(self.handle);
    }

    pub fn kind(self: JsonDoc) Kind {
        return @enumFromInt(verve_json_kind(self.handle));
    }

    pub fn int(self: JsonDoc) i64 {
        return verve_json_i64(self.handle);
    }

    pub fn float(self: JsonDoc) f64 {
        return verve_json_f64(self.handle);
    }

    pub fn boolean(self: JsonDoc) bool {
        return verve_json_bool(self.handle) != 0;
    }

    pub fn strLen(self: JsonDoc) u32 {
        return verve_json_str_len(self.handle);
    }

    /// Copy the string value into `buf`, returning the filled slice
    /// (truncated to `buf.len`).
    pub fn str(self: JsonDoc, buf: []u8) []const u8 {
        const wrote = verve_json_str(self.handle, buf.ptr, @intCast(buf.len));
        return buf[0..wrote];
    }

    /// Release this handle. On a root, frees the whole parse tree.
    pub fn free(self: JsonDoc) void {
        verve_json_free(self.handle);
    }
};

/// Parse `bytes` (JSON) into the shared table. Null on parse failure or
/// a full table. Call `.free()` on the returned root when done.
pub fn parseJson(bytes: []const u8) ?JsonDoc {
    const h = verve_json_parse(bytes.ptr, @intCast(bytes.len));
    return if (h == 0) null else .{ .handle = h };
}

/// Read a whole `Reply` value off a `JsonDoc`. Scalars (int/float/bool)
/// read directly; `[]const u8` and slice fields are allocated from
/// `gpa`; nested structs and optionals recurse. The chunk owns the
/// allocations — pass a per-dispatch arena (e.g. a `FixedBufferAllocator`
/// over chunk scratch; `chunkArena` in a later phase).
pub fn readStruct(comptime Reply: type, doc: JsonDoc, gpa: std.mem.Allocator) !Reply {
    return readValue(Reply, doc.handle, gpa);
}

fn readValue(comptime T: type, handle: u32, gpa: std.mem.Allocator) anyerror!T {
    switch (@typeInfo(T)) {
        .int => return @intCast(verve_json_i64(handle)),
        .float => return @floatCast(verve_json_f64(handle)),
        .bool => return verve_json_bool(handle) != 0,
        .optional => |o| {
            const k = verve_json_kind(handle);
            // missing key (handle 0 → invalid), JSON null, or bad handle
            // all collapse to a Zig null.
            if (handle == 0 or k == 0 or k == 0xFFFFFFFF) return null;
            return try readValue(o.child, handle, gpa);
        },
        .@"struct" => |s| {
            var out: T = undefined;
            inline for (s.fields) |f| {
                const child = verve_json_get(handle, f.name.ptr, @intCast(f.name.len));
                @field(out, f.name) = try readValue(f.type, child, gpa);
            }
            return out;
        },
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                const n = verve_json_str_len(handle);
                const buf = try gpa.alloc(u8, n);
                _ = verve_json_str(handle, buf.ptr, n);
                return buf;
            }
            if (p.size == .slice) {
                const count = verve_json_len(handle);
                const n: usize = if (count < 0) 0 else @intCast(count);
                const arr = try gpa.alloc(p.child, n);
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    arr[i] = try readValue(p.child, verve_json_at(handle, i), gpa);
                }
                return arr;
            }
            @compileError("readStruct: unsupported pointer type " ++ @typeName(T));
        },
        else => @compileError("readStruct: unsupported field type " ++ @typeName(T)),
    }
}

// ---- Current-event accessors (Phase 18) ---------------------------------
//
// Call these from inside a closure event handler (registered via
// `registerEvent` + a `z-on-<event>-id` stamp). They read the event the
// bridge staged just before invoking the handler.

/// Modifier keys held during the current event.
pub const Mods = packed struct(u32) {
    meta: bool = false,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    _pad: u28 = 0,
};

pub fn eventMods() Mods {
    return @bitCast(verve_event_mods());
}

/// The `key` value (e.g. "k", "Enter", "ArrowDown") copied into `buf`.
pub fn eventKey(buf: []u8) []const u8 {
    const n = verve_event_key(buf.ptr, @intCast(buf.len));
    return buf[0..n];
}

pub fn eventCoordX() f64 {
    return verve_event_coord_x();
}

pub fn eventCoordY() f64 {
    return verve_event_coord_y();
}

/// Wheel `deltaY` for the current event (valid inside a wheel handler).
pub fn eventDeltaY() f64 {
    return verve_event_delta_y();
}

/// Pointer `button` for the current event (-1 when none).
pub fn eventButton() i32 {
    return verve_event_button();
}

/// A `data-*` attribute of the element the handler was stamped on,
/// copied into `buf` (camelCase key, matching JS `dataset`: `data-pin-id`
/// → "pinId"). Empty when absent.
pub fn eventTargetAttr(name: []const u8, buf: []u8) []const u8 {
    const n = verve_event_target_attr(name.ptr, @intCast(name.len), buf.ptr, @intCast(buf.len));
    return buf[0..n];
}

/// Suppress the browser default for this event (honored after the
/// handler returns).
pub fn eventPreventDefault() void {
    verve_event_prevent_default();
}

pub fn eventStopPropagation() void {
    verve_event_stop_propagation();
}

/// Capture the pointer to the handler's element so the gesture keeps
/// receiving pointermove/up after the pointer leaves it (honored after
/// the handler returns; released implicitly on pointerup).
pub fn eventCapturePointer() void {
    verve_event_capture_pointer();
}

/// Pure viz math for chunks: geometry (`fitBox`/`applyFit`), the layout
/// algorithms (tree/radial/force/dag), interaction math, and edge-path
/// builders — the exact code SSR runs, so client recomputes reproduce server
/// positions bit-for-bit.
pub const viz_core = @import("viz_core");

// ---- Animation (verve.anim) ----------------------------------------------
//
// Pure descriptor builders come from `anim_core` (src/core/anim/
// client_core.zig); this section is the bridge glue. Build tweens /
// timelines in the chunk arena, hand them to `animPlay`, control via the
// returned `AnimHandle`. The JS interpreter copies the descriptor at the
// `verve_anim_create` boundary, so the arena can be reset immediately
// after — handles and callback slot ids are plain u32s, safe to stash in
// chunk statics. Callback handlers must not capture arena pointers (they
// fire after any reset).

/// Tween/Timeline builders, easing, stagger math, and math utils
/// (`anim.to`, `anim.from`, `anim.timeline`, `anim.clamp`, ...).
pub const anim = @import("anim_core");

// ---- 3D / GL (verve.gl) --------------------------------------------------
//
// Pure math/scene/command/mesh engine. Island chunks import it as
// `const gl = verve.gl;` and use it to build scenes + encode binary
// command streams that the bridge's WebGL2 interpreter executes.

/// Math (Vec3/Quat/Mat4), scene graph, binary command encoder, unit cube.
pub const gl = @import("gl_core");

extern "verve_runtime" fn verve_anim_create(desc_ptr: [*]const u8, desc_len: u32) u32;
extern "verve_runtime" fn verve_anim_ctrl(handle: u32, op: u32, value: f64) void;
extern "verve_runtime" fn verve_anim_get(handle: u32, field: u32) f64;
extern "verve_runtime" fn verve_anim_lookup(name_ptr: [*]const u8, name_len: u32) u32;
extern "verve_runtime" fn verve_anim_seek_label(handle: u32, name_ptr: [*]const u8, name_len: u32) void;
// Dyn-value / fn-modifier registration: the chunk passes its PRIVATE-table
// fn index; the bridge's makeChunkRuntime wrapper copies the funcref into
// the main table and returns the slot — only translated slots are safe to
// embed in descriptor JSON (same hazard as registerEvent).
extern "verve_runtime" fn verve_anim_register_dyn(handler_idx: u32) u32;
extern "verve_runtime" fn verve_anim_register_mod(handler_idx: u32) u32;
extern "verve_runtime" fn verve_anim_register_setter(idx: u32) u32;
extern "verve_runtime" fn verve_anim_register_gl_resolver(idx: u32) u32;
extern "verve_runtime" fn verve_ref_set_style(handle: i32, name_ptr: [*]const u8, name_len: u32, val_ptr: [*]const u8, val_len: u32) void;

/// Live animation handle. Plain u32 id into the bridge registry — copy
/// freely, store in chunk statics across frames. All ops are no-ops on a
/// killed/unknown handle.
pub const AnimHandle = struct {
    id: u32,

    pub fn play(self: AnimHandle) void {
        verve_anim_ctrl(self.id, 0, 0);
    }
    pub fn pause(self: AnimHandle) void {
        verve_anim_ctrl(self.id, 1, 0);
    }
    pub fn reverse(self: AnimHandle) void {
        verve_anim_ctrl(self.id, 2, 0);
    }
    pub fn restart(self: AnimHandle) void {
        verve_anim_ctrl(self.id, 3, 0);
    }
    pub fn seek(self: AnimHandle, t_s: f64) void {
        verve_anim_ctrl(self.id, 4, t_s);
    }
    pub fn seekLabel(self: AnimHandle, label: []const u8) void {
        verve_anim_seek_label(self.id, label.ptr, @intCast(label.len));
    }
    pub fn timeScale(self: AnimHandle, factor: f64) void {
        verve_anim_ctrl(self.id, 5, factor);
    }
    /// Remove from the registry; last-written styles stay in place
    /// (GSAP semantics). Pending callbacks never fire.
    pub fn kill(self: AnimHandle) void {
        verve_anim_ctrl(self.id, 6, 0);
    }

    pub fn time(self: AnimHandle) f64 {
        return verve_anim_get(self.id, 0);
    }
    /// 0..1 across the full duration. 0 for infinite animations.
    pub fn progress(self: AnimHandle) f64 {
        return verve_anim_get(self.id, 1);
    }
    /// Total seconds; -1 when infinite (repeat(-1)).
    pub fn duration(self: AnimHandle) f64 {
        return verve_anim_get(self.id, 2);
    }
    pub fn isActive(self: AnimHandle) bool {
        return verve_anim_get(self.id, 3) != 0;
    }
    pub fn currentTimeScale(self: AnimHandle) f64 {
        return verve_anim_get(self.id, 4);
    }
    pub fn isReversed(self: AnimHandle) bool {
        return verve_anim_get(self.id, 5) != 0;
    }
};

fn animSerialize(a: anytype) ?[]const u8 {
    const T = @TypeOf(a.*);
    const alloc = chunkArena();
    if (T == anim.Tween) {
        return anim.serialize.tweenToJson(alloc, a, .island) catch null;
    } else if (T == anim.Timeline) {
        return anim.serialize.timelineToJson(alloc, a, .island) catch null;
    } else {
        @compileError("animPlay/animPrepare expect *anim.Tween or *anim.Timeline, got *" ++ @typeName(T));
    }
}

/// Serialize `a` (`*anim.Tween` or `*anim.Timeline`) and register it with
/// the JS interpreter, autoplaying unless the builder was `.paused()`.
/// Returns null on builder error, serialize failure, or zero matched
/// targets. The descriptor is copied JS-side before this returns.
pub fn animPlay(a: anytype) ?AnimHandle {
    const json = animSerialize(a) orelse return null;
    const h = verve_anim_create(json.ptr, @intCast(json.len));
    if (h == 0) return null;
    return .{ .id = h };
}

/// Like `animPlay` but constructed paused — call `.play()` on the handle.
pub fn animPrepare(a: anytype) ?AnimHandle {
    a.autoplay = false;
    return animPlay(a);
}

/// Resolve a named animation (`.named("intro")` — including SSR-declared
/// `data-anim` ones) to a control handle.
pub fn animLookup(name: []const u8) ?AnimHandle {
    const h = verve_anim_lookup(name.ptr, @intCast(name.len));
    if (h == 0) return null;
    return .{ .id = h };
}

/// Callback sugar: register `handler` as an event slot and stamp it on
/// the builder. Works on `*anim.Tween` and (onComplete) `*anim.Timeline`.
pub fn animOnStart(t: *anim.Tween, handler: *const fn () void) *anim.Tween {
    return t.onStartSlot(registerEvent(handler));
}

pub fn animOnComplete(t: anytype, handler: *const fn () void) @TypeOf(t) {
    return t.onCompleteSlot(registerEvent(handler));
}

pub fn animOnRepeat(t: *anim.Tween, handler: *const fn () void) *anim.Tween {
    return t.onRepeatSlot(registerEvent(handler));
}

/// Dynamic end value: `f(target_index, target_count)` is evaluated
/// per-target when the tween starts. Use as any prop value:
/// `t.x(verve.animDyn(&cardX))`. Pure functions only — runs outside any
/// island scope.
pub fn animDyn(f: *const fn (u32, u32) f64) anim.Value {
    return .{ .dyn = verve_anim_register_dyn(@intCast(@intFromPtr(f))) };
}

/// Per-frame fn modifier on `prop`: receives the interpolated value,
/// returns the value to write. `t.modifier(verve.animModFn("y", &snapY))`.
pub fn animModFn(prop: []const u8, f: *const fn (f64) f64) anim.Modifier {
    return .{ .prop = prop, .op = .{ .dyn = verve_anim_register_mod(@intCast(@intFromPtr(f))) } };
}

/// Register a gl-value setter `fn(target_id, value)` for gl-target tweens
/// (Tween.glTarget). Returns the translated indirect-table slot to pass as
/// `setter_slot`. Mirror of animDyn/animModFn.
pub fn animGlSetter(f: *const fn (u32, f64) void) u32 {
    return verve_anim_register_setter(@intCast(@intFromPtr(f)));
}

/// Register a deferred-target resolver `fn(placeholder_id, name_hash) u32` for
/// SSR `material:`/`node:` gl tweens. The bridge calls it once per deferred
/// target to map name_hash → submesh index (returning a frozen id), then caches
/// the result. Returns 0 when the mesh isn't loaded or the name is absent — the
/// bridge skips the write and retries next tick. Mirror of animGlSetter.
pub fn animGlResolver(f: *const fn (u32, u32) u32) u32 {
    return verve_anim_register_gl_resolver(@intCast(@intFromPtr(f)));
}

// ---- ScrollTrigger / Observer (verve.anim phase 2) -------------------------
//
// ScrollTrigger config rides the animation descriptor ("sc" key) for
// tweens/timelines played via `animPlay` — the AnimHandle controls both,
// and killing the animation kills its trigger. The standalone form below
// is for triggers with no animation (callbacks / class toggles).

extern "verve_runtime" fn verve_sc_create(desc_ptr: [*]const u8, desc_len: u32) u32;
// op: 0 kill, 1 refresh (handle 0 = refresh ALL), 2 disable, 3 enable
extern "verve_runtime" fn verve_sc_ctrl(handle: u32, op: u32) void;
// field: 0 progress, 1 active, 2 direction, 3 scroll velocity (px/s)
extern "verve_runtime" fn verve_sc_get(handle: u32, field: u32) f64;
extern "verve_runtime" fn verve_scroll_pos(axis: u32) f64; // 0 x, 1 y
// Observer handler crosses as a chunk-private fn-table index; the
// bridge's makeChunkRuntime wrapper copies the funcref into the main
// table (timers precedent).
extern "verve_runtime" fn verve_obs_create(flags: u32, tolerance: f64, sel_ptr: [*]const u8, sel_len: u32, handler_idx: u32) u32;
// op: 0 kill, 1 disable, 2 enable
extern "verve_runtime" fn verve_obs_ctrl(handle: u32, op: u32) void;
// field: 0 dx, 1 dy, 2 vx, 3 vy, 4 dirX, 5 dirY, 6 dragging,
//        7 kind (0 wheel, 1 touch, 2 pointer, 3 scroll)
extern "verve_runtime" fn verve_obs_get(handle: u32, field: u32) f64;

/// Live standalone scroll-trigger handle. Plain u32 id — safe in chunk
/// statics; all ops no-op on a killed/unknown handle.
pub const ScrollTriggerHandle = struct {
    id: u32,

    pub fn kill(self: ScrollTriggerHandle) void {
        verve_sc_ctrl(self.id, 0);
    }
    /// Re-measure this trigger's geometry (after layout-changing DOM work).
    pub fn refresh(self: ScrollTriggerHandle) void {
        verve_sc_ctrl(self.id, 1);
    }
    pub fn disable(self: ScrollTriggerHandle) void {
        verve_sc_ctrl(self.id, 2);
    }
    pub fn enable(self: ScrollTriggerHandle) void {
        verve_sc_ctrl(self.id, 3);
    }
    /// 0..1 through the start..end range (clamped).
    pub fn progress(self: ScrollTriggerHandle) f64 {
        return verve_sc_get(self.id, 0);
    }
    pub fn isActive(self: ScrollTriggerHandle) bool {
        return verve_sc_get(self.id, 1) != 0;
    }
    /// +1 scrolling down, -1 scrolling up.
    pub fn direction(self: ScrollTriggerHandle) f64 {
        return verve_sc_get(self.id, 2);
    }
    /// Page scroll velocity, px/s (decays after scrolling stops).
    pub fn velocity(self: ScrollTriggerHandle) f64 {
        return verve_sc_get(self.id, 3);
    }
};

/// Lifecycle callbacks for scroll triggers. Registered as event slots
/// (same translation as `registerEvent`); handlers must not capture
/// chunk-arena pointers.
pub const ScrollCallbacks = struct {
    on_enter: ?*const fn () void = null,
    on_leave: ?*const fn () void = null,
    on_enter_back: ?*const fn () void = null,
    on_leave_back: ?*const fn () void = null,
    /// Fires each scroll tick while inside the range; read progress /
    /// velocity via the handle.
    on_update: ?*const fn () void = null,
};

fn stampScrollSlots(sc: *anim.ScrollTrigger, cbs: ScrollCallbacks) void {
    if (cbs.on_enter) |f| sc.on_enter_slot = registerEvent(f);
    if (cbs.on_leave) |f| sc.on_leave_slot = registerEvent(f);
    if (cbs.on_enter_back) |f| sc.on_enter_back_slot = registerEvent(f);
    if (cbs.on_leave_back) |f| sc.on_leave_back_slot = registerEvent(f);
    if (cbs.on_update) |f| sc.on_update_slot = registerEvent(f);
}

/// Stamp scroll callbacks onto a builder's existing `.scrollTrigger(...)`
/// config. Works on `*anim.Tween` and `*anim.Timeline`. Deferred
/// `error.ScrollTriggerNotSet` when no trigger was configured.
pub fn scrollCallbacks(t: anytype, cbs: ScrollCallbacks) @TypeOf(t) {
    if (t.err != null) return t;
    if (t.scroll_trigger == null) {
        t.err = error.ScrollTriggerNotSet;
        return t;
    }
    stampScrollSlots(&t.scroll_trigger.?, cbs);
    return t;
}

/// Standalone scroll trigger with no animation attached:
/// `verve.scrollTrigger(.{ .trigger = "#sec" }, .{ .on_enter = &onEnter })`.
/// Returns null on validation/serialize failure or missing trigger element.
pub fn scrollTrigger(cfg: anim.ScrollTrigger, cbs: ScrollCallbacks) ?ScrollTriggerHandle {
    var c = cfg;
    stampScrollSlots(&c, cbs);
    const a = chunkArena();
    const trig = anim.scroll.trigger(a, c);
    const json = anim.serialize.triggerToJson(a, trig, .island) catch return null;
    const h = verve_sc_create(json.ptr, @intCast(json.len));
    if (h == 0) return null;
    return .{ .id = h };
}

/// Re-measure ALL trigger geometry (after layout-changing DOM work).
pub fn scrollRefresh() void {
    verve_sc_ctrl(0, 1);
}

/// Current page scroll position, px.
pub fn scrollPos() f64 {
    return verve_scroll_pos(1);
}

pub fn scrollPosX() f64 {
    return verve_scroll_pos(0);
}

/// Observer config — unified wheel/touch/pointer/scroll input detection
/// with velocity tracking. One onChange handler; read values via
/// `ObserverHandle` getters.
pub const ObserverConfig = struct {
    /// CSS selector to observe; null = the whole window.
    target: ?[]const u8 = null,
    wheel: bool = false,
    touch: bool = false,
    pointer: bool = false,
    scroll: bool = false,
    /// Force non-passive listeners and call preventDefault — suppresses
    /// native scrolling (the future ScrollSmoother path). Careful: this
    /// also suppresses the page scroll ScrollTriggers depend on.
    prevent_default: bool = false,
    /// Restrict deltas to the dominant axis once a gesture commits.
    lock_axis: bool = false,
    /// Minimum accumulated px before the handler starts firing.
    tolerance: f64 = 0,

    fn flags(self: ObserverConfig) u32 {
        var f: u32 = 0;
        if (self.wheel) f |= 1;
        if (self.touch) f |= 2;
        if (self.pointer) f |= 4;
        if (self.scroll) f |= 8;
        if (self.prevent_default) f |= 16;
        if (self.lock_axis) f |= 32;
        return f;
    }
};

pub const ObserverHandle = struct {
    id: u32,

    pub fn kill(self: ObserverHandle) void {
        verve_obs_ctrl(self.id, 0);
    }
    pub fn disable(self: ObserverHandle) void {
        verve_obs_ctrl(self.id, 1);
    }
    pub fn enable(self: ObserverHandle) void {
        verve_obs_ctrl(self.id, 2);
    }
    pub fn deltaX(self: ObserverHandle) f64 {
        return verve_obs_get(self.id, 0);
    }
    pub fn deltaY(self: ObserverHandle) f64 {
        return verve_obs_get(self.id, 1);
    }
    pub fn velocityX(self: ObserverHandle) f64 {
        return verve_obs_get(self.id, 2);
    }
    pub fn velocityY(self: ObserverHandle) f64 {
        return verve_obs_get(self.id, 3);
    }
    /// +1 / -1 / 0 (no horizontal movement yet).
    pub fn dirX(self: ObserverHandle) f64 {
        return verve_obs_get(self.id, 4);
    }
    pub fn dirY(self: ObserverHandle) f64 {
        return verve_obs_get(self.id, 5);
    }
    pub fn isDragging(self: ObserverHandle) bool {
        return verve_obs_get(self.id, 6) != 0;
    }
    pub const Kind = enum(u32) { wheel = 0, touch = 1, pointer = 2, scroll = 3 };
    /// Input kind of the most recent delta.
    pub fn kind(self: ObserverHandle) Kind {
        return @enumFromInt(@as(u32, @intFromFloat(verve_obs_get(self.id, 7))));
    }
};

/// Unified input observer. `handler` fires on every accepted delta; read
/// the values through the returned handle. Returns null when the target
/// selector matches nothing.
pub fn observe(cfg: ObserverConfig, handler: *const fn () void) ?ObserverHandle {
    const sel = cfg.target orelse "";
    const h = verve_obs_create(
        cfg.flags(),
        cfg.tolerance,
        sel.ptr,
        @intCast(sel.len),
        @intCast(@intFromPtr(handler)),
    );
    if (h == 0) return null;
    return .{ .id = h };
}

// ---- Draggable (verve.anim phase 4) ----------------------------------------
//
// Drag config rides its own descriptor ("dr" key; `data-drag` on SSR).
// The JS engine owns pointer capture, the state machine, inertia
// integration, and snap resolution; read live position/velocity via
// verve_drag_get. NOT the Phase-22 file-drop machinery (registerDrop).

extern "verve_runtime" fn verve_drag_create(desc_ptr: [*]const u8, desc_len: u32) u32;
// op: 0 kill, 1 disable (cancels active drag/throw), 2 enable,
//     3 setPos (x/y args; unclamped — bounds resolve per-gesture)
extern "verve_runtime" fn verve_drag_ctrl(handle: u32, op: u32, x: f64, y: f64) void;
// field: 0 x, 1 y, 2 vx, 3 vy, 4 dragging, 5 throwing
extern "verve_runtime" fn verve_drag_get(handle: u32, field: u32) f64;

/// Live draggable handle. Plain u32 id — safe in chunk statics; all ops
/// no-op on a killed/unknown handle.
pub const DragHandle = struct {
    id: u32,

    pub fn kill(self: DragHandle) void {
        verve_drag_ctrl(self.id, 0, 0, 0);
    }
    /// Cancels any active drag/throw and ignores pointers until enable.
    pub fn disable(self: DragHandle) void {
        verve_drag_ctrl(self.id, 1, 0, 0);
    }
    pub fn enable(self: DragHandle) void {
        verve_drag_ctrl(self.id, 2, 0, 0);
    }
    /// Programmatic position (translate-space px). Unclamped — bounds
    /// only constrain pointer gestures and throws.
    pub fn setPos(self: DragHandle, px: f64, py: f64) void {
        verve_drag_ctrl(self.id, 3, px, py);
    }

    /// Current translate offset, px.
    pub fn x(self: DragHandle) f64 {
        return verve_drag_get(self.id, 0);
    }
    pub fn y(self: DragHandle) f64 {
        return verve_drag_get(self.id, 1);
    }
    /// Pointer/throw velocity, px/s.
    pub fn velocityX(self: DragHandle) f64 {
        return verve_drag_get(self.id, 2);
    }
    pub fn velocityY(self: DragHandle) f64 {
        return verve_drag_get(self.id, 3);
    }
    pub fn isDragging(self: DragHandle) bool {
        return verve_drag_get(self.id, 4) != 0;
    }
    pub fn isThrowing(self: DragHandle) bool {
        return verve_drag_get(self.id, 5) != 0;
    }
    /// Zone index from the last release (-1 = none). Note: a dead handle
    /// also reads 0, ambiguous with zone 0 (getter ABI wart).
    pub fn dropZone(self: DragHandle) i32 {
        return @intFromFloat(verve_drag_get(self.id, 6));
    }
    /// Zone index under the pointer while dragging (-1 = none).
    pub fn hoverZone(self: DragHandle) i32 {
        return @intFromFloat(verve_drag_get(self.id, 7));
    }
};

/// Drag lifecycle callbacks. Registered as event slots (same translation
/// as registerEvent); handlers must not capture chunk-arena pointers.
pub const DragCallbacks = struct {
    on_start: ?*const fn () void = null,
    /// Fires per move tick; read position/velocity via the handle.
    on_drag: ?*const fn () void = null,
    on_end: ?*const fn () void = null,
    /// Fires when an inertia throw settles (requires .inertia).
    on_throw_complete: ?*const fn () void = null,
    /// Fires on release over a drop zone (requires .zones); read the
    /// index via `DragHandle.dropZone()`.
    on_drop: ?*const fn () void = null,
};

fn stampDragSlots(dr: *anim.Draggable, cbs: DragCallbacks) void {
    if (cbs.on_start) |f| dr.on_start_slot = registerEvent(f);
    if (cbs.on_drag) |f| dr.on_drag_slot = registerEvent(f);
    if (cbs.on_end) |f| dr.on_end_slot = registerEvent(f);
    if (cbs.on_throw_complete) |f| dr.on_throw_complete_slot = registerEvent(f);
    if (cbs.on_drop) |f| dr.on_drop_slot = registerEvent(f);
}

/// Imperative draggable:
/// `verve.draggable(.{ .target = "#card", .inertia = .on }, .{ .on_end = &f })`.
/// The island surface requires an explicit target (selector or ref
/// handle) — there is no carrying node. Returns null on validation /
/// serialize failure or zero matched elements.
pub fn draggable(cfg: anim.Draggable, cbs: DragCallbacks) ?DragHandle {
    if (cfg.target == null and cfg.target_handle == null) return null;
    var c = cfg;
    stampDragSlots(&c, cbs);
    const a = chunkArena();
    const d = anim.drag.draggable(a, c);
    const json = anim.serialize.dragToJson(a, d, .island) catch return null;
    const h = verve_drag_create(json.ptr, @intCast(json.len));
    if (h == 0) return null;
    return .{ .id = h };
}

// ---- Sortable (verve.anim Sortable) ----------------------------------------
// JS engine owns the pointer machine, slot computation, FLIP preview, and
// DOM reorder; the island surface registers callbacks and gets a handle.

extern "verve_runtime" fn verve_sortable_create(desc_ptr: [*]const u8, desc_len: u32) u32;
// op: 0 kill, 1 disable, 2 enable
extern "verve_runtime" fn verve_sortable_ctrl(handle: u32, op: u32) void;
// field: 0 lastFrom, 1 lastTo (-1 = never reordered),
//        2 lastFromGroup handle (-1 = no group / same-list),
//        3 lastToGroup handle (-1 = no group / same-list)
extern "verve_runtime" fn verve_sortable_get(handle: u32, field: u32) i32;

/// Live sortable handle. Plain u32 id — safe in chunk statics.
pub const SortableHandle = struct {
    id: u32,

    pub fn kill(self: SortableHandle) void {
        verve_sortable_ctrl(self.id, 0);
    }
    pub fn disable(self: SortableHandle) void {
        verve_sortable_ctrl(self.id, 1);
    }
    pub fn enable(self: SortableHandle) void {
        verve_sortable_ctrl(self.id, 2);
    }

    /// Original index of the item before the last reorder (-1 if none yet).
    pub fn lastFrom(self: SortableHandle) i32 {
        return verve_sortable_get(self.id, 0);
    }

    /// Final index of the item after the last reorder (-1 if none yet).
    pub fn lastTo(self: SortableHandle) i32 {
        return verve_sortable_get(self.id, 1);
    }

    /// Sortable handle id of the source container in the last cross-list
    /// reorder (-1 if no group configured or no reorder yet).
    pub fn fromContainer(self: SortableHandle) i32 {
        return verve_sortable_get(self.id, 2);
    }

    /// Sortable handle id of the target container in the last cross-list
    /// reorder (-1 if no group configured or no reorder yet).
    pub fn toContainer(self: SortableHandle) i32 {
        return verve_sortable_get(self.id, 3);
    }
};

/// Sortable lifecycle callbacks. Registered as event slots.
pub const SortableCallbacks = struct {
    /// Fires on settle after a reorder. Read current DOM order in the handler.
    on_reorder: ?*const fn () void = null,
    /// Fires when the dragged item enters a new group container.
    /// Requires `group` to be set on the Sortable config.
    on_enter_group: ?*const fn () void = null,
};

fn stampSortableSlots(so: *anim.sortable_mod.Sortable, cbs: SortableCallbacks) void {
    if (cbs.on_reorder) |f| so.on_reorder_slot = registerEvent(f);
    if (cbs.on_enter_group) |f| so.on_enter_group_slot = registerEvent(f);
}

/// Escape `"` and `\` in `s` for embedding in a JSON string value.
/// Allocates from `a`; returns the escaped slice.
fn jsonEscapeStr(a: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]u8 {
    var extra: usize = 0;
    for (s) |c| if (c == '"' or c == '\\') {
        extra += 1;
    };
    if (extra == 0) return a.dupe(u8, s);
    var out = try a.alloc(u8, s.len + extra);
    var i: usize = 0;
    for (s) |c| {
        if (c == '"' or c == '\\') {
            out[i] = '\\';
            i += 1;
        }
        out[i] = c;
        i += 1;
    }
    return out;
}

/// Imperative sortable:
/// `verve.sortable("#my-list", .{ .items = "li" }, .{ .on_reorder = &f })`.
/// `container_sel` is a CSS selector for the container element.
/// Returns null on validation / serialize failure.
pub fn sortable(container_sel: []const u8, cfg: anim.Sortable, cbs: SortableCallbacks) ?SortableHandle {
    var c = cfg;
    stampSortableSlots(&c, cbs);
    const a = chunkArena();
    const s = anim.sortable_mod.sortable(a, c);
    // Build descriptor with container selector in "ct"."s".
    // Format: {"v":1,"ct":{"s":"<selector>"},"so":{...}}
    // Produces sortable JSON {"v":1,"so":{...}}, then splices in "ct":{"s":"<sel>"},
    // by concatenating slices — no allocPrint (forbidden on wasm32-freestanding).
    const inner = anim.serialize.sortableToJson(a, s, .island) catch return null;
    // inner is {"v":1,"so":{...}} — find the "so" key splice point.
    const so_pos = std.mem.indexOf(u8, inner, ",\"so\"") orelse return null;
    // Escape `"` and `\` in the selector to produce valid JSON.
    const sel_escaped = jsonEscapeStr(a, container_sel) catch return null;
    // Build: {"v":1,"ct":{"s":"<sel>"},"so":{...}}
    const json = std.mem.concat(a, u8, &.{
        "{\"v\":1,\"ct\":{\"s\":\"",
        sel_escaped,
        "\"}",
        inner[so_pos..],
    }) catch return null;
    const h = verve_sortable_create(json.ptr, @intCast(json.len));
    if (h == 0) return null;
    return .{ .id = h };
}

// ---- ScrollSmoother (verve.anim phase 6) -----------------------------------
//
// The smoother is a page singleton authored via Node.smoothScroll();
// islands get read-only access. No create/kill ops — lifecycle belongs
// to the page markup; geometry refresh rides scrollRefresh().
// field: 0 smoothed y (native scrollY fallback when no smoother),
//        1 smoothed velocity px/s, 2 active (1 = installed)
extern "verve_runtime" fn verve_sm_get(field: u32) f64;

/// Smoothed scroll position, px (== native scrollY when no smoother).
pub fn smootherY() f64 {
    return verve_sm_get(0);
}

/// Smoothed scroll velocity, px/s.
pub fn smootherVelocity() f64 {
    return verve_sm_get(1);
}

/// True when a ScrollSmoother is installed on this page.
pub fn smootherActive() bool {
    return verve_sm_get(2) != 0;
}

// ---- FLIP (verve.anim phase 5) ----------------------------------------------
//
// First-Last-Invert-Play layout animation. Island-only — capture rects,
// mutate the DOM (listDiff, signals, manual moves), then play; the JS
// engine matches elements (identity, then data-vkey), inverts via the
// shared transform composer, and eases to identity in the ticker.
// Under prefers-reduced-motion, play is a no-op that fires on_complete.

extern "verve_runtime" fn verve_flip_capture(sel_ptr: [*]const u8, sel_len: u32) u32;
extern "verve_runtime" fn verve_flip_play(state: u32, desc_ptr: [*]const u8, desc_len: u32) u32;
extern "verve_runtime" fn verve_flip_discard(state: u32) void;
// op: 0 kill (snap to identity, no callback)
extern "verve_runtime" fn verve_flip_ctrl(handle: u32, op: u32) void;

/// One-shot layout snapshot. Consumed by `flipPlay`; `discard()` when
/// abandoned (entries hold element refs JS-side).
pub const FlipState = struct {
    id: u32,

    pub fn discard(self: FlipState) void {
        verve_flip_discard(self.id);
    }
};

/// Live flip handle. Ops no-op once settled.
pub const FlipHandle = struct {
    id: u32,

    /// Snap remaining elements to identity; callbacks do NOT fire.
    pub fn kill(self: FlipHandle) void {
        verve_flip_ctrl(self.id, 0);
    }
};

pub const FlipCallbacks = struct {
    /// Fires once when every element (including stagger tails) settles —
    /// also fires immediately under reduced motion or when nothing moved.
    on_complete: ?*const fn () void = null,
    /// Fires once per play when elements exist that weren't captured
    /// (they also fade in when fade_in is set). Runs synchronously
    /// BEFORE flipPlay returns — don't depend on the handle or capture
    /// arena pointers.
    on_enter: ?*const fn () void = null,
    /// Fires once per play when captured elements are gone. Same
    /// synchronous-before-return contract as on_enter.
    on_leave: ?*const fn () void = null,
};

/// Snapshot the current layout of every element matching `selector`.
pub fn flipCapture(selector: []const u8) ?FlipState {
    const h = verve_flip_capture(selector.ptr, @intCast(selector.len));
    if (h == 0) return null;
    return .{ .id = h };
}

/// Animate from the captured layout to the current one. Always consumes
/// `state`. Returns null when nothing animates (callbacks still fire).
pub fn flipPlay(state: FlipState, opts: anim.FlipOpts, cbs: FlipCallbacks) ?FlipHandle {
    var buf: [192]u8 = undefined;
    const slots: anim.flip.FlipSlots = .{
        .complete = if (cbs.on_complete) |f| registerEvent(f) else null,
        .enter = if (cbs.on_enter) |f| registerEvent(f) else null,
        .leave = if (cbs.on_leave) |f| registerEvent(f) else null,
    };
    const json = anim.flip.optsToJson(&buf, opts, slots) catch {
        verve_flip_discard(state.id);
        return null;
    };
    const h = verve_flip_play(state.id, json.ptr, @intCast(json.len));
    if (h == 0) return null;
    return .{ .id = h };
}

// ---- Timers (Phase 19) --------------------------------------------------
//
// Handlers are `*const fn () void` taken via `&handler` — the same
// shared-table convention as `registerEvent`. Each scheduling call
// returns an id for `clearTimer`. The handler runs in chunk code via the
// shared indirect function table.

/// Run `handler` once after `ms` milliseconds. Returns a cancel id.
pub fn setTimeout(ms: u32, handler: *const fn () void) u32 {
    return verve_set_timeout(ms, @intCast(@intFromPtr(handler)));
}

/// Run `handler` every `ms` milliseconds until cleared. Returns a cancel id.
pub fn setInterval(ms: u32, handler: *const fn () void) u32 {
    return verve_set_interval(ms, @intCast(@intFromPtr(handler)));
}

/// Run `handler` on the next animation frame. Returns a cancel id.
pub fn requestAnimationFrame(handler: *const fn () void) u32 {
    return verve_request_animation_frame(@intCast(@intFromPtr(handler)));
}

/// Run `handler` as a microtask (after the current call stack unwinds).
pub fn queueMicrotask(handler: *const fn () void) void {
    verve_queue_microtask(@intCast(@intFromPtr(handler)));
}

/// Cancel a pending timeout / interval / animation frame by its id.
pub fn clearTimer(id: u32) void {
    verve_clear_timer(id);
}

// ---- localStorage (Phase 19) --------------------------------------------

pub const storage = struct {
    /// Byte length of the stored value, or 0 when absent. Probe before
    /// `get` to size a buffer exactly.
    pub fn len(key: []const u8) u32 {
        return verve_storage_len(key.ptr, @intCast(key.len));
    }

    /// Copy the stored value into `buf`, returning the filled slice
    /// (truncated to `buf.len`; empty when the key is absent).
    pub fn get(key: []const u8, buf: []u8) []const u8 {
        const n = verve_storage_get(key.ptr, @intCast(key.len), buf.ptr, @intCast(buf.len));
        return buf[0..n];
    }

    pub fn set(key: []const u8, value: []const u8) void {
        verve_storage_set(key.ptr, @intCast(key.len), value.ptr, @intCast(value.len));
    }

    pub fn remove(key: []const u8) void {
        verve_storage_remove(key.ptr, @intCast(key.len));
    }
};

// ---- Clipboard (Phase 19) -----------------------------------------------

/// Write `text` to the system clipboard (async; falls back to
/// `execCommand("copy")` where the async API is unavailable).
pub fn clipboardWrite(text: []const u8) void {
    verve_clipboard_write(text.ptr, @intCast(text.len));
}

// ---- Forms + DOM measurement (Phase 20) ---------------------------------

/// Read a form control's `.value` (string) into `buf`. Pair with a
/// `query_ref` handle. Complements the numeric `refValueI32`/`F32`.
pub fn refValueStr(handle: i32, buf: []u8) []const u8 {
    const n = verve_ref_get_value_str(handle, buf.ptr, @intCast(buf.len));
    return buf[0..n];
}

/// Byte length of an attribute value. 0 = missing attribute, stale
/// handle, OR empty value (the storage contract's ambiguity — probe
/// before sizing a buffer, don't treat 0 as proof of absence).
pub fn refAttrLen(handle: i32, name: []const u8) u32 {
    return verve_ref_attr_len(handle, name.ptr, @intCast(name.len));
}

/// Copy an attribute value into `buf` (truncated at capacity); returns
/// the filled slice. Prefer `refGetAttrArena` for unbounded values like
/// SVG path `d` strings — silent truncation corrupts them.
pub fn refGetAttr(handle: i32, name: []const u8, buf: []u8) []const u8 {
    const n = verve_ref_get_attr(handle, name.ptr, @intCast(name.len), buf.ptr, @intCast(buf.len));
    return buf[0..n];
}

/// Probe-then-copy an attribute into an exact-size chunk-arena slice —
/// null when missing/empty. The bytes live until the next arena reset,
/// which is exactly long enough to feed `.morph(.{ .from = current, ... })`
/// through `animPlay` (the bridge copies the descriptor at the boundary).
pub fn refGetAttrArena(handle: i32, name: []const u8) ?[]const u8 {
    const len = refAttrLen(handle, name);
    if (len == 0) return null;
    const buf = chunkArena().alloc(u8, len) catch return null;
    const n = verve_ref_get_attr(handle, name.ptr, @intCast(name.len), buf.ptr, @intCast(buf.len));
    return buf[0..n];
}

/// Submit the form owning this control (`el.form.requestSubmit()`),
/// firing validation + the submit event rather than a raw `.submit()`.
pub fn refRequestSubmit(handle: i32) void {
    verve_ref_request_submit(handle);
}

pub fn refSelect(handle: i32) void {
    verve_ref_select(handle);
}

pub fn refBlur(handle: i32) void {
    verve_ref_blur(handle);
}

pub fn refScrollIntoView(handle: i32) void {
    verve_ref_scroll_into_view(handle);
}

/// A DOM rectangle in CSS pixels (from `getBoundingClientRect`).
pub const Rect = struct { x: f64, y: f64, w: f64, h: f64 };

pub fn refRect(handle: i32) Rect {
    var o: [4]f64 = .{ 0, 0, 0, 0 };
    verve_ref_rect(handle, &o);
    return .{ .x = o[0], .y = o[1], .w = o[2], .h = o[3] };
}

pub const Viewport = struct { w: f64, h: f64 };

pub fn viewport() Viewport {
    var o: [2]f64 = .{ 0, 0 };
    verve_viewport(&o);
    return .{ .w = o[0], .h = o[1] };
}

/// `window.matchMedia(query).matches` — e.g. "(prefers-color-scheme: dark)".
pub fn matchMedia(query: []const u8) bool {
    return verve_match_media(query.ptr, @intCast(query.len)) != 0;
}

/// Serialize the named-field values of a form (located by `[z-bind]` /
/// `[data-vh]`, or the nearest enclosing form) into `buf` as a JSON
/// object. Parse it with `parseJson` / `readStruct` for a typed value.
/// Returns the filled JSON slice.
pub fn formCollect(bind: []const u8, buf: []u8) []const u8 {
    const n = verve_form_collect(bind.ptr, @intCast(bind.len), buf.ptr, @intCast(buf.len));
    return buf[0..n];
}

// ---- Generic JS interop (Phase 21) --------------------------------------
//
// The escape hatch for browser APIs verve doesn't type natively (Intl
// date/number formatting, markdown, syntax highlight, canvas). The app
// registers a JS function in `window.verveHost`; the chunk calls it by
// name with a JSON arg payload and gets a JSON result.

/// Synchronous host call. `args_json` is the JSON arguments ("" or "{}"
/// for none); the JSON result is written to `out` and the filled slice
/// returned (empty when the host fn is missing or threw). Parse the
/// result with `parseJson`. The host fn must be synchronous — use
/// `hostAsync` for one returning a Promise.
pub fn host(name: []const u8, args_json: []const u8, out: []u8) []const u8 {
    const n = verve_host_call(
        name.ptr,
        @intCast(name.len),
        args_json.ptr,
        @intCast(args_json.len),
        out.ptr,
        @intCast(out.len),
    );
    return out[0..n];
}

/// Subscribe `island`'s named export to the server-push channel: every SSE
/// frame on `/push?channel=<channel>` is staged in the island scratch buffer
/// and delivered to `export fn <export_name>(ptr: u32, len: u32) void`
/// (payload valid only for the call). Returns false when the host has no
/// EventSource — fall back to polling.
/// `vid` is the subscribing island's per-instance id (its `root_id` from
/// hydrate). The bridge routes pushed events back to THIS instance via the vid;
/// without it, a page with multiple same-name islands delivers every event to
/// the first DOM match, whose name-keyed signals never match (silent no-repaint).
pub fn pushSubscribe(channel: []const u8, island: []const u8, export_name: []const u8, vid: u32) bool {
    var args_buf: [224]u8 = undefined;
    const args = @import("push.zig").subscribeArgs(&args_buf, channel, island, export_name, vid) orelse return false;
    var out: [64]u8 = undefined;
    const reply = host("vervePush", args, &out);
    return std.mem.indexOf(u8, reply, "\"err\"") == null;
}

pub fn pushUnsubscribe(channel: []const u8, island: []const u8, vid: u32) void {
    var args_buf: [192]u8 = undefined;
    const args = @import("push.zig").unsubscribeArgs(&args_buf, channel, island, vid) orelse return;
    var out: [16]u8 = undefined;
    _ = host("vervePush", args, &out);
}

/// One-shot POST `/api/<api_name>` whose reply text is delivered to
/// `island`'s named export (same staging contract as `pushSubscribe`). The
/// push path's resync hook.
pub fn fetchToExport(api_name: []const u8, island: []const u8, export_name: []const u8, vid: u32) void {
    var args_buf: [216]u8 = undefined;
    const args = std.fmt.bufPrint(
        &args_buf,
        "{{\"api\":\"{s}\",\"island\":\"{s}\",\"export\":\"{s}\",\"vid\":{d}}}",
        .{ api_name, island, export_name, vid },
    ) catch return;
    var out: [16]u8 = undefined;
    _ = host("verveFetchExport", args, &out);
}

/// Fetch a URL's raw bytes into the page-scoped asset region (4 MB bump
/// allocator, NOT the 8 KB island_scratch) and deliver `(ptr, len)` into
/// the WASM linear memory to the named chunk export. Bypasses the 8 KB cap.
/// The bridge scopes `vid` via `verve_enter_island` + `vizcanvas_select`
/// before calling the export, so `current` is set when the export runs.
pub fn fetchBinaryToExport(url: []const u8, island: []const u8, export_name: []const u8, vid: u32) void {
    var args_buf: [256]u8 = undefined;
    const args = std.fmt.bufPrint(
        &args_buf,
        "{{\"url\":\"{s}\",\"island\":\"{s}\",\"export\":\"{s}\",\"vid\":{d}}}",
        .{ url, island, export_name, vid },
    ) catch return;
    var out: [16]u8 = undefined;
    _ = host("verveFetchBinary", args, &out);
}

/// Asynchronous host call. The JSON result fans back to the handler
/// registered for `route` (via `registerResponseHandler`) — same path a
/// server-fn reply takes. Use for host fns that return a Promise.
pub fn hostAsync(name: []const u8, args_json: []const u8, route: []const u8) void {
    verve_host_call_async(
        name.ptr,
        @intCast(name.len),
        args_json.ptr,
        @intCast(args_json.len),
        route.ptr,
        @intCast(route.len),
    );
}

// ---- Chunk-local arena (Phase 22) ---------------------------------------
//
// A `std.mem.Allocator` backed by a bump region in the main client.
// Chunks size buffers to actual data instead of worst-case statics.
// Recycle per dispatch: `const m = chunkArenaMark(); defer chunkArenaReset(m);`.

fn chunkAllocFn(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    const a: u32 = @intCast(alignment.toByteUnits());
    const p = verve_chunk_alloc(@intCast(len), a);
    if (p == 0) return null;
    return @ptrFromInt(@as(usize, p));
}

const chunk_arena_vtable = std.mem.Allocator.VTable{
    .alloc = chunkAllocFn,
    .resize = std.mem.Allocator.noResize,
    .remap = std.mem.Allocator.noRemap,
    .free = std.mem.Allocator.noFree,
};

pub fn chunkArena() std.mem.Allocator {
    return .{ .ptr = undefined, .vtable = &chunk_arena_vtable };
}

/// Save point for `chunkArenaReset` — everything allocated after the
/// returned mark is freed on reset.
pub fn chunkArenaMark() u32 {
    return verve_chunk_arena_mark();
}

pub fn chunkArenaReset(m: u32) void {
    verve_chunk_arena_reset(m);
}

// ---- Asset region (gl GPU assets — page-scoped) -------------------------

/// Frees every fetched gl asset. Call ONLY from the page's single stateful
/// gl island's hydrate() — it owns the page's asset lifetime.
pub fn assetReset() void {
    verve_asset_reset();
}

// ---- Drag-drop (Phase 22) -----------------------------------------------

/// Register a drop zone on the element bound to `bind`. When a file is
/// dropped, its bytes are written into the chunk arena and `handler`
/// fires — read the file inside the handler via `currentDrop`.
pub fn registerDrop(bind: []const u8, handler: *const fn () void) void {
    verve_register_drop(bind.ptr, @intCast(bind.len), @intCast(@intFromPtr(handler)));
}

pub const Drop = struct { name: []const u8, bytes: []const u8 };

/// The most recently dropped file. Call from inside a `registerDrop`
/// handler. `name_buf` receives the file name; `bytes` views the arena
/// allocation holding the file contents (valid until the arena resets).
pub fn currentDrop(name_buf: []u8) Drop {
    const n = verve_drop_name(name_buf.ptr, @intCast(name_buf.len));
    const ptr = verve_drop_ptr();
    const len = verve_drop_len();
    const bytes: []const u8 = if (ptr == 0)
        &.{}
    else
        @as([*]const u8, @ptrFromInt(@as(usize, ptr)))[0..len];
    return .{ .name = name_buf[0..n], .bytes = bytes };
}

// ---- Named templates (G2) -----------------------------------------------
//
// Clone a server-rendered prototype, fill its slots, append into the
// live DOM. Row markup lives in `components.zig` via
// `ctx.template("<name>", inner)`; chunks reach it here.

pub fn cloneTemplate(name: []const u8) ?i32 {
    const h = verve_clone_template(name.ptr, @intCast(name.len));
    return if (h <= 0) null else h;
}

pub fn slotText(handle: i32, slot: []const u8, text: []const u8) void {
    verve_slot_text(
        handle,
        slot.ptr,
        @intCast(slot.len),
        text.ptr,
        @intCast(text.len),
    );
}

pub fn slotAttr(handle: i32, slot: []const u8, attr_name: []const u8, attr_value: []const u8) void {
    verve_slot_attr(
        handle,
        slot.ptr,
        @intCast(slot.len),
        attr_name.ptr,
        @intCast(attr_name.len),
        attr_value.ptr,
        @intCast(attr_value.len),
    );
}

pub fn appendToBind(parent_bind: []const u8, child_handle: i32) void {
    verve_append_to_bind(parent_bind.ptr, @intCast(parent_bind.len), child_handle);
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
///
/// NOTE: unlike signals, `parent_bind` is NOT vid-scoped automatically.
/// For binds inside this island's own markup, suffix the name yourself
/// (`"<bind>__v{d}"` with the `root_id` from hydrate) — the SSR's
/// rewriteBindings stamped the suffixed form on the DOM.
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
