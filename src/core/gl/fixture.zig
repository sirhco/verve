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
    try w.writeAll("\"occlusionTexture\":{\"index\":4,\"strength\":0.8},");
    try w.writeAll("\"alphaMode\":\"BLEND\"");
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

// ── alpha-test cutout cube fixture (MASK) ────────────────────────────────────────

/// Single-cube glb whose base-color texture carries a REAL alpha channel with
/// HOLES (zero-alpha texels) and whose material is `"alphaMode":"MASK"` with
/// `"alphaCutoff":0.5`. The `variant_alpha_test` shader discards any fragment
/// whose sampled base-texture alpha is below the cutoff, so the holes punch
/// clean see-through cutouts (hard edge, no translucency).
///
/// Hole pattern: a 32-px diagonal-stripe grid (zero alpha along the stripes)
/// plus a punched circular center, so the cutout is unmistakable from any
/// viewing angle. The non-hole texels keep alpha=255 (fully kept).
///
/// Mesh name "Cutout" (node "CutoutCube") so name-based animation targets the
/// submesh as `material:Cutout.baseColorA`; the /gl-cutout dissolve scrub
/// drives baseColorA 1.0→0.0 (the base-color alpha multiplies the sampled
/// texture alpha → as it falls, more texels drop below the cutoff and the
/// silhouette erodes). NO tangents are baked: the asset-gen tool generates
/// them, matching demo/mixed/shadow.
pub fn pbrCubeCutoutGlb(alloc: Allocator) ![]u8 {
    // ── 1. Build the base-color map with alpha holes (256×256 RGBA) ────────────
    const base_dim: u32 = 256;
    const base_map = try alloc.alloc(u8, base_dim * base_dim * 4);
    defer alloc.free(base_map);
    {
        const cx: i64 = @intCast(base_dim / 2);
        const cy: i64 = @intCast(base_dim / 2);
        // Punched-center radius² (≈ 1/6 of the half-extent) — a clean round hole.
        const r: i64 = @intCast(base_dim / 6);
        const r2: i64 = r * r;
        var y: u32 = 0;
        while (y < base_dim) : (y += 1) {
            var x: u32 = 0;
            while (x < base_dim) : (x += 1) {
                const idx = (y * base_dim + x) * 4;
                // Opaque checkerboard base color (warm/cool cells) so the kept
                // texels read clearly against the punched holes.
                const cell = ((x / 32) + (y / 32)) % 2 == 0;
                base_map[idx + 0] = if (cell) 230 else 60;
                base_map[idx + 1] = if (cell) 90 else 170;
                base_map[idx + 2] = if (cell) 60 else 210;
                // Alpha HOLES: diagonal-stripe grid + punched circular center.
                // Stripe holes: an 8-px-wide zero-alpha band every 32 px along
                // the (x+y) diagonal → an unmistakable lattice of cutouts.
                const diag: u32 = (x +% y) % 32;
                const on_stripe = diag < 8;
                // Center hole: texels inside the circle are punched out.
                const dx: i64 = @as(i64, @intCast(x)) - cx;
                const dy: i64 = @as(i64, @intCast(y)) - cy;
                const in_center = (dx * dx + dy * dy) < r2;
                base_map[idx + 3] = if (on_stripe or in_center) 0 else 255;
            }
        }
    }

    // ── The four 8×8 PBR side maps (same scheme as pbrCubeGlb) ─────────────────
    var mr_map: [8 * 8 * 4]u8 = undefined;
    var nrm_map: [8 * 8 * 4]u8 = undefined;
    var emi_map: [8 * 8 * 4]u8 = undefined;
    var occ_map: [8 * 8 * 4]u8 = undefined;
    for (0..8) |row| {
        for (0..8) |col| {
            const idx = (row * 8 + col) * 4;
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
        }
    }

    // ── Receiver-plane base map (8×8 neutral floor). The directional light
    // casts the cube's hole-accurate shadow onto this opaque plane so the
    // cutout shadow is actually VISIBLE in the /gl-cutout scene. A faint
    // checker reads the shadow clearly against the floor. ──────────────────────
    var floor_map: [8 * 8 * 4]u8 = undefined;
    for (0..8) |row| {
        for (0..8) |col| {
            const idx = (row * 8 + col) * 4;
            const lightcell = (row + col) % 2 == 0;
            const f: u8 = if (lightcell) 205 else 185;
            floor_map[idx + 0] = f;
            floor_map[idx + 1] = f;
            floor_map[idx + 2] = @intCast(@as(u16, f) + 8);
            floor_map[idx + 3] = 255;
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
    const floor_png = try png.encodeRgba(alloc, &floor_map, 8, 8);
    defer alloc.free(floor_png);

    const pngs = [6][]const u8{ base_png, mr_png, nrm_png, emi_png, occ_png, floor_png };

    // ── 2. BIN layout (NO tangents — asset-gen generates them) ─────────────────
    // Cube geometry first (mesh 0 "Cutout"), then the receiver-plane quad
    // geometry (mesh 1 "ReceiverPlane"), then the six PNGs. The floor's 8×8 map
    // (<64×64) stays in-blob; only the cube's 256² base externalizes to tex0.
    const p_pos_off: u32 = 0;
    const p_pos_len: u32 = 24 * 3 * 4; // 288
    const p_nrm_off: u32 = p_pos_off + p_pos_len;
    const p_nrm_len: u32 = 24 * 3 * 4; // 288
    const p_uv_off: u32 = p_nrm_off + p_nrm_len;
    const p_uv_len: u32 = 24 * 2 * 4; // 192
    const p_idx_off: u32 = p_uv_off + p_uv_len;
    const p_idx_len: u32 = 36 * 2; // 72
    // Receiver plane: 4-vertex quad.
    const fl_pos_off: u32 = (p_idx_off + p_idx_len + 3) & ~@as(u32, 3);
    const fl_geom_len: u32 = 4 * 3 * 4; // 48 (pos / nrm)
    const fl_nrm_off: u32 = fl_pos_off + fl_geom_len;
    const fl_uv_off: u32 = fl_nrm_off + fl_geom_len;
    const fl_uv_len: u32 = 4 * 2 * 4; // 32
    const fl_idx_off: u32 = fl_uv_off + fl_uv_len;
    const fl_idx_len: u32 = 6 * 2; // 12
    var png_offs: [6]u32 = undefined;
    var cursor: u32 = (fl_idx_off + fl_idx_len + 3) & ~@as(u32, 3);
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

    var off: usize = p_pos_off;
    for (faces) |face| {
        for (face.v) |v| {
            std.mem.writeInt(u32, bin[off..][0..4], @bitCast(v[0]), .little);
            std.mem.writeInt(u32, bin[off + 4 ..][0..4], @bitCast(v[1]), .little);
            std.mem.writeInt(u32, bin[off + 8 ..][0..4], @bitCast(v[2]), .little);
            off += 12;
        }
    }
    off = p_nrm_off;
    for (faces) |face| {
        for (0..4) |_| {
            std.mem.writeInt(u32, bin[off..][0..4], @bitCast(face.nx), .little);
            std.mem.writeInt(u32, bin[off + 4 ..][0..4], @bitCast(face.ny), .little);
            std.mem.writeInt(u32, bin[off + 8 ..][0..4], @bitCast(face.nz), .little);
            off += 12;
        }
    }
    off = p_uv_off;
    for (faces) |_| {
        for (face_uvs) |uv| {
            std.mem.writeInt(u32, bin[off..][0..4], @bitCast(uv[0]), .little);
            std.mem.writeInt(u32, bin[off + 4 ..][0..4], @bitCast(uv[1]), .little);
            off += 8;
        }
    }
    off = p_idx_off;
    for (0..6) |face_i| {
        const base: u16 = @intCast(face_i * 4);
        const tri_offsets = [6]u16{ 0, 1, 2, 0, 2, 3 };
        for (tri_offsets) |o| {
            std.mem.writeInt(u16, bin[off..][0..2], base + o, .little);
            off += 2;
        }
    }

    // Receiver plane: a large +Y-facing quad at y = -1.5 spanning [-6,6] on X/Z,
    // just below the cube (extent ±1). The directional light (dir ≈ down/away)
    // projects the cube's alpha-tested shadow onto it. Winding chosen so the
    // up-facing side survives back-face culling.
    {
        const fy: f32 = -1.5;
        const s: f32 = 6.0;
        const fpos = [4][3]f32{
            .{ -s, fy, -s }, .{ s, fy, -s }, .{ s, fy, s }, .{ -s, fy, s },
        };
        var po: usize = fl_pos_off;
        for (fpos) |v| {
            std.mem.writeInt(u32, bin[po..][0..4], @bitCast(v[0]), .little);
            std.mem.writeInt(u32, bin[po + 4 ..][0..4], @bitCast(v[1]), .little);
            std.mem.writeInt(u32, bin[po + 8 ..][0..4], @bitCast(v[2]), .little);
            po += 12;
        }
        var no: usize = fl_nrm_off;
        for (0..4) |_| {
            std.mem.writeInt(u32, bin[no..][0..4], @bitCast(@as(f32, 0)), .little);
            std.mem.writeInt(u32, bin[no + 4 ..][0..4], @bitCast(@as(f32, 1)), .little);
            std.mem.writeInt(u32, bin[no + 8 ..][0..4], @bitCast(@as(f32, 0)), .little);
            no += 12;
        }
        const fuv = [4][2]f32{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 4 }, .{ 0, 4 } };
        var uo: usize = fl_uv_off;
        for (fuv) |uv| {
            std.mem.writeInt(u32, bin[uo..][0..4], @bitCast(uv[0]), .little);
            std.mem.writeInt(u32, bin[uo + 4 ..][0..4], @bitCast(uv[1]), .little);
            uo += 8;
        }
        var io: usize = fl_idx_off;
        for ([6]u16{ 0, 2, 1, 0, 3, 2 }) |o| {
            std.mem.writeInt(u16, bin[io..][0..2], o, .little);
            io += 2;
        }
    }

    for (pngs, 0..) |p, i| {
        @memcpy(bin[png_offs[i]..][0..p.len], p);
    }

    // ── 3. JSON ────────────────────────────────────────────────────────────────
    var json_aw: std.Io.Writer.Allocating = .init(alloc);
    defer json_aw.deinit();
    const w = &json_aw.writer;

    // accessors: cube 0=POSITION 1=NORMAL 2=UV 3=indices; receiver plane
    // 4=POSITION 5=NORMAL 6=UV 7=indices. bufferViews mirror those 8 geom views,
    // then the 6 PNG views. The image bufferViews start after the geom views.
    const bv_count_geom: u32 = 8;

    try w.writeAll("{");
    try w.writeAll("\"asset\":{\"version\":\"2.0\"},");
    try w.writeAll("\"scene\":0,");
    try w.writeAll("\"scenes\":[{\"nodes\":[0,1]}],");
    // Node 0 keeps the original name "CutoutCube" (the addressable submesh). Node
    // 1 is the opaque shadow receiver.
    try w.writeAll("\"nodes\":[{\"mesh\":0,\"name\":\"CutoutCube\"},{\"mesh\":1,\"name\":\"ReceiverPlane\"}],");
    try w.writeAll("\"meshes\":[");
    try w.writeAll("{\"name\":\"Cutout\",\"primitives\":[{\"attributes\":{");
    try w.writeAll("\"POSITION\":0,\"NORMAL\":1,\"TEXCOORD_0\":2");
    try w.writeAll("},\"indices\":3,\"material\":0}]},");
    try w.writeAll("{\"name\":\"ReceiverPlane\",\"primitives\":[{\"attributes\":{");
    try w.writeAll("\"POSITION\":4,\"NORMAL\":5,\"TEXCOORD_0\":6");
    try w.writeAll("},\"indices\":7,\"material\":1}]}");
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
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ p_pos_off, p_pos_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ p_nrm_off, p_nrm_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ p_uv_off, p_uv_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d},\"target\":34963}},", .{ p_idx_off, p_idx_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ fl_pos_off, fl_geom_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ fl_nrm_off, fl_geom_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ fl_uv_off, fl_uv_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d},\"target\":34963}},", .{ fl_idx_off, fl_idx_len });
    for (pngs, 0..) |p, i| {
        try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}}", .{ png_offs[i], p.len });
        if (i + 1 < pngs.len) try w.writeAll(",");
    }
    try w.writeAll("],");

    try w.print("\"buffers\":[{{\"byteLength\":{d}}}],", .{bin_total});
    // material 0: the MASK cutout cube (unchanged). material 1: the OPAQUE
    // receiver plane (default alphaMode → alpha_mode 0 → draws in the opaque
    // pass and receives the cube's cast shadow). Floor texture is source 5.
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
    try w.writeAll("\"occlusionTexture\":{\"index\":4,\"strength\":0.8},");
    try w.writeAll("\"alphaMode\":\"MASK\",\"alphaCutoff\":0.5");
    try w.writeAll("},{");
    try w.writeAll("\"pbrMetallicRoughness\":{\"baseColorFactor\":[1.0,1.0,1.0,1.0],");
    try w.writeAll("\"baseColorTexture\":{\"index\":5},\"metallicFactor\":0.0,\"roughnessFactor\":1.0}");
    try w.writeAll("}],");
    try w.writeAll("\"textures\":[");
    for (0..6) |i| {
        try w.print("{{\"source\":{d}}}", .{i});
        if (i + 1 < 6) try w.writeAll(",");
    }
    try w.writeAll("],");
    try w.writeAll("\"images\":[");
    for (0..6) |i| {
        try w.print("{{\"bufferView\":{d},\"mimeType\":\"image/png\"}}", .{bv_count_geom + @as(u32, @intCast(i))});
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
    const off_twmid: u32 = off_arot + len_arot;
    const len_twmid: u32 = 3 * 4 * 4; // 3 VEC4 quats
    const off_twtop: u32 = off_twmid + len_twmid;
    const len_twtop: u32 = 3 * 4 * 4;
    const off_png: u32 = off_twtop + len_twtop;
    const png_len: u32 = @intCast(png_bytes.len);
    const off_smooth: u32 = off_png + png_len;
    const len_smooth: u32 = 9 * 16; // CUBICSPLINE: 3 keys × (inTangent, point, outTangent) × VEC4

    const bin_total: u32 = off_smooth + len_smooth;
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

    // twist: per-joint Y rotation (id → rotY(θ) → id); jmid + jtop both θ=0.6.
    const tw_half: f32 = 0.6 * 0.5;
    const tw_sin = @sin(tw_half);
    const tw_cos = @cos(tw_half);
    const tw_quats = [3][4]f32{ .{ 0, 0, 0, 1 }, .{ 0, tw_sin, 0, tw_cos }, .{ 0, 0, 0, 1 } };
    for (tw_quats, 0..) |q, i| {
        const bm = off_twmid + @as(u32, @intCast(i)) * 16;
        const bt = off_twtop + @as(u32, @intCast(i)) * 16;
        inline for (0..4) |c| {
            std.mem.writeInt(u32, bin[bm + c * 4 ..][0..4], @bitCast(q[c]), .little);
            std.mem.writeInt(u32, bin[bt + c * 4 ..][0..4], @bitCast(q[c]), .little);
        }
    }

    // smooth (CUBICSPLINE): jmid Z rotation, SAME points as Bend (id → rotZ(0.7) → id) but
    // with non-zero in/out tangents so the cubic visibly OVERSHOOTS the LINEAR Bend mid-segment
    // (lets a frozen mid-time pose-diff distinguish CUBICSPLINE from LINEAR). glTF layout per
    // key: [inTangent.xyzw, point.xyzw, outTangent.xyzw].
    const sm_t: f32 = 1.5; // tangent magnitude (value/sec; runtime scales by the 0.5s segment)
    const sm_quats = [9][4]f32{
        .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 1 }, .{ 0, 0, sm_t, 0 }, // key0 in, point(id), out
        .{ 0, 0, sm_t, 0 }, .{ 0, 0, a_sin, a_cos }, .{ 0, 0, -sm_t, 0 }, // key1 in, point(rotZ), out
        .{ 0, 0, -sm_t, 0 }, .{ 0, 0, 0, 1 }, .{ 0, 0, 0, 0 }, // key2 in, point(id), out
    };
    for (sm_quats, 0..) |q, i| {
        const base = off_smooth + @as(u32, @intCast(i)) * 16;
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
    try w.writeAll(",{\"bufferView\":9,\"componentType\":5126,\"count\":3,\"type\":\"VEC4\"}"); // 9 twist jmid
    try w.writeAll(",{\"bufferView\":10,\"componentType\":5126,\"count\":3,\"type\":\"VEC4\"}"); // 10 twist jtop
    try w.writeAll(",{\"bufferView\":12,\"componentType\":5126,\"count\":9,\"type\":\"VEC4\"}"); // 11 smooth (CUBICSPLINE: 3 keys × 3 slots)
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
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ off_atime, len_atime }); // 7 times
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ off_arot, len_arot }); // 8 bend rot
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ off_twmid, len_twmid }); // 9 twist jmid
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ off_twtop, len_twtop }); // 10 twist jtop
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ off_png, png_len }); // 11 PNG
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}}", .{ off_smooth, len_smooth }); // 12 smooth cubicspline
    try w.writeAll("],");

    try w.print("\"buffers\":[{{\"byteLength\":{d}}}],", .{bin_total});
    try w.writeAll("\"materials\":[{\"pbrMetallicRoughness\":{\"baseColorTexture\":{\"index\":0},\"baseColorFactor\":[1.0,1.0,1.0,1.0],\"metallicFactor\":0.0,\"roughnessFactor\":0.8}}],");
    try w.writeAll("\"textures\":[{\"source\":0}],");
    try w.writeAll("\"images\":[{\"bufferView\":11,\"mimeType\":\"image/png\"}],");
    try w.writeAll("\"animations\":[" ++
        "{\"name\":\"Bend\",\"channels\":[{\"sampler\":0,\"target\":{\"node\":2,\"path\":\"rotation\"}}],\"samplers\":[{\"input\":7,\"output\":8,\"interpolation\":\"LINEAR\"}]}," ++
        "{\"name\":\"Twist\",\"channels\":[{\"sampler\":0,\"target\":{\"node\":2,\"path\":\"rotation\"}},{\"sampler\":1,\"target\":{\"node\":3,\"path\":\"rotation\"}}],\"samplers\":[{\"input\":7,\"output\":9,\"interpolation\":\"LINEAR\"},{\"input\":7,\"output\":10,\"interpolation\":\"LINEAR\"}]}," ++
        "{\"name\":\"Smooth\",\"channels\":[{\"sampler\":0,\"target\":{\"node\":2,\"path\":\"rotation\"}}],\"samplers\":[{\"input\":7,\"output\":11,\"interpolation\":\"CUBICSPLINE\"}]}" ++
        "]");
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

