//! Per-app island registry (each decl becomes a wasm chunk entry).

/// FLIP gallery: shuffle reorders keyed cards through the reconciler and
/// FLIP-animates the moves; remove/restore exercises the enter/leave
/// callbacks + fade-in. Source: `src/client/islands/Gallery.zig`
/// (example-local — the build resolves local island sources first).
pub const Gallery = struct {
    pub const props_schema: []const u8 = "{}";
};

/// Sortable demo: single drag-to-reorder list + two-column cross-list
/// board. Source: `src/client/islands/Sortable.zig` (example-local).
pub const Sortable = struct {
    pub const props_schema: []const u8 = "{}";
};
