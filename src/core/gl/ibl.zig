//! Pure-Zig build-time IBL (image-based lighting) prefilter math.
//!
//! Turns an equirectangular linear-RGB environment (from hdr.zig) into the
//! split-sum IBL inputs a WebGL2 PBR shader needs:
//!   - a cubemap of the environment (`equirectToCube`),
//!   - a cosine-convolved irradiance cube for diffuse (`irradiance`),
//!   - GGX-importance-sampled specular prefilter mips (`prefilter`), and
//!   - the Karis split-sum BRDF integration LUT (`brdfLut`).
//! Plus RGBA16F packing helpers for `.venv` / GPU upload and a native
//! reference of the in-shader ACES tonemap fit.
//!
//! tools/gl_asset_gen.zig drives the pipeline; the WebGL2 PBR shader consumes
//! the packed result. The cube face order/orientation feeds directly into
//! texImage2D(TEXTURE_CUBE_MAP_POSITIVE_X + f) uploads, so the face table
//! below is binding (must match WebGL2 cubemap conventions).
//!
//! Native-side asset pipeline. Island chunks must not reference this — Zig's
//! lazy analysis makes the bare import free; only actual references would
//! pull it into wasm.
//!
//! Errors: `error.OutOfMemory`.

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

// ── public surface ──────────────────────────────────────────────────────────

/// 6 faces, GL order +X,-X,+Y,-Y,+Z,-Z; each face size*size*3 f32 RGB.
pub const Cube = struct {
    size: u32,
    faces: [6][]f32,

    pub fn deinit(self: *Cube, alloc: Allocator) void {
        for (self.faces) |f| {
            // A partial cube (errdefer cleanup mid-build) leaves later faces
            // as empty slices; freeing &.{} is a no-op, so this is safe.
            alloc.free(f);
        }
        self.* = undefined;
    }
};

// ── small vec helpers (std.math only; module is self-contained) ───────────────

const V3 = struct {
    x: f32,
    y: f32,
    z: f32,

    inline fn add(a: V3, b: V3) V3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }
    inline fn sub(a: V3, b: V3) V3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }
    inline fn scale(a: V3, s: f32) V3 {
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }
    inline fn dot(a: V3, b: V3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }
    inline fn cross(a: V3, b: V3) V3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }
    inline fn normalize(a: V3) V3 {
        const len = @sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
        if (len <= 0.0) return .{ .x = 0, .y = 0, .z = 1 };
        const inv = 1.0 / len;
        return .{ .x = a.x * inv, .y = a.y * inv, .z = a.z * inv };
    }
};

// ── cube face direction table ────────────────────────────────────────────────
//
// Standard GL cubemap layout. For each face, given texel center coords
// u,v ∈ [-1,1] (from ((px+0.5)/size)*2 - 1), the (un-normalized) world
// direction is:
//
//   face | index | dir(u,v)
//   -----+-------+----------------------
//   +X   |   0   | ( 1, -v, -u)
//   -X   |   1   | (-1, -v,  u)
//   +Y   |   2   | ( u,  1,  v)
//   -Y   |   3   | ( u, -1, -v)
//   +Z   |   4   | ( u, -v,  1)
//   -Z   |   5   | (-u, -v, -1)
//
// MUST match WebGL2 TEXTURE_CUBE_MAP_POSITIVE_X.. conventions so runtime
// reflections aren't flipped.

inline fn faceDir(face: u32, u: f32, v: f32) V3 {
    const d: V3 = switch (face) {
        0 => .{ .x = 1, .y = -v, .z = -u }, // +X
        1 => .{ .x = -1, .y = -v, .z = u }, // -X
        2 => .{ .x = u, .y = 1, .z = v }, // +Y
        3 => .{ .x = u, .y = -1, .z = -v }, // -Y
        4 => .{ .x = u, .y = -v, .z = 1 }, // +Z
        5 => .{ .x = -u, .y = -v, .z = -1 }, // -Z
        else => unreachable,
    };
    return d.normalize();
}

