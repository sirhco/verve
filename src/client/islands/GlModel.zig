//! verve.gl P2 demo chunk — textured cube model via the asset pipeline.
//!
//! hydrate: gl_load("/gl/demo.vmesh", "glmodel_ready") then
//! gl_start(canvas, "glmodel_frame"). The bridge fetches the asset into
//! the chunk arena and calls glmodel_ready(ptr, len); ready parses the
//! vmesh Reader views and flags resources for upload on the next frame.
//! Frames before the asset lands emit only BEGIN/END (clear).
//!
//! The arena bytes backing the vmesh Reader stay alive for the page
//! lifetime — the chunk arena is never reset by this island, so the
//! slices inside `asset` remain valid across frames.
//!
//! Multi-instance: singleton statics, same documented choice as GlCube.

const verve = @import("verve");
const gl = verve.gl;

extern "verve" fn gl_start(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;
extern "verve" fn gl_load(url_ptr: [*]const u8, url_len: u32, cb_ptr: [*]const u8, cb_len: u32) void;

const SceneT = gl.Scene(8);

var scn: SceneT = .{};
var node: u32 = 0;
var angle: f32 = 0;
var asset: ?gl.vmesh.Reader = null;
var resources_sent: bool = false;
var mvp: [16]f32 = undefined;

// Per-submesh color pool (cap 8). Each drawSub points at its own slot so
// the JS interpreter reads the correct color when it walks the command
// stream — a single shared `color: [4]f32` would leave only the LAST
// submesh's color visible across all drawSub commands (latent bug).
// Bail/clamp: submeshes beyond index 7 are skipped with a comment below.
var colors: [8][4]f32 = undefined;

// cmd_buf sizing (N = 8 submesh cap):
//   header(4) + 2×createBuffer(20) + createShader(28) + 8×createTexture(24)
//   + beginFrame(28) + setPipeline(12) + 8×bindTexture(12) + 8×drawSub(28)
//   + endFrame(4)
//   = 4 + 40 + 28 + 192 + 28 + 12 + 96 + 224 + 4 = 628 < 1024 ✓
var cmd_buf: [1024]u8 = undefined;

const vbuf: u32 = 1;
const ibuf: u32 = 2;
const shader: u32 = 1;
const url = "/gl/demo.vmesh";
const ready_export = "glmodel_ready";
const frame_export = "glmodel_frame";

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;
    scn = .{};
    node = scn.addNode(-1, "model");
    asset = null;
    resources_sent = false;
    angle = 0;
    gl_load(url.ptr, url.len, ready_export.ptr, ready_export.len);
    const handle = verve.queryRef(@as([]const u8, "glmodel-canvas")) orelse return; // canvas missing
    gl_start(handle, frame_export.ptr, frame_export.len);
}

export fn glmodel_ready(ptr: u32, len: u32) void {
    if (ptr == 0) return; // fetch failed; stay on clear-only frames
    const bytes = @as([*]const u8, @ptrFromInt(ptr))[0..len];
    asset = gl.vmesh.Reader.init(bytes) catch null;
}

export fn glmodel_frame(dt_ms: f32, width: u32, height: u32) u32 {
    angle += dt_ms * 0.0005;
    scn.setRotation(node, gl.math.Quat.fromAxisAngle(gl.math.Vec3.init(0, 1, 0.2), angle));
    scn.updateWorld();
    const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(@max(height, 1)));
    const proj = gl.math.Mat4.perspective(1.0, aspect, 0.1, 100.0);
    const view = gl.math.Mat4.lookAt(
        gl.math.Vec3.init(0, 1.2, 4),
        gl.math.Vec3.init(0, 0, 0),
        gl.math.Vec3.init(0, 1, 0),
    );
    mvp = proj.mul(view).mul(scn.world[node]).m;

    var enc = gl.Encoder.init(&cmd_buf);
    if (asset) |*a| {
        if (!resources_sent) {
            resources_sent = true;
            enc.createBuffer(vbuf, .vertex, @intCast(@intFromPtr(a.vertices.ptr)), @intCast(a.vertices.len));
            enc.createBuffer(ibuf, .index, @intCast(@intFromPtr(a.indices.ptr)), @intCast(a.indices.len));
            enc.createShader(
                shader,
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
        enc.setPipeline(shader, gl.command.state_depth_test | gl.command.state_cull_back);
        var s: u32 = 0;
        while (s < a.submesh_count) : (s += 1) {
            // Clamp to color pool capacity; submeshes beyond index 7 are
            // skipped rather than aliasing into adjacent memory.
            if (s >= 8) break;
            const sub = a.submesh(s);
            colors[s] = sub.base_color; // each slot is stable for the frame
            if (sub.tex_index >= 0) enc.bindTexture(0, @intCast(sub.tex_index + 1));
            enc.drawSub(vbuf, ibuf, sub.index_byte_off, sub.index_count, @intCast(@intFromPtr(&mvp)), @intCast(@intFromPtr(&colors[s])));
        }
        enc.endFrame();
    } else {
        enc.beginFrame(.{ 0.05, 0.06, 0.09, 1.0 }, width, height);
        enc.endFrame();
    }
    _ = enc.finish();
    return @intCast(@intFromPtr(&cmd_buf));
}
