//! Scaffold WASM client. Compiles to `wasm32-freestanding` and is
//! served at `verve://app/client.wasm`. The bridge in
//! `frontend/verve_desktop.js` instantiates it, scans for
//! `verve_init_*` exports, and seeds them from the server-rendered DOM
//! text content. Click handlers stamped with `z-on-click="<name>"`
//! dispatch through the matching wasm export.
//!
//! Starts deliberately small — direct DOM externs, no reactive graph.
//! Replace with verve.Signal + on_set hook once the runtime is exposed
//! through the public `verve` module.

const COUNT_BIND: []const u8 = "count";
const CLICKS_BIND: []const u8 = "clicks";

var count: i32 = 0;
var clicks: i32 = 0;

extern "verve" fn set_text_by_bind_i32(bind_ptr: [*]const u8, bind_len: u32, value: i32) void;
extern "verve" fn console_log_i32(value: i32) void;

/// Bridge calls this once per `verve_init_<bind>` export after wasm
/// instantiation. Seeds the in-memory counter from the server-rendered
/// text content.
export fn verve_init_count(value: i32) void {
    count = value;
}

export fn verve_init_clicks(value: i32) void {
    clicks = value;
}

/// Bridge calls this after seeding completes. Final wiring hook —
/// noop today, reserved for signal/effect setup.
export fn verve_hydrate() void {}

export fn increment_counter() void {
    count += 1;
    clicks += 1;
    set_text_by_bind_i32(COUNT_BIND.ptr, @intCast(COUNT_BIND.len), count);
    set_text_by_bind_i32(CLICKS_BIND.ptr, @intCast(CLICKS_BIND.len), clicks);
    console_log_i32(count);
}

export fn decrement_counter() void {
    count -= 1;
    clicks += 1;
    set_text_by_bind_i32(COUNT_BIND.ptr, @intCast(COUNT_BIND.len), count);
    set_text_by_bind_i32(CLICKS_BIND.ptr, @intCast(CLICKS_BIND.len), clicks);
}
