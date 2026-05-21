//! Phase 13C — per-island WASM chunk for the Counter island.
//!
//! Standalone wasm32-freestanding module fetched on demand by the JS
//! bridge when a `<verve-island data-name="Counter">` marker is found
//! in the document. Today the chunk is a thin stub: the universal
//! `data-vh` walker in the main `client.wasm` already hydrates the
//! Counter's reactive span, so the per-chunk `hydrate` entry is
//! mostly a place to wire island-specific state (multi-step
//! initialization, prop-driven Signal seeding, event handlers that
//! aren't expressible via `[z-on-click]`).
//!
//! The real bytes-on-the-wire win comes with Phase 13D, when the
//! main runtime extracts into a shared chunk that islands import
//! via WebAssembly memory + table sharing. Until then, every
//! per-island chunk ships standalone — small enough that the
//! plumbing pays for itself only on pages with multiple islands.

const std = @import("std");

/// Scratch buffer for JS to write the island's `data-props` string
/// before invoking `hydrate`. Sized for modest payloads; oversize
/// props blobs should stage through the main client's allocator.
var props_scratch: [4096]u8 align(@alignOf(usize)) = undefined;

/// Track whether `hydrate` has been called this session — JS reads
/// the export back to confirm the chunk took effect (smoke-test path
/// in lieu of richer telemetry).
var hydrate_hits: u32 = 0;

export fn props_buf_ptr() u32 {
    return @intFromPtr(&props_scratch);
}

export fn props_buf_capacity() u32 {
    return props_scratch.len;
}

export fn hydrate_count() u32 {
    return hydrate_hits;
}

/// Island hydration entry. JS copies the `data-props` string into
/// `props_scratch` (via `props_buf_ptr`) and then calls this with the
/// length. `root_id` is reserved for the future case where multiple
/// instances of the same island coexist on a page — Phase 13D will
/// use it to disambiguate effect ownership.
export fn hydrate(props_len: u32, root_id: u32) void {
    _ = props_len;
    _ = root_id;
    hydrate_hits += 1;
}
