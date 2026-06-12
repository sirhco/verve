//! .vmesh packed asset format v3 — writer + freestanding reader.
//!
//! Invariant: the byte buffer handed to `Reader.init` must itself be at least
//! 4-byte aligned (the asset region provides 16) — section offsets only
//! preserve alignment relative to the buffer base, and
//! `bvh.nodesFromBytes`/`triPermFromBytes` assert on the absolute pointer.
//!
//! Header layout (56 bytes, all integers little-endian u32):
//!   [0..4]   magic "VMSH"
//!   [4..8]   version u32 = 3
//!   [8..12]  vertex_count
//!   [12..16] index_count
//!   [16..20] submesh_count
//!   [20..24] texture_count
//!   [24..28] vertex_off  (16-aligned, from file start)
//!   [28..32] index_off   (4-aligned)
//!   [32..36] tex_table_off
//!   [36..40] tex_data_off (4-aligned)
//!   [40..44] bvh_off        (16-aligned; 0 allowed ONLY if bvh_node_count == 0)
//!   [44..48] bvh_node_count
//!   [48..52] name_table_off (4-aligned; 0 allowed ONLY if name_count == 0)
//!   [52..56] name_count
//! submesh table @56, submesh_count × 72 bytes:
//!   index_byte_off u32 @0, index_count u32 @4,
//!   base_color f32×4 @8, metallic f32 @24, roughness f32 @28,
//!   emissive f32×3 @32, occlusion_strength f32 @44, normal_scale f32 @48,
//!   tex_base i32 @52, tex_mr i32 @56, tex_normal i32 @60,
//!   tex_emissive i32 @64, tex_occlusion i32 @68
//! texture table @tex_table_off, texture_count × 16 bytes:
//!   width u32, height u32, data_off u32 (into tex blob), data_len u32
//!
//! Sections appended after the texture blob, in order:
//!   BVH nodes  : bvh_node_count × 32 B @ bvh_off (16-aligned), followed
//!                immediately by tri-perm: u32 × (index_count/3) starting at
//!                bvh_off + bvh_node_count*32 (4-aligned automatically).
//!   name table : name_count × 12 B @ name_table_off (4-aligned), then the
//!                name blob (UTF-8 bytes located via per-entry absolute offsets).
//!   name entry 12 B: name_hash u32 (FNV-1a-32) @0, blob_off u32 (ABSOLUTE
//!                file offset) @4, blob_len u32 @8. Entry index ↔ submesh index
//!                (name_count == submesh_count when names present; 0 = no names).
//!
//! Vertex layout (stride 48):
//!   pos f32×3 @0, normal f32×3 @12, tangent f32×4 @24 (w=handedness ±1), uv f32×2 @40

const std = @import("std");
const bvh = @import("bvh.zig");

pub const magic = "VMSH";
pub const version: u32 = 3;
pub const vertex_stride: u32 = 48; // pos f32x3 @0, normal f32x3 @12, tangent f32x4 @24, uv f32x2 @40
pub const header_size: u32 = 56;
pub const submesh_size: u32 = 72;
pub const tex_entry_size: u32 = 16;
pub const name_entry_size: u32 = 12;

/// FNV-1a-32 hash (offset basis 0x811c9dc5, prime 0x01000193). The chunk-side
/// findName uses the same fn — keep frozen.
pub fn fnv1a32(s: []const u8) u32 {
    var h: u32 = 0x811c9dc5;
    for (s) |b| {
        h ^= b;
        h *%= 0x01000193;
    }
    return h;
}

pub const Submesh = struct {
    index_byte_off: u32,
    index_count: u32,
    base_color: [4]f32,
    metallic: f32,
    roughness: f32,
    emissive: [3]f32,
    occlusion_strength: f32,
    normal_scale: f32,
    tex_base: i32,
    tex_mr: i32,
    tex_normal: i32,
    tex_emissive: i32,
    tex_occlusion: i32,
};

pub const Texture = struct {
    width: u32,
    height: u32,
    rgba: []const u8, // width*height*4
};

