//! Phase 13F — Counter island chunk (shared-runtime).
//!
//! Imports its memory + reactive surface from the main `client.wasm`
//! at instantiation time. The chunk keeps no static state of its own
//! so the chunk + main module can safely share the same linear memory.
//!
//! `hydrate` runs once per `<verve-island data-name="Counter">` on the
//! page. It registers a per-island Signal under the main runtime's
//! root Owner; subsequent click handlers exported from this chunk
//! call into the shared API to mutate it.
//!
//! Multi-instance: `root_id` is a per-page document-order id assigned
//! by the bridge JS. Chunks that need distinct state per
//! `<verve-island>` marker should namespace their bind-names using
//! it — e.g. `std.fmt.bufPrint(&buf, "counter_island_{d}", .{root_id})`.
//! The SSR'd content's `[z-bind=...]` must use the same namespaced
//! form so the on_set hook reaches the right element. This demo
//! ignores `root_id` and uses a single shared signal — multiple
//! `<verve-island data-name="Counter">` markers on the same page
//! would share state (which is what the idempotent `registerI32`
//! contract delivers safely; no slot duplication).

const verve = @import("verve");

const COUNTER_BIND: []const u8 = "counter_island";

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;
    // Allocate the signal in the main runtime's slot table. The
    // matching server-rendered element carries
    // `[z-bind="counter_island"]` so the runtime's `on_set` hook drives
    // the DOM update on every `signalSet*` call below.
    verve.registerI32(COUNTER_BIND, 0);
}

/// Click handler stamped via `[z-on-click="counter_island_bump"]` in
/// the SSR'd island content. The bridge JS string-name delegate looks
/// up the export on the chunk's instance and invokes it directly.
export fn counter_island_bump() void {
    verve.signalSetI32(COUNTER_BIND, verve.signalGetI32(COUNTER_BIND) + 1);
}
