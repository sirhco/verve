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
// Shader handles 1..4 live in the bridge's separate `st.shaders[]` namespace
// (distinct from buffers/textures), one per PBR variant — see shaderHandleFor.
const irr_handle: u32 = 16;
const spec_handle: u32 = 17;
const lut_handle: u32 = 18;

// P9 slice 3 — single directional shadow map. The depth-only shader lives at
// handle 5 (above the four PBR variants 1..4); the shadow map is handle 1 in the
// bridge's separate `st.shadowMaps[]` namespace.
const depth_shader: u32 = 5;
const shadow_handle: u32 = 1;
const shadow_size: u32 = 1024;

const max_submesh = 8; // material-pool cap
const max_tex = 8; // material-texture cap (per mesh)

// A worker-decoded external texture awaiting upload on the next frame.
const TexUpload = struct { handle: u32, w: u32, h: u32, ptr: u32, len: u32, srgb: bool };
const max_picks = 4; // mirror of gl_scene.zig max_picks
const max_name = 64; // per-name fixed storage
const no_hover_hash: u32 = 0xFFFF_FFFF;

// Up to four PBR variants per mesh: variant_pbr is always set; normal_map and
// emissive are independent sub-bits. Each maps to a fixed shader handle 1..4 in
// the bridge's `st.shaders[]` namespace (separate from buffers/textures).
const variant_pbr = gl.command.variant_pbr;
const variant_nm = gl.command.variant_normal_map;
const variant_em = gl.command.variant_emissive;

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
};

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
    depth_mvps: [max_submesh][16]f32 = undefined, // P9 slice 3 shadow pass
    light_vp_mat: [16]f32 = undefined,
    mats: [max_submesh][12]f32 = undefined, // per-submesh material block

    // Single directional light from props: 8 f32 [type, intensity, x,y,z, r,g,b].
    lights: [8]f32 = .{ 0, 3, -0.39801488, -0.69652603, -0.59702231, 1, 1, 1 },

    // GPU-resource registry for context-restore replay (cap 32; 16 worst case).
    registry: gl.Registry(32) = .{},
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
//   one-time create OR replay: 2×createBuffer + ≤4 PBR + 1 depth shader +
//     1 shadow map + 5 createTexture + 3 createTextureEx ≈ 420 B
//   per-frame worst case (every submesh a distinct variant): depth pass 220 +
//     beginFrame 28 + 8×160 + endFrame 4 ≈ 1532 B. Total ≈ 1952. Round to 4096.
var cmd_buf: [4096]u8 = undefined;

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

/// Stable shader handle per PBR variant: pbr→1, pbr|nm→2, pbr|em→3, pbr|nm|em→4.
fn shaderHandleFor(variant: u32) u32 {
    return switch (variant) {
        variant_pbr => 1,
        variant_pbr | variant_nm => 2,
        variant_pbr | variant_em => 3,
        variant_pbr | variant_nm | variant_em => 4,
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
        else => unreachable,
    }
}

