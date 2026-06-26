//! verve.gl billboard / points demo — drives the /gl-points canvas.
//!
//! Renders a particle cloud (N=2000 round soft points, additive blend, CPU
//! upward-drift sim) and one textured disc sprite (alpha blend, sizeAttenuation
//! OFF). Both are driven by `Encoder.drawBillboards` — the Slice 1 billboard
//! primitive (wire tag 42, variant_billboard).
//!
//! STRUCTURE: singleton statics (instance buf + velocities in chunk linear
//! memory, NOT frame stack — stack is 64KB), a send-once resource block, a
//! frame export returning cmd_buf pointer every frame.

const verve = @import("verve");
const gl = verve.gl;

extern "verve" fn gl_start(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;
extern "verve" fn gl_start_gpu(ref_handle: i32, name_ptr: [*]const u8, name_len: u32) void;
extern "verve" fn gl_webgpu_available() i32;

// ── Constants ─────────────────────────────────────────────────────────────────

/// Particle count. 2000×36B = 72KB in chunk static memory — within budget.
const N: usize = 2000;

/// GPU resource handles (stable identifiers the JS bridge tracks).
const h_shader: u32 = 1;
const h_particle_buf: u32 = 2;
const h_sprite_buf: u32 = 3;
const h_sprite_tex: u32 = 4;

/// Frame fn name passed to gl_start / gl_start_gpu.
const frame_export: []const u8 = "glpoints_frame";

// ── Statics (chunk linear memory — NOT frame stack) ──────────────────────────

var canvas_handle: ?i32 = null;
var use_webgpu: bool = false;
var resources_sent: bool = false;
var frozen: bool = false;

/// Toggles wired to z-on-click controls.
var attenuation_on: bool = true; // sizeAttenuation: particle size in world-units
var additive_on: bool = true; // additive blend for particle cloud

// ── Particle cloud (N=2000) ───────────────────────────────────────────────────

// Instance buffer layout (9 f32 = 36 B per record):
//   [0] cx  [1] cy  [2] cz    — center (world space)
//   [3] size                  — world-unit radius (sizeAttenuation=ON)
//   [4] r  [5] g  [6] b  [7] a  — color
//   [8] rot                   — billboard rotation (radians)
var particle_buf: [N * 9]f32 = undefined; // 72 000 B

// Per-particle velocity — CPU-only, never uploaded.
var velocities: [N * 3]f32 = undefined; // 24 000 B

// ── Sprite (1 disc billboard) ─────────────────────────────────────────────────

// One static sprite record at world position (0, 4, 0).
// sizeAttenuation=OFF (flags bit0=0), so size is in view-space NDC half-extent.
var sprite_buf: [9]f32 = .{
    0.0, 4.0, 0.0, // center: slightly above the cloud
    0.15, // size (screen-constant — no world-unit scaling)
    1.0, 1.0, 1.0, 1.0, // color: white so texture colours show through
    0.0, // rot
};

// 16×16 disc sprite texture (RGBA8, linear).
// Built at runtime in buildSpriteTexture() called from hydrate.
var sprite_tex_data: [16 * 16 * 4]u8 = undefined;

// ── STABLE statics (addresses carried in draw records; read after frame fn) ──

var view_mat: [16]f32 = undefined;
var proj_mat: [16]f32 = undefined;

// cmd_buf sizing:
//   one-time: createShader~28 + createTexture~24 + createBuffer(sprite)~20 = 72B
//   per-frame: createBuffer(particle)~20 + beginFrame~20 + setPipeline×2~24
//              + drawBillboards×2~60 + endFrame~8 = ~132B
//   total max: ~204B — 2048B gives ample headroom.
var cmd_buf: [2048]u8 = undefined;

// ── PRNG (deterministic, seeded per-particle) ─────────────────────────────────

fn lcg(seed: u32) u32 {
    return seed *% 1664525 +% 1013904223;
}

fn randUnit(seed: *u32) f32 {
    seed.* = lcg(seed.*);
    return @as(f32, @floatFromInt(seed.* >> 8)) / 16777215.0;
}

fn randRange(seed: *u32, lo: f32, hi: f32) f32 {
    return lo + randUnit(seed) * (hi - lo);
}

// ── Init helpers ──────────────────────────────────────────────────────────────

fn initParticles() void {
    var seed: u32 = 0xdeadbeef;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const b = i * 9;
        const v = i * 3;
        // Scatter in an 8×6×8 box centred at the origin.
        particle_buf[b + 0] = randRange(&seed, -4.0, 4.0); // cx
        particle_buf[b + 1] = randRange(&seed, -3.0, 3.0); // cy
        particle_buf[b + 2] = randRange(&seed, -4.0, 4.0); // cz
        particle_buf[b + 3] = randRange(&seed, 0.05, 0.14); // size (world units)
        // Colour: blue–cyan–white nebula palette.
        const t = randUnit(&seed);
        particle_buf[b + 4] = t * 0.35; // r
        particle_buf[b + 5] = 0.4 + t * 0.6; // g
        particle_buf[b + 6] = 0.8 + t * 0.2; // b
        particle_buf[b + 7] = randRange(&seed, 0.3, 0.9); // a
        particle_buf[b + 8] = 0.0; // rot
        // Velocity: mostly upward with slight horizontal wander.
        velocities[v + 0] = randRange(&seed, -0.6, 0.6); // vx
        velocities[v + 1] = randRange(&seed, 0.3, 1.2); // vy (upward)
        velocities[v + 2] = randRange(&seed, -0.6, 0.6); // vz
    }
}

