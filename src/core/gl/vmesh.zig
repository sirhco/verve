//! .vmesh packed asset format v13 — writer + freestanding reader.
//!
//! Invariant: the byte buffer handed to `Reader.init` must itself be at least
//! 4-byte aligned (the asset region provides 16) — section offsets only
//! preserve alignment relative to the buffer base, and
//! `bvh.nodesFromBytes`/`triPermFromBytes` assert on the absolute pointer.
//!
//! Header layout (88 bytes, all integers little-endian u32):
//!   [0..4]   magic "VMSH"
//!   [4..8]   version u32 = 14
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
//!   [72..76] instance_off (16-aligned; 0 = no instances)
//!   [76..80] morph_off (16-aligned; 0 = no morph section)  [v13+]
//!   [80..84] morph_target_count  [v13+]
//!   [84..88] morph_vertex_count  [v13+]
//!
//! Morph section @ morph_off (16-aligned):
//!   Deltas blob (texture-upload-ready, target-major then vertex-major):
//!     morph_target_count × morph_vertex_count × morphRecordF16(version) × @sizeOf(f16) bytes.
//!     Per (target t, vertex v): 3 f16 POSITION delta, 3 f16 NORMAL delta[, 3 f16 TANGENT delta (v14+)].
//!   Weight clip (appended after deltas, 4-aligned):
//!     Same wire format as the anim section clip:
//!       clip_count u32 @0, flags u32 @4,
//!       clip table @8 (clip_count × 16B: name_hash, duration, dir_off, reserved),
//!       per clip: track_count × 12B dir (interp u8 @0, pad @1-3, key_count u32 @4,
//!                 data_off u32 @8), then per-track times[]f32 + values[]f32.
//!     Each track has comps=1 (scalar weight). track_count = morph_target_count.
//!     Empty clip (0 clips) when mesh has no weight animation.
//! submesh table @68, submesh_count × 84 bytes:
//!   index_byte_off u32 @0, index_count u32 @4,
//!   base_color f32×4 @8, metallic f32 @24, roughness f32 @28,
//!   emissive f32×3 @32, occlusion_strength f32 @44, normal_scale f32 @48,
//!   tex_base i32 @52, tex_mr i32 @56, tex_normal i32 @60,
//!   tex_emissive i32 @64, tex_occlusion i32 @68, alpha_mode u32 @72,
//!   alpha_cutoff f32 @76, double_sided u32 @80
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
pub const version: u32 = 14;

/// Returns the number of f16 values per (target, vertex) morph record.
/// v13: 6 (pos3 + nrm3). v14+: 9 (pos3 + nrm3 + tan3).
pub fn morphRecordF16(ver: u32) u32 {
    return if (ver >= 14) 9 else 6;
}

pub const vertex_stride: u32 = 48; // pos f32x3 @0, normal f32x3 @12, tangent f32x4 @24, uv f32x2 @40
pub const skinned_vertex_stride: u32 = 56; // …48, then joints uint8x4 @48, weights unorm8x4 @52
pub const header_size: u32 = 88;
pub const submesh_size: u32 = 84;
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

