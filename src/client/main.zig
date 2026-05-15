//! Verve client runtime. Compiles to wasm32-freestanding.
//!
//! Exports: `verve_hydrate` (no-op stub for now), action functions.
//! Imports from JS bridge (namespace "verve"): see src/client/dom.zig.

const dom = @import("dom.zig");

var count: i32 = 0;

const COUNT_BIND: []const u8 = "count_display";
const API_PATH: []const u8 = "/api/updateDatabase";
const API_FIELD: []const u8 = "new_count";

export fn verve_hydrate() void {
    dom.set_text_by_bind_i32(COUNT_BIND.ptr, COUNT_BIND.len, count);
}

export fn verve_init_count(value: i32) void {
    count = value;
}

export fn increment_counter() void {
    count += 1;
    dom.set_text_by_bind_i32(COUNT_BIND.ptr, COUNT_BIND.len, count);
    dom.post_json_i32(
        API_PATH.ptr,
        API_PATH.len,
        API_FIELD.ptr,
        API_FIELD.len,
        count,
    );
}

export fn decrement_counter() void {
    count -= 1;
    dom.set_text_by_bind_i32(COUNT_BIND.ptr, COUNT_BIND.len, count);
}

export fn current_count() i32 {
    return count;
}
