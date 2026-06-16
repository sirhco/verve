/// Procedural textured-cube .glb builder.
/// Produces a complete GLB-2 binary: JSON chunk + BIN chunk.
/// BIN layout (fixed offsets):
///   [0..288)   POSITION   24 × vec3 f32  (288 bytes)
///   [288..576) NORMAL     24 × vec3 f32  (288 bytes)
///   [576..768) TEXCOORD_0 24 × vec2 f32  (192 bytes)
///   [768..840) indices    36 × u16       (72 bytes)
///   [840..)    PNG image  checkerboard 8×8 RGBA
const std = @import("std");
const png = @import("png.zig");
const hdr = @import("hdr.zig");

const Allocator = std.mem.Allocator;

// ── BIN-layout constants ──────────────────────────────────────────────────────

const bv_pos_off: u32 = 0;
const bv_pos_len: u32 = 24 * 3 * 4; // 288
const bv_nrm_off: u32 = bv_pos_off + bv_pos_len; // 288
const bv_nrm_len: u32 = 24 * 3 * 4; // 288
const bv_uv_off: u32 = bv_nrm_off + bv_nrm_len; // 576
const bv_uv_len: u32 = 24 * 2 * 4; // 192
const bv_idx_off: u32 = bv_uv_off + bv_uv_len; // 768
const bv_idx_len: u32 = 36 * 2; // 72
const bv_png_off: u32 = bv_idx_off + bv_idx_len; // 840

// ── accessor indices (matches JSON array order) ───────────────────────────────
const acc_pos: u32 = 0;
const acc_nrm: u32 = 1;
const acc_uv: u32 = 2;
const acc_idx: u32 = 3;

// ── bufferView indices ────────────────────────────────────────────────────────
const bv_pos: u32 = 0;
const bv_nrm: u32 = 1;
const bv_uv: u32 = 2;
const bv_idx_bv: u32 = 3;
const bv_png: u32 = 4;

// ── geometry data ─────────────────────────────────────────────────────────────

// 6 faces × 4 vertices = 24 vertices.
// Each face: 4 positions, 1 normal (all verts share it), 4 uvs.
// Face description: [normal xyz] then 4 vertex positions.
const Face = struct {
    nx: f32,
    ny: f32,
    nz: f32,
    // 4 corner positions (xyz each)
    v: [4][3]f32,
};

// Corner order per face is CCW viewed from outside, starting at uv(0,0):
// corner 0 = uv(0,0), 1 = +u, 2 = +u+v, 3 = +v, so triangles {0,1,2, 0,2,3}
// are CCW front faces under WebGL's default frontFace(CCW) + cullFace(BACK),
// and each face's tangent (+u world direction) is corner0→corner1.
// Verified per face: cross(v1−v0, v2−v0) points along the stored normal.
// (P2 shipped ±X/±Y corner rows wound CW-from-outside — those four exterior
// faces were culled and the cube rendered inside-out; caught by P4 e2e.)

const faces = [6]Face{
    // +X
    .{ .nx = 1, .ny = 0, .nz = 0, .v = .{
        .{ 1, -1, 1 },
        .{ 1, -1, -1 },
        .{ 1, 1, -1 },
        .{ 1, 1, 1 },
    } },
    // -X
    .{ .nx = -1, .ny = 0, .nz = 0, .v = .{
        .{ -1, -1, -1 },
        .{ -1, -1, 1 },
        .{ -1, 1, 1 },
        .{ -1, 1, -1 },
    } },
    // +Y
    .{ .nx = 0, .ny = 1, .nz = 0, .v = .{
        .{ -1, 1, 1 },
        .{ 1, 1, 1 },
        .{ 1, 1, -1 },
        .{ -1, 1, -1 },
    } },
    // -Y
    .{ .nx = 0, .ny = -1, .nz = 0, .v = .{
        .{ -1, -1, -1 },
        .{ 1, -1, -1 },
        .{ 1, -1, 1 },
        .{ -1, -1, 1 },
    } },
    // +Z
    .{ .nx = 0, .ny = 0, .nz = 1, .v = .{
        .{ -1, -1, 1 },
        .{ 1, -1, 1 },
        .{ 1, 1, 1 },
        .{ -1, 1, 1 },
    } },
    // -Z
    .{ .nx = 0, .ny = 0, .nz = -1, .v = .{
        .{ 1, -1, -1 },
        .{ -1, -1, -1 },
        .{ -1, 1, -1 },
        .{ 1, 1, -1 },
    } },
};

// UV per vertex within a face: (0,0),(1,0),(1,1),(0,1)
const face_uvs = [4][2]f32{
    .{ 0, 0 },
    .{ 1, 0 },
    .{ 1, 1 },
    .{ 0, 1 },
};

// ── public API ────────────────────────────────────────────────────────────────

/// Complete .glb: one mesh ("DemoCube"), one primitive, POSITION/NORMAL/
/// TEXCOORD_0 + u16 indices, one material (baseColorTexture -> embedded
/// 8x8 checkerboard PNG, baseColorFactor (1,1,1,1)), one node, one scene.
/// 24 vertices (per-face normals/uvs), 36 indices.
pub fn texturedCubeGlb(alloc: Allocator) ![]u8 {
    // ── 1. Build checkerboard PNG ─────────────────────────────────────────────
    var checker: [8 * 8 * 4]u8 = undefined;
    for (0..8) |row| {
        for (0..8) |col| {
            const idx = (row * 8 + col) * 4;
            const light = (row + col) % 2 == 0;
            if (light) {
                checker[idx + 0] = 230;
                checker[idx + 1] = 230;
                checker[idx + 2] = 230;
                checker[idx + 3] = 255;
            } else {
                checker[idx + 0] = 60;
                checker[idx + 1] = 60;
                checker[idx + 2] = 200;
                checker[idx + 3] = 255;
            }
        }
    }
    const png_bytes = try png.encodeRgba(alloc, &checker, 8, 8);
    defer alloc.free(png_bytes);

    // ── 2. Build BIN chunk payload ────────────────────────────────────────────
    const bin_total: u32 = bv_png_off + @as(u32, @intCast(png_bytes.len));
    // Pad bin to 4-byte alignment
    const bin_padded = (bin_total + 3) & ~@as(u32, 3);

    var bin = try alloc.alloc(u8, bin_padded);
    defer alloc.free(bin);
    @memset(bin, 0);

    // Write positions
    var pos_off: usize = bv_pos_off;
    for (faces) |face| {
        for (face.v) |v| {
            std.mem.writeInt(u32, bin[pos_off..][0..4], @bitCast(v[0]), .little);
            std.mem.writeInt(u32, bin[pos_off + 4 ..][0..4], @bitCast(v[1]), .little);
            std.mem.writeInt(u32, bin[pos_off + 8 ..][0..4], @bitCast(v[2]), .little);
            pos_off += 12;
        }
    }

    // Write normals
    var nrm_off: usize = bv_nrm_off;
    for (faces) |face| {
        for (0..4) |_| {
            std.mem.writeInt(u32, bin[nrm_off..][0..4], @bitCast(face.nx), .little);
            std.mem.writeInt(u32, bin[nrm_off + 4 ..][0..4], @bitCast(face.ny), .little);
            std.mem.writeInt(u32, bin[nrm_off + 8 ..][0..4], @bitCast(face.nz), .little);
            nrm_off += 12;
        }
    }

    // Write UVs
    var uv_off: usize = bv_uv_off;
    for (faces) |_| {
        for (face_uvs) |uv| {
            std.mem.writeInt(u32, bin[uv_off..][0..4], @bitCast(uv[0]), .little);
            std.mem.writeInt(u32, bin[uv_off + 4 ..][0..4], @bitCast(uv[1]), .little);
            uv_off += 8;
        }
    }

    // Write indices: per face base+{0,1,2,0,2,3} (corner tables are CCW from outside)
    var idx_off: usize = bv_idx_off;
    for (0..6) |face_i| {
        const base: u16 = @intCast(face_i * 4);
        const tri_offsets = [6]u16{ 0, 1, 2, 0, 2, 3 };
        for (tri_offsets) |o| {
            std.mem.writeInt(u16, bin[idx_off..][0..2], base + o, .little);
            idx_off += 2;
        }
    }

    // Write PNG
    @memcpy(bin[bv_png_off..][0..png_bytes.len], png_bytes);

    // ── 3. Build JSON chunk ───────────────────────────────────────────────────
    var json_aw: std.Io.Writer.Allocating = .init(alloc);
    defer json_aw.deinit();
    const w = &json_aw.writer;

    const png_len: u32 = @intCast(png_bytes.len);

    // asset + scene + nodes + mesh
    try w.writeAll("{");
    try w.writeAll("\"asset\":{\"version\":\"2.0\"},");
    try w.writeAll("\"scene\":0,");
    try w.writeAll("\"scenes\":[{\"nodes\":[0]}],");
    try w.writeAll("\"nodes\":[{\"mesh\":0,\"name\":\"DemoCube\"}],");
    try w.writeAll("\"meshes\":[{\"primitives\":[{\"attributes\":{");
    try w.print("\"POSITION\":{d},\"NORMAL\":{d},\"TEXCOORD_0\":{d}", .{ acc_pos, acc_nrm, acc_uv });
    try w.print("}},\"indices\":{d},\"material\":0}}]}}],", .{acc_idx});

    // accessors
    try w.writeAll("\"accessors\":[");
    // 0: POSITION
    try w.print("{{\"bufferView\":{d},\"byteOffset\":0,\"componentType\":5126,\"count\":24,\"type\":\"VEC3\",\"min\":[-1.0,-1.0,-1.0],\"max\":[1.0,1.0,1.0]}},", .{bv_pos});
    // 1: NORMAL
    try w.print("{{\"bufferView\":{d},\"byteOffset\":0,\"componentType\":5126,\"count\":24,\"type\":\"VEC3\"}},", .{bv_nrm});
    // 2: TEXCOORD_0
    try w.print("{{\"bufferView\":{d},\"byteOffset\":0,\"componentType\":5126,\"count\":24,\"type\":\"VEC2\"}},", .{bv_uv});
    // 3: indices
    try w.print("{{\"bufferView\":{d},\"byteOffset\":0,\"componentType\":5123,\"count\":36,\"type\":\"SCALAR\"}}", .{bv_idx_bv});
    try w.writeAll("],");

    // bufferViews
    try w.writeAll("\"bufferViews\":[");
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ bv_pos_off, bv_pos_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ bv_nrm_off, bv_nrm_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ bv_uv_off, bv_uv_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d},\"target\":34963}},", .{ bv_idx_off, bv_idx_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}}", .{ bv_png_off, png_len });
    try w.writeAll("],");

    // buffer, materials, textures, images
    try w.print("\"buffers\":[{{\"byteLength\":{d}}}],", .{bin_total});
    try w.writeAll("\"materials\":[{\"pbrMetallicRoughness\":{\"baseColorTexture\":{\"index\":0},\"baseColorFactor\":[1.0,1.0,1.0,1.0]}}],");
    try w.writeAll("\"textures\":[{\"source\":0}],");
    try w.print("\"images\":[{{\"bufferView\":{d},\"mimeType\":\"image/png\"}}]", .{bv_png});
    try w.writeAll("}");

    // Pad JSON to 4-byte alignment with spaces
    while (json_aw.writer.end % 4 != 0) {
        try w.writeByte(0x20);
    }

    const json_bytes = try json_aw.toOwnedSlice();
    defer alloc.free(json_bytes);
    const json_len: u32 = @intCast(json_bytes.len);

    // ── 4. Assemble GLB ───────────────────────────────────────────────────────
    // GLB layout:
    //   [0..12)   header (magic, version, total_len)
    //   [12..20)  chunk0 header (json_len, "JSON")
    //   [20..20+json_len) json payload
    //   [20+json_len..20+json_len+8) chunk1 header (bin_padded, "BIN\0")
    //   [..+bin_padded) bin payload
    const glb_len: u32 = 12 + 8 + json_len + 8 + bin_padded;
    var glb = try alloc.alloc(u8, glb_len);
    var goff: usize = 0;

    // Header
    @memcpy(glb[goff..][0..4], "glTF");
    goff += 4;
    std.mem.writeInt(u32, glb[goff..][0..4], 2, .little);
    goff += 4;
    std.mem.writeInt(u32, glb[goff..][0..4], glb_len, .little);
    goff += 4;

    // Chunk 0: JSON
    std.mem.writeInt(u32, glb[goff..][0..4], json_len, .little);
    goff += 4;
    @memcpy(glb[goff..][0..4], "JSON");
    goff += 4;
    @memcpy(glb[goff..][0..json_len], json_bytes);
    goff += json_len;

    // Chunk 1: BIN\0
    std.mem.writeInt(u32, glb[goff..][0..4], bin_padded, .little);
    goff += 4;
    glb[goff] = 0x42; // B
    glb[goff + 1] = 0x49; // I
    glb[goff + 2] = 0x4E; // N
    glb[goff + 3] = 0x00; // \0
    goff += 4;
    @memcpy(glb[goff..][0..bin_padded], bin);

    return glb;
}

