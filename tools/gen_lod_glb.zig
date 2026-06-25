//! Build-time LOD fixture generator. Writes a GLB with three UV-sphere meshes
//! named "sphere_lod0", "sphere_lod1", "sphere_lod2" (high/medium/low poly).
//! The _lodN names trigger the glTF parser's LOD grouping code in gltf.zig,
//! producing a vmesh with 3 LOD levels and SQUARED distance thresholds.
//!
//! LOD poly counts:
//!   lod0: 32 stacks × 32 slices → ~2048 triangles  (high detail, near)
//!   lod1:  8 stacks ×  8 slices →   128 triangles  (medium detail)
//!   lod2:  4 stacks ×  4 slices →    32 triangles  (low detail, far)
//!
//! Invoked by build.zig via addRunArtifact; the output LazyPath is fed as
//! the input file argument to gl_asset_gen.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.log.err("gen_lod_glb: usage: gen_lod_glb <out.glb>", .{});
        return error.MissingOutPath;
    }
    const out_path = args[1];
    const alloc = init.gpa;

    const glb = try buildLodGlb(alloc);
    defer alloc.free(glb);

    const cwd = std.Io.Dir.cwd();
    var file = try cwd.createFile(io, out_path, .{});
    defer file.close(io);
    try file.writePositionalAll(io, glb, 0);
}

/// UV sphere geometry at `stacks` × `slices` resolution.
/// Returns owned slices (alloc).
const SphereGeom = struct {
    positions: []f32,
    normals: []f32,
    uvs: []f32,
    indices: []u16,
    vertex_count: u32,
    index_count: u32,
};

fn buildSphere(alloc: std.mem.Allocator, stacks: u32, slices: u32) !SphereGeom {
    const vc: u32 = (stacks + 1) * (slices + 1);
    const ic: u32 = stacks * slices * 6;

    var pos = try alloc.alloc(f32, vc * 3);
    var nrm = try alloc.alloc(f32, vc * 3);
    var uvs = try alloc.alloc(f32, vc * 2);
    var idx = try alloc.alloc(u16, ic);

    var vi: u32 = 0;
    for (0..stacks + 1) |st| {
        const phi: f32 = std.math.pi * @as(f32, @floatFromInt(st)) / @as(f32, @floatFromInt(stacks));
        const sp = @sin(phi);
        const cp = @cos(phi);
        for (0..slices + 1) |sl| {
            const theta: f32 = 2.0 * std.math.pi * @as(f32, @floatFromInt(sl)) / @as(f32, @floatFromInt(slices));
            const st2 = @sin(theta);
            const ct = @cos(theta);
            const x = sp * ct;
            const y = cp;
            const z = sp * st2;
            pos[vi * 3 + 0] = x;
            pos[vi * 3 + 1] = y;
            pos[vi * 3 + 2] = z;
            nrm[vi * 3 + 0] = x;
            nrm[vi * 3 + 1] = y;
            nrm[vi * 3 + 2] = z;
            uvs[vi * 2 + 0] = @as(f32, @floatFromInt(sl)) / @as(f32, @floatFromInt(slices));
            uvs[vi * 2 + 1] = @as(f32, @floatFromInt(st)) / @as(f32, @floatFromInt(stacks));
            vi += 1;
        }
    }

    // Indices (two triangles per quad, CCW winding).
    var ti: u32 = 0;
    for (0..stacks) |st_i| {
        for (0..slices) |sl_i| {
            const v0: u16 = @intCast(st_i * (slices + 1) + sl_i);
            const v1: u16 = v0 + 1;
            const v2: u16 = @intCast((st_i + 1) * (slices + 1) + sl_i);
            const v3: u16 = v2 + 1;
            idx[ti + 0] = v0;
            idx[ti + 1] = v2;
            idx[ti + 2] = v1;
            idx[ti + 3] = v1;
            idx[ti + 4] = v2;
            idx[ti + 5] = v3;
            ti += 6;
        }
    }

    return .{
        .positions = pos,
        .normals = nrm,
        .uvs = uvs,
        .indices = idx,
        .vertex_count = vc,
        .index_count = ic,
    };
}

