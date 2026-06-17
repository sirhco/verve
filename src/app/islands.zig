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

/// Multi-instance push-routing regression probe — two instances on one page,
/// each subscribes to the "viz" channel with its vid and updates its own
/// `probe` signal. Drives `/push-multi`. See src/client/islands/PushProbe.zig.
pub const PushProbe = struct {
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

/// verve.viz canvas render path (phase 3). SSR emits `<canvas
/// data-ref="vizcanvas-canvas">`; the chunk renders a large node-link graph to
/// canvas2d (one batched draw call/frame) with pan/zoom/hover/select via
/// hit-test. The ~1500-node demo graph is synthesized in the chunk (the 8 KB
/// SSR props scratch can't carry it), so no props. Source:
/// `src/client/islands/VizGraphCanvas.zig`.
pub const VizGraphCanvas = struct {
    pub const props_schema: []const u8 = "{}";
};

/// WebSocket hub demo (/ws-demo). Full-duplex push over /push-ws: a message sent
/// in one tab broadcasts to every connected tab. Source:
/// `src/client/islands/WsDemo.zig`.
pub const WsDemo = struct {
    pub const props_schema: []const u8 = "{}";
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

/// verve.gl demo — single chunk hosting BOTH /gl canvases (unlit cube +
/// textured model). Two separate stateful chunks on one page would overlap
/// in shared linear memory (each chunk links static data at the same 0x1000
/// base), clobbering each other's scene/cmd_buf/rodata. Merging them into
/// one chunk satisfies the framework invariant (at most ONE stateful chunk
/// per page). Source: `src/client/islands/GlDemo.zig`.
pub const GlDemo = struct {
    pub const props_schema: []const u8 = "{}";
};

/// verve.gl P10 WebGPU demo — a single stateful chunk that uploads an unlit
/// vertex-color cube and drives it through the WebGPU backend (gl_start_gpu).
/// SSR emits `<canvas data-ref="glwebgpu-canvas">`; the client chunk creates
/// buffers + a WGSL shader (gl.command.wgslUnlit) and renders over shared
/// linear memory. Requires a WebGPU-capable browser; degrades to the poster
/// otherwise. Source: `src/client/islands/GlWebgpu.zig`.
pub const GlWebgpu = struct {
    pub const props_schema: []const u8 = "{}";
};

/// verve.gl P10 WebGPU PBR scene (slices 2a + 2b + 2c) — a single stateful chunk
/// that uploads a static stride-48 PBR cube + ground plane + base/metallic-roughness
/// textures, loads a prefiltered `.venv` environment, and drives a textured
/// Cook-Torrance render (directional light + image-based lighting + a PCF shadow
/// pass) through the WebGPU backend (gl_start_gpu) using the WGSL PBR + depth
/// shaders (gl.command.wgslPbr / wgslDepth). SSR emits
/// `<canvas data-ref="glscenewebgpu-canvas">`. Dedicated WebGPU-only chunk (shared-
/// island backend selection remains slice-2d work). Requires a WebGPU-capable
/// browser; degrades to the blank canvas otherwise.
/// Source: `src/client/islands/GlSceneWebgpu.zig`.
pub const GlSceneWebgpu = struct {
    pub const props_schema: []const u8 = "{}";
};

/// verve.gl skinning slice 1 (/gl-skin). Renders a GPU-skinned rigged bar
/// (`skinbar.vmesh`) deformed by a fixed bent pose; backend-detects WebGPU vs
/// WebGL2 like GlScene. SSR emits `<canvas data-ref="glskin-canvas">`.
/// Source: `src/client/islands/GlSkin.zig`.
pub const GlSkin = struct {
    pub const props_schema: []const u8 = "{}";
};

/// verve.gl declarative scene (P4). Built via `ctx.glScene(.{...})` — a vmesh
/// model + venv environment rendered with orbit camera, a directional light,
/// optional auto-rotate, and named pickable meshes wired to closure event ids.
/// SSR emits `<canvas data-ref="glscene-canvas">` (+ optional poster `<img>`);
/// the client chunk decodes `Props` and drives a WebGL2 scene over shared
/// linear memory. Source: `src/client/islands/GlScene.zig` (Task 12; until then
/// the build resolves it to the `_default.zig` no-op chunk).
///
/// `Props` is the frozen wire contract — a positional mirror of
/// `core/gl_scene.zig`'s `Props`, decoded field-by-field by the chunk. The
/// design's `light_dir: [3]f32` is flattened to three scalars because the
/// SSR↔hydration codec (serialize.zig) has no fixed-array tag.
///
/// WARNING: the codec is positional (field order, not names) — any change
/// here MUST be applied identically to `core/gl_scene.zig`'s `Props`, or
/// hydration silently decodes garbage.
pub const GlScene = struct {
    /// WARNING: the codec is positional (field order, not names) — any change
    /// here MUST be applied identically to `core/gl_scene.zig`'s `Props` AND
    /// `src/client/islands/GlScene.zig`'s `Props`, or hydration silently decodes
    /// garbage. Last field added: `pick_export_names` (P8, onPickExport).
    pub const props_schema: []const u8 = "{\"src\":\"string\",\"env\":\"string\",\"orbit_distance\":\"f32\",\"orbit_pitch\":\"f32\",\"orbit_yaw\":\"f32\",\"auto_rotate\":\"f32\",\"light_dir_x\":\"f32\",\"light_dir_y\":\"f32\",\"light_dir_z\":\"f32\",\"light_intensity\":\"f32\",\"pick_names\":\"string[]\",\"pick_event_ids\":\"u32[]\",\"scrub\":\"bool\",\"pick_export_names\":\"string[]\"}";

    pub const Props = struct {
        src: []const u8,
        env: []const u8,
        orbit_distance: f32,
        orbit_pitch: f32,
        orbit_yaw: f32,
        auto_rotate: f32,
        light_dir_x: f32,
        light_dir_y: f32,
        light_dir_z: f32,
        light_intensity: f32,
        pick_names: []const []const u8,
        pick_event_ids: []const u32,
        scrub: bool, // scroll-scrub mode (Task 9); when true auto_rotate is forced 0 at build()
        pick_export_names: []const []const u8, // P8 onPickExport: per-slot DOM event name ("" = none)
    };
};