// ── full-PBR cube fixture ───────────────────────────────────────────────────────

// Per-face world-space tangents (xyz) for the cube above, consistent with the
// per-face uv layout (uv (0,0)→(1,0) is the +u direction). w=+1 for all faces.
// Derived: +u = corner1 − corner0, normalized.
//   +X→(0,0,-1)  -X→(0,0,1)  +Y→(1,0,0)  -Y→(1,0,0)  +Z→(1,0,0)  -Z→(-1,0,0)
const face_tangents = [6][3]f32{
    .{ 0, 0, -1 }, // +X
    .{ 0, 0, 1 }, // -X
    .{ 1, 0, 0 }, // +Y
    .{ 1, 0, 0 }, // -Y
    .{ 1, 0, 0 }, // +Z
    .{ -1, 0, 0 }, // -Z
};

/// Full-PBR cube glb: baseColor checkerboard (8x8), metallicRoughness map
/// (8x8: G ramps roughness across x, B ramps metallic across y),
/// normal map (8x8 diagonal-groove pattern around (128,128,255)),
/// emissive map (8x8, bright 2x2 patch) + emissiveFactor (1,1,1),
/// occlusion map (8x8 corner-darkened) with strength 0.8,
/// metallicFactor 1.0, roughnessFactor 1.0, normalTexture.scale 1.0.
/// with_tangents=true emits a TANGENT VEC4 accessor; false omits it
/// (exercises build-side generation).
///
/// Same 24-vertex cube geometry as texturedCubeGlb. Five embedded PNGs
/// (base/MR/normal/emissive/occlusion) each 8x8 RGBA.
pub fn pbrCubeGlb(alloc: Allocator, opts: struct { with_tangents: bool = true }) ![]u8 {
    // ── 1. Build the maps ──────────────────────────────────────────────────────
    // ── Base-color map: detailed 256×256 procedural (real-sized for the
    //    compressed-textures demo). Deterministic — no RNG — so goldens are stable.
    const base_dim: u32 = 256;
    const base_map = try alloc.alloc(u8, base_dim * base_dim * 4);
    defer alloc.free(base_map);
    {
        var y: u32 = 0;
        while (y < base_dim) : (y += 1) {
            var x: u32 = 0;
            while (x < base_dim) : (x += 1) {
                const idx = (y * base_dim + x) * 4;
                const cell = ((x / 32) + (y / 32)) % 2 == 0;
                var r: u32 = if (cell) 210 else 70;
                var g: u32 = if (cell) 200 else 80;
                var b: u32 = if (cell) 180 else 190;
                r = r * (160 + x / 4) / 255;
                g = g * (160 + y / 4) / 255;
                // Per-8×8-block value noise (constant within a block) — adds visual
                // variation while staying PNG-compressible (runs), unlike per-pixel
                // noise which is near-incompressible.
                const h = ((x / 8) *% 374761393 +% (y / 8) *% 668265263) *% 1274126177;
                const n: u32 = (h >> 24) & 0xFF;
                r = (r * 3 + n) / 4;
                g = (g * 3 + n) / 4;
                b = (b * 3 + n) / 4;
                if (x % 32 == 0 or y % 32 == 0) {
                    r /= 2;
                    g /= 2;
                    b /= 2;
                }
                base_map[idx + 0] = @intCast(@min(r, 255));
                base_map[idx + 1] = @intCast(@min(g, 255));
                base_map[idx + 2] = @intCast(@min(b, 255));
                base_map[idx + 3] = 255;
            }
        }
    }

    // ── The four 8x8 PBR side maps ─────────────────────────────────────────────
    var mr_map: [8 * 8 * 4]u8 = undefined; // G=roughness ramp(x), B=metallic ramp(y)
    var nrm_map: [8 * 8 * 4]u8 = undefined; // diagonal groove around (128,128,255)
    var emi_map: [8 * 8 * 4]u8 = undefined; // bright 2x2 patch
    var occ_map: [8 * 8 * 4]u8 = undefined; // corner-darkened
    for (0..8) |row| {
        for (0..8) |col| {
            const idx = (row * 8 + col) * 4;
            // metallicRoughness: G ramps roughness across x, B ramps metallic across y
            mr_map[idx + 0] = 0;
            mr_map[idx + 1] = @intCast(col * 255 / 7); // roughness across x
            mr_map[idx + 2] = @intCast(row * 255 / 7); // metallic across y
            mr_map[idx + 3] = 255;
            // normal: diagonal-groove pattern around (128,128,255)
            const groove: bool = ((row + col) % 4) < 2;
            nrm_map[idx + 0] = if (groove) 160 else 96;
            nrm_map[idx + 1] = if (groove) 96 else 160;
            nrm_map[idx + 2] = 255;
            nrm_map[idx + 3] = 255;
            // emissive: bright 2x2 patch near center, else black
            const bright = (row >= 3 and row <= 4 and col >= 3 and col <= 4);
            emi_map[idx + 0] = if (bright) 255 else 0;
            emi_map[idx + 1] = if (bright) 255 else 0;
            emi_map[idx + 2] = if (bright) 255 else 0;
            emi_map[idx + 3] = 255;
            // occlusion: corner-darkened (darker toward (0,0))
            const oc: u8 = @intCast(128 + (row + col) * 127 / 14);
            occ_map[idx + 0] = oc;
            occ_map[idx + 1] = oc;
            occ_map[idx + 2] = oc;
            occ_map[idx + 3] = 255;
        }
    }

    const base_png = try png.encodeRgba(alloc, base_map, base_dim, base_dim);
    defer alloc.free(base_png);
    const mr_png = try png.encodeRgba(alloc, &mr_map, 8, 8);
    defer alloc.free(mr_png);
    const nrm_png = try png.encodeRgba(alloc, &nrm_map, 8, 8);
    defer alloc.free(nrm_png);
    const emi_png = try png.encodeRgba(alloc, &emi_map, 8, 8);
    defer alloc.free(emi_png);
    const occ_png = try png.encodeRgba(alloc, &occ_map, 8, 8);
    defer alloc.free(occ_png);

    const pngs = [5][]const u8{ base_png, mr_png, nrm_png, emi_png, occ_png };

    // ── 2. Compute BIN layout ─────────────────────────────────────────────────
    // POSITION(288) NORMAL(288) [TANGENT(384)] TEXCOORD_0(192) indices(72) 5×PNG.
    const p_pos_off: u32 = 0;
    const p_pos_len: u32 = 24 * 3 * 4; // 288
    const p_nrm_off: u32 = p_pos_off + p_pos_len; // 288
    const p_nrm_len: u32 = 24 * 3 * 4; // 288
    const has_tan = opts.with_tangents;
    const p_tan_off: u32 = p_nrm_off + p_nrm_len; // 576
    const p_tan_len: u32 = if (has_tan) 24 * 4 * 4 else 0; // 384 or 0
    const p_uv_off: u32 = p_tan_off + p_tan_len;
    const p_uv_len: u32 = 24 * 2 * 4; // 192
    const p_idx_off: u32 = p_uv_off + p_uv_len;
    const p_idx_len: u32 = 36 * 2; // 72
    // PNGs each 4-aligned after indices.
    var png_offs: [5]u32 = undefined;
    var cursor: u32 = (p_idx_off + p_idx_len + 3) & ~@as(u32, 3);
    for (pngs, 0..) |p, i| {
        png_offs[i] = cursor;
        cursor += @intCast(p.len);
        cursor = (cursor + 3) & ~@as(u32, 3);
    }
    const bin_total: u32 = cursor;
    const bin_padded = (bin_total + 3) & ~@as(u32, 3);

    var bin = try alloc.alloc(u8, bin_padded);
    defer alloc.free(bin);
    @memset(bin, 0);

    // positions
    var off: usize = p_pos_off;
    for (faces) |face| {
        for (face.v) |v| {
            std.mem.writeInt(u32, bin[off..][0..4], @bitCast(v[0]), .little);
            std.mem.writeInt(u32, bin[off + 4 ..][0..4], @bitCast(v[1]), .little);
            std.mem.writeInt(u32, bin[off + 8 ..][0..4], @bitCast(v[2]), .little);
            off += 12;
        }
    }
    // normals
    off = p_nrm_off;
    for (faces) |face| {
        for (0..4) |_| {
            std.mem.writeInt(u32, bin[off..][0..4], @bitCast(face.nx), .little);
            std.mem.writeInt(u32, bin[off + 4 ..][0..4], @bitCast(face.ny), .little);
            std.mem.writeInt(u32, bin[off + 8 ..][0..4], @bitCast(face.nz), .little);
            off += 12;
        }
    }
    // tangents (VEC4, w=+1) if requested
    if (has_tan) {
        off = p_tan_off;
        for (face_tangents) |t| {
            for (0..4) |_| {
                std.mem.writeInt(u32, bin[off..][0..4], @bitCast(t[0]), .little);
                std.mem.writeInt(u32, bin[off + 4 ..][0..4], @bitCast(t[1]), .little);
                std.mem.writeInt(u32, bin[off + 8 ..][0..4], @bitCast(t[2]), .little);
                std.mem.writeInt(u32, bin[off + 12 ..][0..4], @bitCast(@as(f32, 1.0)), .little);
                off += 16;
            }
        }
    }
    // uvs
    off = p_uv_off;
    for (faces) |_| {
        for (face_uvs) |uv| {
            std.mem.writeInt(u32, bin[off..][0..4], @bitCast(uv[0]), .little);
            std.mem.writeInt(u32, bin[off + 4 ..][0..4], @bitCast(uv[1]), .little);
            off += 8;
        }
    }
    // indices
    off = p_idx_off;
    for (0..6) |face_i| {
        const base: u16 = @intCast(face_i * 4);
        const tri_offsets = [6]u16{ 0, 1, 2, 0, 2, 3 };
        for (tri_offsets) |o| {
            std.mem.writeInt(u16, bin[off..][0..2], base + o, .little);
            off += 2;
        }
    }
    // PNGs
    for (pngs, 0..) |p, i| {
        @memcpy(bin[png_offs[i]..][0..p.len], p);
    }

    // ── 3. Build JSON ─────────────────────────────────────────────────────────
    var json_aw: std.Io.Writer.Allocating = .init(alloc);
    defer json_aw.deinit();
    const w = &json_aw.writer;

    // accessor / bufferView index layout depends on whether tangents are present.
    // accessors: 0=POSITION 1=NORMAL [2=TANGENT] then UV, indices.
    // bufferViews mirror accessors then 5 PNG bufferViews.
    const acc_p_pos: u32 = 0;
    const acc_p_nrm: u32 = 1;
    const acc_p_tan: u32 = 2;
    const acc_p_uv: u32 = if (has_tan) 3 else 2;
    const acc_p_idx: u32 = if (has_tan) 4 else 3;
    const bv_count_geom: u32 = if (has_tan) 5 else 4;
    const bv_p_pos: u32 = 0;
    const bv_p_nrm: u32 = 1;
    const bv_p_tan: u32 = 2;
    const bv_p_uv: u32 = if (has_tan) 3 else 2;
    const bv_p_idx: u32 = if (has_tan) 4 else 3;

    try w.writeAll("{");
    try w.writeAll("\"asset\":{\"version\":\"2.0\"},");
    try w.writeAll("\"scene\":0,");
    try w.writeAll("\"scenes\":[{\"nodes\":[0]}],");
    try w.writeAll("\"nodes\":[{\"mesh\":0,\"name\":\"PbrCube\"}],");
    try w.writeAll("\"meshes\":[{\"name\":\"Cube\",\"primitives\":[{\"attributes\":{");
    try w.print("\"POSITION\":{d},\"NORMAL\":{d}", .{ acc_p_pos, acc_p_nrm });
    if (has_tan) try w.print(",\"TANGENT\":{d}", .{acc_p_tan});
    try w.print(",\"TEXCOORD_0\":{d}", .{acc_p_uv});
    try w.print("}},\"indices\":{d},\"material\":0}}]}}],", .{acc_p_idx});

    // accessors
    try w.writeAll("\"accessors\":[");
    try w.print("{{\"bufferView\":{d},\"byteOffset\":0,\"componentType\":5126,\"count\":24,\"type\":\"VEC3\",\"min\":[-1.0,-1.0,-1.0],\"max\":[1.0,1.0,1.0]}},", .{bv_p_pos});
    try w.print("{{\"bufferView\":{d},\"byteOffset\":0,\"componentType\":5126,\"count\":24,\"type\":\"VEC3\"}},", .{bv_p_nrm});
    if (has_tan) {
        try w.print("{{\"bufferView\":{d},\"byteOffset\":0,\"componentType\":5126,\"count\":24,\"type\":\"VEC4\"}},", .{bv_p_tan});
    }
    try w.print("{{\"bufferView\":{d},\"byteOffset\":0,\"componentType\":5126,\"count\":24,\"type\":\"VEC2\"}},", .{bv_p_uv});
    try w.print("{{\"bufferView\":{d},\"byteOffset\":0,\"componentType\":5123,\"count\":36,\"type\":\"SCALAR\"}}", .{bv_p_idx});
    try w.writeAll("],");

    // bufferViews (geometry, then 5 PNG)
    try w.writeAll("\"bufferViews\":[");
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ p_pos_off, p_pos_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ p_nrm_off, p_nrm_len });
    if (has_tan) {
        try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ p_tan_off, p_tan_len });
    }
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ p_uv_off, p_uv_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d},\"target\":34963}},", .{ p_idx_off, p_idx_len });
    for (pngs, 0..) |p, i| {
        try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}}", .{ png_offs[i], p.len });
        if (i + 1 < pngs.len) try w.writeAll(",");
    }
    try w.writeAll("],");

    // buffer, material (full PBR), textures, images
    try w.print("\"buffers\":[{{\"byteLength\":{d}}}],", .{bin_total});
    try w.writeAll("\"materials\":[{");
    try w.writeAll("\"pbrMetallicRoughness\":{");
    try w.writeAll("\"baseColorFactor\":[1.0,1.0,1.0,1.0],");
    try w.writeAll("\"baseColorTexture\":{\"index\":0},");
    try w.writeAll("\"metallicFactor\":1.0,\"roughnessFactor\":1.0,");
    try w.writeAll("\"metallicRoughnessTexture\":{\"index\":1}");
    try w.writeAll("},");
    try w.writeAll("\"normalTexture\":{\"index\":2,\"scale\":1.0},");
    try w.writeAll("\"emissiveTexture\":{\"index\":3},");
    try w.writeAll("\"emissiveFactor\":[1.0,1.0,1.0],");
    try w.writeAll("\"occlusionTexture\":{\"index\":4,\"strength\":0.8}");
    try w.writeAll("}],");
    // textures point at image i (source); image i points at bufferView bv_count_geom+i
    try w.writeAll("\"textures\":[");
    for (0..5) |i| {
        try w.print("{{\"source\":{d}}}", .{i});
        if (i + 1 < 5) try w.writeAll(",");
    }
    try w.writeAll("],");
    try w.writeAll("\"images\":[");
    for (0..5) |i| {
        try w.print("{{\"bufferView\":{d},\"mimeType\":\"image/png\"}}", .{bv_count_geom + @as(u32, @intCast(i))});
        if (i + 1 < 5) try w.writeAll(",");
    }
    try w.writeAll("]");
    try w.writeAll("}");

    while (json_aw.writer.end % 4 != 0) {
        try w.writeByte(0x20);
    }

    const json_bytes = try json_aw.toOwnedSlice();
    defer alloc.free(json_bytes);
    const json_len: u32 = @intCast(json_bytes.len);

    // ── 4. Assemble GLB ───────────────────────────────────────────────────────
    const glb_len: u32 = 12 + 8 + json_len + 8 + bin_padded;
    var glb = try alloc.alloc(u8, glb_len);
    var goff: usize = 0;
    @memcpy(glb[goff..][0..4], "glTF");
    goff += 4;
    std.mem.writeInt(u32, glb[goff..][0..4], 2, .little);
    goff += 4;
    std.mem.writeInt(u32, glb[goff..][0..4], glb_len, .little);
    goff += 4;
    std.mem.writeInt(u32, glb[goff..][0..4], json_len, .little);
    goff += 4;
    @memcpy(glb[goff..][0..4], "JSON");
    goff += 4;
    @memcpy(glb[goff..][0..json_len], json_bytes);
    goff += json_len;
    std.mem.writeInt(u32, glb[goff..][0..4], bin_padded, .little);
    goff += 4;
    glb[goff] = 0x42; // B
    glb[goff + 1] = 0x49; // I
    glb[goff + 2] = 0x4E; // N
    glb[goff + 3] = 0x00; // \0
    goff += 4;
    @memcpy(glb[goff..][0..bin_padded], bin);

    return glb;
}

