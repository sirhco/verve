//! Per-app island registry. Each `pub const <Name> = struct { ... };`
//! decl in this namespace becomes an entry in the build-time
//! `client_manifest.zig` (Phase 13B). The convention is intentionally
//! decoupled from `verve.island(...)` calls so a single island
//! declaration can power both the SSR marker and the JS-side hydrator
//! lookup table.
//!
//! Per-island WASM chunking (Phase 13C, deferred) will reuse the same
//! manifest — the `props_schema` slot then becomes the contract the
//! per-chunk codec reads to decode `data-props`.

pub const Counter = struct {
    /// Pre-serialized JSON shape the SSR marker stamps into
    /// `data-props`. Today the runtime doesn't decode it — Phase 13C
    /// will pipe the schema through the binary codec.
    pub const props_schema: []const u8 = "{\"initial\":\"i32\"}";
};
