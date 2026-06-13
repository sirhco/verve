//! verve.gl demo chunk — drives BOTH /gl canvases (unlit cube + textured model).
//!
//! WHY ONE CHUNK: per-island wasm chunks import the main client's linear
//! memory and each chunk links its static data starting at the same base
//! (0x1000). Two stateful chunks on the same page — GlCube + GlModel —
//! overlap: GlModel's data segments clobber GlCube's scn/cmd_buf/rodata,
//! causing the cube canvas to go blank (0x1000 data-segment collision).
//! The framework invariant (build.zig ~line 165) requires at most ONE
//! stateful chunk per page; merging them here satisfies that constraint.
//!
//! STRUCTURE: two independent sets of statics (cube_* and model_*), two
//! frame exports with their original names (`glcube_frame` / `glmodel_frame`),
//! a single `hydrate` that initialises both and starts each loop
//! independently — a missing canvas does not disable the other.
//!
//! Multi-instance: singleton statics, same documented choice as Counter.zig.
//! Namespace by root_id if a future page ever needs two cubes or two models.

const verve = @import("verve");
const gl = verve.gl;

extern "verve" fn gl_start(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;
extern "verve" fn gl_load(url_ptr: [*]const u8, url_len: u32, cb_ptr: [*]const u8, cb_len: u32) void;

// ── Cube statics ────────────────────────────────────────────────────────────

const SceneT = gl.Scene(8);

var cube_scn: SceneT = .{};
var cube_node: u32 = 0;
var cube_angle: f32 = 0;
var cube_resources_sent: bool = false;
var cube_mvp: [16]f32 = undefined;
var cube_cmd_buf: [512]u8 = undefined;

const cube_vbuf_handle: u32 = 1;
const cube_ibuf_handle: u32 = 2;
const cube_shader_handle: u32 = 1;
const cube_frame_export = "glcube_frame";

// ── Model statics ───────────────────────────────────────────────────────────

var model_scn: SceneT = .{};
var model_node: u32 = 0;
var model_angle: f32 = 0;
var model_asset: ?gl.vmesh.Reader = null;
var model_env: ?gl.venv.Reader = null;
var model_resources_sent: bool = false;
var model_mvp: [16]f32 = undefined;
var model_model_mat: [16]f32 = undefined; // node world matrix (column-major), stable static for drawPbr
var model_normal9: [9]f32 = undefined; // inverse-transpose upper-3x3, column-major
var model_camera: [3]f32 = .{ 0, 1.2, 4 }; // MUST equal the lookAt eye used in glmodel_frame below

// Per-submesh material block pool (cap 8). Each drawPbr points at its own
// stable slot (model_mats[s]) so the JS interpreter reads the correct 12-f32
// material block when it walks the command stream — a single shared block
// would leave only the LAST submesh's material visible (same latent-aliasing
// reason as the P1 color pool). Slots stay stable for the frame.
var model_mats: [8][12]f32 = undefined;

// Direct lights, 8 f32 each: [type(0=dir,1=point), intensity, x,y,z, r,g,b].
// dir-light direction literal (-0.4,-0.7,-0.6) is normalized by hand:
//   len = sqrt(0.16+0.49+0.36) = sqrt(1.01) ≈ 1.00498756
//   (-0.4,-0.7,-0.6)/len = (-0.39801488, -0.69652603, -0.59702231)
var model_lights: [16]f32 = .{
    // dir light: warm key from above-front
    0.0, 3.0, // type=dir, intensity=3.0
    -0.39801488, -0.69652603, -0.59702231, // normalized direction
    1.0, 0.97, 0.92, // color
    // point light: cool fill
    1.0, 8.0, // type=point, intensity=8.0
    2.0, 1.5, 2.0, // position
    0.9, 0.95, 1.0, // color
};

// cmd_buf sizing (N = 8 submesh cap). Record = 4-byte tag/size header + payload.
//   one-time send:
//     2×createBuffer(4+16=20) + createShader(4+24=28)
//     + 5×createTexture(4+20=24) + 3×createTextureEx(4+32=36)
//     = 40 + 28 + 120 + 108 = 296
//   per-frame:
//     header(4) + beginFrame(4+24=28) + setPipeline(4+8=12)
//     + setLights(4+8=12) + bindIbl(4+16=20)
//     + N×(5×bindTexture(4+8=12) + drawPbr(4+36=40)) = 8×(60+40) = 800
//     + endFrame(4)
//     = 4 + 28 + 12 + 12 + 20 + 800 + 4 = 880
//   worst case (one-time + per-frame on the same first frame) = 296 + 880 = 1176
//   round up generously to 4096.
var model_cmd_buf: [4096]u8 = undefined;

const model_vbuf: u32 = 1;
const model_ibuf: u32 = 2;
const model_shader: u32 = 1;
const model_url = "/gl/demo.vmesh";
const model_env_url = "/gl/studio.venv";
const model_ready_export = "glmodel_ready";
const model_env_ready_export = "glmodel_env_ready";
const model_frame_export = "glmodel_frame";

// IBL texture handles (distinct from per-material texture handles t+1, which
// range 1..5 from the v2 vmesh).
const irr_handle: u32 = 16;
const spec_handle: u32 = 17;
const lut_handle: u32 = 18;

// Comptime PBR variant: full Cook-Torrance + IBL + tangent-space normals + emissive.
const pbr_variant = gl.command.variant_pbr | gl.command.variant_normal_map | gl.command.variant_emissive;

// ── Context-restore exports ──────────────────────────────────────────────────
//
// On webglcontextrestored the bridge calls `<frame_export>_restore` before
// resuming the rAF loop (Task 9 convention, bridge verve.js ~line 4636).
// Resetting the sent flag causes the next frame to re-issue all CREATE_*
// commands with the same handle IDs — safe because the JS resource arrays
// were wiped when the context was lost, so overwriting the same slots is
// correct (no live-context leak; the old objects are already dead).
//
// model_asset / model_env (vmesh/venv Readers) are NOT reset: the asset bytes
// live in the WASM linear-memory asset region for the page lifetime, so the
// Reader slices remain valid. Only the GPU-side objects need re-uploading.
// The existing model_resources_sent guard already gates GPU sends, so
// clearing it is the complete and correct restore action.
//
// Registry (Registry(cap)) is intentionally absent from GlDemo: recording
// alongside every create* would be dead weight because GlDemo's restore
// path re-runs the original create block naturally (flag → false → block
// executes on next frame). Registry.replay() earns its keep in GlScene
// (Task 12) where the create block runs once at startup and replay is the
// only way to re-emit those creates on restore.

export fn glcube_frame_restore() void {
    // Re-run the one-time create block on the next glcube_frame tick.
    cube_resources_sent = false;
}

export fn glmodel_frame_restore() void {
    // Re-run the one-time create block on the next glmodel_frame tick
    // (only fires when model_asset and model_env are both non-null, which
    // they will be — the asset-region bytes are still valid after restore).
    model_resources_sent = false;
}

// ── hydrate ─────────────────────────────────────────────────────────────────

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;

    // This island owns the page's gl asset lifetime (single stateful gl island
    // per page invariant). Free any assets fetched by a prior hydrate before we
    // re-fetch — the venv/vmesh Reader slices below point into the asset region.
    verve.assetReset();

    // Reset cube state.
    cube_scn = .{};
    cube_node = cube_scn.addNode(-1, "cube");
    cube_resources_sent = false;
    cube_angle = 0;

    // Reset model state.
    model_scn = .{};
    model_node = model_scn.addNode(-1, "model");
    model_asset = null;
    model_env = null;
    model_resources_sent = false;
    model_angle = 0;

    // Kick the asset fetches for the model canvas (geometry + prefiltered IBL).
    gl_load(model_url.ptr, model_url.len, model_ready_export.ptr, model_ready_export.len);
    gl_load(model_env_url.ptr, model_env_url.len, model_env_ready_export.ptr, model_env_ready_export.len);

    // Start each rAF loop independently — a missing canvas must not disable
    // the other, so we use separate optional checks rather than a shared return.
    if (verve.queryRef(@as([]const u8, "glcube-canvas"))) |h|
        gl_start(h, cube_frame_export.ptr, cube_frame_export.len);

    if (verve.queryRef(@as([]const u8, "glmodel-canvas"))) |h|
        gl_start(h, model_frame_export.ptr, model_frame_export.len);
}

