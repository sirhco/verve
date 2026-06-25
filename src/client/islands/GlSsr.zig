//! verve.gl SSR demo — drives the /gl-ssr canvas (image-quality slice 4).
//!
//! Renders a flat reflective FLOOR plane with several bright/emissive cubes
//! floating above it; screen-space reflections of those cubes appear inverted in
//! the floor. The frame pipeline (SSR on):
//!
//!   prepass(scene → h_gbuffer)          // depth + view-space normals (slice 1)
//!   scene → h_scene_hdr                 // lit PBR, linear HDR (post path)
//!   runSsr(h_gbuffer + h_scene_hdr → h_scene_ssr)  // slice 4 SSR (scene + refl)
//!   composite(scene_src = h_scene_ssr × AO + bloom) → canvas
//!
//! SSR off → scene_src defaults to h_scene_hdr (a visual no-op vs the other demos).
//!
//! SSR needs `inv_proj` (view-space reconstruction) AND `proj` (re-projecting the
//! marched reflection ray to screen UV). The island computes the camera projection,
//! inverts it via `gl.math.invert`, and threads both into `runSsr`; the SSR pass
//! writes scene+reflections to `h_scene_ssr`, which the composite reads via
//! `PostProcess.scene_src` so the reflections bloom + tonemap correctly.
//!
//! Backend-detect mirrors GlSsao/GlPost: `gl_webgpu_available()` selects WGSL vs
//! GLSL. Controls (z-on-click → exports):
//!   glssr_toggle      — SSR on/off (off routes scene_src=h_scene_hdr → matte floor)
//!   glssr_toggle_view — show the raw SSR RT (scene + reflections) straight to canvas
//!   glssr_freeze      — pin the orbit
//!
//! STRUCTURE: singleton statics, send-once create block, STABLE per-frame statics
//! (their addresses ride the command stream), a frame export returning cmd_buf.
//! All per-frame scratch lives in module statics — nothing large on the ~64KB
//! chunk wasm stack.
//!
//! NOTE: reuses the asset-free `gl.mesh.pbr_plane_vertices` floor (not shadow.vmesh)
//! to honour the "NO new assets" rule — a flat plane is an ideal mirror surface and
//! needs no .glb/.vmesh load. Material-aware / roughness-weighted SSR is deferred
//! (the G-buffer has no roughness/metalness channel; it needs MRT).

const verve = @import("verve");
const gl = verve.gl;