// ── equirect sampling ────────────────────────────────────────────────────────
//
// Equirect mapping convention (the probe test pins this):
//   u = atan2(d.x, -d.z) / (2π) + 0.5
//   v = acos(clamp(d.y, -1, 1)) / π        (v = 0 at +Y top)
// Sampling: bilinear with x-wrap (u), y-clamp (v).

inline fn dirToEquirectUv(d: V3) [2]f32 {
    const u = math.atan2(d.x, -d.z) / (2.0 * math.pi) + 0.5;
    const v = math.acos(math.clamp(d.y, -1.0, 1.0)) / math.pi;
    return .{ u, v };
}

fn sampleEquirect(rgb: []const f32, w: u32, h: u32, u: f32, v: f32) [3]f32 {
    const wf: f32 = @floatFromInt(w);
    const hf: f32 = @floatFromInt(h);

    // Texel-space coords (pixel centers at integer + 0.5).
    var fx = u * wf - 0.5;
    const fy = math.clamp(v * hf - 0.5, 0.0, hf - 1.0);

    // x wraps.
    fx = @mod(fx, wf);
    if (fx < 0) fx += wf;

    const x0: u32 = @intFromFloat(@floor(fx));
    const x1: u32 = (x0 + 1) % w;
    const tx = fx - @floor(fx);

    const y0: u32 = @intFromFloat(@floor(fy));
    const y1: u32 = @min(y0 + 1, h - 1);
    const ty = fy - @floor(fy);

    var out: [3]f32 = .{ 0, 0, 0 };
    inline for (0..3) |c| {
        const p00 = rgb[(@as(usize, y0) * w + x0) * 3 + c];
        const p10 = rgb[(@as(usize, y0) * w + x1) * 3 + c];
        const p01 = rgb[(@as(usize, y1) * w + x0) * 3 + c];
        const p11 = rgb[(@as(usize, y1) * w + x1) * 3 + c];
        const top = p00 * (1 - tx) + p10 * tx;
        const bot = p01 * (1 - tx) + p11 * tx;
        out[c] = top * (1 - ty) + bot * ty;
    }
    return out;
}

/// Equirectangular linear-RGB env → cubemap. See face table + mapping above.
pub fn equirectToCube(alloc: Allocator, rgb: []const f32, w: u32, h: u32, face_size: u32) !Cube {
    var cube = try allocCube(alloc, face_size);
    errdefer cube.deinit(alloc);

    const sz: f32 = @floatFromInt(face_size);
    for (0..6) |face| {
        const f: u32 = @intCast(face);
        var py: u32 = 0;
        while (py < face_size) : (py += 1) {
            const v = (@as(f32, @floatFromInt(py)) + 0.5) / sz * 2.0 - 1.0;
            var px: u32 = 0;
            while (px < face_size) : (px += 1) {
                const uu = (@as(f32, @floatFromInt(px)) + 0.5) / sz * 2.0 - 1.0;
                const dir = faceDir(f, uu, v);
                const uv = dirToEquirectUv(dir);
                const col = sampleEquirect(rgb, w, h, uv[0], uv[1]);
                const idx = (@as(usize, py) * face_size + px) * 3;
                cube.faces[f][idx + 0] = col[0];
                cube.faces[f][idx + 1] = col[1];
                cube.faces[f][idx + 2] = col[2];
            }
        }
    }
    return cube;
}

// ── cube sampling (direction → face → bilinear) ───────────────────────────────

