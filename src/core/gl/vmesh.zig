//! .vmesh packed asset format v6 — writer + freestanding reader.
//!
//! Invariant: the byte buffer handed to `Reader.init` must itself be at least
//! 4-byte aligned (the asset region provides 16) — section offsets only
//! preserve alignment relative to the buffer base, and
//! `bvh.nodesFromBytes`/`triPermFromBytes` assert on the absolute pointer.
//!
//! Header layout (72 bytes, all integers little-endian u32):
//!   [0..4]   magic "VMSH"
//!   [4..8]   version u32 = 6
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
//!   [56..60] skinned u32 (0 = non-skinned stride 48; 1 = skinned stride 56)
//!   [60..64] skeleton_off (16-aligned; 0 allowed ONLY if joint_count == 0)
//!   [64..68] joint_count
//!   [68..72] anim_off (16-aligned; 0 = no animation clip)
//! submesh table @68, submesh_count × 72 bytes:
//!   index_byte_off u32 @0, index_count u32 @4,
//!   base_color f32×4 @8, metallic f32 @24, roughness f32 @28,
//!   emissive f32×3 @32, occlusion_strength f32 @44, normal_scale f32 @48,
//!   tex_base i32 @52, tex_mr i32 @56, tex_normal i32 @60,
//!   tex_emissive i32 @64, tex_occlusion i32 @68
//! texture table @tex_table_off, texture_count × 20 bytes:
//!   width u32, height u32, data_off u32 (into tex blob), data_len u32,
//!   format u32 (Format enum; 0 = raw)
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
//! Vertex layout (stride 48, non-skinned):
//!   pos f32×3 @0, normal f32×3 @12, tangent f32×4 @24 (w=handedness ±1), uv f32×2 @40
//! Skinned vertex layout (stride 56, when header skinned != 0):
//!   …the 48 bytes above, then joints uint8×4 @48, weights unorm8×4 @52.
//!
//! Skeleton section @ skeleton_off (16-aligned), joint_count × 132 bytes:
//!   parent i32 @0, inverse_bind 16f32 @4, bind_local 16f32 @68.

const std = @import("std");
const bvh = @import("bvh.zig");
const command = @import("command.zig");

pub const magic = "VMSH";
pub const version: u32 = 7;
pub const vertex_stride: u32 = 48; // pos f32x3 @0, normal f32x3 @12, tangent f32x4 @24, uv f32x2 @40
pub const skinned_vertex_stride: u32 = 56; // …48, then joints uint8x4 @48, weights unorm8x4 @52
pub const header_size: u32 = 72;
pub const submesh_size: u32 = 72;
pub const tex_entry_size: u32 = 20;
pub const name_entry_size: u32 = 12;
pub const joint_entry_size: u32 = 132; // parent i32 (4) + inverse_bind 16f32 (64) + bind_local 16f32 (64)

/// One skeleton joint. `parent` is an index into the joint array, or -1 for root.
/// Matrices are column-major 4×4 (16 f32), matching the GL command stream.
pub const Joint = struct { parent: i32, inverse_bind: [16]f32, bind_local: [16]f32 };

pub const Track = struct { interp: u8, times: []const f32, values: []const f32 };
pub const Clip = struct { name_hash: u32, duration: f32, tracks: []const Track };
pub const Anims = struct { clips: []const Clip };
pub const ClipInfo = struct { name_hash: u32, duration: f32 };
pub fn animComps(channel: u2) u32 {
    return if (channel == 1) 4 else 3;
}
pub const TrackInfo = struct { interp: u8, key_count: u32, data_off: u32, comps: u32 };
const anim_dir_entry_size: u32 = 12;
const anim_clip_entry_size: u32 = 16;

/// Per-texture pixel encoding. v4: every texture is `.raw` today; the tag is
/// groundwork for compressed/encoded payloads (PNG/JPEG/WebP) in later slices.
pub const Format = enum(u32) { raw = 0, png = 1, jpeg = 2, webp = 3 };

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
    rgba: []const u8, // width*height*4 (raw) or encoded payload bytes
    format: Format = .raw,
};