// ── mixed-material cube fixture (P9 shader-variant fan-out) ──────────────────────

/// Two-cube, two-material, two-mesh glb that forces per-submesh shader
/// variant fan-out. TWO meshes, each ONE primitive, each on its own node so the
/// two resulting submeshes get DISTINCT names (name-based addressing can reach
/// both):
///   - mesh 0 "MixedFull" / material 0: FULL PBR (base/mr/normal/emissive+factor/
///     occlusion) → after the writer runs, all five tex_* >= 0 → variant
///     pbr|normal_map|emissive.
///   - mesh 1 "MixedBase" / material 1: BASE-COLOR ONLY (one baseColorTexture, no
///     mr/normal/emissive/occlusion, zero emissive factor) → writer emits
///     tex_normal == -1 and tex_emissive == -1 → variant pbr.
/// Two distinct variants in one asset = GlScene builds two shaders and switches
/// setPipeline between them.
///
/// Geometry: the same 24-vertex cube as pbrCubeGlb, twice; the second cube is
/// offset +x_off (2.5) on X so the two read side-by-side. Both primitives use the SAME
/// attribute set (POSITION + NORMAL + TEXCOORD_0, NO TANGENT) so the downstream
/// vmesh is uniform stride-48; the asset-gen tool generates tangents.
///
/// Six embedded 8x8 RGBA PNGs: material 0's five maps + material 1's lone base map.
pub fn pbrCubeMixedMaterialGlb(alloc: Allocator) ![]u8 {
    // ── 1. Build the six 8x8 RGBA maps ────────────────────────────────────────
    var base_map: [8 * 8 * 4]u8 = undefined; // mat0 base: checkerboard
    var mr_map: [8 * 8 * 4]u8 = undefined; // mat0 metallicRoughness
    var nrm_map: [8 * 8 * 4]u8 = undefined; // mat0 normal
    var emi_map: [8 * 8 * 4]u8 = undefined; // mat0 emissive
    var occ_map: [8 * 8 * 4]u8 = undefined; // mat0 occlusion
    var base2_map: [8 * 8 * 4]u8 = undefined; // mat1 base (only map)
    for (0..8) |row| {
        for (0..8) |col| {
            const idx = (row * 8 + col) * 4;
            const light = (row + col) % 2 == 0;
            if (light) {
                base_map[idx + 0] = 230;
                base_map[idx + 1] = 230;
                base_map[idx + 2] = 230;
            } else {
                base_map[idx + 0] = 60;
                base_map[idx + 1] = 60;
                base_map[idx + 2] = 200;
            }
            base_map[idx + 3] = 255;
            mr_map[idx + 0] = 0;
            mr_map[idx + 1] = @intCast(col * 255 / 7);
            mr_map[idx + 2] = @intCast(row * 255 / 7);
            mr_map[idx + 3] = 255;
            const groove: bool = ((row + col) % 4) < 2;
            nrm_map[idx + 0] = if (groove) 160 else 96;
            nrm_map[idx + 1] = if (groove) 96 else 160;
            nrm_map[idx + 2] = 255;
            nrm_map[idx + 3] = 255;
            const bright = (row >= 3 and row <= 4 and col >= 3 and col <= 4);
            emi_map[idx + 0] = if (bright) 255 else 0;
            emi_map[idx + 1] = if (bright) 255 else 0;
            emi_map[idx + 2] = if (bright) 255 else 0;
            emi_map[idx + 3] = 255;
            const oc: u8 = @intCast(128 + (row + col) * 127 / 14);
            occ_map[idx + 0] = oc;
            occ_map[idx + 1] = oc;
            occ_map[idx + 2] = oc;
            occ_map[idx + 3] = 255;
            // mat1 base: solid warm tint (distinct from mat0's checkerboard).
            base2_map[idx + 0] = 200;
            base2_map[idx + 1] = 140;
            base2_map[idx + 2] = 90;
            base2_map[idx + 3] = 255;
        }
    }

    const base_png = try png.encodeRgba(alloc, &base_map, 8, 8);
    defer alloc.free(base_png);
    const mr_png = try png.encodeRgba(alloc, &mr_map, 8, 8);
    defer alloc.free(mr_png);
    const nrm_png = try png.encodeRgba(alloc, &nrm_map, 8, 8);
    defer alloc.free(nrm_png);
    const emi_png = try png.encodeRgba(alloc, &emi_map, 8, 8);
    defer alloc.free(emi_png);
    const occ_png = try png.encodeRgba(alloc, &occ_map, 8, 8);
    defer alloc.free(occ_png);
    const base2_png = try png.encodeRgba(alloc, &base2_map, 8, 8);
    defer alloc.free(base2_png);

    // image order: 0..4 = mat0 (base/mr/nrm/emi/occ), 5 = mat1 base.
    const pngs = [6][]const u8{ base_png, mr_png, nrm_png, emi_png, occ_png, base2_png };

    // ── 2. Compute BIN layout ─────────────────────────────────────────────────
    // +X offset for the second cube. The cube spans [-1,+1] so primitive 1's
    // POSITION min/max X derive from this const (x_off-1 .. x_off+1) — single
    // source of truth so geometry and accessor bounds can't drift.
    const x_off: f32 = 2.5;
    // Two geometry sets (no TANGENT): each pos(288) nrm(288) uv(192) idx(72).
    const geom_len: u32 = 24 * 3 * 4; // 288
    const uv_len: u32 = 24 * 2 * 4; // 192
    const idx_len: u32 = 36 * 2; // 72

    // primitive 0 geometry
    const m0_pos_off: u32 = 0;
    const m0_nrm_off: u32 = m0_pos_off + geom_len; // 288
    const m0_uv_off: u32 = m0_nrm_off + geom_len; // 576
    const m0_idx_off: u32 = m0_uv_off + uv_len; // 768
    // primitive 1 geometry (4-aligned after primitive 0's indices)
    const m1_pos_off: u32 = (m0_idx_off + idx_len + 3) & ~@as(u32, 3); // 840
    const m1_nrm_off: u32 = m1_pos_off + geom_len;
    const m1_uv_off: u32 = m1_nrm_off + geom_len;
    const m1_idx_off: u32 = m1_uv_off + uv_len;

    // PNGs each 4-aligned after primitive 1's indices.
    var png_offs: [6]u32 = undefined;
    var cursor: u32 = (m1_idx_off + idx_len + 3) & ~@as(u32, 3);
    for (pngs, 0..) |p, i| {
        png_offs[i] = cursor;
        cursor += @intCast(p.len);
        cursor = (cursor + 3) & ~@as(u32, 3);
    }
    const bin_total: u32 = cursor;
    // cursor is 4-aligned after every PNG, so bin_padded == bin_total (no-op).
    const bin_padded = (bin_total + 3) & ~@as(u32, 3);

    var bin = try alloc.alloc(u8, bin_padded);
    defer alloc.free(bin);
    @memset(bin, 0);

    // Helper writers for one cube's geometry into bin at the given offsets.
    // x_offset shifts every position on X (second cube is +2.5).
    const writeCube = struct {
        fn go(b: []u8, pos_off: u32, nrm_off: u32, uvw_off: u32, idxw_off: u32, x_shift: f32) void {
            var po: usize = pos_off;
            for (faces) |face| {
                for (face.v) |v| {
                    std.mem.writeInt(u32, b[po..][0..4], @bitCast(v[0] + x_shift), .little);
                    std.mem.writeInt(u32, b[po + 4 ..][0..4], @bitCast(v[1]), .little);
                    std.mem.writeInt(u32, b[po + 8 ..][0..4], @bitCast(v[2]), .little);
                    po += 12;
                }
            }
            var no: usize = nrm_off;
            for (faces) |face| {
                for (0..4) |_| {
                    std.mem.writeInt(u32, b[no..][0..4], @bitCast(face.nx), .little);
                    std.mem.writeInt(u32, b[no + 4 ..][0..4], @bitCast(face.ny), .little);
                    std.mem.writeInt(u32, b[no + 8 ..][0..4], @bitCast(face.nz), .little);
                    no += 12;
                }
            }
            var uo: usize = uvw_off;
            for (faces) |_| {
                for (face_uvs) |uv| {
                    std.mem.writeInt(u32, b[uo..][0..4], @bitCast(uv[0]), .little);
                    std.mem.writeInt(u32, b[uo + 4 ..][0..4], @bitCast(uv[1]), .little);
                    uo += 8;
                }
            }
            var io: usize = idxw_off;
            for (0..6) |face_i| {
                const base: u16 = @intCast(face_i * 4);
                const tri_offsets = [6]u16{ 0, 1, 2, 0, 2, 3 };
                for (tri_offsets) |o| {
                    std.mem.writeInt(u16, b[io..][0..2], base + o, .little);
                    io += 2;
                }
            }
        }
    }.go;

    writeCube(bin, m0_pos_off, m0_nrm_off, m0_uv_off, m0_idx_off, 0.0);
    writeCube(bin, m1_pos_off, m1_nrm_off, m1_uv_off, m1_idx_off, x_off);

    for (pngs, 0..) |p, i| {
        @memcpy(bin[png_offs[i]..][0..p.len], p);
    }

    // ── 3. Build JSON ─────────────────────────────────────────────────────────
    var json_aw: std.Io.Writer.Allocating = .init(alloc);
    defer json_aw.deinit();
    const w = &json_aw.writer;

    // accessor layout: per primitive 0..3 (pos/nrm/uv/idx), per primitive 4..7.
    // bufferView layout mirrors accessors (8 geom bufferViews), then 6 PNG bvs.
    const acc_m0_pos: u32 = 0;
    const acc_m0_nrm: u32 = 1;
    const acc_m0_uv: u32 = 2;
    const acc_m0_idx: u32 = 3;
    const acc_m1_pos: u32 = 4;
    const acc_m1_nrm: u32 = 5;
    const acc_m1_uv: u32 = 6;
    const acc_m1_idx: u32 = 7;
    const bv_geom_count: u32 = 8;

    try w.writeAll("{");
    try w.writeAll("\"asset\":{\"version\":\"2.0\"},");
    try w.writeAll("\"scene\":0,");
    // Two nodes (one per mesh) both in the scene → two distinctly named submeshes.
    try w.writeAll("\"scenes\":[{\"nodes\":[0,1]}],");
    try w.writeAll("\"nodes\":[{\"mesh\":0,\"name\":\"MixedFullNode\"},{\"mesh\":1,\"name\":\"MixedBaseNode\"}],");
    // Two meshes, each one primitive. Distinct mesh names → distinct submesh names.
    try w.writeAll("\"meshes\":[");
    // mesh 0 "MixedFull" → primitive / material 0 (full PBR)
    try w.print("{{\"name\":\"MixedFull\",\"primitives\":[{{\"attributes\":{{\"POSITION\":{d},\"NORMAL\":{d},\"TEXCOORD_0\":{d}}},\"indices\":{d},\"material\":0}}]}},", .{ acc_m0_pos, acc_m0_nrm, acc_m0_uv, acc_m0_idx });
    // mesh 1 "MixedBase" → primitive / material 1 (base-only)
    try w.print("{{\"name\":\"MixedBase\",\"primitives\":[{{\"attributes\":{{\"POSITION\":{d},\"NORMAL\":{d},\"TEXCOORD_0\":{d}}},\"indices\":{d},\"material\":1}}]}}", .{ acc_m1_pos, acc_m1_nrm, acc_m1_uv, acc_m1_idx });
    try w.writeAll("],");

    // accessors (primitive 0 geom, then primitive 1 geom)
    try w.writeAll("\"accessors\":[");
    try w.print("{{\"bufferView\":0,\"byteOffset\":0,\"componentType\":5126,\"count\":24,\"type\":\"VEC3\",\"min\":[-1.0,-1.0,-1.0],\"max\":[1.0,1.0,1.0]}},", .{});
    try w.writeAll("{\"bufferView\":1,\"byteOffset\":0,\"componentType\":5126,\"count\":24,\"type\":\"VEC3\"},");
    try w.writeAll("{\"bufferView\":2,\"byteOffset\":0,\"componentType\":5126,\"count\":24,\"type\":\"VEC2\"},");
    try w.writeAll("{\"bufferView\":3,\"byteOffset\":0,\"componentType\":5123,\"count\":36,\"type\":\"SCALAR\"},");
    try w.print("{{\"bufferView\":4,\"byteOffset\":0,\"componentType\":5126,\"count\":24,\"type\":\"VEC3\",\"min\":[{d:.1},-1.0,-1.0],\"max\":[{d:.1},1.0,1.0]}},", .{ x_off - 1.0, x_off + 1.0 });
    try w.writeAll("{\"bufferView\":5,\"byteOffset\":0,\"componentType\":5126,\"count\":24,\"type\":\"VEC3\"},");
    try w.writeAll("{\"bufferView\":6,\"byteOffset\":0,\"componentType\":5126,\"count\":24,\"type\":\"VEC2\"},");
    try w.writeAll("{\"bufferView\":7,\"byteOffset\":0,\"componentType\":5123,\"count\":36,\"type\":\"SCALAR\"}");
    try w.writeAll("],");

    // bufferViews (8 geometry, then 6 PNG)
    try w.writeAll("\"bufferViews\":[");
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ m0_pos_off, geom_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ m0_nrm_off, geom_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ m0_uv_off, uv_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d},\"target\":34963}},", .{ m0_idx_off, idx_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ m1_pos_off, geom_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ m1_nrm_off, geom_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ m1_uv_off, uv_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d},\"target\":34963}},", .{ m1_idx_off, idx_len });
    for (pngs, 0..) |p, i| {
        try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}}", .{ png_offs[i], p.len });
        if (i + 1 < pngs.len) try w.writeAll(",");
    }
    try w.writeAll("],");

    // buffer
    try w.print("\"buffers\":[{{\"byteLength\":{d}}}],", .{bin_total});

    // materials: 0 = full PBR (textures 0..4), 1 = base-only (texture 5)
    try w.writeAll("\"materials\":[");
    try w.writeAll("{");
    try w.writeAll("\"pbrMetallicRoughness\":{");
    try w.writeAll("\"baseColorFactor\":[1.0,1.0,1.0,1.0],");
    try w.writeAll("\"baseColorTexture\":{\"index\":0},");
    try w.writeAll("\"metallicFactor\":1.0,\"roughnessFactor\":1.0,");
    try w.writeAll("\"metallicRoughnessTexture\":{\"index\":1}");
    try w.writeAll("},");
    try w.writeAll("\"normalTexture\":{\"index\":2,\"scale\":1.0},");
    try w.writeAll("\"emissiveTexture\":{\"index\":3},");
    try w.writeAll("\"emissiveFactor\":[1.0,1.0,1.0],");
    try w.writeAll("\"occlusionTexture\":{\"index\":4,\"strength\":0.8}");
    try w.writeAll("},");
    // material 1: base-color only. No mr/normal/emissive/occlusion, no emissive factor.
    try w.writeAll("{\"pbrMetallicRoughness\":{\"baseColorFactor\":[1.0,1.0,1.0,1.0],\"baseColorTexture\":{\"index\":5}}}");
    try w.writeAll("],");

    // textures: one per image (6).
    try w.writeAll("\"textures\":[");
    for (0..6) |i| {
        try w.print("{{\"source\":{d}}}", .{i});
        if (i + 1 < 6) try w.writeAll(",");
    }
    try w.writeAll("],");
    // images point at the PNG bufferViews (geom count + i).
    try w.writeAll("\"images\":[");
    for (0..6) |i| {
        try w.print("{{\"bufferView\":{d},\"mimeType\":\"image/png\"}}", .{bv_geom_count + @as(u32, @intCast(i))});
        if (i + 1 < 6) try w.writeAll(",");
    }
    try w.writeAll("]");
    try w.writeAll("}");

    while (json_aw.writer.end % 4 != 0) {
        try w.writeByte(0x20);
    }

    const json_bytes = try json_aw.toOwnedSlice();
    defer alloc.free(json_bytes);
    const json_len: u32 = @intCast(json_bytes.len);

    // ── 4. Assemble GLB ───────────────────────────────────────────────────────
    const glb_len: u32 = 12 + 8 + json_len + 8 + bin_padded;
    var glb = try alloc.alloc(u8, glb_len);
    var goff: usize = 0;
    @memcpy(glb[goff..][0..4], "glTF");
    goff += 4;
    std.mem.writeInt(u32, glb[goff..][0..4], 2, .little);
    goff += 4;
    std.mem.writeInt(u32, glb[goff..][0..4], glb_len, .little);
    goff += 4;
    std.mem.writeInt(u32, glb[goff..][0..4], json_len, .little);
    goff += 4;
    @memcpy(glb[goff..][0..4], "JSON");
    goff += 4;
    @memcpy(glb[goff..][0..json_len], json_bytes);
    goff += json_len;
    std.mem.writeInt(u32, glb[goff..][0..4], bin_padded, .little);
    goff += 4;
    glb[goff] = 0x42; // B
    glb[goff + 1] = 0x49; // I
    glb[goff + 2] = 0x4E; // N
    glb[goff + 3] = 0x00; // \0
    goff += 4;
    @memcpy(glb[goff..][0..bin_padded], bin);

    return glb;
}