/// Select cube face + face-local uv ∈ [-1,1] for a world direction.
/// Inverse of faceDir: major axis picks the face; the other two components,
/// divided by |major|, give (uc, vc); then u,v solved per the face table.
fn dirToFaceUv(d: V3) struct { face: u32, u: f32, v: f32 } {
    const ax = @abs(d.x);
    const ay = @abs(d.y);
    const az = @abs(d.z);

    var face: u32 = 0;
    var uc: f32 = 0;
    var vc: f32 = 0;
    var ma: f32 = 0;

    if (ax >= ay and ax >= az) {
        ma = ax;
        if (d.x >= 0) {
            // +X: u=-z/ma, v=-y/ma  (dir=(1,-v,-u) ⇒ -u=z/ma, -v=y/ma)
            face = 0;
            uc = -d.z;
            vc = -d.y;
        } else {
            // -X: dir=(-1,-v,u) ⇒ u=z/ma, -v=y/ma
            face = 1;
            uc = d.z;
            vc = -d.y;
        }
    } else if (ay >= ax and ay >= az) {
        ma = ay;
        if (d.y >= 0) {
            // +Y: dir=(u,1,v) ⇒ u=x/ma, v=z/ma
            face = 2;
            uc = d.x;
            vc = d.z;
        } else {
            // -Y: dir=(u,-1,-v) ⇒ u=x/ma, -v=z/ma
            face = 3;
            uc = d.x;
            vc = -d.z;
        }
    } else {
        ma = az;
        if (d.z >= 0) {
            // +Z: dir=(u,-v,1) ⇒ u=x/ma, -v=y/ma
            face = 4;
            uc = d.x;
            vc = -d.y;
        } else {
            // -Z: dir=(-u,-v,-1) ⇒ -u=x/ma, -v=y/ma
            face = 5;
            uc = -d.x;
            vc = -d.y;
        }
    }
    const inv = 1.0 / ma;
    return .{ .face = face, .u = uc * inv, .v = vc * inv };
}

/// Bilinear sample of a cube at a world direction (u,v wrap clamped to face).
fn sampleCube(c: Cube, d: V3) [3]f32 {
    const sel = dirToFaceUv(d);
    const sz: f32 = @floatFromInt(c.size);
    // u,v ∈ [-1,1] → texel space.
    const fx = math.clamp((sel.u * 0.5 + 0.5) * sz - 0.5, 0.0, sz - 1.0);
    const fy = math.clamp((sel.v * 0.5 + 0.5) * sz - 0.5, 0.0, sz - 1.0);

    const x0: u32 = @intFromFloat(@floor(fx));
    const x1: u32 = @min(x0 + 1, c.size - 1);
    const tx = fx - @floor(fx);
    const y0: u32 = @intFromFloat(@floor(fy));
    const y1: u32 = @min(y0 + 1, c.size - 1);
    const ty = fy - @floor(fy);

    const fp = c.faces[sel.face];
    var out: [3]f32 = .{ 0, 0, 0 };
    inline for (0..3) |ch| {
        const p00 = fp[(@as(usize, y0) * c.size + x0) * 3 + ch];
        const p10 = fp[(@as(usize, y0) * c.size + x1) * 3 + ch];
        const p01 = fp[(@as(usize, y1) * c.size + x0) * 3 + ch];
        const p11 = fp[(@as(usize, y1) * c.size + x1) * 3 + ch];
        const top = p00 * (1 - tx) + p10 * tx;
        const bot = p01 * (1 - tx) + p11 * tx;
        out[ch] = top * (1 - ty) + bot * ty;
    }
    return out;
}

// ── low-discrepancy sampling ──────────────────────────────────────────────────

/// Van der Corput radical inverse (base 2, bit reversal).
inline fn radicalInverseVdC(bits_in: u32) f32 {
    var bits = bits_in;
    bits = (bits << 16) | (bits >> 16);
    bits = ((bits & 0x55555555) << 1) | ((bits & 0xAAAAAAAA) >> 1);
    bits = ((bits & 0x33333333) << 2) | ((bits & 0xCCCCCCCC) >> 2);
    bits = ((bits & 0x0F0F0F0F) << 4) | ((bits & 0xF0F0F0F0) >> 4);
    bits = ((bits & 0x00FF00FF) << 8) | ((bits & 0xFF00FF00) >> 8);
    return @as(f32, @floatFromInt(bits)) * 2.3283064365386963e-10; // / 2^32
}

inline fn hammersley(i: u32, n: u32) [2]f32 {
    return .{ @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n)), radicalInverseVdC(i) };
}

/// Tangent frame around N: pick a non-parallel up, then T,B.
inline fn tangentFrame(n: V3) struct { t: V3, b: V3 } {
    const up: V3 = if (@abs(n.z) < 0.999) .{ .x = 0, .y = 0, .z = 1 } else .{ .x = 1, .y = 0, .z = 0 };
    const t = V3.cross(up, n).normalize();
    const b = V3.cross(n, t);
    return .{ .t = t, .b = b };
}

