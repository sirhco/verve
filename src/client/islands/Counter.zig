//! Phase 13E — Counter island chunk (shared-runtime).
//!
//! Imports its memory from the main `client.wasm` at
//! instantiation time and keeps no static state of its own, so
//! both modules can safely share the same linear memory. The
//! universal `data-vh` walker in the main runtime already wires
//! the counter's reactive span; this chunk's `hydrate` runs once
//! per `<verve-island data-name="Counter">` on the page and is
//! the place island-specific bring-up will land (multi-step
//! initialization, prop-driven Signal seeding, custom event
//! handlers) once Phase 13F exposes the shared runtime's
//! Signal-registration API to per-chunk callers.

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;
}
