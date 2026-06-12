//! verve.gl interactive scene chunk — orbit camera + ray-picking + autoRotate,
//! with Registry-driven GPU-resource replay across WebGL context restore.
//!
//! WHY ONE STATEFUL CHUNK PER PAGE: per-island wasm chunks share the main
//! client's linear memory and each links its static data starting at the same
//! base (0x1000). Two stateful gl chunks on one page overlap their data
//! segments (the same hazard documented in GlDemo.zig). The framework invariant
//! (build.zig) allows at most ONE stateful chunk per page, so GlScene must live
//! alone on its route (/gl-scene, Task 13) — never co-located with GlDemo.
//!
//! Multi-instance: singleton statics, same documented choice as GlDemo. The
//! per-instance vid (root_id) scopes ref lookups; a second scene on one page
//! would need namespacing.
//!
//! ── DESIGN CHOICES (see Task 12 spec) ───────────────────────────────────────
//!  • Scene graph (P6): node 0 = root "model", carrying model_yaw as a +Y
//!    rotation; node s+1 = submesh s (named from the vmesh), animatable via
//!    node:<Name>.rotationX/Y/Z — Euler radians composed Qz·Qy·Qx (X applied
//!    first). Each draw reads its own world matrix: the per-submesh mvps/
//!    model_mats/normal9s pools keep every drawPbr pointer at a stable
//!    distinct slot (stream aliasing — JS walks the stream AFTER the frame fn
//!    returns, same reason as the `mats` pool). setRotation is only called
//!    when a value actually changed (applied-mirrors) so updateWorld's
//!    clean-subtree no-op stays effective. The CAMERA also orbits; mvp =
//!    proj · view · world. Pick/hover (Task 7) raycasts via inverse node
//!    transforms, three paths: (1) fast — no rotation anywhere, one walk with
//!    the raw ray; (2) root-only — model_yaw set but all node_rot zero, one
//!    walk with the ray moved by invert(world[0]); (3) slow — any per-node
//!    rotation, per-submesh walk with invert(world[s+1]), keeping hits owned
//!    by that submesh, global nearest t wins. All transforms are rigid
//!    (scale ≡ 1) so t stays comparable across spaces.
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
//!    `onPick(name, id)` registered, restoring that island's vid — a real
//!    chunk→event-dispatch path, no gap.
//!  • Hover: implemented (same ray path, throttled to one raycast per frame
//!    while NOT dragging). Stamps data-gl-hover on the canvas.
//!
//! ── Context-restore (Registry replay) ───────────────────────────────────────
//! Unlike GlDemo (whose restore re-runs its create block by clearing a flag),
//! GlScene's create block runs exactly ONCE at startup (`resources_sent`).
//! Every create* is mirrored into `registry` as it's issued. On restore the
//! bridge calls `glscene_frame_restore` (Task 9 "<frame>_restore" convention),
//! which sets `needs_replay`; the next frame emits `registry.replay(&enc)` to
//! re-upload all GPU resources WITHOUT re-recording, then resumes normal
//! frames. Asset Reader bytes live in the page-scoped asset region, so the
//! recorded pointers stay valid for the page lifetime.

const std = @import("std");
const verve = @import("verve");
const gl = verve.gl;
const anim = verve.anim;

extern "verve" fn gl_start(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;
extern "verve" fn gl_load(url_ptr: [*]const u8, url_len: u32, cb_ptr: [*]const u8, cb_len: u32) void;

// ── Tuning ───────────────────────────────────────────────────────────────────

const drag_sens: f32 = 0.01; // rad per client px
const zoom_sens: f32 = 0.005; // distance per wheel deltaY unit
const fov_y: f32 = 1.0; // vertical fov (rad) — MUST match the proj below

const vmesh_ready_export = "glscene_vmesh_ready";
const env_ready_export = "glscene_env_ready";
const frame_export = "glscene_frame";

// GPU resource handles (kept distinct from IBL handles 16/17/18).
const vbuf: u32 = 1;
const ibuf: u32 = 2;
const shader: u32 = 1;
const irr_handle: u32 = 16;
const spec_handle: u32 = 17;
const lut_handle: u32 = 18;

// Comptime PBR variant — full Cook-Torrance + IBL + tangent-space normals +
// emissive (parity with GlDemo's textured model path).
const pbr_variant = gl.command.variant_pbr | gl.command.variant_normal_map | gl.command.variant_emissive;

const max_submesh = 8; // material-pool cap

// ── Props copies (decoded from SSR data-props; copied to statics before the
//    chunk arena that held the decode result is reset) ────────────────────────

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
};

// URL buffers — asset paths copied out of the arena. 128 matches the asset-URL
// envelope GlDemo uses for its compile-time literals ("/gl/demo.vmesh" etc.).
var src_buf: [128]u8 = undefined;
var src_len: usize = 0;
var env_buf: [128]u8 = undefined;
var env_len: usize = 0;

