//! verve.gl fat-line demo — drives the /gl-lines canvas.
//!
//! Renders two primitives via Encoder.drawLines (wire tag 43, variant_fatline):
//!   1. Static opaque wireframe cube: 12 edges, drawn first so depth-writes
//!      gate the trail behind (state_depth_test only — no blend).
//!   2. Animated translucent trail: a Lissajous curve advancing each frame,
//!      64 points → 63 segments, alpha fading from transparent tail to opaque
//!      head (state_depth_test | state_blend).
//! Orbit camera + freeze pin, width-step controls (1..32 px), worldUnits toggle.
//!
//! STRUCTURE: singleton statics (segment buffers in chunk linear memory, NOT
//! frame stack — stack is 64KB), a send-once resource block, a frame export
//! returning cmd_buf pointer every frame.

const verve = @import("verve");
const gl = verve.gl;

extern "verve" fn gl_start(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;
extern "verve" fn gl_start_gpu(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;
extern "verve" fn gl_webgpu_available() i32;

// ── Constants ─────────────────────────────────────────────────────────────────

const pi: f32 = 3.14159265358979;

/// Trail points. 64 points → 63 segments × 40B ≈ 2.5KB in chunk static memory.
const N_TRAIL: usize = 64;

/// Wireframe cube edges.
const N_WIRE: usize = 12;

/// GPU resource handles (stable identifiers the JS bridge tracks).
const h_shader: u32 = 1;
const h_trail_buf: u32 = 2;
const h_wire_buf: u32 = 3;

/// Frame fn name passed to gl_start / gl_start_gpu.
const frame_export: []const u8 = "gllines_frame";

// ── Statics (chunk linear memory — NOT frame stack) ──────────────────────────

var canvas_handle: ?i32 = null;
var use_webgpu: bool = false;
var resources_sent: bool = false;
var frozen: bool = false;
var yaw: f32 = 0; // orbit azimuth (advances per frame unless frozen)
var trail_t: f32 = 0; // Lissajous curve parameter (advances per frame)
var line_width: f32 = 4.0; // pixels in screen-space (or world units when toggled)
var world_units: bool = false; // flags bit0 for drawLines

// ── Segment buffers (chunk static — never on frame stack) ─────────────────────

// Trail: 63 segments × 10 f32 = 630 f32 = 2520B.
// Record layout (40B = 10 f32): p0(3f)@0, p1(3f)@12, color(4f)@24.
var trail_buf: [(N_TRAIL - 1) * 10]f32 = undefined;

// Wire cube: 12 edges × 10 f32 = 120 f32 = 480B.
var wire_buf: [N_WIRE * 10]f32 = undefined;

// ── STABLE statics (addresses carried in draw records; read after frame fn) ──

/// Combined view-projection matrix (16 f32) passed as vp_ptr to drawLines.
var vp_mat: [16]f32 = undefined;

/// Canvas resolution [w, h] passed as resolution_ptr to drawLines.
var resolution_buf: [2]f32 = undefined;

// cmd_buf sizing:
//   reserved header: 4B
//   resources_sent: createShader(28) + createBuffer(wire)(20) = 48B
//   per-frame: createBuffer(trail)(20) + beginFrame(28) + setPipeline×2(24)
//              + drawLines×2(56) + endFrame(4) = 132B
//   total first frame: 4 + 48 + 132 = 184B → 1024B ample.
var cmd_buf: [1024]u8 = undefined;

// ── WebGPU depth-range fix (WebGL z∈[-1,1]; WebGPU z∈[0,1]) ─────────────────

/// Returns an identity-or-remap matrix so that depth lands in [0,1] on WebGPU
/// and is left unchanged on WebGL2. Mirrors GlScene.zig clipFix().
fn clipFix() gl.math.Mat4 {
    if (!use_webgpu) {
        var m = gl.math.Mat4{ .m = [_]f32{0} ** 16 };
        m.m[0] = 1;
        m.m[5] = 1;
        m.m[10] = 1;
        m.m[15] = 1;
        return m;
    }
    var z = gl.math.Mat4{ .m = [_]f32{0} ** 16 };
    z.m[0] = 1;
    z.m[5] = 1;
    z.m[10] = 0.5;
    z.m[14] = 0.5;
    z.m[15] = 1;
    return z;
}

// ── Wire cube init (called once from hydrate) ─────────────────────────────────

fn initWireCube() void {
    const h: f32 = 2.5; // half-extent
    // 12 edges, each row: [p0x,p0y,p0z, p1x,p1y,p1z, r,g,b,a]
    const edges: [N_WIRE][10]f32 = .{
        // bottom ring (y = -h)
        .{ -h, -h, -h, h, -h, -h, 0.8, 0.9, 1.0, 1.0 },
        .{ h, -h, -h, h, -h, h, 0.8, 0.9, 1.0, 1.0 },
        .{ h, -h, h, -h, -h, h, 0.8, 0.9, 1.0, 1.0 },
        .{ -h, -h, h, -h, -h, -h, 0.8, 0.9, 1.0, 1.0 },
        // top ring (y = +h)
        .{ -h, h, -h, h, h, -h, 0.8, 0.9, 1.0, 1.0 },
        .{ h, h, -h, h, h, h, 0.8, 0.9, 1.0, 1.0 },
        .{ h, h, h, -h, h, h, 0.8, 0.9, 1.0, 1.0 },
        .{ -h, h, h, -h, h, -h, 0.8, 0.9, 1.0, 1.0 },
        // verticals
        .{ -h, -h, -h, -h, h, -h, 0.8, 0.9, 1.0, 1.0 },
        .{ h, -h, -h, h, h, -h, 0.8, 0.9, 1.0, 1.0 },
        .{ h, -h, h, h, h, h, 0.8, 0.9, 1.0, 1.0 },
        .{ -h, -h, h, -h, h, h, 0.8, 0.9, 1.0, 1.0 },
    };
    var i: usize = 0;
    while (i < N_WIRE) : (i += 1) {
        const b = i * 10;
        wire_buf[b + 0] = edges[i][0];
        wire_buf[b + 1] = edges[i][1];
        wire_buf[b + 2] = edges[i][2];
        wire_buf[b + 3] = edges[i][3];
        wire_buf[b + 4] = edges[i][4];
        wire_buf[b + 5] = edges[i][5];
        wire_buf[b + 6] = edges[i][6];
        wire_buf[b + 7] = edges[i][7];
        wire_buf[b + 8] = edges[i][8];
        wire_buf[b + 9] = edges[i][9];
    }
}

// ── Trail animation (Lissajous curve in 3D) ───────────────────────────────────

/// Advance the Lissajous parameter and rebuild the segment buffer.
/// Pts allocated on the frame stack (64×3×4 = 768B — well within 64KB).
fn tickTrail(dt_s: f32) void {
    trail_t += dt_s * 1.2; // ~1.2 rad/s advance

    const n = N_TRAIL;
    var pts: [n * 3]f32 = undefined; // 768B on frame stack
    const step: f32 = (2.0 * pi) / @as(f32, @floatFromInt(n - 1));
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const s = @as(f32, @floatFromInt(i)) * step + trail_t;
        pts[i * 3 + 0] = 3.0 * @cos(s);
        pts[i * 3 + 1] = 1.5 * @sin(s * 1.3); // 1.3× for out-of-plane figure-eight
        pts[i * 3 + 2] = 3.0 * @sin(s);
    }

    // Build segment records (40B each): tail (i=0) transparent → head opaque.
    i = 0;
    while (i < n - 1) : (i += 1) {
        const b = i * 10;
        const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n - 2));
        const a = t * t; // quadratic alpha: 0 at tail → 1 at head
        trail_buf[b + 0] = pts[i * 3 + 0];
        trail_buf[b + 1] = pts[i * 3 + 1];
        trail_buf[b + 2] = pts[i * 3 + 2];
        trail_buf[b + 3] = pts[(i + 1) * 3 + 0];
        trail_buf[b + 4] = pts[(i + 1) * 3 + 1];
        trail_buf[b + 5] = pts[(i + 1) * 3 + 2];
        // Colour gradient: dim cyan tail → bright white-yellow head.
        trail_buf[b + 6] = 0.3 + t * 0.7; // r: 0.3 → 1.0
        trail_buf[b + 7] = 0.7 + t * 0.3; // g: 0.7 → 1.0
        trail_buf[b + 8] = 1.0; // b: constant
        trail_buf[b + 9] = a; // a: 0 → 1
    }
}