fn buildSpriteTexture() void {
    // 16×16 disc: golden inner (r≤5), white ring (5<r≤7), transparent outside.
    var py: usize = 0;
    while (py < 16) : (py += 1) {
        var px: usize = 0;
        while (px < 16) : (px += 1) {
            const dx = @as(f32, @floatFromInt(px)) - 7.5;
            const dy = @as(f32, @floatFromInt(py)) - 7.5;
            const r2 = dx * dx + dy * dy;
            const base = (py * 16 + px) * 4;
            if (r2 <= 25.0) { // inner disc r≤5
                sprite_tex_data[base + 0] = 255;
                sprite_tex_data[base + 1] = 200;
                sprite_tex_data[base + 2] = 50;
                sprite_tex_data[base + 3] = 255;
            } else if (r2 <= 49.0) { // ring 5<r≤7
                sprite_tex_data[base + 0] = 255;
                sprite_tex_data[base + 1] = 255;
                sprite_tex_data[base + 2] = 255;
                sprite_tex_data[base + 3] = 255;
            } else { // transparent
                sprite_tex_data[base + 0] = 0;
                sprite_tex_data[base + 1] = 0;
                sprite_tex_data[base + 2] = 0;
                sprite_tex_data[base + 3] = 0;
            }
        }
    }
}

// ── Particle sim ──────────────────────────────────────────────────────────────

fn tickParticles(dt_s: f32) void {
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const b = i * 9;
        const v = i * 3;
        particle_buf[b + 0] += velocities[v + 0] * dt_s;
        particle_buf[b + 1] += velocities[v + 1] * dt_s;
        particle_buf[b + 2] += velocities[v + 2] * dt_s;
        // Wrap: particle leaving top → respawn at bottom (same x,z).
        if (particle_buf[b + 1] > 4.0) particle_buf[b + 1] -= 8.0;
    }
}

// ── hydrate ───────────────────────────────────────────────────────────────────

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;

    resources_sent = false;
    frozen = false;
    attenuation_on = true;
    additive_on = true;
    use_webgpu = gl_webgpu_available() != 0;
    canvas_handle = verve.queryRef(@as([]const u8, "glpoints-canvas"));

    initParticles();
    buildSpriteTexture();

    if (canvas_handle) |h| {
        if (use_webgpu)
            gl_start_gpu(h, frame_export.ptr, frame_export.len)
        else
            gl_start(h, frame_export.ptr, frame_export.len);
    }
}

// ── frame export ──────────────────────────────────────────────────────────────