// ── pbrCubeCutoutGlb (MASK alpha-test) fixture tests ────────────────────────────

test "pbrCubeCutoutGlb: container + MASK material + alpha holes" {
    const glb = try pbrCubeCutoutGlb(testing.allocator);
    defer testing.allocator.free(glb);
    // GLB container invariants (the shared pbrGlbInvariants helper is specific to
    // the single-mesh, 5-image cube fixtures; the cutout scene now also carries
    // the opaque receiver plane → 6 images/textures + 2 materials).
    try testing.expectEqualSlices(u8, "glTF", glb[0..4]);
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, glb[4..8], .little));
    try testing.expectEqual(@as(u32, @intCast(glb.len)), std.mem.readInt(u32, glb[8..12], .little));
    try testing.expectEqualSlices(u8, "JSON", glb[16..20]);

    const json_len = std.mem.readInt(u32, glb[12..16], .little);
    try testing.expectEqual(@as(u32, 0), json_len % 4);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, glb[20 .. 20 + json_len], .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    // No tangents. Cube (pos, normal, uv, indices) + receiver plane
    // (pos, normal, uv, indices) → 8 accessors.
    try testing.expectEqual(@as(usize, 8), root.get("accessors").?.array.items.len);
    // Mesh 0 name must still be "Cutout" (the addressable submesh name); mesh 1
    // is the opaque shadow receiver.
    const meshes = root.get("meshes").?.array.items;
    try testing.expectEqual(@as(usize, 2), meshes.len);
    try testing.expectEqualStrings("Cutout", meshes[0].object.get("name").?.string);
    try testing.expectEqualStrings("ReceiverPlane", meshes[1].object.get("name").?.string);
    // Material 0 is the MASK cutout (cutoff 0.5); material 1 the opaque receiver.
    const mats = root.get("materials").?.array.items;
    try testing.expectEqual(@as(usize, 2), mats.len);
    const mat = mats[0].object;
    try testing.expectEqualStrings("MASK", mat.get("alphaMode").?.string);
    try testing.expectEqual(@as(f64, 0.5), mat.get("alphaCutoff").?.float);
    // The receiver plane has no alphaMode key → defaults to OPAQUE.
    try testing.expect(mats[1].object.get("alphaMode") == null);
    // Six PNG maps (cube's 5 PBR maps + the floor base) → 6 images/textures.
    try testing.expectEqual(@as(usize, 6), root.get("images").?.array.items.len);
    try testing.expectEqual(@as(usize, 6), root.get("textures").?.array.items.len);
}