/// Native-side packer. Caller supplies all arrays; `pack` computes
/// aligned offsets and returns the complete file bytes (alloc-owned).
/// vertices: len % 12 == 0 (stride 48 / 4 = 12 f32/vertex).
///
/// `bvh_nodes` + `tri_perm`: either both empty (a v3 file without picking
/// data) or bvh_nodes.len > 0 with tri_perm.len == indices.len/3.
/// `names`: len 0 (no names) or == submeshes.len; index ↔ submesh index.
pub fn pack(
    alloc: std.mem.Allocator,
    vertices: []const f32, // len % 12 == 0 (stride 48 / 4)
    indices: []const u16,
    submeshes: []const Submesh,
    textures: []const Texture,
    bvh_nodes: []const bvh.Node,
    tri_perm: []const u32,
    names: []const []const u8,
) ![]u8 {
    // Validate BVH section coupling.
    if (bvh_nodes.len > 0) {
        if (tri_perm.len != indices.len / 3) return error.SizeMismatch;
    } else {
        if (tri_perm.len != 0) return error.SizeMismatch;
    }
    // Validate name section: 0 (none) or one per submesh.
    if (names.len != 0 and names.len != submeshes.len) return error.SizeMismatch;

    const vertex_count: u32 = @intCast(vertices.len / 12);
    const index_count: u32 = @intCast(indices.len);
    const submesh_count: u32 = @intCast(submeshes.len);
    const texture_count: u32 = @intCast(textures.len);
    const bvh_node_count: u32 = @intCast(bvh_nodes.len);
    const name_count: u32 = @intCast(names.len);

    // Layout: header(56) → submesh_table → tex_table → [align16] → vertices →
    //   [align4] → indices → [align4] → tex_blob → [align16] → bvh_nodes →
    //   tri_perm → [align4] → name_table → name_blob
    const submesh_table_off: u32 = header_size;
    const tex_table_off: u32 = submesh_table_off + submesh_count * submesh_size;
    const after_tex_table: u32 = tex_table_off + texture_count * tex_entry_size;
    const vertex_off: u32 = alignUp(after_tex_table, 16);
    const vertex_bytes: u32 = vertex_count * vertex_stride;
    const after_vertices: u32 = vertex_off + vertex_bytes;
    const index_off: u32 = alignUp(after_vertices, 4);
    const index_bytes: u32 = index_count * 2;
    const after_indices: u32 = index_off + index_bytes;
    const tex_data_off: u32 = alignUp(after_indices, 4);

    // Compute total texture blob size
    var tex_blob_size: u32 = 0;
    for (textures) |t| {
        tex_blob_size += @intCast(t.rgba.len);
    }
    const after_tex_blob: u32 = tex_data_off + tex_blob_size;

    // BVH section (nodes 16-aligned, then tri_perm contiguous → 4-aligned).
    const bvh_bytes: u32 = bvh_node_count * bvh.node_size;
    const tri_perm_bytes: u32 = @as(u32, @intCast(tri_perm.len)) * 4;
    const bvh_off: u32 = if (bvh_node_count == 0) 0 else alignUp(after_tex_blob, 16);
    const after_bvh: u32 = if (bvh_node_count == 0)
        after_tex_blob
    else
        bvh_off + bvh_bytes + tri_perm_bytes;

    // Name table (4-aligned), then name blob.
    const name_table_off: u32 = if (name_count == 0) 0 else alignUp(after_bvh, 4);
    const name_table_bytes: u32 = name_count * name_entry_size;
    const name_blob_off: u32 = if (name_count == 0) after_bvh else name_table_off + name_table_bytes;
    var name_blob_size: u32 = 0;
    for (names) |nm| name_blob_size += @intCast(nm.len);

    const total_size: u32 = if (name_count == 0) after_bvh else name_blob_off + name_blob_size;
    const buf = try alloc.alloc(u8, total_size);
    @memset(buf, 0);

    // Write header
    @memcpy(buf[0..4], magic);
    std.mem.writeInt(u32, buf[4..8], version, .little);
    std.mem.writeInt(u32, buf[8..12], vertex_count, .little);
    std.mem.writeInt(u32, buf[12..16], index_count, .little);
    std.mem.writeInt(u32, buf[16..20], submesh_count, .little);
    std.mem.writeInt(u32, buf[20..24], texture_count, .little);
    std.mem.writeInt(u32, buf[24..28], vertex_off, .little);
    std.mem.writeInt(u32, buf[28..32], index_off, .little);
    std.mem.writeInt(u32, buf[32..36], tex_table_off, .little);
    std.mem.writeInt(u32, buf[36..40], tex_data_off, .little);
    std.mem.writeInt(u32, buf[40..44], bvh_off, .little);
    std.mem.writeInt(u32, buf[44..48], bvh_node_count, .little);
    std.mem.writeInt(u32, buf[48..52], name_table_off, .little);
    std.mem.writeInt(u32, buf[52..56], name_count, .little);

    // Write submesh table @40
    for (submeshes, 0..) |s, i| {
        const off: u32 = submesh_table_off + @as(u32, @intCast(i)) * submesh_size;
        // @0: index_byte_off, @4: index_count
        std.mem.writeInt(u32, buf[off..][0..4], s.index_byte_off, .little);
        std.mem.writeInt(u32, buf[off + 4 ..][0..4], s.index_count, .little);
        // @8: base_color f32×4
        std.mem.writeInt(u32, buf[off + 8 ..][0..4], @bitCast(s.base_color[0]), .little);
        std.mem.writeInt(u32, buf[off + 12 ..][0..4], @bitCast(s.base_color[1]), .little);
        std.mem.writeInt(u32, buf[off + 16 ..][0..4], @bitCast(s.base_color[2]), .little);
        std.mem.writeInt(u32, buf[off + 20 ..][0..4], @bitCast(s.base_color[3]), .little);
        // @24: metallic, @28: roughness
        std.mem.writeInt(u32, buf[off + 24 ..][0..4], @bitCast(s.metallic), .little);
        std.mem.writeInt(u32, buf[off + 28 ..][0..4], @bitCast(s.roughness), .little);
        // @32: emissive f32×3
        std.mem.writeInt(u32, buf[off + 32 ..][0..4], @bitCast(s.emissive[0]), .little);
        std.mem.writeInt(u32, buf[off + 36 ..][0..4], @bitCast(s.emissive[1]), .little);
        std.mem.writeInt(u32, buf[off + 40 ..][0..4], @bitCast(s.emissive[2]), .little);
        // @44: occlusion_strength, @48: normal_scale
        std.mem.writeInt(u32, buf[off + 44 ..][0..4], @bitCast(s.occlusion_strength), .little);
        std.mem.writeInt(u32, buf[off + 48 ..][0..4], @bitCast(s.normal_scale), .little);
        // @52..@68: five tex indices (i32)
        std.mem.writeInt(i32, buf[off + 52 ..][0..4], s.tex_base, .little);
        std.mem.writeInt(i32, buf[off + 56 ..][0..4], s.tex_mr, .little);
        std.mem.writeInt(i32, buf[off + 60 ..][0..4], s.tex_normal, .little);
        std.mem.writeInt(i32, buf[off + 64 ..][0..4], s.tex_emissive, .little);
        std.mem.writeInt(i32, buf[off + 68 ..][0..4], s.tex_occlusion, .little);
    }

    // Write texture table
    var tex_blob_cursor: u32 = 0;
    for (textures, 0..) |t, i| {
        const off: u32 = tex_table_off + @as(u32, @intCast(i)) * tex_entry_size;
        const data_len: u32 = @intCast(t.rgba.len);
        std.mem.writeInt(u32, buf[off..][0..4], t.width, .little);
        std.mem.writeInt(u32, buf[off + 4 ..][0..4], t.height, .little);
        std.mem.writeInt(u32, buf[off + 8 ..][0..4], tex_blob_cursor, .little);
        std.mem.writeInt(u32, buf[off + 12 ..][0..4], data_len, .little);
        tex_blob_cursor += data_len;
    }

    // Write vertex data
    const verts_bytes = std.mem.sliceAsBytes(vertices);
    @memcpy(buf[vertex_off..][0..verts_bytes.len], verts_bytes);

    // Write index data
    const idx_bytes = std.mem.sliceAsBytes(indices);
    @memcpy(buf[index_off..][0..idx_bytes.len], idx_bytes);

    // Write texture blob
    var blob_off: u32 = tex_data_off;
    for (textures) |t| {
        @memcpy(buf[blob_off..][0..t.rgba.len], t.rgba);
        blob_off += @intCast(t.rgba.len);
    }

    // Write BVH nodes + tri_perm.
    if (bvh_node_count > 0) {
        const node_bytes = std.mem.sliceAsBytes(bvh_nodes);
        @memcpy(buf[bvh_off..][0..node_bytes.len], node_bytes);
        const perm_bytes = std.mem.sliceAsBytes(tri_perm);
        @memcpy(buf[bvh_off + bvh_bytes ..][0..perm_bytes.len], perm_bytes);
    }

    // Write name table + name blob (entry blob_off is ABSOLUTE).
    if (name_count > 0) {
        var nb_cursor: u32 = name_blob_off;
        for (names, 0..) |nm, i| {
            const off: u32 = name_table_off + @as(u32, @intCast(i)) * name_entry_size;
            const len: u32 = @intCast(nm.len);
            std.mem.writeInt(u32, buf[off..][0..4], fnv1a32(nm), .little);
            std.mem.writeInt(u32, buf[off + 4 ..][0..4], nb_cursor, .little);
            std.mem.writeInt(u32, buf[off + 8 ..][0..4], len, .little);
            @memcpy(buf[nb_cursor..][0..nm.len], nm);
            nb_cursor += len;
        }
    }

    return buf;
}

