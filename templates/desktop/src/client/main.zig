//! Scaffold WASM client. Compiles to `wasm32-freestanding` and is
//! served at `verve://app/client.wasm`. The bridge in
//! `frontend/verve_desktop.js` instantiates it, runs the Phase 14
//! auto-walker against every `[data-vh-type]` element the renderer
//! stamped (via `Node.bindI32` / `bindStr` / `bindBool` / `bindF32`),
//! and registers each Signal under the runtime's root Owner. Click
//! handlers stamped with `z-on-click="<exportName>"` dispatch through
//! the matching wasm export.
//!
//! Reactive flow: bindings registered by the walker get their
//! `on_set` hook wired to the matching `[z-bind]` element via the JS
//! bridge. Click handlers below look up Signals by name + call
//! `.set(...)` — DOM mutations are a side effect of `Signal.set`,
//! never written directly.

const verve = @import("verve");

export fn increment_counter() void {
    if (verve.signalI32("count")) |c| c.increment();
    if (verve.signalI32("clicks")) |c| c.increment();
}

export fn decrement_counter() void {
    if (verve.signalI32("count")) |c| c.decrement();
    if (verve.signalI32("clicks")) |c| c.increment();
}