test "pbrCubeCutoutGlb: round-trips through gltf parse → alpha_mode 2 + cutoff" {
    const glb = try pbrCubeCutoutGlb(testing.allocator);
    defer testing.allocator.free(glb);
    var model = try gltf_mod.parseGlb(testing.allocator, glb);
    defer model.deinit();
    try testing.expect(model.submeshes.len >= 1);
    // alphaMode "MASK" → alpha_mode == 2; alphaCutoff 0.5.
    try testing.expectEqual(@as(u32, 2), model.submeshes[0].alpha_mode);
    try testing.expectApproxEqAbs(@as(f32, 0.5), model.submeshes[0].alpha_cutoff, 1e-6);
    // Submesh name is "Cutout".
    try testing.expect(model.names.len >= 1);
    try testing.expectEqualStrings("Cutout", model.names[0]);
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
    // 12 accessors (pos,nrm,uv,joints,weights,indices,ibm,anim_times,bend_rot,twist_jmid,twist_jtop,smooth_cubic)
    try testing.expectEqual(@as(usize, 12), root.get("accessors").?.array.items.len);
    try testing.expectEqual(@as(usize, 3), root.get("animations").?.array.items.len);
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

// ── wind-farm fixture ──────────────────────────────────────────────────────────

/// Procedural wind-farm scene for the mission-control demo.
/// Coordinate scheme: tower vertices are in LOCAL space (centered at x=0, z=0).
/// Each turbineN glTF node carries the world x translation (-12/-4/+4/+12).
/// The rotorN child node is placed at local (0, 6.0, 0.3) — tower top + z=0.3.
/// Blade vertices are hub-local (hub at local origin), never pre-offset to world.
///
/// Geometry: one ground plane mesh ("ground") + 4 turbine tower meshes
/// ("turbine0".."turbine3") at x=-12,-4,+4,+12. Each tower: 0.5 wide, 6.0 tall,
/// local x∈[-0.25,0.25], y∈[0,6], z∈[-0.25,0.25]. Each turbine has a child
/// scene-graph node ("rotor0".."rotor3") at local (0,6,0.3) — hub at tower top.
/// Each rotor node has its own mesh ("rotor0".."rotor3") of 3 blades (2.8 long,
/// 0.25 wide, 0.1 deep) arranged at 120° around the hub axis, hub-local.
/// An anim `node:rotorN.rotationZ` tween spins the visible blades in the demo's island.
///
/// Non-skinned PBR (pos/nrm/uv, no TANGENT — gltf parser generates them).
/// One flat metallic-gray material (baseColorFactor, no textures).
/// Single-buffer GLB; BIN padded to 4 bytes.
pub fn windFarmGlb(alloc: Allocator) ![]u8 {
    // ── geometry constants ─────────────────────────────────────────────────────
    // Ground quad: 4 verts, 6 indices
    const g_vc: u32 = 4;
    const g_ic: u32 = 6;
    // Tower box per turbine: 6 faces × 4 verts = 24 verts, 36 indices
    const t_vc: u32 = 24;
    const t_ic: u32 = 36;
    const turbine_count: u32 = 4;
    // Rotor: 3 blades, each a 6-face box → 3×24=72 verts, 3×36=108 indices
    // 4 distinct rotor meshes (one per turbine) so the gltf parser bakes each
    // at its own turbine's nacelle rather than "first node wins".
    const blade_count: u32 = 3;
    const r_vc: u32 = blade_count * 24; // 72
    const r_ic: u32 = blade_count * 36; // 108

    // Per-mesh BIN sizes (bytes)
    const g_pos_len: u32 = g_vc * 12; // VEC3 f32
    const g_nrm_len: u32 = g_vc * 12;
    const g_uv_len: u32 = g_vc * 8; // VEC2 f32
    const g_idx_len: u32 = g_ic * 2; // u16

    const t_pos_len: u32 = t_vc * 12;
    const t_nrm_len: u32 = t_vc * 12;
    const t_uv_len: u32 = t_vc * 8;
    const t_idx_len: u32 = t_ic * 2;

    const r_pos_len: u32 = r_vc * 12;
    const r_nrm_len: u32 = r_vc * 12;
    const r_uv_len: u32 = r_vc * 8;
    const r_idx_len: u32 = r_ic * 2;

    // ── BIN layout: ground then turbine0..3 then rotor0..3 (4 distinct sections) ──
    const g_pos_off: u32 = 0;
    const g_nrm_off: u32 = g_pos_off + g_pos_len;
    const g_uv_off: u32 = g_nrm_off + g_nrm_len;
    const g_idx_off: u32 = g_uv_off + g_uv_len;

    var t_pos_off: [turbine_count]u32 = undefined;
    var t_nrm_off: [turbine_count]u32 = undefined;
    var t_uv_off: [turbine_count]u32 = undefined;
    var t_idx_off: [turbine_count]u32 = undefined;
    {
        var cur: u32 = (g_idx_off + g_idx_len + 3) & ~@as(u32, 3);
        for (0..turbine_count) |i| {
            t_pos_off[i] = cur;
            cur += t_pos_len;
            t_nrm_off[i] = cur;
            cur += t_nrm_len;
            t_uv_off[i] = cur;
            cur += t_uv_len;
            t_idx_off[i] = cur;
            cur += t_idx_len;
            cur = (cur + 3) & ~@as(u32, 3);
        }
    }
    // 4 distinct rotor BIN sections (same blade geometry, separate accessors/meshes)
    var r_pos_off: [turbine_count]u32 = undefined;
    var r_nrm_off: [turbine_count]u32 = undefined;
    var r_uv_off: [turbine_count]u32 = undefined;
    var r_idx_off: [turbine_count]u32 = undefined;
    {
        var cur: u32 = (t_idx_off[turbine_count - 1] + t_idx_len + 3) & ~@as(u32, 3);
        for (0..turbine_count) |i| {
            r_pos_off[i] = cur;
            cur += r_pos_len;
            r_nrm_off[i] = cur;
            cur += r_nrm_len;
            r_uv_off[i] = cur;
            cur += r_uv_len;
            r_idx_off[i] = cur;
            cur += r_idx_len;
            cur = (cur + 3) & ~@as(u32, 3);
        }
    }

    const bin_total: u32 = (r_idx_off[turbine_count - 1] + r_idx_len + 3) & ~@as(u32, 3);
    const bin_padded = (bin_total + 3) & ~@as(u32, 3);

    var bin = try alloc.alloc(u8, bin_padded);
    defer alloc.free(bin);
    @memset(bin, 0);

    // ── write ground geometry ─────────────────────────────────────────────────
    {
        const gpos = [g_vc][3]f32{
            .{ -10, 0, -10 }, .{ 10, 0, -10 }, .{ 10, 0, 10 }, .{ -10, 0, 10 },
        };
        var po: usize = g_pos_off;
        for (gpos) |v| {
            std.mem.writeInt(u32, bin[po..][0..4], @bitCast(v[0]), .little);
            std.mem.writeInt(u32, bin[po + 4 ..][0..4], @bitCast(v[1]), .little);
            std.mem.writeInt(u32, bin[po + 8 ..][0..4], @bitCast(v[2]), .little);
            po += 12;
        }
        var no: usize = g_nrm_off;
        const gn = [3]f32{ 0, 1, 0 };
        for (0..g_vc) |_| {
            std.mem.writeInt(u32, bin[no..][0..4], @bitCast(gn[0]), .little);
            std.mem.writeInt(u32, bin[no + 4 ..][0..4], @bitCast(gn[1]), .little);
            std.mem.writeInt(u32, bin[no + 8 ..][0..4], @bitCast(gn[2]), .little);
            no += 12;
        }
        const guv = [g_vc][2]f32{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 4 }, .{ 0, 4 } };
        var uo: usize = g_uv_off;
        for (guv) |uv| {
            std.mem.writeInt(u32, bin[uo..][0..4], @bitCast(uv[0]), .little);
            std.mem.writeInt(u32, bin[uo + 4 ..][0..4], @bitCast(uv[1]), .little);
            uo += 8;
        }
        var io: usize = g_idx_off;
        for ([6]u16{ 0, 2, 1, 0, 3, 2 }) |v| {
            std.mem.writeInt(u16, bin[io..][0..2], v, .little);
            io += 2;
        }
    }

    // ── write turbine tower geometry (same box shape, one per turbine) ────────
    // Coordinate scheme: tower vertices are authored in LOCAL space centered on
    // the hub axis (x=0, z=0). The turbine glTF node carries the world translation
    // to x = turbine_x[i]. The rotor child node's translation is then purely
    // local-relative: (0, tower_top_y, 0.3) lands the hub at world (tx, tower_top_y, 0.3).
    // IMPORTANT: do NOT add tx to vertex x — the node translation handles that.
    //
    // Tower box: from (-0.25, 0, -0.25) to (0.25, 6.0, 0.25), centered at x=0, z=0.
    // 6 faces, each 4 verts. CCW winding viewed from outside (+normal dir).
    const TFace = struct { nx: f32, ny: f32, nz: f32, v: [4][3]f32 };
    const h: f32 = 0.25; // tower half-width (total 0.5 per spec)
    const top: f32 = 6.0; // tower height
    const tower_faces = [6]TFace{
        .{ .nx = 1, .ny = 0, .nz = 0, .v = .{ .{ h, 0, h }, .{ h, top, h }, .{ h, top, -h }, .{ h, 0, -h } } }, // +X
        .{ .nx = -1, .ny = 0, .nz = 0, .v = .{ .{ -h, 0, -h }, .{ -h, top, -h }, .{ -h, top, h }, .{ -h, 0, h } } }, // -X
        .{ .nx = 0, .ny = 1, .nz = 0, .v = .{ .{ -h, top, -h }, .{ h, top, -h }, .{ h, top, h }, .{ -h, top, h } } }, // +Y (top cap)
        .{ .nx = 0, .ny = -1, .nz = 0, .v = .{ .{ -h, 0, h }, .{ h, 0, h }, .{ h, 0, -h }, .{ -h, 0, -h } } }, // -Y (bottom cap)
        .{ .nx = 0, .ny = 0, .nz = 1, .v = .{ .{ -h, 0, h }, .{ -h, top, h }, .{ h, top, h }, .{ h, 0, h } } }, // +Z
        .{ .nx = 0, .ny = 0, .nz = -1, .v = .{ .{ h, 0, -h }, .{ h, top, -h }, .{ -h, top, -h }, .{ -h, 0, -h } } }, // -Z
    };
    // Box face uvs (same for all faces)
    const tuv = [4][2]f32{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 } };

    // x-positions for 4 turbines spread along X
    const turbine_x = [turbine_count]f32{ -12, -4, 4, 12 };

    for (0..turbine_count) |ti| {
        var po: usize = t_pos_off[ti];
        var no: usize = t_nrm_off[ti];
        var uo: usize = t_uv_off[ti];
        for (tower_faces) |face| {
            for (face.v) |v| {
                // Vertices in local space (no tx offset — node translation handles x placement)
                std.mem.writeInt(u32, bin[po..][0..4], @bitCast(v[0]), .little);
                std.mem.writeInt(u32, bin[po + 4 ..][0..4], @bitCast(v[1]), .little);
                std.mem.writeInt(u32, bin[po + 8 ..][0..4], @bitCast(v[2]), .little);
                po += 12;
            }
            for (0..4) |_| {
                std.mem.writeInt(u32, bin[no..][0..4], @bitCast(face.nx), .little);
                std.mem.writeInt(u32, bin[no + 4 ..][0..4], @bitCast(face.ny), .little);
                std.mem.writeInt(u32, bin[no + 8 ..][0..4], @bitCast(face.nz), .little);
                no += 12;
            }
            for (tuv) |uv| {
                std.mem.writeInt(u32, bin[uo..][0..4], @bitCast(uv[0]), .little);
                std.mem.writeInt(u32, bin[uo + 4 ..][0..4], @bitCast(uv[1]), .little);
                uo += 8;
            }
        }
        var io: usize = t_idx_off[ti];
        for (0..6) |fi| {
            const base: u16 = @intCast(fi * 4);
            for ([6]u16{ 0, 1, 2, 0, 2, 3 }) |o| {
                std.mem.writeInt(u16, bin[io..][0..2], base + o, .little);
                io += 2;
            }
        }
    }

    // ── write rotor blade geometry (4 distinct meshes, identical geometry) ───────
    // 3 blades at 0°, 120°, 240° in local XY plane (rotor spins about Z).
    // Blade local space: hub is at local origin (0,0,0). Each blade (at angle 0)
    // extends from x=0.15 (hub clearance) to x=2.95 (total ~2.8 long), 0.25 wide in Y,
    // 0.1 deep in Z. Blade 0 points along +X; blades 1,2 are rotated 120°,240° about Z.
    // When rotorN node is placed at (0, top_y, 0.3) relative to turbineN, rotating
    // the node about Z sweeps all blades around the hub — blades never need a world offset.
    // Writing the same blade geometry 4 times (once per turbine) gives each its own
    // mesh so the gltf parser bakes each rotor node's transform independently.
    {
        const blade_len: f32 = 2.8;
        const blade_start: f32 = 0.15; // clearance from hub centre
        const bw: f32 = 0.125; // half-width in Y (total 0.25)
        const bd: f32 = 0.05; // half-depth in Z (total 0.1)

        const BFace = struct { nx: f32, ny: f32, nz: f32, v: [4][3]f32 };
        const bx0: f32 = blade_start;
        const bx1: f32 = blade_start + blade_len;
        const blade_faces = [6]BFace{
            .{ .nx = 1, .ny = 0, .nz = 0, .v = .{ .{ bx1, -bw, bd }, .{ bx1, bw, bd }, .{ bx1, bw, -bd }, .{ bx1, -bw, -bd } } }, // +X tip
            .{ .nx = -1, .ny = 0, .nz = 0, .v = .{ .{ bx0, -bw, -bd }, .{ bx0, bw, -bd }, .{ bx0, bw, bd }, .{ bx0, -bw, bd } } }, // -X root
            .{ .nx = 0, .ny = 1, .nz = 0, .v = .{ .{ bx0, bw, -bd }, .{ bx1, bw, -bd }, .{ bx1, bw, bd }, .{ bx0, bw, bd } } }, // +Y edge
            .{ .nx = 0, .ny = -1, .nz = 0, .v = .{ .{ bx0, -bw, bd }, .{ bx1, -bw, bd }, .{ bx1, -bw, -bd }, .{ bx0, -bw, -bd } } }, // -Y edge
            .{ .nx = 0, .ny = 0, .nz = 1, .v = .{ .{ bx0, -bw, bd }, .{ bx0, bw, bd }, .{ bx1, bw, bd }, .{ bx1, -bw, bd } } }, // +Z face
            .{ .nx = 0, .ny = 0, .nz = -1, .v = .{ .{ bx1, -bw, -bd }, .{ bx1, bw, -bd }, .{ bx0, bw, -bd }, .{ bx0, -bw, -bd } } }, // -Z face
        };

        const pi: f32 = std.math.pi;
        const blade_angles = [blade_count]f32{ 0.0, 2.0 * pi / 3.0, 4.0 * pi / 3.0 };

        for (0..turbine_count) |ri| {
            var po: usize = r_pos_off[ri];
            var no: usize = r_nrm_off[ri];
            var uo: usize = r_uv_off[ri];
            var io: usize = r_idx_off[ri];
            var vtx_base: u16 = 0;

            for (blade_angles) |angle| {
                const ca: f32 = @cos(angle);
                const sa: f32 = @sin(angle);
                for (blade_faces) |face| {
                    for (face.v) |v| {
                        const rx: f32 = v[0] * ca - v[1] * sa;
                        const ry: f32 = v[0] * sa + v[1] * ca;
                        std.mem.writeInt(u32, bin[po..][0..4], @bitCast(rx), .little);
                        std.mem.writeInt(u32, bin[po + 4 ..][0..4], @bitCast(ry), .little);
                        std.mem.writeInt(u32, bin[po + 8 ..][0..4], @bitCast(v[2]), .little);
                        po += 12;
                    }
                    for (0..4) |_| {
                        const rnx: f32 = face.nx * ca - face.ny * sa;
                        const rny: f32 = face.nx * sa + face.ny * ca;
                        std.mem.writeInt(u32, bin[no..][0..4], @bitCast(rnx), .little);
                        std.mem.writeInt(u32, bin[no + 4 ..][0..4], @bitCast(rny), .little);
                        std.mem.writeInt(u32, bin[no + 8 ..][0..4], @bitCast(face.nz), .little);
                        no += 12;
                    }
                    for (tuv) |uv| {
                        std.mem.writeInt(u32, bin[uo..][0..4], @bitCast(uv[0]), .little);
                        std.mem.writeInt(u32, bin[uo + 4 ..][0..4], @bitCast(uv[1]), .little);
                        uo += 8;
                    }
                }
                for (0..6) |fi| {
                    const base: u16 = vtx_base + @as(u16, @intCast(fi * 4));
                    for ([6]u16{ 0, 1, 2, 0, 2, 3 }) |o| {
                        std.mem.writeInt(u16, bin[io..][0..2], base + o, .little);
                        io += 2;
                    }
                }
                vtx_base += 24;
            }
        }
    }

    // ── JSON chunk ─────────────────────────────────────────────────────────────
    var json_aw: std.Io.Writer.Allocating = .init(alloc);
    defer json_aw.deinit();
    const w = &json_aw.writer;

    // Mesh index layout: 0=ground, 1..4=turbine0..3, 5..8=rotor0..3 (distinct)
    // Accessor index layout:
    //   ground: 0(pos),1(nrm),2(uv),3(idx)
    //   turbine0..3: 4..19 (4 per turbine)
    //   rotor0..3: 20..35 (4 per rotor: 20..23, 24..27, 28..31, 32..35)
    const r_acc_base: u32 = 4 + turbine_count * 4; // 20
    // BufferView index layout mirrors accessors:
    //   ground: 0..3, turbine0..3: 4..19, rotor0..3: 20..35
    const r_bv_base: u32 = 4 + turbine_count * 4; // 20

    try w.writeAll("{\"asset\":{\"version\":\"2.0\"},\"scene\":0,");
    // scene: root nodes = ground (0) + 4 turbine roots (1..4)
    try w.writeAll("\"scenes\":[{\"nodes\":[0,1,2,3,4]}],");

    // nodes: ground(0), turbine0..3(1..4) with children rotor0..3(5..8)
    // each rotorN node references its own distinct mesh (5+N)
    try w.writeAll("\"nodes\":[");
    try w.writeAll("{\"mesh\":0,\"name\":\"ground\"},");
    for (0..turbine_count) |ti| {
        const ri: u32 = @intCast(5 + ti);
        const tx = turbine_x[ti];
        try w.print("{{\"mesh\":{d},\"name\":\"turbine{d}\",\"translation\":[{d:.1},0.0,0.0],\"children\":[{d}]}},", .{ ti + 1, ti, tx, ri });
    }
    // rotor nodes — each references its own mesh so parser bakes its transform.
    // Translation is relative to the parent turbineN node (which is already at x=tx).
    // Local (0, 6.0, 0.3) places the hub at world (tx, 6.0, 0.3) — tower top + slight Z.
    for (0..turbine_count) |ti| {
        const rotor_mesh_idx: u32 = @intCast(5 + ti);
        if (ti < turbine_count - 1) {
            try w.print("{{\"mesh\":{d},\"name\":\"rotor{d}\",\"translation\":[0.0,6.0,0.3]}},", .{ rotor_mesh_idx, ti });
        } else {
            try w.print("{{\"mesh\":{d},\"name\":\"rotor{d}\",\"translation\":[0.0,6.0,0.3]}}", .{ rotor_mesh_idx, ti });
        }
    }
    try w.writeAll("],");

    // meshes: ground(0) + turbine0..3(1..4) + rotor0..3(5..8, distinct meshes)
    try w.writeAll("\"meshes\":[");
    try w.writeAll("{\"name\":\"ground\",\"primitives\":[{\"attributes\":{\"POSITION\":0,\"NORMAL\":1,\"TEXCOORD_0\":2},\"indices\":3,\"material\":0}]},");
    for (0..turbine_count) |ti| {
        const acc_base: u32 = @intCast(4 + ti * 4);
        try w.print("{{\"name\":\"turbine{d}\",\"primitives\":[{{\"attributes\":{{\"POSITION\":{d},\"NORMAL\":{d},\"TEXCOORD_0\":{d}}},\"indices\":{d},\"material\":0}}]}},", .{ ti, acc_base, acc_base + 1, acc_base + 2, acc_base + 3 });
    }
    // 4 distinct rotor meshes (same geometry, separate BIN sections)
    for (0..turbine_count) |ri| {
        const acc_base: u32 = r_acc_base + @as(u32, @intCast(ri)) * 4;
        if (ri < turbine_count - 1) {
            try w.print("{{\"name\":\"rotor{d}\",\"primitives\":[{{\"attributes\":{{\"POSITION\":{d},\"NORMAL\":{d},\"TEXCOORD_0\":{d}}},\"indices\":{d},\"material\":0}}]}},", .{ ri, acc_base, acc_base + 1, acc_base + 2, acc_base + 3 });
        } else {
            try w.print("{{\"name\":\"rotor{d}\",\"primitives\":[{{\"attributes\":{{\"POSITION\":{d},\"NORMAL\":{d},\"TEXCOORD_0\":{d}}},\"indices\":{d},\"material\":0}}]}}", .{ ri, acc_base, acc_base + 1, acc_base + 2, acc_base + 3 });
        }
    }
    try w.writeAll("],");

    // accessors: ground(0..3) + turbine0..3(4..19) + rotor0..3(20..35)
    try w.writeAll("\"accessors\":[");
    // ground accessors
    try w.print("{{\"bufferView\":0,\"componentType\":5126,\"count\":{d},\"type\":\"VEC3\"}},", .{g_vc});
    try w.print("{{\"bufferView\":1,\"componentType\":5126,\"count\":{d},\"type\":\"VEC3\"}},", .{g_vc});
    try w.print("{{\"bufferView\":2,\"componentType\":5126,\"count\":{d},\"type\":\"VEC2\"}},", .{g_vc});
    try w.print("{{\"bufferView\":3,\"componentType\":5123,\"count\":{d},\"type\":\"SCALAR\"}}", .{g_ic});
    // turbine accessors
    for (0..turbine_count) |ti| {
        const bv_base: u32 = @intCast(4 + ti * 4);
        try w.print(",{{\"bufferView\":{d},\"componentType\":5126,\"count\":{d},\"type\":\"VEC3\"}}", .{ bv_base, t_vc });
        try w.print(",{{\"bufferView\":{d},\"componentType\":5126,\"count\":{d},\"type\":\"VEC3\"}}", .{ bv_base + 1, t_vc });
        try w.print(",{{\"bufferView\":{d},\"componentType\":5126,\"count\":{d},\"type\":\"VEC2\"}}", .{ bv_base + 2, t_vc });
        try w.print(",{{\"bufferView\":{d},\"componentType\":5123,\"count\":{d},\"type\":\"SCALAR\"}}", .{ bv_base + 3, t_ic });
    }
    // rotor accessors (4 sets of 4)
    for (0..turbine_count) |ri| {
        const bv_base: u32 = r_bv_base + @as(u32, @intCast(ri)) * 4;
        try w.print(",{{\"bufferView\":{d},\"componentType\":5126,\"count\":{d},\"type\":\"VEC3\"}}", .{ bv_base, r_vc });
        try w.print(",{{\"bufferView\":{d},\"componentType\":5126,\"count\":{d},\"type\":\"VEC3\"}}", .{ bv_base + 1, r_vc });
        try w.print(",{{\"bufferView\":{d},\"componentType\":5126,\"count\":{d},\"type\":\"VEC2\"}}", .{ bv_base + 2, r_vc });
        try w.print(",{{\"bufferView\":{d},\"componentType\":5123,\"count\":{d},\"type\":\"SCALAR\"}}", .{ bv_base + 3, r_ic });
    }
    try w.writeAll("],");

    // bufferViews: ground(0..3) + turbine0..3(4..19) + rotor0..3(20..35)
    try w.writeAll("\"bufferViews\":[");
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ g_pos_off, g_pos_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ g_nrm_off, g_nrm_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ g_uv_off, g_uv_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d},\"target\":34963}}", .{ g_idx_off, g_idx_len });
    for (0..turbine_count) |ti| {
        try w.print(",{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}}", .{ t_pos_off[ti], t_pos_len });
        try w.print(",{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}}", .{ t_nrm_off[ti], t_nrm_len });
        try w.print(",{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}}", .{ t_uv_off[ti], t_uv_len });
        try w.print(",{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d},\"target\":34963}}", .{ t_idx_off[ti], t_idx_len });
    }
    // 4 rotor bufferView sets
    for (0..turbine_count) |ri| {
        try w.print(",{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}}", .{ r_pos_off[ri], r_pos_len });
        try w.print(",{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}}", .{ r_nrm_off[ri], r_nrm_len });
        try w.print(",{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}}", .{ r_uv_off[ri], r_uv_len });
        try w.print(",{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d},\"target\":34963}}", .{ r_idx_off[ri], r_idx_len });
    }
    try w.writeAll("],");

    try w.print("\"buffers\":[{{\"byteLength\":{d}}}],", .{bin_total});

    // One flat PBR material (no textures — parser white-bakes missing tex_base).
    try w.writeAll("\"materials\":[{\"pbrMetallicRoughness\":{\"baseColorFactor\":[0.85,0.88,0.90,1.0],\"metallicFactor\":0.1,\"roughnessFactor\":0.7}}]");
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