/// Morph target data for the vmesh morph section (v14+).
/// `deltas`: raw f16 blob, target-major then vertex-major.
///   Layout per (target t, vertex v): 3×f16 POSITION delta, 3×f16 NORMAL delta, 3×f16 TANGENT delta (9 f16/record v14+).
///   len must == target_count * vertex_count * morphRecordF16(14) * @sizeOf(f16) (v14).
///   When `tangent_deltas` is non-null: `deltas` holds only 6 f16/record (pos+nrm) and
///   pack() interleaves the tangent channel from `tangent_deltas` to produce the 9-f16 blob.
/// `weight_clip`: optional weight animation clip. One track per morph target,
///   comps=1 (scalar weight). null → empty clip written (0 clips, no animation).
pub const MorphData = struct {
    target_count: u32,
    vertex_count: u32,
    deltas: []const u8, // raw f16 bytes; len == target_count * vertex_count * morphRecordF16(14) * 2 (v14)
    weight_clip: ?Clip = null, // scalar weight animation; null = no animation
    tangent_deltas: ?[]const f16 = null, // v14: per-(target,vertex) tangent delta xyz; null → zeros
};
pub fn animComps(channel: u2) u32 {
    return if (channel == 1) 4 else 3;
}
/// Returns the per-key value multiplier: 3 for CUBICSPLINE (in/point/out),
/// 1 for LINEAR and STEP. File-private helper used by pack + Reader.init.
fn valueStride(interp: u8) u32 {
    return if (interp == 2) 3 else 1;
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
    alpha_mode: u32 = 0, // 0=opaque, 1=blend, 2=mask. vmesh v9.
    alpha_cutoff: f32 = 0.5, // MASK alpha-test threshold. vmesh v10.
    double_sided: u32 = 0, // glTF doubleSided (0/1). vmesh v11.
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
    instances: []const f32, // instance_count × 20 f32 (mat4 + color); empty = no section
    instance_count: u32,
    morph: ?MorphData, // v13 morph section; null → morph_off=0, counts=0
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

    // Layout: header(88) → submesh_table → tex_table → [align16] → vertices →
    //   [align4] → indices → [align4] → tex_blob → [align16] → bvh_nodes →
    //   tri_perm → [align4] → name_table → name_blob → [align16] → skeleton →
    //   [align16] → anim → [align16] → instances → [align16] → morph
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
                const vs = valueStride(tr.interp);
                std.debug.assert(tr.values.len == @as(usize, kc) * comps * vs);
                sect += kc * 4 + kc * comps * vs * 4;
            }
            cur += sect;
        }
        anim_total = cur;
    }
    const anim_off: u32 = if (anim == null) 0 else alignUp(after_skeleton, 16);
    const after_anim: u32 = if (anim == null) after_skeleton else anim_off + anim_total;

    // Instances section (16-aligned): [instance_count u32][pad to 16][instance_count × 80 B].
    // Absent when instance_count == 0.
    const instance_off: u32 = if (instance_count == 0) 0 else alignUp(after_anim, 16);
    const instance_section_bytes: u32 = if (instance_count == 0) 0 else blk: {
        // Header word (4 B) + pad to 16 + instance blob
        const inst_blob: u32 = instance_count * 80;
        break :blk 16 + inst_blob; // 4 B count + 12 B pad = 16 B prefix
    };
    const after_instances: u32 = if (instance_count == 0) after_anim else instance_off + instance_section_bytes;

    // Morph section (16-aligned): deltas blob then weight clip (4-aligned after deltas).
    // morph_off == 0 when no morph section. morph_target_count/morph_vertex_count = 0.
    var morph_total: u32 = 0;
    if (morph) |m| {
        const delta_bytes: u32 = m.target_count * m.vertex_count * morphRecordF16(14) * 2; // 9 f16 per vertex per target (v14)
        if (m.tangent_deltas != null) {
            std.debug.assert(m.deltas.len == m.target_count * m.vertex_count * 6 * 2);
            std.debug.assert(m.tangent_deltas.?.len == m.target_count * m.vertex_count * 3);
        } else {
            std.debug.assert(m.deltas.len == delta_bytes);
        }
        const after_deltas_rel: u32 = delta_bytes;
        var wclip_bytes: u32 = 0;
        if (m.weight_clip) |wc| {
            const track_count: u32 = m.target_count;
            std.debug.assert(wc.tracks.len == @as(usize, track_count));
            // Header: clip_count(4) + flags(4) + clip_table(1×16) + 4-align dir
            const wclip_table: u32 = 8 + anim_clip_entry_size; // 1 clip
            var cur: u32 = wclip_table;
            cur = alignUp(cur, 4);
            // Directory: track_count × 12B
            const dir_bytes2: u32 = track_count * anim_dir_entry_size;
            var blob_cur: u32 = cur + dir_bytes2;
            for (wc.tracks) |tr| {
                const kc: u32 = @intCast(tr.times.len);
                const vs = valueStride(tr.interp);
                std.debug.assert(tr.values.len == @as(usize, kc) * 1 * vs); // comps=1
                blob_cur += kc * 4 + kc * 1 * vs * 4;
            }
            cur = blob_cur;
            wclip_bytes = cur;
        } else {
            // Empty: just clip_count(4) + flags(4) → 8 bytes, 0 clips
            wclip_bytes = 8;
        }
        const wclip_off_rel: u32 = alignUp(after_deltas_rel, 4);
        morph_total = wclip_off_rel + wclip_bytes;
    }
    const morph_off: u32 = if (morph == null) 0 else alignUp(after_instances, 16);
    const after_morph: u32 = if (morph == null) after_instances else morph_off + morph_total;

    const total_size: u32 = after_morph;
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
    std.mem.writeInt(u32, buf[72..76], instance_off, .little);
    std.mem.writeInt(u32, buf[76..80], morph_off, .little);
    std.mem.writeInt(u32, buf[80..84], if (morph) |m| m.target_count else 0, .little);
    std.mem.writeInt(u32, buf[84..88], if (morph) |m| m.vertex_count else 0, .little);

    // Write submesh table right after the header
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
        // @72: alpha_mode (vmesh v9)
        std.mem.writeInt(u32, buf[off + 72 ..][0..4], s.alpha_mode, .little);
        // @76: alpha_cutoff (vmesh v10)
        std.mem.writeInt(u32, buf[off + 76 ..][0..4], @bitCast(s.alpha_cutoff), .little);
        // @80: double_sided (vmesh v11)
        std.mem.writeInt(u32, buf[off + 80 ..][0..4], s.double_sided, .little);
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

    // Write instances section: [instance_count u32 @0][pad to 16][instance_count × 80 B blob].
    // Each instance is 20 f32 = mat4 (16 f32, col-major) + color rgba (4 f32) = 80 B.
    if (instance_count > 0) {
        std.mem.writeInt(u32, buf[instance_off..][0..4], instance_count, .little);
        // Prefix is exactly 16 B (4 B count + 12 B zero pad, already zeroed by @memset).
        const blob_dst = instance_off + 16;
        const inst_bytes = std.mem.sliceAsBytes(instances);
        @memcpy(buf[blob_dst..][0..inst_bytes.len], inst_bytes);
    }

    // Write morph section (v14): deltas blob then weight clip.
    if (morph) |m| {
        const delta_bytes: u32 = m.target_count * m.vertex_count * morphRecordF16(14) * 2;
        if (m.tangent_deltas) |tan| {
            // Interleave 6-f16 (pos+nrm) from m.deltas and 3-f16 tan from tan
            // into the 9-f16 per-record layout: [pos3][nrm3][tan3].
            for (0..m.target_count) |ti| {
                for (0..m.vertex_count) |vi| {
                    const src_base = ti * m.vertex_count * 6 * 2 + vi * 6 * 2;
                    const dst_base = morph_off + ti * m.vertex_count * 9 * 2 + vi * 9 * 2;
                    // pos3 + nrm3 (12 bytes)
                    @memcpy(buf[dst_base..][0..12], m.deltas[src_base..][0..12]);
                    // tan3 (3 f16 values)
                    const tan_base = (ti * m.vertex_count + vi) * 3;
                    inline for (0..3) |ci| {
                        const hv: u16 = @bitCast(tan[tan_base + ci]);
                        std.mem.writeInt(u16, buf[dst_base + 12 + ci * 2 ..][0..2], hv, .little);
                    }
                }
            }
        } else {
            @memcpy(buf[morph_off..][0..delta_bytes], m.deltas);
        }
        const wclip_off_abs: u32 = morph_off + alignUp(delta_bytes, 4);
        if (m.weight_clip) |wc| {
            const track_count: u32 = m.target_count;
            // clip_count = 1, flags = 0
            std.mem.writeInt(u32, buf[wclip_off_abs..][0..4], 1, .little);
            std.mem.writeInt(u32, buf[wclip_off_abs + 4 ..][0..4], 0, .little);
            // clip table entry @8: name_hash, duration, dir_off (relative to wclip section), reserved
            const te: u32 = wclip_off_abs + 8;
            const wclip_table_size: u32 = 8 + anim_clip_entry_size; // 24 B
            const dir_rel: u32 = alignUp(wclip_table_size, 4);
            std.mem.writeInt(u32, buf[te..][0..4], wc.name_hash, .little);
            std.mem.writeInt(u32, buf[te + 4 ..][0..4], @bitCast(wc.duration), .little);
            std.mem.writeInt(u32, buf[te + 8 ..][0..4], dir_rel, .little);
            std.mem.writeInt(u32, buf[te + 12 ..][0..4], 0, .little);
            const dir_abs: u32 = wclip_off_abs + dir_rel;
            const dir_bytes2: u32 = track_count * anim_dir_entry_size;
            var blob_cursor_rel: u32 = dir_rel + dir_bytes2;
            for (wc.tracks, 0..) |tr, ti| {
                const kc: u32 = @intCast(tr.times.len);
                const vs = valueStride(tr.interp);
                const e: u32 = dir_abs + @as(u32, @intCast(ti)) * anim_dir_entry_size;
                buf[e] = tr.interp;
                buf[e + 1] = 0;
                buf[e + 2] = 0;
                buf[e + 3] = 0;
                std.mem.writeInt(u32, buf[e + 4 ..][0..4], kc, .little);
                std.mem.writeInt(u32, buf[e + 8 ..][0..4], blob_cursor_rel, .little);
                var k: u32 = 0;
                while (k < kc) : (k += 1)
                    std.mem.writeInt(u32, buf[wclip_off_abs + blob_cursor_rel + k * 4 ..][0..4], @bitCast(tr.times[k]), .little);
                const vbase: u32 = wclip_off_abs + blob_cursor_rel + kc * 4;
                var vi: u32 = 0;
                // comps = 1 (scalar weight)
                while (vi < kc * 1 * vs) : (vi += 1)
                    std.mem.writeInt(u32, buf[vbase + vi * 4 ..][0..4], @bitCast(tr.values[vi]), .little);
                blob_cursor_rel += kc * 4 + kc * 1 * vs * 4;
            }
        } else {
            // Empty weight clip: clip_count=0, flags=0
            std.mem.writeInt(u32, buf[wclip_off_abs..][0..4], 0, .little);
            std.mem.writeInt(u32, buf[wclip_off_abs + 4 ..][0..4], 0, .little);
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
                const vs = valueStride(tr.interp);
                var vi: u32 = 0;
                while (vi < kc * comps * vs) : (vi += 1)
                    std.mem.writeInt(u32, buf[vbase + vi * 4 ..][0..4], @bitCast(tr.values[vi]), .little);
                blob_cursor += kc * 4 + kc * comps * vs * 4;
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
    instance_off_: u32,
    morph_off_: u32, // v13+; 0 when absent or version < 13
    morph_target_count_: u32, // v13+; 0 when absent
    morph_vertex_count_: u32, // v13+; 0 when absent
    version_: u32, // file format version (13 or 14)
    bytes: []const u8,

    pub fn init(bytes: []const u8) error{ BadMagic, BadVersion, Truncated, BadTexIndex }!Reader {
        if (bytes.len < header_size) return error.Truncated;
        // Capture the buffer length ONCE at entry, BEFORE the readInt header block
        // below. Zig 0.16.0's self-hosted x86_64 backend (the Debug default on
        // x86_64-linux) miscompiles a `bytes.len` read taken AFTER that block:
        // the param slice's `.len` reads a stale value (observed 256 vs the real
        // 336) → spurious error.Truncated. Confirmed a backend bug — the same code
        // passes under `-fllvm`, and aarch64-macOS / x86_64-Windows (LLVM path)
        // never hit it (which is why only ubuntu CI was red). Reading len here,
        // ahead of the miscompiled region, sidesteps it.
        const blen: u64 = bytes.len;
        if (!std.mem.eql(u8, bytes[0..4], magic)) return error.BadMagic;
        const ver = std.mem.readInt(u32, bytes[4..8], .little);
        if (ver < 13 or ver > version) return error.BadVersion; // accept v13 and v14

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
        const instance_off = std.mem.readInt(u32, bytes[72..76], .little);
        // v13 morph header fields: only read when buffer is large enough (≥88 B).
        // A v13 file always has header_size == 88, and init already checked bytes.len ≥ 88.
        const morph_off = std.mem.readInt(u32, bytes[76..80], .little);
        const morph_target_count = std.mem.readInt(u32, bytes[80..84], .little);
        const morph_vertex_count = std.mem.readInt(u32, bytes[84..88], .little);

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
                    const interp: u8 = bytes[e];
                    if (interp > 2) return error.Truncated; // reject unknown interp
                    const kc: u64 = std.mem.readInt(u32, bytes[e + 4 ..][0..4], .little);
                    const data_off: u64 = std.mem.readInt(u32, bytes[e + 8 ..][0..4], .little);
                    const vs: u64 = valueStride(interp);
                    const need: u64 = kc * 4 + kc * comps * vs * 4;
                    const abs: u64 = @as(u64, anim_off) + data_off;
                    if (abs > blen or need > blen - abs) return error.Truncated;
                }
            }
        }

        // ── Instances section ────────────────────────────────────────────────
        // instance_off == 0 → no instances. When present, validate alignment
        // and that the header word + blob fit in the buffer.
        if (instance_off != 0) {
            if (instance_off % 16 != 0) return error.Truncated;
            if (@as(u64, instance_off) + 16 > blen) return error.Truncated;
            const inst_count_sec = std.mem.readInt(u32, bytes[instance_off..][0..4], .little);
            const need_inst: u64 = @as(u64, inst_count_sec) * 80;
            const inst_blob_start: u64 = @as(u64, instance_off) + 16;
            if (inst_blob_start > blen or need_inst > blen - inst_blob_start) return error.Truncated;
        }

        // ── Morph section (v13) ──────────────────────────────────────────────
        // morph_off == 0 → no morph. When present, validate alignment, delta
        // blob bounds, and weight clip header bounds.
        if (morph_off != 0) {
            if (morph_off % 16 != 0) return error.Truncated;
            const delta_bytes: u64 = @as(u64, morph_target_count) * @as(u64, morph_vertex_count) * @as(u64, morphRecordF16(ver)) * 2;
            if (@as(u64, morph_off) > blen or delta_bytes > blen - @as(u64, morph_off)) return error.Truncated;
            // Weight clip header: 4-aligned after delta blob, at least 8 bytes (clip_count + flags).
            const wclip_off: u64 = @as(u64, morph_off) + ((@as(u64, @intCast(delta_bytes)) + 3) & ~@as(u64, 3));
            if (wclip_off + 8 > blen) return error.Truncated;
            const wclip_count = std.mem.readInt(u32, bytes[@intCast(wclip_off)..][0..4], .little);
            if (wclip_count > 1) return error.Truncated; // morph section supports 0 or 1 clip
            if (wclip_count == 1) {
                const wclip_table_end: u64 = wclip_off + 8 + anim_clip_entry_size;
                if (wclip_table_end > blen) return error.Truncated;
                const dir_rel = std.mem.readInt(u32, bytes[@intCast(wclip_off + 8 + 8)..][0..4], .little);
                const dir_abs: u64 = wclip_off + @as(u64, dir_rel);
                const dir_bytes2: u64 = @as(u64, morph_target_count) * anim_dir_entry_size;
                if (dir_abs > blen or dir_bytes2 > blen - dir_abs) return error.Truncated;
                // Validate each track's blob bounds (comps=1 for weight tracks).
                var ti: u32 = 0;
                while (ti < morph_target_count) : (ti += 1) {
                    const e: usize = @intCast(dir_abs + @as(u64, ti) * anim_dir_entry_size);
                    const interp: u8 = bytes[e];
                    if (interp > 2) return error.Truncated;
                    const kc: u64 = std.mem.readInt(u32, bytes[e + 4 ..][0..4], .little);
                    const data_off_rel: u64 = std.mem.readInt(u32, bytes[e + 8 ..][0..4], .little);
                    const vs: u64 = valueStride(interp);
                    const need: u64 = kc * 4 + kc * 1 * vs * 4; // comps=1
                    const abs_data: u64 = wclip_off + data_off_rel;
                    if (abs_data > blen or need > blen - abs_data) return error.Truncated;
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
            .instance_off_ = instance_off,
            .morph_off_ = morph_off,
            .morph_target_count_ = morph_target_count,
            .morph_vertex_count_ = morph_vertex_count,
            .version_ = ver,
            .bytes = bytes,
        };
    }

    /// File format version (header [4..8]). 13 or 14 for files this reader accepts.
    pub fn fileVersion(self: *const Reader) u32 {
        return std.mem.readInt(u32, self.bytes[4..8], .little);
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

    /// Component `comp` of keyframe `i` point value of track `t`. For
    /// CUBICSPLINE (interp==2) the point is the middle triple per key:
    /// offset index = i*3*comps + comps + comp. For LINEAR/STEP:
    /// offset index = i*comps + comp. Caller must ensure `i < t.key_count`
    /// and `comp < t.comps`.
    pub fn animValue(self: *const Reader, t: TrackInfo, i: u32, comp: u32) f32 {
        const vbase = @as(usize, self.anim_off_) + t.data_off + @as(usize, t.key_count) * 4;
        const idx: usize = if (t.interp == 2)
            @as(usize, i) * 3 * t.comps + t.comps + comp
        else
            @as(usize, i) * t.comps + comp;
        const off = vbase + idx * 4;
        return @bitCast(std.mem.readInt(u32, self.bytes[off..][0..4], .little));
    }

    /// In-tangent component `comp` of keyframe `i` for a CUBICSPLINE track.
    /// Index = i*3*comps + comp. Caller must ensure track is CUBICSPLINE
    /// (interp==2), `i < t.key_count`, and `comp < t.comps`.
    pub fn animInTangent(self: *const Reader, t: TrackInfo, i: u32, comp: u32) f32 {
        const vbase = @as(usize, self.anim_off_) + t.data_off + @as(usize, t.key_count) * 4;
        const idx: usize = @as(usize, i) * 3 * t.comps + comp;
        return @bitCast(std.mem.readInt(u32, self.bytes[vbase + idx * 4 ..][0..4], .little));
    }

    /// Out-tangent component `comp` of keyframe `i` for a CUBICSPLINE track.
    /// Index = i*3*comps + 2*comps + comp. Caller must ensure track is CUBICSPLINE
    /// (interp==2), `i < t.key_count`, and `comp < t.comps`.
    pub fn animOutTangent(self: *const Reader, t: TrackInfo, i: u32, comp: u32) f32 {
        const vbase = @as(usize, self.anim_off_) + t.data_off + @as(usize, t.key_count) * 4;
        const idx: usize = @as(usize, i) * 3 * t.comps + 2 * t.comps + comp;
        return @bitCast(std.mem.readInt(u32, self.bytes[vbase + idx * 4 ..][0..4], .little));
    }

    /// Number of GPU instances stored in the instances section. 0 when absent.
    pub fn instanceCount(self: *const Reader) u32 {
        if (self.instance_off_ == 0) return 0;
        return std.mem.readInt(u32, self.bytes[self.instance_off_..][0..4], .little);
    }

    /// Raw instances blob: `instanceCount() × 80 B` (mat4 col-major f32×16 then
    /// color rgba f32×4). Empty slice when no instances section present.
    pub fn instances(self: *const Reader) []const u8 {
        if (self.instance_off_ == 0) return self.bytes[0..0];
        const cnt = std.mem.readInt(u32, self.bytes[self.instance_off_..][0..4], .little);
        const blob_start: usize = @intCast(@as(u64, self.instance_off_) + 16);
        return self.bytes[blob_start..][0 .. @as(usize, cnt) * 80];
    }

    /// Number of morph targets (header [80..84]). 0 when no morph section (v13+).
    pub fn morphTargetCount(self: *const Reader) u32 {
        return self.morph_target_count_;
    }

    /// Number of morph vertices (header [84..88]). 0 when no morph section (v13+).
    pub fn morphVertexCount(self: *const Reader) u32 {
        return self.morph_vertex_count_;
    }

    /// Raw f16 delta blob: target-major then vertex-major.
    /// Per (target t, vertex v): 3×f16 POSITION delta, 3×f16 NORMAL delta[, 3×f16 TANGENT delta (v14+)].
    /// len == morphTargetCount() * morphVertexCount() * morphRecordF16(fileVersion()) * @sizeOf(f16).
    /// Returns empty slice when no morph section present.
    pub fn morphDeltas(self: *const Reader) []const u8 {
        if (self.morph_off_ == 0) return self.bytes[0..0];
        const delta_bytes: usize = @as(usize, self.morph_target_count_) * @as(usize, self.morph_vertex_count_) * @as(usize, morphRecordF16(self.version_)) * 2;
        return self.bytes[self.morph_off_..][0..delta_bytes];
    }

    /// Weight clip track info for morph target `target_idx`.
    /// comps = 1 (scalar weight). Returns null when no weight animation.
    /// Caller must ensure `target_idx < morphTargetCount()`.
    pub fn morphWeightTrack(self: *const Reader, target_idx: u32) ?TrackInfo {
        if (self.morph_off_ == 0) return null;
        const delta_bytes: u32 = self.morph_target_count_ * self.morph_vertex_count_ * morphRecordF16(self.version_) * 2;
        const wclip_off: usize = @intCast(@as(u64, self.morph_off_) + alignUp(delta_bytes, 4));
        const wclip_count = std.mem.readInt(u32, self.bytes[wclip_off..][0..4], .little);
        if (wclip_count == 0) return null;
        const dir_rel = std.mem.readInt(u32, self.bytes[wclip_off + 8 + 8 ..][0..4], .little);
        const e: usize = wclip_off + @as(usize, dir_rel) + @as(usize, target_idx) * anim_dir_entry_size;
        return TrackInfo{
            .interp = self.bytes[e],
            .key_count = std.mem.readInt(u32, self.bytes[e + 4 ..][0..4], .little),
            .data_off = std.mem.readInt(u32, self.bytes[e + 8 ..][0..4], .little),
            .comps = 1,
        };
    }

    /// Keyframe `i` time of morph weight track `t`. `t` from morphWeightTrack().
    /// Uses wclip_off as base — data_off is relative to the weight clip section start.
    /// Caller must ensure `i < t.key_count`.
    pub fn morphWeightTime(self: *const Reader, t: TrackInfo, i: u32) f32 {
        const delta_bytes: u32 = self.morph_target_count_ * self.morph_vertex_count_ * morphRecordF16(self.version_) * 2;
        const wclip_off: usize = @intCast(@as(u64, self.morph_off_) + alignUp(delta_bytes, 4));
        const off: usize = wclip_off + @as(usize, t.data_off) + @as(usize, i) * 4;
        return @bitCast(std.mem.readInt(u32, self.bytes[off..][0..4], .little));
    }

    /// Weight value (point) of morph target at keyframe `i` from track `t`. comps=1.
    /// For CUBICSPLINE (interp==2) returns the middle slot of the [in, point, out] triple:
    /// index = i*3 + 1. For LINEAR/STEP: index = i.
    /// Caller must ensure `i < t.key_count`.
    pub fn morphWeightValue(self: *const Reader, t: TrackInfo, i: u32) f32 {
        const delta_bytes: u32 = self.morph_target_count_ * self.morph_vertex_count_ * morphRecordF16(self.version_) * 2;
        const wclip_off: usize = @intCast(@as(u64, self.morph_off_) + alignUp(delta_bytes, 4));
        const vbase: usize = wclip_off + @as(usize, t.data_off) + @as(usize, t.key_count) * 4;
        const idx: usize = if (t.interp == 2) @as(usize, i) * 3 + 1 else i;
        return @bitCast(std.mem.readInt(u32, self.bytes[vbase + idx * 4 ..][0..4], .little));
    }

    /// In-tangent of morph weight keyframe `i` from CUBICSPLINE track `t`. comps=1.
    /// Index = i*3 + 0 (first slot of the [in, point, out] triple).
    /// Caller must ensure track is CUBICSPLINE (interp==2) and `i < t.key_count`.
    pub fn morphWeightInTangent(self: *const Reader, t: TrackInfo, i: u32) f32 {
        const delta_bytes: u32 = self.morph_target_count_ * self.morph_vertex_count_ * morphRecordF16(self.version_) * 2;
        const wclip_off: usize = @intCast(@as(u64, self.morph_off_) + alignUp(delta_bytes, 4));
        const vbase: usize = wclip_off + @as(usize, t.data_off) + @as(usize, t.key_count) * 4;
        const idx: usize = @as(usize, i) * 3; // slot 0 = in-tangent
        return @bitCast(std.mem.readInt(u32, self.bytes[vbase + idx * 4 ..][0..4], .little));
    }

    /// Out-tangent of morph weight keyframe `i` from CUBICSPLINE track `t`. comps=1.
    /// Index = i*3 + 2 (third slot of the [in, point, out] triple).
    /// Caller must ensure track is CUBICSPLINE (interp==2) and `i < t.key_count`.
    pub fn morphWeightOutTangent(self: *const Reader, t: TrackInfo, i: u32) f32 {
        const delta_bytes: u32 = self.morph_target_count_ * self.morph_vertex_count_ * morphRecordF16(self.version_) * 2;
        const wclip_off: usize = @intCast(@as(u64, self.morph_off_) + alignUp(delta_bytes, 4));
        const vbase: usize = wclip_off + @as(usize, t.data_off) + @as(usize, t.key_count) * 4;
        const idx: usize = @as(usize, i) * 3 + 2; // slot 2 = out-tangent
        return @bitCast(std.mem.readInt(u32, self.bytes[vbase + idx * 4 ..][0..4], .little));
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
            .alpha_mode = std.mem.readInt(u32, raw[72..76], .little),
            .alpha_cutoff = @bitCast(std.mem.readInt(u32, raw[76..80], .little)),
            .double_sided = std.mem.readInt(u32, raw[80..84], .little),
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
    /// the submesh has a normal-map texture (`tex_normal >= 0`),
    /// `variant_emissive` when it has an emissive texture (`tex_emissive >= 0`),
    /// and `variant_alpha_test` when `alpha_mode == 2` (MASK).
    /// Caller must ensure `s < self.submesh_count`.
    pub fn submeshVariant(self: *const Reader, s: u32) u32 {
        const sub = self.submesh(s);
        var bits: u32 = command.variant_pbr;
        if (sub.tex_normal >= 0) bits |= command.variant_normal_map;
        if (sub.tex_emissive >= 0) bits |= command.variant_emissive;
        if (sub.alpha_mode == 2) bits |= command.variant_alpha_test;
        if (sub.double_sided != 0) bits |= command.variant_double_sided;
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
    const bytes = try pack(testing.allocator, &verts, &idx, &subs, &texs, &.{}, &.{}, &.{}, false, &.{}, &.{}, &.{}, null, &.{}, 0, null);
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
    const bytes = try pack(testing.allocator, &verts, &idx, &.{}, &.{}, &.{}, &.{}, &.{}, false, &.{}, &.{}, &.{}, null, &.{}, 0, null);
    defer testing.allocator.free(bytes);
    const vo = std.mem.readInt(u32, bytes[24..28], .little);
    const io = std.mem.readInt(u32, bytes[28..32], .little);
    try testing.expectEqual(@as(u32, 0), vo % 16);
    try testing.expectEqual(@as(u32, 0), io % 4);
}

test "reader rejects hostile counts (u32 overflow)" {
    var buf = [_]u8{0} ** 96; // ≥88 B so header_size check passes, count checks fire
    @memcpy(buf[0..4], magic);
    std.mem.writeInt(u32, buf[4..8], version, .little);
    std.mem.writeInt(u32, buf[8..12], 0x8000_0000, .little); // vertex_count: *48 wraps
    std.mem.writeInt(u32, buf[24..28], 96, .little); // vertex_off (past buf → Truncated)
    try testing.expectError(error.Truncated, Reader.init(&buf));

    std.mem.writeInt(u32, buf[8..12], 0, .little);
    std.mem.writeInt(u32, buf[16..20], 0xFFFF_FFFF, .little); // submesh_count: *72 wraps
    try testing.expectError(error.Truncated, Reader.init(&buf));

    std.mem.writeInt(u32, buf[16..20], 0, .little);
    std.mem.writeInt(u32, buf[20..24], 0xFFFF_FFFF, .little); // texture_count: *20 wraps
    try testing.expectError(error.Truncated, Reader.init(&buf));

    std.mem.writeInt(u32, buf[20..24], 0, .little);
    std.mem.writeInt(u32, buf[12..16], 0x8000_0000, .little); // index_count: *2 wraps to 0
    std.mem.writeInt(u32, buf[28..32], 96, .little); // index_off (past buf → Truncated)
    try testing.expectError(error.Truncated, Reader.init(&buf));
}

test "reader rejects bad magic and truncation" {
    var junk = [_]u8{0} ** 96; // ≥88 so Truncated is not the first rejection
    try testing.expectError(error.BadMagic, Reader.init(&junk));
    @memcpy(junk[0..4], magic);
    std.mem.writeInt(u32, junk[4..8], 99, .little);
    try testing.expectError(error.BadVersion, Reader.init(&junk));
    try testing.expectError(error.Truncated, Reader.init(junk[0..10]));
}

test "reader rejects v1 and v2 buffers (BadVersion)" {
    // Build valid-looking old-version buffers (version word = 1, then 2) →
    // both must get BadVersion now that the reader only accepts v13.
    var buf = [_]u8{0} ** 96; // ≥88 B (header_size) so the version check fires
    @memcpy(buf[0..4], magic);
    // zero vertex/index/submesh/tex counts, offsets pointing into buf
    std.mem.writeInt(u32, buf[24..28], 96, .little); // vertex_off
    std.mem.writeInt(u32, buf[28..32], 96, .little); // index_off
    std.mem.writeInt(u32, buf[32..36], 96, .little); // tex_table_off
    std.mem.writeInt(u32, buf[36..40], 96, .little); // tex_data_off

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

    const bytes = try pack(testing.allocator, &v3_verts, &v3_idx, &subs, &.{}, &nodes, &perm, &names, false, &.{}, &.{}, &.{}, null, &.{}, 0, null);
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
    const bytes = try pack(testing.allocator, &v3_verts, &v3_idx, &.{}, &.{}, &.{}, &.{}, &.{}, false, &.{}, &.{}, &.{}, null, &.{}, 0, null);
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
    const bytes = try pack(testing.allocator, &v3_verts, &v3_idx, &subs, &.{}, &nodes, &perm, &names, false, &.{}, &.{}, &.{}, null, &.{}, 0, null);
    defer testing.allocator.free(bytes);

    const bvh_off = std.mem.readInt(u32, bytes[40..44], .little);
    const name_table_off = std.mem.readInt(u32, bytes[48..52], .little);
    try testing.expectEqual(@as(u32, 0), bvh_off % 16);
    try testing.expectEqual(@as(u32, 0), name_table_off % 4);
}

test "(d) v3 hostile sections → Truncated / empty (no panic)" {
    // Start from a valid zero-section v3 file, then corrupt the header.
    const base = try pack(testing.allocator, &v3_verts, &v3_idx, &.{}, &.{}, &.{}, &.{}, &.{}, false, &.{}, &.{}, &.{}, null, &.{}, 0, null);
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
        const buf = try pack(testing.allocator, &v3_verts, &v3_idx, &subs, &.{}, &.{}, &.{}, &names, false, &.{}, &.{}, &.{}, null, &.{}, 0, null);
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
    const bytes = try pack(testing.allocator, &v3_verts, &v3_idx, &subs, &texs, &.{}, &.{}, &.{}, false, &.{}, &.{}, &.{}, null, &.{}, 0, null);
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
        const bytes = try pack(testing.allocator, &v3_verts, &v3_idx, &good, &texs, &.{}, &.{}, &.{}, false, &.{}, &.{}, &.{}, null, &.{}, 0, null);
        defer testing.allocator.free(bytes);
        _ = try Reader.init(bytes);
    }
    // tex index == tex_count (1) → out of range → reject.
    {
        const bytes = try pack(testing.allocator, &v3_verts, &v3_idx, &good, &texs, &.{}, &.{}, &.{}, false, &.{}, &.{}, &.{}, null, &.{}, 0, null);
        defer testing.allocator.free(bytes);
        std.mem.writeInt(i32, bytes[header_size + 56 ..][0..4], 1, .little); // tex_mr @56
        try testing.expectError(error.BadTexIndex, Reader.init(bytes));
    }
    // tex index < -1 (e.g. -2, not the missing-sentinel) → reject.
    {
        const bytes = try pack(testing.allocator, &v3_verts, &v3_idx, &good, &texs, &.{}, &.{}, &.{}, false, &.{}, &.{}, &.{}, null, &.{}, 0, null);
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
    try testing.expectError(error.SizeMismatch, pack(testing.allocator, &v3_verts, &v3_idx, &subs, &.{}, &nodes, &bad_perm, &.{}, false, &.{}, &.{}, &.{}, null, &.{}, 0, null));

    // names.len == 1 with 2 submeshes → SizeMismatch.
    const one_name = [_][]const u8{"only"};
    try testing.expectError(error.SizeMismatch, pack(testing.allocator, &v3_verts, &v3_idx, &subs, &.{}, &.{}, &.{}, &one_name, false, &.{}, &.{}, &.{}, null, &.{}, 0, null));
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

    const bytes = try pack(testing.allocator, &v3_verts, &v3_idx, &subs, &texs, &.{}, &.{}, &.{}, false, &.{}, &.{}, &.{}, null, &.{}, 0, null);
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

    const bytes = try pack(testing.allocator, &verts, &idx, &.{}, &.{}, &.{}, &.{}, &.{}, true, &joints, &weights, &skel, null, &.{}, 0, null);
    defer testing.allocator.free(bytes);

    // Header: version 14, skinned flag set, joint_count == 2.
    try testing.expectEqual(@as(u32, 14), std.mem.readInt(u32, bytes[4..8], .little));
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

test "vmesh v9: CUBICSPLINE round-trip — in/point/out tangents + LINEAR regression" {
    // Minimal skinned mesh: 1 vertex, 1 joint.
    const verts = [_]f32{0} ** 12;
    const joints_arr = [_][4]u8{.{ 0, 0, 0, 0 }};
    const weights_arr = [_][4]u8{.{ 255, 0, 0, 0 }};
    const skel = [_]Joint{.{ .parent = -1, .inverse_bind = Mat4Identity, .bind_local = Mat4Identity }};

    // CUBICSPLINE rotation track (channel 1, comps=4), key_count=2.
    // Per-key layout: [inTangent(4), point(4), outTangent(4)] → values len = 2*4*3 = 24.
    // Key 0: inT=(0.1,0.2,0.3,0.4), pt=(0,0,0,1), outT=(0.5,0.6,0.7,0.8)
    // Key 1: inT=(0.9,0.8,0.7,0.6), pt=(0,1,0,0), outT=(0.5,0.4,0.3,0.2)
    const cs_times = [_]f32{ 0.0, 1.0 };
    const cs_values = [_]f32{
        // key 0
        0.1, 0.2, 0.3, 0.4, // inTangent
        0.0, 0.0, 0.0, 1.0, // point
        0.5, 0.6, 0.7, 0.8, // outTangent
        // key 1
        0.9, 0.8, 0.7, 0.6, // inTangent
        0.0, 1.0, 0.0, 0.0, // point
        0.5, 0.4, 0.3, 0.2, // outTangent
    };

    // LINEAR translation track (channel 0, comps=3), key_count=2. Regression check.
    const lin_times = [_]f32{ 0.0, 1.0 };
    const lin_values = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0 };

    // STEP scale track (channel 2, comps=3), key_count=1.
    const step_times = [_]f32{0.0};
    const step_values = [_]f32{ 1.0, 1.0, 1.0 };

    // One clip, one joint → 3 tracks (T=linear, R=cubicspline, S=step).
    const tracks = [_]Track{
        .{ .interp = 0, .times = &lin_times, .values = &lin_values }, // T linear
        .{ .interp = 2, .times = &cs_times, .values = &cs_values }, // R cubicspline
        .{ .interp = 1, .times = &step_times, .values = &step_values }, // S step
    };
    const clip = Clip{ .name_hash = fnv1a32("TestClip"), .duration = 1.0, .tracks = &tracks };
    const anims = Anims{ .clips = &[_]Clip{clip} };

    const bytes = try pack(testing.allocator, &verts, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, true, &joints_arr, &weights_arr, &skel, anims, &.{}, 0, null);
    defer testing.allocator.free(bytes);

    // Version must be 14.
    try testing.expectEqual(@as(u32, 14), std.mem.readInt(u32, bytes[4..8], .little));

    const r = try Reader.init(bytes);
    try testing.expect(r.animPresent());
    try testing.expectEqual(@as(u32, 1), r.animClipCount());

    // LINEAR track (T, channel 0): point values unchanged.
    const tr_lin = r.animTrack(0, 0, 0);
    try testing.expectEqual(@as(u8, 0), tr_lin.interp);
    try testing.expectEqual(@as(u32, 2), tr_lin.key_count);
    try testing.expectApproxEqAbs(@as(f32, 1.0), r.animValue(tr_lin, 0, 0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 4.0), r.animValue(tr_lin, 1, 0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 6.0), r.animValue(tr_lin, 1, 2), 1e-6);

    // CUBICSPLINE track (R, channel 1): point / inTangent / outTangent.
    const tr_cs = r.animTrack(0, 0, 1);
    try testing.expectEqual(@as(u8, 2), tr_cs.interp);
    try testing.expectEqual(@as(u32, 2), tr_cs.key_count);
    try testing.expectEqual(@as(u32, 4), tr_cs.comps);

    // Key 0: point (0,0,0,1)
    try testing.expectApproxEqAbs(@as(f32, 0.0), r.animValue(tr_cs, 0, 0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), r.animValue(tr_cs, 0, 3), 1e-6);
    // Key 0: inTangent (0.1,0.2,0.3,0.4)
    try testing.expectApproxEqAbs(@as(f32, 0.1), r.animInTangent(tr_cs, 0, 0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.4), r.animInTangent(tr_cs, 0, 3), 1e-6);
    // Key 0: outTangent (0.5,0.6,0.7,0.8)
    try testing.expectApproxEqAbs(@as(f32, 0.5), r.animOutTangent(tr_cs, 0, 0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.8), r.animOutTangent(tr_cs, 0, 3), 1e-6);
    // Key 1: point (0,1,0,0)
    try testing.expectApproxEqAbs(@as(f32, 0.0), r.animValue(tr_cs, 1, 0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), r.animValue(tr_cs, 1, 1), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), r.animValue(tr_cs, 1, 3), 1e-6);
    // Key 1: inTangent (0.9,0.8,0.7,0.6)
    try testing.expectApproxEqAbs(@as(f32, 0.9), r.animInTangent(tr_cs, 1, 0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.6), r.animInTangent(tr_cs, 1, 3), 1e-6);
    // Key 1: outTangent (0.5,0.4,0.3,0.2)
    try testing.expectApproxEqAbs(@as(f32, 0.5), r.animOutTangent(tr_cs, 1, 0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.2), r.animOutTangent(tr_cs, 1, 3), 1e-6);

    // Time reads still work.
    try testing.expectApproxEqAbs(@as(f32, 0.0), r.animTime(tr_cs, 0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), r.animTime(tr_cs, 1), 1e-6);
}

test "vmesh v9: multi-clip table round-trips" {
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
    const bytes = try pack(std.testing.allocator, &verts, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, true, &joints, &weights, &skel, anims, &.{}, 0, null);
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

test "vmesh v10: submesh alpha_mode round-trips" {
    const verts = [_]f32{0} ** 12;
    const idx = [_]u16{ 0, 0, 0 };
    var subs = [_]Submesh{
        .{ .index_byte_off = 0, .index_count = 3, .base_color = .{ 1, 1, 1, 1 }, .metallic = 0, .roughness = 1, .emissive = .{ 0, 0, 0 }, .occlusion_strength = 1, .normal_scale = 1, .tex_base = -1, .tex_mr = -1, .tex_normal = -1, .tex_emissive = -1, .tex_occlusion = -1, .alpha_mode = 1 },
    };
    const bytes = try pack(testing.allocator, &verts, &idx, &subs, &.{}, &.{}, &.{}, &.{}, false, &.{}, &.{}, &.{}, null, &.{}, 0, null);
    defer testing.allocator.free(bytes);
    const reader = try Reader.init(bytes);
    try testing.expectEqual(@as(u32, 14), version);
    try testing.expectEqual(@as(u32, 84), submesh_size);
    try testing.expectEqual(@as(u32, 1), reader.submesh(0).alpha_mode);
}

test "vmesh v10: submesh alpha_cutoff round-trips" {
    const verts = [_]f32{0} ** 12;
    const idx = [_]u16{ 0, 0, 0 };
    var subs = [_]Submesh{
        .{ .index_byte_off = 0, .index_count = 3, .base_color = .{ 1, 1, 1, 1 }, .metallic = 0, .roughness = 1, .emissive = .{ 0, 0, 0 }, .occlusion_strength = 1, .normal_scale = 1, .tex_base = -1, .tex_mr = -1, .tex_normal = -1, .tex_emissive = -1, .tex_occlusion = -1, .alpha_mode = 2, .alpha_cutoff = 0.3 },
    };
    const bytes = try pack(testing.allocator, &verts, &idx, &subs, &.{}, &.{}, &.{}, &.{}, false, &.{}, &.{}, &.{}, null, &.{}, 0, null);
    defer testing.allocator.free(bytes);
    const reader = try Reader.init(bytes);
    try testing.expectEqual(@as(u32, 14), version);
    try testing.expectEqual(@as(u32, 84), submesh_size);
    try testing.expectEqual(@as(u32, 2), reader.submesh(0).alpha_mode);
    try testing.expectEqual(@as(f32, 0.3), reader.submesh(0).alpha_cutoff);
}

test "(i) submeshVariant: alpha_mode 2 adds variant_alpha_test" {
    const verts = [_]f32{0} ** 12;
    const idx = [_]u16{ 0, 0, 0 };
    var subs = [_]Submesh{
        .{ .index_byte_off = 0, .index_count = 3, .base_color = .{ 1, 1, 1, 1 }, .metallic = 0, .roughness = 1, .emissive = .{ 0, 0, 0 }, .occlusion_strength = 1, .normal_scale = 1, .tex_base = -1, .tex_mr = -1, .tex_normal = -1, .tex_emissive = -1, .tex_occlusion = -1, .alpha_mode = 2, .alpha_cutoff = 0.5 },
        .{ .index_byte_off = 0, .index_count = 3, .base_color = .{ 1, 1, 1, 1 }, .metallic = 0, .roughness = 1, .emissive = .{ 0, 0, 0 }, .occlusion_strength = 1, .normal_scale = 1, .tex_base = -1, .tex_mr = -1, .tex_normal = -1, .tex_emissive = -1, .tex_occlusion = -1, .alpha_mode = 0, .alpha_cutoff = 0.5 },
    };
    const bytes = try pack(testing.allocator, &verts, &idx, &subs, &.{}, &.{}, &.{}, &.{}, false, &.{}, &.{}, &.{}, null, &.{}, 0, null);
    defer testing.allocator.free(bytes);
    const reader = try Reader.init(bytes);
    try testing.expect(reader.submeshVariant(0) & command.variant_alpha_test != 0);
    try testing.expect(reader.submeshVariant(1) & command.variant_alpha_test == 0);
}

test "vmesh v11: submesh double_sided round-trips" {
    const verts = [_]f32{0} ** 12;
    const idx = [_]u16{ 0, 0, 0 };
    var subs = [_]Submesh{
        .{ .index_byte_off = 0, .index_count = 3, .base_color = .{ 1, 1, 1, 1 }, .metallic = 0, .roughness = 1, .emissive = .{ 0, 0, 0 }, .occlusion_strength = 1, .normal_scale = 1, .tex_base = -1, .tex_mr = -1, .tex_normal = -1, .tex_emissive = -1, .tex_occlusion = -1, .alpha_mode = 0, .alpha_cutoff = 0.5, .double_sided = 1 },
    };
    const bytes = try pack(testing.allocator, &verts, &idx, &subs, &.{}, &.{}, &.{}, &.{}, false, &.{}, &.{}, &.{}, null, &.{}, 0, null);
    defer testing.allocator.free(bytes);
    const reader = try Reader.init(bytes);
    try testing.expectEqual(@as(u32, 14), version);
    try testing.expectEqual(@as(u32, 84), submesh_size);
    try testing.expectEqual(@as(u32, 1), reader.submesh(0).double_sided);
}

test "(i) submeshVariant: double_sided adds variant_double_sided" {
    const verts = [_]f32{0} ** 12;
    const idx = [_]u16{ 0, 0, 0 };
    var subs = [_]Submesh{
        .{ .index_byte_off = 0, .index_count = 3, .base_color = .{ 1, 1, 1, 1 }, .metallic = 0, .roughness = 1, .emissive = .{ 0, 0, 0 }, .occlusion_strength = 1, .normal_scale = 1, .tex_base = -1, .tex_mr = -1, .tex_normal = -1, .tex_emissive = -1, .tex_occlusion = -1, .double_sided = 1 },
        .{ .index_byte_off = 0, .index_count = 3, .base_color = .{ 1, 1, 1, 1 }, .metallic = 0, .roughness = 1, .emissive = .{ 0, 0, 0 }, .occlusion_strength = 1, .normal_scale = 1, .tex_base = -1, .tex_mr = -1, .tex_normal = -1, .tex_emissive = -1, .tex_occlusion = -1, .double_sided = 0 },
    };
    const bytes = try pack(testing.allocator, &verts, &idx, &subs, &.{}, &.{}, &.{}, &.{}, false, &.{}, &.{}, &.{}, null, &.{}, 0, null);
    defer testing.allocator.free(bytes);
    const reader = try Reader.init(bytes);
    try testing.expect(reader.submeshVariant(0) & command.variant_double_sided != 0);
    try testing.expect(reader.submeshVariant(1) & command.variant_double_sided == 0);
}

test "vmesh v12: instances section round-trips" {
    const verts = [_]f32{0} ** 12;
    const idx = [_]u16{ 0, 0, 0 };
    var subs = [_]Submesh{
        .{ .index_byte_off = 0, .index_count = 3, .base_color = .{ 1, 1, 1, 1 }, .metallic = 0, .roughness = 1, .emissive = .{ 0, 0, 0 }, .occlusion_strength = 1, .normal_scale = 1, .tex_base = -1, .tex_mr = -1, .tex_normal = -1, .tex_emissive = -1, .tex_occlusion = -1 },
    };
    // two instances: identity@white, translate(2,0,0)@red
    // Each row: 16 f32 mat4 (col-major) then 4 f32 color rgba = 20 f32 = 80 B.
    // inst 0: identity mat4, white color (1,1,1,1)
    // inst 1: translate(2,0,0) mat4 (col3 x=2), red color (1,0,0,1)
    const insts = [_]f32{
        1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 1, 1, 1, 1,
        1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 2, 0, 0, 1, 1, 0, 0, 1,
    };
    const bytes = try pack(testing.allocator, &verts, &idx, &subs, &.{}, &.{}, &.{}, &.{}, false, &.{}, &.{}, &.{}, null, &insts, 2, null);
    defer testing.allocator.free(bytes);
    const reader = try Reader.init(bytes);
    try testing.expectEqual(@as(u32, 14), version);
    try testing.expectEqual(@as(u32, 2), reader.instanceCount());
    const blob = reader.instances();
    try testing.expectEqual(@as(usize, 2 * 80), blob.len);
    // instance 1 color.r == 1, color.g == 0 (red) — bytes at offset 80 + 64 = 144
    const c1g = std.mem.readInt(u32, blob[80 + 64 + 4 ..][0..4], .little);
    try testing.expectEqual(@as(f32, 0), @as(f32, @bitCast(c1g)));
}

// ── v13 morph section ─────────────────────────────────────────────────────────

/// Build a minimal vmesh with a morph section: `targets` morph targets,
/// `verts_per_target` vertices. Fills known f16 delta values so we can spot-check.
fn buildMorphFixture(
    alloc: std.mem.Allocator,
    comptime opts: struct { targets: u32, verts: u32 },
) ![]u8 {
    // Minimal geometry: one triangle, 2 base vertices (index 3 times), no textures.
    const base_verts = [_]f32{
        0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 0, 0,
        1, 0, 0, 0, 0, 1, 1, 0, 0, 1, 1, 0,
    };
    const base_idx = [_]u16{ 0, 1, 0 };
    const sub = Submesh{
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
    };

    // Build delta blob: target-major, vertex-major.
    // Per (target t, vertex v): 3 f16 POSITION delta, 3 f16 NORMAL delta, 3 f16 TANGENT delta (v14).
    // We fill with known values so we can spot-check:
    //   target 0, vertex 0, POSITION.x = @as(f16, 0.5)
    const target_count: u32 = opts.targets;
    const vertex_count: u32 = opts.verts;
    const delta_f16_count: usize = @as(usize, target_count) * @as(usize, vertex_count) * 9; // 9 f16/record (v14)
    const delta_bytes_count: usize = delta_f16_count * 2;
    const delta_buf = try alloc.alloc(u8, delta_bytes_count);
    defer alloc.free(delta_buf);
    @memset(delta_buf, 0);
    // target 0, vertex 0, component 0 (POSITION.x) = 0.5
    const f16_0_5: u16 = @bitCast(@as(f16, 0.5));
    std.mem.writeInt(u16, delta_buf[0..2], f16_0_5, .little);

    // Weight clip: 1 track (target 0 only) with 2 keys: t=0 w=0, t=1 w=1.
    const wc_times = [_]f32{ 0.0, 1.0 };
    const wc_values = [_]f32{ 0.0, 1.0 };
    // One track per target (only target 0 has keys; others get 1 key at t=0 w=0)
    const wc_times_zero = [_]f32{0.0};
    const wc_vals_zero = [_]f32{0.0};

    // Build tracks array: target_count tracks, comps=1
    var tracks_buf = try alloc.alloc(Track, target_count);
    defer alloc.free(tracks_buf);
    tracks_buf[0] = .{ .interp = 0, .times = &wc_times, .values = &wc_values };
    for (tracks_buf[1..]) |*tr| {
        tr.* = .{ .interp = 0, .times = &wc_times_zero, .values = &wc_vals_zero };
    }

    const wclip = Clip{
        .name_hash = fnv1a32("morph_weights"),
        .duration = 1.0,
        .tracks = tracks_buf,
    };

    const morph = MorphData{
        .target_count = target_count,
        .vertex_count = vertex_count,
        .deltas = delta_buf,
        .weight_clip = wclip,
    };

    return pack(
        alloc,
        &base_verts,
        &base_idx,
        &[_]Submesh{sub},
        &.{},
        &.{},
        &.{},
        &.{},
        false,
        &.{},
        &.{},
        &.{},
        null,
        &.{},
        0,
        morph,
    );
}

/// Build a plain vmesh (no morph section) for the back-compat check.
fn buildPlainFixture(alloc: std.mem.Allocator) ![]u8 {
    const base_verts = [_]f32{
        0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 0, 0,
    };
    const base_idx = [_]u16{ 0, 0, 0 };
    const sub = Submesh{
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
    };
    return pack(alloc, &base_verts, &base_idx, &[_]Submesh{sub}, &.{}, &.{}, &.{}, &.{}, false, &.{}, &.{}, &.{}, null, &.{}, 0, null);
}

test "vmesh v13 morph section round-trips; pre-morph mesh reads as zero morphs" {
    // Build a mesh with 2 morph targets, 3 vertices, known f16 deltas,
    // and a weight clip with target_count tracks (2 keys for target 0).
    const bytes = try buildMorphFixture(testing.allocator, .{ .targets = 2, .verts = 3 });
    defer testing.allocator.free(bytes);

    var r = try Reader.init(bytes);
    try testing.expectEqual(@as(u32, 14), r.fileVersion());
    try testing.expectEqual(@as(u32, 2), r.morphTargetCount());
    try testing.expectEqual(@as(u32, 3), r.morphVertexCount());
    try testing.expectEqual(@as(usize, 2 * 3 * 9 * @sizeOf(f16)), r.morphDeltas().len);

    // Spot-check: target 0, vertex 0, POSITION.x = 0.5 (f16 round-trip).
    const deltas = r.morphDeltas();
    const px: f16 = @bitCast(std.mem.readInt(u16, deltas[0..2], .little));
    try testing.expectApproxEqAbs(@as(f16, 0.5), px, 0.001);

    // Weight clip: target 0 track has 2 keys.
    const tr0 = r.morphWeightTrack(0);
    try testing.expect(tr0 != null);
    try testing.expectEqual(@as(u32, 2), tr0.?.key_count);
    try testing.expectEqual(@as(u8, 0), tr0.?.interp); // LINEAR
    try testing.expectEqual(@as(u32, 1), tr0.?.comps); // scalar weight

    // Time and value round-trip for track 0.
    try testing.expectApproxEqAbs(@as(f32, 0.0), r.morphWeightTime(tr0.?, 0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), r.morphWeightTime(tr0.?, 1), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), r.morphWeightValue(tr0.?, 0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), r.morphWeightValue(tr0.?, 1), 1e-6);

    // morph_off is 16-aligned.
    const moff = std.mem.readInt(u32, bytes[76..80], .little);
    try testing.expectEqual(@as(u32, 0), moff % 16);

    // Header counts match.
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, bytes[80..84], .little));
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, bytes[84..88], .little));

    // A plain vmesh (no morph section) must report 0 targets, not error.
    const plain = try buildPlainFixture(testing.allocator);
    defer testing.allocator.free(plain);
    var rp = try Reader.init(plain);
    try testing.expectEqual(@as(u32, 0), rp.morphTargetCount());
    try testing.expectEqual(@as(u32, 0), rp.morphVertexCount());
    try testing.expectEqual(@as(usize, 0), rp.morphDeltas().len);
    try testing.expectEqual(@as(?TrackInfo, null), rp.morphWeightTrack(0));
    // morph_off header field is 0 (no section).
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, plain[76..80], .little));
}

