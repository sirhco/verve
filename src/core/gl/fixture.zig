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
// Vertex order per face (CCW from outside): matches indices 0,1,2,0,2,3.

// Face description: [normal xyz] then 4 vertex positions.
const Face = struct {
    nx: f32,
    ny: f32,
    nz: f32,
    // 4 corner positions (xyz each)
    v: [4][3]f32,
};

// Derive CCW winding from outside for each face.
// Convention: looking from outside (along -normal direction), vertices are CCW.
//
//  +X face (right): normal=(1,0,0)  looking from +x → verts in yz plane, CCW = +y+z → +y-z → -y-z → -y+z
//  -X face (left):  normal=(-1,0,0) looking from -x → CCW = +y-z → +y+z → -y+z → -y-z  (flip z compared to +x)
//  +Y face (top):   normal=(0,1,0)  looking down from +y → verts in xz plane, CCW = -x-z → +x-z → +x+z → -x+z
//  -Y face (bottom):normal=(0,-1,0) looking from -y → CCW = -x+z → +x+z → +x-z → -x-z
//  +Z face (front): normal=(0,0,1)  looking from +z → verts in xy plane, CCW = -x-y → +x-y → +x+y → -x+y
//  -Z face (back):  normal=(0,0,-1) looking from -z → CCW = +x-y → -x-y → -x+y → +x+y

const faces = [6]Face{
    // +X
    .{ .nx = 1, .ny = 0, .nz = 0, .v = .{
        .{ 1, 1, 1 },
        .{ 1, 1, -1 },
        .{ 1, -1, -1 },
        .{ 1, -1, 1 },
    } },
    // -X
    .{ .nx = -1, .ny = 0, .nz = 0, .v = .{
        .{ -1, 1, -1 },
        .{ -1, 1, 1 },
        .{ -1, -1, 1 },
        .{ -1, -1, -1 },
    } },
    // +Y
    .{ .nx = 0, .ny = 1, .nz = 0, .v = .{
        .{ -1, 1, -1 },
        .{ 1, 1, -1 },
        .{ 1, 1, 1 },
        .{ -1, 1, 1 },
    } },
    // -Y
    .{ .nx = 0, .ny = -1, .nz = 0, .v = .{
        .{ -1, -1, 1 },
        .{ 1, -1, 1 },
        .{ 1, -1, -1 },
        .{ -1, -1, -1 },
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

    // Write indices: per face base+{0,1,2,0,2,3}
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
