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
    /// `data-props`. Today the runtime doesn't decode it — Phase 13E
    /// will pipe the schema through the binary codec.
    pub const props_schema: []const u8 = "{\"initial\":\"i32\"}";
};

pub const Greeting = struct {
    pub const props_schema: []const u8 = "{\"name\":\"string\"}";
};

/// Phase 17 — typed-IPC demo. Fires a server-fn POST and reads the reply
/// through the shared JSON service (no per-chunk parser). Source:
/// `src/client/islands/JsonProbe.zig`.
pub const JsonProbe = struct {
    pub const props_schema: []const u8 = "{}";
};

/// Interactive node-link graph (verve.viz). SSR renders the converged layout
/// (works with JS off); the client chunk reveals the nodes — scaling each from
/// 0→1 in place — by mutating each group's `transform` by ref over a few
/// animation frames. No new bridge primitives; the element set is fixed at SSR.
/// Source: `src/client/islands/VizGraph.zig`.
pub const VizGraph = struct {
    pub const props_schema: []const u8 = "{\"xs\":\"f64[]\",\"ys\":\"f64[]\"}";

    /// Final fitted node positions, shared verbatim between the server encoder
    /// and the client decoder so the reveal lands exactly on the SSR layout.
    pub const Props = struct {
        xs: []const f64,
        ys: []const f64,
    };
};

/// ScrollSmoother probe — streams native vs smoothed scroll position into
/// signals (verve_sm_get end-to-end). Source: `src/client/islands/SmoothDemo.zig`.
pub const SmoothDemo = struct {
    pub const props_schema: []const u8 = "{}";
};

/// verve.anim demo — imperative timeline with staggered entrance, control
/// API buttons, an onComplete-callback signal, and a dynamic-value +
/// fn-modifier tween. Source: `src/client/islands/AnimDemo.zig`.
pub const AnimDemo = struct {
    pub const props_schema: []const u8 = "{}";
};

/// Interactive node-link graph: wheel-zoom, drag-to-pan, node drag (incident
/// edges follow), hover tooltip, click-select. SSR renders the full static
/// graph; the client chunk wires interaction over the fixed element set. No new
/// elements created. Source: `src/client/islands/VizGraphInteractive.zig`.
pub const VizGraphInteractive = struct {
    pub const props_schema: []const u8 = "{\"xs\":\"f64[]\",\"ys\":\"f64[]\",\"ef\":\"u32[]\",\"et\":\"u32[]\",\"labels\":\"string[]\",\"ids\":\"string[]\",\"layout\":\"u32\",\"margin\":\"f64\"}";

    /// Positionally mirrored in the client chunk. `ef`/`et` are edge endpoint
    /// node indices; `labels` feeds tooltips. `layout` is
    /// `@intFromEnum(viz.Layout)` and `margin` the SSR `GraphOpts.margin` —
    /// together they let the chunk recompute deterministic layouts
    /// (tree/radial/dag) after runtime mutation with SSR-identical fitting.
    pub const Props = struct {
        xs: []const f64,
        ys: []const f64,
        ef: []const u32,
        et: []const u32,
        labels: []const []const u8,
        ids: []const []const u8,
        layout: u32,
        margin: f64,
    };
};