/// Shadow demo glb: a checkerboard cube sitting above a large neutral floor
/// quad, two base-color-only meshes ("Cube", "Floor") so both resolve to the
/// single `variant_pbr` shader. The floor is a receiver for the cube's
/// directional shadow (P9 slice 3, /gl-shadow demo route). Same attribute set
/// as the other fixtures (POSITION + NORMAL + TEXCOORD_0, no TANGENT) → uniform
/// stride-48 vmesh; the asset-gen pass generates tangents.
pub fn pbrCubeFloorGlb(alloc: Allocator) ![]u8 {
    // ── 1. Two 8×8 RGBA maps: cube checker + neutral floor ────────────────────
    var cube_map: [8 * 8 * 4]u8 = undefined;
    var floor_map: [8 * 8 * 4]u8 = undefined;
    for (0..8) |row| {
        for (0..8) |col| {
            const idx = (row * 8 + col) * 4;
            const light = (row + col) % 2 == 0;
            cube_map[idx + 0] = if (light) 230 else 60;
            cube_map[idx + 1] = if (light) 230 else 60;
            cube_map[idx + 2] = if (light) 230 else 200;
            cube_map[idx + 3] = 255;
            // Floor: near-uniform light gray with a faint checker so the shadow
            // reads clearly against it.
            const f: u8 = if (light) 205 else 185;
            floor_map[idx + 0] = f;
            floor_map[idx + 1] = f;
            floor_map[idx + 2] = @intCast(@as(u16, f) + 8);
            floor_map[idx + 3] = 255;
        }
    }
    const cube_png = try png.encodeRgba(alloc, &cube_map, 8, 8);
    defer alloc.free(cube_png);
    const floor_png = try png.encodeRgba(alloc, &floor_map, 8, 8);
    defer alloc.free(floor_png);
    const pngs = [2][]const u8{ cube_png, floor_png };

    // ── 2. BIN layout: cube geom, floor geom, then the two PNGs ───────────────
    const geom_len: u32 = 24 * 3 * 4; // 288 (cube pos / nrm)
    const uv_len: u32 = 24 * 2 * 4; // 192 (cube uv)
    const idx_len: u32 = 36 * 2; // 72  (cube idx)
    const f_geom_len: u32 = 4 * 3 * 4; // 48 (floor pos / nrm)
    const f_uv_len: u32 = 4 * 2 * 4; // 32 (floor uv)
    const f_idx_len: u32 = 6 * 2; // 12 (floor idx)

    const c_pos_off: u32 = 0;
    const c_nrm_off: u32 = c_pos_off + geom_len;
    const c_uv_off: u32 = c_nrm_off + geom_len;
    const c_idx_off: u32 = c_uv_off + uv_len;
    const f_pos_off: u32 = (c_idx_off + idx_len + 3) & ~@as(u32, 3);
    const f_nrm_off: u32 = f_pos_off + f_geom_len;
    const f_uv_off: u32 = f_nrm_off + f_geom_len;
    const f_idx_off: u32 = f_uv_off + f_uv_len;

    var png_offs: [2]u32 = undefined;
    var cursor: u32 = (f_idx_off + f_idx_len + 3) & ~@as(u32, 3);
    for (pngs, 0..) |p, i| {
        png_offs[i] = cursor;
        cursor += @intCast(p.len);
        cursor = (cursor + 3) & ~@as(u32, 3);
    }
    const bin_total: u32 = cursor;
    const bin_padded = (bin_total + 3) & ~@as(u32, 3);

    var bin = try alloc.alloc(u8, bin_padded);
    defer alloc.free(bin);
    @memset(bin, 0);

    // Cube geometry (reuse the shared face tables; no x-shift).
    {
        var po: usize = c_pos_off;
        for (faces) |face| {
            for (face.v) |v| {
                std.mem.writeInt(u32, bin[po..][0..4], @bitCast(v[0]), .little);
                std.mem.writeInt(u32, bin[po + 4 ..][0..4], @bitCast(v[1]), .little);
                std.mem.writeInt(u32, bin[po + 8 ..][0..4], @bitCast(v[2]), .little);
                po += 12;
            }
        }
        var no: usize = c_nrm_off;
        for (faces) |face| {
            for (0..4) |_| {
                std.mem.writeInt(u32, bin[no..][0..4], @bitCast(face.nx), .little);
                std.mem.writeInt(u32, bin[no + 4 ..][0..4], @bitCast(face.ny), .little);
                std.mem.writeInt(u32, bin[no + 8 ..][0..4], @bitCast(face.nz), .little);
                no += 12;
            }
        }
        var uo: usize = c_uv_off;
        for (faces) |_| {
            for (face_uvs) |uv| {
                std.mem.writeInt(u32, bin[uo..][0..4], @bitCast(uv[0]), .little);
                std.mem.writeInt(u32, bin[uo + 4 ..][0..4], @bitCast(uv[1]), .little);
                uo += 8;
            }
        }
        var io: usize = c_idx_off;
        for (0..6) |face_i| {
            const base: u16 = @intCast(face_i * 4);
            for ([6]u16{ 0, 1, 2, 0, 2, 3 }) |o| {
                std.mem.writeInt(u16, bin[io..][0..2], base + o, .little);
                io += 2;
            }
        }
    }

    // Floor quad: y = -1.5, spans [-6,6] on X/Z, normal +Y. Winding chosen so
    // the up-facing side is the front face (survives back-face culling).
    {
        const fy: f32 = -1.5;
        const s: f32 = 6.0;
        const fpos = [4][3]f32{
            .{ -s, fy, -s }, .{ s, fy, -s }, .{ s, fy, s }, .{ -s, fy, s },
        };
        var po: usize = f_pos_off;
        for (fpos) |v| {
            std.mem.writeInt(u32, bin[po..][0..4], @bitCast(v[0]), .little);
            std.mem.writeInt(u32, bin[po + 4 ..][0..4], @bitCast(v[1]), .little);
            std.mem.writeInt(u32, bin[po + 8 ..][0..4], @bitCast(v[2]), .little);
            po += 12;
        }
        var no: usize = f_nrm_off;
        for (0..4) |_| {
            std.mem.writeInt(u32, bin[no..][0..4], @bitCast(@as(f32, 0)), .little);
            std.mem.writeInt(u32, bin[no + 4 ..][0..4], @bitCast(@as(f32, 1)), .little);
            std.mem.writeInt(u32, bin[no + 8 ..][0..4], @bitCast(@as(f32, 0)), .little);
            no += 12;
        }
        const fuv = [4][2]f32{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 4 }, .{ 0, 4 } };
        var uo: usize = f_uv_off;
        for (fuv) |uv| {
            std.mem.writeInt(u32, bin[uo..][0..4], @bitCast(uv[0]), .little);
            std.mem.writeInt(u32, bin[uo + 4 ..][0..4], @bitCast(uv[1]), .little);
            uo += 8;
        }
        var io: usize = f_idx_off;
        for ([6]u16{ 0, 2, 1, 0, 3, 2 }) |o| {
            std.mem.writeInt(u16, bin[io..][0..2], o, .little);
            io += 2;
        }
    }

    for (pngs, 0..) |p, i| @memcpy(bin[png_offs[i]..][0..p.len], p);

    // ── 3. JSON ───────────────────────────────────────────────────────────────
    var json_aw: std.Io.Writer.Allocating = .init(alloc);
    defer json_aw.deinit();
    const w = &json_aw.writer;

    try w.writeAll("{\"asset\":{\"version\":\"2.0\"},\"scene\":0,");
    try w.writeAll("\"scenes\":[{\"nodes\":[0,1]}],");
    try w.writeAll("\"nodes\":[{\"mesh\":0,\"name\":\"CubeNode\"},{\"mesh\":1,\"name\":\"FloorNode\"}],");
    try w.writeAll("\"meshes\":[");
    try w.writeAll("{\"name\":\"Cube\",\"primitives\":[{\"attributes\":{\"POSITION\":0,\"NORMAL\":1,\"TEXCOORD_0\":2},\"indices\":3,\"material\":0}]},");
    try w.writeAll("{\"name\":\"Floor\",\"primitives\":[{\"attributes\":{\"POSITION\":4,\"NORMAL\":5,\"TEXCOORD_0\":6},\"indices\":7,\"material\":1}]}");
    try w.writeAll("],");

    try w.writeAll("\"accessors\":[");
    try w.writeAll("{\"bufferView\":0,\"byteOffset\":0,\"componentType\":5126,\"count\":24,\"type\":\"VEC3\",\"min\":[-1.0,-1.0,-1.0],\"max\":[1.0,1.0,1.0]},");
    try w.writeAll("{\"bufferView\":1,\"byteOffset\":0,\"componentType\":5126,\"count\":24,\"type\":\"VEC3\"},");
    try w.writeAll("{\"bufferView\":2,\"byteOffset\":0,\"componentType\":5126,\"count\":24,\"type\":\"VEC2\"},");
    try w.writeAll("{\"bufferView\":3,\"byteOffset\":0,\"componentType\":5123,\"count\":36,\"type\":\"SCALAR\"},");
    try w.writeAll("{\"bufferView\":4,\"byteOffset\":0,\"componentType\":5126,\"count\":4,\"type\":\"VEC3\",\"min\":[-6.0,-1.5,-6.0],\"max\":[6.0,-1.5,6.0]},");
    try w.writeAll("{\"bufferView\":5,\"byteOffset\":0,\"componentType\":5126,\"count\":4,\"type\":\"VEC3\"},");
    try w.writeAll("{\"bufferView\":6,\"byteOffset\":0,\"componentType\":5126,\"count\":4,\"type\":\"VEC2\"},");
    try w.writeAll("{\"bufferView\":7,\"byteOffset\":0,\"componentType\":5123,\"count\":6,\"type\":\"SCALAR\"}");
    try w.writeAll("],");

    try w.writeAll("\"bufferViews\":[");
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ c_pos_off, geom_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ c_nrm_off, geom_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ c_uv_off, uv_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d},\"target\":34963}},", .{ c_idx_off, idx_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ f_pos_off, f_geom_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ f_nrm_off, f_geom_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ f_uv_off, f_uv_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d},\"target\":34963}},", .{ f_idx_off, f_idx_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ png_offs[0], cube_png.len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}}", .{ png_offs[1], floor_png.len });
    try w.writeAll("],");

    try w.print("\"buffers\":[{{\"byteLength\":{d}}}],", .{bin_total});

    // Two base-color-only materials → both variant_pbr (no normal/emissive maps).
    try w.writeAll("\"materials\":[");
    try w.writeAll("{\"pbrMetallicRoughness\":{\"baseColorFactor\":[1.0,1.0,1.0,1.0],\"baseColorTexture\":{\"index\":0},\"metallicFactor\":0.0,\"roughnessFactor\":0.85}},");
    try w.writeAll("{\"pbrMetallicRoughness\":{\"baseColorFactor\":[1.0,1.0,1.0,1.0],\"baseColorTexture\":{\"index\":1},\"metallicFactor\":0.0,\"roughnessFactor\":1.0}}");
    try w.writeAll("],");

    try w.writeAll("\"textures\":[{\"source\":0},{\"source\":1}],");
    try w.writeAll("\"images\":[{\"bufferView\":8,\"mimeType\":\"image/png\"},{\"bufferView\":9,\"mimeType\":\"image/png\"}]");
    try w.writeAll("}");

    while (json_aw.writer.end % 4 != 0) try w.writeByte(0x20);

    const json_bytes = try json_aw.toOwnedSlice();
    defer alloc.free(json_bytes);
    const json_len: u32 = @intCast(json_bytes.len);

    // ── 4. Assemble GLB ───────────────────────────────────────────────────────
    const glb_len: u32 = 12 + 8 + json_len + 8 + bin_padded;
    var glb = try alloc.alloc(u8, glb_len);
    var goff: usize = 0;
    @memcpy(glb[goff..][0..4], "glTF");
    goff += 4;
    std.mem.writeInt(u32, glb[goff..][0..4], 2, .little);
    goff += 4;
    std.mem.writeInt(u32, glb[goff..][0..4], glb_len, .little);
    goff += 4;
    std.mem.writeInt(u32, glb[goff..][0..4], json_len, .little);
    goff += 4;
    @memcpy(glb[goff..][0..4], "JSON");
    goff += 4;
    @memcpy(glb[goff..][0..json_len], json_bytes);
    goff += json_len;
    std.mem.writeInt(u32, glb[goff..][0..4], bin_padded, .little);
    goff += 4;
    glb[goff] = 0x42; // B
    glb[goff + 1] = 0x49; // I
    glb[goff + 2] = 0x4E; // N
    glb[goff + 3] = 0x00; // \0
    goff += 4;
    @memcpy(glb[goff..][0..bin_padded], bin);

    return glb;
}

