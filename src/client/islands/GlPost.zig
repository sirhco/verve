//! verve.gl post-processing demo — drives the /gl-post canvas.
//!
//! Renders a bright emissive PBR cube on a dark background with a full
//! post-processing pipeline (bloom + FXAA). The scene shader uses
//! `variant_pbr | variant_linear_output` to emit linear HDR (skipping the
//! in-shader ACES tonemap); `beginPostProcess`/`endPostProcess` runs the
//! bloom bright-pass + blur chain, composite (tonemap), and FXAA pass.
//!
//! Backend-detect mirrors GlSkin: `gl_webgpu_available()` selects WGSL PBR
//! (via `wgslPbr`) + `gl_start_gpu`, else GLSL PBR (`pbrVertexSrc` /
//! `pbrFragmentSrc`) + `gl_start`. The post shaders are selected by
//! `PostProcess.webgpu` mirroring the same flag.
//!
//! STRUCTURE: singleton statics, a send-once create block guarded by a flag,
//! STABLE statics whose addresses the draw record carries (the bridge reads
//! them after the frame fn returns), a frame export returning cmd_buf pointer.

const verve = @import("verve");
const gl = verve.gl;

extern "verve" fn gl_start(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;
extern "verve" fn gl_start_gpu(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;
extern "verve" fn gl_webgpu_available() i32;

// ── Statics ───────────────────────────────────────────────────────────────────

var canvas_handle: ?i32 = null;
var use_webgpu: bool = false;
var resources_sent: bool = false;
var bloom_on: bool = true;
var fxaa_on: bool = true;
var frozen: bool = false;
var yaw: f32 = 0;
// Image-quality slice 1: G-buffer prepass debug viz. When on, the frame renders
// the depth + view-space-normal prepass into h_gbuffer and blits the gdebug
// fullscreen shader straight to the canvas (bypassing the scene + post chain).
// gbuffer_mode: 0 = view normals (rgb=n*0.5+0.5), 1 = linearized depth grayscale.
var gbuffer_on: bool = false;
var gbuffer_mode: f32 = 0;

// STABLE statics — wire records carry their addresses; read after frame returns.
var mvp: [16]f32 = undefined;
var model_mat: [16]f32 = undefined;
var normal9: [9]f32 = undefined;
var camera_pos: [3]f32 = .{ 0, 0.5, 3.5 };
// Prepass mv = view·model (view-space pos + normal transform); gdebug params.x = mode.
var mv_mat: [16]f32 = undefined;
var gdebug_params: [4]f32 = .{ 0, 0, 0, 0 };

// Material: baseColor.rgba, [metallic, roughness, occlusion_strength, normal_scale],
// emissive.rgb, pad. High emissive (2.5 linear) so the bloom halo is clearly visible.
var material: [12]f32 = .{ 0.1, 0.1, 0.2, 1, 0, 0.9, 1, 1, 2.5, 2.5, 2.5, 0 };

// One directional light, 16 f32 (the set_lights wire format = 4 vec4/light):
//   v0 = type/intensity/pos.xy, v1 = pos.z/dir.xyz, v2 = color.rgb/range, v3 = shadow.
var light: [16]f32 = .{ 0, 2.0, 0, 0, 0, -0.4, -0.7, -0.5, 1, 1, 1, 0, 0, 0, 0, 0 };

// 1×1 white base-color (the emissive term dominates appearance).
const base_rgba = [_]u8{ 255, 255, 255, 255 };
const mr_rgba = [_]u8{ 255, 255, 255, 255 };
const occ_rgba = [_]u8{ 255, 255, 255, 255 };
// 1×1 white emissive map (linear); emissive_factor(2.5) × 1.0 → HDR > bloom threshold.
const emis_rgba = [_]u8{ 255, 255, 255, 255 };

// cmd_buf sizing: createBuffer×2 (one-time ~40B) + createShader (~28B) + textures (~60B)
// + per-frame beginPostProcess (~80B) + setPipeline (12B) + setLights (12B) +
// bindTexture×3 (36B) + drawPbr (40B) + endPostProcess (~200B) + header (4B) = ~500B.
// Round up to 4096 for headroom.
var cmd_buf: [4096]u8 = undefined;

// Post-processing persistent context (stable param buffers, shader/RT handles).
var post_ctx: gl.command.PostCtx = .{};
// Prepass persistent context (G-buffer RT + prepass/gdebug shader handles 248-250).
var prepass_ctx: gl.command.PrepassCtx = .{};

const vbuf_handle: u32 = 1;
const ibuf_handle: u32 = 2;
const shader_handle: u32 = 1;
const base_tex: u32 = 1;
const mr_tex: u32 = 2;
const occ_tex: u32 = 3;
const emis_tex: u32 = 4;

const frame_export = "glpost_frame";

// ── hydrate ───────────────────────────────────────────────────────────────────

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;

    resources_sent = false;
    bloom_on = true;
    fxaa_on = true;
    frozen = false;
    yaw = 0;
    gbuffer_on = false;
    gbuffer_mode = 0;
    post_ctx = .{};
    prepass_ctx = .{};
    use_webgpu = gl_webgpu_available() != 0;
    canvas_handle = verve.queryRef(@as([]const u8, "glpost-canvas"));

    if (canvas_handle) |h| {
        if (use_webgpu)
            gl_start_gpu(h, frame_export.ptr, frame_export.len)
        else
            gl_start(h, frame_export.ptr, frame_export.len);
    }
}

// ── frame export ──────────────────────────────────────────────────────────────

export fn glpost_frame(dt_ms: f32, width: u32, height: u32) u32 {
    if (!frozen) yaw += dt_ms * 0.0008; // slow orbit ~0.8 rad/s (freeze pins orientation)

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
    mv_mat = view.mul(model).m; // view·model — prepass view-space pos + normal transform

    const scene_variant = gl.command.variant_pbr | gl.command.variant_emissive | gl.command.variant_linear_output;

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
        if (use_webgpu) {
            const w = gl.command.wgslPbr(scene_variant);
            enc.createShader(shader_handle, scene_variant, @intCast(@intFromPtr(w.ptr)), @intCast(w.len), 0, 0);
        } else {
            const vs = gl.command.pbrVertexSrc(scene_variant);
            const fs = gl.command.pbrFragmentSrc(scene_variant);
            enc.createShader(shader_handle, scene_variant, @intCast(@intFromPtr(vs.ptr)), @intCast(vs.len), @intCast(@intFromPtr(fs.ptr)), @intCast(fs.len));
        }
        enc.createTextureSrgb(base_tex, 1, 1, @intCast(@intFromPtr(&base_rgba)), @intCast(base_rgba.len));
        enc.createTexture(mr_tex, 1, 1, @intCast(@intFromPtr(&mr_rgba)), @intCast(mr_rgba.len));
        enc.createTexture(occ_tex, 1, 1, @intCast(@intFromPtr(&occ_rgba)), @intCast(occ_rgba.len));
        enc.createTexture(emis_tex, 1, 1, @intCast(@intFromPtr(&emis_rgba)), @intCast(emis_rgba.len));
    }

    if (gbuffer_on) {
        // ── G-buffer debug path (image-quality slice 1) ──
        // Render the cube into the prepass G-buffer, then blit the gdebug
        // fullscreen shader straight to the canvas (bypass scene + post chain).
        const C = gl.command;
        enc.beginPrepass(&prepass_ctx, use_webgpu, width, height);
        enc.setPipeline(C.PrepassCtx.sh_prepass, C.state_depth_test | C.state_cull_back);
        enc.drawPrepass(
            vbuf_handle,
            ibuf_handle,
            0,
            @intCast(gl.mesh.pbr_cube_indices.len),
            @intCast(@intFromPtr(&mvp)),
            @intCast(@intFromPtr(&mv_mat)),
        );
        enc.endPrepass(&prepass_ctx);

        // Debug blit: gdebug fullscreen → canvas. params.x = mode (0 normals, 1 depth).
        gdebug_params[0] = gbuffer_mode;
        enc.beginFrame(.{ 0, 0, 0, 1 }, width, height);
        enc.drawFullscreenQuad(C.PrepassCtx.sh_gdebug, C.PrepassCtx.h_gbuffer, 0, 0, @intCast(@intFromPtr(&gdebug_params)), 1);
        enc.endFrame();

        _ = enc.finish();
        return @intCast(@intFromPtr(&cmd_buf));
    }

    enc.beginPostProcess(&post_ctx, .{
        .bloom = if (bloom_on) .{ .threshold = 1.0, .intensity = 0.8 } else null,
        .fxaa = fxaa_on,
        .webgpu = use_webgpu,
    }, width, height);

    enc.setPipeline(shader_handle, gl.command.state_depth_test | gl.command.state_cull_back);
    enc.setLights(1, @intCast(@intFromPtr(&light)));
    enc.bindTexture(gl.command.tex_slot_base, base_tex);
    enc.bindTexture(gl.command.tex_slot_mr, mr_tex);
    enc.bindTexture(gl.command.tex_slot_emissive, emis_tex);
    enc.bindTexture(gl.command.tex_slot_occlusion, occ_tex);
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

    enc.endPostProcess(&post_ctx, true);
    _ = enc.finish();
    return @intCast(@intFromPtr(&cmd_buf));
}

// ── controls (wired to /gl-post buttons via z-on-click) ──────────────────────

export fn glpost_toggle_bloom() void {
    bloom_on = !bloom_on;
}

export fn glpost_toggle_fxaa() void {
    fxaa_on = !fxaa_on;
}

export fn glpost_toggle_freeze() void {
    frozen = !frozen;
}

// Image-quality slice 1: toggle the G-buffer prepass debug viz on/off. When on,
// the frame renders the depth+normal prepass and blits the gdebug shader to the
// canvas instead of the lit scene + post chain.
export fn glpost_toggle_gbuffer() void {
    gbuffer_on = !gbuffer_on;
}

// Switch the G-buffer debug mode: 0 = view normals, 1 = linearized depth.
export fn glpost_toggle_gbuffer_mode() void {
    gbuffer_mode = if (gbuffer_mode > 0.5) 0 else 1;
}