/// Native-side packer. Caller supplies all arrays; `pack` computes
/// aligned offsets and returns the complete file bytes (alloc-owned).
/// vertices: len % 12 == 0 (the 48-byte base layout = 12 f32/vertex). When
/// `skinned`, joints/weights are NOT in `vertices` — they ride in the parallel
/// `joints`/`weights` arrays (one [4]u8 each per vertex) and `pack` interleaves
/// them into the stride-56 blob.
///
/// `bvh_nodes` + `tri_perm`: either both empty (a file without picking
/// data) or bvh_nodes.len > 0 with tri_perm.len == indices.len/3.
/// `names`: len 0 (no names) or == submeshes.len; index ↔ submesh index.
///
/// Skin inputs: when `skinned` is false the mesh is byte-identical to a
/// non-skinned file (stride 48, no skeleton, header skinned=0) — `joints`,
/// `weights`, `skel` must be empty. When `skinned` is true, `joints.len` and
/// `weights.len` must == vertex_count and `skel` carries the skeleton.
pub fn pack(
    alloc: std.mem.Allocator,
    vertices: []const f32, // len % 12 == 0 (48-byte base layout / 4)
    indices: []const u16,
    submeshes: []const Submesh,
    textures: []const Texture,
    bvh_nodes: []const bvh.Node,
    tri_perm: []const u32,
    names: []const []const u8,
    skinned: bool,
    joints: []const [4]u8,
    weights: []const [4]u8,
    skel: []const Joint,
    anim: ?Anims,
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

    // Validate skin coupling: joints/weights are 1:1 with vertices when skinned;
    // all three skin arrays empty when not.
    if (skinned) {
        std.debug.assert(joints.len == vertex_count);
        std.debug.assert(weights.len == vertex_count);
    } else {
        std.debug.assert(joints.len == 0 and weights.len == 0 and skel.len == 0);
    }
    const stride: u32 = if (skinned) skinned_vertex_stride else vertex_stride;
    const joint_count: u32 = @intCast(skel.len);

    const index_count: u32 = @intCast(indices.len);
    const submesh_count: u32 = @intCast(submeshes.len);
    const texture_count: u32 = @intCast(textures.len);
    const bvh_node_count: u32 = @intCast(bvh_nodes.len);
    const name_count: u32 = @intCast(names.len);

    // Layout: header(68) → submesh_table → tex_table → [align16] → vertices →
    //   [align4] → indices → [align4] → tex_blob → [align16] → bvh_nodes →
    //   tri_perm → [align4] → name_table → name_blob → [align16] → skeleton
    const submesh_table_off: u32 = header_size;
    const tex_table_off: u32 = submesh_table_off + submesh_count * submesh_size;
    const after_tex_table: u32 = tex_table_off + texture_count * tex_entry_size;
    const vertex_off: u32 = alignUp(after_tex_table, 16);
    const vertex_bytes: u32 = vertex_count * stride;
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

    const after_names: u32 = if (name_count == 0) after_bvh else name_blob_off + name_blob_size;

    // Skeleton section (16-aligned), joint_count × 132 B. Absent when not skinned.
    const skeleton_off: u32 = if (joint_count == 0) 0 else alignUp(after_names, 16);
    const skeleton_bytes: u32 = joint_count * joint_entry_size;
    const after_skeleton: u32 = if (joint_count == 0) after_names else skeleton_off + skeleton_bytes;

    var anim_total: u32 = 0;
    if (anim) |an| {
        const clip_table: u32 = 8 + @as(u32, @intCast(an.clips.len)) * anim_clip_entry_size;
        var cur: u32 = clip_table;
        for (an.clips) |cl| {
            std.debug.assert(cl.tracks.len == @as(usize, joint_count) * 3);
            cur = alignUp(cur, 4);
            var sect: u32 = joint_count * 3 * anim_dir_entry_size;
            for (cl.tracks, 0..) |tr, ti| {
                const comps = animComps(@intCast(ti % 3));
                const kc: u32 = @intCast(tr.times.len);
                std.debug.assert(tr.values.len == @as(usize, kc) * comps);
                sect += kc * 4 + kc * comps * 4;
            }
            cur += sect;
        }
        anim_total = cur;
    }
    const anim_off: u32 = if (anim == null) 0 else alignUp(after_skeleton, 16);
    const after_anim: u32 = if (anim == null) after_skeleton else anim_off + anim_total;

    const total_size: u32 = after_anim;
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
    std.mem.writeInt(u32, buf[56..60], @intFromBool(skinned), .little);
    std.mem.writeInt(u32, buf[60..64], skeleton_off, .little);
    std.mem.writeInt(u32, buf[64..68], joint_count, .little);
    std.mem.writeInt(u32, buf[68..72], anim_off, .little);

    // Write submesh table @68 (right after the header)
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
        std.mem.writeInt(u32, buf[off + 16 ..][0..4], @intFromEnum(t.format), .little);
        tex_blob_cursor += data_len;
    }

    // Write vertex data. Non-skinned: flat 48-byte stride blob. Skinned: per
    // vertex write the 48 base bytes, then joints[v] (4 B) + weights[v] (4 B).
    if (!skinned) {
        const verts_bytes = std.mem.sliceAsBytes(vertices);
        @memcpy(buf[vertex_off..][0..verts_bytes.len], verts_bytes);
    } else {
        const all_base = std.mem.sliceAsBytes(vertices); // vertex_count × 48 B
        var v: u32 = 0;
        while (v < vertex_count) : (v += 1) {
            const dst = vertex_off + v * stride;
            @memcpy(buf[dst..][0..48], all_base[v * 48 ..][0..48]);
            @memcpy(buf[dst + 48 ..][0..4], &joints[v]);
            @memcpy(buf[dst + 52 ..][0..4], &weights[v]);
        }
    }

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

    // Write skeleton section: parent i32 @0, inverse_bind 16f32 @4, bind_local
    // 16f32 @68 — joint_entry_size (132 B) per joint.
    if (joint_count > 0) {
        for (skel, 0..) |j, i| {
            const off: u32 = skeleton_off + @as(u32, @intCast(i)) * joint_entry_size;
            std.mem.writeInt(i32, buf[off..][0..4], j.parent, .little);
            inline for (0..16) |k| {
                std.mem.writeInt(u32, buf[off + 4 + k * 4 ..][0..4], @bitCast(j.inverse_bind[k]), .little);
                std.mem.writeInt(u32, buf[off + 68 + k * 4 ..][0..4], @bitCast(j.bind_local[k]), .little);
            }
        }
    }

    // Write animation section: clip_count u32 @0, flags u32 @4, clip table @8
    // (clip_count × 16B), then per-clip directory (joint_count*3 × 12B) + blobs.
    if (anim) |an| {
        std.mem.writeInt(u32, buf[anim_off..][0..4], @intCast(an.clips.len), .little);
        std.mem.writeInt(u32, buf[anim_off + 4 ..][0..4], 0, .little);
        const table_off = anim_off + 8;
        var sect_cursor: u32 = 8 + @as(u32, @intCast(an.clips.len)) * anim_clip_entry_size;
        for (an.clips, 0..) |cl, ci| {
            sect_cursor = alignUp(sect_cursor, 4);
            const te = table_off + @as(u32, @intCast(ci)) * anim_clip_entry_size;
            std.mem.writeInt(u32, buf[te..][0..4], cl.name_hash, .little);
            std.mem.writeInt(u32, buf[te + 4 ..][0..4], @bitCast(cl.duration), .little);
            std.mem.writeInt(u32, buf[te + 8 ..][0..4], sect_cursor, .little);
            std.mem.writeInt(u32, buf[te + 12 ..][0..4], 0, .little);
            const dir_off = anim_off + sect_cursor;
            const dir_bytes: u32 = joint_count * 3 * anim_dir_entry_size;
            var blob_cursor: u32 = sect_cursor + dir_bytes;
            for (cl.tracks, 0..) |tr, ti| {
                const comps = animComps(@intCast(ti % 3));
                const kc: u32 = @intCast(tr.times.len);
                const e = dir_off + @as(u32, @intCast(ti)) * anim_dir_entry_size;
                buf[e] = tr.interp;
                buf[e + 1] = 0;
                buf[e + 2] = 0;
                buf[e + 3] = 0;
                std.mem.writeInt(u32, buf[e + 4 ..][0..4], kc, .little);
                std.mem.writeInt(u32, buf[e + 8 ..][0..4], blob_cursor, .little);
                var k: u32 = 0;
                while (k < kc) : (k += 1)
                    std.mem.writeInt(u32, buf[anim_off + blob_cursor + k * 4 ..][0..4], @bitCast(tr.times[k]), .little);
                const vbase = anim_off + blob_cursor + kc * 4;
                var vi: u32 = 0;
                while (vi < kc * comps) : (vi += 1)
                    std.mem.writeInt(u32, buf[vbase + vi * 4 ..][0..4], @bitCast(tr.values[vi]), .little);
                blob_cursor += kc * 4 + kc * comps * 4;
            }
            sect_cursor = blob_cursor;
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
    skinned: bool,
    joint_count_: u32,
    anim_off_: u32,
    bytes: []const u8,

    pub fn init(bytes: []const u8) error{ BadMagic, BadVersion, Truncated, BadTexIndex }!Reader {
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
        const skinned = std.mem.readInt(u32, bytes[56..60], .little) != 0;
        const skeleton_off = std.mem.readInt(u32, bytes[60..64], .little);
        const joint_count = std.mem.readInt(u32, bytes[64..68], .little);
        const anim_off = std.mem.readInt(u32, bytes[68..72], .little);

        const blen: u64 = bytes.len;

        // Bounds-check vertex data (u64 to prevent u32 multiply wrap). Skinned
        // meshes use the wider stride-56 layout.
        const stride: u64 = if (skinned) @as(u64, skinned_vertex_stride) else @as(u64, vertex_stride);
        const need_verts: u64 = @as(u64, vertex_count) * stride;
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

        // Validate every submesh's five texture indices: each must be the
        // missing-sentinel (-1) or a real index in [0, tex_count). A hostile or
        // corrupt file would otherwise reach the GL bind path with an
        // out-of-range handle (the island `texHandle` clamp is the last line of
        // defense — reject here so a bad asset fails at parse, not at draw).
        const tex_lim: i64 = @as(i64, tex_count);
        for (0..sub_count) |i| {
            const off = sub_table_off + @as(u64, @intCast(i)) * submesh_size + 52; // first tex i32 @52
            inline for (0..5) |k| {
                const idx = std.mem.readInt(i32, bytes[@intCast(off + k * 4)..][0..4], .little);
                if (idx < -1 or @as(i64, idx) >= tex_lim) return error.BadTexIndex;
            }
        }

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

        // ── Skeleton section ─────────────────────────────────────────────────
        // joint_count == 0 → no skeleton (every non-skinned file). When skinned
        // with joints present, validate the section fits + is 16-aligned.
        if (joint_count > 0) {
            if (skeleton_off == 0) return error.Truncated;
            if (skeleton_off % 16 != 0) return error.Truncated;
            const need_skel: u64 = @as(u64, joint_count) * @as(u64, joint_entry_size);
            if (@as(u64, skeleton_off) > blen or need_skel > blen - @as(u64, skeleton_off)) return error.Truncated;
        }

        // ── Animation section ────────────────────────────────────────────────
        // anim_off == 0 → no clip. When present, validate the section header +
        // directory fit, then each track's time+value blob is in bounds.
        if (anim_off != 0) {
            if (anim_off % 16 != 0) return error.Truncated;
            if (@as(u64, anim_off) + 8 > blen) return error.Truncated;
            const clip_count = std.mem.readInt(u32, bytes[anim_off..][0..4], .little);
            const table_end: u64 = @as(u64, anim_off) + 8 + @as(u64, clip_count) * anim_clip_entry_size;
            if (table_end > blen) return error.Truncated;
            var ci: u32 = 0;
            while (ci < clip_count) : (ci += 1) {
                const te: usize = @intCast(@as(u64, anim_off) + 8 + @as(u64, ci) * anim_clip_entry_size);
                const dir_off: u64 = std.mem.readInt(u32, bytes[te + 8 ..][0..4], .little);
                const dir_bytes: u64 = @as(u64, joint_count) * 3 * anim_dir_entry_size;
                const dir_end: u64 = @as(u64, anim_off) + dir_off + dir_bytes;
                if (dir_end > blen) return error.Truncated;
                var ti: u32 = 0;
                while (ti < joint_count * 3) : (ti += 1) {
                    const comps: u64 = if (ti % 3 == 1) 4 else 3;
                    const e: usize = @intCast(@as(u64, anim_off) + dir_off + @as(u64, ti) * anim_dir_entry_size);
                    const kc: u64 = std.mem.readInt(u32, bytes[e + 4 ..][0..4], .little);
                    const data_off: u64 = std.mem.readInt(u32, bytes[e + 8 ..][0..4], .little);
                    const need: u64 = kc * 4 + kc * comps * 4;
                    const abs: u64 = @as(u64, anim_off) + data_off;
                    if (abs > blen or need > blen - abs) return error.Truncated;
                }
            }
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
            .skinned = skinned,
            .joint_count_ = joint_count,
            .anim_off_ = anim_off,
            .bytes = bytes,
        };
    }

    /// Vertex stride in bytes: 56 when skinned (joints+weights appended), else 48.
    pub fn vertexStride(self: *const Reader) u32 {
        return if (self.skinned) skinned_vertex_stride else vertex_stride;
    }

    /// Number of skeleton joints (header [64..68]). 0 for non-skinned meshes.
    pub fn jointCount(self: *const Reader) u32 {
        return self.joint_count_;
    }

    /// Skeleton joint `i`. Caller must ensure `i < self.jointCount()`.
    pub fn joint(self: *const Reader, i: u32) Joint {
        std.debug.assert(i < self.joint_count_);
        const skeleton_off = std.mem.readInt(u32, self.bytes[60..64], .little);
        const off = @as(usize, skeleton_off) + @as(usize, i) * joint_entry_size;
        const raw = self.bytes[off..][0..joint_entry_size];
        var j: Joint = .{ .parent = std.mem.readInt(i32, raw[0..4], .little), .inverse_bind = undefined, .bind_local = undefined };
        inline for (0..16) |k| {
            j.inverse_bind[k] = @bitCast(std.mem.readInt(u32, raw[4 + k * 4 ..][0..4], .little));
            j.bind_local[k] = @bitCast(std.mem.readInt(u32, raw[68 + k * 4 ..][0..4], .little));
        }
        return j;
    }

    /// True when the file carries a baked animation clip (header anim_off != 0).
    pub fn animPresent(self: *const Reader) bool {
        return self.anim_off_ != 0;
    }

    /// Number of animation clips in the clip table. 0 when no anim present.
    pub fn animClipCount(self: *const Reader) u32 {
        if (self.anim_off_ == 0) return 0;
        return std.mem.readInt(u32, self.bytes[self.anim_off_..][0..4], .little);
    }

    /// Clip table entry `i`: name_hash + duration. Caller must ensure
    /// `i < animClipCount()`.
    pub fn animClip(self: *const Reader, i: u32) ClipInfo {
        const te = @as(usize, self.anim_off_) + 8 + @as(usize, i) * anim_clip_entry_size;
        return .{
            .name_hash = std.mem.readInt(u32, self.bytes[te..][0..4], .little),
            .duration = @bitCast(std.mem.readInt(u32, self.bytes[te + 4 ..][0..4], .little)),
        };
    }

    /// Directory entry for clip `clip`, joint `j`, channel `c` (0=T,1=R,2=S).
    /// Caller must ensure `clip < animClipCount()` and `j < jointCount()`.
    pub fn animTrack(self: *const Reader, clip: u32, j: u32, c: u2) TrackInfo {
        const te = @as(usize, self.anim_off_) + 8 + @as(usize, clip) * anim_clip_entry_size;
        const dir_off = std.mem.readInt(u32, self.bytes[te + 8 ..][0..4], .little);
        const idx = j * 3 + @as(u32, c);
        const e = @as(usize, self.anim_off_) + dir_off + @as(usize, idx) * anim_dir_entry_size;
        return .{
            .interp = self.bytes[e],
            .key_count = std.mem.readInt(u32, self.bytes[e + 4 ..][0..4], .little),
            .data_off = std.mem.readInt(u32, self.bytes[e + 8 ..][0..4], .little),
            .comps = animComps(c),
        };
    }

    /// Keyframe `i` time of track `t`. Caller must ensure `i < t.key_count`.
    pub fn animTime(self: *const Reader, t: TrackInfo, i: u32) f32 {
        const off = @as(usize, self.anim_off_) + t.data_off + @as(usize, i) * 4;
        return @bitCast(std.mem.readInt(u32, self.bytes[off..][0..4], .little));
    }

    /// Component `comp` of keyframe `i` value of track `t`. Caller must ensure
    /// `i < t.key_count` and `comp < t.comps`.
    pub fn animValue(self: *const Reader, t: TrackInfo, i: u32, comp: u32) f32 {
        const vbase = @as(usize, self.anim_off_) + t.data_off + @as(usize, t.key_count) * 4;
        const off = vbase + (@as(usize, i) * t.comps + comp) * 4;
        return @bitCast(std.mem.readInt(u32, self.bytes[off..][0..4], .little));
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
    pub fn texture(self: *const Reader, i: u32) struct { width: u32, height: u32, rgba: []const u8, format: Format } {
        std.debug.assert(i < self.tex_count);
        const tex_table_off = std.mem.readInt(u32, self.bytes[32..36], .little);
        const tex_data_off = std.mem.readInt(u32, self.bytes[36..40], .little);
        const entry_off = @as(usize, tex_table_off) + @as(usize, i) * tex_entry_size;
        const raw = self.bytes[entry_off..][0..tex_entry_size];
        const width = std.mem.readInt(u32, raw[0..4], .little);
        const height = std.mem.readInt(u32, raw[4..8], .little);
        const data_off = std.mem.readInt(u32, raw[8..12], .little);
        const data_len = std.mem.readInt(u32, raw[12..16], .little);
        const fmt = std.mem.readInt(u32, raw[16..20], .little);
        return .{
            .width = width,
            .height = height,
            .rgba = self.bytes[@as(usize, tex_data_off) + data_off ..][0..data_len],
            .format = @enumFromInt(fmt),
        };
    }

    /// Pixel-encoding tag for texture `i`. Caller must ensure `i < self.tex_count`.
    pub fn texFormat(self: *const Reader, i: u32) Format {
        std.debug.assert(i < self.tex_count);
        const tex_table_off = std.mem.readInt(u32, self.bytes[32..36], .little);
        const entry_off = @as(usize, tex_table_off) + @as(usize, i) * tex_entry_size;
        const raw = self.bytes[entry_off..][0..tex_entry_size];
        return @enumFromInt(std.mem.readInt(u32, raw[16..20], .little));
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

    /// True if texture `tex_index` is used as a base-color or emissive map by
    /// any submesh (→ sRGB color space; the chunk uploads it via
    /// `CREATE_TEXTURE_SRGB`). metallic-roughness / normal / occlusion maps are
    /// linear. A texture used in both contexts resolves to sRGB (base/emissive
    /// wins) — harmless in practice (real assets keep color and data maps
    /// distinct; the shared neutral white is identity in either space).
    pub fn texIsSrgb(self: *const Reader, tex_index: u32) bool {
        const ti: i32 = @intCast(tex_index);
        var s: u32 = 0;
        while (s < self.submesh_count) : (s += 1) {
            const sub = self.submesh(s);
            if (sub.tex_base == ti or sub.tex_emissive == ti) return true;
        }
        return false;
    }

    /// Returns the CREATE_SHADER variant bitset for submesh `s`.
    /// Always sets `variant_pbr`; additionally sets `variant_normal_map` when
    /// the submesh has a normal-map texture (`tex_normal >= 0`) and
    /// `variant_emissive` when it has an emissive texture (`tex_emissive >= 0`).
    /// Caller must ensure `s < self.submesh_count`.
    pub fn submeshVariant(self: *const Reader, s: u32) u32 {
        const sub = self.submesh(s);
        var bits: u32 = command.variant_pbr;
        if (sub.tex_normal >= 0) bits |= command.variant_normal_map;
        if (sub.tex_emissive >= 0) bits |= command.variant_emissive;
        return bits;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

const Mat4Identity = [_]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };

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
    // Three textures so tex indices 0/1/2 are all in range (reader rejects
    // out-of-range now). tex 0 keeps the 2×2 checked below; 1/2 are 1×1 fillers.
    const fill = [_]u8{ 0, 0, 0, 255 };
    const texs = [_]Texture{
        .{ .width = 2, .height = 2, .rgba = &texels },
        .{ .width = 1, .height = 1, .rgba = &fill },
        .{ .width = 1, .height = 1, .rgba = &fill },
    };
    const bytes = try pack(testing.allocator, &verts, &idx, &subs, &texs, &.{}, &.{}, &.{}, false, &.{}, &.{}, &.{}, null);
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
    const bytes = try pack(testing.allocator, &verts, &idx, &.{}, &.{}, &.{}, &.{}, &.{}, false, &.{}, &.{}, &.{}, null);
    defer testing.allocator.free(bytes);
    const vo = std.mem.readInt(u32, bytes[24..28], .little);
    const io = std.mem.readInt(u32, bytes[28..32], .little);
    try testing.expectEqual(@as(u32, 0), vo % 16);
    try testing.expectEqual(@as(u32, 0), io % 4);
}

test "reader rejects hostile counts (u32 overflow)" {
    var buf = [_]u8{0} ** 72;
    @memcpy(buf[0..4], magic);
    std.mem.writeInt(u32, buf[4..8], version, .little);
    std.mem.writeInt(u32, buf[8..12], 0x8000_0000, .little); // vertex_count: *48 wraps
    std.mem.writeInt(u32, buf[24..28], 48, .little); // vertex_off
    try testing.expectError(error.Truncated, Reader.init(&buf));

    std.mem.writeInt(u32, buf[8..12], 0, .little);
    std.mem.writeInt(u32, buf[16..20], 0xFFFF_FFFF, .little); // submesh_count: *72 wraps
    try testing.expectError(error.Truncated, Reader.init(&buf));

    std.mem.writeInt(u32, buf[16..20], 0, .little);
    std.mem.writeInt(u32, buf[20..24], 0xFFFF_FFFF, .little); // texture_count: *20 wraps
    try testing.expectError(error.Truncated, Reader.init(&buf));

    std.mem.writeInt(u32, buf[20..24], 0, .little);
    std.mem.writeInt(u32, buf[12..16], 0x8000_0000, .little); // index_count: *2 wraps to 0
    std.mem.writeInt(u32, buf[28..32], 48, .little); // index_off
    try testing.expectError(error.Truncated, Reader.init(&buf));
}

test "reader rejects bad magic and truncation" {
    var junk = [_]u8{0} ** 72;
    try testing.expectError(error.BadMagic, Reader.init(&junk));
    @memcpy(junk[0..4], magic);
    std.mem.writeInt(u32, junk[4..8], 99, .little);
    try testing.expectError(error.BadVersion, Reader.init(&junk));
    try testing.expectError(error.Truncated, Reader.init(junk[0..10]));
}

test "reader rejects v1 and v2 buffers (BadVersion)" {
    // Build valid-looking old-version buffers (version word = 1, then 2) →
    // both must get BadVersion now that the reader only accepts v6.
    var buf = [_]u8{0} ** 72;
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

    const bytes = try pack(testing.allocator, &v3_verts, &v3_idx, &subs, &.{}, &nodes, &perm, &names, false, &.{}, &.{}, &.{}, null);
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
    const bytes = try pack(testing.allocator, &v3_verts, &v3_idx, &.{}, &.{}, &.{}, &.{}, &.{}, false, &.{}, &.{}, &.{}, null);
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
    const bytes = try pack(testing.allocator, &v3_verts, &v3_idx, &subs, &.{}, &nodes, &perm, &names, false, &.{}, &.{}, &.{}, null);
    defer testing.allocator.free(bytes);

    const bvh_off = std.mem.readInt(u32, bytes[40..44], .little);
    const name_table_off = std.mem.readInt(u32, bytes[48..52], .little);
    try testing.expectEqual(@as(u32, 0), bvh_off % 16);
    try testing.expectEqual(@as(u32, 0), name_table_off % 4);
}

test "(d) v3 hostile sections → Truncated / empty (no panic)" {
    // Start from a valid zero-section v3 file, then corrupt the header.
    const base = try pack(testing.allocator, &v3_verts, &v3_idx, &.{}, &.{}, &.{}, &.{}, &.{}, false, &.{}, &.{}, &.{}, null);
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
        const buf = try pack(testing.allocator, &v3_verts, &v3_idx, &subs, &.{}, &.{}, &.{}, &names, false, &.{}, &.{}, &.{}, null);
        defer testing.allocator.free(buf);
        const r0 = try Reader.init(buf);
        try testing.expectEqualStrings("X", r0.name(0)); // sanity: valid first
        const nto = std.mem.readInt(u32, buf[48..52], .little);
        std.mem.writeInt(u32, buf[nto + 4 ..][0..4], @intCast(buf.len + 100), .little); // blob_off past EOF
        const r = try Reader.init(buf); // init must still succeed (lazy per-entry)
        try testing.expectEqual(@as(usize, 0), r.name(0).len); // empty, no panic
    }
}

test "(h) texIsSrgb: base/emissive → sRGB, mr/normal/occlusion → linear" {
    const texels = [_]u8{ 0, 0, 0, 255 };
    const texs = [_]Texture{
        .{ .width = 1, .height = 1, .rgba = &texels },
        .{ .width = 1, .height = 1, .rgba = &texels },
        .{ .width = 1, .height = 1, .rgba = &texels },
    };
    const subs = [_]Submesh{.{
        .index_byte_off = 0,
        .index_count = 3,
        .base_color = .{ 1, 1, 1, 1 },
        .metallic = 0,
        .roughness = 1,
        .emissive = .{ 0, 0, 0 },
        .occlusion_strength = 1,
        .normal_scale = 1,
        .tex_base = 0, // sRGB
        .tex_mr = 1, // linear
        .tex_normal = -1,
        .tex_emissive = 2, // sRGB
        .tex_occlusion = -1,
    }};
    const bytes = try pack(testing.allocator, &v3_verts, &v3_idx, &subs, &texs, &.{}, &.{}, &.{}, false, &.{}, &.{}, &.{}, null);
    defer testing.allocator.free(bytes);
    const r = try Reader.init(bytes);
    try testing.expect(r.texIsSrgb(0)); // base-color
    try testing.expect(!r.texIsSrgb(1)); // metallic-roughness
    try testing.expect(r.texIsSrgb(2)); // emissive
}

test "(g) v3 rejects out-of-range submesh tex index (BadTexIndex)" {
    // One texture present (tex_count == 1 → only index 0 or sentinel -1 valid).
    const texels = [_]u8{ 255, 0, 0, 255 };
    const texs = [_]Texture{.{ .width = 1, .height = 1, .rgba = &texels }};
    const good = [_]Submesh{.{
        .index_byte_off = 0,
        .index_count = 3,
        .base_color = .{ 1, 1, 1, 1 },
        .metallic = 0,
        .roughness = 1,
        .emissive = .{ 0, 0, 0 },
        .occlusion_strength = 1,
        .normal_scale = 1,
        .tex_base = 0,
        .tex_mr = -1,
        .tex_normal = -1,
        .tex_emissive = -1,
        .tex_occlusion = -1,
    }};
    // Sanity: the in-range version parses fine.
    {
        const bytes = try pack(testing.allocator, &v3_verts, &v3_idx, &good, &texs, &.{}, &.{}, &.{}, false, &.{}, &.{}, &.{}, null);
        defer testing.allocator.free(bytes);
        _ = try Reader.init(bytes);
    }
    // tex index == tex_count (1) → out of range → reject.
    {
        const bytes = try pack(testing.allocator, &v3_verts, &v3_idx, &good, &texs, &.{}, &.{}, &.{}, false, &.{}, &.{}, &.{}, null);
        defer testing.allocator.free(bytes);
        std.mem.writeInt(i32, bytes[header_size + 56 ..][0..4], 1, .little); // tex_mr @56
        try testing.expectError(error.BadTexIndex, Reader.init(bytes));
    }
    // tex index < -1 (e.g. -2, not the missing-sentinel) → reject.
    {
        const bytes = try pack(testing.allocator, &v3_verts, &v3_idx, &good, &texs, &.{}, &.{}, &.{}, false, &.{}, &.{}, &.{}, null);
        defer testing.allocator.free(bytes);
        std.mem.writeInt(i32, bytes[header_size + 52 ..][0..4], -2, .little); // tex_base @52
        try testing.expectError(error.BadTexIndex, Reader.init(bytes));
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
    try testing.expectError(error.SizeMismatch, pack(testing.allocator, &v3_verts, &v3_idx, &subs, &.{}, &nodes, &bad_perm, &.{}, false, &.{}, &.{}, &.{}, null));

    // names.len == 1 with 2 submeshes → SizeMismatch.
    const one_name = [_][]const u8{"only"};
    try testing.expectError(error.SizeMismatch, pack(testing.allocator, &v3_verts, &v3_idx, &subs, &.{}, &.{}, &.{}, &one_name, false, &.{}, &.{}, &.{}, null));
}

// ── submeshVariant ────────────────────────────────────────────────────────────

test "(i) submeshVariant: all four tex_normal × tex_emissive combinations" {
    // Two textures so any non-negative tex index in [0,1] is valid.
    const texels = [_]u8{ 0, 0, 0, 255 };
    const texs = [_]Texture{
        .{ .width = 1, .height = 1, .rgba = &texels },
        .{ .width = 1, .height = 1, .rgba = &texels },
    };

    // Helper closure: build a minimal Submesh with given tex_normal/tex_emissive.
    const make = struct {
        fn sub(tn: i32, te: i32) Submesh {
            return .{
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
                .tex_normal = tn,
                .tex_emissive = te,
                .tex_occlusion = -1,
            };
        }
    }.sub;

    // Four submeshes covering all (normal, emissive) combinations.
    const subs = [_]Submesh{
        make(0, 1), // both present
        make(0, -1), // normal only
        make(-1, 1), // emissive only
        make(-1, -1), // neither
    };

    const bytes = try pack(testing.allocator, &v3_verts, &v3_idx, &subs, &texs, &.{}, &.{}, &.{}, false, &.{}, &.{}, &.{}, null);
    defer testing.allocator.free(bytes);
    const r = try Reader.init(bytes);

    const pbr = command.variant_pbr;
    const nm = command.variant_normal_map;
    const em = command.variant_emissive;

    // both maps present → pbr | normal_map | emissive
    try testing.expectEqual(pbr | nm | em, r.submeshVariant(0));
    // normal present, emissive = -1 → pbr | normal_map
    try testing.expectEqual(pbr | nm, r.submeshVariant(1));
    // emissive present, normal = -1 → pbr | emissive
    try testing.expectEqual(pbr | em, r.submeshVariant(2));
    // both = -1 → pbr only
    try testing.expectEqual(pbr, r.submeshVariant(3));
}

// ── v5 skinning: skinned vertex stride + skeleton section ──────────────────────

test "(j) v5 skinned round-trip: stride 56, 2-joint skeleton" {
    // 2 vertices, base layout 12 f32 each (the 48-byte block); joints/weights
    // ride in the parallel arrays and `pack` interleaves them at @48/@52.
    const verts = [_]f32{
        0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 0, 0,
        1, 0, 0, 0, 0, 1, 1, 0, 0, 1, 1, 0,
    };
    const idx = [_]u16{ 0, 1, 0 };
    const joints = [_][4]u8{ .{ 0, 1, 0, 0 }, .{ 1, 0, 0, 0 } };
    const weights = [_][4]u8{ .{ 200, 55, 0, 0 }, .{ 255, 0, 0, 0 } };
    const skel = [_]Joint{
        .{ .parent = -1, .inverse_bind = [_]f32{0} ** 16, .bind_local = [_]f32{1} ** 16 },
        .{
            .parent = 0,
            .inverse_bind = blk: {
                var m = [_]f32{0} ** 16;
                m[12] = 2.5; // a translation component to prove float round-trip
                break :blk m;
            },
            .bind_local = [_]f32{0} ** 16,
        },
    };

    const bytes = try pack(testing.allocator, &verts, &idx, &.{}, &.{}, &.{}, &.{}, &.{}, true, &joints, &weights, &skel, null);
    defer testing.allocator.free(bytes);

    // Header: version 7, skinned flag set, joint_count == 2.
    try testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, bytes[4..8], .little));
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, bytes[56..60], .little));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, bytes[64..68], .little));
    // skeleton_off 16-aligned.
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, bytes[60..64], .little) % 16);

    const r = try Reader.init(bytes);
    try testing.expectEqual(@as(u32, 56), r.vertexStride());
    try testing.expect(r.skinned);
    try testing.expectEqual(@as(u32, 2), r.jointCount());
    try testing.expectEqual(@as(u32, 2), r.vertex_count);

    // Skeleton round-trips: parent links + an inverse_bind float.
    try testing.expectEqual(@as(i32, -1), r.joint(0).parent);
    try testing.expectEqual(@as(i32, 0), r.joint(1).parent);
    try testing.expectApproxEqAbs(@as(f32, 2.5), r.joint(1).inverse_bind[12], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), r.joint(0).bind_local[0], 1e-6);

    // Vertex blob is stride 56; per-vertex joints @48 + weights @52 round-trip.
    try testing.expectEqual(@as(usize, 2 * 56), r.vertices.len);
    try testing.expectEqualSlices(u8, &joints[0], r.vertices[48..52]);
    try testing.expectEqualSlices(u8, &weights[0], r.vertices[52..56]);
    try testing.expectEqualSlices(u8, &joints[1], r.vertices[56 + 48 .. 56 + 52]);
    try testing.expectEqualSlices(u8, &weights[1], r.vertices[56 + 52 .. 56 + 56]);
    // The 48 base bytes of v0 match the source.
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(verts[0..12]), r.vertices[0..48]);
}

