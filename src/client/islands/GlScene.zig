//! verve.gl interactive scene chunk — orbit camera + ray-picking + autoRotate,
//! with Registry-driven GPU-resource replay across WebGL context restore.
//!
//! MULTI-INSTANCE (P7): the bridge instantiates ONE GlScene chunk per page and
//! calls `hydrate(props, len, root_id)` once per `<verve-island data-name=
//! "GlScene">` marker, with a distinct `root_id` (the island vid). Every
//! per-instance field lives in an `Inst` slot; `instances[]` holds up to
//! `MAX_INSTANCES`, keyed by vid. The bridge calls `glscene_select(root_id)`
//! immediately before each frame / event / asset-callback / restore dispatch,
//! which sets `current`; every export then operates on `current.*`. Islands
//! without a `glscene_select` export (GlDemo, non-gl) make the bridge's guarded
//! select call a no-op, so the generic gl-driving contract is unchanged.
//!
//! Still ONE instance-of-chunk: the chunk links its static data at base 0x1000
//! like every island chunk, so co-locating a DIFFERENT stateful chunk (GlDemo)
//! on the same page still overlaps — that's the separate memory-partition track.
//! Here we only widen the statics into a per-vid array.
//!
//! ── DESIGN CHOICES (see Task 12 spec) ───────────────────────────────────────
//!  • Scene graph (P6): node 0 = root "model", carrying model_yaw as a +Y
//!    rotation; node s+1 = submesh s (named from the vmesh), animatable via
//!    node:<Name>.rotationX/Y/Z — Euler radians composed Qz·Qy·Qx (X applied
//!    first). Each draw reads its own world matrix: the per-submesh mvps/
//!    model_mats/normal9s pools keep every drawPbr pointer at a stable
//!    distinct slot (stream aliasing — JS walks the stream AFTER the frame fn
//!    returns). The pools live inside `Inst` in the fixed `instances` array, so
//!    `&inst.mvps[s]` is a stable absolute address for the page lifetime.
//!  • autoRotate BYPASSES the orbit damping: `orbit.yaw += auto_rotate*dt_s`
//!    applied before tick(), giving a constant angular rate (rad/s) rather than
//!    an impulse that decays. User drag impulses still flow through tick().
//!  • Drag sign: orbit.eye() uses +sin(yaw) for +X. Dragging RIGHT should make
//!    the model appear to follow the pointer → the camera swings LEFT → yaw
//!    decreases. Hence `dyaw -= dx*sens`. Same logic vertically: `dpitch -=
//!    dy*sens`. orbit.tick() clamps pitch to [min,max].
//!  • Wheel: scroll DOWN (deltaY>0) zooms OUT (distance grows) → `dzoom +=
//!    deltaY*zoom_sens`. orbit.tick() clamps distance.
//!  • Pick dispatch: each picked submesh name is matched against pick_names[i];
//!    on a match we fire the SSR-registered closure via dispatchEvent(
//!    pick_event_ids[i]). dispatchEvent runs whatever event slot the SSR
//!    `onPick(name, id)` registered, restoring that island's vid.
//!  • Hover: implemented (same ray path, throttled to one raycast per frame
//!    while NOT dragging). Stamps data-gl-hover on the canvas.
//!
//! ── Context-restore (Registry replay) ───────────────────────────────────────
//! GlScene's create block runs exactly ONCE per instance (`resources_sent`).
//! Every create* is mirrored into `inst.registry`. On restore the bridge calls
//! `glscene_frame_restore` (selected to the right instance first), which sets
//! `needs_replay`; the next frame emits `registry.replay(&enc)`. Asset Reader
//! bytes live in the page-scoped asset region (shared across instances while ≥1
//! is live — see `live_count`), so the recorded pointers stay valid.

const std = @import("std");
const verve = @import("verve");
const gl = verve.gl;
const anim = verve.anim;