/// GGX importance sample. Xi ∈ [0,1)², α = roughness². Returns world H.
inline fn importanceSampleGGX(xi: [2]f32, n: V3, roughness: f32) V3 {
    const a = roughness * roughness;
    const phi = 2.0 * math.pi * xi[0];
    const cos_t = @sqrt((1.0 - xi[1]) / (1.0 + (a * a - 1.0) * xi[1]));
    const sin_t = @sqrt(@max(0.0, 1.0 - cos_t * cos_t));

    // Local-space half vector.
    const hl = V3{ .x = @cos(phi) * sin_t, .y = @sin(phi) * sin_t, .z = cos_t };

    const frame = tangentFrame(n);
    return V3.add(V3.add(frame.t.scale(hl.x), frame.b.scale(hl.y)), n.scale(hl.z)).normalize();
}

// ── irradiance (diffuse) ──────────────────────────────────────────────────────

/// Cosine-convolved irradiance cube. For each output texel direction N,
/// cosine-weighted hemisphere sampling; the cosine pdf cancels cosθ/π so the
/// estimator is the plain mean of sampled radiance. Constant env L → output L.
pub fn irradiance(alloc: Allocator, env: Cube, out_size: u32, samples: u32) !Cube {
    var cube = try allocCube(alloc, out_size);
    errdefer cube.deinit(alloc);

    const sz: f32 = @floatFromInt(out_size);
    const ns = @max(@as(u32, 1), samples);
    const inv_n = 1.0 / @as(f32, @floatFromInt(ns));

    for (0..6) |face| {
        const f: u32 = @intCast(face);
        var py: u32 = 0;
        while (py < out_size) : (py += 1) {
            const v = (@as(f32, @floatFromInt(py)) + 0.5) / sz * 2.0 - 1.0;
            var px: u32 = 0;
            while (px < out_size) : (px += 1) {
                const uu = (@as(f32, @floatFromInt(px)) + 0.5) / sz * 2.0 - 1.0;
                const n = faceDir(f, uu, v);
                const frame = tangentFrame(n);

                var acc: [3]f32 = .{ 0, 0, 0 };
                var i: u32 = 0;
                while (i < ns) : (i += 1) {
                    const xi = hammersley(i, ns);
                    // Cosine-weighted hemisphere in local space.
                    const phi = 2.0 * math.pi * xi[0];
                    const cos_t = @sqrt(1.0 - xi[1]); // cosθ = sqrt(1-u2)
                    const sin_t = @sqrt(xi[1]); // sinθ = sqrt(u2)
                    const lx = @cos(phi) * sin_t;
                    const ly = @sin(phi) * sin_t;
                    const lz = cos_t;
                    const dir = V3.add(V3.add(frame.t.scale(lx), frame.b.scale(ly)), n.scale(lz)).normalize();
                    const col = sampleCube(env, dir);
                    acc[0] += col[0];
                    acc[1] += col[1];
                    acc[2] += col[2];
                }
                const idx = (@as(usize, py) * out_size + px) * 3;
                cube.faces[f][idx + 0] = acc[0] * inv_n;
                cube.faces[f][idx + 1] = acc[1] * inv_n;
                cube.faces[f][idx + 2] = acc[2] * inv_n;
            }
        }
    }
    return cube;
}

// ── specular prefilter ────────────────────────────────────────────────────────

