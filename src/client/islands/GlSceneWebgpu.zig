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
// Asset fetch (backend-agnostic): fetches a URL, calls the named export with the
// loaded bytes (ptr/len). Shared with GlScene's env path.
extern "verve" fn gl_load(url_ptr: [*]const u8, url_len: u32, cb_ptr: [*]const u8, cb_len: u32) void;

// ── Statics ─────────────────────────────────────────────────────────────────

var canvas_handle: ?i32 = null;
var yaw: f32 = 0;
var resources_sent: bool = false;
// IBL environment (P10 2b): fetched async via gl_load; the create_texture_ex
// uploads are emitted once `env_reader` resolves (gated by `ibl_sent`), then
// `bindIbl` is re-emitted each frame. The Reader holds slices into the page
// asset region, which stays valid for this single-instance chunk's lifetime.
var env_reader: ?gl.venv.Reader = null;
var ibl_sent: bool = false;

// STABLE statics — drawPbr records their addresses; the bridge reads them after
// the frame fn returns, so they must outlive the call (exactly like GlScene's
// per-submesh pools, here a single instance so plain module statics suffice).
var mvp: [16]f32 = undefined;
var model_mat: [16]f32 = undefined;
var normal9: [9]f32 = undefined;
var camera_pos: [3]f32 = .{ 3, 3.5, 6 };
// Material block: baseColor.rgba, [metallic, roughness, occlusion, normalScale],
// emissive.rgb, pad. Metallic + low roughness so the IBL environment shows as
// reflections (metals tint the reflection by the base-color texture).
var material: [12]f32 = .{ 1, 1, 1, 1, 0, 0.5, 1, 1, 0, 0, 0, 0 };
// One directional light: [type(0=dir), intensity, dir.xyz, color.rgb].
var light: [8]f32 = .{ 0, 3, -0.4, -0.7, -0.6, 1, 1, 1 };

// Ground plane (shadow receiver): matte dielectric so the shadow reads clearly.
var plane_mvp: [16]f32 = undefined;
var plane_model: [16]f32 = undefined;
var plane_normal9: [9]f32 = undefined;
var plane_material: [12]f32 = .{ 0.8, 0.8, 0.8, 1, 0, 0.9, 1, 1, 0, 0, 0, 0 };

// Shadow pass (STABLE statics — the wire records their addresses):
//   light_vp      = Zfix · ortho · lookAt (WebGPU [0,1]-z light matrix); the
//                   PBR vertex shader applies ·model, so this is the raw light VP.
//   depth_mvp_*   = light_vp · model, fed to the depth-only draw per object.
var light_vp: [16]f32 = undefined;
var depth_mvp_cube: [16]f32 = undefined;
var depth_mvp_plane: [16]f32 = undefined;

// 2×2 sRGB base-color checker (orange / slate) so the UV texturing is visible.
const base_rgba = [_]u8{
    220, 120, 40, 255, 60,  60,  70, 255,
    60,  60,  70, 255, 220, 120, 40, 255,
};
// 1×1 metallic-roughness, white — the material factors (metallic 0, roughness
// 0.5) dominate (glTF packs roughness in G, metallic in B; factor × texel).
const mr_rgba = [_]u8{ 255, 255, 255, 255 };

// cmd_buf: one-time mesh creates (≈ 160 B) + one-time IBL creates (3×
// createTextureEx ≈ 110 B) + per-frame beginFrame/setPipeline/setLights/bindIbl/
// 2×bindTexture/drawPbr/endFrame (≈ 150 B). Round generously to 1024.
var cmd_buf: [1024]u8 = undefined;

const vbuf_handle: u32 = 1;
const ibuf_handle: u32 = 2;
const shader_handle: u32 = 1;
const base_tex: u32 = 1;
const mr_tex: u32 = 2;
// IBL texture handles — distinct from base/mr (textures live in their own bridge
// handle space; 16/17/18 mirror GlScene's irr/spec/lut handles).
const irr_handle: u32 = 16;
const spec_handle: u32 = 17;
const lut_handle: u32 = 18;
// Ground-plane receiver buffers (own buffer-handle space) + shadow resources.
const plane_vbuf_handle: u32 = 3;
const plane_ibuf_handle: u32 = 4;
const depth_shader: u32 = 5; // variant_depth program (separate shader space)
const shadow_handle: u32 = 1; // shadow map (separate shadowMaps space)
const shadow_size: u32 = 1024;
const frame_export = "glscenewebgpu_frame";
const env_ready_export = "glscenewebgpu_env_ready";
const env_url = "/gl/studio.venv";

