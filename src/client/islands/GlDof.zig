//! verve.gl DOF demo — drives the /gl-dof canvas (image-quality slice 5).
//!
//! Renders a row of cubes receding from near to far along the camera's view
//! axis. A depth-of-field pass blurs cubes whose linear view-space depth is far
//! from a focus distance, keeping the focus band sharp. The frame pipeline
//! (DOF on):
//!
//!   prepass(scene → h_gbuffer)             // depth + view-space normals (slice 1)
//!   scene → h_scene_hdr                    // lit PBR, linear HDR (post path)
//!   runDof(blur H + blur V + CoC combine → h_scene_dof) // slice 5 DOF
//!   composite(scene_src = h_scene_dof × AO + bloom) → canvas
//!
//! DOF off → scene_src defaults to h_scene_hdr (a visual no-op vs the other demos).
//!
//! DOF needs NO matrices — it reads linear view depth straight from the G-buffer
//! alpha. The two blur passes reuse `PostCtx.sh_blur`; the CoC combine derives a
//! circle-of-confusion from |depth - focus_distance| and lerps sharp→blurred by it,
//! writing the result to `h_scene_dof`, which the composite reads via
//! `PostProcess.scene_src` so the blurred scene bloom + tonemaps correctly.
//!
//! Backend-detect mirrors GlSsr/GlSsao/GlPost: `gl_webgpu_available()` selects
//! WGSL vs GLSL. Controls (z-on-click → exports):
//!   gldof_toggle      — DOF on/off (off → scene_src=h_scene_hdr → all sharp)
//!   gldof_focus_near  — step focus_distance toward the camera (near band sharp)
//!   gldof_focus_far   — step focus_distance away (far band sharp)
//!   gldof_toggle_view — blit the raw DOF RT (h_scene_dof) straight to canvas (CDP)
//!   gldof_freeze      — pin the orbit
//!
//! STRUCTURE: singleton statics, send-once create block, STABLE per-frame statics
//! (their addresses ride the command stream), a frame export returning cmd_buf.
//! All per-frame scratch lives in module statics — nothing large on the ~64KB
//! chunk wasm stack.
//!
//! PER-OBJECT ARRAYS: mvp/model/normal/mv/material are `[obj_count][N]f32` — the
//! command stream stores each address and the bridge dereferences AFTER the frame
//! returns, so a single shared static would alias to the last-written value for
//! EVERY draw (this caused slice-4's black scene). Reuses the asset-free
//! `gl.mesh.pbr_cube_vertices` (NO new assets).

const verve = @import("verve");
const gl = verve.gl;

