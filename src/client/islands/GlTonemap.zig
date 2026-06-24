//! verve.gl tone-mapping + vignette demo — drives the /gl-tonemap canvas.
//!
//! Renders a bright emissive PBR sphere on a dark background with a full
//! post-processing pipeline (bloom + FXAA + selectable tone-mapper + vignette).
//! The scene shader uses `variant_pbr | variant_linear_output` to emit linear HDR
//! (skipping the in-shader ACES tonemap); `beginPostProcess`/`endPostProcess` runs
//! the bloom chain and composite with the current `ToneMap` operator + vignette.
//!
//! High-intensity emissive (factor 4.0) makes operators visibly differ:
//!   op 0 (Linear): clips to white on the bright emissive blob.
//!   op 1 (Reinhard): soft rolloff, slightly desaturated highlights.
//!   op 2 (Reinhard-ext): brighter shoulder than plain Reinhard.
//!   op 3 (ACES, default): filmic S-curve, warm look.
//!   op 4 (AgX): neutral, perceptually linear, no hue-shift.
//!   op 5 (Uncharted2): slightly crushed blacks, warm filmic.
//!
//! Exports: gltonemap_frame / gltonemap_cycle_tonemap / gltonemap_toggle_vignette
//!          / gltonemap_freeze (mirrors GlPost freeze convention).
//! Per-frame scratch (operator index, vignette flag, yaw, frozen) kept in module
//! statics — OFF the ~64 KB wasm chunk stack.

const verve = @import("verve");
const gl = verve.gl;

extern "verve" fn gl_start(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;
extern "verve" fn gl_start_gpu(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;
extern "verve" fn gl_webgpu_available() i32;

// ── Module statics (all per-frame scratch lives here, not on the wasm stack) ──

var canvas_handle: ?i32 = null;
var use_webgpu: bool = false;
var resources_sent: bool = false;
var frozen: bool = false;
var yaw: f32 = 0;
/// Current tone-mapping operator (0–5). Cycles via gltonemap_cycle_tonemap().
var tonemap_op: u8 = 3; // default ACES
/// Vignette toggle. Off by default; gltonemap_toggle_vignette() flips it.
var vignette_on: bool = false;

// STABLE statics — wire records carry addresses; read after frame fn returns.
var mvp: [16]f32 = undefined;
var model_mat: [16]f32 = undefined;
var normal9: [9]f32 = undefined;
var camera_pos: [3]f32 = .{ 0, 0.0, 4.0 };

// Material: baseColor.rgba, [metallic, roughness, occlusion_strength, normal_scale],
// emissive.rgb, pad. Very high emissive (4.0 linear) so operators visibly differ.
var material: [12]f32 = .{ 0.05, 0.05, 0.1, 1, 0, 0.85, 1, 1, 4.0, 4.0, 4.0, 0 };

// Two lights: one directional (key), one point (fill). Bright key light (4.0)
// creates HDR headroom so operators respond differently.
// Layout: [type(0=dir), intensity, dir.x, dir.y, dir.z, color.r, color.g, color.b]
var lights: [16]f32 = .{
    // directional key light
    0, 4.0, -0.4, -0.7, -0.5, 1,   0.95, 0.9,
    // directional fill light (opposite direction, cooler, dimmer)
    0, 0.8, 0.5,  0.3,  0.8,  0.7, 0.8,  1.0,
};

// 1×1 white textures; emissive factor dominates.
const base_rgba = [_]u8{ 255, 255, 255, 255 };
const mr_rgba = [_]u8{ 255, 255, 255, 255 };
const occ_rgba = [_]u8{ 255, 255, 255, 255 };
const emis_rgba = [_]u8{ 255, 255, 255, 255 };

// cmd_buf: one-time creates (~200B) + per-frame post+scene (~400B) + header (4B).
// Round up to 4096 for headroom.
var cmd_buf: [4096]u8 = undefined;

// Post-processing persistent context (stable param buffers, shader/RT handles).
var post_ctx: gl.command.PostCtx = .{};

const vbuf_handle: u32 = 1;
const ibuf_handle: u32 = 2;
const shader_handle: u32 = 1;
const base_tex: u32 = 1;
const mr_tex: u32 = 2;
const occ_tex: u32 = 3;
const emis_tex: u32 = 4;

const frame_export = "gltonemap_frame";

// ── hydrate ───────────────────────────────────────────────────────────────────

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;

    resources_sent = false;
    frozen = false;
    yaw = 0;
    tonemap_op = 3; // ACES default
    vignette_on = false;
    post_ctx = .{};
    use_webgpu = gl_webgpu_available() != 0;
    canvas_handle = verve.queryRef(@as([]const u8, "gltonemap-canvas"));

    if (canvas_handle) |h| {
        if (use_webgpu)
            gl_start_gpu(h, frame_export.ptr, frame_export.len)
        else
            gl_start(h, frame_export.ptr, frame_export.len);
    }
}

// ── frame export ──────────────────────────────────────────────────────────────

export fn gltonemap_frame(dt_ms: f32, width: u32, height: u32) u32 {
    if (!frozen) yaw += dt_ms * 0.0006; // slow orbit

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
        gl.math.Quat.fromAxisAngle(gl.math.Vec3.init(0.3, 1, 0), yaw),
        gl.math.Vec3.init(1, 1, 1),
    );
    mvp = proj.mul(view).mul(model).m;
    model_mat = model.m;
    normal9 = gl.math.normalMatrix(model);

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

    // Map the static u8 operator index to the ToneMap enum.
    const tonemap: gl.command.ToneMap = @enumFromInt(tonemap_op);
    const vignette: ?gl.command.Vignette = if (vignette_on)
        .{ .intensity = 0.85, .radius = 0.65 }
    else
        null;

    enc.beginPostProcess(&post_ctx, .{
        .bloom = .{ .threshold = 1.0, .intensity = 0.9 },
        .fxaa = true,
        .webgpu = use_webgpu,
        .tonemap = tonemap,
        .vignette = vignette,
    }, width, height);

    enc.setPipeline(shader_handle, gl.command.state_depth_test | gl.command.state_cull_back);
    enc.setLights(2, @intCast(@intFromPtr(&lights)));
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

    enc.endPostProcess(&post_ctx);
    _ = enc.finish();
    return @intCast(@intFromPtr(&cmd_buf));
}

// ── controls (wired to /gl-tonemap buttons via z-on-click) ───────────────────

/// Advance the tone-mapping operator: 0→1→2→3→4→5→0.
/// The operator is sent via p_comp[1] every frame — no shader re-creation needed.
export fn gltonemap_cycle_tonemap() void {
    tonemap_op = (tonemap_op + 1) % 6;
}

/// Toggle vignette on/off.
export fn gltonemap_toggle_vignette() void {
    vignette_on = !vignette_on;
}

/// Freeze/unfreeze orbit (pin orientation for stable CDP frames).
export fn gltonemap_freeze() void {
    frozen = !frozen;
}