// ── Cube frame export ────────────────────────────────────────────────────────

export fn glcube_frame(dt_ms: f32, width: u32, height: u32) u32 {
    cube_angle += dt_ms * 0.001; // ~1 rad/s
    cube_scn.setRotation(cube_node, gl.math.Quat.fromAxisAngle(
        gl.math.Vec3.init(0.3, 1, 0),
        cube_angle,
    ));
    cube_scn.updateWorld();

    const aspect = @as(f32, @floatFromInt(width)) /
        @as(f32, @floatFromInt(@max(height, 1)));
    const proj = gl.math.Mat4.perspective(1.0, aspect, 0.1, 100.0);
    const view = gl.math.Mat4.lookAt(
        gl.math.Vec3.init(0, 1.5, 5),
        gl.math.Vec3.init(0, 0, 0),
        gl.math.Vec3.init(0, 1, 0),
    );
    cube_mvp = proj.mul(view).mul(cube_scn.world[cube_node]).m;

    var enc = gl.Encoder.init(&cube_cmd_buf);
    if (!cube_resources_sent) {
        cube_resources_sent = true;
        enc.createBuffer(
            cube_vbuf_handle,
            .vertex,
            @intCast(@intFromPtr(&gl.mesh.cube_vertices)),
            @sizeOf(@TypeOf(gl.mesh.cube_vertices)),
        );
        enc.createBuffer(
            cube_ibuf_handle,
            .index,
            @intCast(@intFromPtr(&gl.mesh.cube_indices)),
            @sizeOf(@TypeOf(gl.mesh.cube_indices)),
        );
        enc.createShader(
            cube_shader_handle,
            gl.command.variant_vertex_color,
            @intCast(@intFromPtr(gl.command.unlit_vs.ptr)),
            @intCast(gl.command.unlit_vs.len),
            @intCast(@intFromPtr(gl.command.unlit_fs.ptr)),
            @intCast(gl.command.unlit_fs.len),
        );
    }
    enc.beginFrame(.{ 0.07, 0.07, 0.1, 1.0 }, width, height);
    enc.setPipeline(cube_shader_handle, gl.command.state_depth_test | gl.command.state_cull_back);
    enc.draw(cube_vbuf_handle, cube_ibuf_handle, gl.mesh.cube_indices.len, @intCast(@intFromPtr(&cube_mvp)));
    enc.endFrame();
    _ = enc.finish();
    return @intCast(@intFromPtr(&cube_cmd_buf));
}

