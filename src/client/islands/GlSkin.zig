//! verve.gl skinning slice 1 — drives the /gl-skin canvas.
//!
//! A dedicated, single-instance chunk that renders a GPU-skinned rigged bar
//! (`skinbar.vmesh`, stride-56 skinned vertices + a 3-joint skeleton) deformed
//! by a FIXED bent pose: the mid joint carries a constant rotation, so the upper
//! half of the bar visibly bends. Animation (time-varying pose) is slice 2.
//!
//! Backend-detect mirrors GlScene: `gl_webgpu_available()` selects the WGSL
//! skinned shader + `gl_start_gpu`, else the GLSL skinned shader + `gl_start`.
//! The bone palette is recomputed each frame and pushed via `set_bones`; the
//! skinned PBR program (`variant_pbr | variant_skinned`) skins each vertex.
//!
//! STRUCTURE mirrors GlSceneWebgpu: send-once create block guarded by a flag;
//! STABLE module statics whose addresses the draw record carries (the bridge
//! dereferences them AFTER the frame fn returns, so they must outlive the call).

const verve = @import("verve");
const gl = verve.gl;

extern "verve" fn gl_start(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;
extern "verve" fn gl_start_gpu(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;
extern "verve" fn gl_webgpu_available() i32;
extern "verve" fn gl_load(url_ptr: [*]const u8, url_len: u32, cb_ptr: [*]const u8, cb_len: u32) void;

// ── Statics ───────────────────────────────────────────────────────────────────

const max_bones: u32 = 64;

var canvas_handle: ?i32 = null;
var use_webgpu: bool = false;
var resources_sent: bool = false;
var yaw: f32 = 0;
// Resolved once the vmesh bytes land (gl_load → glskin_vmesh_ready). Holds slices
// into the page asset region, valid for this single-instance chunk's lifetime.
var asset: ?gl.vmesh.Reader = null;

// STABLE statics — the wire records their addresses; read after the frame returns.
var mvp: [16]f32 = undefined;
var model_mat: [16]f32 = undefined;
var normal9: [9]f32 = undefined;
var camera_pos: [3]f32 = .{ 4, 2.2, 5.5 };
// Material: baseColor.rgba, [metallic, roughness, occlusion, normalScale],
// emissive.rgb, pad. Matte dielectric so the direct-light shading reads the bend.
var material: [12]f32 = .{ 1, 1, 1, 1, 0, 0.6, 1, 1, 0, 0, 0, 0 };
// One directional light: [type(0=dir), intensity, dir.xyz, color.rgb].
var light: [8]f32 = .{ 0, 3, -0.4, -0.7, -0.5, 1, 1, 1 };

// Bone palette (skinMat per joint) pushed via set_bones each frame, + the joint
// world-matrix scratch used to compose it. STABLE: drawn-after-return.
var bones: [max_bones * 16]f32 = [_]f32{0} ** (max_bones * 16);
var world_mats: [max_bones]gl.math.Mat4 = undefined;

// 2×2 sRGB base-color checker (amber / brown) so the UV texturing is visible.
const base_rgba = [_]u8{
    235, 170, 70, 255, 150, 90,  30, 255,
    150, 90,  30, 255, 235, 170, 70, 255,
};
// 1×1 neutral textures for the MR + occlusion slots (factors dominate).
const mr_rgba = [_]u8{ 255, 255, 255, 255 };
const occ_rgba = [_]u8{ 255, 255, 255, 255 };

var cmd_buf: [1024]u8 = undefined;

const vbuf_handle: u32 = 1;
const ibuf_handle: u32 = 2;
const shader_handle: u32 = 1;
const base_tex: u32 = 1;
const mr_tex: u32 = 2;
const occ_tex: u32 = 3;
const frame_export = "glskin_frame";
const vmesh_ready_export = "glskin_vmesh_ready";
const vmesh_url = "/gl/skinbar.vmesh";

// Constant bend applied at the mid joint (rad about +Z) — the fixed pose.
const bend_angle: f32 = 0.7;

// ── hydrate ─────────────────────────────────────────────────────────────────

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;

    resources_sent = false;
    asset = null;
    yaw = 0;
    use_webgpu = gl_webgpu_available() != 0;
    canvas_handle = verve.queryRef(@as([]const u8, "glskin-canvas"));

    if (canvas_handle) |h| {
        if (use_webgpu)
            gl_start_gpu(h, frame_export.ptr, frame_export.len)
        else
            gl_start(h, frame_export.ptr, frame_export.len);
    }
    // Fetch the skinned mesh; resources upload once the bytes land.
    gl_load(vmesh_url.ptr, vmesh_url.len, vmesh_ready_export.ptr, vmesh_ready_export.len);
}

// ── asset-ready callback ──────────────────────────────────────────────────────

export fn glskin_vmesh_ready(ptr: u32, len: u32) void {
    if (ptr == 0) return; // fetch failed → poster stays
    const bytes = @as([*]const u8, @ptrFromInt(@as(usize, ptr)))[0..len];
    asset = gl.vmesh.Reader.init(bytes) catch null;
}

// ── bone palette ──────────────────────────────────────────────────────────────

/// Recompute the bone palette for the fixed bent pose: per joint
/// `world = parent_world · local` (mid joint's local carries the bend), then
/// `bone = world · inverse_bind`. Joints are stored parent-before-child, so the
/// parent world matrix is always ready.
fn updateBones(a: *const gl.vmesh.Reader) void {
    const jc = @min(a.jointCount(), max_bones);
    const bend = gl.math.Mat4.fromTrs(
        gl.math.Vec3.init(0, 0, 0),
        gl.math.Quat.fromAxisAngle(gl.math.Vec3.init(0, 0, 1), bend_angle),
        gl.math.Vec3.init(1, 1, 1),
    );
    var j: u32 = 0;
    while (j < jc) : (j += 1) {
        const joint = a.joint(j);
        var local = gl.math.Mat4{ .m = joint.bind_local };
        if (j == 1) local = local.mul(bend); // bend at the mid joint
        const w = if (joint.parent < 0)
            local
        else
            world_mats[@intCast(joint.parent)].mul(local);
        world_mats[j] = w;
        const bone = w.mul(gl.math.Mat4{ .m = joint.inverse_bind });
        @memcpy(bones[j * 16 ..][0..16], &bone.m);
    }
}

// ── frame export ──────────────────────────────────────────────────────────────

export fn glskin_frame(dt_ms: f32, width: u32, height: u32) u32 {
    const a = if (asset) |*r| r else return 0; // no mesh yet → nothing to draw
    yaw += dt_ms * 0.0006; // slow orbit so the 3D bend reads from all sides

    const aspect = @as(f32, @floatFromInt(width)) /
        @as(f32, @floatFromInt(@max(height, 1)));
    const proj = gl.math.Mat4.perspective(1.0, aspect, 0.1, 100.0);
    const view = gl.math.Mat4.lookAt(
        gl.math.Vec3.init(camera_pos[0], camera_pos[1], camera_pos[2]),
        gl.math.Vec3.init(0, 1.3, 0),
        gl.math.Vec3.init(0, 1, 0),
    );
    const model = gl.math.Mat4.fromTrs(
        gl.math.Vec3.init(0, 0, 0),
        gl.math.Quat.fromAxisAngle(gl.math.Vec3.init(0, 1, 0), yaw),
        gl.math.Vec3.init(1, 1, 1),
    );
    mvp = proj.mul(view).mul(model).m;
    model_mat = model.m;
    normal9 = gl.math.normalMatrix(model);

    updateBones(a);

    var enc = gl.Encoder.init(&cmd_buf);
    if (!resources_sent) {
        resources_sent = true;
        enc.createBuffer(vbuf_handle, .vertex, @intCast(@intFromPtr(a.vertices.ptr)), @intCast(a.vertices.len));
        enc.createBuffer(ibuf_handle, .index, @intCast(@intFromPtr(a.indices.ptr)), @intCast(a.indices.len));

        const variant = gl.command.variant_pbr | gl.command.variant_skinned;
        if (use_webgpu) {
            const w = gl.command.wgslPbr(variant);
            enc.createShader(shader_handle, variant, @intCast(@intFromPtr(w.ptr)), @intCast(w.len), 0, 0);
        } else {
            const vs = gl.command.pbrVertexSrc(variant);
            const fs = gl.command.pbrFragmentSrc(variant);
            enc.createShader(shader_handle, variant, @intCast(@intFromPtr(vs.ptr)), @intCast(vs.len), @intCast(@intFromPtr(fs.ptr)), @intCast(fs.len));
        }
        enc.createTextureSrgb(base_tex, 2, 2, @intCast(@intFromPtr(&base_rgba)), @intCast(base_rgba.len));
        enc.createTexture(mr_tex, 1, 1, @intCast(@intFromPtr(&mr_rgba)), @intCast(mr_rgba.len));
        enc.createTexture(occ_tex, 1, 1, @intCast(@intFromPtr(&occ_rgba)), @intCast(occ_rgba.len));
    }

    enc.beginFrame(.{ 0.05, 0.06, 0.09, 1.0 }, width, height);
    enc.setPipeline(shader_handle, gl.command.state_depth_test | gl.command.state_cull_back);
    enc.setLights(1, @intCast(@intFromPtr(&light)));
    enc.setBones(@min(a.jointCount(), max_bones), @intCast(@intFromPtr(&bones)));
    enc.bindTexture(0, base_tex);
    enc.bindTexture(1, mr_tex);
    enc.bindTexture(gl.command.tex_slot_occlusion, occ_tex);
    enc.drawPbr(
        vbuf_handle,
        ibuf_handle,
        0,
        @intCast(a.indices.len / 2),
        @intCast(@intFromPtr(&mvp)),
        @intCast(@intFromPtr(&model_mat)),
        @intCast(@intFromPtr(&normal9)),
        @intCast(@intFromPtr(&material)),
        @intCast(@intFromPtr(&camera_pos)),
    );
    enc.endFrame();
    _ = enc.finish();
    return @intCast(@intFromPtr(&cmd_buf));
}