// ── studio HDR environment fixture ──────────────────────────────────────────────

// ── skinned-bar fixture (skinning slice 1) ──────────────────────────────────────

/// A procedural rigged bar along +Y for the skinning demo. A square-section
/// open tube (4 side walls, 5 rings) skinned to a 3-joint vertical chain
/// (root @y=0 → mid @y=1.5 → top @y=3). Vertices are weighted ring-by-ring so a
/// rotation of the mid joint visibly bends the upper half.
///
/// Geometry: 4 sides × 5 rings × 2 corners = 40 vertices, 96 indices.
/// Skin: skins[0].joints = [root,mid,node], inverseBindMatrices = inverse of
/// each joint's bind WORLD (translate(0,−jointY,0)); node TRS gives bind_local.
/// JOINTS_0 (u8 VEC4, indices into the joint list) + WEIGHTS_0 (f32 VEC4).
/// One small (8×8) base-color PNG so the texture stays in-blob (no sidecar).
pub fn skinnedBarGlb(alloc: Allocator) ![]u8 {
    const half: f32 = 0.3;
    const nr: usize = 5; // rings
    const ring_y = [nr]f32{ 0.0, 0.75, 1.5, 2.25, 3.0 };
    // joint indices in the skin's joint list: root=0, mid=1, top=2.
    // Per-ring (joint0,w0,joint1,w1) — the other two weights are 0.
    const RingSkin = struct { j0: u8, w0: f32, j1: u8, w1: f32 };
    const ring_skin = [nr]RingSkin{
        .{ .j0 = 0, .w0 = 1.0, .j1 = 0, .w1 = 0.0 }, // y=0    → root
        .{ .j0 = 0, .w0 = 0.5, .j1 = 1, .w1 = 0.5 }, // y=0.75 → root/mid
        .{ .j0 = 1, .w0 = 1.0, .j1 = 1, .w1 = 0.0 }, // y=1.5  → mid
        .{ .j0 = 1, .w0 = 0.5, .j1 = 2, .w1 = 0.5 }, // y=2.25 → mid/top
        .{ .j0 = 2, .w0 = 1.0, .j1 = 2, .w1 = 0.0 }, // y=3.0  → top
    };
    // Per side: left corner (Lx,Lz), right corner (Rx,Rz), outward normal (nx,nz)
    // — ordered so {L,R}×{ring,ring+1} winds CCW viewed from outside (+normal).
    const Side = struct { lx: f32, lz: f32, rx: f32, rz: f32, nx: f32, nz: f32 };
    const sides = [4]Side{
        .{ .lx = half, .lz = half, .rx = -half, .rz = half, .nx = 0, .nz = 1 }, // +Z
        .{ .lx = -half, .lz = half, .rx = -half, .rz = -half, .nx = -1, .nz = 0 }, // -X
        .{ .lx = -half, .lz = -half, .rx = half, .rz = -half, .nx = 0, .nz = -1 }, // -Z
        .{ .lx = half, .lz = -half, .rx = half, .rz = half, .nx = 1, .nz = 0 }, // +X
    };

    const vert_count: u32 = 4 * @as(u32, nr) * 2; // 40
    const index_count: u32 = 4 * (@as(u32, nr) - 1) * 6; // 96
    const joint_count: u32 = 3;

    // ── base-color PNG (8×8 amber checker, stays in-blob) ──────────────────────
    var checker: [8 * 8 * 4]u8 = undefined;
    for (0..8) |row| {
        for (0..8) |col| {
            const idx = (row * 8 + col) * 4;
            const light = (row + col) % 2 == 0;
            checker[idx + 0] = if (light) 235 else 150;
            checker[idx + 1] = if (light) 170 else 90;
            checker[idx + 2] = if (light) 70 else 30;
            checker[idx + 3] = 255;
        }
    }
    const png_bytes = try png.encodeRgba(alloc, &checker, 8, 8);
    defer alloc.free(png_bytes);

    // ── BIN layout ─────────────────────────────────────────────────────────────
    const off_pos: u32 = 0;
    const len_pos: u32 = vert_count * 12;
    const off_nrm: u32 = off_pos + len_pos;
    const len_nrm: u32 = vert_count * 12;
    const off_uv: u32 = off_nrm + len_nrm;
    const len_uv: u32 = vert_count * 8;
    const off_jnt: u32 = off_uv + len_uv;
    const len_jnt: u32 = vert_count * 4; // u8 VEC4
    const off_wgt: u32 = off_jnt + len_jnt;
    const len_wgt: u32 = vert_count * 16; // f32 VEC4
    const off_idx: u32 = off_wgt + len_wgt;
    const len_idx: u32 = index_count * 2;
    const off_ibm: u32 = off_idx + len_idx;
    const len_ibm: u32 = joint_count * 64; // MAT4 f32
    const off_atime: u32 = off_ibm + len_ibm;
    const len_atime: u32 = 3 * 4; // 3 SCALAR f32 times
    const off_arot: u32 = off_atime + len_atime;
    const len_arot: u32 = 3 * 4 * 4; // 3 VEC4 f32 quats
    const off_png: u32 = off_arot + len_arot;
    const png_len: u32 = @intCast(png_bytes.len);

    const bin_total: u32 = off_png + png_len;
    const bin_padded = (bin_total + 3) & ~@as(u32, 3);
    var bin = try alloc.alloc(u8, bin_padded);
    defer alloc.free(bin);
    @memset(bin, 0);

    // positions / normals / uvs / joints / weights — one pass over (side, ring, col)
    var pc: usize = off_pos;
    var nc: usize = off_nrm;
    var uc: usize = off_uv;
    var jc: usize = off_jnt;
    var wc: usize = off_wgt;
    for (sides) |s| {
        for (0..nr) |r| {
            const y = ring_y[r];
            const rs = ring_skin[r];
            // col 0 = L, col 1 = R
            const cols = [2][2]f32{ .{ s.lx, s.lz }, .{ s.rx, s.rz } };
            for (cols, 0..) |c, col| {
                // position
                std.mem.writeInt(u32, bin[pc..][0..4], @bitCast(c[0]), .little);
                std.mem.writeInt(u32, bin[pc + 4 ..][0..4], @bitCast(y), .little);
                std.mem.writeInt(u32, bin[pc + 8 ..][0..4], @bitCast(c[1]), .little);
                pc += 12;
                // normal
                std.mem.writeInt(u32, bin[nc..][0..4], @bitCast(s.nx), .little);
                std.mem.writeInt(u32, bin[nc + 4 ..][0..4], @bitCast(@as(f32, 0)), .little);
                std.mem.writeInt(u32, bin[nc + 8 ..][0..4], @bitCast(s.nz), .little);
                nc += 12;
                // uv (u = col, v = ring fraction)
                std.mem.writeInt(u32, bin[uc..][0..4], @bitCast(@as(f32, @floatFromInt(col))), .little);
                std.mem.writeInt(u32, bin[uc + 4 ..][0..4], @bitCast(y / 3.0), .little);
                uc += 8;
                // joints (u8 VEC4): j0,j1,0,0
                bin[jc + 0] = rs.j0;
                bin[jc + 1] = rs.j1;
                bin[jc + 2] = 0;
                bin[jc + 3] = 0;
                jc += 4;
                // weights (f32 VEC4): w0,w1,0,0
                std.mem.writeInt(u32, bin[wc..][0..4], @bitCast(rs.w0), .little);
                std.mem.writeInt(u32, bin[wc + 4 ..][0..4], @bitCast(rs.w1), .little);
                std.mem.writeInt(u32, bin[wc + 8 ..][0..4], @bitCast(@as(f32, 0)), .little);
                std.mem.writeInt(u32, bin[wc + 12 ..][0..4], @bitCast(@as(f32, 0)), .little);
                wc += 16;
            }
        }
    }

    // indices: per side, per quad (ring r → r+1): (BL,BR,TR),(BL,TR,TL)
    var ic: usize = off_idx;
    for (0..4) |side| {
        const base: u16 = @intCast(side * nr * 2);
        for (0..nr - 1) |r| {
            const bl: u16 = base + @as(u16, @intCast(r * 2 + 0));
            const br: u16 = base + @as(u16, @intCast(r * 2 + 1));
            const tr: u16 = base + @as(u16, @intCast((r + 1) * 2 + 1));
            const tl: u16 = base + @as(u16, @intCast((r + 1) * 2 + 0));
            for ([6]u16{ bl, br, tr, bl, tr, tl }) |v| {
                std.mem.writeInt(u16, bin[ic..][0..2], v, .little);
                ic += 2;
            }
        }
    }

    // inverseBindMatrices (column-major translate(0,−jointY,0)): root y=0, mid
    // y=1.5, top y=3.0 → inverse translation (0,−jointY,0) in elements [13].
    const inv_y = [joint_count]f32{ 0.0, -1.5, -3.0 };
    for (inv_y, 0..) |ty, j| {
        const mo = off_ibm + @as(u32, @intCast(j)) * 64;
        // identity
        const ident = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
        var m = ident;
        m[13] = ty; // column-major translation.y
        inline for (0..16) |k| {
            std.mem.writeInt(u32, bin[mo + k * 4 ..][0..4], @bitCast(m[k]), .little);
        }
    }

    // animation: 3 keyframe times + 3 rotation quats (id → ~rotZ(0.7) → id)
    const a_times = [3]f32{ 0.0, 0.5, 1.0 };
    for (a_times, 0..) |tv, i| {
        std.mem.writeInt(u32, bin[off_atime + @as(u32, @intCast(i)) * 4 ..][0..4], @bitCast(tv), .little);
    }
    const a_half: f32 = 0.7 * 0.5;
    const a_sin = @sin(a_half);
    const a_cos = @cos(a_half);
    const a_quats = [3][4]f32{ .{ 0, 0, 0, 1 }, .{ 0, 0, a_sin, a_cos }, .{ 0, 0, 0, 1 } };
    for (a_quats, 0..) |q, i| {
        const base = off_arot + @as(u32, @intCast(i)) * 16;
        inline for (0..4) |c| std.mem.writeInt(u32, bin[base + c * 4 ..][0..4], @bitCast(q[c]), .little);
    }

    // PNG
    @memcpy(bin[off_png..][0..png_len], png_bytes);

    // ── JSON chunk ─────────────────────────────────────────────────────────────
    var json_aw: std.Io.Writer.Allocating = .init(alloc);
    defer json_aw.deinit();
    const w = &json_aw.writer;

    try w.writeAll("{");
    try w.writeAll("\"asset\":{\"version\":\"2.0\"},");
    try w.writeAll("\"scene\":0,");
    try w.writeAll("\"scenes\":[{\"nodes\":[0,1]}],");
    // node0 = mesh (skin 0); node1..3 = joint chain root→mid→top
    try w.writeAll("\"nodes\":[");
    try w.writeAll("{\"mesh\":0,\"skin\":0,\"name\":\"SkinBar\"},");
    try w.writeAll("{\"name\":\"jroot\",\"translation\":[0.0,0.0,0.0],\"children\":[2]},");
    try w.writeAll("{\"name\":\"jmid\",\"translation\":[0.0,1.5,0.0],\"children\":[3]},");
    try w.writeAll("{\"name\":\"jtop\",\"translation\":[0.0,1.5,0.0]}");
    try w.writeAll("],");
    try w.writeAll("\"skins\":[{\"joints\":[1,2,3],\"inverseBindMatrices\":6}],");
    try w.writeAll("\"meshes\":[{\"primitives\":[{\"attributes\":{");
    try w.writeAll("\"POSITION\":0,\"NORMAL\":1,\"TEXCOORD_0\":2,\"JOINTS_0\":3,\"WEIGHTS_0\":4");
    try w.writeAll("},\"indices\":5,\"material\":0}]}],");

    // accessors
    try w.writeAll("\"accessors\":[");
    try w.print("{{\"bufferView\":0,\"componentType\":5126,\"count\":{d},\"type\":\"VEC3\"}},", .{vert_count});
    try w.print("{{\"bufferView\":1,\"componentType\":5126,\"count\":{d},\"type\":\"VEC3\"}},", .{vert_count});
    try w.print("{{\"bufferView\":2,\"componentType\":5126,\"count\":{d},\"type\":\"VEC2\"}},", .{vert_count});
    // JOINTS_0: unsigned byte (5121), VEC4
    try w.print("{{\"bufferView\":3,\"componentType\":5121,\"count\":{d},\"type\":\"VEC4\"}},", .{vert_count});
    // WEIGHTS_0: f32 (5126), VEC4
    try w.print("{{\"bufferView\":4,\"componentType\":5126,\"count\":{d},\"type\":\"VEC4\"}},", .{vert_count});
    try w.print("{{\"bufferView\":5,\"componentType\":5123,\"count\":{d},\"type\":\"SCALAR\"}},", .{index_count});
    try w.print("{{\"bufferView\":6,\"componentType\":5126,\"count\":{d},\"type\":\"MAT4\"}}", .{joint_count});
    try w.writeAll(",{\"bufferView\":7,\"componentType\":5126,\"count\":3,\"type\":\"SCALAR\"}");
    try w.writeAll(",{\"bufferView\":8,\"componentType\":5126,\"count\":3,\"type\":\"VEC4\"}");
    try w.writeAll("],");

    // bufferViews
    try w.writeAll("\"bufferViews\":[");
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ off_pos, len_pos });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ off_nrm, len_nrm });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ off_uv, len_uv });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ off_jnt, len_jnt });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ off_wgt, len_wgt });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d},\"target\":34963}},", .{ off_idx, len_idx });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ off_ibm, len_ibm });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ off_atime, len_atime }); // 7 anim times
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ off_arot, len_arot }); // 8 anim rot
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}}", .{ off_png, png_len }); // 9 PNG
    try w.writeAll("],");

    try w.print("\"buffers\":[{{\"byteLength\":{d}}}],", .{bin_total});
    try w.writeAll("\"materials\":[{\"pbrMetallicRoughness\":{\"baseColorTexture\":{\"index\":0},\"baseColorFactor\":[1.0,1.0,1.0,1.0],\"metallicFactor\":0.0,\"roughnessFactor\":0.8}}],");
    try w.writeAll("\"textures\":[{\"source\":0}],");
    try w.writeAll("\"images\":[{\"bufferView\":9,\"mimeType\":\"image/png\"}],");
    try w.writeAll("\"animations\":[{\"channels\":[{\"sampler\":0,\"target\":{\"node\":2,\"path\":\"rotation\"}}],\"samplers\":[{\"input\":7,\"output\":8,\"interpolation\":\"LINEAR\"}]}]");
    try w.writeAll("}");

    while (json_aw.writer.end % 4 != 0) try w.writeByte(0x20);
    const json_bytes = try json_aw.toOwnedSlice();
    defer alloc.free(json_bytes);
    const json_len: u32 = @intCast(json_bytes.len);

    // ── assemble GLB ───────────────────────────────────────────────────────────
    const glb_len: u32 = 12 + 8 + json_len + 8 + bin_padded;
    var glb = try alloc.alloc(u8, glb_len);
    var goff: usize = 0;
    @memcpy(glb[goff..][0..4], "glTF");
    goff += 4;
    std.mem.writeInt(u32, glb[goff..][0..4], 2, .little);
    goff += 4;
    std.mem.writeInt(u32, glb[goff..][0..4], glb_len, .little);
    goff += 4;
    std.mem.writeInt(u32, glb[goff..][0..4], json_len, .little);
    goff += 4;
    @memcpy(glb[goff..][0..4], "JSON");
    goff += 4;
    @memcpy(glb[goff..][0..json_len], json_bytes);
    goff += json_len;
    std.mem.writeInt(u32, glb[goff..][0..4], bin_padded, .little);
    goff += 4;
    glb[goff] = 0x42;
    glb[goff + 1] = 0x49;
    glb[goff + 2] = 0x4E;
    glb[goff + 3] = 0x00;
    goff += 4;
    @memcpy(glb[goff..][0..bin_padded], bin);
    return glb;
}

