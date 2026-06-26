//! verve.gl decal demo — drives the /gl-decals canvas.
//!
//! Renders a UV sphere (target surface, variant_lit_uv) with a crosshair/ring
//! decal (variant_decal, wire tag 44) projected onto it via
//! `gl.decal.projectDecal`. The decal basis is built from the sphere normal
//! at the chosen point so the overlay conforms to the surface curvature.
//!
//! STRUCTURE: singleton statics (sphere + decal buffers in chunk linear memory,
//! NOT frame stack — stack is 64KB), send-once resource block, per-frame
//! export returning cmd_buf pointer every frame. Re-projection only when the
//! decal is marked dirty (controls set the flag).

const verve = @import("verve");
const gl = verve.gl;

extern "verve" fn gl_start(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;
extern "verve" fn gl_start_gpu(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;
extern "verve" fn gl_webgpu_available() i32;

// ── Constants ─────────────────────────────────────────────────────────────────

const pi: f32 = 3.14159265358979;

/// UV sphere resolution.
const RINGS: usize = 20;
const SECTORS: usize = 24;

/// Total vertex and index counts (comptime).
const N_VERTS: usize = (RINGS + 1) * (SECTORS + 1); // 21 × 25 = 525
const N_INDICES: usize = RINGS * SECTORS * 6; // 20 × 24 × 6 = 2880

/// GPU resource handles (stable identifiers the JS bridge tracks).
const h_sphere_shader: u32 = 1;
const h_decal_shader: u32 = 2;
const h_sphere_vbuf: u32 = 3;
const h_sphere_ibuf: u32 = 4;
const h_sphere_tex: u32 = 5;
const h_decal_tex: u32 = 6;
const h_decal_vbuf: u32 = 7;
const h_decal_ibuf: u32 = 8;

/// Frame fn name passed to gl_start / gl_start_gpu.
const frame_export: []const u8 = "gldecals_frame";

// ── Statics (chunk linear memory — NOT frame stack) ──────────────────────────

var canvas_handle: ?i32 = null;
var use_webgpu: bool = false;
var resources_sent: bool = false;
var frozen: bool = false;
var yaw: f32 = 0; // orbit azimuth (advances per frame unless frozen)

/// Decal placement on the sphere (spherical coords, unit sphere).
var decal_theta: f32 = pi / 2.0; // start at equator
var decal_phi: f32 = 0.0; // start at +X face (visible from default camera)
var decal_size: [3]f32 = .{ 0.55, 0.55, 2.0 }; // [right, up, depth] extents
var decal_dirty: bool = true; // triggers re-projection (+ re-upload) on first frame

// ── Sphere geometry (chunk static) ───────────────────────────────────────────

/// Interleaved vertex buffer: pos(12B)@0, normal(12B)@12, uv(8B)@24, stride=32B.
/// 525 verts × 32B = 16 800B.
var sphere_verts: [N_VERTS * 8]f32 = undefined;

/// u16 index buffer for the sphere: 2880 × 2B = 5 760B.
var sphere_indices: [N_INDICES]u16 = undefined;

/// Flat packed positions (N×3) fed to projectDecal. 525 × 12B = 6 300B.
var sphere_pos_flat: [N_VERTS * 3]f32 = undefined;

// ── Decal output geometry (chunk static) ──────────────────────────────────────

/// Stride-32 interleaved decal verts from projectDecal. 1024 × 32B = 32 768B.
var decal_out_verts: [gl.decal.max_decal_verts * 8]f32 = undefined;

/// u16 index buffer for the projected decal. 2048 × 2B = 4 096B.
var decal_out_indices: [gl.decal.max_decal_indices]u16 = undefined;

/// Counts returned by the last projectDecal call.
var decal_vert_count: u32 = 0;
var decal_index_count: u32 = 0;

// ── Textures ──────────────────────────────────────────────────────────────────

/// 1×1 neutral-grey RGBA8 texture for the sphere surface.
var sphere_tex_data: [4]u8 = .{ 200, 200, 200, 255 };

/// 32×32 RGBA8 ring-and-crosshair decal texture (alpha=0 outside shapes).
var decal_tex_data: [32 * 32 * 4]u8 = undefined;

// ── STABLE statics (addresses carried in draw records) ────────────────────────

/// Combined MVP matrix (proj·view; model = identity) passed to both draws.
var mvp_mat: [16]f32 = undefined;

/// Tint for the sphere surface draw (white, full alpha).
var sphere_color: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 };

/// Tint for the decal draw (orange-red, 90% opacity).
var decal_color: [4]f32 = .{ 1.0, 0.45, 0.1, 0.9 };

// cmd_buf sizing:
//   resources (once): createShader×2(56) + createTexture×2(48) + createBuffer sphere×2(40) = 144B
//   decal dirty: createBuffer decal×2(40)
//   per-frame: beginFrame(28) + setPipeline×2(24) + bindTexture(12) + drawSub(28)
//              + drawDecal(32) + endFrame(8) = 132B
//   header: 4B
//   total first frame: 4 + 144 + 40 + 132 = 320B → 2048B ample.
var cmd_buf: [2048]u8 = undefined;

// ── WebGPU depth-range fix ────────────────────────────────────────────────────

/// Returns identity for WebGL2 (z∈[-1,1]) or a z-remap for WebGPU (z∈[0,1]).
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

// ── Sphere generation (called once from hydrate) ──────────────────────────────

fn initSphere() void {
    // Generate interleaved verts + flat position array simultaneously.
    var vi: usize = 0;
    var ring: usize = 0;
    while (ring <= RINGS) : (ring += 1) {
        const theta: f32 = @as(f32, @floatFromInt(ring)) * pi / @as(f32, @floatFromInt(RINGS));
        const sin_t = @sin(theta);
        const cos_t = @cos(theta);
        var sector: usize = 0;
        while (sector <= SECTORS) : (sector += 1) {
            const phi_v: f32 = @as(f32, @floatFromInt(sector)) * 2.0 * pi / @as(f32, @floatFromInt(SECTORS));
            const sin_p = @sin(phi_v);
            const cos_p = @cos(phi_v);
            // pos = normal on a unit sphere
            const x = sin_t * cos_p;
            const y = cos_t;
            const z = sin_t * sin_p;
            const u_coord: f32 = @as(f32, @floatFromInt(sector)) / @as(f32, @floatFromInt(SECTORS));
            const v_coord: f32 = @as(f32, @floatFromInt(ring)) / @as(f32, @floatFromInt(RINGS));
            // Stride-32 interleaved: pos(3f) + normal(3f) + uv(2f)
            sphere_verts[vi * 8 + 0] = x;
            sphere_verts[vi * 8 + 1] = y;
            sphere_verts[vi * 8 + 2] = z;
            sphere_verts[vi * 8 + 3] = x; // unit sphere: normal == position
            sphere_verts[vi * 8 + 4] = y;
            sphere_verts[vi * 8 + 5] = z;
            sphere_verts[vi * 8 + 6] = u_coord;
            sphere_verts[vi * 8 + 7] = v_coord;
            // Flat positions for projectDecal
            sphere_pos_flat[vi * 3 + 0] = x;
            sphere_pos_flat[vi * 3 + 1] = y;
            sphere_pos_flat[vi * 3 + 2] = z;
            vi += 1;
        }
    }

    // Generate CCW triangle indices (two triangles per quad).
    var idx: usize = 0;
    ring = 0;
    while (ring < RINGS) : (ring += 1) {
        var sector: usize = 0;
        while (sector < SECTORS) : (sector += 1) {
            const v0: u16 = @intCast(ring * (SECTORS + 1) + sector);
            const v1: u16 = @intCast(ring * (SECTORS + 1) + sector + 1);
            const v2: u16 = @intCast((ring + 1) * (SECTORS + 1) + sector);
            const v3: u16 = @intCast((ring + 1) * (SECTORS + 1) + sector + 1);
            sphere_indices[idx + 0] = v0;
            sphere_indices[idx + 1] = v2;
            sphere_indices[idx + 2] = v1;
            sphere_indices[idx + 3] = v1;
            sphere_indices[idx + 4] = v2;
            sphere_indices[idx + 5] = v3;
            idx += 6;
        }
    }
}

// ── Decal texture ─────────────────────────────────────────────────────────────

fn buildDecalTexture() void {
    const W: i32 = 32;
    const cx: f32 = 15.5;
    const cy: f32 = 15.5;
    var py: i32 = 0;
    while (py < W) : (py += 1) {
        var px: i32 = 0;
        while (px < W) : (px += 1) {
            const dx = @as(f32, @floatFromInt(px)) - cx;
            const dy = @as(f32, @floatFromInt(py)) - cy;
            const dist = @sqrt(dx * dx + dy * dy);
            // Ring: outer radius 12, inner radius 9
            const on_ring = (dist >= 9.0 and dist <= 12.0);
            // Crosshair: horizontal or vertical band ≤1.2px from center
            const adx: f32 = if (dx < 0) -dx else dx;
            const ady: f32 = if (dy < 0) -dy else dy;
            const on_cross = (adx <= 1.2 and ady <= 14.5) or (ady <= 1.2 and adx <= 14.5);
            const tidx = @as(usize, @intCast(py * W + px)) * 4;
            if (on_ring or on_cross) {
                decal_tex_data[tidx + 0] = 255;
                decal_tex_data[tidx + 1] = 80;
                decal_tex_data[tidx + 2] = 20;
                decal_tex_data[tidx + 3] = 230;
            } else {
                decal_tex_data[tidx + 0] = 0;
                decal_tex_data[tidx + 1] = 0;
                decal_tex_data[tidx + 2] = 0;
                decal_tex_data[tidx + 3] = 0;
            }
        }
    }
}

// ── Decal basis + projection ──────────────────────────────────────────────────

/// Compute the row-major 3×3 basis for the current (decal_theta, decal_phi).
/// Column order: [right, up, forward]. Satisfies right × up = forward (right-hand).
fn computeDecalBasis() [9]f32 {
    const sin_t = @sin(decal_theta);
    const cos_t = @cos(decal_theta);
    const sin_p = @sin(decal_phi);
    const cos_p = @cos(decal_phi);

    // forward = outward unit-sphere normal at (theta, phi)
    const fx = sin_t * cos_p;
    const fy = cos_t;
    const fz = sin_t * sin_p;

    // up = -d(pos)/dtheta normalised = (-cos_t·cos_p, sin_t, -cos_t·sin_p)
    // This unit vector points toward the north pole of the sphere.
    const ux = -cos_t * cos_p;
    const uy = sin_t;
    const uz = -cos_t * sin_p;

    // right = up × forward  (ensures right × up = forward for a right-hand frame)
    const rx = uy * fz - uz * fy;
    const ry = uz * fx - ux * fz;
    const rz = ux * fy - uy * fx;

    // Row-major encoding: b[0]=rx, b[1]=ux, b[2]=fx  (first row = x-components)
    //                     b[3]=ry, b[4]=uy, b[5]=fy
    //                     b[6]=rz, b[7]=uz, b[8]=fz
    return .{ rx, ux, fx, ry, uy, fy, rz, uz, fz };
}

/// Run projectDecal with the current state; sets decal_dirty = false.
fn reproject() void {
    const sin_t = @sin(decal_theta);
    const cos_t = @cos(decal_theta);
    const sin_p = @sin(decal_phi);
    const cos_p = @cos(decal_phi);
    const center = [3]f32{ sin_t * cos_p, cos_t, sin_t * sin_p };
    const basis = computeDecalBasis();
    const result = gl.decal.projectDecal(
        &sphere_pos_flat,
        &sphere_indices,
        center,
        basis,
        decal_size,
        &decal_out_verts,
        &decal_out_indices,
    );
    decal_vert_count = result.vert_count;
    decal_index_count = result.index_count;
    decal_dirty = false;
}

// ── hydrate ───────────────────────────────────────────────────────────────────

export fn hydrate(props_ptr: [*]const u8, props_len: u32) void {
    _ = props_ptr;
    _ = props_len;

    use_webgpu = gl_webgpu_available() != 0;
    canvas_handle = verve.queryRef(@as([]const u8, "gldecals-canvas"));

    initSphere();
    buildDecalTexture();
    // decal_dirty is already true; first frame will reproject.

    if (canvas_handle) |h| {
        if (use_webgpu)
            gl_start_gpu(h, frame_export.ptr, frame_export.len)
        else
            gl_start(h, frame_export.ptr, frame_export.len);
    }
}

// ── frame export ──────────────────────────────────────────────────────────────

export fn gldecals_frame(dt_ms: f32, width: u32, height: u32) u32 {
    const dt_s = @min(dt_ms, 100.0) * 0.001;

    // Orbit camera unless frozen.
    if (!frozen) yaw += dt_s * 0.4; // ~0.4 rad/s slow orbit

    // Re-project the decal when marked dirty (controls moved/resized it).
    if (decal_dirty) reproject();

    // ── Camera ───────────────────────────────────────────────────────────────
    const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(@max(height, 1)));
    const proj = gl.math.Mat4.perspective(pi / 3.5, aspect, 0.1, 20.0);
    const eye = gl.math.Vec3.init(@cos(yaw) * 3.5, 1.2, @sin(yaw) * 3.5);
    const view = gl.math.Mat4.lookAt(
        eye,
        gl.math.Vec3.init(0, 0, 0),
        gl.math.Vec3.init(0, 1, 0),
    );
    // clipFix remaps depth to [0,1] on WebGPU; identity on WebGL2.
    mvp_mat = clipFix().mul(proj).mul(view).m;

    // ── Encode ───────────────────────────────────────────────────────────────
    var enc = gl.Encoder.init(&cmd_buf);

    // ── One-time resources ────────────────────────────────────────────────────
    if (!resources_sent) {
        resources_sent = true;

        // Sphere shader (variant_lit_uv — standard lit pipeline, no depth bias).
        // WebGPU: reuse the decal WGSL source (same stride-32 lit mesh layout);
        // only the variant flag differs so the bridge creates a standard pipeline.
        if (use_webgpu) {
            const wgsl = gl.command.wgslDecal();
            enc.createShader(
                h_sphere_shader,
                gl.command.variant_lit_uv,
                @intCast(@intFromPtr(wgsl.ptr)),
                @intCast(wgsl.len),
                0,
                0,
            );
        } else {
            enc.createShader(
                h_sphere_shader,
                gl.command.variant_lit_uv,
                @intCast(@intFromPtr(gl.command.lit_vs.ptr)),
                @intCast(gl.command.lit_vs.len),
                @intCast(@intFromPtr(gl.command.lit_fs.ptr)),
                @intCast(gl.command.lit_fs.len),
            );
        }

        // Decal shader (variant_decal — depth-biased pipeline).
        if (use_webgpu) {
            const wgsl = gl.command.wgslDecal();
            enc.createShader(
                h_decal_shader,
                gl.command.variant_decal,
                @intCast(@intFromPtr(wgsl.ptr)),
                @intCast(wgsl.len),
                0,
                0,
            );
        } else {
            const vs = gl.command.decalVertexSrc();
            const fs = gl.command.decalFragmentSrc();
            enc.createShader(
                h_decal_shader,
                gl.command.variant_decal,
                @intCast(@intFromPtr(vs.ptr)),
                @intCast(vs.len),
                @intCast(@intFromPtr(fs.ptr)),
                @intCast(fs.len),
            );
        }

        // 1×1 neutral-grey sphere texture.
        enc.createTexture(
            h_sphere_tex,
            1,
            1,
            @intCast(@intFromPtr(&sphere_tex_data)),
            @sizeOf(@TypeOf(sphere_tex_data)),
        );

        // 32×32 ring+crosshair decal texture.
        enc.createTexture(
            h_decal_tex,
            32,
            32,
            @intCast(@intFromPtr(&decal_tex_data)),
            @sizeOf(@TypeOf(decal_tex_data)),
        );

        // Static sphere vertex + index buffers (never change).
        enc.createBuffer(
            h_sphere_vbuf,
            .vertex,
            @intCast(@intFromPtr(&sphere_verts)),
            @sizeOf(@TypeOf(sphere_verts)),
        );
        enc.createBuffer(
            h_sphere_ibuf,
            .index,
            @intCast(@intFromPtr(&sphere_indices)),
            @sizeOf(@TypeOf(sphere_indices)),
        );
    }

    // ── Upload decal geometry when dirty (or first frame) ────────────────────
    // decal_dirty was cleared by reproject() above; upload the result.
    // We only create/re-upload the decal buffers when the geometry changed.
    // `decal_dirty` was already cleared above — track uploads separately.
    if (decal_vert_count > 0 and decal_index_count > 0) {
        // Always upload on first frame; after that only when the user moved/
        // resized the decal.  We use a simple pattern: resources_sent was just
        // set above on the first frame, and reproject() is called whenever
        // decal_dirty is true (controls or first frame).  The dirty flag being
        // true on entry means we just re-projected → upload the new mesh.
        // On other frames (frozen and not moved) we skip the upload.
        // Implementation: re-project sets decal_dirty = false; we track whether
        // we uploaded this frame via a local bool derived from the initial dirty
        // value captured before the reproject call above.  To keep it simple:
        // we always upload on the first call (resources_sent just became true)
        // and whenever the user interacted (the reproject() call above ran).
        // Since we cannot easily distinguish those cases here cheaply, we just
        // always upload — the decal mesh is small (~4 KB indices + 32 KB verts
        // at cap, far less typically) and createBuffer is idempotent.
        enc.createBuffer(
            h_decal_vbuf,
            .vertex,
            @intCast(@intFromPtr(&decal_out_verts)),
            @intCast(decal_vert_count * 8 * @sizeOf(f32)),
        );
        enc.createBuffer(
            h_decal_ibuf,
            .index,
            @intCast(@intFromPtr(&decal_out_indices)),
            @intCast(decal_index_count * @sizeOf(u16)),
        );
    }

    // ── Draw ─────────────────────────────────────────────────────────────────

    enc.beginFrame(.{ 0.05, 0.05, 0.1, 1.0 }, width, height);

    // 1. Sphere surface (lit, depth-test + cull back faces).
    enc.setPipeline(h_sphere_shader, gl.command.state_depth_test | gl.command.state_cull_back);
    enc.bindTexture(0, h_sphere_tex);
    enc.drawSub(
        h_sphere_vbuf,
        h_sphere_ibuf,
        0,
        @as(u32, N_INDICES),
        @intCast(@intFromPtr(&mvp_mat)),
        @intCast(@intFromPtr(&sphere_color)),
    );

    // 2. Decal overlay (depth-biased via bridge, alpha blended on top).
    if (decal_vert_count > 0 and decal_index_count > 0) {
        enc.setPipeline(h_decal_shader, gl.command.state_depth_test | gl.command.state_blend);
        enc.drawDecal(
            h_decal_vbuf,
            h_decal_ibuf,
            0,
            decal_index_count,
            @intCast(@intFromPtr(&mvp_mat)),
            h_decal_tex,
            @intCast(@intFromPtr(&decal_color)),
        );
    }

    enc.endFrame();
    _ = enc.finish();
    return @intCast(@intFromPtr(&cmd_buf));
}

// ── Controls (wired via z-on-click) ──────────────────────────────────────────

export fn gldecals_move_left() void {
    decal_phi -= 0.25;
    decal_dirty = true;
}

export fn gldecals_move_right() void {
    decal_phi += 0.25;
    decal_dirty = true;
}

export fn gldecals_move_up() void {
    decal_theta = @max(0.15, decal_theta - 0.25);
    decal_dirty = true;
}

export fn gldecals_move_down() void {
    decal_theta = @min(pi - 0.15, decal_theta + 0.25);
    decal_dirty = true;
}

export fn gldecals_grow() void {
    decal_size[0] = @min(1.5, decal_size[0] + 0.1);
    decal_size[1] = @min(1.5, decal_size[1] + 0.1);
    decal_dirty = true;
}

export fn gldecals_shrink() void {
    decal_size[0] = @max(0.1, decal_size[0] - 0.1);
    decal_size[1] = @max(0.1, decal_size[1] - 0.1);
    decal_dirty = true;
}

export fn gldecals_freeze() void {
    frozen = true;
}

export fn gldecals_unfreeze() void {
    frozen = false;
}