fn alignUp(x: u32, alignment: u32) u32 {
    return (x + alignment - 1) & ~(alignment - 1);
}

/// Freestanding-safe zero-copy view over a .vmesh byte buffer.
/// Validates magic/version/bounds; all slices point into `bytes`.
pub const Reader = struct {
    vertex_count: u32,
    index_count: u32,
    vertices: []const u8, // raw, GPU-uploadable
    indices: []const u8,
    submeshes: []const u8, // raw table; use submesh(i)
    submesh_count: u32,
    tex_count: u32,
    bvh_node_count: u32,
    bvh_nodes: []const u8, // raw 32B-per-node run (feed bvh.nodesFromBytes)
    tri_perm: []const u8, // raw u32 run (feed bvh.triPermFromBytes)
    name_count: u32,
    names: []const u8, // raw name table (name_count × 12B); use name(i)
    bytes: []const u8,

    pub fn init(bytes: []const u8) error{ BadMagic, BadVersion, Truncated }!Reader {
        if (bytes.len < header_size) return error.Truncated;
        if (!std.mem.eql(u8, bytes[0..4], magic)) return error.BadMagic;
        const ver = std.mem.readInt(u32, bytes[4..8], .little);
        if (ver != version) return error.BadVersion;

        const vertex_count = std.mem.readInt(u32, bytes[8..12], .little);
        const index_count = std.mem.readInt(u32, bytes[12..16], .little);
        const sub_count = std.mem.readInt(u32, bytes[16..20], .little);
        const tex_count = std.mem.readInt(u32, bytes[20..24], .little);
        const vertex_off = std.mem.readInt(u32, bytes[24..28], .little);
        const index_off = std.mem.readInt(u32, bytes[28..32], .little);
        const tex_table_off = std.mem.readInt(u32, bytes[32..36], .little);
        const tex_data_off = std.mem.readInt(u32, bytes[36..40], .little);
        const bvh_off = std.mem.readInt(u32, bytes[40..44], .little);
        const bvh_node_count = std.mem.readInt(u32, bytes[44..48], .little);
        const name_table_off = std.mem.readInt(u32, bytes[48..52], .little);
        const name_count = std.mem.readInt(u32, bytes[52..56], .little);

        const blen: u64 = bytes.len;

        // Bounds-check vertex data (u64 to prevent u32 multiply wrap)
        const need_verts: u64 = @as(u64, vertex_count) * @as(u64, vertex_stride);
        if (@as(u64, vertex_off) > blen or need_verts > blen - @as(u64, vertex_off)) return error.Truncated;
        const vertex_bytes: usize = @intCast(need_verts);

        // Bounds-check index data (u64 to prevent u32 multiply wrap)
        const need_idx: u64 = @as(u64, index_count) * 2;
        if (@as(u64, index_off) > blen or need_idx > blen - @as(u64, index_off)) return error.Truncated;
        const index_bytes: usize = @intCast(need_idx);

        // Bounds-check submesh table (u64 to prevent u32 multiply wrap)
        const need_subs: u64 = @as(u64, sub_count) * @as(u64, submesh_size);
        const sub_table_off: u32 = header_size;
        if (@as(u64, sub_table_off) > blen or need_subs > blen - @as(u64, sub_table_off)) return error.Truncated;
        const sub_table_bytes: usize = @intCast(need_subs);

        // Bounds-check texture table (u64 to prevent u32 multiply wrap)
        const need_tex_table: u64 = @as(u64, tex_count) * @as(u64, tex_entry_size);
        if (@as(u64, tex_table_off) > blen or need_tex_table > blen - @as(u64, tex_table_off)) return error.Truncated;

        // Bounds-check each texture entry's header range and blob data (u64 to prevent wrap)
        for (0..tex_count) |i| {
            const entry_off_u64: u64 = @as(u64, tex_table_off) + @as(u64, i) * @as(u64, tex_entry_size);
            if (entry_off_u64 + @as(u64, tex_entry_size) > blen) return error.Truncated;
            const entry_off: usize = @intCast(entry_off_u64);
            const data_off = std.mem.readInt(u32, bytes[entry_off + 8 ..][0..4], .little);
            const data_len = std.mem.readInt(u32, bytes[entry_off + 12 ..][0..4], .little);
            const abs_off_u64: u64 = @as(u64, tex_data_off) + @as(u64, data_off);
            if (abs_off_u64 > blen or @as(u64, data_len) > blen - abs_off_u64) return error.Truncated;
        }

        // ── BVH section ──────────────────────────────────────────────────────
        // bvh_node_count == 0 → empty slices (valid v3 file without picking).
        var bvh_nodes_slice: []const u8 = bytes[0..0];
        var tri_perm_slice: []const u8 = bytes[0..0];
        if (bvh_node_count > 0) {
            // bvh_off==0 only legal when there are no nodes; here count>0.
            if (bvh_off == 0) return error.Truncated;
            if (bvh_off % 16 != 0) return error.Truncated; // 16-aligned section
            // nodes: count*32 (u64 to prevent wrap)
            const need_nodes: u64 = @as(u64, bvh_node_count) * @as(u64, bvh.node_size);
            if (@as(u64, bvh_off) > blen or need_nodes > blen - @as(u64, bvh_off)) return error.Truncated;
            // tri_perm: derived length (index_count/3)*4, immediately after nodes
            const tri_count: u64 = @as(u64, index_count) / 3;
            const need_perm: u64 = tri_count * 4;
            const perm_off_u64: u64 = @as(u64, bvh_off) + need_nodes;
            if (perm_off_u64 > blen or need_perm > blen - perm_off_u64) return error.Truncated;
            bvh_nodes_slice = bytes[bvh_off..][0..@intCast(need_nodes)];
            tri_perm_slice = bytes[@intCast(perm_off_u64)..][0..@intCast(need_perm)];
        }

        // ── Name table ───────────────────────────────────────────────────────
        // Eager bounds on the table itself; per-entry blob bounds checked
        // LAZILY in name(i) (empty-slice fallback, never panics).
        var names_slice: []const u8 = bytes[0..0];
        if (name_count > 0) {
            if (name_table_off == 0) return error.Truncated;
            if (name_table_off % 4 != 0) return error.Truncated; // 4-aligned
            const need_table: u64 = @as(u64, name_count) * @as(u64, name_entry_size);
            if (@as(u64, name_table_off) > blen or need_table > blen - @as(u64, name_table_off)) return error.Truncated;
            names_slice = bytes[name_table_off..][0..@intCast(need_table)];
        }

        return Reader{
            .vertex_count = vertex_count,
            .index_count = index_count,
            .vertices = bytes[vertex_off..][0..vertex_bytes],
            .indices = bytes[index_off..][0..index_bytes],
            .submeshes = bytes[sub_table_off..][0..sub_table_bytes],
            .submesh_count = sub_count,
            .tex_count = tex_count,
            .bvh_node_count = bvh_node_count,
            .bvh_nodes = bvh_nodes_slice,
            .tri_perm = tri_perm_slice,
            .name_count = name_count,
            .names = names_slice,
            .bytes = bytes,
        };
    }

    /// Caller must ensure `i < self.submesh_count`.
    pub fn submesh(self: *const Reader, i: u32) Submesh {
        std.debug.assert(i < self.submesh_count);
        const off = @as(usize, i) * submesh_size; // usize: u32 product could wrap
        const raw = self.submeshes[off..][0..submesh_size];
        return .{
            .index_byte_off = std.mem.readInt(u32, raw[0..4], .little),
            .index_count = std.mem.readInt(u32, raw[4..8], .little),
            .base_color = .{
                @bitCast(std.mem.readInt(u32, raw[8..12], .little)),
                @bitCast(std.mem.readInt(u32, raw[12..16], .little)),
                @bitCast(std.mem.readInt(u32, raw[16..20], .little)),
                @bitCast(std.mem.readInt(u32, raw[20..24], .little)),
            },
            .metallic = @bitCast(std.mem.readInt(u32, raw[24..28], .little)),
            .roughness = @bitCast(std.mem.readInt(u32, raw[28..32], .little)),
            .emissive = .{
                @bitCast(std.mem.readInt(u32, raw[32..36], .little)),
                @bitCast(std.mem.readInt(u32, raw[36..40], .little)),
                @bitCast(std.mem.readInt(u32, raw[40..44], .little)),
            },
            .occlusion_strength = @bitCast(std.mem.readInt(u32, raw[44..48], .little)),
            .normal_scale = @bitCast(std.mem.readInt(u32, raw[48..52], .little)),
            .tex_base = std.mem.readInt(i32, raw[52..56], .little),
            .tex_mr = std.mem.readInt(i32, raw[56..60], .little),
            .tex_normal = std.mem.readInt(i32, raw[60..64], .little),
            .tex_emissive = std.mem.readInt(i32, raw[64..68], .little),
            .tex_occlusion = std.mem.readInt(i32, raw[68..72], .little),
        };
    }

    /// Caller must ensure `i < self.tex_count`.
    pub fn texture(self: *const Reader, i: u32) struct { width: u32, height: u32, rgba: []const u8 } {
        std.debug.assert(i < self.tex_count);
        const tex_table_off = std.mem.readInt(u32, self.bytes[32..36], .little);
        const tex_data_off = std.mem.readInt(u32, self.bytes[36..40], .little);
        const entry_off = @as(usize, tex_table_off) + @as(usize, i) * tex_entry_size;
        const raw = self.bytes[entry_off..][0..tex_entry_size];
        const width = std.mem.readInt(u32, raw[0..4], .little);
        const height = std.mem.readInt(u32, raw[4..8], .little);
        const data_off = std.mem.readInt(u32, raw[8..12], .little);
        const data_len = std.mem.readInt(u32, raw[12..16], .little);
        return .{
            .width = width,
            .height = height,
            .rgba = self.bytes[@as(usize, tex_data_off) + data_off ..][0..data_len],
        };
    }

    /// Submesh name for entry `i`. Returns an empty slice if `i >= name_count`
    /// or the entry's blob range is out of bounds (lazy per-entry bounds check;
    /// never panics on a hostile blob_off/blob_len).
    pub fn name(self: *const Reader, i: u32) []const u8 {
        if (i >= self.name_count) return self.bytes[0..0];
        const off = @as(usize, i) * name_entry_size; // table bounds proven in init
        const raw = self.names[off..][0..name_entry_size];
        const blob_off = std.mem.readInt(u32, raw[4..8], .little); // ABSOLUTE
        const blob_len = std.mem.readInt(u32, raw[8..12], .little);
        const blen: u64 = self.bytes.len;
        const abs: u64 = @as(u64, blob_off);
        if (abs > blen or @as(u64, blob_len) > blen - abs) return self.bytes[0..0];
        return self.bytes[blob_off..][0..blob_len];
    }

    /// First entry whose stored name_hash equals `hash` → submesh index.
    /// Linear scan; null if no match.
    pub fn findName(self: *const Reader, hash: u32) ?u32 {
        var i: u32 = 0;
        while (i < self.name_count) : (i += 1) {
            const off = @as(usize, i) * name_entry_size;
            const raw = self.names[off..][0..name_entry_size];
            if (std.mem.readInt(u32, raw[0..4], .little) == hash) return i;
        }
        return null;
    }

    /// FNV-1a-32 of `s` — same hash stored in name entries. Re-export so chunk
    /// code can `reader.nameHash(needle)` without importing the free fn.
    pub fn nameHash(s: []const u8) u32 {
        return fnv1a32(s);
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "round-trip: one submesh (full PBR fields), one texture" {
    // 12 f32/vertex = stride 48: pos3 + normal3 + tangent4 + uv2
    const verts = [_]f32{
        // v0: pos(0,0,0) normal(0,0,1) tangent(1,0,0,1) uv(0,0)
        0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 0, 0,
        // v1: pos(1,0,0) normal(0,0,1) tangent(1,0,0,1) uv(1,0)
        1, 0, 0, 0, 0, 1, 1, 0, 0, 1, 1, 0,
    };
    const idx = [_]u16{ 0, 1, 0 };
    const texels = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255 };
    const subs = [_]Submesh{.{
        .index_byte_off = 0,
        .index_count = 3,
        .base_color = .{ 1, 0.5, 0.25, 1 },
        .metallic = 0.25,
        .roughness = 0.5,
        .emissive = .{ 1.0, 0.5, 0.0 },
        .occlusion_strength = 0.8,
        .normal_scale = 1.0,
        .tex_base = 0,
        .tex_mr = 1,
        .tex_normal = -1,
        .tex_emissive = 2,
        .tex_occlusion = -1,
    }};
    const texs = [_]Texture{.{ .width = 2, .height = 2, .rgba = &texels }};
    const bytes = try pack(testing.allocator, &verts, &idx, &subs, &texs, &.{}, &.{}, &.{});
    defer testing.allocator.free(bytes);

    const r = try Reader.init(bytes);
    try testing.expectEqual(@as(u32, 2), r.vertex_count);
    try testing.expectEqual(@as(u32, 3), r.index_count);
    try testing.expectEqual(@as(u32, 1), r.submesh_count);
    try testing.expectEqual(@as(u32, 0), r.bvh_node_count);
    try testing.expectEqual(@as(u32, 0), r.name_count);

    const s = r.submesh(0);
    try testing.expectEqual(@as(u32, 3), s.index_count);
    try testing.expectApproxEqAbs(@as(f32, 0.25), s.base_color[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.25), s.metallic, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), s.roughness, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), s.emissive[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), s.emissive[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), s.emissive[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.8), s.occlusion_strength, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), s.normal_scale, 1e-6);
    try testing.expectEqual(@as(i32, 0), s.tex_base);
    try testing.expectEqual(@as(i32, 1), s.tex_mr);
    try testing.expectEqual(@as(i32, -1), s.tex_normal);
    try testing.expectEqual(@as(i32, 2), s.tex_emissive);
    try testing.expectEqual(@as(i32, -1), s.tex_occlusion);

    const t = r.texture(0);
    try testing.expectEqual(@as(u32, 2), t.width);
    try testing.expectEqualSlices(u8, &texels, t.rgba);
    // raw vertex bytes round-trip
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&verts), r.vertices);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&idx), r.indices);
}

