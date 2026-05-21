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

pub const render = @import("render.zig");

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

export fn verve_island_dispatch(name_len: u32, props_len: u32) i32 {
    const total = @as(usize, name_len) + @as(usize, props_len);
    if (total > island_scratch.len) return 0;
    const name = island_scratch[0..name_len];
    const props = island_scratch[name_len .. name_len + props_len];
    if (island.lookup(name)) |hydrate_fn| {
        hydrate_fn(props);
        return 1;
    }
    return 0;
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