// ── hydrate ───────────────────────────────────────────────────────────────────

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;

    resources_sent = false;
    frozen = false;
    yaw = 0;
    trail_t = 0;
    line_width = 4.0;
    world_units = false;
    use_webgpu = gl_webgpu_available() != 0;
    canvas_handle = verve.queryRef(@as([]const u8, "gllines-canvas"));

    initWireCube();

    if (canvas_handle) |h| {
        if (use_webgpu)
            gl_start_gpu(h, frame_export.ptr, frame_export.len)
        else
            gl_start(h, frame_export.ptr, frame_export.len);
    }
}

// ── frame export ──────────────────────────────────────────────────────────────

export fn gllines_frame(dt_ms: f32, width: u32, height: u32) u32 {
    const dt_s = @min(dt_ms, 100.0) * 0.001;

    // Trail advances every frame; orbit only advances when not frozen.
    tickTrail(dt_s);
    if (!frozen) yaw += dt_s * 0.4; // ~0.4 rad/s slow orbit

    // ── Camera & combined VP ─────────────────────────────────────────────────
    resolution_buf[0] = @floatFromInt(width);
    resolution_buf[1] = @floatFromInt(@max(height, 1));

    const aspect = resolution_buf[0] / resolution_buf[1];
    const eye = gl.math.Vec3.init(@sin(yaw) * 10.0, 3.0, @cos(yaw) * 10.0);
    const proj = gl.math.Mat4.perspective(1.0, aspect, 0.1, 100.0);
    const view = gl.math.Mat4.lookAt(
        eye,
        gl.math.Vec3.init(0, 0, 0),
        gl.math.Vec3.init(0, 1, 0),
    );
    // Combined VP — clipFix remaps depth to [0,1] on WebGPU (identity on WebGL2).
    vp_mat = clipFix().mul(proj).mul(view).m;

    // ── Encode ───────────────────────────────────────────────────────────────
    var enc = gl.Encoder.init(&cmd_buf);

    if (!resources_sent) {
        resources_sent = true;

        // Upload the fat-line shader (variant_fatline, standalone pair).
        if (use_webgpu) {
            const wgsl = gl.command.wgslFatline();
            enc.createShader(
                h_shader,
                gl.command.variant_fatline,
                @intCast(@intFromPtr(wgsl.ptr)),
                @intCast(wgsl.len),
                0,
                0,
            );
        } else {
            const vs = gl.command.fatlineVertexSrc();
            const fs = gl.command.fatlineFragmentSrc();
            enc.createShader(
                h_shader,
                gl.command.variant_fatline,
                @intCast(@intFromPtr(vs.ptr)),
                @intCast(vs.len),
                @intCast(@intFromPtr(fs.ptr)),
                @intCast(fs.len),
            );
        }

        // Upload the static wireframe cube buffer (480B, 12 edges).
        enc.createBuffer(
            h_wire_buf,
            .vertex,
            @intCast(@intFromPtr(&wire_buf)),
            @sizeOf(@TypeOf(wire_buf)),
        );
    }

    // Re-upload trail buffer every frame (positions change per tick).
    enc.createBuffer(
        h_trail_buf,
        .vertex,
        @intCast(@intFromPtr(&trail_buf)),
        @sizeOf(@TypeOf(trail_buf)),
    );

    const flags: u32 = if (world_units) 1 else 0;

    // ── Draw ─────────────────────────────────────────────────────────────────
    enc.beginFrame(.{ 0.02, 0.02, 0.08, 1.0 }, width, height);

    // 1. Opaque wireframe cube — draw first so depth-writes gate the trail.
    enc.setPipeline(h_shader, gl.command.state_depth_test);
    enc.drawLines(
        h_wire_buf,
        N_WIRE,
        line_width,
        @intCast(@intFromPtr(&vp_mat)),
        @intCast(@intFromPtr(&resolution_buf)),
        flags,
    );

    // 2. Translucent animated trail — depth-test reads cube depth; blend ON.
    enc.setPipeline(h_shader, gl.command.state_depth_test | gl.command.state_blend);
    enc.drawLines(
        h_trail_buf,
        N_TRAIL - 1,
        line_width,
        @intCast(@intFromPtr(&vp_mat)),
        @intCast(@intFromPtr(&resolution_buf)),
        flags,
    );

    enc.endFrame();
    _ = enc.finish();
    return @intCast(@intFromPtr(&cmd_buf));
}

// ── Controls (wired to /gl-lines buttons via z-on-click) ─────────────────────

export fn gllines_width_up() void {
    line_width = @min(line_width + 2.0, 32.0);
}

export fn gllines_width_down() void {
    line_width = @max(line_width - 2.0, 1.0);
}

export fn gllines_toggle_worldunits() void {
    world_units = !world_units;
}

export fn gllines_freeze() void {
    frozen = true;
}

export fn gllines_unfreeze() void {
    frozen = false;
}