test "alignment: vertex_off 16-aligned, index/tex 4-aligned" {
    const verts = [_]f32{0} ** 12;
    const idx = [_]u16{0};
    const bytes = try pack(testing.allocator, &verts, &idx, &.{}, &.{}, &.{}, &.{}, &.{});
    defer testing.allocator.free(bytes);
    const vo = std.mem.readInt(u32, bytes[24..28], .little);
    const io = std.mem.readInt(u32, bytes[28..32], .little);
    try testing.expectEqual(@as(u32, 0), vo % 16);
    try testing.expectEqual(@as(u32, 0), io % 4);
}

test "reader rejects hostile counts (u32 overflow)" {
    var buf = [_]u8{0} ** 64;
    @memcpy(buf[0..4], magic);
    std.mem.writeInt(u32, buf[4..8], version, .little);
    std.mem.writeInt(u32, buf[8..12], 0x8000_0000, .little); // vertex_count: *48 wraps
    std.mem.writeInt(u32, buf[24..28], 48, .little); // vertex_off
    try testing.expectError(error.Truncated, Reader.init(&buf));

    std.mem.writeInt(u32, buf[8..12], 0, .little);
    std.mem.writeInt(u32, buf[16..20], 0xFFFF_FFFF, .little); // submesh_count: *72 wraps
    try testing.expectError(error.Truncated, Reader.init(&buf));

    std.mem.writeInt(u32, buf[16..20], 0, .little);
    std.mem.writeInt(u32, buf[20..24], 0xFFFF_FFFF, .little); // texture_count: *16 wraps
    try testing.expectError(error.Truncated, Reader.init(&buf));

    std.mem.writeInt(u32, buf[20..24], 0, .little);
    std.mem.writeInt(u32, buf[12..16], 0x8000_0000, .little); // index_count: *2 wraps to 0
    std.mem.writeInt(u32, buf[28..32], 48, .little); // index_off
    try testing.expectError(error.Truncated, Reader.init(&buf));
}