const max_picks = 4; // mirror of gl_scene.zig max_picks
const max_name = 64; // per-name fixed storage
var pick_names: [max_picks][max_name]u8 = undefined;
var pick_name_lens: [max_picks]usize = undefined;
var pick_ids: [max_picks]u32 = undefined;
var pick_count: usize = 0;

var auto_rotate: f32 = 0;
var scrub_enabled: bool = false; // Task 9 scroll-scrub timeline; wired there
var model_yaw: f32 = 0; // model Y-rotation (radians); set via glscene_anim_set

// ── scrub timeline (Task 9) ───────────────────────────────────────────────────
// Translated gl-setter slot (0 = not yet registered). Registered ONCE, the
// first time we have a chance (hydrate sets scrub flag; we register lazily in
// vmesh_ready alongside the build so a re-hydrate re-registers cleanly).
var anim_setter_slot: u32 = 0;
// Build the scroll-scrubbed timeline exactly once (the asset Reader must be
// resolvable for material:<Name> path lookup).
var scrub_built: bool = false;
// Live timeline handle id (0 = none / build skipped).
var scrub_anim_id: u32 = 0;

// ── Camera + input ───────────────────────────────────────────────────────────

var orbit: gl.Orbit = .{};
var input: gl.OrbitInput = .{};

// ── Drag / pick interaction state ────────────────────────────────────────────

var dragging: bool = false;
var last_x: f64 = 0;
var last_y: f64 = 0;

var pick_pending: bool = false;
var pick_ndc_x: f32 = 0;
var pick_ndc_y: f32 = 0;

var hover_have: bool = false; // a hover position is queued for this frame
var hover_ndc_x: f32 = 0;
var hover_ndc_y: f32 = 0;
var hover_name_hash: u32 = 0; // last stamped hover name's hash (dedup stamps)
const no_hover_hash: u32 = 0xFFFF_FFFF;

// ── Assets ───────────────────────────────────────────────────────────────────

var asset: ?gl.vmesh.Reader = null;
var env_reader: ?gl.venv.Reader = null;

// ── Render statics ───────────────────────────────────────────────────────────

var camera_pos: [3]f32 = .{ 0, 0, 4 }; // updated each frame to orbit.eye()

// ── Scene graph (P6) ─────────────────────────────────────────────────────────
// Node 0 = root "model" (model_yaw about +Y); node s+1 = submesh s, named with
// the submesh's vmesh name. Layout frozen — Tasks 7/8 rely on it.
var scene: gl.Scene(max_submesh + 1) = .{};
var scene_built: bool = false;

// Per-submesh node Euler rotations (X,Y,Z radians; X applied first), written
// by the anim setter, composed into quats per frame. The *_applied mirrors let
// the frame skip setRotation when nothing changed — setRotation always marks
// dirty, which would defeat updateWorld's clean-subtree optimization.
var node_rot: [max_submesh][3]f32 = [_][3]f32{.{ 0, 0, 0 }} ** max_submesh;
var node_rot_applied: [max_submesh][3]f32 = [_][3]f32{.{ 0, 0, 0 }} ** max_submesh;
var model_yaw_applied: f32 = 0;

// Per-submesh draw pools — like `mats`, each drawPbr must point at a STABLE
// distinct slot because the JS interpreter dereferences the pointers when it
// walks the stream AFTER the frame fn returns (stream aliasing).
var mvps: [max_submesh][16]f32 = undefined;
var model_mats: [max_submesh][16]f32 = undefined;
var normal9s: [max_submesh][9]f32 = undefined;

// Per-submesh material block pool (12 f32 each) — each drawPbr points at its own
// stable slot so the JS interpreter reads the right material when walking the
// stream (same aliasing reason as GlDemo).
// Initialized ONCE from vmesh defaults in buildScene (at asset load); anim
// setters own all subsequent mutations (metallic [4], roughness [5], emissive
// [8..10]). Rebuilt on re-hydrate/asset reload via buildScene.
var mats: [max_submesh][12]f32 = undefined;

// Single directional light from props: 8 f32 [type, intensity, x,y,z, r,g,b].
var lights: [8]f32 = .{ 0, 3, -0.39801488, -0.69652603, -0.59702231, 1, 1, 1 };

var reduced_motion: bool = false;

// GPU-resource registry for context-restore replay. Cap 32:
//   2 buffers + 1 shader + up to 5 material textures + 3 IBL textures = 11
//   worst case; 32 leaves generous headroom (no overflow).
var registry: gl.Registry(32) = .{};
var resources_sent: bool = false;
var needs_replay: bool = false;

// cmd_buf sizing (N = max_submesh = 8). Record = 4-byte header + payload.
//   one-time create OR replay (same set):
//     2×createBuffer(20) + createShader(28) + 5×createTexture(24)
//     + 3×createTextureEx(36) = 40 + 28 + 120 + 108 = 296
//   per-frame:
//     header(4) + beginFrame(28) + setPipeline(12) + setLights(12)
//     + bindIbl(20) + N×(5×bindTexture(12) + drawPbr(40)) = 8×100 = 800
//     + endFrame(4) = 880
//   worst case (create/replay + frame on one tick) = 296 + 880 = 1176.
//   Round up to 4096 (matches GlDemo).
var cmd_buf: [4096]u8 = undefined;

