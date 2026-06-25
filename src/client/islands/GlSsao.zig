//! verve.gl SSAO demo — drives the /gl-ssao canvas (image-quality slice 3).
//!
//! Renders a floor plane with several cubes sitting on it — contact/crease
//! geometry where ambient occlusion is clearly visible. The frame pipeline:
//!
//!   prepass(scene → h_gbuffer)          // depth + view-space normals (slice 1)
//!   scene → h_scene_hdr                 // lit PBR, linear HDR (post path)
//!   runSsao(h_gbuffer → h_ao_raw → h_ao_blur)   // slice 3 SSAO
//!   composite(scene_hdr × AO + bloom) → canvas  // AO multiplied in
//!
//! The SSAO pass needs `inv_proj` (view-space reconstruction) AND `proj`
//! (re-projecting hemisphere samples to screen UV). The island computes the
//! camera projection, inverts it via `gl.math.invert`, and threads both into
//! `runSsao`; `endPostProcess` binds `h_ao_blur` at the composite's tex2.
//!
//! Backend-detect mirrors GlPost/GlSkin: `gl_webgpu_available()` selects WGSL
//! vs GLSL. Controls (z-on-click → exports):
//!   glssao_toggle      — SSAO on/off (off binds the white tex2 dummy → AO=1)
//!   glssao_toggle_view — show the raw AO buffer (grayscale) vs the final image
//!   glssao_freeze      — pin the orbit
//!
//! STRUCTURE: singleton statics, send-once create block, STABLE per-frame statics
//! (their addresses ride the command stream), a frame export returning cmd_buf.
//! All per-frame scratch lives in module statics — nothing large on the ~64KB
//! chunk wasm stack.

const verve = @import("verve");
const gl = verve.gl;