extern "verve" fn gl_start(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;
// P10 slice 2d: WebGPU frame loop + synchronous backend feature-detect. When
// WebGPU is available the scene emits WGSL + drives gl_start_gpu instead of GLSL +
// gl_start; the command stream is otherwise identical (gpuInterpret handles it).
extern "verve" fn gl_start_gpu(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;
extern "verve" fn gl_webgpu_available() i32;
extern "verve" fn gl_load(url_ptr: [*]const u8, url_len: u32, cb_ptr: [*]const u8, cb_len: u32) void;
// P8 onPickExport: dispatch a bubbling DOM CustomEvent(name, {detail:{name:detail}})
// from the element behind `ref_handle` (the canvas). No-op if the handle is stale.
extern "verve" fn gl_emit_event(ref_handle: i32, name_ptr: [*]const u8, name_len: u32, detail_ptr: [*]const u8, detail_len: u32) void;

// ── Tuning ───────────────────────────────────────────────────────────────────

const drag_sens: f32 = 0.01; // rad per client px
const zoom_sens: f32 = 0.005; // distance per wheel deltaY unit
const fov_y: f32 = 1.0; // vertical fov (rad) — MUST match the proj below

const vmesh_ready_export = "glscene_vmesh_ready";
const env_ready_export = "glscene_env_ready";
const tex_ready_export = "glscene_tex_ready";
const frame_export = "glscene_frame";

// GPU resource handles (kept distinct from IBL handles 16/17/18).
const vbuf: u32 = 1;
const ibuf: u32 = 2;
// Shader handles 1..4 (opaque PBR) and 6..9 (alpha-test PBR) live in the bridge's
// `st.shaders[]` namespace (distinct from buffers/textures) — see shaderHandleFor.
const irr_handle: u32 = 16;
const spec_handle: u32 = 17;
const lut_handle: u32 = 18;

// P9 slice 3 — single directional shadow map. The depth-only shader lives at
// handle 5 (above the four PBR variants 1..4); the shadow map is handle 1 in the
// bridge's separate `st.shadowMaps[]` namespace.
const depth_shader: u32 = 5;
const depth_at_shader: u32 = 10; // alpha-tested depth shader for MASK cutout shadows
const shadow_handle: u32 = 1;
// Multi-caster 2D shadow atlas (was a single 1024² map). Now a 4096² atlas tiled
// into 1024² cells; up to max_2d_casters (4) directional/spot casters share row 0.
const shadow_size: u32 = gl.command.shadow_atlas_dim; // 4096
const shadow_tile: u32 = gl.command.shadow_tile_dim; // 1024

// Point-light shadow atlas (multi-caster). RGBA8 1536×4096: 3 cols × 8 rows of
// 512² tiles = 6 faces × up to max_point_casters (4) point casters. Caster `pidx`
// occupies rows [pidx*2, pidx*2+1]. Lives in st.shadowMaps[] at handle 2.
const point_atlas_handle: u32 = 2;
const point_atlas_w: u32 = gl.command.point_atlas_w; // 1536
const point_atlas_h: u32 = gl.command.point_atlas_h; // 4096
const point_atlas_tile: u32 = 512;

const max_submesh = 128; // per-instance pool cap (was 8); sizes Scene + all Inst pools
const max_tex = 8; // material-texture cap (per mesh)

// A worker-decoded external texture awaiting upload on the next frame.
const TexUpload = struct { handle: u32, w: u32, h: u32, ptr: u32, len: u32, srgb: bool };
const max_picks = 4; // mirror of gl_scene.zig max_picks
const max_name = 64; // per-name fixed storage
const no_hover_hash: u32 = 0xFFFF_FFFF;

// Up to eight PBR variants per mesh: variant_pbr is always set; normal_map,
// emissive, and alpha_test are independent sub-bits. Opaque variants map to
// shader handles 1..4; alpha-test variants map to handles 6..9 in the bridge's
// `st.shaders[]` namespace (separate from buffers/textures). Handle 5 is the
// depth-only shader; handle 1 in `st.shadowMaps[]` is the shadow map.
const variant_pbr = gl.command.variant_pbr;
const variant_nm = gl.command.variant_normal_map;
const variant_em = gl.command.variant_emissive;
const variant_at = gl.command.variant_alpha_test;
const variant_ds = gl.command.variant_double_sided;
const variant_inst = gl.command.variant_instanced; // T6: GPU instancing
const variant_fog = gl.command.variant_fog; // distance fog mix before tonemap
const variant_morph = gl.command.variant_morph; // M7: morph-target blending

// GPU instancing (v1): per-instance mat4(16) + color(4) = 20 f32 = 80 B each.
const max_instances = 1024;

// M7: morph targets. max_morph_targets sizes the per-instance weight array in
// Inst (static pool, not stack). 64 covers all known real-world rigs.
const max_morph_targets: u32 = 64;
// Morph data texture handle (M7). Separate from material textures (1..8) and
// IBL (16..18). No collision with shader handles (distinct namespace).
const morph_tex_handle: u32 = 19;

// ── Props copies (decoded from SSR data-props; copied into the Inst before the
//    chunk arena that held the decode result is reset) ─────────────────────────

const Props = struct {
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
    scrub: bool, // scroll-scrub mode (Task 9); wired to timeline in Task 9
    pick_export_names: []const []const u8, // P8 onPickExport: per-slot DOM event name ("" = none)
    // NOTE: NO fog field. Fog arrives via the canvas `data-glfog` attribute
    // (refGetAttr), parsed in hydrate — NOT through Props. This MUST mirror
    // src/core/gl_scene.zig Props exactly (14 fields); see the fuller note
    // there (the blank GlScene pages were the chunk-data memory window in
    // build.zig, not a decodeProps miscompile).
};

comptime {
    std.debug.assert(@typeInfo(Props).@"struct".fields.len == 14);
}

// ── Per-instance state ─────────────────────────────────────────────────────────
//
// Every field that was a module-level singleton pre-P7 now lives here, one copy
// per `<verve-island data-name="GlScene">` on the page. Field defaults match the
// pre-P7 hydrate reset so `Inst{}` IS the fresh-hydrate reset (replaces the old
// ~30-line manual block).
const Inst = struct {
    vid: u32 = 0, // island vid this slot serves (0 = free)
    in_use: bool = false,

    // URL buffers — asset paths copied out of the arena (128 matches GlDemo).
    src_buf: [128]u8 = undefined,
    src_len: usize = 0,
    env_buf: [128]u8 = undefined,
    env_len: usize = 0,

    // Pick registry (onPick closures + onPickExport DOM-event names).
    pick_names: [max_picks][max_name]u8 = undefined,
    pick_name_lens: [max_picks]usize = undefined,
    pick_ids: [max_picks]u32 = undefined,
    pick_exports: [max_picks][max_name]u8 = undefined,
    pick_export_lens: [max_picks]usize = undefined,
    pick_count: usize = 0,

    auto_rotate: f32 = 0,
    scrub_enabled: bool = false,
    model_yaw: f32 = 0, // model Y-rotation (radians); set via glscene_anim_set

    // Scrub timeline (Task 9).
    anim_setter_slot: u32 = 0,
    anim_resolver_slot: u32 = 0,
    scrub_built: bool = false,
    scrub_anim_id: u32 = 0,

    // Camera + input.
    orbit: gl.Orbit = .{},
    input: gl.OrbitInput = .{},

    // Drag / pick interaction state.
    dragging: bool = false,
    last_x: f64 = 0,
    last_y: f64 = 0,
    pick_pending: bool = false,
    pick_ndc_x: f32 = 0,
    pick_ndc_y: f32 = 0,
    hover_have: bool = false,
    hover_ndc_x: f32 = 0,
    hover_ndc_y: f32 = 0,
    hover_name_hash: u32 = no_hover_hash,

    // Assets.
    asset: ?gl.vmesh.Reader = null,
    env_reader: ?gl.venv.Reader = null,

    camera_pos: [3]f32 = .{ 0, 0, 4 }, // updated each frame to orbit.eye()

    // Scene graph (P6). Node 0 = root "model"; node s+1 = submesh s.
    scene: gl.Scene(max_submesh + 1) = .{},
    scene_built: bool = false,
    node_rot: [max_submesh][3]f32 = [_][3]f32{.{ 0, 0, 0 }} ** max_submesh,
    node_rot_applied: [max_submesh][3]f32 = [_][3]f32{.{ 0, 0, 0 }} ** max_submesh,
    node_pos: [max_submesh][3]f32 = [_][3]f32{.{ 0, 0, 0 }} ** max_submesh,
    node_pos_applied: [max_submesh][3]f32 = [_][3]f32{.{ 0, 0, 0 }} ** max_submesh,
    node_scale: [max_submesh][3]f32 = [_][3]f32{.{ 1, 1, 1 }} ** max_submesh,
    node_scale_applied: [max_submesh][3]f32 = [_][3]f32{.{ 1, 1, 1 }} ** max_submesh,
    model_yaw_applied: f32 = 0,

    // Per-submesh draw pools — each drawPbr points at a STABLE distinct slot;
    // the JS interpreter dereferences these AFTER the frame fn returns. Inside a
    // fixed-array Inst, `&inst.<pool>[s]` is a stable absolute address.
    mvps: [max_submesh][16]f32 = undefined,
    model_mats: [max_submesh][16]f32 = undefined,
    normal9s: [max_submesh][9]f32 = undefined,
    submesh_aabb: [max_submesh]gl.cull.Aabb = undefined, // P9 slice 2 (CPU-only)
    mats: [max_submesh][12]f32 = undefined, // per-submesh material block
    // Pass-2 transparency sort scratch. Kept in Inst (static), NOT on the
    // frame stack: at max_submesh=128 these two arrays are 1 KB, and keeping
    // the frame's stack frame lean regardless of capacity avoids re-pressuring
    // the per-chunk wasm stack (build.zig stack_size) as max_submesh grows.
    tidx: [max_submesh]u32 = undefined,
    tkey: [max_submesh]f32 = undefined,

    // Multi-light array: up to max_lights lights, 16 f32 each.
    // Layout per light i (base = i*16):
    //   [0]  type (0=dir, 1=point, 2=spot)   [1]  intensity
    //   [2..4]  pos x,y,z                    [5..7]  dir x,y,z (normalized)
    //   [8..10] color r,g,b                  [11] range
    //   [12] cosInner  [13] cosOuter          [14,15] _pad
    lights: [gl.command.max_lights * 16]f32 = blk: {
        var a = [_]f32{0} ** (gl.command.max_lights * 16);
        // Default: single white directional light matching the old 8-f32 defaults.
        a[0] = 0; // type = directional
        a[1] = 3; // intensity
        // pos [2..4] = 0 (directional has no position)
        a[5] = -0.39801488; // dir x
        a[6] = -0.69652603; // dir y
        a[7] = -0.59702231; // dir z
        a[8] = 1;
        a[9] = 1;
        a[10] = 1; // white
        break :blk a;
    },
    light_count: u32 = 1,

    // Distance fog (mode,r,g,b,near,far,density,_pad). Default off.
    fog_params: [8]f32 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    fog_enabled: bool = false,

    // GPU-resource registry for context-restore replay (cap 80; morph adds 16 more
    // shader variants + 1 morph tex: 2 buf + 36 shader + depth + depth_at + shadow
    // + 8 tex + 1 morph_tex + 3 IBL = 54 max; 80 gives comfortable headroom).
    registry: gl.Registry(80) = .{},
    resources_sent: bool = false,
    needs_replay: bool = false,

    // P-compressed-textures: external (compressed) material textures stream in via
    // gl_load (worker-decoded to [w][h]+RGBA), are queued here, and uploaded on the
    // next frame (gl_load callbacks run outside a frame, so they can't emit GPU
    // commands directly). Raw (in-blob) textures still upload inline in sendResources.
    tex_scan: u32 = 0, // next texture index to consider for an external load
    tex_loading: i32 = -1, // texture index currently in-flight (-1 = none)
    tex_url_buf: [192]u8 = undefined, // scratch for the derived "<stem>.tex{N}.<ext>"
    tex_up: [max_tex]TexUpload = undefined, // decoded textures awaiting createTexture
    tex_up_n: u32 = 0,

    // Refs resolved once in hydrate (scoped); frame/asset callbacks run unscoped.
    canvas_handle: ?i32 = null,
    scroll_section_handle: ?i32 = null,

    // Per-frame frustum-cull counters (T3). Reset at frame start; shadow fields
    // incremented in T4. Exported via glscene_cull_stats().
    cull_main_drawn: u32 = 0,
    cull_main_culled: u32 = 0,
    cull_shadow_drawn: u32 = 0,
    cull_shadow_culled: u32 = 0,

    // GPU instancing (T6): per-instance mat4(16)+color(4) = 20 f32, animated per frame.
    // Lives in Inst (static) NOT on the frame stack — 1024×80 B = 80 KB would overflow
    // the 64 KB chunk stack (same lesson as the frustum-cull OOB).
    instance_scratch: [max_instances][20]f32 = undefined,
    // view·proj for the instanced shader (pv, no model baked in).
    vp_mat: [16]f32 = undefined,
    // Accumulated frame time (ms) for instanced animation (wraps at ~1h; fine for animation).
    inst_time_ms: f32 = 0,

    // M7: morph-target state. Lives in Inst (static pool) — NOT on the frame
    // stack. morph_weights is indexed by target; active set is the top-32 by
    // |weight|. Zeroed by default (Inst{} = no morph animation).
    morph_enabled: bool = false,
    morph_weights: [max_morph_targets]f32 = .{0} ** max_morph_targets,
    morph_active_idx: [32]u32 = .{0} ** 32,
    morph_active_wt: [32]f32 = .{0} ** 32,
    morph_count: u32 = 0,
    morph_tex_recorded: bool = false, // true once createMorphTex emitted (for restore)
    // M8: per-index runtime-set flag. When set, the per-frame baked-clip advance
    // skips that index so runtime tweens (or parseMorph seeds) are not clobbered.
    morph_runtime_set: [max_morph_targets]bool = .{false} ** max_morph_targets,

    // ── Multi-caster shadow state (up to max_2d_casters 2D + max_point_casters
    // point, all at once). EVERY matrix a command points at must remain valid at
    // deferred-decode time (the bridge walks cmd_buf AFTER glscene_frame returns),
    // so each caster owns its OWN persistent buffer here in Inst — never the frame
    // stack (chunk wasm stack is 64 KB; these pools would overflow it). The price
    // of deferred decode is ~33 KB of static per-caster matrix storage.
    //
    // 2D casters (directional/spot): CONTIGUOUS VP array so &shadow_vp_mats[0] +
    // n_2d_casters feeds one bind_shadow_map; per-caster per-submesh depth MVPs.
    shadow_vp_mats: [gl.command.max_2d_casters][16]f32 = undefined,
    depth_mvps_mc: [gl.command.max_2d_casters][max_submesh][16]f32 = undefined,
    // Point casters: per-caster 6-face VPs + light pos + far plane.
    face_vp_mc: [gl.command.max_point_casters][6][16]f32 = undefined,
    point_lp_mc: [gl.command.max_point_casters][3]f32 = undefined,
    point_far_mc: [gl.command.max_point_casters]f32 = undefined,
    // Caster tables: light index per slot, populated by parseLights/hydrate.
    n_2d_casters: u32 = 0,
    casters_2d: [gl.command.max_2d_casters]u32 = undefined,
    // ── CSM (Slice 2): the directional caster is split into `cascade_count`
    // cascades occupying 2D atlas slots 0..cascade_count-1. csm_light is its light
    // index (-1 = no CSM caster this frame → behave like slice 1, spots/points only).
    // cascade_splits (view-space FAR per cascade) + view_forward are PERSISTENT
    // because set_csm points at them (deferred decode walks cmd_buf post-return).
    csm_light: i32 = -1,
    cascade_count: u32 = 0,
    cascade_splits: [4]f32 = .{ 0, 0, 0, 0 },
    view_forward: [3]f32 = .{ 0, 0, -1 },
    n_point_casters: u32 = 0,
    casters_point: [gl.command.max_point_casters]u32 = undefined,
    // True once createPointShadow has been emitted for this instance.
    point_atlas_sent: bool = false,

    // ── Area lights (Slice 3, LTC). Pool of up to max_area_lights rect lights,
    // 16 f32 each (4 vec4). Layout per area light i (base = i*16) — mirrors the
    // S3T1 shader UBO packing:
    //   a0 = [pos.x, pos.y, pos.z, intensity]
    //   a1 = [ex.x, ex.y, ex.z, two_sided]      (ex = half-width edge)
    //   a2 = [ey.x, ey.y, ey.z, shadow_slot]    (ey = half-height edge; 2D slot or -1)
    //   a3 = [color.r, color.g, color.b, shadow_kind]  (0=none, 1=2D shadow)
    // set_area_lights points at &area_lights[0] (deferred decode → persistent).
    area_lights: [gl.command.max_area_lights * 16]f32 = .{0} ** (gl.command.max_area_lights * 16),
    area_count: u32 = 0,
    // Area shadow casters share the 2D atlas slots (after cascades+spots). For each
    // occupied 2D slot, slot_area_li = the area-light index that owns it (-1 = a
    // regular directional/spot/CSM caster). Set by classifyAreaCasters; read in the
    // 2D depth-pass loop to pick the area VP vs. the light-pool VP.
    slot_area_li: [gl.command.max_2d_casters]i32 = .{-1} ** gl.command.max_2d_casters,
};

const MAX_INSTANCES = 4;
var instances: [MAX_INSTANCES]Inst = .{Inst{}} ** MAX_INSTANCES;
// The instance the bridge selected for the in-flight dispatch (frame / event /
// asset callback / restore). Set by `glscene_select`; null = unknown vid (every
// export null-guards → silent no-op).
var current: ?*Inst = null;
// Count of live instances. Gates the page-scoped asset-region reset: only the
// FIRST instance of a fresh population resets it (subsequent instances share the
// region; a full unmount→remount re-resets). See hydrate / glscene_unmount.
var live_count: u32 = 0;

var reduced_motion: bool = false; // page media query — same for every instance
// Debug/test-harness freeze: pins the auto-orbit so a CDP run has a stable frame
// for pixel metrics (mirrors GlSkin's glskin_freeze). Page-global, like
// reduced_motion. Toggled via the glscene_freeze / glscene_unfreeze exports
// (wired to a /gl-multishadow button); orbit drag still works while frozen.
var freeze: bool = false;
// P10 slice 2d: page-global backend choice. Set once at the first hydrate from
// gl_webgpu_available(); selects WGSL + gl_start_gpu vs GLSL + gl_start, and
// whether the clip-space z fix is applied to the proj/light matrices.
var use_webgpu: bool = false;

/// Clip-space z remap [−1,1]→[0,1] for WebGPU (gl.math proj/ortho are GL
/// convention; WebGPU clips z<0 and stores depth in [0,1]). Identity on WebGL2 so
/// that path is byte-for-byte unchanged. Premultiplied onto proj (color mvp) and
/// the light matrix (shadow), matching GlSceneWebgpu's computeLightVp (2c).
fn clipFix() gl.math.Mat4 {
    if (!use_webgpu) {
        var m = gl.math.Mat4{ .m = [_]f32{0} ** 16 };
        m.m[0] = 1;
        m.m[5] = 1;
        m.m[10] = 1;
        m.m[15] = 1;
        return m;
    }
    var z = gl.math.Mat4{ .m = [_]f32{0} ** 16 };
    z.m[0] = 1;
    z.m[5] = 1;
    z.m[10] = 0.5;
    z.m[14] = 0.5;
    z.m[15] = 1;
    return z;
}

// Shared transient scratch — `glscene_frame` fills it and returns its pointer;
// the bridge walks the stream synchronously before the next frame call, so
// instances never interleave within a tick. NOT per-instance (saves 3×4 KB).
//
// MULTI-CASTER + CSM WORST CASE. Every command record = 4-byte header + payload.
// With max_submesh M = 128, up to max_2d_casters (8 — CSM: 4 cascades share the 2D
// atlas + up to 4 spots/dir) 2D passes + up to max_point_casters (4) point casters
// (each 6 faces) + one main pass, all in a single frame:
//
//   2D depth (per slot): beginShadowPass(4+20=24) + M × MASK-worst
//                          (bindTexture 12 + drawDepthAt 32 = 44) + endShadowPass(12)
//                          = 24 + 128×44 + 12 = 5,668; × 8 = 45,344
//   point depth (per caster): 6 faces × (beginPointShadowFace(4+28=32) +
//                          M × drawPointDepth(4+20=24)) = 6×(32 + 128×24) = 18,624;
//                          × 4 = 74,496; + ONE endPointShadow(12) total
//   main: beginFrame(28) + set_csm(4+12=16) + M × DS-BLEND-worst(≈384: 2-pass
//                          setPipeline+setLights+bindIbl+bindShadowMap(20)+
//                          bindPointShadow(12)+fog+morph+5×bindTexture+drawPbr) +
//                          endFrame(4) = 28 + 16 + 128×384 + 4 = 49,200
//   one-time create/replay burst (shares this buffer on frame 1): ≈ 800 B
//   length header(4) + slop.
//
//   45,344 + 74,508 + 49,200 + 800 + 4 ≈ 169,856 → round up to 192 KiB.
// (CDP at T4 confirms this fits chunk memory; the static-buffer growth to
// 196,608 B is the price of simultaneous CSM + multi-caster shadows.)
const cmd_buf_cap: usize = 192 * 1024;
var cmd_buf: [cmd_buf_cap]u8 = undefined;

fn findSlot(vid: u32) ?*Inst {
    for (&instances) |*it| {
        if (it.in_use and it.vid == vid) return it;
    }
    return null;
}

/// Find this vid's slot (re-hydrate) or claim a free one; fully reset to fresh
/// (`Inst{}`) either way — that reset replaces the pre-P7 manual hydrate block.
/// `live_count` bumps only when a NEW slot is claimed. Returns null if the pool
/// is exhausted (> MAX_INSTANCES scenes co-resident).
fn allocSlot(vid: u32) ?*Inst {
    const slot = findSlot(vid) orelse blk: {
        for (&instances) |*it| {
            if (!it.in_use) break :blk it;
        }
        return null;
    };
    const newly = !slot.in_use;
    slot.* = Inst{};
    slot.vid = vid;
    slot.in_use = true;
    if (newly) live_count += 1;
    return slot;
}

fn slotIndex(inst: *const Inst) usize {
    return (@intFromPtr(inst) - @intFromPtr(&instances[0])) / @sizeOf(Inst);
}

/// Bridge calls this immediately before every frame / event / asset-callback /
/// restore dispatch, so the export operates on the right instance.
export fn glscene_select(root_id: u32) void {
    current = findSlot(root_id);
}

/// Bridge calls this when an island's canvas disconnects (the point JS runs
/// `disposeGlState`). Reclaims the slot so add/remove cycles don't exhaust the
/// pool, and decrements `live_count` so the asset region re-resets on the next
/// fresh population.
export fn glscene_unmount(root_id: u32) void {
    if (findSlot(root_id)) |inst| {
        if (current == inst) current = null;
        inst.* = Inst{}; // in_use=false, vid=0
        if (live_count > 0) live_count -= 1;
    }
}

// ── helpers (pure — no instance state) ─────────────────────────────────────────

const up_vec = gl.math.Vec3.init(0, 1, 0);

/// Stable shader handle per PBR variant:
///   opaque:          pbr→1, pbr|nm→2, pbr|em→3, pbr|nm|em→4
///   alpha-test:      pbr|at→6, pbr|nm|at→7, pbr|em|at→8, pbr|nm|em|at→9
///   double-sided:    pbr|ds→11..pbr|nm|em|at|ds→18
/// Handle 5 = depth-only shadow shader; handle 10 = alpha-tested depth shader.
fn shaderHandleFor(variant: u32) u32 {
    return switch (variant) {
        variant_pbr => 1,
        variant_pbr | variant_nm => 2,
        variant_pbr | variant_em => 3,
        variant_pbr | variant_nm | variant_em => 4,
        variant_pbr | variant_at => 6,
        variant_pbr | variant_nm | variant_at => 7,
        variant_pbr | variant_em | variant_at => 8,
        variant_pbr | variant_nm | variant_em | variant_at => 9,
        variant_pbr | variant_ds => 11,
        variant_pbr | variant_nm | variant_ds => 12,
        variant_pbr | variant_em | variant_ds => 13,
        variant_pbr | variant_nm | variant_em | variant_ds => 14,
        variant_pbr | variant_at | variant_ds => 15,
        variant_pbr | variant_nm | variant_at | variant_ds => 16,
        variant_pbr | variant_em | variant_at | variant_ds => 17,
        variant_pbr | variant_nm | variant_em | variant_at | variant_ds => 18,
        variant_pbr | variant_inst => 19, // T6: GPU instancing (non-shadow; handle 19)
        // Fog variants (base+fog → 20–27, ds+fog → 28–35, instanced+fog → 36):
        variant_pbr | variant_fog => 20,
        variant_pbr | variant_nm | variant_fog => 21,
        variant_pbr | variant_em | variant_fog => 22,
        variant_pbr | variant_nm | variant_em | variant_fog => 23,
        variant_pbr | variant_at | variant_fog => 24,
        variant_pbr | variant_nm | variant_at | variant_fog => 25,
        variant_pbr | variant_em | variant_at | variant_fog => 26,
        variant_pbr | variant_nm | variant_em | variant_at | variant_fog => 27,
        variant_pbr | variant_ds | variant_fog => 28,
        variant_pbr | variant_nm | variant_ds | variant_fog => 29,
        variant_pbr | variant_em | variant_ds | variant_fog => 30,
        variant_pbr | variant_nm | variant_em | variant_ds | variant_fog => 31,
        variant_pbr | variant_at | variant_ds | variant_fog => 32,
        variant_pbr | variant_nm | variant_at | variant_ds | variant_fog => 33,
        variant_pbr | variant_em | variant_at | variant_ds | variant_fog => 34,
        variant_pbr | variant_nm | variant_em | variant_at | variant_ds | variant_fog => 35,
        variant_pbr | variant_inst | variant_fog => 36,
        // Morph variants (base+morph → 37–44, ds+morph → 45–52):
        // No instanced+morph (both backends @compileError) and no skinned+morph.
        variant_pbr | variant_morph => 37,
        variant_pbr | variant_nm | variant_morph => 38,
        variant_pbr | variant_em | variant_morph => 39,
        variant_pbr | variant_nm | variant_em | variant_morph => 40,
        variant_pbr | variant_at | variant_morph => 41,
        variant_pbr | variant_nm | variant_at | variant_morph => 42,
        variant_pbr | variant_em | variant_at | variant_morph => 43,
        variant_pbr | variant_nm | variant_em | variant_at | variant_morph => 44,
        variant_pbr | variant_ds | variant_morph => 45,
        variant_pbr | variant_nm | variant_ds | variant_morph => 46,
        variant_pbr | variant_em | variant_ds | variant_morph => 47,
        variant_pbr | variant_nm | variant_em | variant_ds | variant_morph => 48,
        variant_pbr | variant_at | variant_ds | variant_morph => 49,
        variant_pbr | variant_nm | variant_at | variant_ds | variant_morph => 50,
        variant_pbr | variant_em | variant_at | variant_ds | variant_morph => 51,
        variant_pbr | variant_nm | variant_em | variant_at | variant_ds | variant_morph => 52,
        // Point-shadow receiver variants (variant_shadow_point): 16 combos at handles 53–68.
        // No instanced+point (both backends @compileError); no fog or morph with point shadow v1.
        variant_pbr | gl.command.variant_shadow_point => 53,
        variant_pbr | variant_nm | gl.command.variant_shadow_point => 54,
        variant_pbr | variant_em | gl.command.variant_shadow_point => 55,
        variant_pbr | variant_nm | variant_em | gl.command.variant_shadow_point => 56,
        variant_pbr | variant_at | gl.command.variant_shadow_point => 57,
        variant_pbr | variant_nm | variant_at | gl.command.variant_shadow_point => 58,
        variant_pbr | variant_em | variant_at | gl.command.variant_shadow_point => 59,
        variant_pbr | variant_nm | variant_em | variant_at | gl.command.variant_shadow_point => 60,
        variant_pbr | variant_ds | gl.command.variant_shadow_point => 61,
        variant_pbr | variant_nm | variant_ds | gl.command.variant_shadow_point => 62,
        variant_pbr | variant_em | variant_ds | gl.command.variant_shadow_point => 63,
        variant_pbr | variant_nm | variant_em | variant_ds | gl.command.variant_shadow_point => 64,
        variant_pbr | variant_at | variant_ds | gl.command.variant_shadow_point => 65,
        variant_pbr | variant_nm | variant_at | variant_ds | gl.command.variant_shadow_point => 66,
        variant_pbr | variant_em | variant_at | variant_ds | gl.command.variant_shadow_point => 67,
        variant_pbr | variant_nm | variant_em | variant_at | variant_ds | gl.command.variant_shadow_point => 68,
        else => unreachable,
    };
}

/// Compose per-node Euler radians (X,Y,Z) into a quaternion (Qz·Qy·Qx).
fn nodeQuat(r: [3]f32) gl.math.Quat {
    const qx = gl.math.Quat.fromAxisAngle(gl.math.Vec3.init(1, 0, 0), r[0]);
    const qy = gl.math.Quat.fromAxisAngle(gl.math.Vec3.init(0, 1, 0), r[1]);
    const qz = gl.math.Quat.fromAxisAngle(gl.math.Vec3.init(0, 0, 1), r[2]);
    return gl.math.Quat.mul(gl.math.Quat.mul(qz, qy), qx);
}

/// vmesh texture index → wire handle (slot t gets handle t+1); negatives → 0.
fn texHandle(i: i32) u32 {
    return if (i >= 0) @intCast(i + 1) else 0;
}

/// Map an ORIGINAL triangle index to its owning submesh by scanning index ranges.
fn submeshOfTri(a: *const gl.vmesh.Reader, tri: u32) ?u32 {
    const first_index: u32 = tri * 3;
    var s: u32 = 0;
    while (s < a.submesh_count) : (s += 1) {
        const sub = a.submesh(s);
        const start = sub.index_byte_off / 2; // u16 indices: 2 bytes each
        if (first_index >= start and first_index < start + sub.index_count) return s;
    }
    return null;
}

/// Convert client (clientX, clientY) to NDC using the canvas bounding rect.
fn clientToNdc(canvas: i32, cx: f64, cy: f64, ndc_x: *f32, ndc_y: *f32) void {
    const r = verve.refRect(canvas);
    const nx: f64 = if (r.w == 0) 0 else (cx - r.x) / r.w * 2.0 - 1.0;
    const ny: f64 = if (r.h == 0) 0 else 1.0 - (cy - r.y) / r.h * 2.0;
    ndc_x.* = @floatCast(nx);
    ndc_y.* = @floatCast(ny);
}

fn bytesAsF32(b: []const u8) []const f32 {
    const ptr: [*]const f32 = @ptrCast(@alignCast(b.ptr));
    return ptr[0 .. b.len / 4];
}

fn bytesAsU16(b: []const u8) []const u16 {
    const ptr: [*]const u16 = @ptrCast(@alignCast(b.ptr));
    return ptr[0 .. b.len / 2];
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

fn canvasRef(inst: *const Inst) ?i32 {
    return inst.canvas_handle;
}

/// Model-local AABB over a submesh's indexed vertex positions (stride 12 f32,
/// pos xyz @0). An empty range yields an inverted (inf) box (never visible).
fn submeshLocalAabb(verts: []const f32, indices: []const u16, first: u32, count: u32) gl.cull.Aabb {
    const inf = std.math.inf(f32);
    var lo = gl.math.Vec3.init(inf, inf, inf);
    var hi = gl.math.Vec3.init(-inf, -inf, -inf);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const vi = @as(usize, indices[first + i]) * 12;
        const x = verts[vi];
        const y = verts[vi + 1];
        const z = verts[vi + 2];
        lo = gl.math.Vec3.init(@min(lo.x, x), @min(lo.y, y), @min(lo.z, z));
        hi = gl.math.Vec3.init(@max(hi.x, x), @max(hi.y, y), @max(hi.z, z));
    }
    return .{ .min = lo, .max = hi };
}

// ── shader emission (records into the instance's registry) ──────────────────────

fn createShaderForVariant(inst: *Inst, enc: *gl.Encoder, variant: u32) void {
    switch (variant) {
        variant_pbr => emitShader(inst, enc, variant_pbr),
        variant_pbr | variant_nm => emitShader(inst, enc, variant_pbr | variant_nm),
        variant_pbr | variant_em => emitShader(inst, enc, variant_pbr | variant_em),
        variant_pbr | variant_nm | variant_em => emitShader(inst, enc, variant_pbr | variant_nm | variant_em),
        variant_pbr | variant_at => emitShader(inst, enc, variant_pbr | variant_at),
        variant_pbr | variant_nm | variant_at => emitShader(inst, enc, variant_pbr | variant_nm | variant_at),
        variant_pbr | variant_em | variant_at => emitShader(inst, enc, variant_pbr | variant_em | variant_at),
        variant_pbr | variant_nm | variant_em | variant_at => emitShader(inst, enc, variant_pbr | variant_nm | variant_em | variant_at),
        variant_pbr | variant_ds => emitShader(inst, enc, variant_pbr | variant_ds),
        variant_pbr | variant_nm | variant_ds => emitShader(inst, enc, variant_pbr | variant_nm | variant_ds),
        variant_pbr | variant_em | variant_ds => emitShader(inst, enc, variant_pbr | variant_em | variant_ds),
        variant_pbr | variant_nm | variant_em | variant_ds => emitShader(inst, enc, variant_pbr | variant_nm | variant_em | variant_ds),
        variant_pbr | variant_at | variant_ds => emitShader(inst, enc, variant_pbr | variant_at | variant_ds),
        variant_pbr | variant_nm | variant_at | variant_ds => emitShader(inst, enc, variant_pbr | variant_nm | variant_at | variant_ds),
        variant_pbr | variant_em | variant_at | variant_ds => emitShader(inst, enc, variant_pbr | variant_em | variant_at | variant_ds),
        variant_pbr | variant_nm | variant_em | variant_at | variant_ds => emitShader(inst, enc, variant_pbr | variant_nm | variant_em | variant_at | variant_ds),
        variant_pbr | variant_inst => emitInstancedShader(inst, enc), // T6
        // Fog variants (handles 20–35 via emitShader, 36 via emitInstancedShader):
        variant_pbr | variant_fog => emitShader(inst, enc, variant_pbr | variant_fog),
        variant_pbr | variant_nm | variant_fog => emitShader(inst, enc, variant_pbr | variant_nm | variant_fog),
        variant_pbr | variant_em | variant_fog => emitShader(inst, enc, variant_pbr | variant_em | variant_fog),
        variant_pbr | variant_nm | variant_em | variant_fog => emitShader(inst, enc, variant_pbr | variant_nm | variant_em | variant_fog),
        variant_pbr | variant_at | variant_fog => emitShader(inst, enc, variant_pbr | variant_at | variant_fog),
        variant_pbr | variant_nm | variant_at | variant_fog => emitShader(inst, enc, variant_pbr | variant_nm | variant_at | variant_fog),
        variant_pbr | variant_em | variant_at | variant_fog => emitShader(inst, enc, variant_pbr | variant_em | variant_at | variant_fog),
        variant_pbr | variant_nm | variant_em | variant_at | variant_fog => emitShader(inst, enc, variant_pbr | variant_nm | variant_em | variant_at | variant_fog),
        variant_pbr | variant_ds | variant_fog => emitShader(inst, enc, variant_pbr | variant_ds | variant_fog),
        variant_pbr | variant_nm | variant_ds | variant_fog => emitShader(inst, enc, variant_pbr | variant_nm | variant_ds | variant_fog),
        variant_pbr | variant_em | variant_ds | variant_fog => emitShader(inst, enc, variant_pbr | variant_em | variant_ds | variant_fog),
        variant_pbr | variant_nm | variant_em | variant_ds | variant_fog => emitShader(inst, enc, variant_pbr | variant_nm | variant_em | variant_ds | variant_fog),
        variant_pbr | variant_at | variant_ds | variant_fog => emitShader(inst, enc, variant_pbr | variant_at | variant_ds | variant_fog),
        variant_pbr | variant_nm | variant_at | variant_ds | variant_fog => emitShader(inst, enc, variant_pbr | variant_nm | variant_at | variant_ds | variant_fog),
        variant_pbr | variant_em | variant_at | variant_ds | variant_fog => emitShader(inst, enc, variant_pbr | variant_em | variant_at | variant_ds | variant_fog),
        variant_pbr | variant_nm | variant_em | variant_at | variant_ds | variant_fog => emitShader(inst, enc, variant_pbr | variant_nm | variant_em | variant_at | variant_ds | variant_fog),
        variant_pbr | variant_inst | variant_fog => emitInstancedShader(inst, enc), // fog-aware instanced (handle 36)
        // Morph variants (handles 37–52 via emitShader; no instanced+morph):
        variant_pbr | variant_morph => emitShader(inst, enc, variant_pbr | variant_morph),
        variant_pbr | variant_nm | variant_morph => emitShader(inst, enc, variant_pbr | variant_nm | variant_morph),
        variant_pbr | variant_em | variant_morph => emitShader(inst, enc, variant_pbr | variant_em | variant_morph),
        variant_pbr | variant_nm | variant_em | variant_morph => emitShader(inst, enc, variant_pbr | variant_nm | variant_em | variant_morph),
        variant_pbr | variant_at | variant_morph => emitShader(inst, enc, variant_pbr | variant_at | variant_morph),
        variant_pbr | variant_nm | variant_at | variant_morph => emitShader(inst, enc, variant_pbr | variant_nm | variant_at | variant_morph),
        variant_pbr | variant_em | variant_at | variant_morph => emitShader(inst, enc, variant_pbr | variant_em | variant_at | variant_morph),
        variant_pbr | variant_nm | variant_em | variant_at | variant_morph => emitShader(inst, enc, variant_pbr | variant_nm | variant_em | variant_at | variant_morph),
        variant_pbr | variant_ds | variant_morph => emitShader(inst, enc, variant_pbr | variant_ds | variant_morph),
        variant_pbr | variant_nm | variant_ds | variant_morph => emitShader(inst, enc, variant_pbr | variant_nm | variant_ds | variant_morph),
        variant_pbr | variant_em | variant_ds | variant_morph => emitShader(inst, enc, variant_pbr | variant_em | variant_ds | variant_morph),
        variant_pbr | variant_nm | variant_em | variant_ds | variant_morph => emitShader(inst, enc, variant_pbr | variant_nm | variant_em | variant_ds | variant_morph),
        variant_pbr | variant_at | variant_ds | variant_morph => emitShader(inst, enc, variant_pbr | variant_at | variant_ds | variant_morph),
        variant_pbr | variant_nm | variant_at | variant_ds | variant_morph => emitShader(inst, enc, variant_pbr | variant_nm | variant_at | variant_ds | variant_morph),
        variant_pbr | variant_em | variant_at | variant_ds | variant_morph => emitShader(inst, enc, variant_pbr | variant_em | variant_at | variant_ds | variant_morph),
        variant_pbr | variant_nm | variant_em | variant_at | variant_ds | variant_morph => emitShader(inst, enc, variant_pbr | variant_nm | variant_em | variant_at | variant_ds | variant_morph),
        // Point-shadow receiver variants (handles 53–68). No instanced+point, no fog/morph v1.
        variant_pbr | gl.command.variant_shadow_point => emitPointShader(inst, enc, variant_pbr),
        variant_pbr | variant_nm | gl.command.variant_shadow_point => emitPointShader(inst, enc, variant_pbr | variant_nm),
        variant_pbr | variant_em | gl.command.variant_shadow_point => emitPointShader(inst, enc, variant_pbr | variant_em),
        variant_pbr | variant_nm | variant_em | gl.command.variant_shadow_point => emitPointShader(inst, enc, variant_pbr | variant_nm | variant_em),
        variant_pbr | variant_at | gl.command.variant_shadow_point => emitPointShader(inst, enc, variant_pbr | variant_at),
        variant_pbr | variant_nm | variant_at | gl.command.variant_shadow_point => emitPointShader(inst, enc, variant_pbr | variant_nm | variant_at),
        variant_pbr | variant_em | variant_at | gl.command.variant_shadow_point => emitPointShader(inst, enc, variant_pbr | variant_em | variant_at),
        variant_pbr | variant_nm | variant_em | variant_at | gl.command.variant_shadow_point => emitPointShader(inst, enc, variant_pbr | variant_nm | variant_em | variant_at),
        variant_pbr | variant_ds | gl.command.variant_shadow_point => emitPointShader(inst, enc, variant_pbr | variant_ds),
        variant_pbr | variant_nm | variant_ds | gl.command.variant_shadow_point => emitPointShader(inst, enc, variant_pbr | variant_nm | variant_ds),
        variant_pbr | variant_em | variant_ds | gl.command.variant_shadow_point => emitPointShader(inst, enc, variant_pbr | variant_em | variant_ds),
        variant_pbr | variant_nm | variant_em | variant_ds | gl.command.variant_shadow_point => emitPointShader(inst, enc, variant_pbr | variant_nm | variant_em | variant_ds),
        variant_pbr | variant_at | variant_ds | gl.command.variant_shadow_point => emitPointShader(inst, enc, variant_pbr | variant_at | variant_ds),
        variant_pbr | variant_nm | variant_at | variant_ds | gl.command.variant_shadow_point => emitPointShader(inst, enc, variant_pbr | variant_nm | variant_at | variant_ds),
        variant_pbr | variant_em | variant_at | variant_ds | gl.command.variant_shadow_point => emitPointShader(inst, enc, variant_pbr | variant_em | variant_at | variant_ds),
        variant_pbr | variant_nm | variant_em | variant_at | variant_ds | gl.command.variant_shadow_point => emitPointShader(inst, enc, variant_pbr | variant_nm | variant_em | variant_at | variant_ds),
        else => unreachable,
    }
}

fn emitShader(inst: *Inst, enc: *gl.Encoder, comptime variant: u32) void {
    const handle = shaderHandleFor(variant); // handle keyed on the bare variant (1..52)
    // Every PBR program emitted here receives the 2D directional/spot shadow map.
    const full = variant | gl.command.variant_shadow;
    if (use_webgpu) {
        // One WGSL module (both stages) in the vs slot; fs slot 0/0.
        const w = gl.command.wgslPbr(full);
        enc.createShader(handle, full, @intCast(@intFromPtr(w.ptr)), @intCast(w.len), 0, 0);
        inst.registry.recordShader(handle, full, @intCast(@intFromPtr(w.ptr)), @intCast(w.len), 0, 0);
        return;
    }
    const vs = gl.command.pbrVertexSrc(full);
    const fs = gl.command.pbrFragmentSrc(full);
    enc.createShader(handle, full, @intCast(@intFromPtr(vs.ptr)), @intCast(vs.len), @intCast(@intFromPtr(fs.ptr)), @intCast(fs.len));
    inst.registry.recordShader(handle, full, @intCast(@intFromPtr(vs.ptr)), @intCast(vs.len), @intCast(@intFromPtr(fs.ptr)), @intCast(fs.len));
}

/// Emit a combined-shadow PBR receiver (variant | variant_shadow | variant_shadow_point)
/// at its distinct handle (53..68). Bakes BOTH the 2D and point sampling paths so the
/// SAME program receives up to max_2d_casters 2D casters AND up to max_point_casters
/// point casters simultaneously (selected per-light at runtime via v3.w shadow_kind).
/// The handle is keyed on (base | variant_shadow_point); variant_shadow is folded into
/// `full` here so the bridge derives both hasShadow (0x20) and hasPointShadow (0x8000).
fn emitPointShader(inst: *Inst, enc: *gl.Encoder, comptime base_variant: u32) void {
    const full = base_variant | gl.command.variant_shadow | gl.command.variant_shadow_point;
    // Handle keyed on the point bit only (matches shaderHandleFor's 53..68 table).
    const handle = shaderHandleFor(base_variant | gl.command.variant_shadow_point);
    if (use_webgpu) {
        const w = gl.command.wgslPbr(full);
        enc.createShader(handle, full, @intCast(@intFromPtr(w.ptr)), @intCast(w.len), 0, 0);
        inst.registry.recordShader(handle, full, @intCast(@intFromPtr(w.ptr)), @intCast(w.len), 0, 0);
        return;
    }
    const vs = gl.command.pbrVertexSrc(full);
    const fs = gl.command.pbrFragmentSrc(full);
    enc.createShader(handle, full, @intCast(@intFromPtr(vs.ptr)), @intCast(vs.len), @intCast(@intFromPtr(fs.ptr)), @intCast(fs.len));
    inst.registry.recordShader(handle, full, @intCast(@intFromPtr(vs.ptr)), @intCast(vs.len), @intCast(@intFromPtr(fs.ptr)), @intCast(fs.len));
}

fn emitDepthShader(inst: *Inst, enc: *gl.Encoder) void {
    if (use_webgpu) {
        const w = gl.command.wgslDepth();
        enc.createShader(depth_shader, gl.command.variant_depth, @intCast(@intFromPtr(w.ptr)), @intCast(w.len), 0, 0);
        inst.registry.recordShader(depth_shader, gl.command.variant_depth, @intCast(@intFromPtr(w.ptr)), @intCast(w.len), 0, 0);
        return;
    }
    const vs = gl.command.depthVertexSrc();
    const fs = gl.command.depthFragmentSrc();
    enc.createShader(depth_shader, gl.command.variant_depth, @intCast(@intFromPtr(vs.ptr)), @intCast(vs.len), @intCast(@intFromPtr(fs.ptr)), @intCast(fs.len));
    inst.registry.recordShader(depth_shader, gl.command.variant_depth, @intCast(@intFromPtr(vs.ptr)), @intCast(vs.len), @intCast(@intFromPtr(fs.ptr)), @intCast(fs.len));
}

fn emitDepthAtShader(inst: *Inst, enc: *gl.Encoder) void {
    if (use_webgpu) {
        const w = gl.command.wgslDepthAt();
        enc.createShader(depth_at_shader, gl.command.variant_depth | gl.command.variant_alpha_test, @intCast(@intFromPtr(w.ptr)), @intCast(w.len), 0, 0);
        inst.registry.recordShader(depth_at_shader, gl.command.variant_depth | gl.command.variant_alpha_test, @intCast(@intFromPtr(w.ptr)), @intCast(w.len), 0, 0);
        return;
    }
    const vs = gl.command.depthAtVertexSrc();
    const fs = gl.command.depthAtFragmentSrc();
    enc.createShader(depth_at_shader, gl.command.variant_depth | gl.command.variant_alpha_test, @intCast(@intFromPtr(vs.ptr)), @intCast(vs.len), @intCast(@intFromPtr(fs.ptr)), @intCast(fs.len));
    inst.registry.recordShader(depth_at_shader, gl.command.variant_depth | gl.command.variant_alpha_test, @intCast(@intFromPtr(vs.ptr)), @intCast(vs.len), @intCast(@intFromPtr(fs.ptr)), @intCast(fs.len));
}

// T6: Instanced shader — must NOT add variant_shadow (vp/light_vp slot collision →
// @compileError in both GLSL and WGSL paths). Handle 19 without fog, 36 with fog.
// Uses a comptime-branched helper to keep the variant comptime-known for wgslPbr/pbrVertexSrc.
fn emitInstancedShader(inst: *Inst, enc: *gl.Encoder) void {
    if (inst.fog_enabled) {
        emitInstancedShaderVariant(inst, enc, variant_pbr | variant_inst | variant_fog);
    } else {
        emitInstancedShaderVariant(inst, enc, variant_pbr | variant_inst);
    }
}

fn emitInstancedShaderVariant(inst: *Inst, enc: *gl.Encoder, comptime v: u32) void {
    const handle = shaderHandleFor(v);
    if (use_webgpu) {
        const w = gl.command.wgslPbr(v);
        enc.createShader(handle, v, @intCast(@intFromPtr(w.ptr)), @intCast(w.len), 0, 0);
        inst.registry.recordShader(handle, v, @intCast(@intFromPtr(w.ptr)), @intCast(w.len), 0, 0);
        return;
    }
    const vs = gl.command.pbrVertexSrc(v);
    const fs = gl.command.pbrFragmentSrc(v);
    enc.createShader(handle, v, @intCast(@intFromPtr(vs.ptr)), @intCast(vs.len), @intCast(@intFromPtr(fs.ptr)), @intCast(fs.len));
    inst.registry.recordShader(handle, v, @intCast(@intFromPtr(vs.ptr)), @intCast(vs.len), @intCast(@intFromPtr(fs.ptr)), @intCast(fs.len));
}

// ── hydrate ──────────────────────────────────────────────────────────────────

// Parse a "mode,r,g,b,near,far,density" fog attribute into inst.fog_params.
// Tolerant: needs ≥7 comma fields, else leaves fog off.
fn parseFog(inst: *Inst, s: []const u8) void {
    var vals: [7]f32 = .{ 0, 0, 0, 0, 0, 0, 0 };
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |tok| {
        if (n >= 7) break;
        vals[n] = std.fmt.parseFloat(f32, tok) catch return;
        n += 1;
    }
    if (n < 7 or vals[0] == 0) return;
    inst.fog_params = .{ vals[0], vals[1], vals[2], vals[3], vals[4], vals[5], vals[6], 0 };
    inst.fog_enabled = true;
}

// Parse the `data-gllights` attribute into inst.lights / light_count, then
// classify shadow casters into the 2D + point tables.
// Format: semicolon-separated light records, each a 15-field comma-separated CSV:
//   type,intensity,px,py,pz,dx,dy,dz,r,g,b,range,cosIn,cosOut,castsShadow
// Maps CSV[0..13] → lights[i*16 + 0..13]. Indices 14,15 are NOT from the CSV:
// they are per-light shadow metadata (v3.z=shadow_index, v3.w=shadow_kind) filled
// by classifyCasters(). CSV[14] (castsShadow) only drives the classification.
// Tolerant: parse errors for a token leave that field at 0; extra fields ignored.
fn parseLights(inst: *Inst, s: []const u8) void {
    const max_l = gl.command.max_lights;
    var li: u32 = 0;
    var casts: [gl.command.max_lights]bool = .{false} ** gl.command.max_lights;
    var light_it = std.mem.splitScalar(u8, s, ';');
    while (light_it.next()) |rec| {
        if (li >= max_l) break;
        const base = li * 16;
        // Zero the full 16-f32 slot before filling (pad fields stay 0).
        for (inst.lights[base .. base + 16]) |*f| f.* = 0;
        var fi: u32 = 0;
        var field_it = std.mem.splitScalar(u8, rec, ',');
        while (field_it.next()) |tok| {
            if (fi >= 15) break;
            const v = std.fmt.parseFloat(f32, tok) catch 0.0;
            if (fi < 14) {
                inst.lights[base + fi] = v;
            } else {
                // fi == 14: castsShadow — directional (0), point (1), spot (2) all
                // valid. Classification (2D vs point slot) happens after the loop.
                casts[li] = v >= 0.5;
            }
            fi += 1;
        }
        li += 1;
    }
    inst.light_count = li;
    classifyCasters(inst, casts[0..li]);
}

// Classify every shadow-casting light into the 2D atlas (directional/spot) or the
// point cube atlas, filling the caster tables and writing per-light shadow metadata
// into v3.z (shadow_index) and v3.w (shadow_kind: 0=none, 1=2D, 2=point). Over-cap
// casters degrade to non-casters. Does NOT clobber v3.x/v3.y (indices 12,13 =
// cos_inner/cos_outer for spots). Enforces the range==far contract for point casters.
fn classifyCasters(inst: *Inst, casts: []const bool) void {
    inst.n_2d_casters = 0;
    inst.n_point_casters = 0;
    inst.csm_light = -1;
    inst.cascade_count = 0;

    // ── Pass 1: the FIRST directional shadow caster becomes a CSM caster (kind=3),
    // reserving 2D atlas slots 0..N-1 (N = max_csm_cascades). Its v3.z = base
    // cascade slot (0); the receiver samples shadow_vp[0 + ci]. Only one directional
    // CSM caster is supported; later directional casters fall through to Pass 2 as
    // plain single-2D casters (kind=1) at slots after the cascades.
    const ncas = gl.command.max_csm_cascades;
    {
        var li: u32 = 0;
        while (li < inst.light_count) : (li += 1) {
            const base = li * 16;
            const wants = li < casts.len and casts[li];
            const ltype = inst.lights[base + 0];
            const is_dir = ltype < 0.5;
            if (wants and is_dir and inst.csm_light < 0 and inst.n_2d_casters + ncas <= gl.command.max_2d_casters) {
                inst.csm_light = @intCast(li);
                inst.cascade_count = ncas;
                // Reserve cascade slots 0..N-1 for this caster; casters_2d[c] = li so
                // each cascade's depth pass + VP knows its source light.
                var c: u32 = 0;
                while (c < ncas) : (c += 1) {
                    inst.casters_2d[c] = li;
                    inst.n_2d_casters += 1;
                }
                inst.lights[base + 14] = 0.0; // base cascade slot
                inst.lights[base + 15] = 3.0; // CSM directional
            }
        }
    }

    // ── Pass 2: every other caster. Points → cube atlas (kind=2). Spots and any
    // extra directional casters → single 2D (kind=1) at slots after the cascades.
    var li: u32 = 0;
    while (li < inst.light_count) : (li += 1) {
        const base = li * 16;
        if (@as(i32, @intCast(li)) == inst.csm_light) continue; // already CSM-classified
        const wants = li < casts.len and casts[li];
        if (!wants) {
            inst.lights[base + 14] = -1.0; // shadow_index = none
            inst.lights[base + 15] = 0.0; // shadow_kind = none
            continue;
        }
        const ltype = inst.lights[base + 0];
        const is_point = ltype >= 0.5 and ltype < 1.5;
        if (is_point) {
            if (inst.n_point_casters < gl.command.max_point_casters) {
                const pidx = inst.n_point_casters;
                inst.n_point_casters += 1;
                inst.casters_point[pidx] = li;
                inst.lights[base + 14] = @floatFromInt(pidx);
                inst.lights[base + 15] = 2.0; // point
                // Enforce range==far: the receiver normalises by range (v2.w =
                // lights[base+11]); range≤0 is illegal for a caster. Clamp to the
                // depth-pass default far AND write it back so both agree.
                if (inst.lights[base + 11] <= 0) inst.lights[base + 11] = 25.0;
            } else {
                inst.lights[base + 14] = -1.0;
                inst.lights[base + 15] = 0.0;
            }
        } else {
            // spot (type≥1.5) or extra directional (type<0.5) → 2D atlas, kind=1
            if (inst.n_2d_casters < gl.command.max_2d_casters) {
                const sidx = inst.n_2d_casters;
                inst.n_2d_casters += 1;
                inst.casters_2d[sidx] = li;
                inst.lights[base + 14] = @floatFromInt(sidx);
                inst.lights[base + 15] = 1.0; // 2D
            } else {
                inst.lights[base + 14] = -1.0;
                inst.lights[base + 15] = 0.0;
            }
        }
    }
}

// Parse the `data-glarealights` attribute into inst.area_lights / area_count,
// then classify area shadow casters into the shared 2D atlas.
// Format: semicolon-separated area-light records, each a 15-field comma CSV:
//   px,py,pz, exx,exy,exz, eyx,eyy,eyz, r,g,b, intensity, two_sided, casts_shadow
// Maps into the S3T1 packing: a0=[pos,intensity], a1=[ex,two_sided],
// a2=[ey,shadow_slot=-1], a3=[color,shadow_kind=0]. classifyAreaCasters fills the
// shadow_slot / shadow_kind after parsing. Tolerant: parse errors → 0; extras ignored.
fn parseAreaLights(inst: *Inst, s: []const u8) void {
    const max_a = gl.command.max_area_lights;
    var ai: u32 = 0;
    var casts: [gl.command.max_area_lights]bool = .{false} ** gl.command.max_area_lights;
    var it = std.mem.splitScalar(u8, s, ';');
    while (it.next()) |rec| {
        if (ai >= max_a) break;
        const base = ai * 16;
        for (inst.area_lights[base .. base + 16]) |*f| f.* = 0;
        // Parse the 15 CSV fields into temporaries, then pack into the 4 vec4 layout.
        var fields: [15]f32 = .{0} ** 15;
        var fi: u32 = 0;
        var field_it = std.mem.splitScalar(u8, rec, ',');
        while (field_it.next()) |tok| {
            if (fi >= 15) break;
            fields[fi] = std.fmt.parseFloat(f32, tok) catch 0.0;
            fi += 1;
        }
        // a0 = [pos.xyz, intensity]
        inst.area_lights[base + 0] = fields[0];
        inst.area_lights[base + 1] = fields[1];
        inst.area_lights[base + 2] = fields[2];
        inst.area_lights[base + 3] = fields[12]; // intensity
        // a1 = [ex.xyz, two_sided]
        inst.area_lights[base + 4] = fields[3];
        inst.area_lights[base + 5] = fields[4];
        inst.area_lights[base + 6] = fields[5];
        inst.area_lights[base + 7] = fields[13]; // two_sided
        // a2 = [ey.xyz, shadow_slot] (slot filled by classifyAreaCasters; -1 default)
        inst.area_lights[base + 8] = fields[6];
        inst.area_lights[base + 9] = fields[7];
        inst.area_lights[base + 10] = fields[8];
        inst.area_lights[base + 11] = -1.0;
        // a3 = [color.rgb, shadow_kind] (kind filled by classifyAreaCasters; 0 default)
        inst.area_lights[base + 12] = fields[9];
        inst.area_lights[base + 13] = fields[10];
        inst.area_lights[base + 14] = fields[11];
        inst.area_lights[base + 15] = 0.0;
        casts[ai] = fields[14] >= 0.5; // casts_shadow
        ai += 1;
    }
    inst.area_count = ai;
    classifyAreaCasters(inst, casts[0..ai]);
}

// Assign each shadow-casting area light the NEXT free 2D atlas slot, AFTER the
// cascades + spot/dir casters already counted in n_2d_casters. Writes a2.w = slot
// (float) and a3.w = 1.0 (2D shadow kind) into the area pool, records the owning
// area-light index in slot_area_li[slot], and increments n_2d_casters so
// bindShadowMap covers the area passes too. If the 8-slot pool is full the area
// shadow is DROPPED (a3.w stays 0 → the shader treats it as unshadowed). MUST run
// after classifyCasters (parseLights) so the slot accounting is correct.
fn classifyAreaCasters(inst: *Inst, casts: []const bool) void {
    var ai: u32 = 0;
    while (ai < inst.area_count) : (ai += 1) {
        const base = ai * 16;
        const wants = ai < casts.len and casts[ai];
        if (!wants) {
            inst.area_lights[base + 11] = -1.0; // shadow_slot = none
            inst.area_lights[base + 15] = 0.0; // shadow_kind = none
            continue;
        }
        if (inst.n_2d_casters < gl.command.max_2d_casters) {
            const slot = inst.n_2d_casters;
            inst.n_2d_casters += 1;
            inst.slot_area_li[slot] = @intCast(ai);
            inst.area_lights[base + 11] = @floatFromInt(slot); // a2.w = slot
            inst.area_lights[base + 15] = 1.0; // a3.w = 2D shadow
        } else {
            // Pool full (cascades+spots already used all 8 slots) → drop the shadow.
            inst.area_lights[base + 11] = -1.0;
            inst.area_lights[base + 15] = 0.0;
        }
    }
}

/// Area-light view-projection for the shadow depth pass: a spot-like perspective
/// from the rect center (pos) along the rect normal = normalize(cross(ex,ey)).
/// The normal points OUT of the lit face (CCW corners c0=pos+ex-ey … → cross(ex,ey)
/// is the front normal). A wide 90° fovy covers the near hemisphere the rect lights.
fn areaLightVp(inst: *const Inst, area_idx: u32) gl.math.Mat4 {
    const Vec3 = gl.math.Vec3;
    const base = area_idx * 16;
    const pos = Vec3.init(inst.area_lights[base + 0], inst.area_lights[base + 1], inst.area_lights[base + 2]);
    const ex = Vec3.init(inst.area_lights[base + 4], inst.area_lights[base + 5], inst.area_lights[base + 6]);
    const ey = Vec3.init(inst.area_lights[base + 8], inst.area_lights[base + 9], inst.area_lights[base + 10]);
    // Rect normal = cross(ex,ey); the rect emits along this direction (the lit side).
    const normal = Vec3.normalize(Vec3.cross(ex, ey));
    const fovy: f32 = std.math.pi * 0.5; // 90°
    const near: f32 = 0.05;
    const far: f32 = 50.0;
    return gl.math.spotLightVpMat(pos, normal, fovy, near, far);
}

// Parse a "w0,w1,…" morph-weight attribute into inst.morph_weights[0..].
// Seeds up to max_morph_targets weights and marks each as runtime-set so the
// per-frame baked-clip advance does not overwrite them.  Tolerant: extra
// tokens are ignored; parse errors for a token leave that index at 0.
fn parseMorph(inst: *Inst, s: []const u8) void {
    var n: u32 = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |tok| {
        if (n >= max_morph_targets) break;
        const w = std.fmt.parseFloat(f32, tok) catch 0.0;
        inst.morph_weights[n] = w;
        inst.morph_runtime_set[n] = true;
        n += 1;
    }
}

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    // First instance of a fresh population owns the page asset-region reset.
    // Subsequent instances SHARE the region (resetting would free their assets).
    // Full unmount→remount returns live_count to 0, so the region re-resets.
    const first = (live_count == 0);
    const inst = allocSlot(root_id) orelse return; // pool exhausted → ignore marker
    current = inst;
    if (first) verve.assetReset();

    // `inst.*` is fresh (Inst{} defaults == the pre-P7 hydrate reset). Decode
    // props into it.
    if (props_len != 0) {
        const bytes = @as([*]const u8, @ptrFromInt(@as(usize, props_ptr)))[0..props_len];
        const mark = verve.chunkArenaMark();
        defer verve.chunkArenaReset(mark);
        if (verve.decodeProps(Props, bytes, verve.chunkArena())) |p| {
            // Copy every slice out of the arena BEFORE it's reset.
            inst.src_len = @min(p.src.len, inst.src_buf.len);
            @memcpy(inst.src_buf[0..inst.src_len], p.src[0..inst.src_len]);
            inst.env_len = @min(p.env.len, inst.env_buf.len);
            @memcpy(inst.env_buf[0..inst.env_len], p.env[0..inst.env_len]);

            inst.orbit = .{
                .distance = p.orbit_distance,
                .pitch = p.orbit_pitch,
                .yaw = p.orbit_yaw,
            };
            inst.auto_rotate = p.auto_rotate;
            inst.scrub_enabled = p.scrub;

            // Default single directional light into slot 0 of the 16-f32 layout.
            // When data-gllights is present, parseLights overwrites this below.
            inst.lights[0] = 0; // type = directional
            inst.lights[1] = p.light_intensity;
            // [2..4] pos = 0 (directional)
            inst.lights[2] = 0;
            inst.lights[3] = 0;
            inst.lights[4] = 0;
            inst.lights[5] = p.light_dir_x;
            inst.lights[6] = p.light_dir_y;
            inst.lights[7] = p.light_dir_z;
            inst.lights[8] = 1; // r
            inst.lights[9] = 1; // g
            inst.lights[10] = 1; // b
            // [11..15] range/cosIn/cosOut/_pad = 0
            inst.lights[11] = 0;
            inst.lights[12] = 0;
            inst.lights[13] = 0;
            inst.lights[14] = 0;
            inst.lights[15] = 0;
            inst.light_count = 1;
            // Default: light 0 is a 2D (directional) shadow caster in slot 0.
            // classifyCasters writes v3.z/v3.w; parseLights (data-gllights) overrides.
            classifyCasters(inst, &.{true});

            // Deep-copy pick names/ids into the instance (arena dies on reset).
            inst.pick_count = @min(@min(p.pick_names.len, p.pick_event_ids.len), max_picks);
            var i: usize = 0;
            while (i < inst.pick_count) : (i += 1) {
                const nm = p.pick_names[i];
                const ln = @min(nm.len, max_name);
                @memcpy(inst.pick_names[i][0..ln], nm[0..ln]);
                inst.pick_name_lens[i] = ln;
                inst.pick_ids[i] = p.pick_event_ids[i];
                if (i < p.pick_export_names.len) {
                    const ev = p.pick_export_names[i];
                    const el = @min(ev.len, max_name);
                    @memcpy(inst.pick_exports[i][0..el], ev[0..el]);
                    inst.pick_export_lens[i] = el;
                } else {
                    inst.pick_export_lens[i] = 0;
                }
            }
        } else |_| {}
    }

    // Cache reduced-motion once (matchMedia is a host round-trip; page-global).
    reduced_motion = verve.matchMedia("(prefers-reduced-motion: reduce)");
    // Pick the GPU backend once (page-global): WebGPU when available, else WebGL2.
    use_webgpu = gl_webgpu_available() != 0;

    // Resolve refs ONCE while hydrate runs inside island scope — frame- and
    // asset-callback lookups run UNSCOPED and would miss the vid-suffixed ref.
    // queryRef auto-scopes via the runtime's current_island_id (this vid), so
    // each instance resolves its OWN `glscene-canvas__v{vid}` handle.
    inst.canvas_handle = verve.queryRef(@as([]const u8, "glscene-canvas"));
    inst.scroll_section_handle = verve.queryRef(@as([]const u8, "glscene-scroll-section"));

    // Fog rides on the canvas `data-glfog` attribute (NOT Props — see Props
    // note). Format: "mode,r,g,b,near,far,density". Absent → fog stays off.
    if (inst.canvas_handle) |ch| {
        var fbuf: [512]u8 = undefined;
        const fa = verve.refGetAttr(ch, "data-glfog", &fbuf);
        if (fa.len != 0) parseFog(inst, fa);
    }

    // Multi-light array rides on the canvas `data-gllights` attribute (NOT Props).
    // Format: semicolon-separated 15-field CSV records. When present, overrides
    // the Props default-directional written above.
    if (inst.canvas_handle) |ch| {
        var llbuf: [1400]u8 = undefined;
        const la = verve.refGetAttr(ch, "data-gllights", &llbuf);
        if (la.len != 0) parseLights(inst, la);
    }

    // Area lights ride on the canvas `data-glarealights` attribute (NOT Props).
    // Format: semicolon-separated 15-field CSV records. MUST be parsed AFTER
    // data-gllights so classifyAreaCasters appends to the n_2d_casters the
    // cascades+spots already claimed (shared 8-slot atlas). Absent → area_count=0.
    if (inst.canvas_handle) |ch| {
        var albuf: [1400]u8 = undefined;
        const aa = verve.refGetAttr(ch, "data-glarealights", &albuf);
        if (aa.len != 0) parseAreaLights(inst, aa);
    }

    // Morph weights ride on the canvas `data-glmorph` attribute (NOT Props).
    // Format: "w0,w1,…".  Seeds inst.morph_weights and marks runtime-set so the
    // per-frame baked-clip advance does not overwrite these initial values.
    if (inst.canvas_handle) |ch| {
        var mbuf: [512]u8 = undefined;
        const ma = verve.refGetAttr(ch, "data-glmorph", &mbuf);
        if (ma.len != 0) parseMorph(inst, ma);
    }

    // Kick the asset fetches (geometry + prefiltered IBL).
    if (inst.src_len != 0)
        gl_load(&inst.src_buf, @intCast(inst.src_len), vmesh_ready_export.ptr, vmesh_ready_export.len);
    if (inst.env_len != 0)
        gl_load(&inst.env_buf, @intCast(inst.env_len), env_ready_export.ptr, env_ready_export.len);

    if (canvasRef(inst)) |h| {
        if (use_webgpu) gl_start_gpu(h, frame_export.ptr, frame_export.len) else gl_start(h, frame_export.ptr, frame_export.len);
    }
}

// ── asset-ready callbacks ─────────────────────────────────────────────────────

export fn glscene_vmesh_ready(ptr: u32, len: u32) void {
    const inst = current orelse return;
    if (ptr == 0) return; // fetch failed → stay on clear-only frames
    const bytes = @as([*]const u8, @ptrFromInt(@as(usize, ptr)))[0..len];
    inst.asset = gl.vmesh.Reader.init(bytes) catch null;
    if (inst.asset) |*a| buildScene(inst, a);
    // With the Reader resolvable, build the scroll-scrubbed timeline once.
    if (inst.scrub_enabled and !inst.scrub_built) buildScrubTimeline(inst);
}

export fn glscene_env_ready(ptr: u32, len: u32) void {
    const inst = current orelse return;
    if (ptr == 0) return;
    const bytes = @as([*]const u8, @ptrFromInt(@as(usize, ptr)))[0..len];
    inst.env_reader = gl.venv.Reader.init(bytes) catch null;
}

// ── external (compressed) texture streaming (P-compressed-textures) ──────────────

fn texExtName(fmt: gl.vmesh.Format) []const u8 {
    return switch (fmt) {
        .raw => "bin", // unreachable for streaming (raw never externalized)
        .png => "png",
        .jpeg => "jpg",
        .webp => "webp",
    };
}

/// Derive "<stem>.tex{idx}.<ext>" from the instance's vmesh src into tex_url_buf.
fn buildTexUrl(inst: *Inst, idx: u32, fmt: gl.vmesh.Format) []const u8 {
    const src = inst.src_buf[0..inst.src_len];
    const stem = if (std.mem.endsWith(u8, src, ".vmesh")) src[0 .. src.len - ".vmesh".len] else src;
    return std.fmt.bufPrint(&inst.tex_url_buf, "{s}.tex{d}.{s}", .{ stem, idx, texExtName(fmt) }) catch "";
}

/// Kick the next external (non-raw) material texture load, scanning from tex_scan.
/// Raw textures upload inline in sendResources, so they're skipped here.
fn loadNextExternalTex(inst: *Inst, a: *const gl.vmesh.Reader) void {
    while (inst.tex_scan < a.tex_count) {
        const i = inst.tex_scan;
        if (a.texFormat(i) == .raw) {
            inst.tex_scan += 1;
            continue;
        }
        inst.tex_scan = i + 1;
        inst.tex_loading = @intCast(i);
        const url = buildTexUrl(inst, i, a.texFormat(i));
        if (url.len != 0)
            gl_load(url.ptr, @intCast(url.len), tex_ready_export.ptr, tex_ready_export.len);
        return;
    }
    inst.tex_loading = -1;
}

/// Worker-decoded external texture arrived: bytes = [w:u32 LE][h:u32 LE][RGBA…] at
/// `ptr`. Queue it for upload on the next frame, then kick the next one. (gl_load
/// callbacks run outside a frame, so the createTexture is deferred to drainTexUploads.)
export fn glscene_tex_ready(ptr: u32, len: u32) void {
    const inst = current orelse return;
    if (inst.tex_loading < 0) return;
    const idx: u32 = @intCast(inst.tex_loading);
    inst.tex_loading = -1;
    if (ptr != 0 and len >= 8 and inst.tex_up_n < max_tex) {
        const bytes = @as([*]const u8, @ptrFromInt(@as(usize, ptr)))[0..len];
        inst.tex_up[inst.tex_up_n] = .{
            .handle = idx + 1,
            .w = std.mem.readInt(u32, bytes[0..4], .little),
            .h = std.mem.readInt(u32, bytes[4..8], .little),
            .ptr = ptr + 8,
            .len = len - 8,
            .srgb = if (inst.asset) |*a| a.texIsSrgb(idx) else false,
        };
        inst.tex_up_n += 1;
    }
    // ptr==0 → load/decode failed: leave the slot's default texture.
    if (inst.asset) |*a| loadNextExternalTex(inst, a);
}

/// Drain queued external textures into createTexture commands (called each frame
/// while assets are live). Recorded into the registry for context-restore replay.
fn drainTexUploads(inst: *Inst, enc: *gl.Encoder) void {
    var i: u32 = 0;
    while (i < inst.tex_up_n) : (i += 1) {
        const u = inst.tex_up[i];
        if (u.srgb) {
            enc.createTextureSrgb(u.handle, u.w, u.h, u.ptr, u.len);
            inst.registry.recordTextureSrgb(u.handle, u.w, u.h, u.ptr, u.len);
        } else {
            enc.createTexture(u.handle, u.w, u.h, u.ptr, u.len);
            inst.registry.recordTexture(u.handle, u.w, u.h, u.ptr, u.len);
        }
    }
    inst.tex_up_n = 0;
}

/// (Re)build the scene graph for a freshly-read vmesh: root "model" at node 0,
/// one child per submesh at node s+1. Also initializes the mats pool + per-
/// submesh local AABBs from vmesh defaults.
fn buildScene(inst: *Inst, a: *const gl.vmesh.Reader) void {
    inst.scene = .{};
    _ = inst.scene.addNode(-1, "model");
    const n: u32 = @min(a.submesh_count, max_submesh);
    // Vertices: vmesh stride 48 bytes = 12 f32; position xyz at offset 0.
    const verts_f32 = bytesAsF32(a.vertices);
    const indices_u16 = bytesAsU16(a.indices);
    var s: u32 = 0;
    while (s < n) : (s += 1) {
        _ = inst.scene.addNode(0, a.name(s));
        const sub = a.submesh(s);
        inst.mats[s] = .{
            sub.base_color[0], sub.base_color[1], sub.base_color[2],      sub.base_color[3],
            sub.metallic,      sub.roughness,     sub.occlusion_strength, sub.normal_scale,
            sub.emissive[0],   sub.emissive[1],   sub.emissive[2],        sub.alpha_cutoff,
        };
        inst.submesh_aabb[s] = submeshLocalAabb(verts_f32, indices_u16, sub.index_byte_off / 2, sub.index_count);
    }
    inst.model_yaw_applied = 0;
    inst.node_rot_applied = [_][3]f32{.{ 0, 0, 0 }} ** max_submesh;
    inst.node_pos_applied = [_][3]f32{.{ 0, 0, 0 }} ** max_submesh;
    inst.node_scale_applied = [_][3]f32{.{ 1, 1, 1 }} ** max_submesh;
    inst.scene_built = true;
}

// ── pointer / wheel / click handlers ──────────────────────────────────────────

export fn glscene_pointerdown() void {
    const inst = current orelse return;
    if (verve.eventButton() != 0) return; // primary button only
    inst.dragging = true;
    inst.last_x = verve.eventCoordX();
    inst.last_y = verve.eventCoordY();
    verve.eventCapturePointer();
}

export fn glscene_pointermove() void {
    const inst = current orelse return;
    const x = verve.eventCoordX();
    const y = verve.eventCoordY();
    if (inst.dragging) {
        const dx: f32 = @floatCast(x - inst.last_x);
        const dy: f32 = @floatCast(y - inst.last_y);
        // See drag-sign note up top: dragging right swings the camera left.
        inst.input.dyaw -= dx * drag_sens;
        inst.input.dpitch -= dy * drag_sens;
        inst.last_x = x;
        inst.last_y = y;
    } else {
        // Queue a hover raycast for the next frame (one raycast/frame max).
        if (canvasRef(inst)) |h| {
            clientToNdc(h, x, y, &inst.hover_ndc_x, &inst.hover_ndc_y);
            inst.hover_have = true;
        }
    }
}

export fn glscene_pointerup() void {
    const inst = current orelse return;
    inst.dragging = false;
}

export fn glscene_wheel() void {
    const inst = current orelse return;
    verve.eventPreventDefault();
    inst.input.dzoom += @as(f32, @floatCast(verve.eventDeltaY())) * zoom_sens;
}

export fn glscene_click() void {
    const inst = current orelse return;
    if (canvasRef(inst)) |h| {
        clientToNdc(h, verve.eventCoordX(), verve.eventCoordY(), &inst.pick_ndc_x, &inst.pick_ndc_y);
        inst.pick_pending = true;
    }
}

// ── context-restore hook ──────────────────────────────────────────────────────

export fn glscene_frame_restore() void {
    const inst = current orelse return;
    // The GL objects died with the old context. Re-emit every recorded create*
    // on the next frame via registry.replay (the records persist).
    inst.needs_replay = true;
}

// ── pick raycast ──────────────────────────────────────────────────────────────

/// True when every per-submesh node transform is identity (zero Euler rotation,
/// zero translation, unit scale) — the common no-anim case that unlocks the
/// cheap single-walk raycast paths. A non-identity translate/scale (even with
/// zero rotation) must take the inverse-transform path so picks stay aligned
/// with the animated node.
fn nodeXformIdentity(inst: *const Inst) bool {
    for (inst.node_rot) |r| {
        if (r[0] != 0 or r[1] != 0 or r[2] != 0) return false;
    }
    for (inst.node_pos) |p| {
        if (p[0] != 0 or p[1] != 0 or p[2] != 0) return false;
    }
    for (inst.node_scale) |sc| {
        if (sc[0] != 1 or sc[1] != 1 or sc[2] != 1) return false;
    }
    return true;
}

/// Build a pick ray for `(ndc_x, ndc_y)` and walk the mesh BVH. Returns the
/// picked submesh index, or null on miss / no BVH data. See the pre-P7 history
/// for the three-path (fast / root-only / slow per-submesh) rationale.
fn raycastSubmesh(inst: *const Inst, a: *const gl.vmesh.Reader, aspect: f32, ndc_x: f32, ndc_y: f32) ?u32 {
    if (a.bvh_node_count == 0) return null;
    const r = gl.ray.rayFromCamera(inst.orbit.eye(), inst.orbit.target, up_vec, fov_y, aspect, ndc_x, ndc_y);
    const nodes = gl.bvh.nodesFromBytes(a.bvh_nodes);
    const tri_perm = gl.bvh.triPermFromBytes(a.tri_perm);
    const verts_f32 = bytesAsF32(a.vertices);
    const indices_u16 = bytesAsU16(a.indices);

    const rot_identity = nodeXformIdentity(inst);
    if (!inst.scene_built or (inst.model_yaw == 0 and rot_identity)) {
        const hit = gl.bvh.walk(nodes, tri_perm, verts_f32, 12, indices_u16, r) orelse return null;
        return submeshOfTri(a, hit.tri_index);
    }
    if (rot_identity) {
        // Root-only: one walk with the ray in model (root) space.
        const tr = gl.ray.transformRay(r, gl.math.invert(inst.scene.world[0]));
        const hit = gl.bvh.walk(nodes, tri_perm, verts_f32, 12, indices_u16, tr) orelse return null;
        return submeshOfTri(a, hit.tri_index);
    }
    // Slow path: per-submesh inverse transform + range-walk over s's triangles.
    var best_t: f32 = std.math.inf(f32);
    var best_s: ?u32 = null;
    const n: u32 = @min(a.submesh_count, max_submesh);
    var s: u32 = 0;
    while (s < n) : (s += 1) {
        const sub = a.submesh(s);
        const tr = gl.ray.transformRay(r, gl.math.invert(inst.scene.world[s + 1]));
        const hit = gl.bvh.walkRange(nodes, tri_perm, verts_f32, 12, indices_u16, tr, sub.index_byte_off / 2, sub.index_count) orelse continue;
        if (hit.t < best_t) {
            best_t = hit.t;
            best_s = s;
        }
    }
    return best_s;
}

/// Stamp `data-<attr>` on the instance's canvas with submesh `s`'s name.
fn stampName(inst: *const Inst, attr: []const u8, a: *const gl.vmesh.Reader, s: u32) void {
    if (canvasRef(inst)) |h| verve.setRefAttr(h, attr, a.name(s));
}

/// Directional light view-projection for the shadow pass (ortho fit to the
/// union of submesh world AABBs). Reads caster direction from the 16-f32
/// layout at base = light_idx*16, dir at +5..+7.
/// Call after `scene.updateWorld()`.
fn lightSpaceMatrix(inst: *const Inst, a: *const gl.vmesh.Reader, light_idx: u32) gl.math.Mat4 {
    const Vec3 = gl.math.Vec3;
    const inf = std.math.inf(f32);
    var lo = Vec3.init(inf, inf, inf);
    var hi = Vec3.init(-inf, -inf, -inf);
    const n: u32 = @min(a.submesh_count, max_submesh);
    var s: u32 = 0;
    while (s < n) : (s += 1) {
        const wb = gl.cull.worldAabb(inst.submesh_aabb[s], inst.scene.world[s + 1]);
        lo = Vec3.init(@min(lo.x, wb.min.x), @min(lo.y, wb.min.y), @min(lo.z, wb.min.z));
        hi = Vec3.init(@max(hi.x, wb.max.x), @max(hi.y, wb.max.y), @max(hi.z, wb.max.z));
    }
    if (n == 0 or lo.x > hi.x) { // no geometry: a unit box at the origin
        lo = Vec3.init(-1, -1, -1);
        hi = Vec3.init(1, 1, 1);
    }
    const center = Vec3.scale(Vec3.add(lo, hi), 0.5);
    const radius = @max(@as(f32, 0.5), Vec3.length(Vec3.sub(hi, lo)) * 0.5);
    // Read dir from caster's slot in the new 16-f32 layout (dir at +5..+7).
    const base = light_idx * 16;
    const dir = Vec3.normalize(Vec3.init(inst.lights[base + 5], inst.lights[base + 6], inst.lights[base + 7]));
    const up = if (@abs(dir.y) > 0.99) Vec3.init(0, 0, 1) else Vec3.init(0, 1, 0);
    const dist = radius * 3.0;
    const eye = Vec3.sub(center, Vec3.scale(dir, dist));
    const view = gl.math.Mat4.lookAt(eye, center, up);
    const ext = radius * 1.2;
    const proj = gl.math.Mat4.ortho(-ext, ext, -ext, ext, dist - radius * 1.5, dist + radius * 1.5);
    return proj.mul(view);
}

// ── CSM (Slice 2) ────────────────────────────────────────────────────────────

// CSM shadow distance (m): the camera proj uses far=100, but packing 4 cascades
// over the full 0.1..100 range wastes resolution far from the camera. Clamp the
// CSM far to a tuned shadow distance so cascades concentrate near the viewer.
// min(proj_far, csm_far) keeps it valid for any scene scale.
const csm_far: f32 = 60.0;
const csm_lambda: f32 = 0.5; // practical-split blend (0=uniform, 1=logarithmic)

/// Practical-scheme cascade splits (view-space FAR distance per cascade).
/// split_i = λ·cn·(cf/cn)^(i/N) + (1-λ)·(cn + (cf-cn)·i/N), i=1..N.
/// cn = camera near, cf = min(camera far, csm_far). Writes inst.cascade_splits.
fn computeCascadeSplits(inst: *Inst, cn: f32, cam_far: f32) void {
    const ncas = gl.command.max_csm_cascades;
    const cf = @min(cam_far, csm_far);
    var i: u32 = 1;
    while (i <= ncas) : (i += 1) {
        const fi: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(ncas));
        const log = cn * std.math.pow(f32, cf / cn, fi);
        const uni = cn + (cf - cn) * fi;
        inst.cascade_splits[i - 1] = csm_lambda * log + (1.0 - csm_lambda) * uni;
    }
}