/// GGX importance-sampled prefilter for one roughness level.
/// roughness == 0 → direct bilinear env resample (mirror), no sampling loop.
pub fn prefilter(alloc: Allocator, env: Cube, out_size: u32, roughness: f32, samples: u32) !Cube {
    var cube = try allocCube(alloc, out_size);
    errdefer cube.deinit(alloc);

    const sz: f32 = @floatFromInt(out_size);
    const mirror = roughness <= 0.0;
    const ns = @max(@as(u32, 1), samples);

    for (0..6) |face| {
        const f: u32 = @intCast(face);
        var py: u32 = 0;
        while (py < out_size) : (py += 1) {
            const v = (@as(f32, @floatFromInt(py)) + 0.5) / sz * 2.0 - 1.0;
            var px: u32 = 0;
            while (px < out_size) : (px += 1) {
                const uu = (@as(f32, @floatFromInt(px)) + 0.5) / sz * 2.0 - 1.0;
                const n = faceDir(f, uu, v);

                var col: [3]f32 = .{ 0, 0, 0 };
                if (mirror) {
                    col = sampleCube(env, n);
                } else {
                    // Karis: N = V = R = texel dir.
                    const view = n;
                    var acc: [3]f32 = .{ 0, 0, 0 };
                    var w_sum: f32 = 0;
                    var i: u32 = 0;
                    while (i < ns) : (i += 1) {
                        const xi = hammersley(i, ns);
                        const hh = importanceSampleGGX(xi, n, roughness);
                        // L = reflect(-V, H) = 2*dot(V,H)*H - V
                        const l = V3.sub(hh.scale(2.0 * V3.dot(view, hh)), view).normalize();
                        const ndotl = V3.dot(n, l);
                        if (ndotl > 0.0) {
                            const c = sampleCube(env, l);
                            acc[0] += c[0] * ndotl;
                            acc[1] += c[1] * ndotl;
                            acc[2] += c[2] * ndotl;
                            w_sum += ndotl;
                        }
                    }
                    if (w_sum > 0.0) {
                        const inv = 1.0 / w_sum;
                        col = .{ acc[0] * inv, acc[1] * inv, acc[2] * inv };
                    } else {
                        col = sampleCube(env, n);
                    }
                }
                const idx = (@as(usize, py) * out_size + px) * 3;
                cube.faces[f][idx + 0] = col[0];
                cube.faces[f][idx + 1] = col[1];
                cube.faces[f][idx + 2] = col[2];
            }
        }
    }
    return cube;
}

// ── BRDF integration LUT ──────────────────────────────────────────────────────

/// Smith geometry G1 for IBL with k.
inline fn gSmithG1(n_dot_x: f32, k: f32) f32 {
    return n_dot_x / (n_dot_x * (1.0 - k) + k);
}

/// Karis split-sum BRDF LUT: size*size*2 f32 (A, B); x = NdotV, y = roughness.
/// Karis IBL geometry term uses k = (roughness²)/2.
pub fn brdfLut(alloc: Allocator, size: u32, samples: u32) ![]f32 {
    const out = try alloc.alloc(f32, @as(usize, size) * size * 2);
    errdefer alloc.free(out);

    const szf: f32 = @floatFromInt(size);
    const ns = @max(@as(u32, 1), samples);
    const inv_n = 1.0 / @as(f32, @floatFromInt(ns));
    const n = V3{ .x = 0, .y = 0, .z = 1 };

    var py: u32 = 0;
    while (py < size) : (py += 1) {
        const roughness = (@as(f32, @floatFromInt(py)) + 0.5) / szf;
        const k = (roughness * roughness) / 2.0;
        var px: u32 = 0;
        while (px < size) : (px += 1) {
            var n_dot_v = (@as(f32, @floatFromInt(px)) + 0.5) / szf;
            n_dot_v = math.clamp(n_dot_v, 1e-4, 1.0);
            const view = V3{ .x = @sqrt(1.0 - n_dot_v * n_dot_v), .y = 0, .z = n_dot_v };

            var a_sum: f32 = 0;
            var b_sum: f32 = 0;
            var i: u32 = 0;
            while (i < ns) : (i += 1) {
                const xi = hammersley(i, ns);
                const hh = importanceSampleGGX(xi, n, roughness);
                const l = V3.sub(hh.scale(2.0 * V3.dot(view, hh)), view);
                if (l.z > 0.0) {
                    const n_dot_l = math.clamp(l.z, 0.0, 1.0);
                    const n_dot_h = math.clamp(hh.z, 0.0, 1.0);
                    const v_dot_h = math.clamp(V3.dot(view, hh), 0.0, 1.0);
                    const g = gSmithG1(n_dot_l, k) * gSmithG1(n_dot_v, k);
                    const g_vis = (g * v_dot_h) / (n_dot_h * n_dot_v);
                    const fc = math.pow(f32, 1.0 - v_dot_h, 5.0);
                    a_sum += (1.0 - fc) * g_vis;
                    b_sum += fc * g_vis;
                }
            }
            const idx = (@as(usize, py) * size + px) * 2;
            out[idx + 0] = a_sum * inv_n;
            out[idx + 1] = b_sum * inv_n;
        }
    }
    return out;
}