// ── helpers ──────────────────────────────────────────────────────────────────

const up_vec = gl.math.Vec3.init(0, 1, 0);

/// Compose per-node Euler radians (X,Y,Z) into a quaternion, applying X first:
/// q = Qz · Qy · Qx (quat mul applies the right-hand factor first).
fn nodeQuat(r: [3]f32) gl.math.Quat {
    const qx = gl.math.Quat.fromAxisAngle(gl.math.Vec3.init(1, 0, 0), r[0]);
    const qy = gl.math.Quat.fromAxisAngle(gl.math.Vec3.init(0, 1, 0), r[1]);
    const qz = gl.math.Quat.fromAxisAngle(gl.math.Vec3.init(0, 0, 1), r[2]);
    return gl.math.Quat.mul(gl.math.Quat.mul(qz, qy), qx);
}

/// vmesh texture index → wire handle (slot t gets handle t+1). Negatives clamp
/// to handle 0 (never created) instead of trapping (parity with GlDemo).
fn texHandle(i: i32) u32 {
    return if (i >= 0) @intCast(i + 1) else 0;
}

/// Map an ORIGINAL triangle index to its owning submesh index by scanning the
/// submesh index ranges. A triangle's first index sits at element position
/// `tri*3` in the u16 index array; submesh s owns elements
/// [index_byte_off/2, index_byte_off/2 + index_count). Returns null if no
/// submesh contains it (malformed mesh).
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
/// +x right, +y UP (NDC convention) — the browser's y grows downward, so y is
/// flipped. Mirrors VizGraphInteractive's client→svg conversion, retargeted to
/// canvas NDC.
fn clientToNdc(canvas: i32, cx: f64, cy: f64, ndc_x: *f32, ndc_y: *f32) void {
    const r = verve.refRect(canvas);
    const nx: f64 = if (r.w == 0) 0 else (cx - r.x) / r.w * 2.0 - 1.0;
    const ny: f64 = if (r.h == 0) 0 else 1.0 - (cy - r.y) / r.h * 2.0;
    ndc_x.* = @floatCast(nx);
    ndc_y.* = @floatCast(ny);
}

/// Canvas ref handle, cached at hydrate. queryRef vid-scopes through the
/// main runtime's `current_island_id`, which is only set inside event/hydrate
/// dispatch — the gl rAF loop calls `glscene_frame` directly with NO island
/// scope, so a frame-context queryRef resolves the unsuffixed name and finds
/// nothing (silently dropping data-gl-pick/hover stamps; caught live in P5).
/// Resolving once in hydrate (scoped) and reusing the handle everywhere makes
/// every context safe and skips the per-stamp DOM query.
var canvas_handle: ?i32 = null;

fn canvasRef() ?i32 {
    return canvas_handle;
}

