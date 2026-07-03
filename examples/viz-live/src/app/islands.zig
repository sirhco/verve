//! Per-app island registry. The build discovers each `pub const <Name> =
//! struct { ... }` here and compiles the matching chunk — example-local
//! `src/client/islands/<Name>.zig` first, then the framework's own
//! implementation, then the `_default` stub. This example reuses the
//! framework's `VizGraphInteractive` and `VizGraphCanvas` chunks verbatim.

/// Interactive node-link graph: wheel-zoom, pointer-captured pan/drag, hover
/// tooltip, click-select, dblclick subtree collapse, runtime add/remove with
/// layout-aware tweening, and live SSE wire-delta streaming with seq-gap
/// resync. Source: `../../src/client/islands/VizGraphInteractive.zig`.
pub const VizGraphInteractive = struct {
    pub const props_schema: []const u8 = "{\"xs\":\"f64[]\",\"ys\":\"f64[]\",\"ef\":\"u32[]\",\"et\":\"u32[]\",\"labels\":\"string[]\",\"ids\":\"string[]\",\"layout\":\"u32\",\"margin\":\"f64\",\"edge_routing\":\"u32\"}";

    /// Positionally mirrored in the chunk. `ef`/`et` are edge endpoint node
    /// indices; `layout` is `@intFromEnum(viz.Layout)` and `margin` the SSR
    /// `GraphOpts.margin` — together they let the chunk recompute
    /// deterministic layouts client-side with SSR-identical fitting.
    pub const Props = struct {
        xs: []const f64,
        ys: []const f64,
        ef: []const u32,
        et: []const u32,
        labels: []const []const u8,
        ids: []const []const u8,
        layout: u32,
        margin: f64,
        edge_routing: u32,
    };
};

/// canvas2d render path (one batched draw call/frame) with pan/zoom/hover/select
/// via hit-test. The graph is fetched from /viz/graph.bin at init; no props.
/// Source: `../../src/client/islands/VizGraphCanvas.zig`.
pub const VizGraphCanvas = struct {
    pub const props_schema: []const u8 = "{}";
};
