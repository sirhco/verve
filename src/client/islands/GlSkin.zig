//! verve.gl skinning — drives the /gl-skin canvas.
//!
//! A dedicated, single-instance chunk that renders a GPU-skinned rigged bar
//! (`skinbar.vmesh`, stride-56 skinned vertices + a 3-joint skeleton). Slice 2:
//! the bar plays a looping animation CLIP — each frame samples every joint's
//! baked T/R/S keyframe tracks at `t = elapsed mod duration`, composing local
//! transforms that deform the mesh over time. With no clip it falls back to the
//! static bind pose (slice-1 behavior).
//!
//! Backend-detect mirrors GlScene: `gl_webgpu_available()` selects the WGSL
//! skinned shader + `gl_start_gpu`, else the GLSL skinned shader + `gl_start`.
//! The bone palette is recomputed each frame and pushed via `set_bones`; the
//! skinned PBR program (`variant_pbr | variant_skinned`) skins each vertex.
//!
//! STRUCTURE mirrors GlSceneWebgpu: send-once create block guarded by a flag;
//! STABLE module statics whose addresses the draw record carries (the bridge
//! dereferences them AFTER the frame fn returns, so they must outlive the call).

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
var yaw: f32 = 0;
var elapsed_s: f32 = 0;
// Playback state (slice 3): selected clip, paused, speed multiplier. Mutated by
// the glskin_* control exports (wired to /gl-skin buttons).
var cur_clip: u32 = 0;
var paused: bool = false;
var speed: f32 = 1.0;
// Cross-fade (slice 4): on a clip switch, snapshot the old clip + its looped time
// (FROZEN), and blend old→new pose over `fade_dur` real-time seconds. `pending_clip`
// is set by the control exports and applied in updateBones (which has the Reader).
const fade_dur: f32 = 0.3;
var from_clip: u32 = 0;
var from_time: f32 = 0;
var fade_t: f32 = fade_dur; // start settled (no blend on the first frame)
var pending_clip: i32 = -1;
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

// ── hydrate ─────────────────────────────────────────────────────────────────

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;

    resources_sent = false;
    asset = null;
    yaw = 0;
    elapsed_s = 0;
    cur_clip = 0;
    paused = false;
    speed = 1.0;
    from_clip = 0;
    from_time = 0;
    fade_t = fade_dur;
    pending_clip = -1;
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

/// Last keyframe index whose time <= t (clamped to [0, key_count-1]).
fn lowerKey(a: *const gl.vmesh.Reader, tr: gl.vmesh.TrackInfo, t: f32) u32 {
    if (tr.key_count <= 1) return 0;
    var i: u32 = 0;
    while (i + 1 < tr.key_count and a.animTime(tr, i + 1) <= t) : (i += 1) {}
    return i;
}

/// Sample a vec3 track (translation c=0 / scale c=2) of `clip` at time t.
fn sampleVec3(a: *const gl.vmesh.Reader, clip: u32, j: u32, c: u2, t: f32) gl.math.Vec3 {
    const tr = a.animTrack(clip, j, c);
    const k0 = lowerKey(a, tr, t);
    const v0 = gl.math.Vec3.init(a.animValue(tr, k0, 0), a.animValue(tr, k0, 1), a.animValue(tr, k0, 2));
    if (tr.key_count <= 1 or tr.interp == 1 or k0 + 1 >= tr.key_count) return v0;
    const k1 = k0 + 1;
    const t0 = a.animTime(tr, k0);
    const t1 = a.animTime(tr, k1);
    const f = if (t1 > t0) std.math.clamp((t - t0) / (t1 - t0), 0, 1) else 0;
    const v1 = gl.math.Vec3.init(a.animValue(tr, k1, 0), a.animValue(tr, k1, 1), a.animValue(tr, k1, 2));
    return gl.math.Vec3.init(v0.x + (v1.x - v0.x) * f, v0.y + (v1.y - v0.y) * f, v0.z + (v1.z - v0.z) * f);
}

/// Sample the rotation track (c=1) of `clip` at time t (slerp, or hold for STEP).
fn sampleQuat(a: *const gl.vmesh.Reader, clip: u32, j: u32, t: f32) gl.math.Quat {
    const tr = a.animTrack(clip, j, 1);
    const k0 = lowerKey(a, tr, t);
    const q0 = gl.math.Quat{ .x = a.animValue(tr, k0, 0), .y = a.animValue(tr, k0, 1), .z = a.animValue(tr, k0, 2), .w = a.animValue(tr, k0, 3) };
    if (tr.key_count <= 1 or tr.interp == 1 or k0 + 1 >= tr.key_count) return q0;
    const k1 = k0 + 1;
    const t0 = a.animTime(tr, k0);
    const t1 = a.animTime(tr, k1);
    const f = if (t1 > t0) std.math.clamp((t - t0) / (t1 - t0), 0, 1) else 0;
    const q1 = gl.math.Quat{ .x = a.animValue(tr, k1, 0), .y = a.animValue(tr, k1, 1), .z = a.animValue(tr, k1, 2), .w = a.animValue(tr, k1, 3) };
    return gl.math.Quat.slerp(q0, q1, f);
}