// ── windFarmGlb fixture tests ──────────────────────────────────────────────────

test "windFarmGlb: 4 named turbine submeshes + 4 rotor nodes, parses" {
    const glb = try windFarmGlb(testing.allocator);
    defer testing.allocator.free(glb);
    // GLB container invariants
    try testing.expectEqualSlices(u8, "glTF", glb[0..4]);
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, glb[4..8], .little));
    try testing.expectEqual(@as(u32, @intCast(glb.len)), std.mem.readInt(u32, glb[8..12], .little));
    // parse via gltf.zig — 4 turbine submeshes + 4 rotor submeshes in model.names
    const gltf = @import("gltf.zig");
    var model = try gltf.parseGlb(testing.allocator, glb);
    defer model.deinit();
    // model.names has 9 entries (ground + turbine0..3 + rotor0..3); 4 start with "turbine", 4 with "rotor"
    var turbines: usize = 0;
    var rotors_parsed: usize = 0;
    for (model.names) |n| {
        if (std.mem.startsWith(u8, n, "turbine")) turbines += 1;
        if (std.mem.startsWith(u8, n, "rotor")) rotors_parsed += 1;
    }
    try testing.expectEqual(@as(usize, 4), turbines);
    try testing.expectEqual(@as(usize, 4), rotors_parsed);
    // raw JSON parse for rotor nodes and hierarchy assertions
    const json_len_val = std.mem.readInt(u32, glb[12..16], .little);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, glb[20 .. 20 + json_len_val], .{});
    defer parsed.deinit();
    const nodes = parsed.value.object.get("nodes").?.array.items;
    // assert 4 rotor nodes exist
    var rotors: usize = 0;
    for (nodes) |n| {
        const name_val = n.object.get("name") orelse continue;
        if (name_val != .string) continue;
        if (std.mem.startsWith(u8, name_val.string, "rotor")) rotors += 1;
    }
    try testing.expectEqual(@as(usize, 4), rotors);
    // assert each rotor node has a mesh (blades under the rotor so rotationZ spins them)
    for (nodes) |n| {
        const name_val = n.object.get("name") orelse continue;
        if (name_val != .string) continue;
        if (!std.mem.startsWith(u8, name_val.string, "rotor")) continue;
        try testing.expect(n.object.get("mesh") != null);
    }
    // assert each turbine node's "children" includes its corresponding rotor node
    // Node layout: ground=0, turbine0=1..turbine3=4, rotor0=5..rotor3=8
    for (0..4) |ti| {
        const turbine_node = nodes[1 + ti];
        const children_val = turbine_node.object.get("children") orelse {
            return error.TurbineHasNoChildren;
        };
        const children = children_val.array.items;
        const expected_rotor_idx: i64 = @intCast(5 + ti);
        var found = false;
        for (children) |c| {
            if (c == .integer and c.integer == expected_rotor_idx) {
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }
}

// ── windFarmGlb pick-raycast tests ──────────────────────────────────────────
// Close the construction-only verification gap from the mission-control flagship
// (examples/mission-control FarmScene.raycastSubmesh + submeshTurbineId): the pick
// pipeline — rayFromCamera → bvh.walk over the baked windFarmGlb geometry →
// owning-submesh lookup → name→turbine-id — is exercised here against the real
// asset, built via the same parseGlb → bvh.build → vmesh.pack path gl_asset_gen
// runs at build time. The CDP harness can't drive a WebGL canvas pick (synthetic
// mouse bypasses the compositor hit-test), so this is the authoritative check
// that a click on a turbine resolves to the correct turbine id.

const bvh = @import("bvh.zig");
const ray = @import("ray.zig");
const math = @import("math.zig");
const vmesh = @import("vmesh.zig");
const gltf_mod = @import("gltf.zig");

// Mirror FarmScene.submeshTurbineId: "turbineN"/"rotorN" (N∈0..3) → N; else null.
fn windFarmTurbineId(nm: []const u8) ?u8 {
    const tail: ?[]const u8 =
        if (std.mem.startsWith(u8, nm, "turbine")) nm["turbine".len..] else if (std.mem.startsWith(u8, nm, "rotor")) nm["rotor".len..] else null;
    const t = tail orelse return null;
    if (t.len != 1 or t[0] < '0' or t[0] > '3') return null;
    return t[0] - '0';
}

// Mirror FarmScene.raycastSubmesh's hit→owning-submesh mapping, returning the
// submesh's name (null on miss). Operates on the pre-pack Model arrays, which are
// byte-identical to what vmesh.pack stores and the Reader exposes at runtime.
fn windFarmPickName(
    vertices: []const f32,
    indices: []const u16,
    submeshes: []const vmesh.Submesh,
    names: []const []const u8,
    nodes: []const bvh.Node,
    tri_perm: []const u32,
    r: ray.Ray,
) ?[]const u8 {
    const hit = bvh.walk(nodes, tri_perm, vertices, 12, indices, r) orelse return null;
    const first: u32 = hit.tri_index * 3;
    for (submeshes, 0..) |sub, s| {
        const start = sub.index_byte_off / 2;
        if (first >= start and first < start + sub.index_count) return names[s];
    }
    return null;
}

test "windFarmGlb pick: per-turbine center ray resolves to that turbine id" {
    const a = testing.allocator;
    const glb = try windFarmGlb(a);
    defer a.free(glb);
    var model = try gltf_mod.parseGlb(a, glb);
    defer model.deinit();
    var br = try bvh.build(a, model.vertices, 12, model.indices);
    defer br.deinit(a);

    // Towers: 0.5-wide/deep box, 6.0 tall, world x = -12/-4/+4/+12. Aim a center
    // ray (NDC 0,0 → forward) straight down −Z at mid-tower height (y=2, safely
    // inside [0,6]); only turbine k sits near x=tx (neighbours ≥8 units away), so
    // each ray can hit only its own turbine.
    const turbine_x = [4]f32{ -12, -4, 4, 12 };
    for (turbine_x, 0..) |tx, k| {
        const eye = math.Vec3.init(tx, 2, 25);
        const target = math.Vec3.init(tx, 2, 0);
        const r = ray.rayFromCamera(eye, target, math.Vec3.init(0, 1, 0), 1.0, 1.0, 0, 0);
        const nm = windFarmPickName(model.vertices, model.indices, model.submeshes, model.names, br.nodes, br.tri_perm, r) orelse return error.PickMissedTurbine;
        const id = windFarmTurbineId(nm) orelse return error.HitNonTurbine;
        try testing.expectEqual(@as(u8, @intCast(k)), id);
    }
}

test "windFarmGlb pick: ray into empty sky misses" {
    const a = testing.allocator;
    const glb = try windFarmGlb(a);
    defer a.free(glb);
    var model = try gltf_mod.parseGlb(a, glb);
    defer model.deinit();
    var br = try bvh.build(a, model.vertices, 12, model.indices);
    defer br.deinit(a);
    // Camera above the farm looking straight up — no geometry along +Y.
    const r = ray.rayFromCamera(math.Vec3.init(0, 50, 0), math.Vec3.init(0, 51, 0), math.Vec3.init(0, 0, 1), 1.0, 1.0, 0, 0);
    try testing.expect(windFarmPickName(model.vertices, model.indices, model.submeshes, model.names, br.nodes, br.tri_perm, r) == null);
}

test "windFarmGlb .vmesh asset exposes turbineN/rotorN names the pick maps on" {
    const a = testing.allocator;
    const glb = try windFarmGlb(a);
    defer a.free(glb);
    var model = try gltf_mod.parseGlb(a, glb);
    defer model.deinit();
    var br = try bvh.build(a, model.vertices, 12, model.indices);
    defer br.deinit(a);
    const bytes = try vmesh.pack(a, model.vertices, model.indices, model.submeshes, model.textures, br.nodes, br.tri_perm, model.names, model.skinned, model.joints, model.weights, model.skel, if (model.anim_clips.len == 0) null else vmesh.Anims{ .clips = model.anim_clips }, &.{}, 0, null);
    defer a.free(bytes);
    const reader = try vmesh.Reader.init(bytes);
    // Every turbine id 0..3 must be reachable from BOTH a turbine* and a rotor*
    // name in the packed asset the example actually loads (submeshTurbineId's domain).
    var turbine_seen = [_]bool{false} ** 4;
    var rotor_seen = [_]bool{false} ** 4;
    var s: u32 = 0;
    while (s < reader.submesh_count) : (s += 1) {
        const nm = reader.name(s);
        const id = windFarmTurbineId(nm) orelse continue;
        if (std.mem.startsWith(u8, nm, "turbine")) turbine_seen[id] = true;
        if (std.mem.startsWith(u8, nm, "rotor")) rotor_seen[id] = true;
    }
    for (turbine_seen) |seen| try testing.expect(seen);
    for (rotor_seen) |seen| try testing.expect(seen);
}

// ── double-sided material fixture ────────────────────────────────────────────

/// Minimal GLB that exercises per-submesh double-sided rendering.
///
/// Two meshes:
///  - mesh 0 "DoubleSided": an upright quad at the origin, face normal +Z.
///    Material: `alphaMode:"MASK"`, `alphaCutoff:0.5`, `doubleSided:true`.
///    Texture: an 8×8 checkerboard with every 4th column punched transparent.
///  - mesh 1 "Floor": a horizontal plane at y=-1.5. Material: opaque, single-
///    sided (default). 8×8 neutral-grey texture.
///  - mesh 2 "DoubleBlend": an upright quad offset +X, face normal +Z.
///    Material: `alphaMode:"BLEND"`, `doubleSided:true`, baseColorFactor alpha
///    0.5 (translucent) — exercises the two-pass back-then-front cull path.
///    Reuses the grey floor texture.
///
/// The fixture is intentionally lean (8×8 PNG blobs, 4 vertices per mesh) so
/// gl_asset_gen processes it quickly at build time.
pub fn pbrDoubleGlb(alloc: Allocator) ![]u8 {
    // ── 1. Textures ───────────────────────────────────────────────────────────
    // DS quad: 8×8 checkerboard, every 4th column (x%4==0) punched alpha=0.
    var ds_map: [8 * 8 * 4]u8 = undefined;
    for (0..8) |row| {
        for (0..8) |col| {
            const idx = (row * 8 + col) * 4;
            const warm = (row + col) % 2 == 0;
            ds_map[idx + 0] = if (warm) 220 else 60;
            ds_map[idx + 1] = if (warm) 100 else 160;
            ds_map[idx + 2] = if (warm) 60 else 220;
            ds_map[idx + 3] = if (col % 4 == 0) 0 else 255;
        }
    }
    // Floor: flat neutral grey, fully opaque.
    var fl_map: [8 * 8 * 4]u8 = undefined;
    for (&fl_map) |*b| b.* = 180;
    // Force alpha=255 for floor every 4th byte.
    var fi: usize = 3;
    while (fi < fl_map.len) : (fi += 4) fl_map[fi] = 255;

    const ds_png = try png.encodeRgba(alloc, &ds_map, 8, 8);
    defer alloc.free(ds_png);
    const fl_png = try png.encodeRgba(alloc, &fl_map, 8, 8);
    defer alloc.free(fl_png);

    const pngs = [2][]const u8{ ds_png, fl_png };

    // ── 2. BIN layout ────────────────────────────────────────────────────────
    // DS quad geometry (mesh 0), then Floor geometry (mesh 1), then the 2 PNGs.
    const ds_pos_off: u32 = 0;
    const ds_pos_len: u32 = 4 * 3 * 4; // 48
    const ds_nrm_off: u32 = ds_pos_off + ds_pos_len; // 48
    const ds_nrm_len: u32 = 48;
    const ds_uv_off: u32 = ds_nrm_off + ds_nrm_len; // 96
    const ds_uv_len: u32 = 4 * 2 * 4; // 32
    const ds_idx_off: u32 = ds_uv_off + ds_uv_len; // 128
    const ds_idx_len: u32 = 6 * 2; // 12
    // align to 4 → 144
    const fl_pos_off: u32 = (ds_idx_off + ds_idx_len + 3) & ~@as(u32, 3);
    const fl_pos_len: u32 = 48;
    const fl_nrm_off: u32 = fl_pos_off + fl_pos_len;
    const fl_nrm_len: u32 = 48;
    const fl_uv_off: u32 = fl_nrm_off + fl_nrm_len;
    const fl_uv_len: u32 = 32;
    const fl_idx_off: u32 = fl_uv_off + fl_uv_len;
    const fl_idx_len: u32 = 12;
    // DS BLEND card (mesh 2), aligned to 4 after the floor indices.
    const bl_pos_off: u32 = (fl_idx_off + fl_idx_len + 3) & ~@as(u32, 3);
    const bl_pos_len: u32 = 48;
    const bl_nrm_off: u32 = bl_pos_off + bl_pos_len;
    const bl_nrm_len: u32 = 48;
    const bl_uv_off: u32 = bl_nrm_off + bl_nrm_len;
    const bl_uv_len: u32 = 32;
    const bl_idx_off: u32 = bl_uv_off + bl_uv_len;
    const bl_idx_len: u32 = 12;

    var png_offs: [2]u32 = undefined;
    var cursor: u32 = (bl_idx_off + bl_idx_len + 3) & ~@as(u32, 3);
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

    // DS quad: upright at origin, face normal +Z.
    {
        const pos = [4][3]f32{
            .{ -1.5, -1.5, 0 },
            .{ 1.5, -1.5, 0 },
            .{ 1.5, 1.5, 0 },
            .{ -1.5, 1.5, 0 },
        };
        var o: usize = ds_pos_off;
        for (pos) |v| {
            std.mem.writeInt(u32, bin[o..][0..4], @bitCast(v[0]), .little);
            std.mem.writeInt(u32, bin[o + 4 ..][0..4], @bitCast(v[1]), .little);
            std.mem.writeInt(u32, bin[o + 8 ..][0..4], @bitCast(v[2]), .little);
            o += 12;
        }
        // Normals: all (0,0,1)
        o = ds_nrm_off;
        for (0..4) |_| {
            std.mem.writeInt(u32, bin[o..][0..4], @bitCast(@as(f32, 0)), .little);
            std.mem.writeInt(u32, bin[o + 4 ..][0..4], @bitCast(@as(f32, 0)), .little);
            std.mem.writeInt(u32, bin[o + 8 ..][0..4], @bitCast(@as(f32, 1)), .little);
            o += 12;
        }
        // UVs: bottom-left origin (glTF convention)
        const uvs = [4][2]f32{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } };
        o = ds_uv_off;
        for (uvs) |uv| {
            std.mem.writeInt(u32, bin[o..][0..4], @bitCast(uv[0]), .little);
            std.mem.writeInt(u32, bin[o + 4 ..][0..4], @bitCast(uv[1]), .little);
            o += 8;
        }
        // Indices: CCW from front (+Z side)
        o = ds_idx_off;
        for ([6]u16{ 0, 1, 2, 0, 2, 3 }) |idx| {
            std.mem.writeInt(u16, bin[o..][0..2], idx, .little);
            o += 2;
        }
    }

    // Floor: horizontal plane at y=-1.5.
    {
        const pos = [4][3]f32{
            .{ -4, -1.5, -4 },
            .{ 4, -1.5, -4 },
            .{ 4, -1.5, 4 },
            .{ -4, -1.5, 4 },
        };
        var o: usize = fl_pos_off;
        for (pos) |v| {
            std.mem.writeInt(u32, bin[o..][0..4], @bitCast(v[0]), .little);
            std.mem.writeInt(u32, bin[o + 4 ..][0..4], @bitCast(v[1]), .little);
            std.mem.writeInt(u32, bin[o + 8 ..][0..4], @bitCast(v[2]), .little);
            o += 12;
        }
        // Normals: all (0,1,0)
        o = fl_nrm_off;
        for (0..4) |_| {
            std.mem.writeInt(u32, bin[o..][0..4], @bitCast(@as(f32, 0)), .little);
            std.mem.writeInt(u32, bin[o + 4 ..][0..4], @bitCast(@as(f32, 1)), .little);
            std.mem.writeInt(u32, bin[o + 8 ..][0..4], @bitCast(@as(f32, 0)), .little);
            o += 12;
        }
        const uvs = [4][2]f32{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 2 }, .{ 0, 2 } };
        o = fl_uv_off;
        for (uvs) |uv| {
            std.mem.writeInt(u32, bin[o..][0..4], @bitCast(uv[0]), .little);
            std.mem.writeInt(u32, bin[o + 4 ..][0..4], @bitCast(uv[1]), .little);
            o += 8;
        }
        o = fl_idx_off;
        for ([6]u16{ 0, 2, 1, 0, 3, 2 }) |idx| {
            std.mem.writeInt(u16, bin[o..][0..2], idx, .little);
            o += 2;
        }
    }

    // DS BLEND card: upright quad offset +X (beside the MASK quad), face normal +Z.
    {
        const pos = [4][3]f32{
            .{ 2.5, -1.5, 0 },
            .{ 5.5, -1.5, 0 },
            .{ 5.5, 1.5, 0 },
            .{ 2.5, 1.5, 0 },
        };
        var o: usize = bl_pos_off;
        for (pos) |v| {
            std.mem.writeInt(u32, bin[o..][0..4], @bitCast(v[0]), .little);
            std.mem.writeInt(u32, bin[o + 4 ..][0..4], @bitCast(v[1]), .little);
            std.mem.writeInt(u32, bin[o + 8 ..][0..4], @bitCast(v[2]), .little);
            o += 12;
        }
        // Normals: all (0,0,1)
        o = bl_nrm_off;
        for (0..4) |_| {
            std.mem.writeInt(u32, bin[o..][0..4], @bitCast(@as(f32, 0)), .little);
            std.mem.writeInt(u32, bin[o + 4 ..][0..4], @bitCast(@as(f32, 0)), .little);
            std.mem.writeInt(u32, bin[o + 8 ..][0..4], @bitCast(@as(f32, 1)), .little);
            o += 12;
        }
        const uvs = [4][2]f32{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } };
        o = bl_uv_off;
        for (uvs) |uv| {
            std.mem.writeInt(u32, bin[o..][0..4], @bitCast(uv[0]), .little);
            std.mem.writeInt(u32, bin[o + 4 ..][0..4], @bitCast(uv[1]), .little);
            o += 8;
        }
        // Indices: CCW from front (+Z side)
        o = bl_idx_off;
        for ([6]u16{ 0, 1, 2, 0, 2, 3 }) |idx| {
            std.mem.writeInt(u16, bin[o..][0..2], idx, .little);
            o += 2;
        }
    }

    for (pngs, 0..) |p, i| {
        @memcpy(bin[png_offs[i]..][0..p.len], p);
    }

    // ── 3. JSON ────────────────────────────────────────────────────────────────
    var json_aw: std.Io.Writer.Allocating = .init(alloc);
    defer json_aw.deinit();
    const w = &json_aw.writer;

    // accessors: DS 0=POS 1=NRM 2=UV 3=idx; Floor 4=POS 5=NRM 6=UV 7=idx;
    // BLEND card 8=POS 9=NRM 10=UV 11=idx.
    // bufferViews: 12 geom + 2 PNG.
    const bv_count_geom: u32 = 12;

    try w.writeAll("{");
    try w.writeAll("\"asset\":{\"version\":\"2.0\"},");
    try w.writeAll("\"scene\":0,");
    try w.writeAll("\"scenes\":[{\"nodes\":[0,1,2]}],");
    try w.writeAll("\"nodes\":[{\"mesh\":0,\"name\":\"DsNode\"},{\"mesh\":1,\"name\":\"FloorNode\"},{\"mesh\":2,\"name\":\"BlendNode\"}],");
    try w.writeAll("\"meshes\":[");
    try w.writeAll("{\"name\":\"DoubleSided\",\"primitives\":[{\"attributes\":{");
    try w.writeAll("\"POSITION\":0,\"NORMAL\":1,\"TEXCOORD_0\":2");
    try w.writeAll("},\"indices\":3,\"material\":0}]},");
    try w.writeAll("{\"name\":\"Floor\",\"primitives\":[{\"attributes\":{");
    try w.writeAll("\"POSITION\":4,\"NORMAL\":5,\"TEXCOORD_0\":6");
    try w.writeAll("},\"indices\":7,\"material\":1}]},");
    try w.writeAll("{\"name\":\"DoubleBlend\",\"primitives\":[{\"attributes\":{");
    try w.writeAll("\"POSITION\":8,\"NORMAL\":9,\"TEXCOORD_0\":10");
    try w.writeAll("},\"indices\":11,\"material\":2}]}");
    try w.writeAll("],");

    try w.writeAll("\"accessors\":[");
    try w.print("{{\"bufferView\":0,\"byteOffset\":0,\"componentType\":5126,\"count\":4,\"type\":\"VEC3\",\"min\":[-1.5,-1.5,0.0],\"max\":[1.5,1.5,0.0]}},", .{});
    try w.writeAll("{\"bufferView\":1,\"byteOffset\":0,\"componentType\":5126,\"count\":4,\"type\":\"VEC3\"},");
    try w.writeAll("{\"bufferView\":2,\"byteOffset\":0,\"componentType\":5126,\"count\":4,\"type\":\"VEC2\"},");
    try w.writeAll("{\"bufferView\":3,\"byteOffset\":0,\"componentType\":5123,\"count\":6,\"type\":\"SCALAR\"},");
    try w.print("{{\"bufferView\":4,\"byteOffset\":0,\"componentType\":5126,\"count\":4,\"type\":\"VEC3\",\"min\":[-4.0,-1.5,-4.0],\"max\":[4.0,-1.5,4.0]}},", .{});
    try w.writeAll("{\"bufferView\":5,\"byteOffset\":0,\"componentType\":5126,\"count\":4,\"type\":\"VEC3\"},");
    try w.writeAll("{\"bufferView\":6,\"byteOffset\":0,\"componentType\":5126,\"count\":4,\"type\":\"VEC2\"},");
    try w.writeAll("{\"bufferView\":7,\"byteOffset\":0,\"componentType\":5123,\"count\":6,\"type\":\"SCALAR\"},");
    try w.print("{{\"bufferView\":8,\"byteOffset\":0,\"componentType\":5126,\"count\":4,\"type\":\"VEC3\",\"min\":[2.5,-1.5,0.0],\"max\":[5.5,1.5,0.0]}},", .{});
    try w.writeAll("{\"bufferView\":9,\"byteOffset\":0,\"componentType\":5126,\"count\":4,\"type\":\"VEC3\"},");
    try w.writeAll("{\"bufferView\":10,\"byteOffset\":0,\"componentType\":5126,\"count\":4,\"type\":\"VEC2\"},");
    try w.writeAll("{\"bufferView\":11,\"byteOffset\":0,\"componentType\":5123,\"count\":6,\"type\":\"SCALAR\"}");
    try w.writeAll("],");

    try w.writeAll("\"bufferViews\":[");
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ ds_pos_off, ds_pos_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ ds_nrm_off, ds_nrm_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ ds_uv_off, ds_uv_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d},\"target\":34963}},", .{ ds_idx_off, ds_idx_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ fl_pos_off, fl_pos_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ fl_nrm_off, fl_nrm_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ fl_uv_off, fl_uv_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d},\"target\":34963}},", .{ fl_idx_off, fl_idx_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ bl_pos_off, bl_pos_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ bl_nrm_off, bl_nrm_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ bl_uv_off, bl_uv_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d},\"target\":34963}},", .{ bl_idx_off, bl_idx_len });
    for (pngs, 0..) |p, i| {
        try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}}", .{ png_offs[i], p.len });
        if (i + 1 < pngs.len) try w.writeAll(",");
    }
    try w.writeAll("],");

    try w.print("\"buffers\":[{{\"byteLength\":{d}}}],", .{bin_total});

    // material 0: MASK double-sided quad.
    // material 1: OPAQUE floor (single-sided, default cull-back).
    // material 2: BLEND double-sided card (translucent, two-pass back/front).
    try w.writeAll("\"materials\":[{");
    try w.writeAll("\"pbrMetallicRoughness\":{");
    try w.writeAll("\"baseColorFactor\":[1.0,1.0,1.0,1.0],");
    try w.writeAll("\"baseColorTexture\":{\"index\":0},");
    try w.writeAll("\"metallicFactor\":0.0,\"roughnessFactor\":0.8");
    try w.writeAll("},");
    try w.writeAll("\"alphaMode\":\"MASK\",\"alphaCutoff\":0.5,\"doubleSided\":true");
    try w.writeAll("},{");
    try w.writeAll("\"pbrMetallicRoughness\":{\"baseColorFactor\":[1.0,1.0,1.0,1.0],");
    try w.writeAll("\"baseColorTexture\":{\"index\":1},\"metallicFactor\":0.0,\"roughnessFactor\":1.0}");
    try w.writeAll("},{");
    try w.writeAll("\"pbrMetallicRoughness\":{");
    try w.writeAll("\"baseColorFactor\":[0.4,0.7,1.0,0.5],");
    try w.writeAll("\"baseColorTexture\":{\"index\":1},");
    try w.writeAll("\"metallicFactor\":0.0,\"roughnessFactor\":0.5");
    try w.writeAll("},");
    try w.writeAll("\"alphaMode\":\"BLEND\",\"doubleSided\":true");
    try w.writeAll("}],");

    try w.writeAll("\"textures\":[");
    for (0..2) |i| {
        try w.print("{{\"source\":{d}}}", .{i});
        if (i + 1 < 2) try w.writeAll(",");
    }
    try w.writeAll("],");

    try w.writeAll("\"images\":[");
    for (0..2) |i| {
        try w.print("{{\"bufferView\":{d},\"mimeType\":\"image/png\"}}", .{bv_count_geom + @as(u32, @intCast(i))});
        if (i + 1 < 2) try w.writeAll(",");
    }
    try w.writeAll("]");
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

