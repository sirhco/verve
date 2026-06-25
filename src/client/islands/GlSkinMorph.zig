//! verve.gl combined skinned+morph demo — drives the /gl-skin-morph canvas.
//!
//! Renders a GPU-skinned bar that is ALSO morphed (Bulge target), using
//! `variant_pbr | variant_skinned | variant_morph` — the first slice to
//! exercise the combined shader path in both backends.
//!
//! Each frame:
//!   1. Morph deltas applied to local pos/normal (texelFetch / textureLoad).
//!   2. Skin matrix transforms the morphed locals.
//! This order matches the glTF spec and the combined shader (slice 3).
//!
//! Controls:
//!   glskinmorph_freeze      — toggle auto-orbit (debug)
//!
//! STRUCTURE mirrors GlSkin: send-once create block guarded by a flag;
//! STABLE module statics whose addresses the draw record carries.

const std = @import("std");
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
var morph_tex_sent: bool = false;
var yaw: f32 = 0;
var freeze: bool = false;
var elapsed_s: f32 = 0;

// Resolved once the vmesh bytes land.
var asset: ?gl.vmesh.Reader = null;

// STABLE statics — the wire records their addresses; read after the frame returns.
var mvp: [16]f32 = undefined;
var model_mat: [16]f32 = undefined;
var normal9: [9]f32 = undefined;
var camera_pos: [3]f32 = .{ 2.6, 1.3, 3.4 };
// Material: baseColor.rgba, [metallic, roughness, occlusion, normalScale], emissive.rgb, pad.
var material: [12]f32 = .{ 0.85, 0.85, 1.0, 1.0, 0, 0.45, 1, 1, 0, 0, 0, 0 };
// Two directional lights, 16 f32 each (4 vec4/light, the set_lights wire format):
//   v0 = type/intensity/pos.xy, v1 = pos.z/dir.xyz, v2 = color.rgb/range, v3 = cosIn/cosOut/shadow.
// No IBL is bound on this standalone island, so a key + camera-side fill keep both the lit
// and shadowed faces of the bar readable as it bends + bulges.
const light_count: u32 = 2;
var light: [light_count * 16]f32 = .{
    // key — upper-right-front, warm-white
    0, 5.0, 0, 0, 0, -0.4,  -0.7,  -0.5,  1.0,  0.98, 0.92, 0, 0, 0, 0, 0,
    // fill — from the camera direction (target − camera), cooler, softer
    0, 2.6, 0, 0, 0, -0.59, -0.08, -0.80, 0.85, 0.9,  1.0,  0, 0, 0, 0, 0,
};

// Bone palette (one mat4 per joint).
var bones: [max_bones * 16]f32 = [_]f32{0} ** (max_bones * 16);
var world_mats: [max_bones]gl.math.Mat4 = undefined;

// Morph: one active target (index 0), weight oscillates 0→1→0.
// morph_idx[0] = 0; morph_wt[0] = oscillating weight.
var morph_idx: [1]i32 = .{0};
var morph_wt: [1]f32 = .{0};

// 2×2 sRGB base-color checker (blue-ish so it differs from GlSkin amber).
const base_rgba = [_]u8{
    100, 140, 220, 255, 60,  90,  160, 255,
    60,  90,  160, 255, 100, 140, 220, 255,
};
const mr_rgba = [_]u8{ 255, 255, 255, 255 };
const occ_rgba = [_]u8{ 255, 255, 255, 255 };

// Larger cmd_buf: combined shader is bigger + morph tex + set_morph_weights.
var cmd_buf: [2048]u8 = undefined;

const vbuf_handle: u32 = 1;
const ibuf_handle: u32 = 2;
const shader_handle: u32 = 1;
const base_tex: u32 = 1;
const mr_tex: u32 = 2;
const occ_tex: u32 = 3;
const morph_tex_handle: u32 = 4;
const frame_export = "glskinmorph_frame";
const vmesh_ready_export = "glskinmorph_vmesh_ready";
const vmesh_url = "/gl/skinmorph.vmesh";

// ── hydrate ─────────────────────────────────────────────────────────────────

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;

    resources_sent = false;
    morph_tex_sent = false;
    asset = null;
    yaw = 0;
    freeze = false;
    elapsed_s = 0;
    use_webgpu = gl_webgpu_available() != 0;
    canvas_handle = verve.queryRef(@as([]const u8, "glskinmorph-canvas"));

    if (canvas_handle) |h| {
        if (use_webgpu)
            gl_start_gpu(h, frame_export.ptr, frame_export.len)
        else
            gl_start(h, frame_export.ptr, frame_export.len);
    }
    gl_load(vmesh_url.ptr, vmesh_url.len, vmesh_ready_export.ptr, vmesh_ready_export.len);
}

// ── asset-ready callback ──────────────────────────────────────────────────────

