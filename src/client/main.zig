//! Verve client runtime. Compiles to wasm32-freestanding.
//!
//! Exports: `verve_hydrate`, `verve_init_count`, action functions.
//! Imports from JS bridge (namespace "verve"): see src/client/dom.zig.

const dom = @import("dom.zig");
const signal = @import("signal.zig");

var count = signal.ClientSignal(i32).init("count_display", 0);

const API_PATH: []const u8 = "/api/updateDatabase";
const API_FIELD: []const u8 = "new_count";

export fn verve_hydrate() void {
    count.set(count.get());
}

export fn verve_init_count(value: i32) void {
    count.value = value;
}

export fn increment_counter() void {
    count.increment();
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
}

export fn current_count() i32 {
    return count.get();
}