/// Ortho light VP fit to ONE cascade's view-frustum depth slice [near_d, far_d]
/// (view-space forward distances). Builds the 8 world-space corners of that slice
/// (view-space corner box → world via invert(view)), then fits a light-space AABB
/// over them and an ortho box — the same scheme as lightSpaceMatrix, generalized to
/// an arbitrary point set. `view` is the camera view matrix (NO clipFix). clipFix is
/// applied by the caller (matching the other shadow VPs).
fn cascadeLightVp(inst: *const Inst, light_idx: u32, near_d: f32, far_d: f32, aspect: f32, view: gl.math.Mat4) gl.math.Mat4 {
    const Vec3 = gl.math.Vec3;
    const inv_view = gl.math.invert(view);
    const tan_half = std.math.tan(fov_y * 0.5);
    // 8 view-space corners (camera looks down -Z → forward distance d → z=-d).
    var corners: [8]Vec3 = undefined;
    const depths = [2]f32{ near_d, far_d };
    var ci: usize = 0;
    for (depths) |d| {
        const hh = d * tan_half;
        const hw = hh * aspect;
        const z = -d;
        // 4 corners at this depth: (±hw, ±hh, z), transformed to world.
        corners[ci + 0] = gl.math.transformPoint(inv_view, Vec3.init(-hw, -hh, z));
        corners[ci + 1] = gl.math.transformPoint(inv_view, Vec3.init(hw, -hh, z));
        corners[ci + 2] = gl.math.transformPoint(inv_view, Vec3.init(-hw, hh, z));
        corners[ci + 3] = gl.math.transformPoint(inv_view, Vec3.init(hw, hh, z));
        ci += 4;
    }
    // Frustum-slice bounding sphere (center = mean of corners, radius = max dist).
    var center = Vec3.init(0, 0, 0);
    for (corners) |c| center = Vec3.add(center, c);
    center = Vec3.scale(center, 1.0 / 8.0);
    var radius: f32 = 0;
    for (corners) |c| radius = @max(radius, Vec3.length(Vec3.sub(c, center)));
    radius = @max(radius, 0.5);
    // Light view from the directional caster's dir (lookAt along -dir), exactly as
    // lightSpaceMatrix. Place the light eye back along -dir so the whole slice fits.
    const base = light_idx * 16;
    const dir = Vec3.normalize(Vec3.init(inst.lights[base + 5], inst.lights[base + 6], inst.lights[base + 7]));
    const up = if (@abs(dir.y) > 0.99) Vec3.init(0, 0, 1) else Vec3.init(0, 1, 0);
    const dist = radius * 3.0;
    const eye = Vec3.sub(center, Vec3.scale(dir, dist));
    const lview = gl.math.Mat4.lookAt(eye, center, up);
    const ext = radius * 1.2;
    const proj = gl.math.Mat4.ortho(-ext, ext, -ext, ext, dist - radius * 1.5, dist + radius * 1.5);
    return proj.mul(lview);
}