// ── pbrDoubleGlb fixture tests ────────────────────────────────────────────────

test "pbrDoubleGlb: double-sided MASK quad round-trips through gltf parse" {
    const glb = try pbrDoubleGlb(testing.allocator);
    defer testing.allocator.free(glb);
    var model = try gltf_mod.parseGlb(testing.allocator, glb);
    defer model.deinit();
    try testing.expect(model.submeshes.len >= 1);
    // Submesh 0 is "DoubleSided": alphaMode "MASK" → alpha_mode == 2, doubleSided:true → double_sided == 1.
    try testing.expectEqual(@as(u32, 2), model.submeshes[0].alpha_mode);
    try testing.expectEqual(@as(u32, 1), model.submeshes[0].double_sided);
    // Submesh name is "DoubleSided".
    try testing.expect(model.names.len >= 1);
    try testing.expectEqualStrings("DoubleSided", model.names[0]);
    // Submesh 2 is "DoubleBlend": alphaMode "BLEND" → alpha_mode == 1, doubleSided:true → double_sided == 1.
    try testing.expect(model.submeshes.len >= 3);
    try testing.expectEqual(@as(u32, 1), model.submeshes[2].alpha_mode);
    try testing.expectEqual(@as(u32, 1), model.submeshes[2].double_sided);
    try testing.expectEqualStrings("DoubleBlend", model.names[2]);
}

// ── 7×7 cube-grid fixture (frustum-cull demo) ────────────────────────────────

