//! Scaffold WASM client. Compiles to `wasm32-freestanding` and is
//! served at `verve://app/client.wasm`. The bridge in
//! `frontend/verve_desktop.js` instantiates it, scans for
//! `verve_init_*` exports, and seeds them from the server-rendered DOM
//! text content. Click handlers stamped with `z-on-click="<name>"`
//! dispatch through the matching wasm export.
//!
//! Reactive flow: `verve_init_<bind>` captures the server-rendered
//! initial value, `verve_hydrate` declares the bindings list and the
//! runtime allocates one `verve.Signal(T)` per entry via
//! `verve.autoHydrate`. Each Signal's `on_set` hook is wired to a DOM
//! update extern. Click handlers look the Signal up by name and call
//! `.set(...)` — DOM mutations are a side effect of `Signal.set`,
//! never written directly.

const verve = @import("verve");

// Seeds captured before `verve_hydrate` allocates Signals. The bridge
// invokes `verve_init_<bind>(value)` once per binding to sync the WASM
// side with the server-rendered text content; Signal construction is
// deferred to `verve_hydrate` so the initial value is correct rather
// than mutated post-allocation.
var initial_count: i32 = 0;
var initial_clicks: i32 = 0;

export fn verve_init_count(value: i32) void {
    initial_count = value;
}

export fn verve_init_clicks(value: i32) void {
    initial_clicks = value;
}

/// Bridge calls this after seeding completes. Declares the bindings
/// list once; `autoHydrate` dispatches to the right `register*` per
/// entry based on the union tag.
export fn verve_hydrate() void {
    verve.autoHydrate(&.{
        .{ .name = "count", .initial = .{ .i32 = initial_count } },
        .{ .name = "clicks", .initial = .{ .i32 = initial_clicks } },
    });
}

export fn increment_counter() void {
    if (verve.signalI32("count")) |c| c.increment();
    if (verve.signalI32("clicks")) |c| c.increment();
}

export fn decrement_counter() void {
    if (verve.signalI32("count")) |c| c.decrement();
    if (verve.signalI32("clicks")) |c| c.increment();
}