export fn glskinmorph_vmesh_ready(ptr: u32, len: u32) void {
    if (ptr == 0) return;
    const bytes = @as([*]const u8, @ptrFromInt(@as(usize, ptr)))[0..len];
    asset = gl.vmesh.Reader.init(bytes) catch null;
}

// ── controls ─────────────────────────────────────────────────────────────────

export fn glskinmorph_freeze() void {
    freeze = !freeze;
}

// ── bone palette ──────────────────────────────────────────────────────────────

/// Simple 3-joint bind pose (identity for all joints).  The skinmorph vmesh
/// carries a "SkinMorphAnim" that bends jmid, but for the demo we keep it at
/// the static bind pose to let the morph deformation be visually obvious.
/// A nonzero rotation is applied to jmid so BOTH effects are simultaneously
/// visible (skin bends the bar; morph bulges it).
fn updateBones(a: *const gl.vmesh.Reader, t: f32) void {
    const jc = @min(a.jointCount(), max_bones);
    for (0..jc) |j| {
        const joint = a.joint(@intCast(j));
        // Use joint bind_local; animate jmid (index 1) with a slow Z rotation.
        const local: gl.math.Mat4 = blk: {
            var base = gl.math.Mat4{ .m = joint.bind_local };
            if (j == 1) {
                // bend jmid with a slow oscillating Z rotation
                const angle = @sin(t * 0.8) * 0.4;
                const rot = gl.math.Mat4.fromTrs(
                    gl.math.Vec3.init(0, 0, 0),
                    gl.math.Quat.fromAxisAngle(gl.math.Vec3.init(0, 0, 1), angle),
                    gl.math.Vec3.init(1, 1, 1),
                );
                base = rot;
            }
            break :blk base;
        };
        const wm = if (joint.parent < 0)
            local
        else
            world_mats[@intCast(joint.parent)].mul(local);
        world_mats[j] = wm;
        const bone = wm.mul(gl.math.Mat4{ .m = joint.inverse_bind });
        @memcpy(bones[j * 16 ..][0..16], &bone.m);
    }
}

// ── frame ─────────────────────────────────────────────────────────────────────

export fn glskinmorph_frame(dt_ms: f32, width: u32, height: u32) u32 {
    // Mesh loads async; until it lands emit a clear-only frame (NOT 0).
    const a = if (asset) |*r| r else {
        var enc0 = gl.Encoder.init(&cmd_buf);
        enc0.beginFrame(.{ 0.04, 0.05, 0.10, 1.0 }, width, height);
        enc0.endFrame();
        _ = enc0.finish();
        return @intCast(@intFromPtr(&cmd_buf));
    };

    if (!freeze) {
        yaw += dt_ms * 0.0006;
        elapsed_s += dt_ms * 0.001;
    }

    // Morph weight: oscillate 0→1→0 over a 3-second period.
    morph_wt[0] = (@sin(elapsed_s * (std.math.pi * 2.0 / 3.0)) + 1.0) * 0.5;

    const aspect = @as(f32, @floatFromInt(width)) /
        @as(f32, @floatFromInt(@max(height, 1)));
    const proj = gl.math.Mat4.perspective(1.0, aspect, 0.1, 100.0);
    const view = gl.math.Mat4.lookAt(
        gl.math.Vec3.init(camera_pos[0], camera_pos[1], camera_pos[2]),
        gl.math.Vec3.init(0, 0.95, 0),
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

    updateBones(a, elapsed_s);

    var enc = gl.Encoder.init(&cmd_buf);
    if (!resources_sent) {
        resources_sent = true;
        enc.createBuffer(vbuf_handle, .vertex, @intCast(@intFromPtr(a.vertices.ptr)), @intCast(a.vertices.len));
        enc.createBuffer(ibuf_handle, .index, @intCast(@intFromPtr(a.indices.ptr)), @intCast(a.indices.len));

        const variant = gl.command.variant_pbr | gl.command.variant_skinned | gl.command.variant_morph;
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
    if (!morph_tex_sent and a.morphTargetCount() > 0) {
        morph_tex_sent = true;
        const deltas = a.morphDeltas();
        enc.createMorphTex(
            morph_tex_handle,
            a.morphVertexCount(),
            a.morphTargetCount() * 3, // height = target_count * 3 (pos + nrm + tan rows per target; vmesh v14)
            @intCast(@intFromPtr(deltas.ptr)),
            @intCast(deltas.len),
        );
    }

    enc.beginFrame(.{ 0.04, 0.05, 0.10, 1.0 }, width, height);
    enc.setPipeline(shader_handle, gl.command.state_depth_test | gl.command.state_cull_back);
    enc.setLights(light_count, @intCast(@intFromPtr(&light)));
    enc.setBones(@min(a.jointCount(), max_bones), @intCast(@intFromPtr(&bones)));
    // Upload morph weights (count=1, target index 0, weight oscillating).
    enc.setMorphWeights(1, @intCast(@intFromPtr(&morph_idx)), @intCast(@intFromPtr(&morph_wt)));
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