/// Spot light view-projection for the shadow pass (perspective from the spot's
/// position looking in `dir`). fovy = 2*acos(cosOut) so the cone fits the frustum.
fn spotLightVp(inst: *const Inst, light_idx: u32) gl.math.Mat4 {
    const Vec3 = gl.math.Vec3;
    const base = light_idx * 16;
    const pos = Vec3.init(inst.lights[base + 2], inst.lights[base + 3], inst.lights[base + 4]);
    const dir = Vec3.init(inst.lights[base + 5], inst.lights[base + 6], inst.lights[base + 7]);
    const cos_out = inst.lights[base + 13];
    // fovy = 2 * acos(cosOut). Clamp cosOut to (0,1) to avoid degenerate fov.
    const cos_out_clamped = @max(@as(f32, 0.001), @min(@as(f32, 0.9999), cos_out));
    const fovy = 2.0 * std.math.acos(cos_out_clamped);
    // near/far: small near to avoid clipping; far from range or a large default.
    // Ensure far > near even when range is tiny or zero (degenerate projection guard).
    const range = inst.lights[base + 11];
    const near: f32 = 0.05;
    const far: f32 = @max(near * 2.0, if (range > 0) range else 50.0);
    return gl.math.spotLightVpMat(pos, dir, fovy, near, far);
}