// ── RGBA16F packing ───────────────────────────────────────────────────────────

const f16_max: f32 = 65504.0;

/// RGBA16F packing for .venv / GPU upload. Negative radiance clamped to 0,
/// large values clamped to 65504 before the f16 cast.
pub fn f16Bits(x: f32) u16 {
    const clamped = math.clamp(x, 0.0, f16_max);
    return @bitCast(@as(f16, @floatCast(clamped)));
}

/// Pack a cube to RGBA16F, face-major run. A = 1.0h. 6*size*size*4 u16.
pub fn cubeToRgba16f(alloc: Allocator, c: Cube) ![]u16 {
    const per_face = @as(usize, c.size) * c.size;
    const out = try alloc.alloc(u16, 6 * per_face * 4);
    errdefer alloc.free(out);

    const one: u16 = f16Bits(1.0);
    var o: usize = 0;
    for (c.faces) |fp| {
        var i: usize = 0;
        while (i < per_face) : (i += 1) {
            out[o + 0] = f16Bits(fp[i * 3 + 0]);
            out[o + 1] = f16Bits(fp[i * 3 + 1]);
            out[o + 2] = f16Bits(fp[i * 3 + 2]);
            out[o + 3] = one;
            o += 4;
        }
    }
    return out;
}

/// Pack a BRDF LUT (RG f32) to RGBA16F: R=A, G=B, B=0, A=1. size*size*4 u16.
pub fn lutToRgba16f(alloc: Allocator, ab: []const f32, size: u32) ![]u16 {
    const n = @as(usize, size) * size;
    const out = try alloc.alloc(u16, n * 4);
    errdefer alloc.free(out);

    const zero: u16 = f16Bits(0.0);
    const one: u16 = f16Bits(1.0);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        out[i * 4 + 0] = f16Bits(ab[i * 2 + 0]);
        out[i * 4 + 1] = f16Bits(ab[i * 2 + 1]);
        out[i * 4 + 2] = zero;
        out[i * 4 + 3] = one;
    }
    return out;
}

// ── ACES tonemap reference ────────────────────────────────────────────────────

/// Native reference of the in-shader ACES fit (Narkowicz):
///   (x*(2.51x+0.03)) / (x*(2.43x+0.59)+0.14), clamped to [0,1].
pub fn acesTonemap(x: f32) f32 {
    const num = x * (2.51 * x + 0.03);
    const den = x * (2.43 * x + 0.59) + 0.14;
    return math.clamp(num / den, 0.0, 1.0);
}

// ── internal alloc helper ─────────────────────────────────────────────────────

fn allocCube(alloc: Allocator, size: u32) !Cube {
    var cube = Cube{ .size = size, .faces = .{ &.{}, &.{}, &.{}, &.{}, &.{}, &.{} } };
    errdefer cube.deinit(alloc);
    const n = @as(usize, size) * size * 3;
    for (0..6) |i| {
        cube.faces[i] = try alloc.alloc(f32, n);
    }
    return cube;
}

// ── tests ─────────────────────────────────────────────────────────────────────

fn constEquirect(alloc: Allocator, w: u32, h: u32, val: f32) ![]f32 {
    const rgb = try alloc.alloc(f32, @as(usize, w) * h * 3);
    for (rgb) |*c| c.* = val;
    return rgb;
}

