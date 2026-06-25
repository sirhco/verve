//! verve.gl Weighted-Blended OIT demo — drives the /gl-oit canvas (image-quality
//! slice 6, the FINAL slice). Renders an OPAQUE backdrop (a couple of lit cubes)
//! plus several OVERLAPPING TRANSLUCENT quads (flattened cubes, alpha ~0.5) at
//! varying depth and color, arranged so they overlap heavily from the camera. The
//! frame pipeline (WBOIT on):
//!
//!   beginPostProcess(opens h_scene_hdr) → draw OPAQUE cubes (lit PBR) → close pass
//!   runOit(transparent quads → accum + reveal, then resolve over the opaque scene
//!          → h_scene_oit)                                  // WBOIT (this slice)
//!   composite(scene_src = h_scene_oit × AO + bloom) → canvas
//!
//! The defining property: rotating the camera does NOT change the translucent
//! overlap blend — WBOIT is ORDER-INDEPENDENT. Naive alpha blending (WBOIT off)
//! pops/flickers as the draw order vs camera order diverges.
//!
//! BACKEND PARITY (the riskiest point of the workstream): WebGPU fills accum +
//! reveal in ONE MRT pass (per-target blend); WebGL2 (no per-attachment blend)
//! replays the SAME transparent geometry in TWO single-target passes (accum:
//! ONE/ONE; reveal: ZERO/ONE_MINUS_SRC). The RESOLVE + weight MATH are identical,
//! so both backends produce the SAME composited image. `runOit` hides the
//! divergence — the island just builds a PER-OBJECT `OitDraw` list.
//!
//! STRUCTURE mirrors GlDof: singleton statics, send-once create block, STABLE
//! per-frame statics whose addresses ride the command stream, a frame export
//! returning cmd_buf. PER-OBJECT ARRAYS: the transparent mvp/mv/color and the
//! opaque mvp/model/normal/mv/material are `[N][..]f32` — a single shared static
//! rewritten in the draw loop would alias to the last value for EVERY draw (the
//! slice-4 black-scene bug). Reuses `gl.mesh.pbr_cube_vertices` (NO new assets).
//!
//! Controls (z-on-click → exports):
//!   gloit_toggle — WBOIT on/off (off → naive alpha-over blend, order-dependent)
//!   gloit_freeze — pin the orbit (CDP: observe the stable overlap, then unfreeze)

const verve = @import("verve");
const gl = verve.gl;