// ── frame ─────────────────────────────────────────────────────────────────────

export fn glscene_frame(dt_ms: f32, width: u32, height: u32) u32 {
    const inst = current orelse return 0;

    // autoRotate spins the camera at a constant rate, bypassing damping. Freeze
    // (debug/test) pins the orbit so a CDP run has a stable frame.
    if (!reduced_motion and !freeze and inst.auto_rotate != 0)
        inst.orbit.yaw += inst.auto_rotate * (dt_ms / 1000.0);

    // Consume accumulated pointer/wheel input, then zero the accumulator.
    inst.orbit.tick(dt_ms, inst.input);
    inst.input = .{};

    const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(@max(height, 1)));
    const cam_near: f32 = 0.1;
    const cam_far: f32 = 100.0;
    const proj = gl.math.Mat4.perspective(fov_y, aspect, cam_near, cam_far);
    const view = inst.orbit.viewMatrix(up_vec);
    const eye = inst.orbit.eye();
    inst.camera_pos = .{ eye.x, eye.y, eye.z };

    // CSM frame-globals: camera look direction (view-space +viewZ axis) + practical
    // cascade splits. Persistent (set_csm points at them — deferred decode). Only
    // meaningful when classifyCasters tagged a directional CSM caster (cascade_count
    // > 0); harmless to compute otherwise.
    {
        const fwd = gl.math.Vec3.normalize(gl.math.Vec3.sub(inst.orbit.target, eye));
        inst.view_forward = .{ fwd.x, fwd.y, fwd.z };
        if (inst.cascade_count > 0) computeCascadeSplits(inst, cam_near, cam_far);
    }

    // Sync animated rotations into the scene graph (skip unchanged via mirrors).
    if (inst.scene_built) {
        if (inst.model_yaw != inst.model_yaw_applied) {
            inst.scene.setRotation(0, gl.math.Quat.fromAxisAngle(up_vec, inst.model_yaw));
            inst.model_yaw_applied = inst.model_yaw;
        }
        var n: u32 = 0;
        while (n + 1 < inst.scene.count) : (n += 1) {
            const r = inst.node_rot[n];
            const ra = inst.node_rot_applied[n];
            if (r[0] != ra[0] or r[1] != ra[1] or r[2] != ra[2]) {
                inst.scene.setRotation(n + 1, nodeQuat(r));
                inst.node_rot_applied[n] = r;
            }
        }
        var pn: u32 = 0;
        while (pn + 1 < inst.scene.count) : (pn += 1) {
            const p = inst.node_pos[pn];
            const pa = inst.node_pos_applied[pn];
            if (p[0] != pa[0] or p[1] != pa[1] or p[2] != pa[2]) {
                inst.scene.setPosition(pn + 1, gl.math.Vec3.init(p[0], p[1], p[2]));
                inst.node_pos_applied[pn] = p;
            }
            const sc = inst.node_scale[pn];
            const sca = inst.node_scale_applied[pn];
            if (sc[0] != sca[0] or sc[1] != sca[1] or sc[2] != sca[2]) {
                inst.scene.setScale(pn + 1, gl.math.Vec3.init(sc[0], sc[1], sc[2]));
                inst.node_scale_applied[pn] = sc;
            }
        }
        inst.scene.updateWorld();
    }

    var enc = gl.Encoder.init(&cmd_buf);

    if (inst.asset != null and inst.env_reader != null) {
        const a = &inst.asset.?;
        const env = &inst.env_reader.?;

        if (!inst.resources_sent) {
            inst.resources_sent = true;
            sendResources(inst, &enc, a, env);
        } else if (inst.needs_replay) {
            inst.needs_replay = false;
            inst.registry.replay(&enc);
            // M7: Registry has no recordMorphTex entry; re-emit createMorphTex
            // manually after replay when morph is present.
            if (inst.morph_tex_recorded) {
                const morph_vertex_count = a.morphVertexCount();
                const morph_target_count = a.morphTargetCount();
                const deltas = a.morphDeltas();
                enc.createMorphTex(morph_tex_handle, morph_vertex_count, morph_target_count * 2, @intCast(@intFromPtr(deltas.ptr)), @intCast(deltas.len));
            }
            // P11 task 5: Registry has no recordPointShadow; re-emit createPointShadow
            // when the atlas was previously created (analogous to morph_tex_recorded).
            if (inst.point_atlas_sent) {
                enc.createPointShadow(point_atlas_handle, point_atlas_w, point_atlas_h);
            }
        }

        // Upload any external (compressed) textures that finished decoding since the
        // last frame (createTexture can't run in the gl_load callback's context).
        if (inst.tex_up_n != 0) drainTexUploads(inst, &enc);

        // Process a queued pick (camera state is coherent this frame).
        if (inst.pick_pending) {
            inst.pick_pending = false;
            if (raycastSubmesh(inst, a, aspect, inst.pick_ndc_x, inst.pick_ndc_y)) |s| {
                stampName(inst, "data-gl-pick", a, s);
                dispatchPick(inst, a, s);
            }
        }

        // At most one hover raycast per frame, and only when not dragging.
        if (inst.hover_have and !inst.dragging) {
            inst.hover_have = false;
            if (raycastSubmesh(inst, a, aspect, inst.hover_ndc_x, inst.hover_ndc_y)) |s| {
                const hash = gl.vmesh.Reader.nameHash(a.name(s));
                if (hash != inst.hover_name_hash) {
                    inst.hover_name_hash = hash;
                    stampName(inst, "data-gl-hover", a, s);
                }
            } else if (inst.hover_name_hash != no_hover_hash) {
                inst.hover_name_hash = no_hover_hash;
                if (canvasRef(inst)) |h| verve.setRefAttr(h, "data-gl-hover", "");
            }
        }

        // M7: advance per-frame time clock (shared with instanced animation).
        // Done here (unconditionally) so morph weight playback works on non-instanced
        // meshes. The instanced path does NOT re-advance — it reads inst_time_ms below.
        inst.inst_time_ms += dt_ms;

        // M7: sample morph weight tracks and compute the top-8 active set.
        // Uses the same scalar LINEAR/STEP sampling pattern as skinning bone tracks.
        // Morph weights default to 0; only updated when a weight clip is present.
        if (inst.morph_enabled) {
            const t_s: f32 = inst.inst_time_ms / 1000.0;
            const n_targets = @min(a.morphTargetCount(), max_morph_targets);
            var ti: u32 = 0;
            while (ti < n_targets) : (ti += 1) {
                // M8: skip indices locked by a runtime set (parseMorph or anim tween).
                if (inst.morph_runtime_set[ti]) continue;
                if (a.morphWeightTrack(ti)) |trk| {
                    const kc = trk.key_count;
                    if (kc == 0) continue;
                    // Loop the clip: wrap the sample time into [t0, t1) by the
                    // clip duration (default looping, like skinning clips).
                    const t0 = a.morphWeightTime(trk, 0);
                    const t1 = a.morphWeightTime(trk, kc - 1);
                    const tl: f32 = if (t1 > t0) t0 + @mod(t_s - t0, t1 - t0) else t_s;
                    if (kc == 1) {
                        inst.morph_weights[ti] = a.morphWeightValue(trk, 0);
                    } else {
                        // Binary search for the interval containing the looped time.
                        var lo: u32 = 0;
                        var hi: u32 = kc - 1;
                        while (hi - lo > 1) {
                            const mid = lo + (hi - lo) / 2;
                            if (a.morphWeightTime(trk, mid) <= tl) lo = mid else hi = mid;
                        }
                        const ta = a.morphWeightTime(trk, lo);
                        const tb = a.morphWeightTime(trk, hi);
                        const span = tb - ta;
                        const frac: f32 = if (span > 0) (tl - ta) / span else 0;
                        const va = a.morphWeightValue(trk, lo);
                        const vb = a.morphWeightValue(trk, hi);
                        // STEP interp = 1: hold lo value; LINEAR = 0: lerp;
                        // CUBICSPLINE = 2: glTF cubic Hermite (h00/h10/h01/h11).
                        inst.morph_weights[ti] = if (trk.interp == 1) va else if (trk.interp == 2) blk: {
                            const dt = tb - ta;
                            const m0 = a.morphWeightOutTangent(trk, lo) * dt;
                            const m1 = a.morphWeightInTangent(trk, hi) * dt;
                            const t2 = frac * frac;
                            const t3 = t2 * frac;
                            const h00 = 2 * t3 - 3 * t2 + 1;
                            const h10 = t3 - 2 * t2 + frac;
                            const h01 = -2 * t3 + 3 * t2;
                            const h11 = t3 - t2;
                            break :blk h00 * va + h10 * m0 + h01 * vb + h11 * m1;
                        } else va + (vb - va) * frac;
                    }
                }
            }
            // Select the top-32 by |weight| into the active set.
            // Initialise with the first `n` candidates; then displace the
            // weakest if a later target is stronger.
            inst.morph_count = 0;
            var wi: u32 = 0;
            while (wi < n_targets) : (wi += 1) {
                const w = inst.morph_weights[wi];
                const aw = if (w < 0) -w else w;
                if (inst.morph_count < 32) {
                    inst.morph_active_idx[inst.morph_count] = wi;
                    inst.morph_active_wt[inst.morph_count] = w;
                    inst.morph_count += 1;
                } else {
                    // Find the slot with the smallest |weight| in the active set.
                    var min_slot: u32 = 0;
                    var min_aw: f32 = if (inst.morph_active_wt[0] < 0) -inst.morph_active_wt[0] else inst.morph_active_wt[0];
                    var ms: u32 = 1;
                    while (ms < 32) : (ms += 1) {
                        const caw = if (inst.morph_active_wt[ms] < 0) -inst.morph_active_wt[ms] else inst.morph_active_wt[ms];
                        if (caw < min_aw) {
                            min_aw = caw;
                            min_slot = ms;
                        }
                    }
                    if (aw > min_aw) {
                        inst.morph_active_idx[min_slot] = wi;
                        inst.morph_active_wt[min_slot] = w;
                    }
                }
            }
        }

        // ── multi-caster shadow depth pass — render scene depth from EVERY caster.
        // Up to max_2d_casters (4) directional/spot casters tile the 2D atlas (row
        // 0, col = slot) and up to max_point_casters (4) point casters tile the cube
        // atlas, all in this one frame. Per-caster matrices live in Inst (persistent)
        // so the Encoder pointers survive deferred decode (the bridge walks cmd_buf
        // AFTER this fn returns). No casters → no shadow passes; the PBR receiver is
        // fully-lit for out-of-range/none lookups (v3.w==0), so skipping is safe.
        inst.cull_shadow_drawn = 0;
        inst.cull_shadow_culled = 0;

        // ── 2D casters (directional/spot): one tiled pass each into the 4096² atlas.
        if (inst.n_2d_casters > 0) {
            var s: u32 = 0;
            while (s < inst.n_2d_casters) : (s += 1) {
                const area_li = inst.slot_area_li[s]; // ≥0 → this slot is an area caster
                // casters_2d[s] is ONLY written for regular (dir/spot/CSM) caster
                // slots. For an area slot it is undefined/stale, so guard every read
                // of it (and the inst.lights index it derives) behind area_li < 0 —
                // a stale li*16 would OOB-index inst.lights[64] and trap in wasm.
                const li = if (area_li < 0) inst.casters_2d[s] else 0;
                const caster_base = li * 16;
                const caster_type = if (area_li < 0) inst.lights[caster_base + 0] else 0;
                const is_csm = area_li < 0 and inst.cascade_count > 0 and @as(i32, @intCast(li)) == inst.csm_light and s < inst.cascade_count;
                // clipFix is identity on WebGL2, z-remap on WebGPU.
                const light_vp = if (area_li >= 0)
                    // Area caster: spot-like perspective from the rect center along
                    // its normal (cross(ex,ey)).
                    clipFix().mul(areaLightVp(inst, @intCast(area_li)))
                else if (is_csm) blk: {
                    // Cascade s of the CSM caster: fit ortho VP to this cascade's
                    // view-frustum depth slice [near_s, far_s].
                    const near_s: f32 = if (s == 0) cam_near else inst.cascade_splits[s - 1];
                    const far_s: f32 = inst.cascade_splits[s];
                    break :blk clipFix().mul(cascadeLightVp(inst, li, near_s, far_s, aspect, view));
                } else if (caster_type >= 1.5)
                    clipFix().mul(spotLightVp(inst, li)) // spot: perspective
                else
                    clipFix().mul(lightSpaceMatrix(inst, a, li)); // directional: ortho
                // Store the VP in the CONTIGUOUS array (&shadow_vp_mats[0] + count
                // feeds one bind_shadow_map; index s == the atlas tile + receiver slot).
                inst.shadow_vp_mats[s] = light_vp.m;

                // Per-caster light-frustum cull (keeps off-screen casters that cast
                // into view). Atlas tile = (col=s%4, row=s/4): up to 8 slots span
                // rows 0..1 (CSM cascades 0..3 + spots/extra-dir after).
                const lplanes = gl.cull.frustumPlanes(light_vp);
                enc.beginShadowPass(shadow_handle, depth_shader, s % 4, s / 4, shadow_tile);
                // NOTE: double-sided shadows back-cull this phase (drawDepth/drawDepthAt
                // carry no state word; cull is baked into the depth pipeline).
                {
                    // Phase A: opaque+blend (alpha_mode != 2) — plain position-only depth.
                    // depth_mvps_mc[s][sd] precomputed for ALL submeshes (Phase B reuses).
                    var sd: u32 = 0;
                    while (sd < a.submesh_count) : (sd += 1) {
                        if (sd >= max_submesh) break;
                        const sub = a.submesh(sd);
                        inst.depth_mvps_mc[s][sd] = light_vp.mul(inst.scene.world[sd + 1]).m;
                        const wbox = gl.cull.worldAabb(inst.submesh_aabb[sd], inst.scene.world[sd + 1]);
                        if (!gl.cull.aabbInFrustum(lplanes, wbox)) {
                            inst.cull_shadow_culled += 1;
                            continue;
                        }
                        if (sub.alpha_mode == 2) continue; // MASK: Phase B
                        inst.cull_shadow_drawn += 1;
                        enc.drawDepth(vbuf, ibuf, sub.index_byte_off, sub.index_count, @intCast(@intFromPtr(&inst.depth_mvps_mc[s][sd])));
                    }
                    // Phase B: MASK (alpha_mode == 2) — alpha-tested depth (cutout holes).
                    sd = 0;
                    while (sd < a.submesh_count) : (sd += 1) {
                        if (sd >= max_submesh) break;
                        const sub = a.submesh(sd);
                        if (sub.alpha_mode != 2) continue;
                        const wbox = gl.cull.worldAabb(inst.submesh_aabb[sd], inst.scene.world[sd + 1]);
                        if (!gl.cull.aabbInFrustum(lplanes, wbox)) continue; // counted in Phase A
                        inst.cull_shadow_drawn += 1;
                        enc.bindTexture(0, texHandle(sub.tex_base));
                        enc.drawDepthAt(depth_at_shader, vbuf, ibuf, sub.index_byte_off, sub.index_count, @intCast(@intFromPtr(&inst.depth_mvps_mc[s][sd])), @intCast(@intFromPtr(&inst.mats[sd])));
                    }
                }
                enc.endShadowPass(width, height);
            }
        }

        // ── point casters: 6-face distance atlas each. clipFix applied per face.
        // ALL faces of ALL casters render before the single endPointShadow (the
        // WebGPU bridge clears the atlas only on col==0&&row==0 = caster 0 face 0;
        // every later face/caster loads). Tile = (col=face%3, row=pidx*2+face/3).
        if (inst.n_point_casters > 0) {
            var pidx: u32 = 0;
            while (pidx < inst.n_point_casters) : (pidx += 1) {
                const li = inst.casters_point[pidx];
                const caster_base = li * 16;
                const lp = gl.math.Vec3.init(
                    inst.lights[caster_base + 2],
                    inst.lights[caster_base + 3],
                    inst.lights[caster_base + 4],
                );
                inst.point_lp_mc[pidx] = .{ lp.x, lp.y, lp.z };
                // range==far contract: classifyCasters wrote range back into v2.w
                // (default 25 when ≤0), so the depth-pass far matches the receiver far.
                const far: f32 = inst.lights[caster_base + 11];
                inst.point_far_mc[pidx] = far;
                const near: f32 = 0.05;

                var face: u8 = 0;
                while (face < 6) : (face += 1) {
                    const fvp = clipFix().mul(gl.math.cubeFaceVp(lp, face, near, far));
                    inst.face_vp_mc[pidx][face] = fvp.m;
                    const col: u32 = @as(u32, face) % 3;
                    const row: u32 = pidx * 2 + @as(u32, face) / 3;
                    enc.beginPointShadowFace(
                        point_atlas_handle,
                        col,
                        row,
                        point_atlas_tile,
                        @intCast(@intFromPtr(&inst.face_vp_mc[pidx][face])),
                        @intCast(@intFromPtr(&inst.point_lp_mc[pidx])),
                        @bitCast(far),
                    );
                    var sd: u32 = 0;
                    while (sd < a.submesh_count) : (sd += 1) {
                        if (sd >= max_submesh) break;
                        const sub = a.submesh(sd);
                        enc.drawPointDepth(
                            vbuf,
                            ibuf,
                            sub.index_byte_off,
                            sub.index_count,
                            @intCast(@intFromPtr(&inst.scene.world[sd + 1].m)),
                        );
                    }
                }
            }
            enc.endPointShadow(width, height);
        }

        enc.beginFrame(.{ 0.05, 0.06, 0.09, 1.0 }, width, height);

        // CSM frame-globals — MUST be emitted AFTER beginFrame: the bridge resets
        // frameCascadeCount=0 at begin_frame, so an earlier set_csm would be wiped
        // (see S2T2 report). cascade_splits/view_forward are persistent Inst storage.
        if (inst.cascade_count > 0)
            enc.setCsm(inst.cascade_count, @intCast(@intFromPtr(&inst.cascade_splits)), @intCast(@intFromPtr(&inst.view_forward)));

        // Area lights (LTC) — frame-global, emitted ONLY for area scenes AFTER
        // beginFrame (the bridge resets frameAreaCount=0 at begin_frame, like
        // frameCascadeCount, so an earlier set_area_lights would be wiped).
        // bind_ltc_lut handles are advisory: emitting it triggers the bridge's
        // lazy /gl/ltc.bin fetch + binds the real LUTs; non-area scenes omit both
        // → the bridge keeps the dummy 1×1 LUTs bound. area_lights is persistent
        // Inst storage (deferred decode walks cmd_buf post-return).
        if (inst.area_count > 0) {
            enc.setAreaLights(inst.area_count, @intCast(@intFromPtr(&inst.area_lights[0])));
            enc.bindLtcLut(0, 0);
        }

        const pv = clipFix().mul(proj).mul(view);
        // World-space frustum planes for this frame's camera (P9 slice 2).
        const planes = gl.cull.frustumPlanes(pv);
        // Reset per-frame main-pass cull counters (T3). Shadow counters reset above (T4).
        inst.cull_main_drawn = 0;
        inst.cull_main_culled = 0;

        // ── T6: Instanced draw path ───────────────────────────────────────────
        // When the asset carries an instances section (instanceCount > 0), emit ONE
        // draw_pbr_instanced for mesh 0 INSTEAD of the per-submesh loop.
        // Non-instanced assets (instanceCount == 0) fall through byte-identical.
        const inst_n = a.instanceCount();
        if (inst_n > 0 and a.submesh_count > 0) {
            // inst_time_ms already advanced above (unconditional, for morph + instanced).
            const t_s: f32 = inst.inst_time_ms / 1000.0;
            const n = @min(inst_n, max_instances);
            // Seed from baked blob (instanceCount × 80 B = 20 f32 each).
            const blob = a.instances();
            const blob_f32: [*]const f32 = @ptrCast(@alignCast(blob.ptr));
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                // Copy baked mat4 + color (20 f32) into scratch.
                const src = blob_f32[i * 20 ..][0..20];
                inst.instance_scratch[i] = src.*;
                // Animate: add a per-instance vertical wave to the translation column
                // (column 3 = indices 12,13,14 in col-major mat4).  Each instance
                // oscillates at a unique phase so CDP can observe motion.
                const phase: f32 = @as(f32, @floatFromInt(i)) * 0.7;
                inst.instance_scratch[i][13] += @sin(t_s * 2.0 + phase) * 0.15;
            }
            // Store VP (pv = clipFix·proj·view; no model baked in → IS the VP).
            inst.vp_mat = pv.m;
            // Bind sequence mirrors drawSubmesh: setPipeline→setLights→bindIbl→
            // bindShadowMap→bindTexture 0-4→drawPbrInstanced.
            const sub0 = a.submesh(0);
            enc.setPipeline(shaderHandleFor(variant_pbr | variant_inst | (if (inst.fog_enabled) variant_fog else 0)), gl.command.state_depth_test | gl.command.state_cull_back);
            enc.setLights(inst.light_count, @intCast(@intFromPtr(&inst.lights)));
            enc.bindIbl(irr_handle, spec_handle, lut_handle, env.spec_mip_count);
            // Instanced shader is a non-receiver (variant_shadow{,_point} are
            // @compileError with variant_inst), so these binds are inert on the
            // shader side; emitted for stream uniformity with the new signatures.
            bindShadowResources(inst, &enc);
            if (inst.fog_enabled) enc.setFog(@intCast(@intFromPtr(&inst.fog_params)));
            enc.bindTexture(0, texHandle(sub0.tex_base));
            enc.bindTexture(1, texHandle(sub0.tex_mr));
            enc.bindTexture(2, texHandle(sub0.tex_normal));
            enc.bindTexture(3, texHandle(sub0.tex_emissive));
            enc.bindTexture(4, texHandle(sub0.tex_occlusion));
            enc.drawPbrInstanced(vbuf, ibuf, sub0.index_byte_off, sub0.index_count, @intCast(@intFromPtr(&inst.instance_scratch)), n, @intCast(@intFromPtr(&inst.vp_mat)), @intCast(@intFromPtr(&inst.mats[0])), @intCast(@intFromPtr(&inst.camera_pos)));
            enc.endFrame();
            // finish() stamps the cmd_buf length header (buf[0..4]); without it the
            // bridge reads a stale length and truncates the frame before this draw.
            _ = enc.finish();
            return @intCast(@intFromPtr(&cmd_buf));
        }
        // ── end T6 instanced path (non-instanced falls through) ───────────────

        // Two-pass draw (alpha transparency). Pass 1: opaque submeshes in vmesh
        // order, depth-write on — byte-identical to the historical single-pass
        // stream when every submesh is opaque. Pass 2: transparent submeshes
        // sorted back-to-front with state_blend.

        // Pass 1: opaque (alpha_mode == 0).
        // Sentinel 0 is never a valid variant (variant_pbr always set).
        var last_variant: u32 = 0;
        {
            var s: u32 = 0;
            while (s < a.submesh_count) : (s += 1) {
                if (s >= max_submesh) break;
                const sub1 = a.submesh(s);
                if (sub1.alpha_mode == 1) continue; // Pass 1 = opaque + mask (skip blend)
                if (!visibleAfterCull(inst, planes, s)) {
                    inst.cull_main_culled += 1;
                    continue;
                }
                // single-sided → cull back; double-sided → cull off (both faces).
                const cull: u32 = if (sub1.double_sided != 0) 0 else gl.command.state_cull_back;
                inst.cull_main_drawn += 1;
                drawSubmesh(inst, a, &enc, s, gl.command.state_depth_test | cull, &last_variant, env, pv);
            }
        }

        // Pass 2: transparent (alpha_mode == 1) — sorted far→near, blend on.
        var tcount: u32 = 0;
        const tidx = &inst.tidx;
        const tkey = &inst.tkey;
        {
            var s: u32 = 0;
            while (s < a.submesh_count) : (s += 1) {
                if (s >= max_submesh) break;
                if (a.submesh(s).alpha_mode != 1) continue;
                if (!visibleAfterCull(inst, planes, s)) {
                    inst.cull_main_culled += 1;
                    continue;
                }
                const wbox = gl.cull.worldAabb(inst.submesh_aabb[s], inst.scene.world[s + 1]);
                const cx = (wbox.min.x + wbox.max.x) * 0.5 - inst.camera_pos[0];
                const cy = (wbox.min.y + wbox.max.y) * 0.5 - inst.camera_pos[1];
                const cz = (wbox.min.z + wbox.max.z) * 0.5 - inst.camera_pos[2];
                tidx[tcount] = s;
                tkey[tcount] = cx * cx + cy * cy + cz * cz; // squared distance
                tcount += 1;
            }
        }
        // Selection sort by DESCENDING key (farthest first = back-to-front).
        {
            var i: u32 = 0;
            while (i < tcount) : (i += 1) {
                var maxj: u32 = i;
                var j: u32 = i + 1;
                while (j < tcount) : (j += 1) {
                    if (tkey[j] > tkey[maxj]) maxj = j;
                }
                if (maxj != i) {
                    std.mem.swap(f32, &tkey[i], &tkey[maxj]);
                    std.mem.swap(u32, &tidx[i], &tidx[maxj]);
                }
            }
        }
        var tlast_variant: u32 = 0;
        {
            var i: u32 = 0;
            while (i < tcount) : (i += 1) {
                const s = tidx[i];
                const sub = a.submesh(s);
                inst.cull_main_drawn += 1; // count once per submesh, not per cull-front/back pass
                if (sub.double_sided != 0) {
                    // Double-sided BLEND: two-pass — back faces (cull front) then
                    // front faces (cull back) for correct over-blend compositing.
                    // Both passes share the same variant; state word differs so each
                    // needs its own SET_PIPELINE + full lights/IBL/shadow re-emit.
                    const ds_sbit: u32 = if (pointActive(inst)) gl.command.variant_shadow_point else 0;
                    const v = a.submeshVariant(s) |
                        (if (inst.fog_enabled) variant_fog else 0) |
                        (if (inst.morph_enabled) variant_morph else 0) |
                        ds_sbit;
                    const world_s = inst.scene.world[s + 1];
                    inst.model_mats[s] = world_s.m;
                    inst.normal9s[s] = gl.math.normalMatrix(world_s);
                    inst.mvps[s] = pv.mul(world_s).m;
                    // Pass A: cull front → back faces drawn.
                    enc.setPipeline(shaderHandleFor(v), gl.command.state_depth_test | gl.command.state_cull_front | gl.command.state_blend);
                    enc.setLights(inst.light_count, @intCast(@intFromPtr(&inst.lights)));
                    enc.bindIbl(irr_handle, spec_handle, lut_handle, env.spec_mip_count);
                    bindShadowResources(inst, &enc);
                    if (inst.fog_enabled) enc.setFog(@intCast(@intFromPtr(&inst.fog_params)));
                    if (inst.morph_enabled) enc.setMorphWeights(inst.morph_count, @intCast(@intFromPtr(&inst.morph_active_idx)), @intCast(@intFromPtr(&inst.morph_active_wt)));
                    enc.bindTexture(0, texHandle(sub.tex_base));
                    enc.bindTexture(1, texHandle(sub.tex_mr));
                    enc.bindTexture(2, texHandle(sub.tex_normal));
                    enc.bindTexture(3, texHandle(sub.tex_emissive));
                    enc.bindTexture(4, texHandle(sub.tex_occlusion));
                    enc.drawPbr(vbuf, ibuf, sub.index_byte_off, sub.index_count, @intCast(@intFromPtr(&inst.mvps[s])), @intCast(@intFromPtr(&inst.model_mats[s])), @intCast(@intFromPtr(&inst.normal9s[s])), @intCast(@intFromPtr(&inst.mats[s])), @intCast(@intFromPtr(&inst.camera_pos)));
                    // Pass B: cull back → front faces drawn.
                    enc.setPipeline(shaderHandleFor(v), gl.command.state_depth_test | gl.command.state_cull_back | gl.command.state_blend);
                    enc.setLights(inst.light_count, @intCast(@intFromPtr(&inst.lights)));
                    enc.bindIbl(irr_handle, spec_handle, lut_handle, env.spec_mip_count);
                    bindShadowResources(inst, &enc);
                    if (inst.fog_enabled) enc.setFog(@intCast(@intFromPtr(&inst.fog_params)));
                    if (inst.morph_enabled) enc.setMorphWeights(inst.morph_count, @intCast(@intFromPtr(&inst.morph_active_idx)), @intCast(@intFromPtr(&inst.morph_active_wt)));
                    enc.bindTexture(0, texHandle(sub.tex_base));
                    enc.bindTexture(1, texHandle(sub.tex_mr));
                    enc.bindTexture(2, texHandle(sub.tex_normal));
                    enc.bindTexture(3, texHandle(sub.tex_emissive));
                    enc.bindTexture(4, texHandle(sub.tex_occlusion));
                    enc.drawPbr(vbuf, ibuf, sub.index_byte_off, sub.index_count, @intCast(@intFromPtr(&inst.mvps[s])), @intCast(@intFromPtr(&inst.model_mats[s])), @intCast(@intFromPtr(&inst.normal9s[s])), @intCast(@intFromPtr(&inst.mats[s])), @intCast(@intFromPtr(&inst.camera_pos)));
                    // Force re-bind for next submesh (state changed; variant may match).
                    tlast_variant = 0;
                } else {
                    drawSubmesh(inst, a, &enc, s, gl.command.state_depth_test | gl.command.state_cull_back | gl.command.state_blend, &tlast_variant, env, pv);
                }
            }
        }
        enc.endFrame();
    } else {
        // Assets still loading / failed: clear-only frame.
        enc.beginFrame(.{ 0.05, 0.06, 0.09, 1.0 }, width, height);
        enc.endFrame();
    }
    _ = enc.finish();
    return @intCast(@intFromPtr(&cmd_buf));
}

