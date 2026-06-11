//! verve.gl P1 demo chunk — rotating unlit cube.
//!
//! `hydrate` resolves the SSR'd canvas (`[data-ref="glcube-canvas"]`)
//! and asks the bridge gl section (via the `gl_start` chunk import) to
//! start a rAF loop driving `glcube_frame`. Each call returns a pointer
//! to a length-prefixed command stream (core/gl/command.zig layout);
//! the bridge walks it and issues WebGL2 calls. Returning 0 stops the
//! loop per the protocol — this demo never stops, so no path returns 0.
//! First frame carries the CREATE_* resource commands; vertex bytes and
//! GLSL travel as (ptr, len) into this module's statics — zero copies.
//!
//! Multi-instance: all state below is file-scope statics, so two
//! `<verve-island data-name="GlCube">` markers on one page would share
//! one scene/buffer (same singleton choice Counter.zig documents).
//! Namespace by `root_id` if a page ever needs two cubes.

const verve = @import("verve");
const gl = verve.gl;

extern "verve" fn gl_start(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;

const SceneT = gl.Scene(8);

var scn: SceneT = .{};
var cube_node: u32 = 0;
var angle: f32 = 0;
var resources_sent: bool = false;
var mvp: [16]f32 = undefined;
var cmd_buf: [512]u8 = undefined;

const vbuf_handle: u32 = 1;
const ibuf_handle: u32 = 2;
const shader_handle: u32 = 1;
const frame_export = "glcube_frame";

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;
    scn = .{};
    cube_node = scn.addNode(-1, "cube");
    resources_sent = false;
    angle = 0;
    const handle = verve.queryRef(@as([]const u8, "glcube-canvas")) orelse return; // canvas missing
    gl_start(handle, frame_export.ptr, frame_export.len);
}

export fn glcube_frame(dt_ms: f32, width: u32, height: u32) u32 {
    angle += dt_ms * 0.001; // ~1 rad/s
    scn.setRotation(cube_node, gl.math.Quat.fromAxisAngle(
        gl.math.Vec3.init(0.3, 1, 0),
        angle,
    ));
    scn.updateWorld();

    const aspect = @as(f32, @floatFromInt(width)) /
        @as(f32, @floatFromInt(@max(height, 1)));
    const proj = gl.math.Mat4.perspective(1.0, aspect, 0.1, 100.0);
    const view = gl.math.Mat4.lookAt(
        gl.math.Vec3.init(0, 1.5, 5),
        gl.math.Vec3.init(0, 0, 0),
        gl.math.Vec3.init(0, 1, 0),
    );
    mvp = proj.mul(view).mul(scn.world[cube_node]).m;

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
        enc.createShader(
            shader_handle,
            gl.command.variant_vertex_color,
            @intCast(@intFromPtr(gl.command.unlit_vs.ptr)),
            @intCast(gl.command.unlit_vs.len),
            @intCast(@intFromPtr(gl.command.unlit_fs.ptr)),
            @intCast(gl.command.unlit_fs.len),
        );
    }
    enc.beginFrame(.{ 0.07, 0.07, 0.1, 1.0 }, width, height);
    enc.setPipeline(shader_handle, gl.command.state_depth_test | gl.command.state_cull_back);
    enc.draw(vbuf_handle, ibuf_handle, gl.mesh.cube_indices.len, @intCast(@intFromPtr(&mvp)));
    enc.endFrame();
    _ = enc.finish();
    return @intCast(@intFromPtr(&cmd_buf));
}