test "reader rejects bad magic and truncation" {
    var junk = [_]u8{0} ** 64;
    try testing.expectError(error.BadMagic, Reader.init(&junk));
    @memcpy(junk[0..4], magic);
    std.mem.writeInt(u32, junk[4..8], 99, .little);
    try testing.expectError(error.BadVersion, Reader.init(&junk));
    try testing.expectError(error.Truncated, Reader.init(junk[0..10]));
}

test "reader rejects v1 and v2 buffers (BadVersion)" {
    // Build valid-looking old-version buffers (version word = 1, then 2) →
    // both must get BadVersion now that the reader only accepts v3.
    var buf = [_]u8{0} ** 64;
    @memcpy(buf[0..4], magic);
    // zero vertex/index/submesh/tex counts, offsets pointing into buf
    std.mem.writeInt(u32, buf[24..28], 56, .little); // vertex_off
    std.mem.writeInt(u32, buf[28..32], 56, .little); // index_off
    std.mem.writeInt(u32, buf[32..36], 56, .little); // tex_table_off
    std.mem.writeInt(u32, buf[36..40], 56, .little); // tex_data_off

    std.mem.writeInt(u32, buf[4..8], 1, .little); // version = 1 (old)
    try testing.expectError(error.BadVersion, Reader.init(&buf));

    std.mem.writeInt(u32, buf[4..8], 2, .little); // version = 2 (old)
    try testing.expectError(error.BadVersion, Reader.init(&buf));
}