fn emitShader(inst: *Inst, enc: *gl.Encoder, comptime variant: u32) void {
    const handle = shaderHandleFor(variant); // handle keyed on the bare variant (1..4)
    // Every PBR program receives the directional shadow map (P9 slice 3).
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

// ── hydrate ──────────────────────────────────────────────────────────────────

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

            inst.lights = .{
                0, // type = directional
                p.light_intensity,
                p.light_dir_x,
                p.light_dir_y,
                p.light_dir_z,
                1, 1, 1, // white
            };

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
            sub.emissive[0],   sub.emissive[1],   sub.emissive[2],        0,
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
/// union of submesh world AABBs). Call after `scene.updateWorld()`.
fn lightSpaceMatrix(inst: *const Inst, a: *const gl.vmesh.Reader) gl.math.Mat4 {
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
    const dir = Vec3.normalize(Vec3.init(inst.lights[2], inst.lights[3], inst.lights[4]));
    const up = if (@abs(dir.y) > 0.99) Vec3.init(0, 0, 1) else Vec3.init(0, 1, 0);
    const dist = radius * 3.0;
    const eye = Vec3.sub(center, Vec3.scale(dir, dist));
    const view = gl.math.Mat4.lookAt(eye, center, up);
    const ext = radius * 1.2;
    const proj = gl.math.Mat4.ortho(-ext, ext, -ext, ext, dist - radius * 1.5, dist + radius * 1.5);
    return proj.mul(view);
}

// ── frame ─────────────────────────────────────────────────────────────────────

export fn glscene_frame(dt_ms: f32, width: u32, height: u32) u32 {
    const inst = current orelse return 0;

    // autoRotate spins the camera at a constant rate, bypassing damping.
    if (!reduced_motion and inst.auto_rotate != 0)
        inst.orbit.yaw += inst.auto_rotate * (dt_ms / 1000.0);

    // Consume accumulated pointer/wheel input, then zero the accumulator.
    inst.orbit.tick(dt_ms, inst.input);
    inst.input = .{};

    const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(@max(height, 1)));
    const proj = gl.math.Mat4.perspective(fov_y, aspect, 0.1, 100.0);
    const view = inst.orbit.viewMatrix(up_vec);
    const eye = inst.orbit.eye();
    inst.camera_pos = .{ eye.x, eye.y, eye.z };

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

        // ── shadow depth pass (P9 slice 3) — render scene depth from the light.
        // clipFix is identity on WebGL2 (path unchanged) and the [−1,1]→[0,1] z
        // remap on WebGPU (gl.math ortho is GL-convention; the receiver's WGSL
        // shadowFactor uses ndc.z directly).
        const light_vp = clipFix().mul(lightSpaceMatrix(inst, a));
        inst.light_vp_mat = light_vp.m;
        enc.beginShadowPass(shadow_handle, depth_shader, shadow_size);
        {
            var sd: u32 = 0;
            while (sd < a.submesh_count) : (sd += 1) {
                if (sd >= max_submesh) break;
                const sub = a.submesh(sd);
                inst.depth_mvps[sd] = light_vp.mul(inst.scene.world[sd + 1]).m;
                enc.drawDepth(vbuf, ibuf, sub.index_byte_off, sub.index_count, @intCast(@intFromPtr(&inst.depth_mvps[sd])));
            }
        }
        enc.endShadowPass(width, height);

        enc.beginFrame(.{ 0.05, 0.06, 0.09, 1.0 }, width, height);

        const pv = clipFix().mul(proj).mul(view);
        // World-space frustum planes for this frame's camera (P9 slice 2).
        const planes = gl.cull.frustumPlanes(pv);
        // Sentinel 0 is never a valid variant (variant_pbr always set).
        var last_variant: u32 = 0;
        var s: u32 = 0;
        while (s < a.submesh_count) : (s += 1) {
            if (s >= max_submesh) break;
            // Cull before the variant/pipeline block (lazy SET_PIPELINE keeps the
            // wire stream-order rule intact for the first DRAWN submesh).
            const wbox = gl.cull.worldAabb(inst.submesh_aabb[s], inst.scene.world[s + 1]);
            if (!gl.cull.aabbInFrustum(planes, wbox)) continue;
            const sub = a.submesh(s);
            const v = a.submeshVariant(s);
            if (v != last_variant) {
                enc.setPipeline(shaderHandleFor(v), gl.command.state_depth_test | gl.command.state_cull_back);
                enc.setLights(1, @intCast(@intFromPtr(&inst.lights)));
                enc.bindIbl(irr_handle, spec_handle, lut_handle, env.spec_mip_count);
                enc.bindShadowMap(gl.command.tex_slot_shadow, shadow_handle, @intCast(@intFromPtr(&inst.light_vp_mat)));
                last_variant = v;
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
        enc.endFrame();
    } else {
        // Assets still loading / failed: clear-only frame.
        enc.beginFrame(.{ 0.05, 0.06, 0.09, 1.0 }, width, height);
        enc.endFrame();
    }
    _ = enc.finish();
    return @intCast(@intFromPtr(&cmd_buf));
}

/// One-time GPU resource upload, mirrored into `inst.registry` for restore replay.
fn sendResources(inst: *Inst, enc: *gl.Encoder, a: *const gl.vmesh.Reader, env: *const gl.venv.Reader) void {
    enc.createBuffer(vbuf, .vertex, @intCast(@intFromPtr(a.vertices.ptr)), @intCast(a.vertices.len));
    inst.registry.recordBuffer(vbuf, .vertex, @intCast(@intFromPtr(a.vertices.ptr)), @intCast(a.vertices.len));
    enc.createBuffer(ibuf, .index, @intCast(@intFromPtr(a.indices.ptr)), @intCast(a.indices.len));
    inst.registry.recordBuffer(ibuf, .index, @intCast(@intFromPtr(a.indices.ptr)), @intCast(a.indices.len));

    // Create + record only the distinct shader variants the mesh actually uses.
    var shader_seen: [5]bool = .{ false, false, false, false, false };
    var sv: u32 = 0;
    while (sv < a.submesh_count) : (sv += 1) {
        if (sv >= max_submesh) break;
        const variant = a.submeshVariant(sv);
        const handle = shaderHandleFor(variant);
        if (shader_seen[handle]) continue;
        shader_seen[handle] = true;
        createShaderForVariant(inst, enc, variant);
    }

    // Shadow-pass resources (P9 slice 3): the depth-only shader + depth target.
    emitDepthShader(inst, enc);
    enc.createShadowMap(shadow_handle, shadow_size);
    inst.registry.recordShadowMap(shadow_handle, shadow_size);

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
