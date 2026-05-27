//! Scaffold WASM client. Compiles to `wasm32-freestanding` and is
//! served at `verve://app/client.wasm`. The bridge in
//! `frontend/verve_desktop.js` instantiates it, scans for
//! `verve_init_*` exports, and seeds them from the server-rendered DOM
//! text content. Click handlers stamped with `z-on-click="<name>"`
//! dispatch through the matching wasm export.
//!
//! Reactive flow: `verve_init_<bind>` captures the server-rendered
//! initial value, `verve_hydrate` allocates one `verve.Signal(i32)` per
//! binding via `verve.registerI32`, and the runtime wires each Signal's
//! `on_set` hook to a DOM update extern. Click handlers call `.set(...)`
//! — DOM mutations are a side effect of `Signal.set`, never written
//! directly.

const verve = @import("verve");

const COUNT_BIND: []const u8 = "count";
const CLICKS_BIND: []const u8 = "clicks";

// Seeds captured before `verve_hydrate` allocates Signals. The bridge
// invokes `verve_init_<bind>(value)` once per binding to sync the WASM
// side with the server-rendered text content; Signal construction is
// deferred to `verve_hydrate` so the initial value is correct rather
// than mutated post-allocation.
var initial_count: i32 = 0;
var initial_clicks: i32 = 0;

var count_sig: ?*verve.Signal(i32) = null;
var clicks_sig: ?*verve.Signal(i32) = null;

export fn verve_init_count(value: i32) void {
    initial_count = value;
}

export fn verve_init_clicks(value: i32) void {
    initial_clicks = value;
}

/// Bridge calls this after seeding completes. Allocates one Signal per
/// binding under the runtime's root Owner and wires its `on_set` hook
/// to the matching `[z-bind="<name>"]` element via the JS bridge.
export fn verve_hydrate() void {
    count_sig = verve.registerI32(COUNT_BIND, initial_count);
    clicks_sig = verve.registerI32(CLICKS_BIND, initial_clicks);
}

export fn increment_counter() void {
    if (count_sig) |c| c.increment();
    if (clicks_sig) |c| c.increment();
}

export fn decrement_counter() void {
    if (count_sig) |c| c.decrement();
    if (clicks_sig) |c| c.increment();
}