/// 7×7 grid of 49 unit cubes sharing a single BIN geometry block.
/// Each cube is its own glTF mesh+node; distinctness comes from each node's
/// `translation` ([col*spacing - center, 0, row*spacing - center]).  All 49
/// meshes reference the SAME 4 geometry bufferViews (POSITION / NORMAL /
/// TEXCOORD_0 / indices), so the BIN is tiny.  One shared opaque material.
/// Named `Cube_r{R}_c{C}` for R,C in 0..6.
pub fn cubeGridGlb(alloc: Allocator) ![]u8 {
    const GRID_W: u32 = 7;
    const GRID_N: u32 = GRID_W * GRID_W; // 49
    const spacing: f32 = 3.0;
    const center: f32 = @as(f32, @floatFromInt(GRID_W - 1)) * spacing * 0.5; // 9.0

    // ── 1. Shared base-colour texture (8×8 checkerboard) ─────────────────────
    var checker: [8 * 8 * 4]u8 = undefined;
    for (0..8) |row| {
        for (0..8) |col| {
            const idx = (row * 8 + col) * 4;
            const light = (row + col) % 2 == 0;
            checker[idx + 0] = if (light) @as(u8, 180) else 60;
            checker[idx + 1] = if (light) @as(u8, 200) else 80;
            checker[idx + 2] = if (light) @as(u8, 240) else 160;
            checker[idx + 3] = 255;
        }
    }
    const tex_png = try png.encodeRgba(alloc, &checker, 8, 8);
    defer alloc.free(tex_png);

    // ── 2. BIN layout — shared geometry + PNG ────────────────────────────────
    // Re-use the top-level bv_* constants: pos@0, nrm@288, uv@576, idx@768.
    // PNG immediately after index data (at bv_png_off = 840).
    const png_len: u32 = @intCast(tex_png.len);
    const bin_total: u32 = bv_png_off + png_len;
    const bin_padded: u32 = (bin_total + 3) & ~@as(u32, 3);

    var bin = try alloc.alloc(u8, bin_padded);
    defer alloc.free(bin);
    @memset(bin, 0);

    // POSITION (same as texturedCubeGlb)
    {
        var o: usize = bv_pos_off;
        for (faces) |face| {
            for (face.v) |v| {
                std.mem.writeInt(u32, bin[o..][0..4], @bitCast(v[0]), .little);
                std.mem.writeInt(u32, bin[o + 4 ..][0..4], @bitCast(v[1]), .little);
                std.mem.writeInt(u32, bin[o + 8 ..][0..4], @bitCast(v[2]), .little);
                o += 12;
            }
        }
    }
    // NORMAL
    {
        var o: usize = bv_nrm_off;
        for (faces) |face| {
            for (0..4) |_| {
                std.mem.writeInt(u32, bin[o..][0..4], @bitCast(face.nx), .little);
                std.mem.writeInt(u32, bin[o + 4 ..][0..4], @bitCast(face.ny), .little);
                std.mem.writeInt(u32, bin[o + 8 ..][0..4], @bitCast(face.nz), .little);
                o += 12;
            }
        }
    }
    // TEXCOORD_0
    {
        var o: usize = bv_uv_off;
        for (faces) |_| {
            for (face_uvs) |uv| {
                std.mem.writeInt(u32, bin[o..][0..4], @bitCast(uv[0]), .little);
                std.mem.writeInt(u32, bin[o + 4 ..][0..4], @bitCast(uv[1]), .little);
                o += 8;
            }
        }
    }
    // indices: 6 faces × 2 triangles = 12 triangles, 36 u16
    {
        var o: usize = bv_idx_off;
        for (0..6) |fi| {
            const base: u16 = @intCast(fi * 4);
            for ([6]u16{ 0, 1, 2, 0, 2, 3 }) |v| {
                std.mem.writeInt(u16, bin[o..][0..2], base + v, .little);
                o += 2;
            }
        }
    }
    // PNG
    @memcpy(bin[bv_png_off..][0..tex_png.len], tex_png);

    // ── 3. JSON ───────────────────────────────────────────────────────────────
    // Layout:
    //   accessors  [0]=POS [1]=NRM [2]=UV [3]=IDX  (4 total, shared by all meshes)
    //   bufferViews[0]=pos [1]=nrm [2]=uv [3]=idx [4]=png  (5 total)
    //   meshes     [0..48]: each "Cube_r{R}_c{C}" primitive → acc 0/1/2/3 / mat 0
    //   nodes      [0..48]: each {mesh:i, name:"Cube_r{R}_c{C}", translation:[x,0,z]}
    //   scenes     [{nodes:[0..48]}]
    //   materials  [0]: opaque, single-sided, shared base-colour texture
    //   textures   [0]
    //   images     [0]

    var json_aw: std.Io.Writer.Allocating = .init(alloc);
    defer json_aw.deinit();
    const w = &json_aw.writer;

    const bv_png_idx: u32 = 4; // bufferView index for the PNG

    try w.writeAll("{");
    try w.writeAll("\"asset\":{\"version\":\"2.0\"},");
    try w.writeAll("\"scene\":0,");

    // scene nodes array: [0,1,...,48]
    try w.writeAll("\"scenes\":[{\"nodes\":[");
    for (0..GRID_N) |i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{d}", .{i});
    }
    try w.writeAll("]}],");

    // nodes: each has mesh + name + translation
    try w.writeAll("\"nodes\":[");
    for (0..GRID_N) |i| {
        const row: u32 = @intCast(i / GRID_W);
        const col: u32 = @intCast(i % GRID_W);
        const tx: f32 = @as(f32, @floatFromInt(col)) * spacing - center;
        const tz: f32 = @as(f32, @floatFromInt(row)) * spacing - center;
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"mesh\":{d},\"name\":\"Cube_r{d}_c{d}\",\"translation\":[{d:.4},{d:.4},{d:.4}]}}", .{ i, row, col, tx, @as(f32, 0.0), tz });
    }
    try w.writeAll("],");

    // meshes: all reference the SAME 4 accessors (0=POS,1=NRM,2=UV,3=IDX)
    try w.writeAll("\"meshes\":[");
    for (0..GRID_N) |i| {
        const row: u32 = @intCast(i / GRID_W);
        const col: u32 = @intCast(i % GRID_W);
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"name\":\"Cube_r{d}_c{d}\",\"primitives\":[{{\"attributes\":{{\"POSITION\":0,\"NORMAL\":1,\"TEXCOORD_0\":2}},\"indices\":3,\"material\":0}}]}}", .{ row, col });
    }
    try w.writeAll("],");

    // 4 shared accessors
    try w.writeAll("\"accessors\":[");
    try w.writeAll("{\"bufferView\":0,\"byteOffset\":0,\"componentType\":5126,\"count\":24,\"type\":\"VEC3\",\"min\":[-1.0,-1.0,-1.0],\"max\":[1.0,1.0,1.0]},");
    try w.writeAll("{\"bufferView\":1,\"byteOffset\":0,\"componentType\":5126,\"count\":24,\"type\":\"VEC3\"},");
    try w.writeAll("{\"bufferView\":2,\"byteOffset\":0,\"componentType\":5126,\"count\":24,\"type\":\"VEC2\"},");
    try w.writeAll("{\"bufferView\":3,\"byteOffset\":0,\"componentType\":5123,\"count\":36,\"type\":\"SCALAR\"}");
    try w.writeAll("],");

    // 5 bufferViews (4 geom + 1 png)
    try w.writeAll("\"bufferViews\":[");
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ bv_pos_off, bv_pos_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ bv_nrm_off, bv_nrm_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ bv_uv_off, bv_uv_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d},\"target\":34963}},", .{ bv_idx_off, bv_idx_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}}", .{ bv_png_off, png_len });
    try w.writeAll("],");

    try w.print("\"buffers\":[{{\"byteLength\":{d}}}],", .{bin_total});

    // 1 shared material: opaque, single-sided
    try w.writeAll("\"materials\":[{\"pbrMetallicRoughness\":{");
    try w.writeAll("\"baseColorTexture\":{\"index\":0},");
    try w.writeAll("\"baseColorFactor\":[1.0,1.0,1.0,1.0],");
    try w.writeAll("\"metallicFactor\":0.0,\"roughnessFactor\":0.8");
    try w.writeAll("}}],");

    try w.writeAll("\"textures\":[{\"source\":0}],");
    try w.print("\"images\":[{{\"bufferView\":{d},\"mimeType\":\"image/png\"}}]", .{bv_png_idx});
    try w.writeAll("}");

    // pad JSON to 4-byte alignment
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

// ── cubeGridGlb fixture tests ─────────────────────────────────────────────────

test "cubeGridGlb: N-cube grid round-trips with unique names + distinct positions" {
    const glb = try cubeGridGlb(testing.allocator);
    defer testing.allocator.free(glb);
    var model = try gltf_mod.parseGlb(testing.allocator, glb);
    defer model.deinit();
    // 7x7 = 49 cube submeshes.
    try testing.expectEqual(@as(usize, 49), model.submeshes.len);
    try testing.expectEqual(@as(usize, 49), model.names.len);
    // Names are unique (first != last) and follow the Cube_r{R}_c{C} convention.
    try testing.expect(!std.mem.eql(u8, model.names[0], model.names[48]));
    try testing.expect(std.mem.startsWith(u8, model.names[0], "Cube_r"));
}

// ── cubeFieldGlb fixture (GPU instancing demo) ───────────────────────────────

/// 16×16 = 256 instances of a single unit cube, encoded via EXT_mesh_gpu_instancing.
/// One mesh + one node with the extension. Each instance has:
///   TRANSLATION : grid (spacing 2.5, centered at origin)
///   ROTATION    : small per-instance yaw quaternion
///   SCALE       : uniform 0.4
///   _COLOR_0    : hue-varied palette (red→green→blue cycle by index)
///
/// Accessors layout in BIN (after geom + PNG):
///   [inst_trans_off]  256 × VEC3  f32  (TRANSLATION)
///   [inst_rot_off]    256 × VEC4  f32  (ROTATION xyzw)
///   [inst_scale_off]  256 × VEC3  f32  (SCALE)
///   [inst_color_off]  256 × VEC4  f32  (_COLOR_0)
pub fn cubeFieldGlb(alloc: Allocator) ![]u8 {
    const INST_COUNT: u32 = 256; // 16×16 grid
    const GRID_W: u32 = 16;
    const spacing: f32 = 2.5;
    const center: f32 = @as(f32, @floatFromInt(GRID_W - 1)) * spacing * 0.5; // 18.75

    // ── 1. Shared base-colour texture (8×8 checkerboard, reuse BIN constants) ──
    var checker = [_]u8{0} ** (8 * 8 * 4);
    for (0..8) |row| {
        for (0..8) |col| {
            const idx = (row * 8 + col) * 4;
            const light = (row + col) % 2 == 0;
            checker[idx + 0] = if (light) @as(u8, 220) else 60;
            checker[idx + 1] = if (light) @as(u8, 200) else 80;
            checker[idx + 2] = if (light) @as(u8, 240) else 160;
            checker[idx + 3] = 255;
        }
    }
    const tex_png = try png.encodeRgba(alloc, &checker, 8, 8);
    defer alloc.free(tex_png);

    // ── 2. BIN layout ─────────────────────────────────────────────────────────
    // Geom section: pos@0, nrm@288, uv@576, idx@768. PNG at bv_png_off=840.
    // Instance accessors start after PNG, 4-byte aligned.
    const png_len: u32 = @intCast(tex_png.len);
    const inst_trans_off: u32 = (bv_png_off + png_len + 3) & ~@as(u32, 3);
    const inst_trans_len: u32 = INST_COUNT * 3 * 4; // 256 × VEC3 f32
    const inst_rot_off: u32 = inst_trans_off + inst_trans_len;
    const inst_rot_len: u32 = INST_COUNT * 4 * 4; // 256 × VEC4 f32
    const inst_scale_off: u32 = inst_rot_off + inst_rot_len;
    const inst_scale_len: u32 = INST_COUNT * 3 * 4; // 256 × VEC3 f32
    const inst_color_off: u32 = inst_scale_off + inst_scale_len;
    const inst_color_len: u32 = INST_COUNT * 4 * 4; // 256 × VEC4 f32
    const bin_total: u32 = inst_color_off + inst_color_len;
    const bin_padded: u32 = (bin_total + 3) & ~@as(u32, 3);

    var bin = try alloc.alloc(u8, bin_padded);
    defer alloc.free(bin);
    @memset(bin, 0);

    // POSITION (shared 24-vertex cube, same as texturedCubeGlb)
    {
        var o: usize = bv_pos_off;
        for (faces) |face| {
            for (face.v) |v| {
                std.mem.writeInt(u32, bin[o..][0..4], @bitCast(v[0]), .little);
                std.mem.writeInt(u32, bin[o + 4 ..][0..4], @bitCast(v[1]), .little);
                std.mem.writeInt(u32, bin[o + 8 ..][0..4], @bitCast(v[2]), .little);
                o += 12;
            }
        }
    }
    // NORMAL
    {
        var o: usize = bv_nrm_off;
        for (faces) |face| {
            for (0..4) |_| {
                std.mem.writeInt(u32, bin[o..][0..4], @bitCast(face.nx), .little);
                std.mem.writeInt(u32, bin[o + 4 ..][0..4], @bitCast(face.ny), .little);
                std.mem.writeInt(u32, bin[o + 8 ..][0..4], @bitCast(face.nz), .little);
                o += 12;
            }
        }
    }
    // TEXCOORD_0
    {
        var o: usize = bv_uv_off;
        for (faces) |_| {
            for (face_uvs) |uv| {
                std.mem.writeInt(u32, bin[o..][0..4], @bitCast(uv[0]), .little);
                std.mem.writeInt(u32, bin[o + 4 ..][0..4], @bitCast(uv[1]), .little);
                o += 8;
            }
        }
    }
    // indices: 6 faces × 6 indices = 36 u16
    {
        var o: usize = bv_idx_off;
        for (0..6) |fi| {
            const base: u16 = @intCast(fi * 4);
            for ([6]u16{ 0, 1, 2, 0, 2, 3 }) |v| {
                std.mem.writeInt(u16, bin[o..][0..2], base + v, .little);
                o += 2;
            }
        }
    }
    // PNG
    @memcpy(bin[bv_png_off..][0..tex_png.len], tex_png);

    // TRANSLATION: 16×16 grid, spacing 2.5, y=0
    {
        var o: usize = inst_trans_off;
        for (0..INST_COUNT) |i| {
            const row: u32 = @intCast(i / GRID_W);
            const col: u32 = @intCast(i % GRID_W);
            const tx: f32 = @as(f32, @floatFromInt(col)) * spacing - center;
            const tz: f32 = @as(f32, @floatFromInt(row)) * spacing - center;
            std.mem.writeInt(u32, bin[o..][0..4], @bitCast(tx), .little);
            std.mem.writeInt(u32, bin[o + 4 ..][0..4], @bitCast(@as(f32, 0.0)), .little);
            std.mem.writeInt(u32, bin[o + 8 ..][0..4], @bitCast(tz), .little);
            o += 12;
        }
    }
    // ROTATION: small per-instance yaw quaternion (axis=+Y, angle = i * 0.15 rad)
    {
        var o: usize = inst_rot_off;
        for (0..INST_COUNT) |i| {
            const angle: f32 = @as(f32, @floatFromInt(i)) * 0.15;
            const half: f32 = angle * 0.5;
            const s: f32 = @sin(half);
            const c: f32 = @cos(half);
            // xyzw: x=0, y=sin(half), z=0, w=cos(half)
            std.mem.writeInt(u32, bin[o..][0..4], @bitCast(@as(f32, 0.0)), .little);
            std.mem.writeInt(u32, bin[o + 4 ..][0..4], @bitCast(s), .little);
            std.mem.writeInt(u32, bin[o + 8 ..][0..4], @bitCast(@as(f32, 0.0)), .little);
            std.mem.writeInt(u32, bin[o + 12 ..][0..4], @bitCast(c), .little);
            o += 16;
        }
    }
    // SCALE: uniform 0.4 for all instances
    {
        var o: usize = inst_scale_off;
        for (0..INST_COUNT) |_| {
            std.mem.writeInt(u32, bin[o..][0..4], @bitCast(@as(f32, 0.4)), .little);
            std.mem.writeInt(u32, bin[o + 4 ..][0..4], @bitCast(@as(f32, 0.4)), .little);
            std.mem.writeInt(u32, bin[o + 8 ..][0..4], @bitCast(@as(f32, 0.4)), .little);
            o += 12;
        }
    }
    // _COLOR_0: hue-varied palette cycling red→green→blue by index
    {
        var o: usize = inst_color_off;
        for (0..INST_COUNT) |i| {
            // 3-segment hue cycle: first 86 → red→green, next 86 → green→blue, rest → blue→red
            const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(INST_COUNT));
            const h: f32 = t * 3.0; // 0..3
            const seg: u32 = @intFromFloat(@floor(h));
            const f: f32 = h - @floor(h);
            var r: f32 = 0.0;
            var g: f32 = 0.0;
            var bv: f32 = 0.0;
            switch (seg % 3) {
                0 => {
                    r = 1.0 - f;
                    g = f;
                    bv = 0.2;
                },
                1 => {
                    r = 0.2;
                    g = 1.0 - f;
                    bv = f;
                },
                else => {
                    r = f;
                    g = 0.2;
                    bv = 1.0 - f;
                },
            }
            std.mem.writeInt(u32, bin[o..][0..4], @bitCast(r), .little);
            std.mem.writeInt(u32, bin[o + 4 ..][0..4], @bitCast(g), .little);
            std.mem.writeInt(u32, bin[o + 8 ..][0..4], @bitCast(bv), .little);
            std.mem.writeInt(u32, bin[o + 12 ..][0..4], @bitCast(@as(f32, 1.0)), .little);
            o += 16;
        }
    }

    // ── 3. JSON ────────────────────────────────────────────────────────────────
    // Accessor indices:
    //   0=POS  1=NRM  2=UV  3=IDX  4=TRANS  5=ROT  6=SCALE  7=COLOR
    // BufferView indices:
    //   0=pos  1=nrm  2=uv  3=idx  4=png  5=trans  6=rot  7=scale  8=color
    var json_aw: std.Io.Writer.Allocating = .init(alloc);
    defer json_aw.deinit();
    const w = &json_aw.writer;

    try w.writeAll("{");
    try w.writeAll("\"asset\":{\"version\":\"2.0\"},");
    try w.writeAll("\"extensionsUsed\":[\"EXT_mesh_gpu_instancing\"],");
    try w.writeAll("\"scene\":0,");
    try w.writeAll("\"scenes\":[{\"nodes\":[0]}],");

    // Single node with EXT_mesh_gpu_instancing
    try w.writeAll("\"nodes\":[{\"mesh\":0,\"name\":\"CubeField\",");
    try w.writeAll("\"extensions\":{\"EXT_mesh_gpu_instancing\":{\"attributes\":{");
    try w.writeAll("\"TRANSLATION\":4,\"ROTATION\":5,\"SCALE\":6,\"_COLOR_0\":7");
    try w.writeAll("}}}}],");

    // Single mesh
    try w.writeAll("\"meshes\":[{\"name\":\"CubeFieldMesh\",\"primitives\":[{");
    try w.writeAll("\"attributes\":{\"POSITION\":0,\"NORMAL\":1,\"TEXCOORD_0\":2},");
    try w.writeAll("\"indices\":3,\"material\":0}]}],");

    // 8 accessors: geom (0-3) + instance (4-7)
    try w.writeAll("\"accessors\":[");
    // 0: POSITION
    try w.writeAll("{\"bufferView\":0,\"byteOffset\":0,\"componentType\":5126,\"count\":24,\"type\":\"VEC3\",\"min\":[-1.0,-1.0,-1.0],\"max\":[1.0,1.0,1.0]},");
    // 1: NORMAL
    try w.writeAll("{\"bufferView\":1,\"byteOffset\":0,\"componentType\":5126,\"count\":24,\"type\":\"VEC3\"},");
    // 2: TEXCOORD_0
    try w.writeAll("{\"bufferView\":2,\"byteOffset\":0,\"componentType\":5126,\"count\":24,\"type\":\"VEC2\"},");
    // 3: indices
    try w.writeAll("{\"bufferView\":3,\"byteOffset\":0,\"componentType\":5123,\"count\":36,\"type\":\"SCALAR\"},");
    // 4: TRANSLATION
    try w.print("{{\"bufferView\":5,\"byteOffset\":0,\"componentType\":5126,\"count\":{d},\"type\":\"VEC3\"}},", .{INST_COUNT});
    // 5: ROTATION
    try w.print("{{\"bufferView\":6,\"byteOffset\":0,\"componentType\":5126,\"count\":{d},\"type\":\"VEC4\"}},", .{INST_COUNT});
    // 6: SCALE
    try w.print("{{\"bufferView\":7,\"byteOffset\":0,\"componentType\":5126,\"count\":{d},\"type\":\"VEC3\"}},", .{INST_COUNT});
    // 7: _COLOR_0
    try w.print("{{\"bufferView\":8,\"byteOffset\":0,\"componentType\":5126,\"count\":{d},\"type\":\"VEC4\"}}", .{INST_COUNT});
    try w.writeAll("],");

    // 9 bufferViews: geom (0-3) + png (4) + instance (5-8)
    try w.writeAll("\"bufferViews\":[");
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ bv_pos_off, bv_pos_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ bv_nrm_off, bv_nrm_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ bv_uv_off, bv_uv_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d},\"target\":34963}},", .{ bv_idx_off, bv_idx_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ bv_png_off, png_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ inst_trans_off, inst_trans_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ inst_rot_off, inst_rot_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ inst_scale_off, inst_scale_len });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}}", .{ inst_color_off, inst_color_len });
    try w.writeAll("],");

    try w.print("\"buffers\":[{{\"byteLength\":{d}}}],", .{bin_total});

    // Material
    try w.writeAll("\"materials\":[{\"pbrMetallicRoughness\":{");
    try w.writeAll("\"baseColorTexture\":{\"index\":0},");
    try w.writeAll("\"baseColorFactor\":[1.0,1.0,1.0,1.0],");
    try w.writeAll("\"metallicFactor\":0.0,\"roughnessFactor\":0.8");
    try w.writeAll("}}],");

    try w.writeAll("\"textures\":[{\"source\":0}],");
    try w.print("\"images\":[{{\"bufferView\":4,\"mimeType\":\"image/png\"}}]", .{});
    try w.writeAll("}");

    // pad JSON to 4-byte alignment
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