test "morphWeight CUBICSPLINE: value reads point slot, tangent readers return in/out" {
    // Pack a morph mesh with 1 target, 1 vertex, CUBICSPLINE weight track.
    // CUBICSPLINE layout per key (comps=1): [inTangent, point, outTangent] (3 floats/key).
    // key0: in=0.1, point=0.5, out=0.9
    // key1: in=1.1, point=2.5, out=3.9
    const wc_times = [_]f32{ 0.0, 1.0 };
    const wc_values = [_]f32{ 0.1, 0.5, 0.9, 1.1, 2.5, 3.9 }; // interleaved in/point/out per key

    const wc_track = Track{ .interp = 2, .times = &wc_times, .values = &wc_values };
    const wclip = Clip{
        .name_hash = fnv1a32("morph_weights"),
        .duration = 1.0,
        .tracks = &[_]Track{wc_track},
    };

    // Minimal morph section: 1 target, 1 vertex, zero deltas.
    const delta_bytes_count: usize = 1 * 1 * 9 * 2;
    var deltas_buf = [_]u8{0} ** delta_bytes_count;
    const morph = MorphData{
        .target_count = 1,
        .vertex_count = 1,
        .deltas = &deltas_buf,
        .weight_clip = wclip,
    };

    // Minimal geometry: 1 triangle, 3 vertices.
    const verts = [_]f32{
        0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 0, 0,
        1, 0, 0, 0, 0, 1, 1, 0, 0, 1, 0, 0,
        0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 0,
    };
    const idx = [_]u16{ 0, 1, 2 };
    const sub = Submesh{
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
    };
    const bytes = try pack(testing.allocator, &verts, &idx, &[_]Submesh{sub}, &.{}, &.{}, &.{}, &.{}, false, &.{}, &.{}, &.{}, null, &.{}, 0, morph);
    defer testing.allocator.free(bytes);

    var r = try Reader.init(bytes);
    const trk = r.morphWeightTrack(0);
    try testing.expect(trk != null);
    try testing.expectEqual(@as(u8, 2), trk.?.interp); // CUBICSPLINE
    try testing.expectEqual(@as(u32, 2), trk.?.key_count);

    // morphWeightValue must return the POINT (middle slot), not the in-tangent.
    try testing.expectApproxEqAbs(@as(f32, 0.5), r.morphWeightValue(trk.?, 0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 2.5), r.morphWeightValue(trk.?, 1), 1e-6);

    // morphWeightInTangent: slot 0 per key (i*3 + 0).
    try testing.expectApproxEqAbs(@as(f32, 0.1), r.morphWeightInTangent(trk.?, 0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.1), r.morphWeightInTangent(trk.?, 1), 1e-6);

    // morphWeightOutTangent: slot 2 per key (i*3 + 2).
    try testing.expectApproxEqAbs(@as(f32, 0.9), r.morphWeightOutTangent(trk.?, 0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 3.9), r.morphWeightOutTangent(trk.?, 1), 1e-6);
}

