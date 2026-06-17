//! FarmScene island chunk — wind farm 3D scene with orbit camera and
//! continuous rotor spin. Single-instance, no IBL, no shadow map.
//!
//! Scene graph: root "model" (node 0) → submesh nodes (node s+1, all children
//! of root). Submesh ordering: ground=0, turbine0..3=1..4, rotor0..3=5..8.
//!
//! Rotor spin: the gltf parser BAKES each node's world transform into vertex
//! positions. Rotor blade vertices are authored hub-local (hub at origin), but
//! after baking the world matrix T(tx,0,0)·T(0,6,0.3) their positions are
//! stored at world offset (tx, 6, 0.3). A plain scene-node rotation would
//! rotate those pre-offset vertices about the world origin (wrong — they'd
//! orbit). Instead, each rotor's model matrix is built as:
//!   T(hub) · Rz(theta) · T(-hub)
//! which translates the baked vertices back to the local origin, rotates, then
//! returns them to the hub — so blades spin in place at their tower top.

const verve = @import("verve");
const gl = verve.gl;

extern "verve" fn gl_start(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;
extern "verve" fn gl_start_gpu(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;
extern "verve" fn gl_webgpu_available() i32;
extern "verve" fn gl_load(url_ptr: [*]const u8, url_len: u32, cb_ptr: [*]const u8, cb_len: u32) void;

// ── Tuning ────────────────────────────────────────────────────────────────────

const drag_sens: f32 = 0.01;
const zoom_sens: f32 = 0.005;
const fov_y: f32 = 1.0;
const spin_rate: f32 = 1.2; // rotor0 rotationZ rad/s
const vmesh_url = "/gl/windfarm.vmesh";

// Hub world positions for rotor0..3 (baked by the gltf parser into blade verts).
// turbine X positions: -12, -4, +4, +12; nacelle Y=6.0, Z=0.3.
// Used to build T(hub)·Rz·T(-hub) pivot matrices (see file-level comment).
const rotor_hub = [4]gl.math.Vec3{
    gl.math.Vec3.init(-12, 6.0, 0.3),
    gl.math.Vec3.init(-4, 6.0, 0.3),
    gl.math.Vec3.init(4, 6.0, 0.3),
    gl.math.Vec3.init(12, 6.0, 0.3),
};
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

// ── hydrate ───────────────────────────────────────────────────────────────────

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;

    verve.assetReset();
    use_webgpu = gl_webgpu_available() != 0;
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
        scene_built = true;
    }
}

// ── pointer / wheel ───────────────────────────────────────────────────────────

export fn farmscene_pointerdown() void {
    if (verve.eventButton() != 0) return;
    dragging = true;
    last_x = verve.eventCoordX();
    last_y = verve.eventCoordY();
    verve.eventCapturePointer();
}

export fn farmscene_pointermove() void {
    if (!dragging) return;
    const x = verve.eventCoordX();
    const y = verve.eventCoordY();
    const dx: f32 = @floatCast(x - last_x);
    const dy: f32 = @floatCast(y - last_y);
    orbit_input.dyaw -= dx * drag_sens;
    orbit_input.dpitch -= dy * drag_sens;
    last_x = x;
    last_y = y;
}

export fn farmscene_pointerup() void {
    dragging = false;
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
            // Rotor submeshes are indices 4..7 (rotor0..3). Their blade vertices
            // were baked by the gltf parser to world positions (tx, 6, 0.3) + hub-local
            // offset. A plain scene rotation would spin them about the world origin.
            // Build T(hub)·Rz(theta)·T(-hub) so rotation pivots at the hub.
            const world_s: gl.math.Mat4 = blk: {
                if (scene_built and s >= 4 and s <= 7) {
                    const ri = s - 4; // rotor index 0..3
                    const hub = rotor_hub[ri];
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