// Directional light view-projection for the shadow pass. `gl.math` ortho/lookAt
// are GL-convention (clip z ∈ [−1,1]); WebGPU clips z<0 and stores depth in [0,1],
// so premultiply Zfix (row 2 = [0,0,0.5,0.5]) to remap clip z → [0,1]. The WGSL
// shadowFactor then uses ndc.z directly (see command.zig wgslPbr fs_shadow_decl).
fn computeLightVp() gl.math.Mat4 {
    const dir = gl.math.Vec3.normalize(gl.math.Vec3.init(light[2], light[3], light[4]));
    const center = gl.math.Vec3.init(0, -0.5, 0);
    const eye = gl.math.Vec3.sub(center, gl.math.Vec3.scale(dir, 8.0));
    const view = gl.math.Mat4.lookAt(eye, center, gl.math.Vec3.init(0, 1, 0));
    const proj = gl.math.Mat4.ortho(-4, 4, -4, 4, 0.1, 20);
    var zfix = gl.math.Mat4{ .m = [_]f32{0} ** 16 };
    zfix.m[0] = 1;
    zfix.m[5] = 1;
    zfix.m[10] = 0.5;
    zfix.m[14] = 0.5;
    zfix.m[15] = 1;
    return zfix.mul(proj).mul(view);
}

// ── hydrate ─────────────────────────────────────────────────────────────────

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;

    resources_sent = false;
    ibl_sent = false;
    env_reader = null;
    yaw = 0;
    canvas_handle = verve.queryRef(@as([]const u8, "glscenewebgpu-canvas"));

    // Start the WebGPU rAF loop. Create commands are emitted send-once inside the
    // first frame (guarded by resources_sent), exactly like GlWebgpu.
    if (canvas_handle) |h|
        gl_start_gpu(h, frame_export.ptr, frame_export.len);

    // Fetch the prefiltered IBL environment; createTextureEx + bindIbl follow once
    // the bytes land (glscenewebgpu_env_ready).
    gl_load(env_url.ptr, env_url.len, env_ready_export.ptr, env_ready_export.len);
}

// ── asset-ready callback ──────────────────────────────────────────────────────

export fn glscenewebgpu_env_ready(ptr: u32, len: u32) void {
    if (ptr == 0) return; // fetch failed → stay direct-lit (black IBL defaults)
    const bytes = @as([*]const u8, @ptrFromInt(@as(usize, ptr)))[0..len];
    env_reader = gl.venv.Reader.init(bytes) catch null;
}

// ── frame export ──────────────────────────────────────────────────────────────

