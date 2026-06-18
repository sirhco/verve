//! FarmScene island chunk — wind farm 3D scene with orbit camera and
//! continuous rotor spin. Single-instance, no IBL, no shadow map.
//!
//! Scene graph: root "model" (node 0) → submesh nodes (node s+1, all children
//! of root). Submesh ordering: ground=0, turbine0..3=1..4, rotor0..3=5..8.
//!
//! Rotor spin: the gltf parser BAKES each node's world transform into vertex
//! positions. Rotor blade vertices are authored hub-local (hub at origin), but
//! after baking the world matrix the positions are stored at the world offset
//! of the hub. A plain scene-node rotation would rotate those pre-offset
//! vertices about the world origin (wrong — they'd orbit). Instead, each
//! rotor's model matrix is built as:
//!   T(pivot) · Rz(theta) · T(-pivot)
//! where pivot = AABB center of that rotor submesh's baked vertices (derived
//! once from the vmesh data; no hardcoded positions). This translates the
//! baked vertices back to the local origin, rotates, then returns them — so
//! blades spin in place centred on their tower top.

const std = @import("std");
const verve = @import("verve");
const gl = verve.gl;
const anim = verve.anim;

extern "verve" fn gl_start(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;
extern "verve" fn gl_start_gpu(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;
extern "verve" fn gl_webgpu_available() i32;
extern "verve" fn gl_load(url_ptr: [*]const u8, url_len: u32, cb_ptr: [*]const u8, cb_len: u32) void;
// onPickExport: dispatch a bubbling DOM CustomEvent(name, {detail:{name}}) from
// the element behind `ref_handle` (the canvas). The page <script> in
// components.zig listens for "mc-select" and forwards the id into the Dashboard
// island. No-op if the handle is stale.
extern "verve" fn gl_emit_event(ref_handle: i32, name_ptr: [*]const u8, name_len: u32, detail_ptr: [*]const u8, detail_len: u32) void;

// Cross-island selection: the DOM CustomEvent name the page glue listens for.
const select_event = "mc-select";

// ── Tuning ────────────────────────────────────────────────────────────────────

const drag_sens: f32 = 0.01;
const zoom_sens: f32 = 0.005;
const fov_y: f32 = 1.0;
const spin_rate: f32 = 1.2; // rotor0 rotationZ rad/s
const vmesh_url = "/gl/windfarm.vmesh";

// Pivot points for rotor0..3 (submesh indices 5..8). Derived once from the
// AABB center of each rotor submesh's baked vertex positions (see
// computeRotorPivots). No hardcoded positions — the actual baked geometry
// determines the hub location exactly.
var rotor_pivots: [4]gl.math.Vec3 = [_]gl.math.Vec3{gl.math.Vec3.init(0, 0, 0)} ** 4;
var pivots_computed: bool = false;
const frame_export = "farmscene_frame";
const vmesh_ready_export = "farmscene_vmesh_ready";

const up_vec = gl.math.Vec3.init(0, 1, 0);
const z_axis = gl.math.Vec3.init(0, 0, 1);

// ── GPU handles ───────────────────────────────────────────────────────────────

const vbuf: u32 = 1;
const ibuf: u32 = 2;
const shader_handle: u32 = 1; // single variant_pbr shader
const max_submesh: usize = 10;

// ── Statics ───────────────────────────────────────────────────────────────────

var canvas_handle: ?i32 = null;
var use_webgpu: bool = false;
var resources_sent: bool = false;
var asset: ?gl.vmesh.Reader = null;
var scene_built: bool = false;
var elapsed_s: f32 = 0;

// Orbit camera — framed to show all 4 turbines (farm spans X ∈ [-14,14], Y ∈ [0,6]).
// target=(0,3,0) centers on nacelle height; distance=38 fits the ~28-unit wide farm
// comfortably inside fov_y=1.0; yaw=0.6 gives a front-right perspective; pitch=-0.35
// looks slightly down from above. max_distance raised to allow user zoom-out.
var orbit: gl.orbit.Orbit = .{
    .target = .{ .x = 0, .y = 3, .z = 0 },
    .distance = 38,
    .max_distance = 80,
    .yaw = 0.6,
    .pitch = -0.35,
};
var orbit_input: gl.orbit.OrbitInput = .{};
var dragging: bool = false;
var last_x: f64 = 0;
var last_y: f64 = 0;

// ── pick + camera-tween ─────────────────────────────────────────────────────
// Turbine world X positions (mirror fixture.zig windFarmGlb turbine_x). Used to
// reframe the orbit target onto the selected turbine.
const turbine_x = [4]f32{ -12, -4, 4, 12 };

// A queued click NDC awaiting a BVH raycast on the next frame (camera state is
// only coherent inside the frame fn). down_x/down_y detect drag-vs-click.
var pick_pending: bool = false;
var pick_ndc_x: f32 = 0;
var pick_ndc_y: f32 = 0;
var down_x: f64 = 0;
var down_y: f64 = 0;
var down_moved: bool = false;

// Camera-tween setter slot + live handle (killed before each new select).
var setter_slot: u32 = 0;
var cam_anim: ?verve.AnimHandle = null;
var reduced_motion: bool = false;

// Drag detected click as a real click only when the pointer barely moved.
const click_slop: f64 = 4;

fn bytesAsF32(b: []const u8) []const f32 {
    const ptr: [*]const f32 = @ptrCast(@alignCast(b.ptr));
    return ptr[0 .. b.len / 4];
}

fn bytesAsU16(b: []const u8) []const u16 {
    const ptr: [*]const u16 = @ptrCast(@alignCast(b.ptr));
    return ptr[0 .. b.len / 2];
}

/// Convert client (cx, cy) → NDC ([-1,1]², y up) via the canvas rect.
fn clientToNdc(h: i32, cx: f64, cy: f64, nx: *f32, ny: *f32) void {
    const r = verve.refRect(h);
    nx.* = @floatCast(if (r.w == 0) 0 else (cx - r.x) / r.w * 2.0 - 1.0);
    ny.* = @floatCast(if (r.h == 0) 0 else 1.0 - (cy - r.y) / r.h * 2.0);
}

/// Whole-mesh BVH raycast → owning submesh index (geometry is world-baked, so
/// the ray stays in world space; rotors spin via a separate matrix but the
/// static tower under each rotor still picks the turbine). Null on miss.
fn raycastSubmesh(a: *const gl.vmesh.Reader, aspect: f32, nx: f32, ny: f32) ?u32 {
    if (a.bvh_node_count == 0) return null;
    const r = gl.ray.rayFromCamera(orbit.eye(), orbit.target, up_vec, fov_y, aspect, nx, ny);
    const nodes = gl.bvh.nodesFromBytes(a.bvh_nodes);
    const tri_perm = gl.bvh.triPermFromBytes(a.tri_perm);
    const verts = bytesAsF32(a.vertices);
    const idx = bytesAsU16(a.indices);
    const hit = gl.bvh.walk(nodes, tri_perm, verts, 12, idx, r) orelse return null;
    // Map the hit triangle's first index element to its owning submesh.
    const first: u32 = hit.tri_index * 3;
    var s: u32 = 0;
    while (s < a.submesh_count) : (s += 1) {
        const sub = a.submesh(s);
        const start = sub.index_byte_off / 2;
        if (first >= start and first < start + sub.index_count) return s;
    }
    return null;
}

/// Submesh name "turbineN"/"rotorN" → turbine id N. Ground / unnamed → null.
fn submeshTurbineId(nm: []const u8) ?u8 {
    const tail: ?[]const u8 =
        if (std.mem.startsWith(u8, nm, "turbine")) nm["turbine".len..] else if (std.mem.startsWith(u8, nm, "rotor")) nm["rotor".len..] else null;
    const t = tail orelse return null;
    if (t.len != 1 or t[0] < '0' or t[0] > '3') return null;
    return t[0] - '0';
}

/// FarmScene is single-instance: the anim engine's gl-setter writes camera
/// yaw/pitch/distance straight into `orbit`. The next frame's `orbit.tick`
/// leaves them put (zero input → zero velocity).
fn camSetter(target_id: u32, value: f64) void {
    const d = gl.anim_target.decode(target_id) orelse return;
    if (d.kind != .camera) return;
    const v: f32 = @floatCast(value);
    switch (@as(gl.anim_target.CameraField, @enumFromInt(d.field))) {
        .yaw => orbit.yaw = v,
        .pitch => orbit.pitch = v,
        .distance => orbit.distance = v,
    }
}

/// Ease the camera to frame turbine `id`: snap the orbit target onto that
/// turbine, then tween yaw/pitch/distance to a close, slightly-angled framing.
fn frameTurbine(id: u8) void {
    orbit.target = .{ .x = turbine_x[id], .y = 4, .z = 0 };
    if (cam_anim) |h| h.kill();
    cam_anim = null;
    if (setter_slot == 0) return;

    const yaw_id = gl.anim_target.encode(.camera, 0, @intFromEnum(gl.anim_target.CameraField.yaw));
    const pitch_id = gl.anim_target.encode(.camera, 0, @intFromEnum(gl.anim_target.CameraField.pitch));
    const dist_id = gl.anim_target.encode(.camera, 0, @intFromEnum(gl.anim_target.CameraField.distance));

    if (reduced_motion) {
        // Snap (no tween) under reduced motion.
        orbit.yaw = 0.5;
        orbit.pitch = -0.2;
        orbit.distance = 16;
        return;
    }

    const mark = verve.chunkArenaMark();
    defer verve.chunkArenaReset(mark);
    const arena = verve.chunkArena();

    const t = anim.to(arena, null)
        .glTargetRange(yaw_id, setter_slot, orbit.yaw, 0.5)
        .glTargetRange(pitch_id, setter_slot, orbit.pitch, -0.2)
        .glTargetRange(dist_id, setter_slot, orbit.distance, 16)
        .duration(0.8)
        .ease(.out_cubic);
    cam_anim = verve.animPlay(t);
}

// Scene graph (root + up to max_submesh submesh nodes)
var scene: gl.scene.Scene(11) = .{};
var node_rot: [max_submesh][3]f32 = [_][3]f32{.{ 0, 0, 0 }} ** max_submesh;
var node_rot_applied: [max_submesh][3]f32 = [_][3]f32{.{ 0, 0, 0 }} ** max_submesh;

// STABLE per-submesh statics — addresses recorded in the command stream.
var mvps: [max_submesh][16]f32 = undefined;
var model_mats: [max_submesh][16]f32 = undefined;
var normal9s: [max_submesh][9]f32 = undefined;
var mats: [max_submesh][12]f32 = undefined;
var camera_pos: [3]f32 = .{ 0, 5, 20 };

// White 1×1 fallback textures (uploaded once on first frame with asset).
const base_tex: u32 = 3;
const white_rgba: [4]u8 = .{ 255, 255, 255, 255 };
const mr_rgba: [4]u8 = .{ 0, 128, 255, 255 }; // R=0 metallic, G=128 roughness=0.5

// Single directional light: type=0 (directional), intensity, dir_x, dir_y, dir_z, r, g, b
var light: [8]f32 = .{ 0, 3.0, -0.4, -0.7, -0.6, 1, 1, 1 };

var cmd_buf: [2048]u8 = undefined;

// ── pivot helpers ─────────────────────────────────────────────────────────────

/// Compute the AABB center of a rotor submesh's baked vertex positions.
/// Walk every index in the submesh's index range, read pos.xyz from the
/// stride-48 vertex buffer (pos = first 3 × f32 at offset 0), track
/// min/max → center = (min+max)/2. Runs once after asset load.
fn submeshAabbCenter(a: *const gl.vmesh.Reader, sub_idx: u32) gl.math.Vec3 {
    const sub = a.submesh(sub_idx);
    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var min_z: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    var max_z: f32 = -std.math.floatMax(f32);
    const stride: usize = a.vertexStride();
    var k: u32 = 0;
    while (k < sub.index_count) : (k += 1) {
        const idx_off: usize = @as(usize, sub.index_byte_off) + @as(usize, k) * 2;
        const vi: usize = std.mem.readInt(u16, a.indices[idx_off..][0..2], .little);
        const voff: usize = vi * stride;
        const px: f32 = @bitCast(std.mem.readInt(u32, a.vertices[voff + 0 ..][0..4], .little));
        const py: f32 = @bitCast(std.mem.readInt(u32, a.vertices[voff + 4 ..][0..4], .little));
        const pz: f32 = @bitCast(std.mem.readInt(u32, a.vertices[voff + 8 ..][0..4], .little));
        if (px < min_x) min_x = px;
        if (py < min_y) min_y = py;
        if (pz < min_z) min_z = pz;
        if (px > max_x) max_x = px;
        if (py > max_y) max_y = py;
        if (pz > max_z) max_z = pz;
    }
    return gl.math.Vec3.init(
        (min_x + max_x) * 0.5,
        (min_y + max_y) * 0.5,
        (min_z + max_z) * 0.5,
    );
}

/// Compute and cache pivots for rotor submeshes 5..8.
fn computeRotorPivots(a: *const gl.vmesh.Reader) void {
    if (pivots_computed) return;
    var ri: u32 = 0;
    while (ri < 4) : (ri += 1) {
        rotor_pivots[ri] = submeshAabbCenter(a, 5 + ri);
    }
    pivots_computed = true;
}

// ── hydrate ───────────────────────────────────────────────────────────────────

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;

    verve.assetReset();
    use_webgpu = gl_webgpu_available() != 0;
    reduced_motion = verve.matchMedia("(prefers-reduced-motion: reduce)");
    // Register the camera-tween gl-setter once (slot 0 == failure).
    setter_slot = verve.animGlSetter(&camSetter);
    canvas_handle = verve.queryRef(@as([]const u8, "farmscene-canvas"));

    if (canvas_handle) |h| {
        if (use_webgpu)
            gl_start_gpu(h, frame_export.ptr, frame_export.len)
        else
            gl_start(h, frame_export.ptr, frame_export.len);
    }
    gl_load(vmesh_url.ptr, vmesh_url.len, vmesh_ready_export.ptr, vmesh_ready_export.len);
}

// ── asset-ready ───────────────────────────────────────────────────────────────

export fn farmscene_vmesh_ready(ptr: u32, len: u32) void {
    if (ptr == 0) return;
    const bytes = @as([*]const u8, @ptrFromInt(@as(usize, ptr)))[0..len];
    asset = gl.vmesh.Reader.init(bytes) catch null;
    pivots_computed = false;
    if (asset) |*a| {
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
        node_rot = [_][3]f32{.{ 0, 0, 0 }} ** max_submesh;
        node_rot_applied = [_][3]f32{.{ 0, 0, 0 }} ** max_submesh;
        // Derive rotor pivot points from baked geometry before first frame.
        if (a.submesh_count >= 9) computeRotorPivots(a);
        scene_built = true;
    }
}

// ── pointer / wheel ───────────────────────────────────────────────────────────

export fn farmscene_pointerdown() void {
    if (verve.eventButton() != 0) return;
    dragging = true;
    last_x = verve.eventCoordX();
    last_y = verve.eventCoordY();
    down_x = last_x;
    down_y = last_y;
    down_moved = false;
    verve.eventCapturePointer();
}

export fn farmscene_pointermove() void {
    if (!dragging) return;
    const x = verve.eventCoordX();
    const y = verve.eventCoordY();
    if (@abs(x - down_x) > click_slop or @abs(y - down_y) > click_slop) down_moved = true;
    const dx: f32 = @floatCast(x - last_x);
    const dy: f32 = @floatCast(y - last_y);
    orbit_input.dyaw -= dx * drag_sens;
    orbit_input.dpitch -= dy * drag_sens;
    last_x = x;
    last_y = y;
}

export fn farmscene_pointerup() void {
    dragging = false;
    // A near-stationary press is a pick (a real drag rotates the camera).
    if (!down_moved) {
        if (canvas_handle) |h| {
            clientToNdc(h, verve.eventCoordX(), verve.eventCoordY(), &pick_ndc_x, &pick_ndc_y);
            pick_pending = true;
        }
    }
}

export fn farmscene_wheel() void {
    orbit_input.dzoom += @as(f32, @floatCast(verve.eventDeltaY())) * zoom_sens;
}

// ── frame ─────────────────────────────────────────────────────────────────────

fn nodeQuat(r: [3]f32) gl.math.Quat {
    const qx = gl.math.Quat.fromAxisAngle(gl.math.Vec3.init(1, 0, 0), r[0]);
    const qy = gl.math.Quat.fromAxisAngle(gl.math.Vec3.init(0, 1, 0), r[1]);
    const qz = gl.math.Quat.fromAxisAngle(z_axis, r[2]);
    return qz.mul(qy).mul(qx);
}

export fn farmscene_frame(dt_ms: f32, width: u32, height: u32) u32 {
    // Advance rotor spin regardless of asset state (no-op until scene_built).
    elapsed_s += dt_ms * 0.001;

    orbit.tick(dt_ms, orbit_input);
    orbit_input = .{};

    const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(@max(height, 1)));
    const proj = gl.math.Mat4.perspective(fov_y, aspect, 0.1, 200.0);
    const view = orbit.viewMatrix(up_vec);
    const eye = orbit.eye();
    camera_pos = .{ eye.x, eye.y, eye.z };

    // Advance rotor0..3 (submeshes 5..8) rotationZ.
    // Ordering: ground=0, turbine0..3=1..4, rotor0..3=5..8.
    if (scene_built) {
        node_rot[5][2] = elapsed_s * spin_rate;
        node_rot[6][2] = elapsed_s * spin_rate;
        node_rot[7][2] = elapsed_s * spin_rate;
        node_rot[8][2] = elapsed_s * spin_rate;

        // Sync node rotations into scene graph.
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

    if (asset != null) {
        const a = &asset.?;

        // Process a queued pick: BVH raycast → submesh → turbine id → dispatch
        // the cross-island selection event + ease the camera onto the turbine.
        if (pick_pending) {
            pick_pending = false;
            if (raycastSubmesh(a, aspect, pick_ndc_x, pick_ndc_y)) |s| {
                if (submeshTurbineId(a.name(s))) |id| {
                    var idbuf: [2]u8 = undefined;
                    const id_str = std.fmt.bufPrint(&idbuf, "{d}", .{id}) catch "0";
                    if (canvas_handle) |h|
                        gl_emit_event(h, select_event.ptr, select_event.len, id_str.ptr, @intCast(id_str.len));
                    frameTurbine(id);
                }
            }
        }

        if (!resources_sent) {
            resources_sent = true;
            enc.createBuffer(vbuf, .vertex, @intCast(@intFromPtr(a.vertices.ptr)), @intCast(a.vertices.len));
            enc.createBuffer(ibuf, .index, @intCast(@intFromPtr(a.indices.ptr)), @intCast(a.indices.len));

            const variant = gl.command.variant_pbr;
            if (use_webgpu) {
                const w = gl.command.wgslPbr(variant);
                enc.createShader(shader_handle, variant, @intCast(@intFromPtr(w.ptr)), @intCast(w.len), 0, 0);
            } else {
                const vs = gl.command.pbrVertexSrc(variant);
                const fs = gl.command.pbrFragmentSrc(variant);
                enc.createShader(shader_handle, variant, @intCast(@intFromPtr(vs.ptr)), @intCast(vs.len), @intCast(@intFromPtr(fs.ptr)), @intCast(fs.len));
            }
            enc.createTextureSrgb(base_tex, 1, 1, @intCast(@intFromPtr(&white_rgba)), white_rgba.len);
            enc.createTexture(base_tex + 1, 1, 1, @intCast(@intFromPtr(&mr_rgba)), mr_rgba.len);
        }

        enc.beginFrame(.{ 0.05, 0.07, 0.12, 1.0 }, width, height);
        enc.setPipeline(shader_handle, gl.command.state_depth_test | gl.command.state_cull_back);
        enc.setLights(1, @intCast(@intFromPtr(&light)));

        const pv = proj.mul(view);
        const one3 = gl.math.Vec3.init(1, 1, 1);
        const zero3 = gl.math.Vec3.init(0, 0, 0);
        var s: u32 = 0;
        while (s < a.submesh_count) : (s += 1) {
            if (s >= max_submesh) break;
            const sub = a.submesh(s);
            // Identify rotor submeshes by name (starts with "rotor") so the
            // correct set is always rotor0..3 = submeshes 5..8 regardless of
            // ordering. Fall back to index range 5..8 when the vmesh carries no
            // names. Their blade vertices were baked by the gltf parser to world
            // positions. A plain scene rotation would spin them about the world
            // origin. Build T(pivot)·Rz(theta)·T(-pivot) so rotation pivots at
            // the hub, where pivot is derived from the AABB center of the baked
            // vertex positions.
            const nm = a.name(s);
            const is_rotor = if (nm.len > 0)
                std.mem.startsWith(u8, nm, "rotor")
            else
                (s >= 5 and s <= 8);
            const world_s: gl.math.Mat4 = blk: {
                if (scene_built and is_rotor) {
                    const ri = s - 5; // rotor index 0..3
                    const hub = rotor_pivots[ri];
                    const neg_hub = gl.math.Vec3.init(-hub.x, -hub.y, -hub.z);
                    const theta = elapsed_s * spin_rate;
                    const qz = gl.math.Quat.fromAxisAngle(z_axis, theta);
                    const t_hub = gl.math.Mat4.fromTrs(hub, gl.math.Quat.identity, one3);
                    const r_mat = gl.math.Mat4.fromTrs(zero3, qz, one3);
                    const t_neg = gl.math.Mat4.fromTrs(neg_hub, gl.math.Quat.identity, one3);
                    break :blk t_hub.mul(r_mat).mul(t_neg);
                }
                break :blk if (scene_built) scene.world[s + 1] else gl.math.Mat4.identity;
            };
            model_mats[s] = world_s.m;
            normal9s[s] = gl.math.normalMatrix(world_s);
            mvps[s] = pv.mul(world_s).m;
            enc.bindTexture(0, base_tex);
            enc.bindTexture(1, base_tex + 1);
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
        // Asset loading: clear-only frame. NOT 0 — that unmounts the loop.
        enc.beginFrame(.{ 0.05, 0.07, 0.12, 1.0 }, width, height);
        enc.endFrame();
    }

    _ = enc.finish();
    return @intCast(@intFromPtr(&cmd_buf));
}