// ── v3 sections: BVH + name table ────────────────────────────────────────────

/// Shared minimal geometry for v3 tests: 2 verts, 3 indices (1 tri).
const v3_verts = [_]f32{
    0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 0, 0,
    1, 0, 0, 0, 0, 1, 1, 0, 0, 1, 1, 0,
};
const v3_idx = [_]u16{ 0, 1, 0 };

test "(a) v3 round-trip: 2 BVH nodes, tri_perm, names" {
    const subs = [_]Submesh{
        .{
            .index_byte_off = 0,
            .index_count = 3,
            .base_color = .{ 1, 1, 1, 1 },
            .metallic = 0,
            .roughness = 1,
            .emissive = .{ 0, 0, 0 },
            .occlusion_strength = 1,
            .normal_scale = 1,
            .tex_base = -1,
            .tex_mr = -1,
            .tex_normal = -1,
            .tex_emissive = -1,
            .tex_occlusion = -1,
        },
        .{
            .index_byte_off = 0,
            .index_count = 0,
            .base_color = .{ 1, 1, 1, 1 },
            .metallic = 0,
            .roughness = 1,
            .emissive = .{ 0, 0, 0 },
            .occlusion_strength = 1,
            .normal_scale = 1,
            .tex_base = -1,
            .tex_mr = -1,
            .tex_normal = -1,
            .tex_emissive = -1,
            .tex_occlusion = -1,
        },
    };
    const nodes = [_]bvh.Node{
        .{ .aabb_min = .{ 0, 0, 0 }, .aabb_max = .{ 1, 1, 0 }, .left_or_first = 0, .count = 0 },
        .{ .aabb_min = .{ 0, 0, 0 }, .aabb_max = .{ 1, 0, 0 }, .left_or_first = 0, .count = 1 },
    };
    const perm = [_]u32{0}; // index_count/3 == 1
    const names = [_][]const u8{ "Cube", "Lid" };

    const bytes = try pack(testing.allocator, &v3_verts, &v3_idx, &subs, &.{}, &nodes, &perm, &names);
    defer testing.allocator.free(bytes);

    const r = try Reader.init(bytes);
    try testing.expectEqual(@as(u32, 2), r.bvh_node_count);

    const nv = bvh.nodesFromBytes(r.bvh_nodes);
    try testing.expectEqual(@as(usize, 2), nv.len);
    try testing.expectEqual(@as(u32, 1), nv[1].count);

    const pv = bvh.triPermFromBytes(r.tri_perm);
    try testing.expectEqual(@as(usize, 1), pv.len);
    try testing.expectEqual(@as(u32, 0), pv[0]);

    try testing.expectEqual(@as(u32, 2), r.name_count);
    try testing.expectEqualStrings("Cube", r.name(0));
    try testing.expectEqualStrings("Lid", r.name(1));
    try testing.expectEqual(@as(?u32, 1), r.findName(Reader.nameHash("Lid")));
    try testing.expectEqual(@as(?u32, 0), r.findName(Reader.nameHash("Cube")));
    try testing.expectEqual(@as(?u32, null), r.findName(0xDEAD_BEEF));
}