fn buildLodGlb(alloc: std.mem.Allocator) ![]u8 {
    // LOD levels: stacks × slices (higher = more detail).
    const lod_configs = [3][2]u32{
        .{ 32, 32 }, // lod0: ~2048 tri
        .{ 8, 8 }, //  lod1: ~128 tri
        .{ 4, 4 }, //  lod2: ~32 tri
    };
    const lod_names = [3][]const u8{ "sphere_lod0", "sphere_lod1", "sphere_lod2" };

    // Build geometry for each LOD level.
    var geoms: [3]SphereGeom = undefined;
    for (0..3) |i| {
        geoms[i] = try buildSphere(alloc, lod_configs[i][0], lod_configs[i][1]);
    }
    defer {
        for (0..3) |i| {
            alloc.free(geoms[i].positions);
            alloc.free(geoms[i].normals);
            alloc.free(geoms[i].uvs);
            alloc.free(geoms[i].indices);
        }
    }

    // BIN layout: for each LOD, sequentially:
    //   positions: vc × 3 f32
    //   normals:   vc × 3 f32
    //   uvs:       vc × 2 f32
    //   indices:   ic × u16  (padded to 4 bytes)
    // We keep separate bufferViews for each section of each LOD level.
    // Total accessor count: 4 per LOD = 12. Total bufferView count: 4 per LOD = 12.
    var bin_parts: [3]struct {
        pos_off: u32,
        pos_len: u32,
        nrm_off: u32,
        nrm_len: u32,
        uv_off: u32,
        uv_len: u32,
        idx_off: u32,
        idx_len: u32,
        idx_padded: u32,
    } = undefined;

    var total_bin: u32 = 0;
    for (0..3) |i| {
        const g = &geoms[i];
        const pos_off = total_bin;
        const pos_len: u32 = g.vertex_count * 3 * 4;
        total_bin += pos_len;
        const nrm_off = total_bin;
        const nrm_len: u32 = g.vertex_count * 3 * 4;
        total_bin += nrm_len;
        const uv_off = total_bin;
        const uv_len: u32 = g.vertex_count * 2 * 4;
        total_bin += uv_len;
        const idx_off = total_bin;
        const idx_len: u32 = g.index_count * 2;
        const idx_padded: u32 = (idx_len + 3) & ~@as(u32, 3);
        total_bin += idx_padded;
        bin_parts[i] = .{
            .pos_off = pos_off,
            .pos_len = pos_len,
            .nrm_off = nrm_off,
            .nrm_len = nrm_len,
            .uv_off = uv_off,
            .uv_len = uv_len,
            .idx_off = idx_off,
            .idx_len = idx_len,
            .idx_padded = idx_padded,
        };
    }

    // Build BIN buffer.
    const bin_padded: u32 = (total_bin + 3) & ~@as(u32, 3);
    var bin = try alloc.alloc(u8, bin_padded);
    defer alloc.free(bin);
    @memset(bin, 0);

    for (0..3) |i| {
        const g = &geoms[i];
        const p = &bin_parts[i];
        @memcpy(bin[p.pos_off..][0..p.pos_len], std.mem.sliceAsBytes(g.positions));
        @memcpy(bin[p.nrm_off..][0..p.nrm_len], std.mem.sliceAsBytes(g.normals));
        @memcpy(bin[p.uv_off..][0..p.uv_len], std.mem.sliceAsBytes(g.uvs));
        @memcpy(bin[p.idx_off..][0..p.idx_len], std.mem.sliceAsBytes(g.indices));
    }

    // Build JSON.
    // accessors: 4 per LOD level (pos, nrm, uv, idx) → indices 0..11
    // bufferViews: same 4 per LOD → indices 0..11
    // meshes: 3, each named sphere_lod{N}
    // nodes: 3, each with a mesh
    // materials: 1 shared (metallic sphere, no texture)
    var json_aw: std.Io.Writer.Allocating = .init(alloc);
    defer json_aw.deinit();
    const w = &json_aw.writer;

    try w.writeAll("{");
    try w.writeAll("\"asset\":{\"version\":\"2.0\"},");
    try w.writeAll("\"scene\":0,");
    try w.writeAll("\"scenes\":[{\"nodes\":[0,1,2]}],");

    // nodes
    try w.writeAll("\"nodes\":[");
    for (0..3) |i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"mesh\":{d},\"name\":\"{s}\"}}", .{ i, lod_names[i] });
    }
    try w.writeAll("],");

    // meshes
    try w.writeAll("\"meshes\":[");
    for (0..3) |i| {
        if (i > 0) try w.writeByte(',');
        const acc_base: u32 = @as(u32, @intCast(i)) * 4;
        try w.print(
            "{{\"name\":\"{s}\",\"primitives\":[{{\"attributes\":{{\"POSITION\":{d},\"NORMAL\":{d},\"TEXCOORD_0\":{d}}},\"indices\":{d},\"material\":0}}]}}",
            .{ lod_names[i], acc_base, acc_base + 1, acc_base + 2, acc_base + 3 },
        );
    }
    try w.writeAll("],");

    // accessors (4 per LOD: pos, nrm, uv, idx)
    try w.writeAll("\"accessors\":[");
    for (0..3) |i| {
        const g = &geoms[i];
        const bv_base: u32 = @as(u32, @intCast(i)) * 4;
        if (i > 0) try w.writeByte(',');
        // pos accessor
        try w.print("{{\"bufferView\":{d},\"byteOffset\":0,\"componentType\":5126,\"count\":{d},\"type\":\"VEC3\",\"min\":[-1.0,-1.0,-1.0],\"max\":[1.0,1.0,1.0]}},", .{ bv_base, g.vertex_count });
        // nrm accessor
        try w.print("{{\"bufferView\":{d},\"byteOffset\":0,\"componentType\":5126,\"count\":{d},\"type\":\"VEC3\"}},", .{ bv_base + 1, g.vertex_count });
        // uv accessor
        try w.print("{{\"bufferView\":{d},\"byteOffset\":0,\"componentType\":5126,\"count\":{d},\"type\":\"VEC2\"}},", .{ bv_base + 2, g.vertex_count });
        // idx accessor
        try w.print("{{\"bufferView\":{d},\"byteOffset\":0,\"componentType\":5123,\"count\":{d},\"type\":\"SCALAR\"}}", .{ bv_base + 3, g.index_count });
    }
    try w.writeAll("],");

    // bufferViews (4 per LOD: pos, nrm, uv, idx)
    try w.writeAll("\"bufferViews\":[");
    for (0..3) |i| {
        const p = &bin_parts[i];
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ p.pos_off, p.pos_len });
        try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ p.nrm_off, p.nrm_len });
        try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d}}},", .{ p.uv_off, p.uv_len });
        try w.print("{{\"buffer\":0,\"byteOffset\":{d},\"byteLength\":{d},\"target\":34963}}", .{ p.idx_off, p.idx_len });
    }
    try w.writeAll("],");

    try w.print("\"buffers\":[{{\"byteLength\":{d}}}],", .{total_bin});

    // 1 material: smooth metallic sphere, no texture
    try w.writeAll("\"materials\":[{\"pbrMetallicRoughness\":{");
    try w.writeAll("\"baseColorFactor\":[0.7,0.8,1.0,1.0],");
    try w.writeAll("\"metallicFactor\":0.2,\"roughnessFactor\":0.4");
    try w.writeAll("}}]");
    try w.writeAll("}");

    // Pad JSON to 4-byte alignment.
    while (json_aw.writer.end % 4 != 0) try w.writeByte(0x20);

    const json_bytes = try json_aw.toOwnedSlice();
    defer alloc.free(json_bytes);
    const json_len: u32 = @intCast(json_bytes.len);

    // Assemble GLB.
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
