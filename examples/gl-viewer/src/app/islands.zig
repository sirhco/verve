//! Per-app island registry. The build discovers each `pub const <Name> =
//! struct { ... }` here and compiles the matching chunk — example-local
//! `src/client/islands/<Name>.zig` first, then the framework's own
//! implementation, then the `_default` stub. This example reuses the
//! framework's `GlScene` chunk verbatim
//! (`../../src/client/islands/GlScene.zig`) — no chunk source of its own.

/// verve.gl declarative scene. Built via `ctx.glScene(.{...})`: a vmesh model
/// + venv environment rendered with an orbit camera, a directional light,
/// optional auto-rotate or scroll-scrub, and named pickable meshes wired to
/// closure event ids. SSR emits `<canvas data-ref="glscene-canvas">` (+ the
/// optional poster `<img>`); the client chunk decodes `Props` and drives a
/// WebGL2 scene over shared linear memory.
///
/// WARNING: the codec is positional (field order, not names) — this schema +
/// `Props` mirror `core/gl_scene.zig` and the framework chunk exactly. Do not
/// reorder.
pub const GlScene = struct {
    pub const props_schema: []const u8 = "{\"src\":\"string\",\"env\":\"string\",\"orbit_distance\":\"f32\",\"orbit_pitch\":\"f32\",\"orbit_yaw\":\"f32\",\"auto_rotate\":\"f32\",\"light_dir_x\":\"f32\",\"light_dir_y\":\"f32\",\"light_dir_z\":\"f32\",\"light_intensity\":\"f32\",\"pick_names\":\"string[]\",\"pick_event_ids\":\"u32[]\",\"scrub\":\"bool\"}";

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
        scrub: bool,
    };
};

/// WebGL2 GPU-skinned bar demo. SSR emits `<canvas data-ref="glskin-canvas">`.
/// The chunk fetches skinbar.vmesh and drives variant_pbr | variant_skinned.
/// Source: `src/client/islands/GlSkin.zig`.
pub const GlSkin = struct {
    pub const props_schema: []const u8 = "{}";
};