/// Procedural studio environment as a complete .hdr file (flat RGBE):
/// vertical gradient (zenith (0.4,0.6,1.2) -> horizon (1.0,0.8,0.6) ->
/// ground (0.15,0.12,0.1)) plus a sun disk (~12 deg diameter) at
/// direction ~(+0.5,+0.6,-0.6) normalized, radiance (60,55,45).
/// Defaults used by the demo: w=256, h=128.
///
/// Equirect convention matches ibl.zig (inverse mapping):
///   φ = (u − 0.5)·2π, θ = v·π,
///   d = (sinθ·sinφ, cosθ, −sinθ·cosφ).
pub fn studioHdr(alloc: Allocator, w: u32, h: u32) ![]u8 {
    const zenith = [3]f32{ 0.4, 0.6, 1.2 };
    const horizon = [3]f32{ 1.0, 0.8, 0.6 };
    const ground = [3]f32{ 0.15, 0.12, 0.1 };
    const sun_rad = [3]f32{ 60.0, 55.0, 45.0 };

    // Normalize sun direction (0.5,0.6,-0.6).
    const sx: f32 = 0.5;
    const sy: f32 = 0.6;
    const sz: f32 = -0.6;
    const slen = @sqrt(sx * sx + sy * sy + sz * sz);
    const sun = [3]f32{ sx / slen, sy / slen, sz / slen };

    // ~12° diameter → 6° angular radius.
    const cos_radius = @cos(6.0 * std.math.pi / 180.0);

    const npix = @as(usize, w) * @as(usize, h);
    const rgb = try alloc.alloc(f32, npix * 3);
    defer alloc.free(rgb);

    var py: u32 = 0;
    while (py < h) : (py += 1) {
        const v = (@as(f32, @floatFromInt(py)) + 0.5) / @as(f32, @floatFromInt(h));
        // Gradient: zenith@v=0 → horizon@v=0.5 → ground@v=1.
        var g: [3]f32 = undefined;
        if (v < 0.5) {
            const t = v / 0.5;
            for (0..3) |c| g[c] = zenith[c] + (horizon[c] - zenith[c]) * t;
        } else {
            const t = (v - 0.5) / 0.5;
            for (0..3) |c| g[c] = horizon[c] + (ground[c] - horizon[c]) * t;
        }
        const theta = v * std.math.pi;
        const sin_t = @sin(theta);
        const cos_t = @cos(theta);

        var px: u32 = 0;
        while (px < w) : (px += 1) {
            const u = (@as(f32, @floatFromInt(px)) + 0.5) / @as(f32, @floatFromInt(w));
            const phi = (u - 0.5) * 2.0 * std.math.pi;
            const dx = sin_t * @sin(phi);
            const dy = cos_t;
            const dz = -sin_t * @cos(phi);
            // d is unit (sin²+cos² over the sphere); sun is unit → dot = cos(angle).
            const cd = dx * sun[0] + dy * sun[1] + dz * sun[2];

            var col = g;
            if (cd > cos_radius) {
                for (0..3) |c| col[c] += sun_rad[c];
            }
            const idx = (@as(usize, py) * w + px) * 3;
            rgb[idx + 0] = col[0];
            rgb[idx + 1] = col[1];
            rgb[idx + 2] = col[2];
        }
    }

    return hdr.encode(alloc, rgb, w, h);
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "glb container shape" {
    const glb = try texturedCubeGlb(testing.allocator);
    defer testing.allocator.free(glb);
    try testing.expectEqualSlices(u8, "glTF", glb[0..4]);
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, glb[4..8], .little));
    try testing.expectEqual(@as(u32, @intCast(glb.len)), std.mem.readInt(u32, glb[8..12], .little));
    // first chunk is JSON
    try testing.expectEqualSlices(u8, "JSON", glb[16..20]);
    // chunks 4-aligned
    const json_len = std.mem.readInt(u32, glb[12..16], .little);
    try testing.expectEqual(@as(u32, 0), json_len % 4);
}

