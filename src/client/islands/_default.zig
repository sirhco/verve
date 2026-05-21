//! Phase 13E — shared-runtime default per-island chunk.
//!
//! The chunk imports its memory from the main `client.wasm`'s
//! linear memory at instantiation time. As long as the chunk
//! declares zero static state of its own — no globals, no
//! `var` decls outside fn bodies, no stack-resident locals
//! beyond what a no-op hydrate needs — the import is safe:
//! both modules see the same `memory[0..]` and the chunk's code
//! never touches addresses the main runtime has reserved.
//!
//! Per-island chunks that do want their own scratch should
//! reach into the main runtime's `scratch` allocator via the
//! exports the shared instantiation passes in as imports (the
//! Phase 13F follow-up adds this surface).

/// Island hydration entry. JS arranges for `props_ptr` /
/// `props_len` to point into the main runtime's memory (so the
/// chunk can read the data-props string without a per-chunk
/// scratch buffer). `root_id` is reserved for the multi-instance
/// case Phase 13F formalizes.
export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;
}
