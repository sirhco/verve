//! verve.gl P10 (WebGPU) PBR scene chunk — drives the /gl-scene-webgpu canvas.
//!
//! Slice-2a consumer that proves the WebGPU PBR path (T1 `wgslPbr` + T2 material
//! textures/defaults + T3 PBR pipeline/set_lights/draw_pbr) renders a textured,
//! direct-lit mesh. Uploads the static stride-48 `gl.mesh.pbr_cube`, a base-color
//! (sRGB) + metallic-roughness texture, creates the F0 PBR WGSL shader
//! (`gl.command.wgslPbr(variant_pbr)`), and drives it through the WebGPU backend
//! via `gl_start_gpu`.
//!
//! DEDICATED WebGPU-only chunk (slice-2a decision): no backend detection, no IBL
//! (the bridge fills slots 5–7 with black placeholder textures), no shadow pass.
//! STRUCTURE mirrors GlWebgpu (single instance; send-once create block guarded by
//! a flag; STABLE statics whose addresses the draw record carries — the bridge
//! dereferences them AFTER the frame fn returns, so they must outlive the call).
//! The PBR content (mesh/material/light/draw_pbr) mirrors GlScene's WebGL2 path.

const verve = @import("verve");
const gl = verve.gl;

// Matches the bridge import (gpuStart), shared with GlWebgpu.
extern "verve" fn gl_start_gpu(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;

// ── Statics ─────────────────────────────────────────────────────────────────

var canvas_handle: ?i32 = null;
var yaw: f32 = 0;
var resources_sent: bool = false;

// STABLE statics — drawPbr records their addresses; the bridge reads them after
// the frame fn returns, so they must outlive the call (exactly like GlScene's
// per-submesh pools, here a single instance so plain module statics suffice).
var mvp: [16]f32 = undefined;
var model_mat: [16]f32 = undefined;
var normal9: [9]f32 = undefined;
var camera_pos: [3]f32 = .{ 0, 0, 4 };
// Material block: baseColor.rgba, [metallic, roughness, occlusion, normalScale],
// emissive.rgb, pad. White dielectric, mid roughness.
var material: [12]f32 = .{ 1, 1, 1, 1, 0, 0.5, 1, 1, 0, 0, 0, 0 };
// One directional light: [type(0=dir), intensity, dir.xyz, color.rgb].
var light: [8]f32 = .{ 0, 3, -0.4, -0.7, -0.6, 1, 1, 1 };

// 2×2 sRGB base-color checker (orange / slate) so the UV texturing is visible.
const base_rgba = [_]u8{
    220, 120, 40, 255, 60,  60,  70, 255,
    60,  60,  70, 255, 220, 120, 40, 255,
};
// 1×1 metallic-roughness, white — the material factors (metallic 0, roughness
// 0.5) dominate (glTF packs roughness in G, metallic in B; factor × texel).
const mr_rgba = [_]u8{ 255, 255, 255, 255 };

// cmd_buf: one-time creates (2×createBuffer + createShader + 2×createTexture
// ≈ 160 B) + per-frame beginFrame/setPipeline/setLights/2×bindTexture/drawPbr/
// endFrame (≈ 130 B). Round generously to 512.
var cmd_buf: [512]u8 = undefined;

const vbuf_handle: u32 = 1;
const ibuf_handle: u32 = 2;
const shader_handle: u32 = 1;
const base_tex: u32 = 1;
const mr_tex: u32 = 2;
const frame_export = "glscenewebgpu_frame";

// ── hydrate ─────────────────────────────────────────────────────────────────

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;

    resources_sent = false;
    yaw = 0;
    canvas_handle = verve.queryRef(@as([]const u8, "glscenewebgpu-canvas"));

    // Start the WebGPU rAF loop. Create commands are emitted send-once inside the
    // first frame (guarded by resources_sent), exactly like GlWebgpu.
    if (canvas_handle) |h|
        gl_start_gpu(h, frame_export.ptr, frame_export.len);
}

// ── frame export ──────────────────────────────────────────────────────────────

export fn glscenewebgpu_frame(dt_ms: f32, width: u32, height: u32) u32 {
    yaw += dt_ms * 0.001; // ~1 rad/s

    const aspect = @as(f32, @floatFromInt(width)) /
        @as(f32, @floatFromInt(@max(height, 1)));
    const proj = gl.math.Mat4.perspective(1.0, aspect, 0.1, 100.0);
    const view = gl.math.Mat4.lookAt(
        gl.math.Vec3.init(camera_pos[0], camera_pos[1], camera_pos[2]),
        gl.math.Vec3.init(0, 0, 0),
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

    var enc = gl.Encoder.init(&cmd_buf);
    if (!resources_sent) {
        resources_sent = true;
        enc.createBuffer(
            vbuf_handle,
            .vertex,
            @intCast(@intFromPtr(&gl.mesh.pbr_cube_vertices)),
            @sizeOf(@TypeOf(gl.mesh.pbr_cube_vertices)),
        );
        enc.createBuffer(
            ibuf_handle,
            .index,
            @intCast(@intFromPtr(&gl.mesh.pbr_cube_indices)),
            @sizeOf(@TypeOf(gl.mesh.pbr_cube_indices)),
        );
        // WGSL module (both stages) — F0 plain PBR. fs args 0/0: one source.
        const wgsl = gl.command.wgslPbr(gl.command.variant_pbr);
        enc.createShader(
            shader_handle,
            gl.command.variant_pbr,
            @intCast(@intFromPtr(wgsl.ptr)),
            @intCast(wgsl.len),
            0,
            0,
        );
        // Base color is sRGB (hardware decode); MR stays linear.
        enc.createTextureSrgb(base_tex, 2, 2, @intCast(@intFromPtr(&base_rgba)), @intCast(base_rgba.len));
        enc.createTexture(mr_tex, 1, 1, @intCast(@intFromPtr(&mr_rgba)), @intCast(mr_rgba.len));
    }
    enc.beginFrame(.{ 0.05, 0.06, 0.09, 1.0 }, width, height);
    enc.setPipeline(shader_handle, gl.command.state_depth_test | gl.command.state_cull_back);
    enc.setLights(1, @intCast(@intFromPtr(&light)));
    enc.bindTexture(0, base_tex);
    enc.bindTexture(1, mr_tex);
    enc.drawPbr(
        vbuf_handle,
        ibuf_handle,
        0,
        @intCast(gl.mesh.pbr_cube_indices.len),
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