// ── morphGlb fixture ──────────────────────────────────────────────────────────
// A minimal quad mesh (4 verts, 6 indices) with 2 morph targets and a LINEAR
// weight animation "MorphAnim". Used to test gltf morph parsing + vmesh round-trip.
pub fn morphGlb(alloc: Allocator) ![]u8 {
    // ── BIN layout ────────────────────────────────────────────────────────────
    // off_pos   =   0  4 * 3 * 4 = 48 bytes (POSITION VEC3 f32)
    // off_nrm   =  48  4 * 3 * 4 = 48 bytes (NORMAL VEC3 f32)
    // off_uv    =  96  4 * 2 * 4 = 32 bytes (TEXCOORD_0 VEC2 f32)
    // off_idx   = 128  6 * 2 = 12 bytes (indices u16)  → ends at 140, already 4-aligned
    // off_t0pos = 140  target 0 POSITION deltas: 4*3*4 = 48 bytes
    // off_t0nrm = 188  target 0 NORMAL deltas:   4*3*4 = 48 bytes
    // off_t1pos = 236  target 1 POSITION deltas: 4*3*4 = 48 bytes
    // off_t1nrm = 284  target 1 NORMAL deltas:   4*3*4 = 48 bytes
    // off_times = 332  anim input times: 2*4 = 8 bytes
    // off_wts   = 340  anim weights output: 4*4 = 16 bytes
    // bin_total = 356  (already 4-aligned)
    const off_pos: usize = 0;
    const off_nrm: usize = 48;
    const off_uv: usize = 96;
    const off_idx: usize = 128;
    const off_t0pos: usize = 140;
    const off_t0nrm: usize = 188;
    const off_t1pos: usize = 236;
    const off_t1nrm: usize = 284;
    const off_times: usize = 332;
    const off_wts: usize = 340;
    const bin_total: usize = 356;

    var bin = try alloc.alloc(u8, bin_total);
    defer alloc.free(bin);
    @memset(bin, 0);

    // Helper: write f32 as little-endian u32 bits
    const wf32 = struct {
        fn w(b: []u8, off: usize, v: f32) void {
            std.mem.writeInt(u32, b[off..][0..4], @bitCast(v), .little);
        }
    }.w;

    // POSITION: (0,0,0),(1,0,0),(0,1,0),(1,1,0)
    wf32(bin, off_pos + 0, 0.0);
    wf32(bin, off_pos + 4, 0.0);
    wf32(bin, off_pos + 8, 0.0);
    wf32(bin, off_pos + 12, 1.0);
    wf32(bin, off_pos + 16, 0.0);
    wf32(bin, off_pos + 20, 0.0);
    wf32(bin, off_pos + 24, 0.0);
    wf32(bin, off_pos + 28, 1.0);
    wf32(bin, off_pos + 32, 0.0);
    wf32(bin, off_pos + 36, 1.0);
    wf32(bin, off_pos + 40, 1.0);
    wf32(bin, off_pos + 44, 0.0);

    // NORMAL: all (0,0,1)
    for (0..4) |vi| {
        wf32(bin, off_nrm + vi * 12 + 0, 0.0);
        wf32(bin, off_nrm + vi * 12 + 4, 0.0);
        wf32(bin, off_nrm + vi * 12 + 8, 1.0);
    }

    // TEXCOORD_0: (0,0),(1,0),(0,1),(1,1)
    wf32(bin, off_uv + 0, 0.0);
    wf32(bin, off_uv + 4, 0.0);
    wf32(bin, off_uv + 8, 1.0);
    wf32(bin, off_uv + 12, 0.0);
    wf32(bin, off_uv + 16, 0.0);
    wf32(bin, off_uv + 20, 1.0);
    wf32(bin, off_uv + 24, 1.0);
    wf32(bin, off_uv + 28, 1.0);

    // INDICES: [0,1,2, 1,3,2]
    const idx_vals = [_]u16{ 0, 1, 2, 1, 3, 2 };
    for (idx_vals, 0..) |v, i| {
        std.mem.writeInt(u16, bin[off_idx + i * 2 ..][0..2], v, .little);
    }

    // Target 0 POSITION deltas: vertex 0 = (+0.5, 0, 0), others zero
    wf32(bin, off_t0pos + 0, 0.5); // v0.x
    // all others remain 0 (memset)

    // Target 0 NORMAL deltas: all zero (memset)
    _ = off_t0nrm; // already zero

    // Target 1 POSITION deltas: vertex 1 = (0, +0.25, 0), others zero
    wf32(bin, off_t1pos + 12 + 4, 0.25); // v1.y (v1 offset = 1*12, .y = +4)

    // Target 1 NORMAL deltas: all zero (memset)
    _ = off_t1nrm; // already zero

    // Anim times: [0.0, 1.0]
    wf32(bin, off_times + 0, 0.0);
    wf32(bin, off_times + 4, 1.0);

    // Anim weights output (target_count=2 per keyframe): [0.0, 0.0, 1.0, 0.5]
    // k0=[0.0,0.0] → flat[0]=0.0, flat[1]=0.0
    // k1=[1.0,0.5] → flat[2]=1.0, flat[3]=0.5
    wf32(bin, off_wts + 0, 0.0);
    wf32(bin, off_wts + 4, 0.0);
    wf32(bin, off_wts + 8, 1.0);
    wf32(bin, off_wts + 12, 0.5);

    // ── JSON ──────────────────────────────────────────────────────────────────
    var json_aw: std.Io.Writer.Allocating = .init(alloc);
    defer json_aw.deinit();
    const w = &json_aw.writer;

    try w.writeAll("{\"asset\":{\"version\":\"2.0\"},\"scene\":0,");
    try w.writeAll("\"scenes\":[{\"nodes\":[0]}],\"nodes\":[{\"mesh\":0}],");
    try w.writeAll("\"meshes\":[{\"primitives\":[{");
    try w.writeAll("\"attributes\":{\"POSITION\":0,\"NORMAL\":1,\"TEXCOORD_0\":2},");
    try w.writeAll("\"indices\":3,\"material\":0,");
    try w.writeAll("\"targets\":[{\"POSITION\":4,\"NORMAL\":5},{\"POSITION\":6,\"NORMAL\":7}]");
    try w.writeAll("}]}],");

    // 10 accessors
    try w.writeAll("\"accessors\":[");
    // 0: POSITION
    try w.writeAll("{\"bufferView\":0,\"byteOffset\":0,\"componentType\":5126,\"count\":4,\"type\":\"VEC3\"},");
    // 1: NORMAL
    try w.writeAll("{\"bufferView\":1,\"byteOffset\":0,\"componentType\":5126,\"count\":4,\"type\":\"VEC3\"},");
    // 2: TEXCOORD_0
    try w.writeAll("{\"bufferView\":2,\"byteOffset\":0,\"componentType\":5126,\"count\":4,\"type\":\"VEC2\"},");
    // 3: indices
    try w.writeAll("{\"bufferView\":3,\"byteOffset\":0,\"componentType\":5123,\"count\":6,\"type\":\"SCALAR\"},");
    // 4: target 0 POSITION
    try w.writeAll("{\"bufferView\":4,\"byteOffset\":0,\"componentType\":5126,\"count\":4,\"type\":\"VEC3\"},");
    // 5: target 0 NORMAL
    try w.writeAll("{\"bufferView\":5,\"byteOffset\":0,\"componentType\":5126,\"count\":4,\"type\":\"VEC3\"},");
    // 6: target 1 POSITION
    try w.writeAll("{\"bufferView\":6,\"byteOffset\":0,\"componentType\":5126,\"count\":4,\"type\":\"VEC3\"},");
    // 7: target 1 NORMAL
    try w.writeAll("{\"bufferView\":7,\"byteOffset\":0,\"componentType\":5126,\"count\":4,\"type\":\"VEC3\"},");
    // 8: anim times
    try w.writeAll("{\"bufferView\":8,\"byteOffset\":0,\"componentType\":5126,\"count\":2,\"type\":\"SCALAR\"},");
    // 9: anim weights output
    try w.writeAll("{\"bufferView\":9,\"byteOffset\":0,\"componentType\":5126,\"count\":4,\"type\":\"SCALAR\"}");
    try w.writeAll("],");

    // 10 bufferViews
    try w.writeAll("\"bufferViews\":[");
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ 0, 48 });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ 48, 48 });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ 96, 32 });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ 128, 12 });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ 140, 48 });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ 188, 48 });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ 236, 48 });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ 284, 48 });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ 332, 8 });
    try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}}", .{ 340, 16 });
    try w.writeAll("],");

    try w.print("\"buffers\":[{{\"byteLength\":{d}}}],", .{bin_total});
    try w.writeAll("\"materials\":[{\"pbrMetallicRoughness\":{\"metallicFactor\":0.0,\"roughnessFactor\":0.5}}],");
    try w.writeAll("\"animations\":[{\"name\":\"MorphAnim\",");
    try w.writeAll("\"channels\":[{\"sampler\":0,\"target\":{\"node\":0,\"path\":\"weights\"}}],");
    try w.writeAll("\"samplers\":[{\"input\":8,\"output\":9,\"interpolation\":\"LINEAR\"}]}]");
    try w.writeAll("}");

    // pad JSON to 4-byte alignment
    while (json_aw.writer.end % 4 != 0) try w.writeByte(0x20);

    const json_bytes = try json_aw.toOwnedSlice();
    defer alloc.free(json_bytes);
    const json_len: u32 = @intCast(json_bytes.len);

    // ── Assemble GLB ──────────────────────────────────────────────────────────
    const bin_padded: u32 = @intCast((bin_total + 3) & ~@as(usize, 3));
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
    @memcpy(glb[goff..][0..bin_total], bin);

    return glb;
}

// ── morphDemoGlb ─────────────────────────────────────────────────────────────

