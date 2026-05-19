//! Verve client runtime. Compiles to wasm32-freestanding.
//!
//! Exports: `verve_hydrate`, `verve_init_count`, action functions.
//! Imports from JS bridge (namespace "verve"): see src/client/dom.zig.

const dom = @import("dom.zig");
const signal = @import("signal.zig");
const client_alloc = @import("allocator.zig");
pub const render = @import("render.zig");

var count = signal.ClientSignal(i32).init("count", 0);
var clicks = signal.ClientSignal(i32).init("clicks", 0);

const API_PATH: []const u8 = "/api/updateDatabase";
const API_FIELD: []const u8 = "new_count";

export fn verve_hydrate() void {
    count.set(count.get());
    clicks.set(clicks.get());
}

export fn verve_init_count(value: i32) void {
    count.value = value;
}

export fn verve_init_clicks(value: i32) void {
    clicks.value = value;
}

export fn increment_counter() void {
    count.increment();
    clicks.increment();
    dom.post_json_i32(
        API_PATH.ptr,
        API_PATH.len,
        API_FIELD.ptr,
        API_FIELD.len,
        count.get(),
    );
}

export fn decrement_counter() void {
    count.decrement();
    clicks.increment();
}

export fn current_count() i32 {
    return count.get();
}

/// Bytes currently allocated from the wasm client's FixedBufferAllocator.
/// Useful from JS for debugging / memory sanity checks.
export fn verve_alloc_used() u32 {
    return @intCast(client_alloc.bytesUsed());
}

/// Total capacity of the wasm client's FixedBufferAllocator.
export fn verve_alloc_capacity() u32 {
    return @intCast(client_alloc.capacity());
}

/// Reclaim every allocation made via the wasm client's FBA. Call
/// between render passes when the previous frame's buffers are no
/// longer reachable from JS.
export fn verve_alloc_reset() void {
    client_alloc.reset();
}