test "(b) v3 zero-BVH zero-names → valid, empty slices" {
    const bytes = try pack(testing.allocator, &v3_verts, &v3_idx, &.{}, &.{}, &.{}, &.{}, &.{});
    defer testing.allocator.free(bytes);

    const r = try Reader.init(bytes);
    try testing.expectEqual(@as(u32, 0), r.bvh_node_count);
    try testing.expectEqual(@as(usize, 0), r.bvh_nodes.len);
    try testing.expectEqual(@as(usize, 0), r.tri_perm.len);
    try testing.expectEqual(@as(u32, 0), r.name_count);
    try testing.expectEqual(@as(usize, 0), r.name(0).len); // i >= name_count → empty
    try testing.expectEqual(@as(?u32, null), r.findName(0));
    // header bvh_off / name_table_off both 0 (no sections present)
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, bytes[40..44], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, bytes[48..52], .little));
}

test "(c) v3 section offsets: bvh_off %16==0, name_table_off %4==0" {
    const subs = [_]Submesh{.{
        .index_byte_off = 0,
        .index_count = 3,
        .base_color = .{ 1, 1, 1, 1 },
        .metallic = 0,
        .roughness = 1,
        .emissive = .{ 0, 0, 0 },
        .occlusion_strength = 1,
        .normal_scale = 1,
        .tex_base = -1,
        .tex_mr = -1,
        .tex_normal = -1,
        .tex_emissive = -1,
        .tex_occlusion = -1,
    }};
    const nodes = [_]bvh.Node{
        .{ .aabb_min = .{ 0, 0, 0 }, .aabb_max = .{ 1, 1, 0 }, .left_or_first = 0, .count = 1 },
    };
    const perm = [_]u32{0};
    const names = [_][]const u8{"Solo"};
    const bytes = try pack(testing.allocator, &v3_verts, &v3_idx, &subs, &.{}, &nodes, &perm, &names);
    defer testing.allocator.free(bytes);

    const bvh_off = std.mem.readInt(u32, bytes[40..44], .little);
    const name_table_off = std.mem.readInt(u32, bytes[48..52], .little);
    try testing.expectEqual(@as(u32, 0), bvh_off % 16);
    try testing.expectEqual(@as(u32, 0), name_table_off % 4);
}