/// Recompute the bone palette. With a clip: sample each joint's T/R/S tracks at
/// the looped time → local TRS. Without: the static bind pose (slice-1 fallback).
/// `world = parent_world · local` (parents precede children) → `bone = world ·
/// inverse_bind`.
fn updateBones(a: *const gl.vmesh.Reader) void {
    const jc = @min(a.jointCount(), max_bones);
    const ccount = a.animClipCount();
    const has_anim = a.animPresent() and ccount > 0;

    // Apply a pending clip switch → start a cross-fade from the frozen old pose.
    if (pending_clip >= 0) {
        const np: u32 = @intCast(pending_clip);
        pending_clip = -1;
        if (has_anim and np != cur_clip and np < ccount) {
            const old_dur = a.animClip(cur_clip).duration;
            from_clip = cur_clip;
            from_time = if (old_dur > 0) @mod(elapsed_s, old_dur) else 0;
            fade_t = 0;
            cur_clip = np;
            elapsed_s = 0;
        }
    }

    const clip = if (cur_clip < ccount) cur_clip else 0;
    const dur = if (has_anim) a.animClip(clip).duration else 0;
    const t = if (has_anim and dur > 0) @mod(elapsed_s, dur) else 0;
    const blending = has_anim and fade_t < fade_dur;
    const w = if (fade_dur > 0) std.math.clamp(fade_t / fade_dur, 0, 1) else 1;

    var j: u32 = 0;
    while (j < jc) : (j += 1) {
        const joint = a.joint(j);
        const local = if (has_anim) blk: {
            const nt = sampleVec3(a, clip, j, 0, t); // new translation
            const nr = sampleQuat(a, clip, j, t); // new rotation
            const ns = sampleVec3(a, clip, j, 2, t); // new scale
            if (blending) {
                const ot = sampleVec3(a, from_clip, j, 0, from_time);
                const orr = sampleQuat(a, from_clip, j, from_time);
                const os = sampleVec3(a, from_clip, j, 2, from_time);
                break :blk gl.math.Mat4.fromTrs(
                    gl.math.Vec3.lerp(ot, nt, w),
                    gl.math.Quat.slerp(orr, nr, w),
                    gl.math.Vec3.lerp(os, ns, w),
                );
            }
            break :blk gl.math.Mat4.fromTrs(nt, nr, ns);
        } else gl.math.Mat4{ .m = joint.bind_local };
        const wm = if (joint.parent < 0)
            local
        else
            world_mats[@intCast(joint.parent)].mul(local);
        world_mats[j] = wm;
        const bone = wm.mul(gl.math.Mat4{ .m = joint.inverse_bind });
        @memcpy(bones[j * 16 ..][0..16], &bone.m);
    }
}

// ── controls (wired to /gl-skin buttons via z-on-click) ─────────────────────────
// No-arg named exports (AnimDemo convention). cur_clip is clamped in updateBones,
// so glskin_clip1 on a single-clip mesh is harmless.

export fn glskin_clip0() void {
    pending_clip = 0;
}
export fn glskin_clip1() void {
    pending_clip = 1;
}
export fn glskin_pause() void {
    paused = true;
}
export fn glskin_play() void {
    paused = false;
}
export fn glskin_speed_half() void {
    speed = 0.5;
}
export fn glskin_speed_1x() void {
    speed = 1.0;
}
export fn glskin_speed_2x() void {
    speed = 2.0;
}

// ── frame export ──────────────────────────────────────────────────────────────

export fn glskin_frame(dt_ms: f32, width: u32, height: u32) u32 {
    // The mesh loads async; until it lands emit a clear-only frame (NOT 0 —
    // the WebGL2 loop reads a 0 return as the unmount signal and tears the loop
    // down, which would stop us before the vmesh ever arrives).
    const a = if (asset) |*r| r else {
        var enc0 = gl.Encoder.init(&cmd_buf);
        enc0.beginFrame(.{ 0.05, 0.06, 0.09, 1.0 }, width, height);
        enc0.endFrame();
        _ = enc0.finish();
        return @intCast(@intFromPtr(&cmd_buf));
    };
    yaw += dt_ms * 0.0006; // slow orbit so the 3D bend reads from all sides
    if (!paused) {
        elapsed_s += dt_ms * 0.001 * speed; // clip playback time (speed-scaled, looped)
        fade_t += dt_ms * 0.001; // cross-fade timer (real-time, NOT speed-scaled)
    }

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
