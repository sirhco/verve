//! Verve client runtime. Compiles to wasm32-freestanding.
//!
//! Phase 12: the WASM client now hosts the real reactive graph from
//! `src/core/signal.zig`. `verve_hydrate` walks every server-rendered
//! `bind()` it knows about, allocates one `verve.Signal(i32)` per slot
//! under the runtime's root Owner, and wires the Signal's `on_set`
//! hook to a DOM-update extern. From that point on, DOM mutations are
//! a side effect of `Signal.set` — never written directly from JS.

const std = @import("std");
const verve = @import("verve");
const runtime = @import("runtime.zig");
const island = @import("island.zig");
const dom = @import("dom.zig");
const client_alloc = @import("allocator.zig");
const scratch = @import("scratch.zig");
const client_manifest = @import("client_manifest");
const app_client = @import("app_client");

pub const render = @import("render.zig");

// Phase 13F — force semantic analysis of the chunk-callable wrapper
// surface so its `export fn verve_*` declarations land in this wasm
// module's export table. Bridge JS resolves per-island chunks'
// `extern "verve_runtime"` imports against these exports.
comptime {
    _ = @import("runtime_exports.zig");
}

// ---- Phase 13: island dispatch scratch buffer ----------------------------
// JS writes name+props as concatenated UTF-8 bytes into this buffer
// then invokes `verve_island_dispatch(name_len, props_len)`. Sized for
// modest payloads — large prop blobs should be staged through the
// general-purpose allocator instead (deferred).
var island_scratch: [8192]u8 align(@alignOf(u8)) = undefined;

export fn verve_island_scratch_ptr() u32 {
    return @intFromPtr(&island_scratch);
}

export fn verve_island_scratch_capacity() u32 {
    return island_scratch.len;
}

// Persistent copy of the hydrating island's serialized resource-state blob.
// The bridge stages the blob bytes into `island_scratch` then calls
// `verve_set_island_state(len)`; we copy them OUT here so the subsequent
// name/props staging into the same scratch can't corrupt the blob the chunk
// reads via `verve.resourceFromState`.
var island_state_buf: [island_scratch.len]u8 = undefined;

export fn verve_set_island_state(len: u32) void {
    const n = @min(@as(usize, len), island_state_buf.len);
    @memcpy(island_state_buf[0..n], island_scratch[0..n]);
    @import("island_state_client.zig").setCurrentBlob(island_state_buf[0..n]);
}

export fn verve_island_dispatch(name_len: u32, props_len: u32) i32 {
    return verve_island_dispatch_v(name_len, props_len, 0);
}

export fn verve_island_dispatch_v(name_len: u32, props_len: u32, vid: u32) i32 {
    const total = @as(usize, name_len) + @as(usize, props_len);
    if (total > island_scratch.len) return 0;
    const name = island_scratch[0..name_len];
    const props = island_scratch[name_len .. name_len + props_len];
    return island.dispatch(name, props, vid);
}

const API_PATH: []const u8 = "/api/updateDatabase";
const API_FIELD: []const u8 = "new_count";

// Seeds captured before `verve_hydrate` allocates Signals. The bridge
// invokes `verve_init_<bind>(value)` once per binding to sync the WASM
// side with the server-rendered text content.
var count_initial: i32 = 0;
var clicks_initial: i32 = 0;

var count_sig: ?*verve.Signal(i32) = null;
var clicks_sig: ?*verve.Signal(i32) = null;

export fn verve_hydrate() void {
    // Wire the wasm `_call` round-trip to this runtime's correlation +
    // allocation surface (see core/server_fn_gen.zig installWasmHooks).
    verve.serverFnGen.installWasmHooks(
        runtime.nextReqId,
        runtime.registerResponseHandlerOnce,
        client_alloc.allocator,
    );
    count_sig = runtime.registerI32("count", count_initial);
    clicks_sig = runtime.registerI32("clicks", clicks_initial);
}

export fn verve_init_count(value: i32) void {
    count_initial = value;
}

export fn verve_init_clicks(value: i32) void {
    clicks_initial = value;
}

/// Bridge entry point for live-counter sync (WS / SSE). Routes through
/// the reactive graph so the on_set hook drives the DOM update — keeps
/// WASM the single source of truth.
export fn verve_set_count(value: i32) void {
    if (count_sig) |c| c.set(value);
}

export fn increment_counter() void {
    if (count_sig) |c| c.set(c.peek() + 1);
    if (clicks_sig) |c| c.set(c.peek() + 1);
    if (count_sig) |c| {
        dom.post_json_i32(
            API_PATH.ptr,
            API_PATH.len,
            API_FIELD.ptr,
            API_FIELD.len,
            c.peek(),
        );
    }
}

export fn decrement_counter() void {
    if (count_sig) |c| c.set(c.peek() - 1);
    if (clicks_sig) |c| c.set(c.peek() + 1);
}

/// Reply handler for the `_call` demo — the server returns the new count
/// value, which we push through the reactive graph.
fn onCallIncrement(value: i32) void {
    if (count_sig) |c| c.set(value);
    if (clicks_sig) |c| c.set(c.peek() + 1);
}

/// Demo of the typed `_call` round-trip: POST /api/incrementCount, then
/// the correlated reply's `value` lands in `onCallIncrement`. Also the
/// real call-site that retains `app_client` in the wasm client.
export fn verve_call_increment() void {
    app_client.incrementCount_call(client_alloc.allocator(), .{}, onCallIncrement);
}

export fn current_count() i32 {
    if (count_sig) |c| return c.peek();
    return 0;
}

/// Bytes currently allocated from the wasm client's FixedBufferAllocator.
export fn verve_alloc_used() u32 {
    return @intCast(client_alloc.bytesUsed());
}

export fn verve_alloc_capacity() u32 {
    return @intCast(client_alloc.capacity());
}

export fn verve_alloc_reset() void {
    client_alloc.reset();
}

// ---- Phase 12F: scratch allocator introspection --------------------------

export fn verve_scratch_used() u32 {
    return @intCast(scratch.bytesUsed());
}

export fn verve_scratch_capacity() u32 {
    return @intCast(scratch.capacityBytes());
}

// ---- Phase 13B: island manifest introspection ----------------------------

/// Number of islands the build-time codegen recorded in
/// `client_manifest.zig`. JS uses this to validate `data-name`
/// attributes against the known set before invoking dispatch.
export fn verve_island_count() u32 {
    return @intCast(client_manifest.entries.len);
}