test "json chunk parses as valid JSON with required arrays" {
    const glb = try texturedCubeGlb(testing.allocator);
    defer testing.allocator.free(glb);
    const json_len = std.mem.readInt(u32, glb[12..16], .little);
    const json = glb[20 .. 20 + json_len];
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqual(@as(usize, 1), root.get("meshes").?.array.items.len);
    try testing.expectEqual(@as(usize, 4), root.get("accessors").?.array.items.len);
    try testing.expectEqual(@as(usize, 5), root.get("bufferViews").?.array.items.len);
    try testing.expectEqual(@as(usize, 1), root.get("materials").?.array.items.len);
    try testing.expectEqual(@as(usize, 1), root.get("images").?.array.items.len);
}

// ── pbrCubeGlb fixture tests ────────────────────────────────────────────────────

fn pbrGlbInvariants(glb: []const u8) !void {
    try testing.expectEqualSlices(u8, "glTF", glb[0..4]);
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, glb[4..8], .little));
    try testing.expectEqual(@as(u32, @intCast(glb.len)), std.mem.readInt(u32, glb[8..12], .little));
    try testing.expectEqualSlices(u8, "JSON", glb[16..20]);
    const json_len = std.mem.readInt(u32, glb[12..16], .little);
    try testing.expectEqual(@as(u32, 0), json_len % 4);
    // JSON parses + has the 5 PBR maps (images/textures).
    const json = glb[20 .. 20 + json_len];
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqual(@as(usize, 5), root.get("images").?.array.items.len);
    try testing.expectEqual(@as(usize, 5), root.get("textures").?.array.items.len);
    try testing.expectEqual(@as(usize, 1), root.get("materials").?.array.items.len);
}