test "vmesh v13 back-compat: morphRecordF16 branching" {
    // Verify morphRecordF16 returns correct values for v13 vs v14+.
    // This tests the branching logic without needing a hand-crafted v13 buffer.
    try testing.expectEqual(@as(u32, 6), morphRecordF16(13));
    try testing.expectEqual(@as(u32, 9), morphRecordF16(14));
    try testing.expectEqual(@as(u32, 9), morphRecordF16(15)); // future versions
}

test "vmesh v14 morph tangent round-trip" {
    // Pack with tangent_deltas (6-f16 pos+nrm in deltas, separate tan channel),
    // verify morphDeltas().len == tc*vc*9*2 and tangent values round-trip.
    const tc: u32 = 1;
    const vc: u32 = 2;

    // 6-f16 pos+nrm deltas (all zeros)
    const deltas_6 = [_]u8{0} ** (1 * 2 * 6 * 2);
    // tangent deltas: tc*vc*3 f16 values
    const tan_deltas_f16 = [_]f16{
        0.25, 0.0, 0.0, // target 0, vertex 0
        0.0,  0.5, 0.0, // target 0, vertex 1
    };

    const verts = [_]f32{
        0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 0, 0,
        1, 0, 0, 0, 0, 1, 1, 0, 0, 1, 0, 0,
        0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 0,
    };
    const idx = [_]u16{ 0, 1, 2 };
    const sub = Submesh{
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
    };
    const morph = MorphData{
        .target_count = tc,
        .vertex_count = vc,
        .deltas = &deltas_6,
        .tangent_deltas = &tan_deltas_f16,
    };
    const bytes = try pack(testing.allocator, &verts, &idx, &[_]Submesh{sub}, &.{}, &.{}, &.{}, &.{}, false, &.{}, &.{}, &.{}, null, &.{}, 0, morph);
    defer testing.allocator.free(bytes);

    var r = try Reader.init(bytes);
    try testing.expectEqual(@as(u32, 14), r.fileVersion());
    // Each record is 9 f16 = 18 bytes; 1 target × 2 vertices = 2 records = 36 bytes.
    try testing.expectEqual(@as(usize, 1 * 2 * 9 * @sizeOf(f16)), r.morphDeltas().len);

    const d = r.morphDeltas();
    // Record layout: [pos.x, pos.y, pos.z, nrm.x, nrm.y, nrm.z, tan.x, tan.y, tan.z] × 2 bytes each.
    // Record 0 (target 0, vertex 0): tan.x = 0.25 at byte offset 12.
    const tan_x_v0: f16 = @bitCast(std.mem.readInt(u16, d[12..14], .little));
    try testing.expectApproxEqAbs(@as(f16, 0.25), tan_x_v0, 0.001);

    // Record 1 (target 0, vertex 1) starts at byte offset 18 (9 f16 × 2 bytes).
    // tan.y = 0.5 at byte offset 18 + 14 = 32 (6th f16 within record = tan.y).
    const tan_y_v1: f16 = @bitCast(std.mem.readInt(u16, d[18 + 14 ..][0..2], .little));
    try testing.expectApproxEqAbs(@as(f16, 0.5), tan_y_v1, 0.001);
}