extern "verve" fn gl_start(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;
extern "verve" fn gl_start_gpu(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;
extern "verve" fn gl_webgpu_available() i32;

// ── Statics ───────────────────────────────────────────────────────────────────

var canvas_handle: ?i32 = null;
var use_webgpu: bool = false;
var resources_sent: bool = false;
var dof_on: bool = true;
var dof_view: bool = false; // when on, blit the raw DOF RT straight to canvas (CDP)
var frozen: bool = false;
var yaw: f32 = 0;

// Focus distance in linear view-space depth units. Stepped by the near/far
// controls so the sharp band sweeps through the depth-spread row of cubes.
var focus_distance: f32 = 8.0;
const focal_range: f32 = 4.0; // CoC ramp half-width (view-depth units)
const max_blur: f32 = 0.9; // sharp→blurred lerp cap ∈ [0,1]
const focus_min: f32 = 3.0;
const focus_max: f32 = 16.0;
const focus_step: f32 = 1.5;

// The scene: a row of cubes receding into the distance along -Z, so each cube
// sits at a distinct linear view depth — the focus band is then obvious.
const cube_count: usize = 7;
const cube_pos = [cube_count][3]f32{
    .{ 0.0, 0.0, 6.0 },
    .{ 0.0, 0.0, 4.0 },
    .{ 0.0, 0.0, 2.0 },
    .{ 0.0, 0.0, 0.0 },
    .{ 0.0, 0.0, -2.0 },
    .{ 0.0, 0.0, -4.0 },
    .{ 0.0, 0.0, -6.0 },
};
// Per-cube emissive tint so each depth slice is distinguishable when blurred.
const cube_emissive = [cube_count][3]f32{
    .{ 3.0, 0.5, 0.5 },
    .{ 3.0, 1.8, 0.4 },
    .{ 0.6, 3.0, 0.5 },
    .{ 0.5, 2.6, 2.6 },
    .{ 0.5, 0.8, 3.0 },
    .{ 1.8, 0.5, 3.0 },
    .{ 3.0, 0.5, 2.4 },
};

const obj_count: usize = cube_count;

// STABLE statics — wire records carry their addresses; read after frame returns.
var mvp: [obj_count][16]f32 = undefined;
var model_mat: [obj_count][16]f32 = undefined;
var normal9: [obj_count][9]f32 = undefined;
var mv_mat: [obj_count][16]f32 = undefined;
var camera_pos: [3]f32 = .{ 0, 1.5, 12 };

// Per-object material — ONE slot per object (aliasing rule, see header).
// Each slot: baseColor.rgba, [metallic, roughness, occlusion_strength, normal_scale], emissive.rgb, pad.
var material: [obj_count][12]f32 = undefined;

// gdebug params (DOF-view blit): params.x = 0 → pass rgb (the composited DOF) through.
var gdebug_params: [4]f32 = .{ 0, 0, 0, 0 };

// One directional light from above-front, 16 f32 (set_lights wire = 4 vec4/light):
//   v0 = type/intensity/pos.xy, v1 = pos.z/dir.xyz, v2 = color.rgb/range, v3 = shadow.
var light: [16]f32 = .{ 0, 1.5, 0, 0, 0, -0.3, -0.7, -0.5, 1, 1, 1, 0, 0, 0, 0, 0 };

// 1×1 white maps (baseColor + emissive factors dominate appearance).
const base_rgba = [_]u8{ 255, 255, 255, 255 };
const mr_rgba = [_]u8{ 255, 255, 255, 255 };
const occ_rgba = [_]u8{ 255, 255, 255, 255 };
const emis_rgba = [_]u8{ 255, 255, 255, 255 };

var cmd_buf: [8192]u8 = undefined;

var post_ctx: gl.command.PostCtx = .{};
var prepass_ctx: gl.command.PrepassCtx = .{};
var dof_ctx: gl.command.DofCtx = .{};

const vbuf_cube: u32 = 1;
const ibuf_cube: u32 = 2;
const shader_handle: u32 = 1;
const base_tex: u32 = 1;
const mr_tex: u32 = 2;
const occ_tex: u32 = 3;
const emis_tex: u32 = 4;

const frame_export = "gldof_frame";

// ── hydrate ───────────────────────────────────────────────────────────────────

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;

    resources_sent = false;
    dof_on = true;
    dof_view = false;
    frozen = false;
    yaw = 0;
    focus_distance = 8.0;
    post_ctx = .{};
    prepass_ctx = .{};
    dof_ctx = .{};
    use_webgpu = gl_webgpu_available() != 0;
    canvas_handle = verve.queryRef(@as([]const u8, "gldof-canvas"));

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
    // Bright low-roughness dielectric; per-cube emissive distinguishes depth slices.
    material[i] = .{ 0.85, 0.85, 0.85, 1, 0, 0.45, 1, 1, cube_emissive[i][0], cube_emissive[i][1], cube_emissive[i][2], 0 };
}

// ── frame export ──────────────────────────────────────────────────────────────

export fn gldof_frame(dt_ms: f32, width: u32, height: u32) u32 {
    if (!frozen) yaw += dt_ms * 0.0004; // slow orbit (freeze pins for CDP metrics)

    const aspect = @as(f32, @floatFromInt(width)) /
        @as(f32, @floatFromInt(@max(height, 1)));
    const proj = gl.math.Mat4.perspective(0.9, aspect, 0.1, 100.0);
    // Orbit slightly around the receding row so the depth spread stays legible.
    const r: f32 = 11.0;
    const cx = @sin(yaw) * 2.5;
    const cz = @cos(yaw) * r;
    camera_pos = .{ cx, 1.2, cz };
    const view = gl.math.Mat4.lookAt(
        gl.math.Vec3.init(camera_pos[0], camera_pos[1], camera_pos[2]),
        gl.math.Vec3.init(0, 0, 0),
        gl.math.Vec3.init(0, 1, 0),
    );

    // Per-object transforms: receding row of unit-ish cubes.
    for (cube_pos, 0..) |p, i| {
        objTransforms(i, p, gl.math.Vec3.init(0.6, 0.6, 0.6), view, proj);
    }

    const C = gl.command;
    const scene_variant = C.variant_pbr | C.variant_emissive | C.variant_linear_output;

    var enc = gl.Encoder.init(&cmd_buf);
    if (!resources_sent) {
        resources_sent = true;
        enc.createBuffer(vbuf_cube, .vertex, @intCast(@intFromPtr(&gl.mesh.pbr_cube_vertices)), @sizeOf(@TypeOf(gl.mesh.pbr_cube_vertices)));
        enc.createBuffer(ibuf_cube, .index, @intCast(@intFromPtr(&gl.mesh.pbr_cube_indices)), @sizeOf(@TypeOf(gl.mesh.pbr_cube_indices)));
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

    // ── 1. G-buffer prepass: all scene geometry ──
    enc.beginPrepass(&prepass_ctx, use_webgpu, width, height);
    enc.setPipeline(C.PrepassCtx.sh_prepass, C.state_depth_test | C.state_cull_back);
    var oi: usize = 0;
    while (oi < obj_count) : (oi += 1) {
        enc.drawPrepass(vbuf_cube, ibuf_cube, 0, @intCast(gl.mesh.pbr_cube_indices.len), @intCast(@intFromPtr(&mvp[oi])), @intCast(@intFromPtr(&mv_mat[oi])));
    }
    enc.endPrepass(&prepass_ctx);

    // ── 2. Scene → h_scene_hdr (lit PBR). beginPostProcess opens the HDR pass. ──
    enc.beginPostProcess(&post_ctx, .{
        .bloom = .{ .threshold = 1.0, .intensity = 0.4 },
        .fxaa = true,
        .webgpu = use_webgpu,
        // DOF writes the sharp+blur composite to h_scene_dof; the composite reads it
        // as scene_src. 0 → composite reads h_scene_hdr (DOF off → all sharp, no-op).
        .scene_src = if (dof_on) C.DofCtx.h_scene_dof else 0,
    }, width, height);

    enc.setPipeline(shader_handle, C.state_depth_test | C.state_cull_back);
    enc.setLights(1, @intCast(@intFromPtr(&light)));
    oi = 0;
    while (oi < obj_count) : (oi += 1) {
        setCubeMaterial(oi);
        enc.bindTexture(C.tex_slot_base, base_tex);
        enc.bindTexture(C.tex_slot_mr, mr_tex);
        enc.bindTexture(C.tex_slot_emissive, emis_tex);
        enc.bindTexture(C.tex_slot_occlusion, occ_tex);
        enc.drawPbr(
            vbuf_cube,
            ibuf_cube,
            0,
            @intCast(gl.mesh.pbr_cube_indices.len),
            @intCast(@intFromPtr(&mvp[oi])),
            @intCast(@intFromPtr(&model_mat[oi])),
            @intCast(@intFromPtr(&normal9[oi])),
            @intCast(@intFromPtr(&material[oi])),
            @intCast(@intFromPtr(&camera_pos)),
        );
    }
    // Close the scene HDR pass so the DOF pass + bloom/composite chain can SAMPLE
    // h_scene_hdr as a texture (beginPostProcess opened it; endPostProcess re-uses
    // it but with scene_pass_open=false below).
    enc.endOffscreenPass();

    // ── 3. DOF: blur H + blur V + CoC combine → h_scene_dof ──
    if (dof_on or dof_view) {
        enc.runDof(&dof_ctx, use_webgpu, width, height, focus_distance, focal_range, max_blur);
    }

    // ── DOF-view debug path: blit the raw DOF RT (sharp+blur composite) to canvas ──
    if (dof_view) {
        gdebug_params[0] = 0; // 0 = pass rgb through (no normal-decode)
        enc.beginFrame(.{ 0, 0, 0, 1 }, width, height);
        enc.drawFullscreenQuad(C.PrepassCtx.sh_gdebug, C.DofCtx.h_scene_dof, 0, 0, @intCast(@intFromPtr(&gdebug_params)), 1);
        enc.endFrame();
        _ = enc.finish();
        return @intCast(@intFromPtr(&cmd_buf));
    }

    // ── 4. bloom bright-pass + composite + fxaa, reading scene_src (set above). ──
    // Scene HDR pass already closed above so the DOF pass could SAMPLE it; pass
    // scene_pass_open=false so endPostProcess does NOT issue a leading
    // endOffscreenPass. The chain reads scene_src = h_scene_dof (DOF on) else h_scene_hdr.
    enc.endPostProcess(&post_ctx, false);
    _ = enc.finish();
    return @intCast(@intFromPtr(&cmd_buf));
}

// ── controls (wired to /gl-dof buttons via z-on-click) ──────────────────────

export fn gldof_toggle() void {
    dof_on = !dof_on;
}

export fn gldof_focus_near() void {
    focus_distance -= focus_step;
    if (focus_distance < focus_min) focus_distance = focus_min;
}

export fn gldof_focus_far() void {
    focus_distance += focus_step;
    if (focus_distance > focus_max) focus_distance = focus_max;
}

export fn gldof_toggle_view() void {
    dof_view = !dof_view;
}

export fn gldof_freeze() void {
    frozen = !frozen;
}
