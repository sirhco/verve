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
extern "verve_runtime" fn verve_event_key(buf_ptr: [*]u8, buf_cap: u32) u32;
extern "verve_runtime" fn verve_event_target_attr(
    name_ptr: [*]const u8,
    name_len: u32,
    buf_ptr: [*]u8,
    buf_cap: u32,
) u32;
extern "verve_runtime" fn verve_event_prevent_default() void;
extern "verve_runtime" fn verve_event_stop_propagation() void;

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
                    var buf: [256]u8 = undefined;
                    signalSetStr(name, v.str(&buf));
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