// ── hydrate ──────────────────────────────────────────────────────────────────

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = root_id; // ref lookups auto-scope; no per-instance state beyond singletons

    // This island owns the page's gl asset lifetime. Free any prior assets
    // before re-fetching — the Reader slices below point into the asset region.
    verve.assetReset();

    // Reset interaction + GPU state for a fresh hydrate.
    asset = null;
    env_reader = null;
    resources_sent = false;
    needs_replay = false;
    registry.reset();
    dragging = false;
    pick_pending = false;
    hover_have = false;
    hover_name_hash = no_hover_hash;
    input = .{};
    pick_count = 0;
    model_yaw = 0;
    model_yaw_applied = 0;
    scene_built = false;
    scene = .{};
    node_rot = [_][3]f32{.{ 0, 0, 0 }} ** max_submesh;
    node_rot_applied = [_][3]f32{.{ 0, 0, 0 }} ** max_submesh;
    anim_setter_slot = 0;
    canvas_handle = null;
    scrub_built = false;
    scrub_anim_id = 0;

    // Defaults so a missing/garbage props blob still yields a usable scene.
    src_len = 0;
    env_len = 0;
    auto_rotate = 0;
    scrub_enabled = false;
    orbit = .{};

    if (props_len != 0) {
        const bytes = @as([*]const u8, @ptrFromInt(@as(usize, props_ptr)))[0..props_len];
        const mark = verve.chunkArenaMark();
        defer verve.chunkArenaReset(mark);
        if (verve.decodeProps(Props, bytes, verve.chunkArena())) |p| {
            // Copy every slice out of the arena BEFORE it's reset.
            src_len = @min(p.src.len, src_buf.len);
            @memcpy(src_buf[0..src_len], p.src[0..src_len]);
            env_len = @min(p.env.len, env_buf.len);
            @memcpy(env_buf[0..env_len], p.env[0..env_len]);

            orbit = .{
                .distance = p.orbit_distance,
                .pitch = p.orbit_pitch,
                .yaw = p.orbit_yaw,
            };
            auto_rotate = p.auto_rotate;
            scrub_enabled = p.scrub;

            lights = .{
                0, // type = directional
                p.light_intensity,
                p.light_dir_x,
                p.light_dir_y,
                p.light_dir_z,
                1, 1, 1, // white
            };

            // Deep-copy pick names/ids into fixed statics (arena dies on reset).
            pick_count = @min(@min(p.pick_names.len, p.pick_event_ids.len), max_picks);
            var i: usize = 0;
            while (i < pick_count) : (i += 1) {
                const nm = p.pick_names[i];
                const ln = @min(nm.len, max_name);
                @memcpy(pick_names[i][0..ln], nm[0..ln]);
                pick_name_lens[i] = ln;
                pick_ids[i] = p.pick_event_ids[i];
            }
        } else |_| {}
    }

    // Cache reduced-motion once (matchMedia is a host round-trip).
    reduced_motion = verve.matchMedia("(prefers-reduced-motion: reduce)");

    // Resolve the canvas ref ONCE while hydrate runs inside island scope —
    // frame-context lookups would silently miss (see canvas_handle doc).
    canvas_handle = verve.queryRef(@as([]const u8, "glscene-canvas"));

    // Kick the asset fetches (geometry + prefiltered IBL).
    if (src_len != 0)
        gl_load(&src_buf, @intCast(src_len), vmesh_ready_export.ptr, vmesh_ready_export.len);
    if (env_len != 0)
        gl_load(&env_buf, @intCast(env_len), env_ready_export.ptr, env_ready_export.len);

    if (canvasRef()) |h|
        gl_start(h, frame_export.ptr, frame_export.len);
}

// ── asset-ready callbacks ─────────────────────────────────────────────────────

export fn glscene_vmesh_ready(ptr: u32, len: u32) void {
    if (ptr == 0) return; // fetch failed → stay on clear-only frames
    const bytes = @as([*]const u8, @ptrFromInt(@as(usize, ptr)))[0..len];
    asset = gl.vmesh.Reader.init(bytes) catch null;
    if (asset) |*a| buildScene(a);
    // With the Reader resolvable, build the scroll-scrubbed timeline once.
    if (scrub_enabled and !scrub_built) buildScrubTimeline();
}

/// (Re)build the scene graph for a freshly-read vmesh: root "model" at node 0,
/// one child per submesh at node s+1 (named from the vmesh; capped at
/// max_submesh). The applied-mirrors are reset to match the fresh scene's
/// identity rotations; any pre-asset anim writes (nonzero model_yaw/node_rot)
/// then differ from their mirror and get applied on the next frame.
///
/// Also initializes the mats pool from vmesh defaults. Doing it here (once, at
/// asset load) instead of per-frame means anim setters writing metallic [4],
/// roughness [5], and emissive [8..10] are never clobbered before draw.
fn buildScene(a: *const gl.vmesh.Reader) void {
    scene = .{};
    _ = scene.addNode(-1, "model");
    const n: u32 = @min(a.submesh_count, max_submesh);
    var s: u32 = 0;
    while (s < n) : (s += 1) {
        _ = scene.addNode(0, a.name(s));
        const sub = a.submesh(s);
        mats[s] = .{
            sub.base_color[0], sub.base_color[1], sub.base_color[2],      sub.base_color[3],
            sub.metallic,      sub.roughness,     sub.occlusion_strength, sub.normal_scale,
            sub.emissive[0],   sub.emissive[1],   sub.emissive[2],        0,
        };
    }
    model_yaw_applied = 0;
    node_rot_applied = [_][3]f32{.{ 0, 0, 0 }} ** max_submesh;
    scene_built = true;
}

export fn glscene_env_ready(ptr: u32, len: u32) void {
    if (ptr == 0) return;
    const bytes = @as([*]const u8, @ptrFromInt(@as(usize, ptr)))[0..len];
    env_reader = gl.venv.Reader.init(bytes) catch null;
}

// ── pointer / wheel / click handlers ──────────────────────────────────────────

export fn glscene_pointerdown() void {
    if (verve.eventButton() != 0) return; // primary button only
    dragging = true;
    last_x = verve.eventCoordX();
    last_y = verve.eventCoordY();
    verve.eventCapturePointer();
}

export fn glscene_pointermove() void {
    const x = verve.eventCoordX();
    const y = verve.eventCoordY();
    if (dragging) {
        const dx: f32 = @floatCast(x - last_x);
        const dy: f32 = @floatCast(y - last_y);
        // See drag-sign note up top: dragging right swings the camera left.
        input.dyaw -= dx * drag_sens;
        input.dpitch -= dy * drag_sens;
        last_x = x;
        last_y = y;
    } else {
        // Queue a hover raycast for the next frame (one raycast/frame max).
        if (canvasRef()) |h| {
            clientToNdc(h, x, y, &hover_ndc_x, &hover_ndc_y);
            hover_have = true;
        }
    }
}