export fn glpoints_frame(dt_ms: f32, width: u32, height: u32) u32 {
    // Advance particle simulation (capped at 100ms to avoid spiral on tab hide).
    const dt_s = @min(dt_ms, 100.0) * 0.001;
    if (!frozen) tickParticles(dt_s);

    // Camera: fixed position looking at the origin (no orbit — particle motion
    // provides the visual dynamics; freeze stops the sim, not the camera).
    const aspect = @as(f32, @floatFromInt(width)) /
        @as(f32, @floatFromInt(@max(height, 1)));
    proj_mat = gl.math.Mat4.perspective(1.0, aspect, 0.1, 200.0).m;
    view_mat = gl.math.Mat4.lookAt(
        gl.math.Vec3.init(3.0, 2.5, 12.0),
        gl.math.Vec3.init(0.0, 0.0, 0.0),
        gl.math.Vec3.init(0.0, 1.0, 0.0),
    ).m;

    // Particle billboard flags: bit0=sizeAttenuation, bit1=round (soft disc).
    const particle_flags: u32 = (if (attenuation_on) @as(u32, 1) else 0) | 2;
    // Particle blend state.
    const particle_state: u32 = if (additive_on)
        gl.command.state_depth_test | gl.command.state_blend_add
    else
        gl.command.state_blend;

    var enc = gl.Encoder.init(&cmd_buf);

    if (!resources_sent) {
        resources_sent = true;

        // Upload the billboard shader (variant_billboard, standalone pair).
        if (use_webgpu) {
            const w = gl.command.wgslBillboard();
            enc.createShader(
                h_shader,
                gl.command.variant_billboard,
                @intCast(@intFromPtr(w.ptr)),
                @intCast(w.len),
                0,
                0,
            );
        } else {
            const vs = gl.command.billboardVertexSrc();
            const fs = gl.command.billboardFragmentSrc();
            enc.createShader(
                h_shader,
                gl.command.variant_billboard,
                @intCast(@intFromPtr(vs.ptr)),
                @intCast(vs.len),
                @intCast(@intFromPtr(fs.ptr)),
                @intCast(fs.len),
            );
        }

        // Upload the procedural disc sprite texture (RGBA8, linear).
        enc.createTexture(
            h_sprite_tex,
            16,
            16,
            @intCast(@intFromPtr(&sprite_tex_data)),
            @sizeOf(@TypeOf(sprite_tex_data)),
        );

        // Upload the static sprite instance buffer (36 B, one billboard).
        enc.createBuffer(
            h_sprite_buf,
            .vertex,
            @intCast(@intFromPtr(&sprite_buf)),
            @sizeOf(@TypeOf(sprite_buf)),
        );
    }

    // Re-upload particle instance buffer every frame (positions change per tick).
    enc.createBuffer(
        h_particle_buf,
        .vertex,
        @intCast(@intFromPtr(&particle_buf)),
        @sizeOf(@TypeOf(particle_buf)),
    );

    // ── Draw ────────────────────────────────────────────────────────────────

    enc.beginFrame(.{ 0.0, 0.0, 0.0, 1.0 }, width, height);

    // 1. Particle cloud: round soft points, additive (or alpha-over) blend.
    enc.setPipeline(h_shader, particle_state);
    enc.drawBillboards(
        h_particle_buf,
        N,
        0, // tex_handle 0 → white dummy (no texture needed for round points)
        @intCast(@intFromPtr(&view_mat)),
        @intCast(@intFromPtr(&proj_mat)),
        particle_flags,
    );

    // 2. Textured disc sprite: sizeAttenuation=OFF (flags=0), normal alpha blend.
    enc.setPipeline(h_shader, gl.command.state_blend);
    enc.drawBillboards(
        h_sprite_buf,
        1, // one sprite
        h_sprite_tex,
        @intCast(@intFromPtr(&view_mat)),
        @intCast(@intFromPtr(&proj_mat)),
        0, // flags=0: no sizeAttenuation, no round discard (tex alpha clips shape)
    );

    enc.endFrame();
    _ = enc.finish();
    return @intCast(@intFromPtr(&cmd_buf));
}

// ── Controls (wired to /gl-points buttons via z-on-click) ────────────────────

export fn glpoints_toggle_attenuation() void {
    attenuation_on = !attenuation_on;
}

export fn glpoints_toggle_additive() void {
    additive_on = !additive_on;
}

export fn glpoints_freeze() void {
    frozen = true;
}

export fn glpoints_unfreeze() void {
    frozen = false;
}