test "ibl: constant-color equirect → cube faces all equal" {
    const alloc = std.testing.allocator;
    const vals = [_]f32{ 1.0, 0.5, 0.25 };
    for (vals) |val| {
        const rgb = try constEquirect(alloc, 16, 8, val);
        defer alloc.free(rgb);
        var cube = try equirectToCube(alloc, rgb, 16, 8, 8);
        defer cube.deinit(alloc);
        for (cube.faces) |fp| {
            for (fp) |c| {
                try std.testing.expectApproxEqAbs(val, c, 1e-4);
            }
        }
    }
}

test "ibl: directional probe → +Z face center brightest" {
    // Mapping: u = atan2(d.x,-d.z)/(2π)+0.5, v = acos(d.y)/π.
    // +Z face center direction = (0,0,1): atan2(0,-1)=π → u=1.0 (wraps to 0),
    // v = acos(0)/π = 0.5. So the texel for +Z center is column 0 (u≈0),
    // middle row (v=0.5). Place a single bright texel there.
    const alloc = std.testing.allocator;
    const w: u32 = 16;
    const h: u32 = 8;
    const rgb = try alloc.alloc(f32, @as(usize, w) * h * 3);
    defer alloc.free(rgb);
    for (rgb) |*c| c.* = 0.0;
    // Bright texel at column 0, row h/2 (v center). u-center of col 0 = 0.5/16.
    const bright_row = h / 2;
    const bidx = (@as(usize, bright_row) * w + 0) * 3;
    rgb[bidx + 0] = 100.0;
    rgb[bidx + 1] = 100.0;
    rgb[bidx + 2] = 100.0;

    const fsz: u32 = 16;
    var cube = try equirectToCube(alloc, rgb, w, h, fsz);
    defer cube.deinit(alloc);

    // Compare each face's center texel; +Z (face 4) center must be brightest.
    const cx = fsz / 2;
    const cy = fsz / 2;
    const center_idx = (@as(usize, cy) * fsz + cx) * 3;
    const zpos_center = cube.faces[4][center_idx];
    try std.testing.expect(zpos_center > 0.0);
    for (cube.faces, 0..) |fp, fi| {
        if (fi == 4) continue;
        try std.testing.expect(zpos_center > fp[center_idx]);
    }
}

test "ibl: irradiance of constant env == constant" {
    const alloc = std.testing.allocator;
    const val: f32 = 0.6;
    const rgb = try constEquirect(alloc, 16, 8, val);
    defer alloc.free(rgb);
    var env = try equirectToCube(alloc, rgb, 16, 8, 8);
    defer env.deinit(alloc);
    var irr = try irradiance(alloc, env, 8, 32);
    defer irr.deinit(alloc);
    for (irr.faces) |fp| {
        for (fp) |c| {
            try std.testing.expectApproxEqAbs(val, c, 2e-2);
        }
    }
}

test "ibl: prefilter of constant env == constant (rough 0 and 1)" {
    const alloc = std.testing.allocator;
    const val: f32 = 0.42;
    const rgb = try constEquirect(alloc, 16, 8, val);
    defer alloc.free(rgb);
    var env = try equirectToCube(alloc, rgb, 16, 8, 8);
    defer env.deinit(alloc);

    var p0 = try prefilter(alloc, env, 8, 0.0, 32);
    defer p0.deinit(alloc);
    for (p0.faces) |fp| {
        for (fp) |c| try std.testing.expectApproxEqAbs(val, c, 1e-4);
    }

    var p1 = try prefilter(alloc, env, 8, 1.0, 32);
    defer p1.deinit(alloc);
    for (p1.faces) |fp| {
        for (fp) |c| try std.testing.expectApproxEqAbs(val, c, 2e-2);
    }
}

test "ibl: brdfLut corner + energy sanity" {
    const alloc = std.testing.allocator;
    const size: u32 = 16;
    const lut = try brdfLut(alloc, size, 256);
    defer alloc.free(lut);

    // Texel nearest (NdotV≈1, roughness≈0): px = size-1 (NdotV high),
    // py = 0 (roughness low).
    const px = size - 1;
    const py: u32 = 0;
    const idx = (@as(usize, py) * size + px) * 2;
    const a = lut[idx + 0];
    const b = lut[idx + 1];
    try std.testing.expect(a >= 0.95 and a <= 1.0);
    try std.testing.expect(b <= 0.05);

    // Energy sanity for ALL texels.
    var i: usize = 0;
    while (i < @as(usize, size) * size) : (i += 1) {
        const aa = lut[i * 2 + 0];
        const bb = lut[i * 2 + 1];
        try std.testing.expect(aa >= 0.0);
        try std.testing.expect(bb >= 0.0);
        try std.testing.expect(aa + bb <= 1.02);
    }
}

