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
var model_resources_sent: bool = false;
var model_mvp: [16]f32 = undefined;

// Per-submesh color pool (cap 8). Each drawSub points at its own slot so
// the JS interpreter reads the correct color when it walks the command
// stream — a single shared `color: [4]f32` would leave only the LAST
// submesh's color visible across all drawSub commands (latent bug).
// Bail/clamp: submeshes beyond index 7 are skipped with a comment below.
var model_colors: [8][4]f32 = undefined;

// cmd_buf sizing (N = 8 submesh cap):
//   header(4) + 2×createBuffer(20) + createShader(28) + 8×createTexture(24)
//   + beginFrame(28) + setPipeline(12) + 8×bindTexture(12) + 8×drawSub(28)
//   + endFrame(4)
//   = 4 + 40 + 28 + 192 + 28 + 12 + 96 + 224 + 4 = 628 < 1024 ✓
var model_cmd_buf: [1024]u8 = undefined;

const model_vbuf: u32 = 1;
const model_ibuf: u32 = 2;
const model_shader: u32 = 1;
const model_url = "/gl/demo.vmesh";
const model_ready_export = "glmodel_ready";
const model_frame_export = "glmodel_frame";

// ── hydrate ─────────────────────────────────────────────────────────────────

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;

    // Reset cube state.
    cube_scn = .{};
    cube_node = cube_scn.addNode(-1, "cube");
    cube_resources_sent = false;
    cube_angle = 0;

    // Reset model state.
    model_scn = .{};
    model_node = model_scn.addNode(-1, "model");
    model_asset = null;
    model_resources_sent = false;
    model_angle = 0;

    // Kick the asset fetch for the model canvas.
    gl_load(model_url.ptr, model_url.len, model_ready_export.ptr, model_ready_export.len);

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

export fn glmodel_frame(dt_ms: f32, width: u32, height: u32) u32 {
    model_angle += dt_ms * 0.0005;
    model_scn.setRotation(model_node, gl.math.Quat.fromAxisAngle(gl.math.Vec3.init(0, 1, 0.2), model_angle));
    model_scn.updateWorld();
    const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(@max(height, 1)));
    const proj = gl.math.Mat4.perspective(1.0, aspect, 0.1, 100.0);
    const view = gl.math.Mat4.lookAt(
        gl.math.Vec3.init(0, 1.2, 4),
        gl.math.Vec3.init(0, 0, 0),
        gl.math.Vec3.init(0, 1, 0),
    );
    model_mvp = proj.mul(view).mul(model_scn.world[model_node]).m;

    var enc = gl.Encoder.init(&model_cmd_buf);
    if (model_asset) |*a| {
        if (!model_resources_sent) {
            model_resources_sent = true;
            enc.createBuffer(model_vbuf, .vertex, @intCast(@intFromPtr(a.vertices.ptr)), @intCast(a.vertices.len));
            enc.createBuffer(model_ibuf, .index, @intCast(@intFromPtr(a.indices.ptr)), @intCast(a.indices.len));
            enc.createShader(
                model_shader,
                gl.command.variant_lit_uv,
                @intCast(@intFromPtr(gl.command.lit_vs.ptr)),
                @intCast(gl.command.lit_vs.len),
                @intCast(@intFromPtr(gl.command.lit_fs.ptr)),
                @intCast(gl.command.lit_fs.len),
            );
            var t: u32 = 0;
            while (t < a.tex_count) : (t += 1) {
                const tex = a.texture(t);
                enc.createTexture(t + 1, tex.width, tex.height, @intCast(@intFromPtr(tex.rgba.ptr)), @intCast(tex.rgba.len));
            }
        }
        enc.beginFrame(.{ 0.05, 0.06, 0.09, 1.0 }, width, height);
        enc.setPipeline(model_shader, gl.command.state_depth_test | gl.command.state_cull_back);
        var s: u32 = 0;
        while (s < a.submesh_count) : (s += 1) {
            // Clamp to color pool capacity; submeshes beyond index 7 are
            // skipped rather than aliasing into adjacent memory.
            if (s >= 8) break;
            const sub = a.submesh(s);
            model_colors[s] = sub.base_color; // each slot is stable for the frame
            if (sub.tex_index >= 0) enc.bindTexture(0, @intCast(sub.tex_index + 1));
            enc.drawSub(model_vbuf, model_ibuf, sub.index_byte_off, sub.index_count, @intCast(@intFromPtr(&model_mvp)), @intCast(@intFromPtr(&model_colors[s])));
        }
        enc.endFrame();
    } else {
        enc.beginFrame(.{ 0.05, 0.06, 0.09, 1.0 }, width, height);
        enc.endFrame();
    }
    _ = enc.finish();
    return @intCast(@intFromPtr(&model_cmd_buf));
}