export fn glscenewebgpu_frame(dt_ms: f32, width: u32, height: u32) u32 {
    yaw += dt_ms * 0.001; // ~1 rad/s

    const aspect = @as(f32, @floatFromInt(width)) /
        @as(f32, @floatFromInt(@max(height, 1)));
    const proj = gl.math.Mat4.perspective(1.0, aspect, 0.1, 100.0);
    const view = gl.math.Mat4.lookAt(
        gl.math.Vec3.init(camera_pos[0], camera_pos[1], camera_pos[2]),
        gl.math.Vec3.init(0, -0.3, 0),
        gl.math.Vec3.init(0, 1, 0),
    );
    const model = gl.math.Mat4.fromTrs(
        gl.math.Vec3.init(0, 0.3, 0),
        gl.math.Quat.fromAxisAngle(gl.math.Vec3.init(0, 1, 0), yaw),
        gl.math.Vec3.init(1, 1, 1),
    );
    mvp = proj.mul(view).mul(model).m;
    model_mat = model.m;
    normal9 = gl.math.normalMatrix(model);

    // Ground plane: a large flat quad below the cube (static).
    const pmodel = gl.math.Mat4.fromTrs(
        gl.math.Vec3.init(0, -1.2, 0),
        gl.math.Quat.fromAxisAngle(gl.math.Vec3.init(0, 1, 0), 0),
        gl.math.Vec3.init(4, 1, 4),
    );
    plane_mvp = proj.mul(view).mul(pmodel).m;
    plane_model = pmodel.m;
    plane_normal9 = gl.math.normalMatrix(pmodel);

    // Light-space matrices for the shadow pass (depth = light_vp·model per object;
    // the receiver shader applies ·model itself, so bind_shadow_map gets light_vp).
    const lvp = computeLightVp();
    light_vp = lvp.m;
    depth_mvp_cube = lvp.mul(model).m;
    depth_mvp_plane = lvp.mul(pmodel).m;

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
        // Ground-plane receiver buffers.
        enc.createBuffer(
            plane_vbuf_handle,
            .vertex,
            @intCast(@intFromPtr(&gl.mesh.pbr_plane_vertices)),
            @sizeOf(@TypeOf(gl.mesh.pbr_plane_vertices)),
        );
        enc.createBuffer(
            plane_ibuf_handle,
            .index,
            @intCast(@intFromPtr(&gl.mesh.pbr_plane_indices)),
            @sizeOf(@TypeOf(gl.mesh.pbr_plane_indices)),
        );
        // PBR shadow-receiver shader (one WGSL module, both stages).
        const wgsl = gl.command.wgslPbr(gl.command.variant_pbr | gl.command.variant_shadow);
        enc.createShader(
            shader_handle,
            gl.command.variant_pbr | gl.command.variant_shadow,
            @intCast(@intFromPtr(wgsl.ptr)),
            @intCast(wgsl.len),
            0,
            0,
        );
        // Depth-only shader for the shadow pass + the shadow map target.
        const dwgsl = gl.command.wgslDepth();
        enc.createShader(
            depth_shader,
            gl.command.variant_depth,
            @intCast(@intFromPtr(dwgsl.ptr)),
            @intCast(dwgsl.len),
            0,
            0,
        );
        enc.createShadowMap(shadow_handle, shadow_size);
        // Base color is sRGB (hardware decode); MR stays linear.
        enc.createTextureSrgb(base_tex, 2, 2, @intCast(@intFromPtr(&base_rgba)), @intCast(base_rgba.len));
        enc.createTexture(mr_tex, 1, 1, @intCast(@intFromPtr(&mr_rgba)), @intCast(mr_rgba.len));
    }
    // One-time IBL upload once the .venv environment has loaded: irradiance cube,
    // prefiltered specular mip-chain, BRDF LUT — all RGBA16F (mirror GlScene).
    if (env_reader != null and !ibl_sent) {
        ibl_sent = true;
        const env = &env_reader.?;
        enc.createTextureEx(irr_handle, .cube, .rgba16f, env.irr_size, env.irr_size, 1, @intCast(@intFromPtr(env.irradiance.ptr)), @intCast(env.irradiance.len));
        enc.createTextureEx(spec_handle, .cube, .rgba16f, env.spec_size, env.spec_size, env.spec_mip_count, @intCast(@intFromPtr(env.specular.ptr)), @intCast(env.specular.len));
        enc.createTextureEx(lut_handle, .tex_2d, .rgba16f, env.lut_size, env.lut_size, 1, @intCast(@intFromPtr(env.lut.ptr)), @intCast(env.lut.len));
    }
    // ── shadow depth pass (light's POV) — MUST precede the color pass ──
    enc.beginShadowPass(shadow_handle, depth_shader, shadow_size);
    enc.drawDepth(vbuf_handle, ibuf_handle, 0, @intCast(gl.mesh.pbr_cube_indices.len), @intCast(@intFromPtr(&depth_mvp_cube)));
    enc.drawDepth(plane_vbuf_handle, plane_ibuf_handle, 0, @intCast(gl.mesh.pbr_plane_indices.len), @intCast(@intFromPtr(&depth_mvp_plane)));
    enc.endShadowPass(width, height);

    // ── color pass ──
    enc.beginFrame(.{ 0.05, 0.06, 0.09, 1.0 }, width, height);
    enc.setPipeline(shader_handle, gl.command.state_depth_test | gl.command.state_cull_back);
    enc.setLights(1, @intCast(@intFromPtr(&light)));
    if (ibl_sent) enc.bindIbl(irr_handle, spec_handle, lut_handle, env_reader.?.spec_mip_count);
    enc.bindShadowMap(gl.command.tex_slot_shadow, shadow_handle, @intCast(@intFromPtr(&light_vp)));
    // Cube (metallic, textured).
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
    // Ground plane (matte receiver; same bound textures, plane material).
    enc.drawPbr(
        plane_vbuf_handle,
        plane_ibuf_handle,
        0,
        @intCast(gl.mesh.pbr_plane_indices.len),
        @intCast(@intFromPtr(&plane_mvp)),
        @intCast(@intFromPtr(&plane_model)),
        @intCast(@intFromPtr(&plane_normal9)),
        @intCast(@intFromPtr(&plane_material)),
        @intCast(@intFromPtr(&camera_pos)),
    );
    enc.endFrame();
    _ = enc.finish();
    return @intCast(@intFromPtr(&cmd_buf));
}
