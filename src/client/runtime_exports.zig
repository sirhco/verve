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

const std = @import("std");
const runtime = @import("runtime.zig");
const dom = @import("dom.zig");
const client_alloc = @import("allocator.zig");
const json_service = @import("json_service.zig");
const event_state = @import("event_state.zig");
const chunk_arena = @import("chunk_arena.zig");
const island = @import("island.zig");
const island_state_client = @import("island_state_client.zig");

// ---- Binding / dispatch scratch buffer ------------------------------------
// JS stages binding names + island dispatch payloads into this buffer
// before calling the matching `verve_register_*` / `verve_island_dispatch`
// export. It lives in THIS shared module — force-included by
// `verve_client.zig`'s `comptime { _ = @import("runtime_exports.zig"); }`
// — so every client entry (framework web + any scaffold with its own
// `main.zig`) exports the accessors and the JS binding walker can run.
pub var island_scratch: [8192]u8 align(@alignOf(u8)) = undefined;

export fn verve_island_scratch_ptr() u32 {
    // usize on the native test target is 64-bit; truncate to the wasm32 u32 ABI.
    return @intCast(@intFromPtr(&island_scratch));
}

export fn verve_island_scratch_capacity() u32 {
    return island_scratch.len;
}

test "runtime_exports keeps the walker scratch accessors exported" {
    _ = &verve_island_scratch_ptr;
    _ = &verve_island_scratch_capacity;
    _ = &island_scratch;
}

// ---- Island scope + state for chunk hydration ----------------------------
// A chunk's `register*`/`registerEvent` calls route into this main runtime,
// which scopes them by `island.current_island_id`. The bridge wraps each
// chunk `hydrate` in enter/exit so chunk signals land under the island's vid
// owner (and dispose with it). `verve_current_state_ptr`/`_len` expose the
// already-staged resource-state blob so chunks read it from shared memory.

export fn verve_enter_island(vid: u32) void {
    island.current_island_id = vid;
}

export fn verve_exit_island() void {
    island.current_island_id = 0;
}

export fn verve_current_state_ptr() u32 {
    // usize on the native test target is 64-bit; truncate to the wasm32 u32 ABI.
    return @intCast(@intFromPtr(island_state_client.currentBlob().ptr));
}

export fn verve_current_state_len() u32 {
    return @intCast(island_state_client.currentBlob().len);
}

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
    const id = id_ptr[0..id_len];
    var nbuf: [256]u8 = undefined;
    const scoped = @import("verve").vidBindName(id, island.current_island_id, &nbuf);
    return dom.query_ref(scoped.ptr, scoped.len);
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

// ---- Current-event accessors (Phase 18, chunk-callable) -----------------
//
// JS stages the dispatching event's data via the `verve_event_set_*`
// exports immediately before `verve_event_dispatch(id)`; the handler
// reads it through these accessors; JS reads `verve_event_flags()` after
// dispatch to honor preventDefault / stopPropagation, then calls
// `verve_event_end()`. See `event_state.zig`.

export fn verve_event_begin() void {
    event_state.begin();
}
export fn verve_event_set_mods(m: u32) void {
    event_state.setMods(m);
}
export fn verve_event_set_coords(x: f64, y: f64) void {
    event_state.setCoords(x, y);
}
export fn verve_event_set_key(ptr: [*]const u8, len: u32) void {
    event_state.setKey(ptr[0..len]);
}
export fn verve_event_set_scroll(delta_y: f64) void {
    event_state.setScroll(delta_y);
}
export fn verve_event_set_button(b: i32) void {
    event_state.setButton(b);
}
export fn verve_event_set_dataset(ptr: [*]const u8, len: u32) void {
    event_state.setDataset(ptr[0..len]);
}
export fn verve_event_mods() u32 {
    return event_state.getMods();
}
export fn verve_event_coord_x() f64 {
    return event_state.coordX();
}
export fn verve_event_coord_y() f64 {
    return event_state.coordY();
}
export fn verve_event_delta_y() f64 {
    return event_state.scrollDeltaY();
}
export fn verve_event_button() i32 {
    return event_state.buttonId();
}
export fn verve_event_key(buf_ptr: [*]u8, buf_cap: u32) u32 {
    const s = event_state.keySlice();
    const n: u32 = @min(@as(u32, @intCast(s.len)), buf_cap);
    @memcpy(buf_ptr[0..n], s[0..n]);
    return n;
}
export fn verve_event_target_attr(
    name_ptr: [*]const u8,
    name_len: u32,
    buf_ptr: [*]u8,
    buf_cap: u32,
) u32 {
    return event_state.targetAttr(name_ptr[0..name_len], buf_ptr, buf_cap);
}
export fn verve_event_prevent_default() void {
    event_state.setPrevent();
}
export fn verve_event_stop_propagation() void {
    event_state.setStop();
}
export fn verve_event_flags() u32 {
    return event_state.getFlags();
}
export fn verve_event_end() void {
    event_state.end();
}