/// Frustum-cull test for submesh `s` against this frame's world-space planes.
/// Factored verbatim from the historical single-pass draw loop.
fn visibleAfterCull(inst: *Inst, planes: [6]gl.cull.Plane, s: u32) bool {
    const wbox = gl.cull.worldAabb(inst.submesh_aabb[s], inst.scene.world[s + 1]);
    return gl.cull.aabbInFrustum(planes, wbox);
}

/// Return the four per-frame cull counters for the active instance as a packed
/// u32 so JS can read them in a single wasm call.
///
/// Encoding (each field fits in a byte — max submesh count is 128 < 256):
///   bits  7:0  — cull_main_drawn
///   bits 15:8  — cull_main_culled
///   bits 23:16 — cull_shadow_drawn   (populated in T4)
///   bits 31:24 — cull_shadow_culled  (populated in T4)
///
/// Returns 0 when no instance is selected (guard; same pattern as glscene_frame).
export fn glscene_cull_stats() u32 {
    const inst = current orelse return 0;
    return (inst.cull_main_drawn & 0xff) |
        ((inst.cull_main_culled & 0xff) << 8) |
        ((inst.cull_shadow_drawn & 0xff) << 16) |
        ((inst.cull_shadow_culled & 0xff) << 24);
}

// ── /gl-morph runtime controls ────────────────────────────────────────────────