test "vmesh v7: multi-clip table round-trips" {
    const verts = [_]f32{0} ** 12;
    const joints = [_][4]u8{.{ 0, 0, 0, 0 }};
    const weights = [_][4]u8{.{ 255, 0, 0, 0 }};
    const skel = [_]Joint{.{ .parent = -1, .inverse_bind = Mat4Identity, .bind_local = Mat4Identity }};
    const t1 = [_]f32{0};
    const v_t = [_]f32{ 0, 0, 0 };
    const v_s = [_]f32{ 1, 1, 1 };
    const r0_times = [_]f32{ 0, 0.5, 1.0 };
    const r0_vals = [_]f32{ 0, 0, 0, 1, 0, 0, 0.3827, 0.9239, 0, 0, 0, 1 };
    const r1_times = [_]f32{0};
    const r1_vals = [_]f32{ 0, 0, 0, 1 };
    const c0 = [_]Track{
        .{ .interp = 0, .times = &t1, .values = &v_t },
        .{ .interp = 0, .times = &r0_times, .values = &r0_vals },
        .{ .interp = 0, .times = &t1, .values = &v_s },
    };
    const c1 = [_]Track{
        .{ .interp = 0, .times = &t1, .values = &v_t },
        .{ .interp = 0, .times = &r1_times, .values = &r1_vals },
        .{ .interp = 0, .times = &t1, .values = &v_s },
    };
    const clips = [_]Clip{
        .{ .name_hash = fnv1a32("Bend"), .duration = 1.0, .tracks = &c0 },
        .{ .name_hash = fnv1a32("Twist"), .duration = 2.0, .tracks = &c1 },
    };
    const anims = Anims{ .clips = &clips };
    const bytes = try pack(std.testing.allocator, &verts, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, true, &joints, &weights, &skel, anims);
    defer std.testing.allocator.free(bytes);
    var r = try Reader.init(bytes);
    try std.testing.expect(r.animPresent());
    try std.testing.expectEqual(@as(u32, 2), r.animClipCount());
    try std.testing.expectEqual(fnv1a32("Bend"), r.animClip(0).name_hash);
    try std.testing.expectEqual(fnv1a32("Twist"), r.animClip(1).name_hash);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), r.animClip(1).duration, 1e-6);
    const t0 = r.animTrack(0, 0, 1);
    try std.testing.expectEqual(@as(u32, 3), t0.key_count);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9239), r.animValue(t0, 1, 3), 1e-4);
    const t1c = r.animTrack(1, 0, 1);
    try std.testing.expectEqual(@as(u32, 1), t1c.key_count);
}