/// Builds a VISIBLE morph demo GLB: a 5×5 subdivided plane with 3 morph targets
/// (Bulge/Wave/Twist) and a LINEAR weight animation "MorphDemoAnim" that cycles
/// through each target. Used by gen_morph_glb.zig → gl_asset_gen → morph.vmesh.
pub fn morphDemoGlb(alloc: Allocator) ![]u8 {
    // ── BIN layout ────────────────────────────────────────────────────────────
    // 25 verts × 3 floats × 4 bytes = 300 bytes  POSITION
    // 25 verts × 3 floats × 4 bytes = 300 bytes  NORMAL
    // 25 verts × 2 floats × 4 bytes = 200 bytes  TEXCOORD_0
    // 96 indices × 2 bytes          = 192 bytes  (4-aligned)
    // Target 0 POSITION deltas      = 300 bytes
    // Target 0 NORMAL deltas        = 300 bytes
    // Target 1 POSITION deltas      = 300 bytes
    // Target 1 NORMAL deltas        = 300 bytes
    // Target 2 POSITION deltas      = 300 bytes
    // Target 2 NORMAL deltas        = 300 bytes
    // Anim times  4 × 4             =  16 bytes
    // Anim weights CUBICSPLINE 36×4 = 144 bytes  (4 keys × 3 targets × 3 slots)
    // bin_total                     = 2952 bytes
    const off_pos: usize = 0;
    const off_nrm: usize = 300;
    const off_uv: usize = 600;
    const off_idx: usize = 800;
    const off_t0pos: usize = 992;
    const off_t0nrm: usize = 1292;
    const off_t1pos: usize = 1592;
    const off_t1nrm: usize = 1892;
    const off_t2pos: usize = 2192;
    const off_t2nrm: usize = 2492;
    const off_times: usize = 2792;
    const off_wts: usize = 2808;
    const bin_total: usize = 2952;

    const bin = try alloc.alloc(u8, bin_total);
    defer alloc.free(bin);
    @memset(bin, 0);

    // Helper: write f32 as little-endian u32 bits
    const wf32 = struct {
        fn w(b: []u8, off: usize, v: f32) void {
            std.mem.writeInt(u32, b[off..][0..4], @bitCast(v), .little);
        }
    }.w;

    // Helper: write u16 little-endian
    const wu16 = struct {
        fn w(b: []u8, off: usize, v: u16) void {
            std.mem.writeInt(u16, b[off..][0..2], v, .little);
        }
    }.w;

    // ── POSITION (5×5 grid, XZ plane, Y=0) ───────────────────────────────────
    // Vertex (i,j): x = -1 + i*0.5, y = 0, z = -1 + j*0.5
    for (0..5) |j| {
        for (0..5) |i| {
            const vi: usize = j * 5 + i;
            const x: f32 = -1.0 + @as(f32, @floatFromInt(i)) * 0.5;
            const z: f32 = -1.0 + @as(f32, @floatFromInt(j)) * 0.5;
            wf32(bin, off_pos + vi * 12 + 0, x);
            wf32(bin, off_pos + vi * 12 + 4, 0.0);
            wf32(bin, off_pos + vi * 12 + 8, z);
        }
    }

    // ── NORMAL (all 0,1,0 pointing up) ───────────────────────────────────────
    for (0..25) |vi| {
        wf32(bin, off_nrm + vi * 12 + 0, 0.0);
        wf32(bin, off_nrm + vi * 12 + 4, 1.0);
        wf32(bin, off_nrm + vi * 12 + 8, 0.0);
    }

    // ── TEXCOORD_0 (i/4, j/4) ────────────────────────────────────────────────
    for (0..5) |j| {
        for (0..5) |i| {
            const vi: usize = j * 5 + i;
            wf32(bin, off_uv + vi * 8 + 0, @as(f32, @floatFromInt(i)) / 4.0);
            wf32(bin, off_uv + vi * 8 + 4, @as(f32, @floatFromInt(j)) / 4.0);
        }
    }

    // ── INDICES: 4×4 = 16 quads, each 2 CCW triangles ────────────────────────
    // quad (i,j): base = j*5+i; tris: (base,base+1,base+5),(base+1,base+6,base+5)
    var iidx: usize = 0;
    for (0..4) |j| {
        for (0..4) |i| {
            const base: u16 = @intCast(j * 5 + i);
            wu16(bin, off_idx + iidx * 2 + 0, base);
            wu16(bin, off_idx + iidx * 2 + 2, base + 1);
            wu16(bin, off_idx + iidx * 2 + 4, base + 5);
            wu16(bin, off_idx + iidx * 2 + 6, base + 1);
            wu16(bin, off_idx + iidx * 2 + 8, base + 6);
            wu16(bin, off_idx + iidx * 2 + 10, base + 5);
            iidx += 6;
        }
    }

    // ── Target 0: Bulge ───────────────────────────────────────────────────────
    // centre (2,2)=12: +1.5Y; mid-edge (2,0)=2,(0,2)=10,(4,2)=14,(2,4)=22: +0.8Y
    // corners (0,0)=0,(4,0)=4,(0,4)=20,(4,4)=24: +0.3Y
    const bulge_verts = [_]struct { vi: usize, dy: f32 }{
        .{ .vi = 12, .dy = 1.5 },
        .{ .vi = 2, .dy = 0.8 },
        .{ .vi = 10, .dy = 0.8 },
        .{ .vi = 14, .dy = 0.8 },
        .{ .vi = 22, .dy = 0.8 },
        .{ .vi = 0, .dy = 0.3 },
        .{ .vi = 4, .dy = 0.3 },
        .{ .vi = 20, .dy = 0.3 },
        .{ .vi = 24, .dy = 0.3 },
    };
    for (bulge_verts) |bv| {
        wf32(bin, off_t0pos + bv.vi * 12 + 4, bv.dy);
    }

    // ── Target 1: Wave (sine along X axis) ────────────────────────────────────
    // dPos.y = 0.8 * sin(i * π/2)
    for (0..5) |j| {
        for (0..5) |i| {
            const vi: usize = j * 5 + i;
            const angle: f32 = @as(f32, @floatFromInt(i)) * std.math.pi / 2.0;
            const dy: f32 = 0.8 * std.math.sin(angle);
            wf32(bin, off_t1pos + vi * 12 + 4, dy);
        }
    }

    // ── Target 2: Twist (rotate around Y proportional to Z) ──────────────────
    // twist = z_val * 0.4; dPos.x = x_val*(cos(twist)-1); dPos.z = x_val*sin(twist)
    for (0..5) |j| {
        for (0..5) |i| {
            const vi: usize = j * 5 + i;
            const x_val: f32 = -1.0 + @as(f32, @floatFromInt(i)) * 0.5;
            const z_val: f32 = -1.0 + @as(f32, @floatFromInt(j)) * 0.5;
            const twist: f32 = z_val * 0.4;
            const dpx: f32 = x_val * (std.math.cos(twist) - 1.0);
            const dpz: f32 = x_val * std.math.sin(twist);
            wf32(bin, off_t2pos + vi * 12 + 0, dpx);
            wf32(bin, off_t2pos + vi * 12 + 8, dpz);
        }
    }

    // ── Anim times: [0.0, 1.0, 2.0, 3.0] ────────────────────────────────────
    wf32(bin, off_times + 0, 0.0);
    wf32(bin, off_times + 4, 1.0);
    wf32(bin, off_times + 8, 2.0);
    wf32(bin, off_times + 12, 3.0);

    // ── Anim weights: CUBICSPLINE, 4 keyframes × 3 targets × 3 slots = 36 scalars ─
    // Each keyframe stores [inTangent×3, point×3, outTangent×3] per the glTF spec:
    // accessor count = 4 × 3 (key_count × components), but each "element" is a
    // SCALAR so count = 4 × 3 × 3 = 36 (glTF CUBICSPLINE: output count = 3 × key_count × comps).
    // The baked clip animates ONLY Wave (target 1) and Twist (target 2); Bulge
    // (target 0) stays 0 so it is purely runtime-controlled by the /gl-morph
    // "Bulge +" button (otherwise the baked Bulge pulse masks the runtime lock).
    // Layout per key: [in0,in1,in2, point0,point1,point2, out0,out1,out2]
    // k0: in=[0,0,0] point=[0,0,0] out=[0,0,0]   (start at rest)
    // k1: in=[0,0,0] point=[0,1,0] out=[0,0,0]   (Wave fully active)
    // k2: in=[0,0,0] point=[0,0,1] out=[0,0,0]   (Twist fully active)
    // k3: in=[0,0,0] point=[0,0,0] out=[0,0,0]   (return to rest)
    const anim_weights = [36]f32{
        0, 0, 0,  0, 0, 0,  0, 0, 0, // k0: in, point, out
        0, 0, 0,  0, 1, 0,  0, 0, 0, // k1: in, point, out
        0, 0, 0,  0, 0, 1,  0, 0, 0, // k2: in, point, out
        0, 0, 0,  0, 0, 0,  0, 0, 0, // k3: in, point, out
    };
    for (anim_weights, 0..) |wt, wi| {
        wf32(bin, off_wts + wi * 4, wt);
    }

    // ── JSON ──────────────────────────────────────────────────────────────────
    // bufferViews: 0=pos, 1=nrm, 2=uv, 3=idx, 4=t0pos, 5=t0nrm,
    //              6=t1pos, 7=t1nrm, 8=t2pos, 9=t2nrm, 10=times, 11=wts
    // accessors:   0=pos, 1=nrm, 2=uv, 3=idx, 4=t0pos, 5=t0nrm,
    //              6=t1pos, 7=t1nrm, 8=t2pos, 9=t2nrm, 10=times, 11=wts
    var json_aw: std.Io.Writer.Allocating = .init(alloc);
    defer json_aw.deinit();
    const w = &json_aw.writer;
    try w.writeAll("{\"asset\":{\"version\":\"2.0\"},");
    try w.writeAll("\"scene\":0,\"scenes\":[{\"nodes\":[0]}],");
    try w.writeAll("\"nodes\":[{\"mesh\":0}],");
    // bufferViews
    try w.writeAll("\"bufferViews\":[");
    const bv_offsets = [12]usize{ off_pos, off_nrm, off_uv, off_idx, off_t0pos, off_t0nrm, off_t1pos, off_t1nrm, off_t2pos, off_t2nrm, off_times, off_wts };
    const bv_lens = [12]usize{ 300, 300, 200, 192, 300, 300, 300, 300, 300, 300, 16, 144 };
    for (bv_offsets, bv_lens, 0..) |bv_off, bv_len, bvi| {
        if (bvi > 0) try w.writeAll(",");
        try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}}", .{ bv_off, bv_len });
    }
    try w.writeAll("],");
    // accessors
    try w.writeAll("\"accessors\":[");
    // 0: POSITION VEC3 f32 25
    try w.writeAll("{\"bufferView\":0,\"byteOffset\":0,\"componentType\":5126,\"count\":25,\"type\":\"VEC3\",\"min\":[-1.0,0.0,-1.0],\"max\":[1.0,0.0,1.0]},");
    // 1: NORMAL VEC3 f32 25
    try w.writeAll("{\"bufferView\":1,\"byteOffset\":0,\"componentType\":5126,\"count\":25,\"type\":\"VEC3\"},");
    // 2: TEXCOORD_0 VEC2 f32 25
    try w.writeAll("{\"bufferView\":2,\"byteOffset\":0,\"componentType\":5126,\"count\":25,\"type\":\"VEC2\"},");
    // 3: indices SCALAR u16 96
    try w.writeAll("{\"bufferView\":3,\"byteOffset\":0,\"componentType\":5123,\"count\":96,\"type\":\"SCALAR\"},");
    // 4-9: morph delta accessors VEC3 f32 25 (no min/max required for targets)
    for (4..10) |aci| {
        try w.print("{{\"bufferView\":{d},\"byteOffset\":0,\"componentType\":5126,\"count\":25,\"type\":\"VEC3\"}},", .{aci});
    }
    // 10: times SCALAR f32 4
    try w.writeAll("{\"bufferView\":10,\"byteOffset\":0,\"componentType\":5126,\"count\":4,\"type\":\"SCALAR\",\"min\":[0.0],\"max\":[3.0]},");
    // 11: weights CUBICSPLINE SCALAR f32 36 (4 keys × 3 targets × 3 slots)
    try w.writeAll("{\"bufferView\":11,\"byteOffset\":0,\"componentType\":5126,\"count\":36,\"type\":\"SCALAR\"}");
    try w.writeAll("],");
    // mesh
    try w.writeAll("\"meshes\":[{\"name\":\"MorphPlane\",\"extras\":{\"targetNames\":[\"Bulge\",\"Wave\",\"Twist\"]},");
    try w.writeAll("\"primitives\":[{\"attributes\":{\"POSITION\":0,\"NORMAL\":1,\"TEXCOORD_0\":2},\"indices\":3,\"material\":0,");
    try w.writeAll("\"targets\":[{\"POSITION\":4,\"NORMAL\":5},{\"POSITION\":6,\"NORMAL\":7},{\"POSITION\":8,\"NORMAL\":9}]}]}],");
    // material
    try w.writeAll("\"materials\":[{\"pbrMetallicRoughness\":{\"baseColorFactor\":[0.8,0.6,0.3,1.0],\"metallicFactor\":0.0,\"roughnessFactor\":0.5}}],");
    // animation
    try w.writeAll("\"animations\":[{\"name\":\"MorphDemoAnim\",");
    try w.writeAll("\"channels\":[{\"sampler\":0,\"target\":{\"node\":0,\"path\":\"weights\"}}],");
    try w.writeAll("\"samplers\":[{\"input\":10,\"output\":11,\"interpolation\":\"CUBICSPLINE\"}]}],");
    // buffer
    try w.print("\"buffers\":[{{\"byteLength\":{d}}}]}}", .{bin_total});
    // pad JSON to 4-byte alignment
    while (json_aw.writer.end % 4 != 0) try w.writeByte(0x20);

    const json_bytes = try json_aw.toOwnedSlice();
    defer alloc.free(json_bytes);
    const json_len: u32 = @intCast(json_bytes.len);

    // ── Assemble GLB ──────────────────────────────────────────────────────────
    const bin_padded: u32 = @intCast((bin_total + 3) & ~@as(usize, 3));
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
    @memcpy(glb[goff..][0..bin_total], bin);

    return glb;
}

// ── morphDemoGlb tests ────────────────────────────────────────────────────────

test "morphDemoGlb: parses as valid glb with 3 targets" {
    const glb = try morphDemoGlb(testing.allocator);
    defer testing.allocator.free(glb);
    var model = try gltf_mod.parseGlb(testing.allocator, glb);
    defer model.deinit();
    try testing.expectEqual(@as(u32, 3), model.morph.?.target_count);
    try testing.expect(model.morph.?.weight_clip != null);
}

// ── cubeFieldGlb fixture tests ────────────────────────────────────────────────

test "cubeFieldGlb: 256 instances round-trip via EXT_mesh_gpu_instancing" {
    const glb = try cubeFieldGlb(testing.allocator);
    defer testing.allocator.free(glb);
    var model = try gltf_mod.parseGlb(testing.allocator, glb);
    defer model.deinit();
    try testing.expectEqual(@as(u32, 256), model.instance_count);
    // first and last instance colors differ (varied field)
    try testing.expect(model.instances.len == 256 * 20);
}