test "ibl: f16Bits" {
    try std.testing.expectEqual(@as(u16, 0x3C00), f16Bits(1.0));
    try std.testing.expectEqual(f16Bits(65504.0), f16Bits(1.0e9));
    try std.testing.expectEqual(@as(u16, 0), f16Bits(0.0));
    // negative clamps to 0
    try std.testing.expectEqual(@as(u16, 0), f16Bits(-5.0));
}

test "ibl: acesTonemap" {
    try std.testing.expectEqual(@as(f32, 0.0), acesTonemap(0.0));
    try std.testing.expectApproxEqAbs(@as(f32, 0.8037), acesTonemap(1.0), 1e-3);
    try std.testing.expect(acesTonemap(1000.0) >= 0.99);
    // monotonic nondecreasing over [0,16].
    var prev: f32 = -1.0;
    var i: u32 = 0;
    while (i <= 160) : (i += 1) {
        const x = @as(f32, @floatFromInt(i)) * 0.1;
        const y = acesTonemap(x);
        try std.testing.expect(y >= prev - 1e-6);
        prev = y;
    }
}

test "ibl: cubeToRgba16f" {
    const alloc = std.testing.allocator;
    const size: u32 = 2;
    var cube = try allocCube(alloc, size);
    defer cube.deinit(alloc);
    // Distinct values per face/texel.
    for (cube.faces, 0..) |fp, fi| {
        for (fp, 0..) |*c, i| {
            c.* = @as(f32, @floatFromInt(fi)) + @as(f32, @floatFromInt(i)) * 0.01;
        }
    }
    const packed_data = try cubeToRgba16f(alloc, cube);
    defer alloc.free(packed_data);

    try std.testing.expectEqual(@as(usize, 6 * size * size * 4), packed_data.len);
    const one: u16 = f16Bits(1.0);
    // Every 4th element (alpha) == 1.0h; RGB match f16Bits of inputs.
    var o: usize = 0;
    for (cube.faces) |fp| {
        var i: usize = 0;
        while (i < @as(usize, size) * size) : (i += 1) {
            try std.testing.expectEqual(f16Bits(fp[i * 3 + 0]), packed_data[o + 0]);
            try std.testing.expectEqual(f16Bits(fp[i * 3 + 1]), packed_data[o + 1]);
            try std.testing.expectEqual(f16Bits(fp[i * 3 + 2]), packed_data[o + 2]);
            try std.testing.expectEqual(one, packed_data[o + 3]);
            o += 4;
        }
    }
}

test "ibl: lutToRgba16f" {
    const alloc = std.testing.allocator;
    const size: u32 = 2;
    const ab = try alloc.alloc(f32, @as(usize, size) * size * 2);
    defer alloc.free(ab);
    for (ab, 0..) |*c, i| c.* = @as(f32, @floatFromInt(i)) * 0.1;
    const packed_data = try lutToRgba16f(alloc, ab, size);
    defer alloc.free(packed_data);

    try std.testing.expectEqual(@as(usize, size * size * 4), packed_data.len);
    const zero: u16 = f16Bits(0.0);
    const one: u16 = f16Bits(1.0);
    var i: usize = 0;
    while (i < @as(usize, size) * size) : (i += 1) {
        try std.testing.expectEqual(f16Bits(ab[i * 2 + 0]), packed_data[i * 4 + 0]);
        try std.testing.expectEqual(f16Bits(ab[i * 2 + 1]), packed_data[i * 4 + 1]);
        try std.testing.expectEqual(zero, packed_data[i * 4 + 2]);
        try std.testing.expectEqual(one, packed_data[i * 4 + 3]);
    }
}