// ── Model ready + frame exports ──────────────────────────────────────────────

export fn glmodel_ready(ptr: u32, len: u32) void {
    if (ptr == 0) return; // fetch failed; stay on clear-only frames
    const bytes = @as([*]const u8, @ptrFromInt(ptr))[0..len];
    model_asset = gl.vmesh.Reader.init(bytes) catch null;
}

export fn glmodel_env_ready(ptr: u32, len: u32) void {
    if (ptr == 0) return; // fetch failed; leave model_env null → clear-only frames
    const bytes = @as([*]const u8, @ptrFromInt(ptr))[0..len];
    // Defensive parity with glmodel_ready: bad bytes leave model_env null.
    model_env = gl.venv.Reader.init(bytes) catch null;
}

/// vmesh texture index → wire texture handle (table slot t gets handle t+1).
/// Negative indices clamp to handle 0 (never created) instead of trapping.
fn texHandle(i: i32) u32 {
    return if (i >= 0) @intCast(i + 1) else 0;
}

export fn glmodel_frame(dt_ms: f32, width: u32, height: u32) u32 {
    model_angle += dt_ms * 0.0005;
    model_scn.setRotation(model_node, gl.math.Quat.fromAxisAngle(gl.math.Vec3.init(0, 1, 0.2), model_angle));
    model_scn.updateWorld();
    const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(@max(height, 1)));
    const proj = gl.math.Mat4.perspective(1.0, aspect, 0.1, 100.0);
    const view = gl.math.Mat4.lookAt(
        gl.math.Vec3.init(0, 1.2, 4), // eye — keep in lockstep with model_camera
        gl.math.Vec3.init(0, 0, 0),
        gl.math.Vec3.init(0, 1, 0),
    );
    const world = model_scn.world[model_node];
    model_mvp = proj.mul(view).mul(world).m;

    var enc = gl.Encoder.init(&model_cmd_buf);

    // Full PBR only when BOTH geometry and the prefiltered environment are
    // loaded; otherwise fall back to today's clear-only frame.
    if (model_asset != null and model_env != null) {
        const a = &model_asset.?;
        const env = &model_env.?;

        if (!model_resources_sent) {
            model_resources_sent = true;
            enc.createBuffer(model_vbuf, .vertex, @intCast(@intFromPtr(a.vertices.ptr)), @intCast(a.vertices.len));
            enc.createBuffer(model_ibuf, .index, @intCast(@intFromPtr(a.indices.ptr)), @intCast(a.indices.len));
            // Comptime PBR über-shader — VS/FS assembled at comptime for pbr_variant.
            const vs = gl.command.pbrVertexSrc(pbr_variant);
            const fs = gl.command.pbrFragmentSrc(pbr_variant);
            enc.createShader(
                model_shader,
                pbr_variant,
                @intCast(@intFromPtr(vs.ptr)),
                @intCast(vs.len),
                @intCast(@intFromPtr(fs.ptr)),
                @intCast(fs.len),
            );
            // Material textures (up to 5 from the v2 vmesh): handle = t+1.
            // base-color / emissive → sRGB (hardware decode); rest linear.
            var t: u32 = 0;
            while (t < a.tex_count) : (t += 1) {
                const tex = a.texture(t);
                const ptr: u32 = @intCast(@intFromPtr(tex.rgba.ptr));
                const len: u32 = @intCast(tex.rgba.len);
                if (a.texIsSrgb(t))
                    enc.createTextureSrgb(t + 1, tex.width, tex.height, ptr, len)
                else
                    enc.createTexture(t + 1, tex.width, tex.height, ptr, len);
            }
            // IBL: irradiance cube, prefiltered specular mip-chain, BRDF LUT.
            enc.createTextureEx(irr_handle, .cube, .rgba16f, env.irr_size, env.irr_size, 1, @intCast(@intFromPtr(env.irradiance.ptr)), @intCast(env.irradiance.len));
            enc.createTextureEx(spec_handle, .cube, .rgba16f, env.spec_size, env.spec_size, env.spec_mip_count, @intCast(@intFromPtr(env.specular.ptr)), @intCast(env.specular.len));
            enc.createTextureEx(lut_handle, .tex_2d, .rgba16f, env.lut_size, env.lut_size, 1, @intCast(@intFromPtr(env.lut.ptr)), @intCast(env.lut.len));
        }

        // Per-draw matrices: copy out to stable statics (drawPbr records carry
        // their addresses, same stability requirement as model_mvp).
        model_model_mat = world.m;
        model_normal9 = gl.math.normalMatrix(world);

        enc.beginFrame(.{ 0.05, 0.06, 0.09, 1.0 }, width, height);
        enc.setPipeline(model_shader, gl.command.state_depth_test | gl.command.state_cull_back);
        // Stream order: SET_PIPELINE must precede SET_LIGHTS / BIND_IBL.
        enc.setLights(2, @intCast(@intFromPtr(&model_lights)));
        enc.bindIbl(irr_handle, spec_handle, lut_handle, env.spec_mip_count);

        var s: u32 = 0;
        while (s < a.submesh_count) : (s += 1) {
            // Clamp to material pool capacity; submeshes beyond index 7 are
            // skipped rather than aliasing into adjacent memory.
            if (s >= 8) break;
            const sub = a.submesh(s);
            // Fill the stable material slot: 12 f32 matching command.zig layout —
            // base_color rgba | metallic, roughness, occlusion_strength, normal_scale | emissive rgb, 0.
            model_mats[s] = .{
                sub.base_color[0], sub.base_color[1], sub.base_color[2],      sub.base_color[3],
                sub.metallic,      sub.roughness,     sub.occlusion_strength, sub.normal_scale,
                sub.emissive[0],   sub.emissive[1],   sub.emissive[2],        0,
            };
            // All five tex_* indices are guaranteed ≥ 0 by the gltf neutral
            // baking (missing maps get a baked 1×1 neutral texture). texHandle
            // still clamps negatives so a malformed .vmesh fetched over HTTP
            // can't trap the cast in safe builds — handle 0 is never created,
            // so the JS interpreter's null-guard simply skips the bind.
            enc.bindTexture(0, texHandle(sub.tex_base));
            enc.bindTexture(1, texHandle(sub.tex_mr));
            enc.bindTexture(2, texHandle(sub.tex_normal));
            enc.bindTexture(3, texHandle(sub.tex_emissive));
            enc.bindTexture(4, texHandle(sub.tex_occlusion));
            enc.drawPbr(
                model_vbuf,
                model_ibuf,
                sub.index_byte_off,
                sub.index_count,
                @intCast(@intFromPtr(&model_mvp)),
                @intCast(@intFromPtr(&model_model_mat)),
                @intCast(@intFromPtr(&model_normal9)),
                @intCast(@intFromPtr(&model_mats[s])),
                @intCast(@intFromPtr(&model_camera)),
            );
        }
        enc.endFrame();
    } else {
        enc.beginFrame(.{ 0.05, 0.06, 0.09, 1.0 }, width, height);
        enc.endFrame();
    }
    _ = enc.finish();
    return @intCast(@intFromPtr(&model_cmd_buf));
}