export fn glscene_pointerup() void {
    dragging = false;
}

export fn glscene_wheel() void {
    verve.eventPreventDefault();
    input.dzoom += @as(f32, @floatCast(verve.eventDeltaY())) * zoom_sens;
}

export fn glscene_click() void {
    if (canvasRef()) |h| {
        clientToNdc(h, verve.eventCoordX(), verve.eventCoordY(), &pick_ndc_x, &pick_ndc_y);
        pick_pending = true;
    }
}

// ── context-restore hook ──────────────────────────────────────────────────────

export fn glscene_frame_restore() void {
    // The GL objects died with the old context. Re-emit every recorded create*
    // on the next frame via registry.replay (the records persist). The bridge
    // restores the poster itself.
    needs_replay = true;
}

// ── pick raycast ──────────────────────────────────────────────────────────────

/// True when every per-submesh node Euler rotation is zero — the common
/// no-anim case that unlocks the cheap single-walk raycast paths.
fn nodeRotIdentity() bool {
    for (node_rot) |r| {
        if (r[0] != 0 or r[1] != 0 or r[2] != 0) return false;
    }
    return true;
}

/// Build a pick ray for `(ndc_x, ndc_y)` and walk the mesh BVH. Returns the
/// picked submesh index, or null on miss / no BVH data.
///
/// The walk always intersects MESH-LOCAL geometry (vmesh positions); only the
/// ray moves between spaces, via inverse node world matrices. glscene_frame
/// runs scene.updateWorld() BEFORE pick/hover processing, so scene.world[] is
/// this frame's. Three paths:
///   1. Fast — no rotation anywhere: one walk with the raw world-space ray.
///   2. Root-only — model_yaw != 0, all node_rot zero: one walk with the ray
///      moved into model space by invert(world[0]).
///   3. Slow — any node_rot nonzero: per submesh s, move the ray into node
///      s+1's space, walk, keep hits owned by submesh s, global nearest t.
/// t comparability: every ray derives from the same world-space ray under
/// rigid transforms (scale ≡ 1 in GlScene) with no renormalization, so
/// nearest-t comparison across submeshes is valid.
/// Cost: ≤ (max_submesh+1) inversions per raycast, raycasts ≤ 1/frame.
fn raycastSubmesh(a: *const gl.vmesh.Reader, aspect: f32, ndc_x: f32, ndc_y: f32) ?u32 {
    if (a.bvh_node_count == 0) return null;
    const r = gl.ray.rayFromCamera(orbit.eye(), orbit.target, up_vec, fov_y, aspect, ndc_x, ndc_y);
    const nodes = gl.bvh.nodesFromBytes(a.bvh_nodes);
    const tri_perm = gl.bvh.triPermFromBytes(a.tri_perm);
    // Vertices: vmesh stride 48 bytes = 12 f32; position xyz at offset 0.
    const verts_f32 = bytesAsF32(a.vertices);
    const indices_u16 = bytesAsU16(a.indices);

    const rot_identity = nodeRotIdentity();
    // Guard: scene_built is invariant-true whenever `asset` != null (buildScene
    // runs in the same callback that sets it), but keep the world[] reads safe —
    // an unbuilt scene degrades to the untransformed fast path.
    if (!scene_built or (model_yaw == 0 and rot_identity)) {
        const hit = gl.bvh.walk(nodes, tri_perm, verts_f32, 12, indices_u16, r) orelse return null;
        return submeshOfTri(a, hit.tri_index);
    }
    if (rot_identity) {
        // Root-only: one walk with the ray in model (root) space.
        const tr = gl.ray.transformRay(r, gl.math.invert(scene.world[0]));
        const hit = gl.bvh.walk(nodes, tri_perm, verts_f32, 12, indices_u16, tr) orelse return null;
        return submeshOfTri(a, hit.tri_index);
    }
    // Slow path: per-submesh inverse transform; the walk covers the WHOLE mesh
    // so only hits owned by submesh s are valid in node s+1's space.
    var best_t: f32 = std.math.inf(f32);
    var best_s: ?u32 = null;
    const n: u32 = @min(a.submesh_count, max_submesh);
    var s: u32 = 0;
    while (s < n) : (s += 1) {
        const tr = gl.ray.transformRay(r, gl.math.invert(scene.world[s + 1]));
        const hit = gl.bvh.walk(nodes, tri_perm, verts_f32, 12, indices_u16, tr) orelse continue;
        const owner = submeshOfTri(a, hit.tri_index) orelse continue;
        if (owner != s) continue;
        if (hit.t < best_t) {
            best_t = hit.t;
            best_s = s;
        }
    }
    return best_s;
}