/// Lock target 0 (Bulge) to weight 1.0 at runtime, overriding the baked clip
/// for that index while the clip continues animating targets 1 and 2.
export fn glmorph_bulge_on() void {
    const inst = current orelse return;
    inst.morph_weights[0] = 1.0;
    inst.morph_runtime_set[0] = true;
}

/// Release the runtime lock on target 0; the baked clip resumes animating it.
export fn glmorph_reset() void {
    const inst = current orelse return;
    inst.morph_weights[0] = 0.0;
    inst.morph_runtime_set[0] = false;
}

// Debug/test-harness freeze (wired to the /gl-multishadow button via
// z-on-click). Pins the auto-orbit so the user's CDP run has a stable frame for
// pixel metrics; orbit drag still works. Page-global (mirrors glskin_freeze).
export fn glscene_freeze() void {
    freeze = true;
}
export fn glscene_unfreeze() void {
    freeze = false;
}

/// True when this instance has at least one point-shadow caster — selects the
/// variant_shadow_point receiver shaders (handles 53–68, which now ALSO bake
/// variant_shadow so they receive BOTH 2D and point casters simultaneously).
fn pointActive(inst: *const Inst) bool {
    return inst.n_point_casters > 0;
}

/// Emit the receiver shadow binds with the multi-caster signatures, once per
/// pipeline (re-emitted on WebGL2 because uniform locations are per-program;
/// idempotent re-stash on WebGPU). bindShadowMap uploads the CONTIGUOUS 2D-caster
/// VP array (count = n_2d_casters; atlas handle 0 when there are none). The
/// receiver reads per-light slot/kind from the lights array (uploaded via
/// setLights), so no other per-draw shadow state is needed.
fn bindShadowResources(inst: *const Inst, enc: *gl.Encoder) void {
    enc.bindShadowMap(
        gl.command.tex_slot_shadow,
        if (inst.n_2d_casters > 0) shadow_handle else 0,
        @intCast(@intFromPtr(&inst.shadow_vp_mats[0])),
        inst.n_2d_casters,
    );
    if (inst.n_point_casters > 0)
        enc.bindPointShadow(gl.command.tex_slot_point_shadow, point_atlas_handle);
}

/// Emit the draw commands for a single submesh `s` with the given pipeline
/// `state` word. Lazily re-emits SET_PIPELINE (+ lights/IBL/shadow rebind) when
/// the variant changes vs `last_variant.*`. `pv` is the clip-space proj*view.
/// Factored verbatim from the historical single-pass draw loop — opaque output
/// is byte-identical to the old stream.
fn drawSubmesh(
    inst: *Inst,
    a: *const gl.vmesh.Reader,
    enc: *gl.Encoder,
    s: u32,
    state: u32,
    last_variant: *u32,
    env: *const gl.venv.Reader,
    pv: gl.math.Mat4,
) void {
    const sub = a.submesh(s);
    // Fold in the shadow receiver bit. The base variant always bakes variant_shadow
    // (2D receiver, handles 1–52). When ANY point caster is present, switch to the
    // variant_shadow_point handles (53–68) which now bake BOTH variant_shadow AND
    // variant_shadow_point, so a single program receives 2D + point casters at once.
    const sbit: u32 = if (pointActive(inst)) gl.command.variant_shadow_point else 0;
    const v = a.submeshVariant(s) |
        (if (inst.fog_enabled) variant_fog else 0) |
        (if (inst.morph_enabled) variant_morph else 0) |
        sbit;
    if (v != last_variant.*) {
        enc.setPipeline(shaderHandleFor(v), state);
        enc.setLights(inst.light_count, @intCast(@intFromPtr(&inst.lights)));
        enc.bindIbl(irr_handle, spec_handle, lut_handle, env.spec_mip_count);
        // Re-bind per-pipeline (WebGL2 uniforms are per-program; WebGPU re-stash).
        bindShadowResources(inst, enc);
        if (inst.fog_enabled) enc.setFog(@intCast(@intFromPtr(&inst.fog_params)));
        if (inst.morph_enabled) enc.setMorphWeights(inst.morph_count, @intCast(@intFromPtr(&inst.morph_active_idx)), @intCast(@intFromPtr(&inst.morph_active_wt)));
        last_variant.* = v;
    }
    const world_s = inst.scene.world[s + 1];
    inst.model_mats[s] = world_s.m;
    inst.normal9s[s] = gl.math.normalMatrix(world_s);
    inst.mvps[s] = pv.mul(world_s).m;
    enc.bindTexture(0, texHandle(sub.tex_base));
    enc.bindTexture(1, texHandle(sub.tex_mr));
    enc.bindTexture(2, texHandle(sub.tex_normal));
    enc.bindTexture(3, texHandle(sub.tex_emissive));
    enc.bindTexture(4, texHandle(sub.tex_occlusion));
    enc.drawPbr(
        vbuf,
        ibuf,
        sub.index_byte_off,
        sub.index_count,
        @intCast(@intFromPtr(&inst.mvps[s])),
        @intCast(@intFromPtr(&inst.model_mats[s])),
        @intCast(@intFromPtr(&inst.normal9s[s])),
        @intCast(@intFromPtr(&inst.mats[s])),
        @intCast(@intFromPtr(&inst.camera_pos)),
    );
}