extern "verve" fn gl_start(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;
extern "verve" fn gl_start_gpu(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;
extern "verve" fn gl_webgpu_available() i32;

// ── Statics ───────────────────────────────────────────────────────────────────

var canvas_handle: ?i32 = null;
var use_webgpu: bool = false;
var resources_sent: bool = false;
var oit_on: bool = true;
var frozen: bool = false;
var yaw: f32 = 0;

// ── Opaque backdrop: two lit cubes placed CLEARLY BEHIND every translucent layer
// (the farthest translucent quad is at z = -2; the backdrop sits at z = -4) so the
// transparent depth-test vs the opaque scene depth is a no-op for ALL fragments.
// This keeps the WebGPU path (which depth-tests against the shared opaque depth)
// and the WebGL2 path (whose two single-target passes test against their own empty
// depth) producing the SAME image — the one place the depth-test could diverge. ──
const opaque_count: usize = 2;
const opaque_pos = [opaque_count][3]f32{
    .{ -1.3, 0.0, -4.0 },
    .{ 1.3, 0.0, -4.0 },
};
const opaque_color = [opaque_count][3]f32{
    .{ 0.85, 0.85, 0.85 },
    .{ 0.7, 0.75, 0.85 },
};

// ── Transparent layers: overlapping flattened cubes (quad-like), alpha ~0.5,
// stacked at increasing depth so they overlap heavily from the camera. Distinct
// colors so the order-independent blend is visually obvious. ──
const trans_count: usize = 5;
const trans_pos = [trans_count][3]f32{
    .{ 0.0, 0.0, 2.0 },
    .{ 0.0, 0.0, 1.0 },
    .{ 0.0, 0.0, 0.0 },
    .{ 0.0, 0.0, -1.0 },
    .{ 0.0, 0.0, -2.0 },
};
// Per-object rgba (a = alpha). PER-OBJECT array (aliasing rule, see header).
const trans_color = [trans_count][4]f32{
    .{ 1.0, 0.2, 0.2, 0.5 }, // red
    .{ 0.2, 1.0, 0.2, 0.5 }, // green
    .{ 0.2, 0.4, 1.0, 0.5 }, // blue
    .{ 1.0, 1.0, 0.2, 0.5 }, // yellow
    .{ 1.0, 0.2, 1.0, 0.5 }, // magenta
};

// STABLE statics — wire records carry their addresses; read after frame returns.
// Opaque PBR transforms.
var o_mvp: [opaque_count][16]f32 = undefined;
var o_model: [opaque_count][16]f32 = undefined;
var o_normal9: [opaque_count][9]f32 = undefined;
var o_mv: [opaque_count][16]f32 = undefined;
var o_material: [opaque_count][12]f32 = undefined;

// Transparent OIT transforms + per-object colors (the OitDraw pointers).
var t_mvp: [trans_count][16]f32 = undefined;
var t_mv: [trans_count][16]f32 = undefined;
var t_color: [trans_count][4]f32 = undefined;

var camera_pos: [3]f32 = .{ 0, 1.5, 10 };

// One directional light from above-front for the opaque backdrop.
var light: [8]f32 = .{ 0, 1.6, -0.3, -0.7, -0.5, 1, 1, 1 };

// 1×1 white maps (baseColor dominates the opaque cubes' appearance).
const base_rgba = [_]u8{ 255, 255, 255, 255 };
const mr_rgba = [_]u8{ 255, 255, 255, 255 };
const occ_rgba = [_]u8{ 255, 255, 255, 255 };
const emis_rgba = [_]u8{ 0, 0, 0, 255 };

var cmd_buf: [16384]u8 = undefined;

var post_ctx: gl.command.PostCtx = .{};
var oit_ctx: gl.command.OitCtx = .{};

// Per-object naive-blend material storage (WBOIT-off comparison path). The naive
// path draws the translucent cubes through the regular PBR blend pipeline, so
// each needs a full 12-f32 material slot (PER-OBJECT array — aliasing rule).
var naive_material: [trans_count][12]f32 = undefined;

const vbuf_cube: u32 = 1;
const ibuf_cube: u32 = 2;
const shader_handle: u32 = 1; // opaque PBR
const shader_blend: u32 = 3; // PBR for naive translucent (WBOIT-off)
const base_tex: u32 = 1;
const mr_tex: u32 = 2;
const occ_tex: u32 = 3;
const emis_tex: u32 = 4;

const frame_export = "gloit_frame";

// ── hydrate ───────────────────────────────────────────────────────────────────

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;

    resources_sent = false;
    oit_on = true;
    frozen = false;
    yaw = 0;
    post_ctx = .{};
    oit_ctx = .{};
    use_webgpu = gl_webgpu_available() != 0;
    canvas_handle = verve.queryRef(@as([]const u8, "gloit-canvas"));

    if (canvas_handle) |h| {
        if (use_webgpu)
            gl_start_gpu(h, frame_export.ptr, frame_export.len)
        else
            gl_start(h, frame_export.ptr, frame_export.len);
    }
}

// ── helpers ─────────────────────────────────────────────────────────────────

fn opaqueTransforms(i: usize, pos: [3]f32, view: gl.math.Mat4, proj: gl.math.Mat4) void {
    const model = gl.math.Mat4.fromTrs(
        gl.math.Vec3.init(pos[0], pos[1], pos[2]),
        gl.math.Quat.fromAxisAngle(gl.math.Vec3.init(0, 1, 0), 0),
        gl.math.Vec3.init(0.7, 0.7, 0.7),
    );
    o_mvp[i] = proj.mul(view).mul(model).m;
    o_model[i] = model.m;
    o_normal9[i] = gl.math.normalMatrix(model);
    o_mv[i] = view.mul(model).m;
    // Bright low-roughness dielectric, opaque.
    o_material[i] = .{ opaque_color[i][0], opaque_color[i][1], opaque_color[i][2], 1, 0, 0.5, 1, 1, 0, 0, 0, 0 };
}

fn transTransforms(i: usize, pos: [3]f32, view: gl.math.Mat4, proj: gl.math.Mat4) void {
    // Flattened cube → a thin translucent quad facing the camera plane.
    const model = gl.math.Mat4.fromTrs(
        gl.math.Vec3.init(pos[0], pos[1], pos[2]),
        gl.math.Quat.fromAxisAngle(gl.math.Vec3.init(0, 1, 0), 0),
        gl.math.Vec3.init(1.6, 1.6, 0.08),
    );
    t_mvp[i] = proj.mul(view).mul(model).m;
    t_mv[i] = view.mul(model).m;
    t_color[i] = trans_color[i];
    // Naive-blend material: baseColor rgb + alpha (PER-OBJECT; aliasing rule).
    naive_material[i] = .{ trans_color[i][0], trans_color[i][1], trans_color[i][2], trans_color[i][3], 0, 0.6, 1, 1, 0, 0, 0, 0 };
}

// ── frame export ──────────────────────────────────────────────────────────────

export fn gloit_frame(dt_ms: f32, width: u32, height: u32) u32 {
    if (!frozen) yaw += dt_ms * 0.0004; // slow orbit (freeze pins for CDP metrics)

    const aspect = @as(f32, @floatFromInt(width)) /
        @as(f32, @floatFromInt(@max(height, 1)));
    // far = 100.0 matches the OIT weight's baked OIT_FAR constant.
    const proj = gl.math.Mat4.perspective(0.9, aspect, 0.1, 100.0);
    const r: f32 = 9.0;
    const cx = @sin(yaw) * r;
    const cz = @cos(yaw) * r;
    camera_pos = .{ cx, 1.5, cz };
    const view = gl.math.Mat4.lookAt(
        gl.math.Vec3.init(camera_pos[0], camera_pos[1], camera_pos[2]),
        gl.math.Vec3.init(0, 0, 0),
        gl.math.Vec3.init(0, 1, 0),
    );

    for (opaque_pos, 0..) |p, i| opaqueTransforms(i, p, view, proj);
    for (trans_pos, 0..) |p, i| transTransforms(i, p, view, proj);

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
            enc.createShader(shader_blend, scene_variant, @intCast(@intFromPtr(w.ptr)), @intCast(w.len), 0, 0);
        } else {
            const vs = C.pbrVertexSrc(scene_variant);
            const fs = C.pbrFragmentSrc(scene_variant);
            enc.createShader(shader_handle, scene_variant, @intCast(@intFromPtr(vs.ptr)), @intCast(vs.len), @intCast(@intFromPtr(fs.ptr)), @intCast(fs.len));
            enc.createShader(shader_blend, scene_variant, @intCast(@intFromPtr(vs.ptr)), @intCast(vs.len), @intCast(@intFromPtr(fs.ptr)), @intCast(fs.len));
        }
        enc.createTextureSrgb(base_tex, 1, 1, @intCast(@intFromPtr(&base_rgba)), @intCast(base_rgba.len));
        enc.createTexture(mr_tex, 1, 1, @intCast(@intFromPtr(&mr_rgba)), @intCast(mr_rgba.len));
        enc.createTexture(occ_tex, 1, 1, @intCast(@intFromPtr(&occ_rgba)), @intCast(occ_rgba.len));
        enc.createTextureSrgb(emis_tex, 1, 1, @intCast(@intFromPtr(&emis_rgba)), @intCast(emis_rgba.len));
    }

    // ── 1. Scene → h_scene_hdr (lit PBR opaque backdrop). beginPostProcess opens
    // the HDR pass. When WBOIT is on, the composite reads the resolved
    // h_scene_oit; off → reads h_scene_hdr (which then also carries the naive
    // translucent cubes drawn below). ──
    enc.beginPostProcess(&post_ctx, .{
        .bloom = .{ .threshold = 1.2, .intensity = 0.3 },
        .fxaa = true,
        .webgpu = use_webgpu,
        .scene_src = if (oit_on) C.OitCtx.h_scene_oit else 0,
    }, width, height);

    // Opaque backdrop (depth-write ON).
    enc.setPipeline(shader_handle, C.state_depth_test | C.state_cull_back);
    enc.setLights(1, @intCast(@intFromPtr(&light)));
    var oi: usize = 0;
    while (oi < opaque_count) : (oi += 1) {
        enc.bindTexture(C.tex_slot_base, base_tex);
        enc.bindTexture(C.tex_slot_mr, mr_tex);
        enc.bindTexture(C.tex_slot_emissive, emis_tex);
        enc.bindTexture(C.tex_slot_occlusion, occ_tex);
        enc.drawPbr(
            vbuf_cube,
            ibuf_cube,
            0,
            @intCast(gl.mesh.pbr_cube_indices.len),
            @intCast(@intFromPtr(&o_mvp[oi])),
            @intCast(@intFromPtr(&o_model[oi])),
            @intCast(@intFromPtr(&o_normal9[oi])),
            @intCast(@intFromPtr(&o_material[oi])),
            @intCast(@intFromPtr(&camera_pos)),
        );
    }

    if (!oit_on) {
        // ── WBOIT OFF: naive alpha-over blend into the same HDR scene, in array
        // order (order-DEPENDENT — pops as the camera rotates). For contrast. ──
        enc.setPipeline(shader_blend, C.state_depth_test | C.state_blend);
        var ni: usize = 0;
        while (ni < trans_count) : (ni += 1) {
            enc.bindTexture(C.tex_slot_base, base_tex);
            enc.bindTexture(C.tex_slot_mr, mr_tex);
            enc.bindTexture(C.tex_slot_emissive, emis_tex);
            enc.bindTexture(C.tex_slot_occlusion, occ_tex);
            enc.drawPbr(
                vbuf_cube,
                ibuf_cube,
                0,
                @intCast(gl.mesh.pbr_cube_indices.len),
                @intCast(@intFromPtr(&t_mvp[ni])),
                @intCast(@intFromPtr(&o_model[0])), // model unused for shading color here
                @intCast(@intFromPtr(&o_normal9[0])),
                @intCast(@intFromPtr(&naive_material[ni])),
                @intCast(@intFromPtr(&camera_pos)),
            );
        }
    }

    // Close the scene HDR pass so the OIT resolve (+ bloom/composite) can SAMPLE
    // h_scene_hdr as a texture.
    enc.endOffscreenPass();

    // ── 2. WBOIT: transparent quads → accum + reveal → resolve over opaque. ──
    if (oit_on) {
        var draws: [trans_count]C.OitDraw = undefined;
        var di: usize = 0;
        while (di < trans_count) : (di += 1) {
            draws[di] = .{
                .vbuf = vbuf_cube,
                .ibuf = ibuf_cube,
                .index_byte_off = 0,
                .index_count = @intCast(gl.mesh.pbr_cube_indices.len),
                .mvp_ptr = @intCast(@intFromPtr(&t_mvp[di])),
                .mv_ptr = @intCast(@intFromPtr(&t_mv[di])),
                .color_ptr = @intCast(@intFromPtr(&t_color[di])),
            };
        }
        enc.runOit(&oit_ctx, use_webgpu, width, height, &draws);
    }

    // ── 3. bloom bright-pass + composite + fxaa, reading scene_src (set above). ──
    enc.endPostProcess(&post_ctx, false);
    _ = enc.finish();
    return @intCast(@intFromPtr(&cmd_buf));
}

// ── controls (wired to /gl-oit buttons via z-on-click) ──────────────────────

export fn gloit_toggle() void {
    oit_on = !oit_on;
}

export fn gloit_freeze() void {
    frozen = !frozen;
}
