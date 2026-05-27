//! Phase 13F — shared-runtime default per-island chunk.
//!
//! Used as the fallback chunk source when an island declared under
//! `src/app/islands.zig` doesn't have a matching custom source file at
//! `src/client/islands/<Name>.zig`. The chunk imports the main
//! `client.wasm`'s linear memory at instantiation time, so its code
//! and the main runtime share `memory[0..]` safely. Per-island chunks
//! that need their own logic ship a sibling file with a real `hydrate`
//! body; this stub just satisfies the build's per-island-chunk
//! contract so undeclared islands stay legal at the source level.
//!
//! Per-island chunks that DO need reactive state can `@import("verve")`
//! and call `verve.registerI32` / `signalSet*` / `queryRef` / etc. —
//! see `Counter.zig` for an end-to-end example. Closure-style click
//! handlers (a `*const fn () void` registered cross-module) are not
//! supported; chunks stamp `z-on-click="<exportedHandlerName>"` and
//! export the matching function from the chunk itself.

/// Island hydration entry. JS arranges for `props_ptr` / `props_len`
/// to point into the main runtime's memory (so the chunk can read the
/// data-props string without a per-chunk scratch buffer). `root_id` is
/// reserved for a future multi-instance dispatch.
export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;
}