test "pbrCubeGlb with_tangents=true: container + JSON invariants" {
    const glb = try pbrCubeGlb(testing.allocator, .{ .with_tangents = true });
    defer testing.allocator.free(glb);
    try pbrGlbInvariants(glb);
    // accessor count: pos,normal,tangent,uv,indices = 5
    const json_len = std.mem.readInt(u32, glb[12..16], .little);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, glb[20 .. 20 + json_len], .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 5), parsed.value.object.get("accessors").?.array.items.len);
}

test "pbrCubeGlb with_tangents=false: no TANGENT accessor" {
    const glb = try pbrCubeGlb(testing.allocator, .{ .with_tangents = false });
    defer testing.allocator.free(glb);
    try pbrGlbInvariants(glb);
    // accessor count: pos,normal,uv,indices = 4 (no tangent)
    const json_len = std.mem.readInt(u32, glb[12..16], .little);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, glb[20 .. 20 + json_len], .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 4), parsed.value.object.get("accessors").?.array.items.len);
}

// ── skinnedBarGlb fixture tests ─────────────────────────────────────────────────

test "skinnedBarGlb: container + skin/JOINTS_0/WEIGHTS_0 present" {
    const glb = try skinnedBarGlb(testing.allocator);
    defer testing.allocator.free(glb);
    // GLB container invariants
    try testing.expectEqualSlices(u8, "glTF", glb[0..4]);
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, glb[4..8], .little));
    try testing.expectEqual(@as(u32, @intCast(glb.len)), std.mem.readInt(u32, glb[8..12], .little));
    try testing.expectEqualSlices(u8, "JSON", glb[16..20]);
    const json_len = std.mem.readInt(u32, glb[12..16], .little);
    try testing.expectEqual(@as(u32, 0), json_len % 4);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, glb[20 .. 20 + json_len], .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    // skins[0].joints has 3 entries; inverseBindMatrices accessor present.
    const skins = root.get("skins").?.array.items;
    try testing.expectEqual(@as(usize, 1), skins.len);
    try testing.expectEqual(@as(usize, 3), skins[0].object.get("joints").?.array.items.len);
    try testing.expect(skins[0].object.get("inverseBindMatrices") != null);
    // primitive carries JOINTS_0 + WEIGHTS_0
    const prim = root.get("meshes").?.array.items[0].object.get("primitives").?.array.items[0].object;
    const attrs = prim.get("attributes").?.object;
    try testing.expect(attrs.get("JOINTS_0") != null);
    try testing.expect(attrs.get("WEIGHTS_0") != null);
    // 9 accessors (pos,nrm,uv,joints,weights,indices,ibm,anim_times,anim_rot)
    try testing.expectEqual(@as(usize, 9), root.get("accessors").?.array.items.len);
    try testing.expect(root.get("animations") != null);
}

// ── studioHdr fixture tests ─────────────────────────────────────────────────────

test "studioHdr round-trips: sun texel > 10x zenith texel" {
    const alloc = testing.allocator;
    const w: u32 = 256;
    const h: u32 = 128;
    const bytes = try studioHdr(alloc, w, h);
    defer alloc.free(bytes);

    var img = try hdr.decode(alloc, bytes);
    defer img.deinit(alloc);
    try testing.expectEqual(w, img.width);
    try testing.expectEqual(h, img.height);

    // Zenith texel: top row, any column (gradient near zenith color).
    const zen_idx: usize = (0 * @as(usize, w) + 0) * 3;
    const zen_lum = img.rgb[zen_idx + 0] + img.rgb[zen_idx + 1] + img.rgb[zen_idx + 2];

    // Find the brightest texel (the sun disk).
    var max_lum: f32 = 0;
    var i: usize = 0;
    while (i < @as(usize, w) * h) : (i += 1) {
        const lum = img.rgb[i * 3 + 0] + img.rgb[i * 3 + 1] + img.rgb[i * 3 + 2];
        if (lum > max_lum) max_lum = lum;
    }
    try testing.expect(max_lum > zen_lum * 10.0);
}