// ---- Chunk arena + drag-drop (Phase 22, chunk-callable) -----------------

export fn verve_chunk_alloc(len: u32, alignment: u32) u32 {
    return @intCast(chunk_arena.alloc(len, alignment));
}
export fn verve_chunk_arena_mark() u32 {
    return @intCast(chunk_arena.mark());
}
export fn verve_chunk_arena_reset(m: u32) void {
    chunk_arena.reset(m);
}
/// Called by the bridge after writing a dropped file's bytes into the
/// arena: stages the file name + the (ptr,len) of its bytes.
export fn verve_drop_set(name_ptr: [*]const u8, name_len: u32, ptr: u32, len: u32) void {
    chunk_arena.setDrop(name_ptr[0..name_len], ptr, len);
}
export fn verve_drop_name(buf_ptr: [*]u8, buf_cap: u32) u32 {
    return chunk_arena.dropName(buf_ptr, buf_cap);
}
export fn verve_drop_name_len() u32 {
    return chunk_arena.dropNameLen();
}
export fn verve_drop_ptr() u32 {
    return chunk_arena.dropPtr();
}
export fn verve_drop_len() u32 {
    return chunk_arena.dropLen();
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

// ---- Named templates (G2, chunk-callable) -------------------------------

export fn verve_clone_template(name_ptr: [*]const u8, name_len: u32) i32 {
    return dom.clone_template(name_ptr, @as(usize, name_len));
}

export fn verve_slot_text(
    handle: i32,
    slot_ptr: [*]const u8,
    slot_len: u32,
    text_ptr: [*]const u8,
    text_len: u32,
) void {
    dom.slot_text(handle, slot_ptr, @as(usize, slot_len), text_ptr, @as(usize, text_len));
}

export fn verve_slot_attr(
    handle: i32,
    slot_ptr: [*]const u8,
    slot_len: u32,
    name_ptr: [*]const u8,
    name_len: u32,
    value_ptr: [*]const u8,
    value_len: u32,
) void {
    dom.slot_attr(
        handle,
        slot_ptr,
        @as(usize, slot_len),
        name_ptr,
        @as(usize, name_len),
        value_ptr,
        @as(usize, value_len),
    );
}

export fn verve_append_to_bind(
    parent_bind_ptr: [*]const u8,
    parent_bind_len: u32,
    child_handle: i32,
) void {
    dom.append_to_bind(parent_bind_ptr, @as(usize, parent_bind_len), child_handle);
}

// ---- IPC response handlers (G3, chunk-callable) -------------------------
//
// `verve_register_response_handler(route, handler_idx)` records the
// chunk's fn pointer against `route`. When the bridge JS observes
// a reply with `type == <route>`, it stages the body bytes into
// shared memory and calls `verve_dispatch_response(route, body_ptr,
// body_len)` — the runtime walks the slot table and fires every
// matching handler. Pairs with `server_fn_post` / `post_json_i32`
// for outbound calls.

export fn verve_register_response_handler(
    route_ptr: [*]const u8,
    route_len: u32,
    handler_idx: u32,
) void {
    const route = route_ptr[0..route_len];
    const handler: *const fn ([*]const u8, u32) void = @ptrFromInt(@as(usize, handler_idx));
    runtime.registerResponseHandler(route, handler);
}

export fn verve_dispatch_response(
    route_ptr: [*]const u8,
    route_len: u32,
    body_ptr: [*]const u8,
    body_len: u32,
) void {
    runtime.dispatchResponse(route_ptr[0..route_len], body_ptr[0..body_len]);
}

// ---- Outbound typed POST (Phase 17, chunk-callable) ---------------------
//
// Chunks can't declare `extern "verve" fn server_fn_post` — they only
// receive the `verve_runtime` import namespace (main-client exports),
// not the JS-bridge `verve` namespace. Re-export the bridge call here so
// the chunk façade reaches it via `verve_runtime`. The body bytes live
// in shared memory (typically the chunk's scratch); the bridge POSTs to
// `/api/<name>` and fans the reply back through `verve_dispatch_response`
// to whatever handler the chunk registered for `name`.

export fn verve_server_fn_post(
    name_ptr: [*]const u8,
    name_len: u32,
    body_ptr: [*]const u8,
    body_len: u32,
) void {
    // Chunk-facing fire-and-forget post: no correlation id (rid 0).
    dom.server_fn_post(name_ptr, @as(usize, name_len), body_ptr, @as(usize, body_len), 0);
}

// ---- Correlated round-trip (chunk-callable) -----------------------------
// Mirror the main client's rid correlation into the `verve_runtime` namespace
// so chunks can do one-shot, correlated request → typed-reply loops (e.g.
// `fetchSignal`). The logic lives in `runtime.zig`; these only re-export it.

export fn verve_next_req_id() u32 {
    return runtime.nextReqId();
}

export fn verve_register_response_handler_once(
    route_ptr: [*]const u8,
    route_len: u32,
    rid: u32,
    handler_idx: u32,
) void {
    const handler: *const fn ([*]const u8, u32) void = @ptrFromInt(@as(usize, handler_idx));
    runtime.registerResponseHandlerOnce(route_ptr[0..route_len], rid, handler);
}

export fn verve_server_fn_post_rid(
    name_ptr: [*]const u8,
    name_len: u32,
    body_ptr: [*]const u8,
    body_len: u32,
    rid: u32,
) void {
    dom.server_fn_post(name_ptr, @as(usize, name_len), body_ptr, @as(usize, body_len), rid);
}

// ---- Shared JSON value service (Phase 17, chunk-callable) ---------------
//
// One std.json parser lives here in the main client; chunks call these
// accessors against a numeric handle instead of duplicating a parser
// per chunk. See `json_service.zig` for the handle/lifetime contract.

export fn verve_json_parse(ptr: [*]const u8, len: u32) u32 {
    return json_service.parse(ptr[0..len]);
}

export fn verve_json_free(handle: u32) void {
    json_service.free(handle);
}

export fn verve_json_get(handle: u32, key_ptr: [*]const u8, key_len: u32) u32 {
    return json_service.objGet(handle, key_ptr[0..key_len]);
}

export fn verve_json_at(handle: u32, index: u32) u32 {
    return json_service.at(handle, index);
}

export fn verve_json_len(handle: u32) i32 {
    return json_service.len(handle);
}

export fn verve_json_kind(handle: u32) u32 {
    return json_service.kind(handle);
}

export fn verve_json_i64(handle: u32) i64 {
    return json_service.asI64(handle);
}

export fn verve_json_f64(handle: u32) f64 {
    return json_service.asF64(handle);
}

export fn verve_json_bool(handle: u32) u32 {
    return if (json_service.asBool(handle)) 1 else 0;
}

export fn verve_json_str_len(handle: u32) u32 {
    return json_service.asStrLen(handle);
}

export fn verve_json_str(handle: u32, buf_ptr: [*]u8, buf_cap: u32) u32 {
    return json_service.asStr(handle, buf_ptr, buf_cap);
}

// ---- Keyed-list reconciler (chunk-callable) ------------------------------
//
// Wasm-MVP-callable wrapper around `runtime.applyReconcile`. Each
// list-of-slices arg crosses as `(*[]const u8, count)` — Zig slices
// are `(ptr, len)` pairs in linear memory, and that layout is shared
// across chunk + main runtime so the pointer-to-slice-header form
// resolves to the same bytes on both sides. The runtime allocates a
// short-lived arena under the long-lived bump heap for the planner's
// scratch; the arena disposes at function return so subsequent calls
// don't leak.

export fn verve_list_diff(
    parent_ptr: [*]const u8,
    parent_len: u32,
    old_keys_ptr: [*]const []const u8,
    old_keys_count: u32,
    new_keys_ptr: [*]const []const u8,
    new_keys_count: u32,
    new_html_ptr: [*]const []const u8,
    new_html_count: u32,
) void {
    if (new_keys_count != new_html_count) return;
    const parent = parent_ptr[0..parent_len];
    const old_keys = old_keys_ptr[0..old_keys_count];
    const new_keys = new_keys_ptr[0..new_keys_count];
    const new_html = new_html_ptr[0..new_html_count];

    var arena = std.heap.ArenaAllocator.init(client_alloc.allocator());
    defer arena.deinit();
    runtime.applyReconcile(arena.allocator(), parent, old_keys, new_keys, new_html) catch return;
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

test "verve_list_diff plans + dispatches against native dom stubs" {
    runtime.resetForTesting();

    // Native dom stubs are no-ops; the load-bearing assertion is that
    // the export accepts the slice-of-slices form and reaches
    // applyReconcile without crashing.
    const parent = "items";
    const old_keys = [_][]const u8{ "a", "b", "c" };
    const new_keys = [_][]const u8{ "c", "a", "d" };
    const new_html = [_][]const u8{
        "<li data-vkey=\"c\">C</li>",
        "<li data-vkey=\"a\">A</li>",
        "<li data-vkey=\"d\">D</li>",
    };
    verve_list_diff(
        parent.ptr,
        @intCast(parent.len),
        &old_keys,
        @intCast(old_keys.len),
        &new_keys,
        @intCast(new_keys.len),
        &new_html,
        @intCast(new_html.len),
    );

    // Length-mismatched call short-circuits without panicking.
    const short_html = [_][]const u8{"<li>only</li>"};
    verve_list_diff(
        parent.ptr,
        @intCast(parent.len),
        &old_keys,
        @intCast(old_keys.len),
        &new_keys,
        @intCast(new_keys.len),
        &short_html,
        @intCast(short_html.len),
    );
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