fn bytesAsF32(b: []const u8) []const f32 {
    const ptr: [*]const f32 = @ptrCast(@alignCast(b.ptr));
    return ptr[0 .. b.len / 4];
}

fn bytesAsU16(b: []const u8) []const u16 {
    const ptr: [*]const u16 = @ptrCast(@alignCast(b.ptr));
    return ptr[0 .. b.len / 2];
}

/// Stamp `data-<attr>` on the canvas with submesh `s`'s name.
fn stampName(attr: []const u8, a: *const gl.vmesh.Reader, s: u32) void {
    if (canvasRef()) |h| verve.setRefAttr(h, attr, a.name(s));
}

// ── frame ─────────────────────────────────────────────────────────────────────

export fn glscene_frame(dt_ms: f32, width: u32, height: u32) u32 {
    // autoRotate spins the camera at a constant rate, bypassing damping.
    if (!reduced_motion and auto_rotate != 0)
        orbit.yaw += auto_rotate * (dt_ms / 1000.0);

    // Consume accumulated pointer/wheel input, then zero the accumulator.
    orbit.tick(dt_ms, input);
    input = .{};

    const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(@max(height, 1)));
    const proj = gl.math.Mat4.perspective(fov_y, aspect, 0.1, 100.0);
    const view = orbit.viewMatrix(up_vec);
    const eye = orbit.eye();
    camera_pos = .{ eye.x, eye.y, eye.z };

    // Sync animated rotations into the scene graph. setRotation is skipped for
    // unchanged values (applied-mirrors) so updateWorld's clean-subtree no-op
    // keeps paying off; setRotation always marks dirty otherwise.
    if (scene_built) {
        if (model_yaw != model_yaw_applied) {
            scene.setRotation(0, gl.math.Quat.fromAxisAngle(up_vec, model_yaw));
            model_yaw_applied = model_yaw;
        }
        var n: u32 = 0;
        while (n + 1 < scene.count) : (n += 1) {
            const r = node_rot[n];
            const ra = node_rot_applied[n];
            if (r[0] != ra[0] or r[1] != ra[1] or r[2] != ra[2]) {
                scene.setRotation(n + 1, nodeQuat(r));
                node_rot_applied[n] = r;
            }
        }
        scene.updateWorld();
    }

    var enc = gl.Encoder.init(&cmd_buf);

    if (asset != null and env_reader != null) {
        const a = &asset.?;
        const env = &env_reader.?;

        if (!resources_sent) {
            resources_sent = true;
            sendResources(&enc, a, env);
        } else if (needs_replay) {
            needs_replay = false;
            registry.replay(&enc);
        }

        // Process a queued pick (camera state is coherent this frame).
        if (pick_pending) {
            pick_pending = false;
            if (raycastSubmesh(a, aspect, pick_ndc_x, pick_ndc_y)) |s| {
                stampName("data-gl-pick", a, s);
                dispatchPick(a, s);
            }
        }

        // At most one hover raycast per frame, and only when not dragging.
        if (hover_have and !dragging) {
            hover_have = false;
            if (raycastSubmesh(a, aspect, hover_ndc_x, hover_ndc_y)) |s| {
                const hash = gl.vmesh.Reader.nameHash(a.name(s));
                if (hash != hover_name_hash) {
                    hover_name_hash = hash;
                    stampName("data-gl-hover", a, s);
                }
            } else if (hover_name_hash != no_hover_hash) {
                hover_name_hash = no_hover_hash;
                if (canvasRef()) |h| verve.setRefAttr(h, "data-gl-hover", "");
            }
        }

        enc.beginFrame(.{ 0.05, 0.06, 0.09, 1.0 }, width, height);
        enc.setPipeline(shader, gl.command.state_depth_test | gl.command.state_cull_back);
        enc.setLights(1, @intCast(@intFromPtr(&lights)));
        enc.bindIbl(irr_handle, spec_handle, lut_handle, env.spec_mip_count);

        // pv hoisted out of the loop; per-draw matrices come from the scene
        // graph (scene_built is invariant-true whenever `asset` is non-null —
        // buildScene runs in the same callback that sets `asset`).
        const pv = proj.mul(view);
        var s: u32 = 0;
        while (s < a.submesh_count) : (s += 1) {
            if (s >= max_submesh) break;
            const sub = a.submesh(s);
            // mats[s] initialized once in buildScene; anim setters own mutations.
            const world_s = scene.world[s + 1];
            model_mats[s] = world_s.m;
            normal9s[s] = gl.math.normalMatrix(world_s);
            mvps[s] = pv.mul(world_s).m;
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
                @intCast(@intFromPtr(&mvps[s])),
                @intCast(@intFromPtr(&model_mats[s])),
                @intCast(@intFromPtr(&normal9s[s])),
                @intCast(@intFromPtr(&mats[s])),
                @intCast(@intFromPtr(&camera_pos)),
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

/// One-time GPU resource upload, mirrored into `registry` for restore replay.
fn sendResources(enc: *gl.Encoder, a: *const gl.vmesh.Reader, env: *const gl.venv.Reader) void {
    enc.createBuffer(vbuf, .vertex, @intCast(@intFromPtr(a.vertices.ptr)), @intCast(a.vertices.len));
    registry.recordBuffer(vbuf, .vertex, @intCast(@intFromPtr(a.vertices.ptr)), @intCast(a.vertices.len));
    enc.createBuffer(ibuf, .index, @intCast(@intFromPtr(a.indices.ptr)), @intCast(a.indices.len));
    registry.recordBuffer(ibuf, .index, @intCast(@intFromPtr(a.indices.ptr)), @intCast(a.indices.len));

    const vs = gl.command.pbrVertexSrc(pbr_variant);
    const fs = gl.command.pbrFragmentSrc(pbr_variant);
    enc.createShader(shader, pbr_variant, @intCast(@intFromPtr(vs.ptr)), @intCast(vs.len), @intCast(@intFromPtr(fs.ptr)), @intCast(fs.len));
    registry.recordShader(shader, pbr_variant, @intCast(@intFromPtr(vs.ptr)), @intCast(vs.len), @intCast(@intFromPtr(fs.ptr)), @intCast(fs.len));

    var t: u32 = 0;
    while (t < a.tex_count) : (t += 1) {
        const tex = a.texture(t);
        enc.createTexture(t + 1, tex.width, tex.height, @intCast(@intFromPtr(tex.rgba.ptr)), @intCast(tex.rgba.len));
        registry.recordTexture(t + 1, tex.width, tex.height, @intCast(@intFromPtr(tex.rgba.ptr)), @intCast(tex.rgba.len));
    }

    enc.createTextureEx(irr_handle, .cube, .rgba16f, env.irr_size, env.irr_size, 1, @intCast(@intFromPtr(env.irradiance.ptr)), @intCast(env.irradiance.len));
    registry.recordTextureEx(irr_handle, .cube, .rgba16f, env.irr_size, env.irr_size, 1, @intCast(@intFromPtr(env.irradiance.ptr)), @intCast(env.irradiance.len));
    enc.createTextureEx(spec_handle, .cube, .rgba16f, env.spec_size, env.spec_size, env.spec_mip_count, @intCast(@intFromPtr(env.specular.ptr)), @intCast(env.specular.len));
    registry.recordTextureEx(spec_handle, .cube, .rgba16f, env.spec_size, env.spec_size, env.spec_mip_count, @intCast(@intFromPtr(env.specular.ptr)), @intCast(env.specular.len));
    enc.createTextureEx(lut_handle, .tex_2d, .rgba16f, env.lut_size, env.lut_size, 1, @intCast(@intFromPtr(env.lut.ptr)), @intCast(env.lut.len));
    registry.recordTextureEx(lut_handle, .tex_2d, .rgba16f, env.lut_size, env.lut_size, 1, @intCast(@intFromPtr(env.lut.ptr)), @intCast(env.lut.len));
}

/// If submesh `s`'s name matches a registered pick name, fire its SSR closure.
fn dispatchPick(a: *const gl.vmesh.Reader, s: u32) void {
    const nm = a.name(s);
    if (nm.len == 0) return;
    var i: usize = 0;
    while (i < pick_count) : (i += 1) {
        const reg = pick_names[i][0..pick_name_lens[i]];
        if (eql(reg, nm) and pick_ids[i] != 0) {
            verve.dispatchEvent(pick_ids[i]);
            return;
        }
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

// ── scrub timeline build (Task 9) ──────────────────────────────────────────────

/// Non-export gl-setter trampoline. `glscene_anim_set` is `pub export fn`
/// (callconv(.c)); `animGlSetter` wants a default-callconv `fn(u32, f64) void`
/// pointer, so we register THIS thin wrapper instead and forward straight to
/// `applyAnimTarget` (the same body the export calls).
fn animSetTrampoline(target_id: u32, value: f64) void {
    applyAnimTarget(target_id, @floatCast(value));
}

/// Build the scroll-scrubbed turntable + roughness-ramp timeline. Runs ONCE,
/// after the vmesh Reader is available (so `material:<Name>` paths resolve).
///
/// Targets (one tween, two @gl range entries):
///   • camera.yaw — turntable: current orbit.yaw → +2π (one full turn).
///   • material:Cube.roughness — ramp 0.045 → 1.0 (skipped if the name is
///     absent in the mesh; the camera still scrubs).
///
/// Gating: a ScrollTrigger on the scroll-section ref ("glscene-scroll-section",
/// added by Task 10). When that ref is absent (page without a section), the
/// build is skipped entirely — `scrub` without a section is a no-op.
fn buildScrubTimeline() void {
    scrub_built = true; // attempt once regardless of outcome

    if (asset == null) return;
    const a = &asset.?;

    // The scroll section is the trigger. No section → no scrub (documented).
    const section = verve.queryRef(@as([]const u8, "glscene-scroll-section")) orelse return;

    // Register the gl-setter once. Pass the non-export trampoline (matches the
    // default-callconv fn pointer animGlSetter expects).
    if (anim_setter_slot == 0)
        anim_setter_slot = verve.animGlSetter(&animSetTrampoline);
    const slot = anim_setter_slot;
    if (slot == 0) return; // setter registration failed → no scrub

    const mark = verve.chunkArenaMark();
    defer verve.chunkArenaReset(mark);
    const arena = verve.chunkArena();

    // Camera yaw turntable: from current yaw → +2π (one full revolution).
    const yaw_id = gl.anim_target.encode(.camera, 0, @intFromEnum(gl.anim_target.CameraField.yaw));
    const yaw_from: f64 = orbit.yaw;
    const yaw_to: f64 = yaw_from + std.math.tau;

    const t = anim.to(arena, null)
        .glTargetRange(yaw_id, slot, yaw_from, yaw_to)
        .duration(1.0) // scrub maps progress over the scroll range; absolute ignored
        .ease(.linear);

    // Optional roughness ramp on the named material — skipped silently when the
    // mesh has no matching name (camera still scrubs).
    if (gl.anim_target.resolvePath(a, "material:Cube.roughness")) |rough_id|
        _ = t.glTargetRange(rough_id, slot, 0.045, 1.0);

    // Scroll trigger: section top hits viewport top (start) through section
    // bottom hits viewport top (end). Smooth scrub (0.4s catch-up); plain scrub
    // (.exact) is the fallback vocabulary if smooth is undesired. Default toggle
    // actions are mandatory under scrub (validate rejects otherwise).
    _ = t.scrollTrigger(.{
        .trigger_handle = section,
        .start = .{ .trigger = .top, .viewport = .top },
        .end = .{ .at = .{ .trigger = .bottom, .viewport = .top } },
        .scrub = .{ .smooth = 0.4 },
    });

    if (verve.animPlay(t)) |h| {
        scrub_anim_id = h.id; // nonzero on success
    } else {
        scrub_anim_id = 0; // build/serialize/zero-match failure → no-op
    }
}

// ── animation setter ─────────────────────────────────────────────────────────

/// Write one tweened engine value. Decodes the target id (gl.anim_target) and
/// stores into the matching static. Unknown/invalid ids are silently ignored.
///
/// Camera writes seek absolute values (scrub semantics) — written directly to
/// orbit.yaw/pitch/distance with pitch/distance clamped to the orbit's own
/// constraints. tick() is NOT called; the next frame integrates normally.
///
/// Material writes go to mats[submesh]: [4] metallic, [5] roughness,
/// [8]/[9]/[10] emissive rgb. Guard: submesh must be < max_submesh AND < the
/// loaded asset's submesh_count (if any).
///
/// Model yaw sets model_yaw directly. Node writes store Euler radians into
/// node_rot[submesh]; the frame composes them into the scene-graph quat.
fn applyAnimTarget(id: u32, value: f32) void {
    const d = gl.anim_target.decode(id) orelse return;
    switch (d.kind) {
        .camera => switch (@as(gl.anim_target.CameraField, @enumFromInt(d.field))) {
            .yaw => orbit.yaw = value,
            .pitch => {
                const lo = orbit.min_pitch;
                const hi = orbit.max_pitch;
                orbit.pitch = if (value < lo) lo else if (value > hi) hi else value;
            },
            .distance => {
                const lo = orbit.min_distance;
                const hi = orbit.max_distance;
                orbit.distance = if (value < lo) lo else if (value > hi) hi else value;
            },
        },
        .material => {
            const s: usize = d.submesh;
            const cap = if (asset) |*a| @as(usize, a.submesh_count) else @as(usize, 0);
            if (s >= max_submesh or s >= cap) return;
            switch (@as(gl.anim_target.MaterialField, @enumFromInt(d.field))) {
                .metallic => mats[s][4] = value,
                .roughness => mats[s][5] = value,
                .emissive_r => mats[s][8] = value,
                .emissive_g => mats[s][9] = value,
                .emissive_b => mats[s][10] = value,
            }
        },
        .model => switch (@as(gl.anim_target.ModelField, @enumFromInt(d.field))) {
            .yaw => model_yaw = value,
        },
        // Node Euler rotation (field 0/1/2 = X/Y/Z; decode validated the range).
        // Pre-asset writes are fine: node_rot is only consumed once the scene is
        // built, and the frame loop only reads slots that exist in the scene.
        .node => {
            if (d.submesh >= max_submesh) return;
            node_rot[d.submesh][d.field] = value;
        },
    }
}

/// Exported entry point called by the animation runtime (island_runtime.animGlSetter).
/// Signature matches fn(u32, f64) void as required by animGlSetter registration.
pub export fn glscene_anim_set(target_id: u32, value: f64) void {
    applyAnimTarget(target_id, @floatCast(value));
}