/// One-time GPU resource upload, mirrored into `inst.registry` for restore replay.
fn sendResources(inst: *Inst, enc: *gl.Encoder, a: *const gl.vmesh.Reader, env: *const gl.venv.Reader) void {
    enc.createBuffer(vbuf, .vertex, @intCast(@intFromPtr(a.vertices.ptr)), @intCast(a.vertices.len));
    inst.registry.recordBuffer(vbuf, .vertex, @intCast(@intFromPtr(a.vertices.ptr)), @intCast(a.vertices.len));
    enc.createBuffer(ibuf, .index, @intCast(@intFromPtr(a.indices.ptr)), @intCast(a.indices.len));
    inst.registry.recordBuffer(ibuf, .index, @intCast(@intFromPtr(a.indices.ptr)), @intCast(a.indices.len));

    // M7: detect morph presence from the vmesh and set inst.morph_enabled.
    const morph_target_count = a.morphTargetCount();
    inst.morph_enabled = morph_target_count > 0;

    // Create + record only the distinct shader variants the mesh actually uses.
    // [69]: slots 20–35 = base/ds fog variants; slot 36 = instanced+fog;
    //        slots 37–52 = base/ds morph variants (M7);
    //        slots 53–68 = base/ds point-shadow receiver variants (P11 task 5).
    var shader_seen: [69]bool = .{false} ** 69;
    var sv: u32 = 0;
    while (sv < a.submesh_count) : (sv += 1) {
        if (sv >= max_submesh) break;
        const variant = a.submeshVariant(sv) |
            (if (inst.fog_enabled) variant_fog else 0) |
            (if (inst.morph_enabled) variant_morph else 0);
        const handle = shaderHandleFor(variant);
        if (shader_seen[handle]) continue;
        shader_seen[handle] = true;
        createShaderForVariant(inst, enc, variant);
    }

    // P11 task 5: emit point-shadow receiver shaders for each bare variant in use.
    // Distinct handles (53–68) so the 2D-shadow shaders (handles 1–52) are unchanged.
    // No fog or morph combined with point-shadow in v1; no instanced+point.
    {
        var psv: u32 = 0;
        while (psv < a.submesh_count) : (psv += 1) {
            if (psv >= max_submesh) break;
            // bare variant only (no fog/morph — point-shadow v1 does not combine them)
            const bare = a.submeshVariant(psv);
            const pv = bare | gl.command.variant_shadow_point;
            const ph = shaderHandleFor(pv);
            if (shader_seen[ph]) continue;
            shader_seen[ph] = true;
            createShaderForVariant(inst, enc, pv);
        }
    }

    // T6: emit the instanced shader if this mesh carries an instances section.
    // Use fog-aware handle (19 without fog, 36 with fog). Morph+instanced is
    // not supported (both backends @compileError) so no variant_morph here.
    const inst_handle: usize = shaderHandleFor(variant_pbr | variant_inst | (if (inst.fog_enabled) variant_fog else 0));
    if (a.instanceCount() > 0 and !shader_seen[inst_handle]) {
        emitInstancedShader(inst, enc);
        shader_seen[inst_handle] = true;
    }

    // M7: create the morph data texture (ONCE — width=vertexCount, height=targetCount*2).
    // The morph deltas blob (f16 POSITION+NORMAL interleaved) lives in the asset
    // region for the page lifetime, so the recorded pointer stays valid.
    // Registry has no recordMorphTex; instead inst.morph_tex_recorded flags the
    // restore path in glscene_frame to re-emit createMorphTex after registry.replay.
    if (inst.morph_enabled) {
        const morph_vertex_count = a.morphVertexCount();
        const deltas = a.morphDeltas();
        enc.createMorphTex(morph_tex_handle, morph_vertex_count, morph_target_count * 2, @intCast(@intFromPtr(deltas.ptr)), @intCast(deltas.len));
        inst.morph_tex_recorded = true;
    }

    // Shadow-pass resources (P9 slice 3): the depth-only shader + depth target.
    emitDepthShader(inst, enc);
    var has_mask = false;
    {
        var mi: u32 = 0;
        while (mi < a.submesh_count and mi < max_submesh) : (mi += 1) {
            if (a.submesh(mi).alpha_mode == 2) has_mask = true;
        }
    }
    if (has_mask) emitDepthAtShader(inst, enc);
    enc.createShadowMap(shadow_handle, shadow_size);
    inst.registry.recordShadowMap(shadow_handle, shadow_size);

    // Multi-caster point shadow atlas (RGBA8 1536×4096, 3 cols × 8 rows of 512²
    // tiles = 6 faces × up to max_point_casters casters). Created alongside the 2D
    // atlas (both are cheap allocations; the per-frame dispatch fills only the tiles
    // its casters use). Registry has no recordPointShadow; inst.point_atlas_sent
    // flags the restore path to re-emit createPointShadow after registry.replay.
    enc.createPointShadow(point_atlas_handle, point_atlas_w, point_atlas_h);
    inst.point_atlas_sent = true;

    var t: u32 = 0;
    while (t < a.tex_count) : (t += 1) {
        if (a.texFormat(t) != .raw) continue; // external (compressed): streamed below
        const tex = a.texture(t);
        const ptr: u32 = @intCast(@intFromPtr(tex.rgba.ptr));
        const len: u32 = @intCast(tex.rgba.len);
        if (a.texIsSrgb(t)) {
            enc.createTextureSrgb(t + 1, tex.width, tex.height, ptr, len);
            inst.registry.recordTextureSrgb(t + 1, tex.width, tex.height, ptr, len);
        } else {
            enc.createTexture(t + 1, tex.width, tex.height, ptr, len);
            inst.registry.recordTexture(t + 1, tex.width, tex.height, ptr, len);
        }
    }
    // Kick external (compressed) material textures — fetched + worker-decoded, then
    // uploaded on later frames by drainTexUploads. Raw textures handled inline above.
    inst.tex_scan = 0;
    loadNextExternalTex(inst, a);

    enc.createTextureEx(irr_handle, .cube, .rgba16f, env.irr_size, env.irr_size, 1, @intCast(@intFromPtr(env.irradiance.ptr)), @intCast(env.irradiance.len));
    inst.registry.recordTextureEx(irr_handle, .cube, .rgba16f, env.irr_size, env.irr_size, 1, @intCast(@intFromPtr(env.irradiance.ptr)), @intCast(env.irradiance.len));
    enc.createTextureEx(spec_handle, .cube, .rgba16f, env.spec_size, env.spec_size, env.spec_mip_count, @intCast(@intFromPtr(env.specular.ptr)), @intCast(env.specular.len));
    inst.registry.recordTextureEx(spec_handle, .cube, .rgba16f, env.spec_size, env.spec_size, env.spec_mip_count, @intCast(@intFromPtr(env.specular.ptr)), @intCast(env.specular.len));
    enc.createTextureEx(lut_handle, .tex_2d, .rgba16f, env.lut_size, env.lut_size, 1, @intCast(@intFromPtr(env.lut.ptr)), @intCast(env.lut.len));
    inst.registry.recordTextureEx(lut_handle, .tex_2d, .rgba16f, env.lut_size, env.lut_size, 1, @intCast(@intFromPtr(env.lut.ptr)), @intCast(env.lut.len));
}

/// If submesh `s`'s name matches a registered pick, fire its SSR closure
/// (`onPick`) and/or dispatch its DOM CustomEvent (`onPickExport`).
fn dispatchPick(inst: *const Inst, a: *const gl.vmesh.Reader, s: u32) void {
    const nm = a.name(s);
    if (nm.len == 0) return;
    var i: usize = 0;
    while (i < inst.pick_count) : (i += 1) {
        const reg = inst.pick_names[i][0..inst.pick_name_lens[i]];
        if (!eql(reg, nm)) continue;
        if (inst.pick_ids[i] != 0) verve.dispatchEvent(inst.pick_ids[i]);
        if (inst.pick_export_lens[i] != 0) {
            if (inst.canvas_handle) |h| {
                const ev = inst.pick_exports[i][0..inst.pick_export_lens[i]];
                gl_emit_event(h, ev.ptr, @intCast(ev.len), nm.ptr, @intCast(nm.len));
            }
        }
        return;
    }
}

// ── scrub timeline build (Task 9) ──────────────────────────────────────────────

/// Per-instance gl-setter trampoline. `animGlSetter` wants a default-callconv
/// `fn(u32, f64) void` pointer with no instance argument, so we emit one
/// trampoline per slot at comptime, each hard-wired to `instances[slot]`. The
/// scrub timeline registers THIS instance's trampoline.
fn makeTrampoline(comptime slot: usize) fn (u32, f64) void {
    return struct {
        fn f(target_id: u32, value: f64) void {
            applyAnimTarget(&instances[slot], target_id, @floatCast(value));
        }
    }.f;
}
const trampolines = blk: {
    var t: [MAX_INSTANCES]*const fn (u32, f64) void = undefined;
    for (0..MAX_INSTANCES) |i| t[i] = &makeTrampoline(i);
    break :blk t;
};

/// Per-instance deferred-target resolver trampoline. Maps a deferred SSR target
/// (placeholder id + FNV name_hash) to a frozen id by looking up the submesh
/// index in THIS instance's loaded vmesh name table. Returns 0 when the mesh
/// isn't loaded yet or the name is absent — the bridge skips and retries.
fn makeResolverTrampoline(comptime slot: usize) fn (u32, u32) u32 {
    return struct {
        fn f(placeholder_id: u32, name_hash: u32) u32 {
            const inst = &instances[slot];
            const a = if (inst.asset) |*as| as else return 0;
            const idx = a.findName(name_hash) orelse return 0;
            const d = gl.anim_target.decode(placeholder_id) orelse return 0;
            return gl.anim_target.encode(d.kind, @intCast(idx), d.field);
        }
    }.f;
}
const resolver_trampolines = blk: {
    var t: [MAX_INSTANCES]*const fn (u32, u32) u32 = undefined;
    for (0..MAX_INSTANCES) |i| t[i] = &makeResolverTrampoline(i);
    break :blk t;
};

/// Build the scroll-scrubbed turntable + roughness-ramp timeline. Runs ONCE per
/// instance, after the vmesh Reader is available (so `material:<Name>` resolves).
fn buildScrubTimeline(inst: *Inst) void {
    inst.scrub_built = true; // attempt once regardless of outcome

    if (inst.asset == null) return;
    const a = &inst.asset.?;

    // The scroll section is the trigger; use the hydrate-cached handle (queryRef
    // here, in the unscoped asset callback, would miss the vid-suffixed ref).
    const section = inst.scroll_section_handle orelse return;

    // Register THIS instance's gl-setter trampoline once.
    if (inst.anim_setter_slot == 0)
        inst.anim_setter_slot = verve.animGlSetter(trampolines[slotIndex(inst)]);
    const slot = inst.anim_setter_slot;
    if (slot == 0) return; // setter registration failed → no scrub

    // Register THIS instance's deferred-target resolver (page-default) once, so
    // SSR-declared material:/node: tweens can resolve name_hash → submesh index.
    if (inst.anim_resolver_slot == 0)
        inst.anim_resolver_slot = verve.animGlResolver(resolver_trampolines[slotIndex(inst)]);

    const mark = verve.chunkArenaMark();
    defer verve.chunkArenaReset(mark);
    const arena = verve.chunkArena();

    // Camera yaw turntable: from current yaw → +2π (one full revolution).
    const yaw_id = gl.anim_target.encode(.camera, 0, @intFromEnum(gl.anim_target.CameraField.yaw));
    const yaw_from: f64 = inst.orbit.yaw;
    const yaw_to: f64 = yaw_from + std.math.tau;

    const t = anim.to(arena, null)
        .glTargetRange(yaw_id, slot, yaw_from, yaw_to)
        .duration(1.0) // scrub maps progress over the scroll range; absolute ignored
        .ease(.linear);

    // Optional roughness ramp on the named material — skipped silently when the
    // mesh has no matching name (camera still scrubs).
    if (gl.anim_target.resolvePath(a, "material:Cube.roughness")) |rough_id|
        _ = t.glTargetRange(rough_id, slot, 0.045, 1.0);

    // P6 additions, same silently-skipped pattern.
    if (gl.anim_target.resolvePath(a, "node:Cube.rotationX")) |rx_id|
        _ = t.glTargetRange(rx_id, slot, -0.35, 0.35);
    if (gl.anim_target.resolvePath(a, "material:Cube.emissiveR")) |er_id|
        _ = t.glTargetRange(er_id, slot, 0.0, 0.6);

    _ = t.scrollTrigger(.{
        .trigger_handle = section,
        .start = .{ .trigger = .top, .viewport = .top },
        .end = .{ .at = .{ .trigger = .bottom, .viewport = .top } },
        .scrub = .{ .smooth = 0.4 },
    });

    if (verve.animPlay(t)) |h| {
        inst.scrub_anim_id = h.id; // nonzero on success
    } else {
        inst.scrub_anim_id = 0; // build/serialize/zero-match failure → no-op
    }
}

// ── animation setter ─────────────────────────────────────────────────────────

/// Write one tweened engine value into `inst`. Decodes the target id and stores
/// into the matching field. Unknown/invalid ids are silently ignored.
fn applyAnimTarget(inst: *Inst, id: u32, value: f32) void {
    const d = gl.anim_target.decode(id) orelse return;
    switch (d.kind) {
        .camera => switch (@as(gl.anim_target.CameraField, @enumFromInt(d.field))) {
            .yaw => inst.orbit.yaw = value,
            .pitch => {
                const lo = inst.orbit.min_pitch;
                const hi = inst.orbit.max_pitch;
                inst.orbit.pitch = if (value < lo) lo else if (value > hi) hi else value;
            },
            .distance => {
                const lo = inst.orbit.min_distance;
                const hi = inst.orbit.max_distance;
                inst.orbit.distance = if (value < lo) lo else if (value > hi) hi else value;
            },
        },
        .material => {
            const s: usize = d.submesh;
            const cap = if (inst.asset) |*a| @as(usize, a.submesh_count) else @as(usize, 0);
            if (s >= max_submesh or s >= cap) return;
            switch (@as(gl.anim_target.MaterialField, @enumFromInt(d.field))) {
                .metallic => inst.mats[s][4] = value,
                .roughness => inst.mats[s][5] = value,
                .emissive_r => inst.mats[s][8] = value,
                .emissive_g => inst.mats[s][9] = value,
                .emissive_b => inst.mats[s][10] = value,
                .base_color_r => inst.mats[s][0] = value,
                .base_color_g => inst.mats[s][1] = value,
                .base_color_b => inst.mats[s][2] = value,
                .base_color_a => inst.mats[s][3] = value,
            }
        },
        .model => switch (@as(gl.anim_target.ModelField, @enumFromInt(d.field))) {
            .yaw => inst.model_yaw = value,
        },
        .node => {
            const s: usize = d.submesh;
            if (s >= max_submesh) return;
            switch (@as(gl.anim_target.NodeField, @enumFromInt(d.field))) {
                .rotation_x => inst.node_rot[s][0] = value,
                .rotation_y => inst.node_rot[s][1] = value,
                .rotation_z => inst.node_rot[s][2] = value,
                .translate_x => inst.node_pos[s][0] = value,
                .translate_y => inst.node_pos[s][1] = value,
                .translate_z => inst.node_pos[s][2] = value,
                .scale_x => inst.node_scale[s][0] = value,
                .scale_y => inst.node_scale[s][1] = value,
                .scale_z => inst.node_scale[s][2] = value,
            }
        },
        .morph => {
            // field is the morph target index (0–255); cap to max_morph_targets.
            const idx: usize = d.field;
            if (idx >= max_morph_targets) return;
            inst.morph_weights[idx] = value;
            // Mark as runtime-set so the per-frame baked-clip advance skips this
            // index and the runtime value is not clobbered each frame.
            inst.morph_runtime_set[idx] = true;
        },
    }
}

/// Exported entry point called by the animation runtime for the page-default
/// (slot-0) setter. The bridge selects the right instance before calling it.
pub export fn glscene_anim_set(target_id: u32, value: f64) void {
    const inst = current orelse return;
    applyAnimTarget(inst, target_id, @floatCast(value));
}

/// Resolve a deferred material:/node: target: map name_hash → submesh index via
/// the loaded vmesh name table and re-encode to a frozen id. Returns 0 when the
/// mesh isn't loaded yet or the name is absent (the bridge skips and retries).
pub export fn glscene_resolve_target(placeholder_id: u32, name_hash: u32) u32 {
    const inst = current orelse return 0;
    const a = if (inst.asset) |*as| as else return 0;
    const idx = a.findName(name_hash) orelse return 0;
    const d = gl.anim_target.decode(placeholder_id) orelse return 0;
    return gl.anim_target.encode(d.kind, @intCast(idx), d.field);
}

test "fog handle table covers every emitted fog combo" {
    const combos = [_]u32{
        variant_pbr | variant_fog,
        variant_pbr | variant_nm | variant_fog,
        variant_pbr | variant_em | variant_fog,
        variant_pbr | variant_nm | variant_em | variant_fog,
        variant_pbr | variant_at | variant_fog,
        variant_pbr | variant_nm | variant_at | variant_fog,
        variant_pbr | variant_em | variant_at | variant_fog,
        variant_pbr | variant_nm | variant_em | variant_at | variant_fog,
        variant_pbr | variant_ds | variant_fog,
        variant_pbr | variant_nm | variant_ds | variant_fog,
        variant_pbr | variant_em | variant_ds | variant_fog,
        variant_pbr | variant_nm | variant_em | variant_ds | variant_fog,
        variant_pbr | variant_at | variant_ds | variant_fog,
        variant_pbr | variant_nm | variant_at | variant_ds | variant_fog,
        variant_pbr | variant_em | variant_at | variant_ds | variant_fog,
        variant_pbr | variant_nm | variant_em | variant_at | variant_ds | variant_fog,
        variant_pbr | variant_inst | variant_fog,
    };
    var seen = [_]bool{false} ** 64;
    for (combos) |v| {
        const h = shaderHandleFor(v);
        try std.testing.expect(h >= 20 and h < seen.len);
        try std.testing.expect(!seen[h]); // distinct
        seen[h] = true;
    }
}

test "morph handle table covers every emitted morph combo" {
    // M7: 16 morph variants (8 base + 8 ds); no instanced+morph (compileError).
    // shaderHandleFor and createShaderForVariant MUST cover the same set.
    const combos = [_]u32{
        variant_pbr | variant_morph,
        variant_pbr | variant_nm | variant_morph,
        variant_pbr | variant_em | variant_morph,
        variant_pbr | variant_nm | variant_em | variant_morph,
        variant_pbr | variant_at | variant_morph,
        variant_pbr | variant_nm | variant_at | variant_morph,
        variant_pbr | variant_em | variant_at | variant_morph,
        variant_pbr | variant_nm | variant_em | variant_at | variant_morph,
        variant_pbr | variant_ds | variant_morph,
        variant_pbr | variant_nm | variant_ds | variant_morph,
        variant_pbr | variant_em | variant_ds | variant_morph,
        variant_pbr | variant_nm | variant_em | variant_ds | variant_morph,
        variant_pbr | variant_at | variant_ds | variant_morph,
        variant_pbr | variant_nm | variant_at | variant_ds | variant_morph,
        variant_pbr | variant_em | variant_at | variant_ds | variant_morph,
        variant_pbr | variant_nm | variant_em | variant_at | variant_ds | variant_morph,
    };
    // Morph handles are 37–52; use a seen array sized to cover that range.
    var seen = [_]bool{false} ** 53;
    for (combos) |v| {
        const h = shaderHandleFor(v);
        try std.testing.expect(h >= 37 and h < seen.len);
        try std.testing.expect(!seen[h]); // distinct
        seen[h] = true;
    }
    // All 16 morph handles must be assigned (37..52 inclusive).
    var hi: u32 = 37;
    while (hi <= 52) : (hi += 1) {
        try std.testing.expect(seen[hi]);
    }
}

test "point-shadow handle table covers every emitted point-shadow combo" {
    // P11 task 5: 16 point-shadow receiver variants (8 base + 8 ds).
    // Handles 53–68 are distinct from the 2D-shadow handles (1–52) and from
    // each other. No instanced+point (compileError); no fog or morph in v1.
    // shaderHandleFor and createShaderForVariant MUST cover the same set.
    const vsp = gl.command.variant_shadow_point;
    const combos = [_]u32{
        variant_pbr | vsp,
        variant_pbr | variant_nm | vsp,
        variant_pbr | variant_em | vsp,
        variant_pbr | variant_nm | variant_em | vsp,
        variant_pbr | variant_at | vsp,
        variant_pbr | variant_nm | variant_at | vsp,
        variant_pbr | variant_em | variant_at | vsp,
        variant_pbr | variant_nm | variant_em | variant_at | vsp,
        variant_pbr | variant_ds | vsp,
        variant_pbr | variant_nm | variant_ds | vsp,
        variant_pbr | variant_em | variant_ds | vsp,
        variant_pbr | variant_nm | variant_em | variant_ds | vsp,
        variant_pbr | variant_at | variant_ds | vsp,
        variant_pbr | variant_nm | variant_at | variant_ds | vsp,
        variant_pbr | variant_em | variant_at | variant_ds | vsp,
        variant_pbr | variant_nm | variant_em | variant_at | variant_ds | vsp,
    };
    // Point-shadow handles 53–68; seen array sized to cover that range.
    var seen = [_]bool{false} ** 69;
    for (combos) |v| {
        const h = shaderHandleFor(v);
        try std.testing.expect(h >= 53 and h < seen.len);
        try std.testing.expect(!seen[h]); // distinct
        seen[h] = true;
    }
    // All 16 point-shadow handles must be assigned (53..68 inclusive).
    var hi: u32 = 53;
    while (hi <= 68) : (hi += 1) {
        try std.testing.expect(seen[hi]);
    }
}