extern "verve" fn gl_start(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;
extern "verve" fn gl_start_gpu(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;
extern "verve" fn gl_webgpu_available() i32;

// ── Statics ───────────────────────────────────────────────────────────────────

var canvas_handle: ?i32 = null;
var use_webgpu: bool = false;
var resources_sent: bool = false;
var ssr_on: bool = true;
var ssr_view: bool = false; // when on, blit the raw SSR RT straight to canvas (CDP)
var frozen: bool = false;
var yaw: f32 = 0;

// The scene: a reflective floor + several bright cubes floating above it so their
// reflections are clearly visible in the floor below.
const cube_count: usize = 4;
const cube_pos = [cube_count][3]f32{
    .{ 0.0, 1.4, 0.0 },
    .{ 1.5, 1.1, 0.6 },
    .{ -1.4, 1.2, -0.5 },
    .{ 0.5, 1.7, -1.4 },
};
// Per-cube emissive tint so each reflection is distinguishable.
const cube_emissive = [cube_count][3]f32{
    .{ 3.0, 0.6, 0.6 },
    .{ 0.6, 3.0, 0.8 },
    .{ 0.7, 0.8, 3.0 },
    .{ 3.0, 2.6, 0.6 },
};

// STABLE statics — wire records carry their addresses; read after frame returns.
const obj_count: usize = cube_count + 1; // +1 floor
var mvp: [obj_count][16]f32 = undefined;
var model_mat: [obj_count][16]f32 = undefined;
var normal9: [obj_count][9]f32 = undefined;
var mv_mat: [obj_count][16]f32 = undefined;
var camera_pos: [3]f32 = .{ 4.0, 3.0, 4.5 };

// Per-object material — ONE slot per object. The command stream stores the
// address of each material; the bridge dereferences it AFTER the frame returns,
// so a single shared static would alias to the last-written value (the floor)
// for every draw. Must be per-object, exactly like mvp/model_mat/normal9.
// Each slot: baseColor.rgba, [metallic, roughness, occlusion_strength, normal_scale], emissive.rgb, pad.
var material: [obj_count][12]f32 = undefined;

// SSR matrices (stable; runSsr copies them into its param buffer).
var inv_proj_mat: [16]f32 = undefined;
var proj_mat: [16]f32 = undefined;

// gdebug params (SSR-view blit): params.x = 0 → pass rgb (the HDR scene) through.
var gdebug_params: [4]f32 = .{ 0, 0, 0, 0 };

// One directional light from above-front, 16 f32 (set_lights wire = 4 vec4/light):
//   v0 = type/intensity/pos.xy, v1 = pos.z/dir.xyz, v2 = color.rgb/range, v3 = shadow.
var light: [16]f32 = .{ 0, 1.4, 0, 0, 0, -0.3, -0.9, -0.3, 1, 1, 1, 0, 0, 0, 0, 0 };

// 1×1 white maps (baseColor + emissive factors dominate appearance).
const base_rgba = [_]u8{ 255, 255, 255, 255 };
const mr_rgba = [_]u8{ 255, 255, 255, 255 };
const occ_rgba = [_]u8{ 255, 255, 255, 255 };
const emis_rgba = [_]u8{ 255, 255, 255, 255 };

var cmd_buf: [8192]u8 = undefined;

var post_ctx: gl.command.PostCtx = .{};
var prepass_ctx: gl.command.PrepassCtx = .{};
var ssr_ctx: gl.command.SsrCtx = .{};

const vbuf_cube: u32 = 1;
const ibuf_cube: u32 = 2;
const vbuf_floor: u32 = 3;
const ibuf_floor: u32 = 4;
const shader_handle: u32 = 1;
const base_tex: u32 = 1;
const mr_tex: u32 = 2;
const occ_tex: u32 = 3;
const emis_tex: u32 = 4;

const frame_export = "glssr_frame";

// ── hydrate ───────────────────────────────────────────────────────────────────

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;

    resources_sent = false;
    ssr_on = true;
    ssr_view = false;
    frozen = false;
    yaw = 0;
    post_ctx = .{};
    prepass_ctx = .{};
    ssr_ctx = .{};
    use_webgpu = gl_webgpu_available() != 0;
    canvas_handle = verve.queryRef(@as([]const u8, "glssr-canvas"));

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

fn setCubeMaterial(i: usize) void {
    // Bright low-roughness dielectric; the per-cube emissive makes each reflection
    // a distinct colour in the floor.
    material[i] = .{ 0.8, 0.8, 0.8, 1, 0, 0.4, 1, 1, cube_emissive[i][0], cube_emissive[i][1], cube_emissive[i][2], 0 };
}

fn setFloorMaterial(i: usize) void {
    // Dark, smooth, non-emissive floor — reads as a near-mirror so reflections pop.
    material[i] = .{ 0.04, 0.04, 0.05, 1, 0, 0.1, 1, 1, 0, 0, 0, 0 };
}

// ── frame export ──────────────────────────────────────────────────────────────

export fn glssr_frame(dt_ms: f32, width: u32, height: u32) u32 {
    if (!frozen) yaw += dt_ms * 0.0005; // slow orbit (freeze pins for CDP metrics)

    const aspect = @as(f32, @floatFromInt(width)) /
        @as(f32, @floatFromInt(@max(height, 1)));
    const proj = gl.math.Mat4.perspective(0.9, aspect, 0.1, 100.0);
    // Orbit a low camera so the floor fills most of the frame (good reflection view).
    const r: f32 = 6.0;
    const cx = @cos(yaw) * r;
    const cz = @sin(yaw) * r;
    camera_pos = .{ cx, 2.4, cz };
    const view = gl.math.Mat4.lookAt(
        gl.math.Vec3.init(camera_pos[0], camera_pos[1], camera_pos[2]),
        gl.math.Vec3.init(0, 0.8, 0),
        gl.math.Vec3.init(0, 1, 0),
    );

    // SSR needs both proj and its inverse.
    proj_mat = proj.m;
    inv_proj_mat = gl.math.invert(proj).m;

    // Per-object transforms: cubes (unit-ish) + floor (large flat plane).
    for (cube_pos, 0..) |p, i| {
        objTransforms(i, p, gl.math.Vec3.init(0.5, 0.5, 0.5), view, proj);
    }
    objTransforms(cube_count, .{ 0, 0, 0 }, gl.math.Vec3.init(8, 1, 8), view, proj);

    const C = gl.command;
    const scene_variant = C.variant_pbr | C.variant_emissive | C.variant_linear_output;

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
        enc.createTextureSrgb(emis_tex, 1, 1, @intCast(@intFromPtr(&emis_rgba)), @intCast(emis_rgba.len));
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

    // ── 2. Scene → h_scene_hdr (lit PBR). beginPostProcess opens the HDR pass. ──
    enc.beginPostProcess(&post_ctx, .{
        .bloom = .{ .threshold = 1.0, .intensity = 0.5 },
        .fxaa = true,
        .webgpu = use_webgpu,
        // SSR writes scene+reflections to h_scene_ssr; the composite reads it as
        // scene_src. 0 → composite reads h_scene_hdr (SSR off → matte floor, no-op).
        .scene_src = if (ssr_on) C.SsrCtx.h_scene_ssr else 0,
    }, width, height);

    enc.setPipeline(shader_handle, C.state_depth_test | C.state_cull_back);
    enc.setLights(1, @intCast(@intFromPtr(&light)));
    oi = 0;
    while (oi < obj_count) : (oi += 1) {
        if (oi < cube_count) setCubeMaterial(oi) else setFloorMaterial(oi);
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
            @intCast(@intFromPtr(&material[oi])),
            @intCast(@intFromPtr(&camera_pos)),
        );
    }
    // Close the scene HDR pass (endPostProcess re-opens it; we must close it here so
    // the SSR pass and the bloom/composite chain can read h_scene_hdr as a texture).
    // beginPostProcess opened it; the SSR pass + endPostProcess need it closed first.
    enc.endOffscreenPass();

    // ── 3. SSR: (h_gbuffer + h_scene_hdr) → h_scene_ssr (scene + reflections) ──
    if (ssr_on or ssr_view) {
        // strength 0.7, max view-space march 9.0, depth-compare thickness 0.6, Schlick exp 5.
        enc.runSsr(&ssr_ctx, use_webgpu, width, height, 0.7, 9.0, 0.6, 5.0, &inv_proj_mat, &proj_mat);
    }

    // ── SSR-view debug path: blit the raw SSR RT (scene+reflections) to canvas ──
    if (ssr_view) {
        gdebug_params[0] = 0; // 0 = pass rgb through (no normal-decode)
        enc.beginFrame(.{ 0, 0, 0, 1 }, width, height);
        enc.drawFullscreenQuad(C.PrepassCtx.sh_gdebug, C.SsrCtx.h_scene_ssr, 0, 0, @intCast(@intFromPtr(&gdebug_params)), 1);
        enc.endFrame();
        _ = enc.finish();
        return @intCast(@intFromPtr(&cmd_buf));
    }

    // ── 4. bloom bright-pass + composite + fxaa, reading scene_src (set above). ──
    // The scene HDR pass was already closed above (line ~270) so the SSR pass could
    // SAMPLE h_scene_hdr. Pass scene_pass_open=false so endPostProcess does NOT issue
    // its leading endOffscreenPass (no pass is open). The chain then reads
    // scene_src = h_scene_ssr (set on the opts above) — not h_scene_hdr.
    enc.endPostProcess(&post_ctx, false);
    _ = enc.finish();
    return @intCast(@intFromPtr(&cmd_buf));
}

// ── controls (wired to /gl-ssr buttons via z-on-click) ──────────────────────

export fn glssr_toggle() void {
    ssr_on = !ssr_on;
}

export fn glssr_toggle_view() void {
    ssr_view = !ssr_view;
}

export fn glssr_freeze() void {
    frozen = !frozen;
}