test "(d) v3 hostile sections → Truncated / empty (no panic)" {
    // Start from a valid zero-section v3 file, then corrupt the header.
    const base = try pack(testing.allocator, &v3_verts, &v3_idx, &.{}, &.{}, &.{}, &.{}, &.{});
    defer testing.allocator.free(base);

    // bvh_node_count *32 wraps u32.
    {
        const buf = try testing.allocator.dupe(u8, base);
        defer testing.allocator.free(buf);
        std.mem.writeInt(u32, buf[44..48], 0x1000_0000, .little); // *32 == 0 (wrap)
        std.mem.writeInt(u32, buf[40..44], 16, .little); // some bvh_off
        try testing.expectError(error.Truncated, Reader.init(buf));
    }
    // name_count *12 wraps / overflows file.
    {
        const buf = try testing.allocator.dupe(u8, base);
        defer testing.allocator.free(buf);
        std.mem.writeInt(u32, buf[52..56], 0x2000_0000, .little);
        std.mem.writeInt(u32, buf[48..52], 56, .little); // some table off
        try testing.expectError(error.Truncated, Reader.init(buf));
    }
    // bvh_off past EOF.
    {
        const buf = try testing.allocator.dupe(u8, base);
        defer testing.allocator.free(buf);
        std.mem.writeInt(u32, buf[44..48], 1, .little);
        std.mem.writeInt(u32, buf[40..44], @intCast(buf.len + 16), .little);
        try testing.expectError(error.Truncated, Reader.init(buf));
    }
    // misaligned bvh_off (8, not 16-aligned).
    {
        const buf = try testing.allocator.dupe(u8, base);
        defer testing.allocator.free(buf);
        std.mem.writeInt(u32, buf[44..48], 1, .little);
        std.mem.writeInt(u32, buf[40..44], 8, .little);
        try testing.expectError(error.Truncated, Reader.init(buf));
    }
    // Name entry blob_off past EOF → name(i) returns empty (no panic).
    {
        // Pack a valid 1-name file, then corrupt the entry's blob_off.
        const subs = [_]Submesh{.{
            .index_byte_off = 0,
            .index_count = 3,
            .base_color = .{ 1, 1, 1, 1 },
            .metallic = 0,
            .roughness = 1,
            .emissive = .{ 0, 0, 0 },
            .occlusion_strength = 1,
            .normal_scale = 1,
            .tex_base = -1,
            .tex_mr = -1,
            .tex_normal = -1,
            .tex_emissive = -1,
            .tex_occlusion = -1,
        }};
        const names = [_][]const u8{"X"};
        const buf = try pack(testing.allocator, &v3_verts, &v3_idx, &subs, &.{}, &.{}, &.{}, &names);
        defer testing.allocator.free(buf);
        const r0 = try Reader.init(buf);
        try testing.expectEqualStrings("X", r0.name(0)); // sanity: valid first
        const nto = std.mem.readInt(u32, buf[48..52], .little);
        std.mem.writeInt(u32, buf[nto + 4 ..][0..4], @intCast(buf.len + 100), .little); // blob_off past EOF
        const r = try Reader.init(buf); // init must still succeed (lazy per-entry)
        try testing.expectEqual(@as(usize, 0), r.name(0).len); // empty, no panic
    }
}

test "(f) v3 SizeMismatch: bad tri_perm len; names len mismatch" {
    const subs = [_]Submesh{
        .{
            .index_byte_off = 0,
            .index_count = 3,
            .base_color = .{ 1, 1, 1, 1 },
            .metallic = 0,
            .roughness = 1,
            .emissive = .{ 0, 0, 0 },
            .occlusion_strength = 1,
            .normal_scale = 1,
            .tex_base = -1,
            .tex_mr = -1,
            .tex_normal = -1,
            .tex_emissive = -1,
            .tex_occlusion = -1,
        },
        .{
            .index_byte_off = 0,
            .index_count = 0,
            .base_color = .{ 1, 1, 1, 1 },
            .metallic = 0,
            .roughness = 1,
            .emissive = .{ 0, 0, 0 },
            .occlusion_strength = 1,
            .normal_scale = 1,
            .tex_base = -1,
            .tex_mr = -1,
            .tex_normal = -1,
            .tex_emissive = -1,
            .tex_occlusion = -1,
        },
    };
    const nodes = [_]bvh.Node{
        .{ .aabb_min = .{ 0, 0, 0 }, .aabb_max = .{ 1, 1, 0 }, .left_or_first = 0, .count = 1 },
    };
    // tri_perm must be index_count/3 == 1; give it 2 → SizeMismatch.
    const bad_perm = [_]u32{ 0, 1 };
    try testing.expectError(error.SizeMismatch, pack(testing.allocator, &v3_verts, &v3_idx, &subs, &.{}, &nodes, &bad_perm, &.{}));

    // names.len == 1 with 2 submeshes → SizeMismatch.
    const one_name = [_][]const u8{"only"};
    try testing.expectError(error.SizeMismatch, pack(testing.allocator, &v3_verts, &v3_idx, &subs, &.{}, &.{}, &.{}, &one_name));
}
