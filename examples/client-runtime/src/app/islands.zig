//! Per-app island registry. The build discovers each `pub const <Name> =
//! struct { ... }` here and compiles `src/client/islands/<Name>.zig` into a
//! per-island WASM chunk (falling back to the framework's `_default` stub if
//! the source is absent).

/// Phase 17-22 client-runtime probe. Its source
/// (`src/client/islands/JsonProbe.zig`) exercises typed IPC, events-with-data,
/// timers/storage/clipboard, forms/measurement, JS interop, and the chunk
/// arena + drag-drop in one chunk.
pub const JsonProbe = struct {
    pub const props_schema: []const u8 = "{}";
};