extern "verve" fn gl_start(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;
extern "verve" fn gl_start_gpu(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;
extern "verve" fn gl_webgpu_available() i32;

// ── Statics ───────────────────────────────────────────────────────────────────

var canvas_handle: ?i32 = null;
var use_webgpu: bool = false;
var resources_sent: bool = false;
var ssao_on: bool = true;
var ao_view: bool = false; // when on, blit the AO buffer straight to canvas (CDP)
var frozen: bool = false;
var yaw: f32 = 0;

// The scene: a floor plane + several unit cubes resting on it. Positions chosen
// so cube-cube gaps and cube-floor contacts create visible AO crevices.
const cube_count: usize = 5;
const cube_pos = [cube_count][3]f32{
    .{ 0.0, 0.5, 0.0 },
    .{ 1.3, 0.5, 0.4 },
    .{ -1.2, 0.5, -0.3 },
    .{ 0.6, 0.5, -1.3 },
    .{ -0.7, 0.5, 1.2 },
};

// STABLE statics — wire records carry their addresses; read after frame returns.
// One mvp/model/normal/mv per object (cubes + floor) so the prepass and scene
// passes can re-issue each draw with its own transform.
const obj_count: usize = cube_count + 1; // +1 floor
var mvp: [obj_count][16]f32 = undefined;
var model_mat: [obj_count][16]f32 = undefined;
var normal9: [obj_count][9]f32 = undefined;
var mv_mat: [obj_count][16]f32 = undefined;
var camera_pos: [3]f32 = .{ 3.5, 3.0, 4.5 };

// SSAO matrices (stable; runSsao copies them into its param buffer).
var inv_proj_mat: [16]f32 = undefined;
var proj_mat: [16]f32 = undefined;

// gdebug params (AO-view blit): params.x = 0 → pass rgb (the AO grayscale) through.
var gdebug_params: [4]f32 = .{ 0, 0, 0, 0 };

// Material: baseColor.rgba, [metallic, roughness, occlusion_strength, normal_scale],
// emissive.rgb, pad. Matte mid-grey dielectric so the directional + ambient terms
// (and the AO that modulates them) read clearly. Low emissive so bloom is subtle.
var material: [12]f32 = .{ 0.6, 0.6, 0.62, 1, 0, 0.85, 1, 1, 0, 0, 0, 0 };

// One directional light from above-front: [type(0=dir), intensity, dir.xyz, color.rgb].
var light: [8]f32 = .{ 0, 2.2, -0.3, -0.8, -0.4, 1, 1, 1 };

// 1×1 white maps (baseColor factor dominates appearance).
const base_rgba = [_]u8{ 255, 255, 255, 255 };
const mr_rgba = [_]u8{ 255, 255, 255, 255 };
const occ_rgba = [_]u8{ 255, 255, 255, 255 };
const emis_rgba = [_]u8{ 0, 0, 0, 255 };

// cmd_buf: one-time creates + per-frame prepass(6 draws) + post chain(~6 quads) +
// scene(6 PBR draws) + runSsao(2 quads + 4 creates first frame). Generous headroom.
var cmd_buf: [8192]u8 = undefined;

var post_ctx: gl.command.PostCtx = .{};
var prepass_ctx: gl.command.PrepassCtx = .{};
var ssao_ctx: gl.command.SsaoCtx = .{};

const vbuf_cube: u32 = 1;
const ibuf_cube: u32 = 2;
const vbuf_floor: u32 = 3;
const ibuf_floor: u32 = 4;
const shader_handle: u32 = 1;
const base_tex: u32 = 1;
const mr_tex: u32 = 2;
const occ_tex: u32 = 3;
const emis_tex: u32 = 4;

const frame_export = "glssao_frame";

// ── hydrate ───────────────────────────────────────────────────────────────────

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;

    resources_sent = false;
    ssao_on = true;
    ao_view = false;
    frozen = false;
    yaw = 0;
    post_ctx = .{};
    prepass_ctx = .{};
    ssao_ctx = .{};
    use_webgpu = gl_webgpu_available() != 0;
    canvas_handle = verve.queryRef(@as([]const u8, "glssao-canvas"));

    if (canvas_handle) |h| {
        if (use_webgpu)
            gl_start_gpu(h, frame_export.ptr, frame_export.len)
        else
            gl_start(h, frame_export.ptr, frame_export.len);
    }
}

// ── helpers ─────────────────────────────────────────────────────────────────

fn objTransforms(i: usize, pos: [3]f32, scale: gl.math.Vec3, view: gl.math.Mat4, proj: gl.math.Mat4) void {
    const model = gl.math.Mat4.fromTrs(
        gl.math.Vec3.init(pos[0], pos[1], pos[2]),
        gl.math.Quat.fromAxisAngle(gl.math.Vec3.init(0, 1, 0), 0),
        scale,
    );
    mvp[i] = proj.mul(view).mul(model).m;
    model_mat[i] = model.m;
    normal9[i] = gl.math.normalMatrix(model);
    mv_mat[i] = view.mul(model).m;
}

// ── frame export ──────────────────────────────────────────────────────────────

export fn glssao_frame(dt_ms: f32, width: u32, height: u32) u32 {
    if (!frozen) yaw += dt_ms * 0.0005; // slow orbit (freeze pins for CDP metrics)

    const aspect = @as(f32, @floatFromInt(width)) /
        @as(f32, @floatFromInt(@max(height, 1)));
    const proj = gl.math.Mat4.perspective(0.9, aspect, 0.1, 100.0);
    // Orbit the camera around the scene center.
    const r: f32 = 6.0;
    const cx = @cos(yaw) * r;
    const cz = @sin(yaw) * r;
    camera_pos = .{ cx, 3.2, cz };
    const view = gl.math.Mat4.lookAt(
        gl.math.Vec3.init(camera_pos[0], camera_pos[1], camera_pos[2]),
        gl.math.Vec3.init(0, 0.4, 0),
        gl.math.Vec3.init(0, 1, 0),
    );

    // SSAO needs both proj and its inverse.
    proj_mat = proj.m;
    inv_proj_mat = gl.math.invert(proj).m;

    // Per-object transforms: cubes (unit) + floor (large flat plane).
    for (cube_pos, 0..) |p, i| {
        objTransforms(i, p, gl.math.Vec3.init(0.5, 0.5, 0.5), view, proj);
    }
    objTransforms(cube_count, .{ 0, 0, 0 }, gl.math.Vec3.init(6, 1, 6), view, proj);

    const C = gl.command;
    const scene_variant = C.variant_pbr | C.variant_linear_output;

    var enc = gl.Encoder.init(&cmd_buf);
    if (!resources_sent) {
        resources_sent = true;
        enc.createBuffer(vbuf_cube, .vertex, @intCast(@intFromPtr(&gl.mesh.pbr_cube_vertices)), @sizeOf(@TypeOf(gl.mesh.pbr_cube_vertices)));
        enc.createBuffer(ibuf_cube, .index, @intCast(@intFromPtr(&gl.mesh.pbr_cube_indices)), @sizeOf(@TypeOf(gl.mesh.pbr_cube_indices)));
        enc.createBuffer(vbuf_floor, .vertex, @intCast(@intFromPtr(&gl.mesh.pbr_plane_vertices)), @sizeOf(@TypeOf(gl.mesh.pbr_plane_vertices)));
        enc.createBuffer(ibuf_floor, .index, @intCast(@intFromPtr(&gl.mesh.pbr_plane_indices)), @sizeOf(@TypeOf(gl.mesh.pbr_plane_indices)));
        if (use_webgpu) {
            const w = C.wgslPbr(scene_variant);
            enc.createShader(shader_handle, scene_variant, @intCast(@intFromPtr(w.ptr)), @intCast(w.len), 0, 0);
        } else {
            const vs = C.pbrVertexSrc(scene_variant);
            const fs = C.pbrFragmentSrc(scene_variant);
            enc.createShader(shader_handle, scene_variant, @intCast(@intFromPtr(vs.ptr)), @intCast(vs.len), @intCast(@intFromPtr(fs.ptr)), @intCast(fs.len));
        }
        enc.createTextureSrgb(base_tex, 1, 1, @intCast(@intFromPtr(&base_rgba)), @intCast(base_rgba.len));
        enc.createTexture(mr_tex, 1, 1, @intCast(@intFromPtr(&mr_rgba)), @intCast(mr_rgba.len));
        enc.createTexture(occ_tex, 1, 1, @intCast(@intFromPtr(&occ_rgba)), @intCast(occ_rgba.len));
        enc.createTexture(emis_tex, 1, 1, @intCast(@intFromPtr(&emis_rgba)), @intCast(emis_rgba.len));
    }

    // ── 1. G-buffer prepass: all scene geometry (cubes + floor) ──
    enc.beginPrepass(&prepass_ctx, use_webgpu, width, height);
    enc.setPipeline(C.PrepassCtx.sh_prepass, C.state_depth_test | C.state_cull_back);
    var oi: usize = 0;
    while (oi < obj_count) : (oi += 1) {
        const vb = if (oi < cube_count) vbuf_cube else vbuf_floor;
        const ib = if (oi < cube_count) ibuf_cube else ibuf_floor;
        const count: u32 = if (oi < cube_count) @intCast(gl.mesh.pbr_cube_indices.len) else @intCast(gl.mesh.pbr_plane_indices.len);
        enc.drawPrepass(vb, ib, 0, count, @intCast(@intFromPtr(&mvp[oi])), @intCast(@intFromPtr(&mv_mat[oi])));
    }
    enc.endPrepass(&prepass_ctx);

    // ── 2. SSAO: G-buffer → h_ao_raw → h_ao_blur (skipped when SSAO is off) ──
    if (ssao_on or ao_view) {
        enc.runSsao(&ssao_ctx, use_webgpu, width, height, 0.6, 0.025, 1.4, &inv_proj_mat, &proj_mat);
    }

    // ── AO-view debug path: blit the blurred AO buffer straight to canvas ──
    if (ao_view) {
        gdebug_params[0] = 0; // 0 = pass rgb through (AO stored as grayscale rgb)
        enc.beginFrame(.{ 0, 0, 0, 1 }, width, height);
        enc.drawFullscreenQuad(C.PrepassCtx.sh_gdebug, C.SsaoCtx.h_ao_blur, 0, 0, @intCast(@intFromPtr(&gdebug_params)), 1);
        enc.endFrame();
        _ = enc.finish();
        return @intCast(@intFromPtr(&cmd_buf));
    }

    // ── 3. Scene → h_scene_hdr, composite with AO (tex2) ──
    enc.beginPostProcess(&post_ctx, .{
        .bloom = .{ .threshold = 1.2, .intensity = 0.4 },
        .fxaa = true,
        .webgpu = use_webgpu,
        // SSAO blur feeds the composite's tex2; 0 → white dummy (AO=1, no-op).
        .ao_tex = if (ssao_on) C.SsaoCtx.h_ao_blur else 0,
    }, width, height);

    enc.setPipeline(shader_handle, C.state_depth_test | C.state_cull_back);
    enc.setLights(1, @intCast(@intFromPtr(&light)));
    oi = 0;
    while (oi < obj_count) : (oi += 1) {
        enc.bindTexture(C.tex_slot_base, base_tex);
        enc.bindTexture(C.tex_slot_mr, mr_tex);
        enc.bindTexture(C.tex_slot_emissive, emis_tex);
        enc.bindTexture(C.tex_slot_occlusion, occ_tex);
        const vb = if (oi < cube_count) vbuf_cube else vbuf_floor;
        const ib = if (oi < cube_count) ibuf_cube else ibuf_floor;
        const count: u32 = if (oi < cube_count) @intCast(gl.mesh.pbr_cube_indices.len) else @intCast(gl.mesh.pbr_plane_indices.len);
        enc.drawPbr(
            vb,
            ib,
            0,
            count,
            @intCast(@intFromPtr(&mvp[oi])),
            @intCast(@intFromPtr(&model_mat[oi])),
            @intCast(@intFromPtr(&normal9[oi])),
            @intCast(@intFromPtr(&material)),
            @intCast(@intFromPtr(&camera_pos)),
        );
    }

    enc.endPostProcess(&post_ctx);
    _ = enc.finish();
    return @intCast(@intFromPtr(&cmd_buf));
}

// ── controls (wired to /gl-ssao buttons via z-on-click) ──────────────────────

export fn glssao_toggle() void {
    ssao_on = !ssao_on;
}

export fn glssao_toggle_view() void {
    ao_view = !ao_view;
}

export fn glssao_freeze() void {
    frozen = !frozen;
}
