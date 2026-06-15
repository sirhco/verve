//! verve.gl P10 (WebGPU) demo chunk — drives the /gl-webgpu canvas.
//!
//! End-to-end consumer that proves the WebGPU command-stream interpreter
//! (added in P10 T1–T4) works: uploads an unlit vertex-color cube, creates a
//! WGSL shader (gl.command.wgslUnlit), and drives it through the WebGPU
//! backend via `gl_start_gpu` (the bridge import added in T4).
//!
//! STRUCTURE mirrors GlDemo's unlit-cube path exactly — singleton statics, a
//! send-once create block guarded by a flag, a STABLE static `mvp` (the wire's
//! draw record carries its address; the bridge reads it after the frame fn
//! returns), and a frame export returning the cmd_buf pointer.
//!
//! Multi-instance: singleton statics (slice 1 — single instance; P7 multi-
//! instance is out of scope here). Namespace by root_id if a future page ever
//! needs two WebGPU cubes.

const verve = @import("verve");
const gl = verve.gl;

// Matches the bridge import added in T4 (gpuStart).
extern "verve" fn gl_start_gpu(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;

// ── Statics ─────────────────────────────────────────────────────────────────

var canvas_handle: ?i32 = null;
var yaw: f32 = 0;
var resources_sent: bool = false;
// STABLE static — the draw record carries &mvp; the bridge reads it after the
// frame fn returns, so it must outlive the call (exactly like GlDemo's mvp).
var mvp: [16]f32 = undefined;

// cmd_buf sizing: createBuffer×2 (4+16) + createShader (4+24) one-time = 68;
// per-frame beginFrame (4+24) + setPipeline (4+8) + draw (4+24) + endFrame (4)
// + header(4) = 76. Round generously to 512 (matches GlDemo's cube buffer).
var cmd_buf: [512]u8 = undefined;

const vbuf_handle: u32 = 1;
const ibuf_handle: u32 = 2;
const shader_handle: u32 = 1;
const frame_export = "glwebgpu_frame";

// ── hydrate ─────────────────────────────────────────────────────────────────

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;

    resources_sent = false;
    yaw = 0;
    canvas_handle = verve.queryRef(@as([]const u8, "glwebgpu-canvas"));

    // Start the WebGPU rAF loop. Create commands are emitted send-once inside
    // the first frame (guarded by resources_sent), exactly like GlDemo.
    if (canvas_handle) |h|
        gl_start_gpu(h, frame_export.ptr, frame_export.len);
}

// ── frame export ──────────────────────────────────────────────────────────────

export fn glwebgpu_frame(dt_ms: f32, width: u32, height: u32) u32 {
    yaw += dt_ms * 0.001; // ~1 rad/s

    const aspect = @as(f32, @floatFromInt(width)) /
        @as(f32, @floatFromInt(@max(height, 1)));
    const proj = gl.math.Mat4.perspective(1.0, aspect, 0.1, 100.0);
    const view = gl.math.Mat4.lookAt(
        gl.math.Vec3.init(0, 0, 4),
        gl.math.Vec3.init(0, 0, 0),
        gl.math.Vec3.init(0, 1, 0),
    );
    const model = gl.math.Mat4.fromTrs(
        gl.math.Vec3.init(0, 0, 0),
        gl.math.Quat.fromAxisAngle(gl.math.Vec3.init(0, 1, 0), yaw),
        gl.math.Vec3.init(1, 1, 1),
    );
    mvp = proj.mul(view).mul(model).m;

    var enc = gl.Encoder.init(&cmd_buf);
    if (!resources_sent) {
        resources_sent = true;
        enc.createBuffer(
            vbuf_handle,
            .vertex,
            @intCast(@intFromPtr(&gl.mesh.cube_vertices)),
            @sizeOf(@TypeOf(gl.mesh.cube_vertices)),
        );
        enc.createBuffer(
            ibuf_handle,
            .index,
            @intCast(@intFromPtr(&gl.mesh.cube_indices)),
            @sizeOf(@TypeOf(gl.mesh.cube_indices)),
        );
        // WGSL module (both stages) — the WebGPU port of unlit_vs/unlit_fs.
        // fs args are 0/0: the single WGSL source holds both stages.
        const wgsl = gl.command.wgslUnlit;
        enc.createShader(
            shader_handle,
            gl.command.variant_vertex_color,
            @intCast(@intFromPtr(wgsl.ptr)),
            @intCast(wgsl.len),
            0,
            0,
        );
    }
    enc.beginFrame(.{ 0.05, 0.06, 0.09, 1.0 }, width, height);
    enc.setPipeline(shader_handle, gl.command.state_depth_test);
    enc.draw(vbuf_handle, ibuf_handle, gl.mesh.cube_indices.len, @intCast(@intFromPtr(&mvp)));
    enc.endFrame();
    _ = enc.finish();
    return @intCast(@intFromPtr(&cmd_buf));
}
