//! GLB container + glTF JSON → Model intermediate.
//!
//! Native-side only (uses std.json, alloc-heavy). NOT compiled into wasm in P2;
//! gating is handled by gl.zig / build.zig (lazy analysis — chunks that never
//! reference gl.gltf pay zero size / compat cost).
//!
//! Limitations:
//! - Node transforms IGNORED — geometry is flattened in bind-pose. P-later bakes them.
//! - Normals lit in model space (no u_normal_matrix). P3 adds it.
//! - Multiple meshes/nodes: all flatten into one vertex+index pool (no scene graph).
//! - byteStride (interleaved sources) rejected with error.Unsupported; tight packing only.
//! - Only a single BIN buffer (buffers[0]) is supported; URIs rejected.
//! - Only componentType 5126 (f32) for vertex attributes, 5123 (u16) for indices.
//! - A texCoord set != 0 on any material texture is rejected (error.Unsupported);
//!   only TEXCOORD_0 is read.
//!
//! PBR (P3):
//! - Full metallic-roughness material set parsed: baseColorFactor/Texture,
//!   metallicFactor, roughnessFactor, metallicRoughnessTexture, normalTexture
//!   (+scale), emissiveFactor, emissiveTexture, occlusionTexture (+strength).
//! - TANGENT (VEC4 f32) read when present; generated via tangent.zig otherwise.
//! - Vertices interleave 12 f32/vertex (stride 48): pos3/normal3/tangent4/uv2.
//! - Neutral-texture baking: any unset tex_* slot is patched to a deduped 1×1
//!   white (base/mr/emissive/occlusion) or flat-normal (normal) texture so the
//!   runtime never branches on texture presence; ALL five tex_* are ≥ 0 in output.

const std = @import("std");
const vmesh = @import("vmesh.zig");
const png = @import("png.zig");
const tangent = @import("tangent.zig");

// ── public surface ─────────────────────────────────────────────────────────────

pub const Model = struct {
    arena: std.heap.ArenaAllocator,
    vertices: []f32, // interleaved pos3/normal3/tangent4/uv2, stride 48 — vmesh-ready
    indices: []u16,
    submeshes: []vmesh.Submesh, // index_byte_off/count into `indices`
    textures: []vmesh.Texture, // decoded RGBA8 via png.zig
    names: []const []const u8, // one per submesh; owning mesh's name (fallback "mesh{n}")

    pub fn deinit(self: *Model) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn parseGlb(alloc: std.mem.Allocator, bytes: []const u8) !Model {
    return parseGlbImpl(alloc, bytes);
}

// ── error set ──────────────────────────────────────────────────────────────────

const ParseError = error{
    /// GLB magic "glTF" not present.
    BadMagic,
    /// GLB version != 2, or structural invariant violated (missing required JSON node, etc.).
    Malformed,
    /// Feature present in input but not supported in P2 (byteStride, non-f32 attrs, etc.).
    Unsupported,
    OutOfMemory,
};

// ── GLB container constants ────────────────────────────────────────────────────

const glb_magic = "glTF";
const glb_version: u32 = 2;
const chunk_type_json: u32 = 0x4E4F534A; // "JSON"
const chunk_type_bin: u32 = 0x004E4942; // "BIN\0"

// ── implementation ─────────────────────────────────────────────────────────────

fn parseGlbImpl(backing_alloc: std.mem.Allocator, bytes: []const u8) !Model {
    // ── 1. Validate GLB header ─────────────────────────────────────────────────
    if (bytes.len < 12) return error.BadMagic;
    if (!std.mem.eql(u8, bytes[0..4], glb_magic)) return error.BadMagic;
    const ver = std.mem.readInt(u32, bytes[4..8], .little);
    if (ver != glb_version) return error.Malformed;
    const total_len = std.mem.readInt(u32, bytes[8..12], .little);
    if (total_len > bytes.len) return error.Malformed;
    const glb = bytes[0..total_len];

    // ── 2. Walk chunks ─────────────────────────────────────────────────────────
    var json_data: ?[]const u8 = null;
    var bin_data: ?[]const u8 = null;

    var chunk_off: usize = 12;
    while (chunk_off + 8 <= glb.len) {
        const chunk_len = std.mem.readInt(u32, glb[chunk_off..][0..4], .little);
        const chunk_type = std.mem.readInt(u32, glb[chunk_off + 4 ..][0..4], .little);
        const data_off = chunk_off + 8;
        // Bounds-check chunk data length against the GLB buffer
        if (data_off > glb.len or chunk_len > glb.len - data_off) return error.Malformed;
        const chunk_data = glb[data_off .. data_off + chunk_len];

        if (chunk_type == chunk_type_json) {
            json_data = chunk_data;
        } else if (chunk_type == chunk_type_bin) {
            bin_data = chunk_data;
        }
        // Unknown chunk types are silently skipped (glTF spec allows extension chunks)
        chunk_off = data_off + chunk_len;
    }

    const json_bytes = json_data orelse return error.Malformed;
    const bin = bin_data orelse &[_]u8{};

    // ── 3. Parse JSON ──────────────────────────────────────────────────────────
    // Use a temporary arena for the parsed JSON tree; it's freed before we return.
    var json_arena = std.heap.ArenaAllocator.init(backing_alloc);
    defer json_arena.deinit();
    const json_alloc = json_arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, json_alloc, json_bytes, .{}) catch return error.Malformed;
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.Malformed,
    };

    // ── 4. Extract top-level arrays ────────────────────────────────────────────
    const accessors_val = root.get("accessors") orelse return error.Malformed;
    const accessors = switch (accessors_val) {
        .array => |a| a.items,
        else => return error.Malformed,
    };

    const buffer_views_val = root.get("bufferViews") orelse return error.Malformed;
    const buffer_views = switch (buffer_views_val) {
        .array => |a| a.items,
        else => return error.Malformed,
    };

    const meshes_val = root.get("meshes") orelse return error.Malformed;
    const meshes = switch (meshes_val) {
        .array => |a| a.items,
        else => return error.Malformed,
    };

    const materials_arr = blk: {
        if (root.get("materials")) |mv| {
            switch (mv) {
                .array => |a| break :blk a.items,
                else => return error.Malformed,
            }
        }
        break :blk &[_]std.json.Value{};
    };

    const textures_arr = blk: {
        if (root.get("textures")) |tv| {
            switch (tv) {
                .array => |a| break :blk a.items,
                else => return error.Malformed,
            }
        }
        break :blk &[_]std.json.Value{};
    };

    const images_arr = blk: {
        if (root.get("images")) |iv| {
            switch (iv) {
                .array => |a| break :blk a.items,
                else => return error.Malformed,
            }
        }
        break :blk &[_]std.json.Value{};
    };

    // ── 5. Set up Model arena (owns all output allocations) ────────────────────
    var arena = std.heap.ArenaAllocator.init(backing_alloc);
    errdefer arena.deinit();
    const aa = arena.allocator();

    // ── 6. Decode textures (images) ────────────────────────────────────────────
    // First build the glTF texture list (texture → image source index),
    // then decode each referenced image bufferView with png.decode.
    var tex_list: std.ArrayList(vmesh.Texture) = .empty;

    for (textures_arr) |tex_val| {
        const tex_obj = switch (tex_val) {
            .object => |o| o,
            else => return error.Malformed,
        };
        const source_val = tex_obj.get("source") orelse return error.Malformed;
        const source_idx: usize = @intCast(jsonInt(source_val) orelse return error.Malformed);
        if (source_idx >= images_arr.len) return error.Malformed;

        const img_obj = switch (images_arr[source_idx]) {
            .object => |o| o,
            else => return error.Malformed,
        };
        const bv_idx_val = img_obj.get("bufferView") orelse return error.Malformed;
        const bv_idx: usize = @intCast(jsonInt(bv_idx_val) orelse return error.Malformed);

        const bv_slice = try getBufferViewSlice(buffer_views, bv_idx, bin);

        // Decode PNG into a temporary Image, then copy RGBA into the arena.
        var img = png.decode(backing_alloc, bv_slice) catch return error.Malformed;
        defer img.deinit(backing_alloc);

        const rgba_copy = try aa.alloc(u8, img.rgba.len);
        @memcpy(rgba_copy, img.rgba);

        try tex_list.append(aa, .{
            .width = img.width,
            .height = img.height,
            .rgba = rgba_copy,
        });
    }

    // ── 6b. Build mesh-index → node-name fallback map ──────────────────────────
    // glTF mesh names live on `meshes[i].name`; when absent we fall back to the
    // name of a node that references that mesh (`nodes[j].name` where
    // nodes[j].mesh == i), then finally to "mesh{i}". Walk `nodes` once.
    const node_mesh_names = try aa.alloc(?[]const u8, meshes.len);
    @memset(node_mesh_names, null);
    if (root.get("nodes")) |nodes_val| {
        if (nodes_val == .array) {
            for (nodes_val.array.items) |node_val| {
                const node_obj = switch (node_val) {
                    .object => |o| o,
                    else => continue,
                };
                const mesh_ref = node_obj.get("mesh") orelse continue;
                const mi: usize = @intCast(jsonInt(mesh_ref) orelse continue);
                if (mi >= meshes.len) continue;
                if (node_mesh_names[mi] != null) continue; // first node wins
                if (node_obj.get("name")) |nm_val| {
                    if (nm_val == .string) node_mesh_names[mi] = nm_val.string;
                }
            }
        }
    }

    // ── 7. Process all mesh primitives ────────────────────────────────────────
    // Flatten all meshes / all primitives into one vertex pool + index pool.
    // Each primitive becomes one Submesh.
    var vert_list: std.ArrayList(f32) = .empty;
    var idx_list: std.ArrayList(u16) = .empty;
    var sub_list: std.ArrayList(vmesh.Submesh) = .empty;
    var name_list: std.ArrayList([]const u8) = .empty;

    for (meshes, 0..) |mesh_val, mesh_i| {
        const mesh_obj = switch (mesh_val) {
            .object => |o| o,
            else => return error.Malformed,
        };
        const prims_val = mesh_obj.get("primitives") orelse return error.Malformed;
        const prims = switch (prims_val) {
            .array => |a| a.items,
            else => return error.Malformed,
        };

        // Resolve this mesh's name: meshes[i].name → referencing node name →
        // "mesh{i}". The chosen string is duped into the Model arena so it
        // outlives the JSON arena.
        const mesh_name: []const u8 = blk: {
            if (mesh_obj.get("name")) |nm_val| {
                if (nm_val == .string) break :blk try aa.dupe(u8, nm_val.string);
            }
            if (node_mesh_names[mesh_i]) |nn| break :blk try aa.dupe(u8, nn);
            break :blk try std.fmt.allocPrint(aa, "mesh{d}", .{mesh_i});
        };

        for (prims) |prim_val| {
            const prim_obj = switch (prim_val) {
                .object => |o| o,
                else => return error.Malformed,
            };

            // Vertex base offset before appending this primitive's verts
            const vert_base: u32 = @intCast(vert_list.items.len / 12); // # of vertices so far (stride 48)

            // ── Attributes ────────────────────────────────────────────────────
            const attrs_val = prim_obj.get("attributes") orelse return error.Malformed;
            const attrs = switch (attrs_val) {
                .object => |o| o,
                else => return error.Malformed,
            };

            const pos_idx_val = attrs.get("POSITION") orelse return error.Malformed;
            const pos_idx: usize = @intCast(jsonInt(pos_idx_val) orelse return error.Malformed);

            const nrm_idx_opt: ?usize = blk: {
                if (attrs.get("NORMAL")) |v| {
                    break :blk @intCast(jsonInt(v) orelse return error.Malformed);
                }
                break :blk null;
            };

            const tan_idx_opt: ?usize = blk: {
                if (attrs.get("TANGENT")) |v| {
                    break :blk @intCast(jsonInt(v) orelse return error.Malformed);
                }
                break :blk null;
            };

            const uv_idx_opt: ?usize = blk: {
                if (attrs.get("TEXCOORD_0")) |v| {
                    break :blk @intCast(jsonInt(v) orelse return error.Malformed);
                }
                break :blk null;
            };

            // Read POSITION accessor → f32 slice
            const pos_f32 = try readAccessorF32(accessors, buffer_views, bin, pos_idx, aa);
            const vert_count = pos_f32.len / 3;

            // Read NORMAL accessor if present (else default (0,0,1) below).
            // We materialize a full normal slice so tangent.generate can consume it.
            const nrm_f32: []const f32 = if (nrm_idx_opt) |ni|
                try readAccessorF32(accessors, buffer_views, bin, ni, aa)
            else blk: {
                const n = try aa.alloc(f32, vert_count * 3);
                var i: usize = 0;
                while (i < vert_count) : (i += 1) {
                    n[i * 3 + 0] = 0;
                    n[i * 3 + 1] = 0;
                    n[i * 3 + 2] = 1;
                }
                break :blk n;
            };

            // Read TEXCOORD_0 accessor if present (else (0,0)).
            const uv_f32: []const f32 = if (uv_idx_opt) |ui|
                try readAccessorF32(accessors, buffer_views, bin, ui, aa)
            else blk: {
                const uv = try aa.alloc(f32, vert_count * 2);
                @memset(uv, 0);
                break :blk uv;
            };

            // ── Indices ───────────────────────────────────────────────────────
            const idx_acc_val = prim_obj.get("indices") orelse return error.Malformed;
            const idx_acc_idx: usize = @intCast(jsonInt(idx_acc_val) orelse return error.Malformed);
            const raw_indices = try readAccessorU16(accessors, buffer_views, bin, idx_acc_idx, aa);

            // ── Tangents: read VEC4 attribute, else generate ──────────────────
            const tan_f32: []const f32 = if (tan_idx_opt) |ti|
                try readAccessorVec4F32(accessors, buffer_views, bin, ti, aa)
            else
                tangent.generate(aa, pos_f32, nrm_f32, uv_f32, raw_indices) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidInput => return error.Malformed,
                };

            // ── Interleave pos/normal/tangent/uv into stride-48 layout ─────────
            try vert_list.ensureUnusedCapacity(aa, vert_count * 12);
            for (0..vert_count) |vi| {
                // pos
                vert_list.appendAssumeCapacity(pos_f32[vi * 3 + 0]);
                vert_list.appendAssumeCapacity(pos_f32[vi * 3 + 1]);
                vert_list.appendAssumeCapacity(pos_f32[vi * 3 + 2]);
                // normal
                vert_list.appendAssumeCapacity(nrm_f32[vi * 3 + 0]);
                vert_list.appendAssumeCapacity(nrm_f32[vi * 3 + 1]);
                vert_list.appendAssumeCapacity(nrm_f32[vi * 3 + 2]);
                // tangent (xyz, w=handedness)
                vert_list.appendAssumeCapacity(tan_f32[vi * 4 + 0]);
                vert_list.appendAssumeCapacity(tan_f32[vi * 4 + 1]);
                vert_list.appendAssumeCapacity(tan_f32[vi * 4 + 2]);
                vert_list.appendAssumeCapacity(tan_f32[vi * 4 + 3]);
                // uv
                vert_list.appendAssumeCapacity(uv_f32[vi * 2 + 0]);
                vert_list.appendAssumeCapacity(uv_f32[vi * 2 + 1]);
            }

            // Submesh index_byte_off is byte offset into the index buffer
            const index_byte_off = std.math.cast(u32, idx_list.items.len * 2) orelse
                return error.Malformed;

            // Rebase indices by vert_base. u16 indices cap the flat pool
            // at 65535 vertices — hostile counts must error, not panic.
            const base_u16 = std.math.cast(u16, vert_base) orelse return error.Malformed;
            try idx_list.ensureUnusedCapacity(aa, raw_indices.len);
            for (raw_indices) |raw_idx| {
                const rebased = std.math.add(u16, raw_idx, base_u16) catch
                    return error.Malformed;
                idx_list.appendAssumeCapacity(rebased);
            }

            // ── Material (full metallic-roughness set) ─────────────────────────
            var base_color: [4]f32 = .{ 1, 1, 1, 1 };
            var metallic: f32 = 1.0;
            var roughness: f32 = 1.0;
            var emissive: [3]f32 = .{ 0, 0, 0 };
            var occlusion_strength: f32 = 1.0;
            var normal_scale: f32 = 1.0;
            var tex_base: i32 = -1;
            var tex_mr: i32 = -1;
            var tex_normal: i32 = -1;
            var tex_emissive: i32 = -1;
            var tex_occlusion: i32 = -1;

            if (prim_obj.get("material")) |mat_val| {
                const mat_idx: usize = @intCast(jsonInt(mat_val) orelse return error.Malformed);
                if (mat_idx < materials_arr.len) {
                    const mat_obj = switch (materials_arr[mat_idx]) {
                        .object => |o| o,
                        else => return error.Malformed,
                    };
                    if (mat_obj.get("pbrMetallicRoughness")) |pbr_val| {
                        const pbr = switch (pbr_val) {
                            .object => |o| o,
                            else => return error.Malformed,
                        };
                        // baseColorFactor (default [1,1,1,1])
                        if (pbr.get("baseColorFactor")) |bcf_val| {
                            const bcf = switch (bcf_val) {
                                .array => |a| a.items,
                                else => return error.Malformed,
                            };
                            if (bcf.len >= 4) {
                                for (0..4) |ci| {
                                    base_color[ci] = jsonFloat(bcf[ci]) orelse 1.0;
                                }
                            }
                        }
                        // metallicFactor / roughnessFactor (default 1.0 each)
                        if (pbr.get("metallicFactor")) |mv| {
                            metallic = jsonFloat(mv) orelse return error.Malformed;
                        }
                        if (pbr.get("roughnessFactor")) |rv| {
                            roughness = jsonFloat(rv) orelse return error.Malformed;
                        }
                        // baseColorTexture / metallicRoughnessTexture
                        tex_base = try readTextureInfo(pbr.get("baseColorTexture"), null);
                        tex_mr = try readTextureInfo(pbr.get("metallicRoughnessTexture"), null);
                    }
                    // normalTexture (+scale)
                    tex_normal = try readTextureInfo(mat_obj.get("normalTexture"), &normal_scale);
                    // emissiveTexture / emissiveFactor (default [0,0,0])
                    tex_emissive = try readTextureInfo(mat_obj.get("emissiveTexture"), null);
                    if (mat_obj.get("emissiveFactor")) |ef_val| {
                        const ef = switch (ef_val) {
                            .array => |a| a.items,
                            else => return error.Malformed,
                        };
                        if (ef.len >= 3) {
                            for (0..3) |ci| emissive[ci] = jsonFloat(ef[ci]) orelse 0.0;
                        }
                    }
                    // occlusionTexture (+strength, key "strength")
                    tex_occlusion = try readTextureInfo(mat_obj.get("occlusionTexture"), &occlusion_strength);
                }
            }

            try sub_list.append(aa, .{
                .index_byte_off = index_byte_off,
                .index_count = @intCast(raw_indices.len),
                .base_color = base_color,
                .metallic = metallic,
                .roughness = roughness,
                .emissive = emissive,
                .occlusion_strength = occlusion_strength,
                .normal_scale = normal_scale,
                .tex_base = tex_base,
                .tex_mr = tex_mr,
                .tex_normal = tex_normal,
                .tex_emissive = tex_emissive,
                .tex_occlusion = tex_occlusion,
            });
            try name_list.append(aa, mesh_name);
        }
    }

    // ── 7b. Neutral-texture baking ─────────────────────────────────────────────
    // Downstream the runtime never branches on texture presence: every tex_* slot
    // must resolve to a real texture. For any unset slot (== -1), patch it to a
    // deduped 1×1 neutral:
    //   - white (255,255,255,255): base/mr/emissive/occlusion slots,
    //   - flat-normal (128,128,255,255): normal slot.
    // The two neutral textures are appended once (deduped) only if referenced.
    {
        var white_idx: i32 = -1;
        var flat_idx: i32 = -1;
        for (sub_list.items) |*s| {
            // White-backed slots.
            inline for (.{ "tex_base", "tex_mr", "tex_emissive", "tex_occlusion" }) |field| {
                if (@field(s, field) < 0) {
                    if (white_idx < 0) {
                        const px = try aa.alloc(u8, 4);
                        px[0] = 255;
                        px[1] = 255;
                        px[2] = 255;
                        px[3] = 255;
                        white_idx = @intCast(tex_list.items.len);
                        try tex_list.append(aa, .{ .width = 1, .height = 1, .rgba = px });
                    }
                    @field(s, field) = white_idx;
                }
            }
            // Flat-normal slot.
            if (s.tex_normal < 0) {
                if (flat_idx < 0) {
                    const px = try aa.alloc(u8, 4);
                    px[0] = 128;
                    px[1] = 128;
                    px[2] = 255;
                    px[3] = 255;
                    flat_idx = @intCast(tex_list.items.len);
                    try tex_list.append(aa, .{ .width = 1, .height = 1, .rgba = px });
                }
                s.tex_normal = flat_idx;
            }
        }
    }

    // ── 8. Package Model ───────────────────────────────────────────────────────
    return Model{
        .arena = arena,
        .vertices = vert_list.items,
        .indices = idx_list.items,
        .submeshes = sub_list.items,
        .textures = tex_list.items,
        .names = name_list.items,
    };
}

// ── helpers ────────────────────────────────────────────────────────────────────

/// Get a typed integer from a json.Value (integer or float that is whole).
fn jsonInt(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| blk: {
            const i: i64 = @intFromFloat(f);
            break :blk if (@as(f64, @floatFromInt(i)) == f) i else null;
        },
        else => null,
    };
}

fn jsonFloat(v: std.json.Value) ?f32 {
    return switch (v) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

/// Read a glTF textureInfo object: returns its `index` (or -1 when absent).
/// A texCoord set other than 0 is rejected (error.Unsupported) — only
/// TEXCOORD_0 is read. If `scalar_out` is non-null, the textureInfo's
/// `scale` (normalTexture) or `strength` (occlusionTexture) scalar is written
/// there when present (the field name differs per texture but never collides
/// on the same object, so we accept either key).
fn readTextureInfo(info_opt: ?std.json.Value, scalar_out: ?*f32) !i32 {
    const info_val = info_opt orelse return -1;
    const obj = switch (info_val) {
        .object => |o| o,
        else => return error.Malformed,
    };
    if (obj.get("texCoord")) |tc_val| {
        const tc = jsonInt(tc_val) orelse return error.Malformed;
        if (tc != 0) return error.Unsupported;
    }
    if (scalar_out) |out| {
        if (obj.get("scale")) |sv| {
            out.* = jsonFloat(sv) orelse return error.Malformed;
        } else if (obj.get("strength")) |sv| {
            out.* = jsonFloat(sv) orelse return error.Malformed;
        }
    }
    const idx_val = obj.get("index") orelse return error.Malformed;
    return @intCast(jsonInt(idx_val) orelse return error.Malformed);
}

/// Extract a buffer view's byte slice from the BIN chunk.
/// Bounds-checked against `bin.len`.
fn getBufferViewSlice(
    buffer_views: []const std.json.Value,
    bv_idx: usize,
    bin: []const u8,
) ![]const u8 {
    if (bv_idx >= buffer_views.len) return error.Malformed;
    const bv_obj = switch (buffer_views[bv_idx]) {
        .object => |o| o,
        else => return error.Malformed,
    };

    // byteStride on a bufferView → interleaved source, not supported in P2
    if (bv_obj.get("byteStride") != null) return error.Unsupported;

    const byte_off_val = bv_obj.get("byteOffset") orelse std.json.Value{ .integer = 0 };
    const byte_len_val = bv_obj.get("byteLength") orelse return error.Malformed;

    const byte_off: usize = @intCast(jsonInt(byte_off_val) orelse return error.Malformed);
    const byte_len: usize = @intCast(jsonInt(byte_len_val) orelse return error.Malformed);

    // Bounds-check byteOffset + byteLength vs BIN length
    if (byte_off > bin.len or byte_len > bin.len - byte_off) return error.Malformed;

    return bin[byte_off .. byte_off + byte_len];
}

/// Read a glTF accessor as a slice of f32 (alloc-owned via aa).
/// Validates componentType == 5126 (f32), tight packing, bounds.
fn readAccessorF32(
    accessors: []const std.json.Value,
    buffer_views: []const std.json.Value,
    bin: []const u8,
    acc_idx: usize,
    aa: std.mem.Allocator,
) ![]const f32 {
    if (acc_idx >= accessors.len) return error.Malformed;
    const acc_obj = switch (accessors[acc_idx]) {
        .object => |o| o,
        else => return error.Malformed,
    };

    const component_type_val = acc_obj.get("componentType") orelse return error.Malformed;
    const component_type = jsonInt(component_type_val) orelse return error.Malformed;
    if (component_type != 5126) return error.Unsupported; // must be f32

    const count_val = acc_obj.get("count") orelse return error.Malformed;
    const count: usize = @intCast(jsonInt(count_val) orelse return error.Malformed);

    const type_val = acc_obj.get("type") orelse return error.Malformed;
    const type_str = switch (type_val) {
        .string => |s| s,
        else => return error.Malformed,
    };
    const components_per_elem: usize = componentsForType(type_str) orelse return error.Unsupported;

    const bv_idx_val = acc_obj.get("bufferView") orelse return error.Malformed;
    const bv_idx: usize = @intCast(jsonInt(bv_idx_val) orelse return error.Malformed);

    const byte_off_in_acc: usize = blk: {
        if (acc_obj.get("byteOffset")) |bov| {
            break :blk @intCast(jsonInt(bov) orelse return error.Malformed);
        }
        break :blk 0;
    };

    const bv_slice = try getBufferViewSlice(buffer_views, bv_idx, bin);

    const component_size: usize = 4; // f32
    const total_bytes = count * components_per_elem * component_size;

    // Bounds-check accessor within its bufferView
    if (byte_off_in_acc > bv_slice.len or total_bytes > bv_slice.len - byte_off_in_acc) return error.Malformed;

    const raw = bv_slice[byte_off_in_acc .. byte_off_in_acc + total_bytes];
    const n_floats = count * components_per_elem;
    const result = try aa.alloc(f32, n_floats);
    for (0..n_floats) |i| {
        const bits = std.mem.readInt(u32, raw[i * 4 ..][0..4], .little);
        result[i] = @bitCast(bits);
    }
    return result;
}

/// Read a VEC4 f32 accessor (e.g. TANGENT) → flat 4-f32-per-element slice.
/// Validates the accessor type is exactly VEC4 before reading.
fn readAccessorVec4F32(
    accessors: []const std.json.Value,
    buffer_views: []const std.json.Value,
    bin: []const u8,
    acc_idx: usize,
    aa: std.mem.Allocator,
) ![]const f32 {
    if (acc_idx >= accessors.len) return error.Malformed;
    const acc_obj = switch (accessors[acc_idx]) {
        .object => |o| o,
        else => return error.Malformed,
    };
    const type_val = acc_obj.get("type") orelse return error.Malformed;
    const type_str = switch (type_val) {
        .string => |s| s,
        else => return error.Malformed,
    };
    if (!std.mem.eql(u8, type_str, "VEC4")) return error.Unsupported;
    return readAccessorF32(accessors, buffer_views, bin, acc_idx, aa);
}

/// Read a glTF accessor as a slice of u16 (alloc-owned via aa).
/// Validates componentType == 5123 (u16 / UNSIGNED_SHORT), SCALAR, bounds.
fn readAccessorU16(
    accessors: []const std.json.Value,
    buffer_views: []const std.json.Value,
    bin: []const u8,
    acc_idx: usize,
    aa: std.mem.Allocator,
) ![]const u16 {
    if (acc_idx >= accessors.len) return error.Malformed;
    const acc_obj = switch (accessors[acc_idx]) {
        .object => |o| o,
        else => return error.Malformed,
    };

    const component_type_val = acc_obj.get("componentType") orelse return error.Malformed;
    const component_type = jsonInt(component_type_val) orelse return error.Malformed;
    if (component_type != 5123) return error.Unsupported; // must be UNSIGNED_SHORT

    const count_val = acc_obj.get("count") orelse return error.Malformed;
    const count: usize = @intCast(jsonInt(count_val) orelse return error.Malformed);

    const type_val = acc_obj.get("type") orelse return error.Malformed;
    const type_str = switch (type_val) {
        .string => |s| s,
        else => return error.Malformed,
    };
    if (!std.mem.eql(u8, type_str, "SCALAR")) return error.Unsupported;

    const bv_idx_val = acc_obj.get("bufferView") orelse return error.Malformed;
    const bv_idx: usize = @intCast(jsonInt(bv_idx_val) orelse return error.Malformed);

    const byte_off_in_acc: usize = blk: {
        if (acc_obj.get("byteOffset")) |bov| {
            break :blk @intCast(jsonInt(bov) orelse return error.Malformed);
        }
        break :blk 0;
    };

    const bv_slice = try getBufferViewSlice(buffer_views, bv_idx, bin);

    const total_bytes = count * 2; // u16

    // Bounds-check accessor within its bufferView
    if (byte_off_in_acc > bv_slice.len or total_bytes > bv_slice.len - byte_off_in_acc) return error.Malformed;

    const raw = bv_slice[byte_off_in_acc .. byte_off_in_acc + total_bytes];
    const result = try aa.alloc(u16, count);
    for (0..count) |i| {
        result[i] = std.mem.readInt(u16, raw[i * 2 ..][0..2], .little);
    }
    return result;
}

/// Number of scalar components for a glTF accessor type string.
fn componentsForType(t: []const u8) ?usize {
    if (std.mem.eql(u8, t, "SCALAR")) return 1;
    if (std.mem.eql(u8, t, "VEC2")) return 2;
    if (std.mem.eql(u8, t, "VEC3")) return 3;
    if (std.mem.eql(u8, t, "VEC4")) return 4;
    if (std.mem.eql(u8, t, "MAT2")) return 4;
    if (std.mem.eql(u8, t, "MAT3")) return 9;
    if (std.mem.eql(u8, t, "MAT4")) return 16;
    return null;
}

// ── tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "parse fixture cube (P2 textured, v2 layout + neutral baking)" {
    const glb = try @import("fixture.zig").texturedCubeGlb(testing.allocator);
    defer testing.allocator.free(glb);
    var model = try parseGlb(testing.allocator, glb);
    defer model.deinit();
    try testing.expectEqual(@as(usize, 24 * 12), model.vertices.len); // stride 48 interleaved
    try testing.expectEqual(@as(usize, 36), model.indices.len);
    try testing.expectEqual(@as(usize, 1), model.submeshes.len);
    const s = model.submeshes[0];
    // baseColorTexture → tex_base 0; all other slots neutral-baked → ≥ 0.
    try testing.expectEqual(@as(i32, 0), s.tex_base);
    try testing.expect(s.tex_mr >= 0);
    try testing.expect(s.tex_normal >= 0);
    try testing.expect(s.tex_emissive >= 0);
    try testing.expect(s.tex_occlusion >= 0);
    // 1 original + 1 white (shared base/mr/emissive/occlusion) + 1 flat-normal.
    try testing.expectEqual(@as(usize, 3), model.textures.len);
    try testing.expectEqual(@as(u32, 8), model.textures[0].width);
    // a +z face vertex has normal (0,0,1): find any vertex with nz≈1 (stride 12, normal@3)
    var found = false;
    var i: usize = 0;
    while (i < model.vertices.len) : (i += 12) {
        if (model.vertices[i + 5] > 0.99) found = true;
    }
    try testing.expect(found);
}

test "rejects non-glb" {
    try testing.expectError(error.BadMagic, parseGlb(testing.allocator, "junk0000junk0000"));
}

// ── P3 full-PBR parse tests ─────────────────────────────────────────────────────

test "parse pbrCubeGlb (with_tangents=true): full material + read tangents" {
    const glb = try @import("fixture.zig").pbrCubeGlb(testing.allocator, .{ .with_tangents = true });
    defer testing.allocator.free(glb);
    var model = try parseGlb(testing.allocator, glb);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 24 * 12), model.vertices.len);
    try testing.expectEqual(@as(usize, 1), model.submeshes.len);
    // names: one per submesh; pbrCubeGlb's mesh is named "Cube".
    try testing.expectEqual(model.submeshes.len, model.names.len);
    try testing.expectEqualStrings("Cube", model.names[0]);
    const s = model.submeshes[0];
    try testing.expectApproxEqAbs(@as(f32, 1.0), s.metallic, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), s.roughness, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), s.emissive[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), s.emissive[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), s.emissive[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.8), s.occlusion_strength, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), s.normal_scale, 1e-6);
    // All five tex_* ≥ 0 and distinct (fixture maps all distinct).
    try testing.expect(s.tex_base >= 0);
    try testing.expect(s.tex_mr >= 0);
    try testing.expect(s.tex_normal >= 0);
    try testing.expect(s.tex_emissive >= 0);
    try testing.expect(s.tex_occlusion >= 0);
    try testing.expectEqual(@as(usize, 5), model.textures.len);
    // distinctness
    const slots = [_]i32{ s.tex_base, s.tex_mr, s.tex_normal, s.tex_emissive, s.tex_occlusion };
    for (0..5) |a| for (a + 1..5) |b| try testing.expect(slots[a] != slots[b]);

    // A +Z-face vertex has normal (0,0,1); its tangent ≈ (1,0,0,±1).
    var checked = false;
    var i: usize = 0;
    while (i < model.vertices.len) : (i += 12) {
        if (model.vertices[i + 5] > 0.99) { // nz ≈ 1 → +Z face
            try testing.expectApproxEqAbs(@as(f32, 1.0), model.vertices[i + 6], 1e-5); // tangent.x
            try testing.expectApproxEqAbs(@as(f32, 0.0), model.vertices[i + 7], 1e-5); // tangent.y
            try testing.expectApproxEqAbs(@as(f32, 0.0), model.vertices[i + 8], 1e-5); // tangent.z
            try testing.expect(@abs(model.vertices[i + 9]) == 1.0); // w = ±1
            checked = true;
        }
    }
    try testing.expect(checked);
}

test "parse pbrCubeGlb (with_tangents=false): generated tangents valid" {
    const glb = try @import("fixture.zig").pbrCubeGlb(testing.allocator, .{ .with_tangents = false });
    defer testing.allocator.free(glb);
    var model = try parseGlb(testing.allocator, glb);
    defer model.deinit();
    try testing.expectEqual(@as(usize, 24 * 12), model.vertices.len);

    var i: usize = 0;
    while (i < model.vertices.len) : (i += 12) {
        const nx = model.vertices[i + 3];
        const ny = model.vertices[i + 4];
        const nz = model.vertices[i + 5];
        const tx = model.vertices[i + 6];
        const ty = model.vertices[i + 7];
        const tz = model.vertices[i + 8];
        // finite
        try testing.expect(std.math.isFinite(tx) and std.math.isFinite(ty) and std.math.isFinite(tz));
        // unit length
        const len = @sqrt(tx * tx + ty * ty + tz * tz);
        try testing.expectApproxEqAbs(@as(f32, 1.0), len, 1e-4);
        // perpendicular to normal
        const dot = tx * nx + ty * ny + tz * nz;
        try testing.expectApproxEqAbs(@as(f32, 0.0), dot, 1e-4);
    }
}

test "neutral-texture baking: no textures → deduped neutrals appended" {
    // Minimal cube-less glb: a single triangle, material with NO textures.
    const glb = try minimalNoTextureGlb(testing.allocator);
    defer testing.allocator.free(glb);
    var model = try parseGlb(testing.allocator, glb);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 1), model.submeshes.len);
    const s = model.submeshes[0];
    // All five tex_* ≥ 0 after baking.
    try testing.expect(s.tex_base >= 0);
    try testing.expect(s.tex_mr >= 0);
    try testing.expect(s.tex_normal >= 0);
    try testing.expect(s.tex_emissive >= 0);
    try testing.expect(s.tex_occlusion >= 0);
    // White shared across base/mr/emissive/occlusion.
    try testing.expectEqual(s.tex_base, s.tex_mr);
    try testing.expectEqual(s.tex_base, s.tex_emissive);
    try testing.expectEqual(s.tex_base, s.tex_occlusion);
    // Flat-normal distinct from white.
    try testing.expect(s.tex_normal != s.tex_base);
    // Started with 0 textures; grows by exactly 2 (white + flat-normal).
    try testing.expectEqual(@as(usize, 2), model.textures.len);
    // White texel = (255,255,255,255); flat-normal = (128,128,255,255).
    const white = model.textures[@intCast(s.tex_base)];
    try testing.expectEqual(@as(u32, 1), white.width);
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, white.rgba);
    const flat = model.textures[@intCast(s.tex_normal)];
    try testing.expectEqualSlices(u8, &.{ 128, 128, 255, 255 }, flat.rgba);
}

test "names: mesh + node both unnamed → fallback \"mesh0\"" {
    // minimalNoTextureGlb: mesh has no "name", node {"mesh":0} has no "name" →
    // submesh name falls back to "mesh{mesh_index}" == "mesh0".
    const glb = try minimalNoTextureGlb(testing.allocator);
    defer testing.allocator.free(glb);
    var model = try parseGlb(testing.allocator, glb);
    defer model.deinit();
    try testing.expectEqual(model.submeshes.len, model.names.len);
    try testing.expectEqual(@as(usize, 1), model.names.len);
    try testing.expectEqualStrings("mesh0", model.names[0]);
}

test "rejects texCoord != 0" {
    const glb = try texCoord1Glb(testing.allocator);
    defer testing.allocator.free(glb);
    try testing.expectError(error.Unsupported, parseGlb(testing.allocator, glb));
}

// ── test-only minimal glb builders ──────────────────────────────────────────────

/// One triangle (3 verts, 3 indices), material with NO textures (only factors).
/// BIN: POSITION(36) NORMAL(36) TEXCOORD_0(24) indices(6).
fn minimalNoTextureGlb(alloc: std.mem.Allocator) ![]u8 {
    const pos = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    const nrm = [_]f32{ 0, 0, 1, 0, 0, 1, 0, 0, 1 };
    const uv = [_]f32{ 0, 0, 1, 0, 0, 1 };
    const idx = [_]u16{ 0, 1, 2 };
    const json =
        "{\"asset\":{\"version\":\"2.0\"}," ++
        "\"scene\":0,\"scenes\":[{\"nodes\":[0]}],\"nodes\":[{\"mesh\":0}]," ++
        "\"meshes\":[{\"primitives\":[{\"attributes\":{\"POSITION\":0,\"NORMAL\":1,\"TEXCOORD_0\":2},\"indices\":3,\"material\":0}]}]," ++
        "\"accessors\":[" ++
        "{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}," ++
        "{\"bufferView\":1,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}," ++
        "{\"bufferView\":2,\"componentType\":5126,\"count\":3,\"type\":\"VEC2\"}," ++
        "{\"bufferView\":3,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"}]," ++
        "\"bufferViews\":[" ++
        "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36}," ++
        "{\"buffer\":0,\"byteOffset\":36,\"byteLength\":36}," ++
        "{\"buffer\":0,\"byteOffset\":72,\"byteLength\":24}," ++
        "{\"buffer\":0,\"byteOffset\":96,\"byteLength\":6,\"target\":34963}]," ++
        "\"buffers\":[{\"byteLength\":102}]," ++
        "\"materials\":[{\"pbrMetallicRoughness\":{\"metallicFactor\":0.0,\"roughnessFactor\":0.5}}]}";
    return assembleGlb(alloc, json, &pos, &nrm, &uv, &idx, null);
}

/// Same triangle but baseColorTexture references texCoord 1 → must error.
fn texCoord1Glb(alloc: std.mem.Allocator) ![]u8 {
    const pos = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    const nrm = [_]f32{ 0, 0, 1, 0, 0, 1, 0, 0, 1 };
    const uv = [_]f32{ 0, 0, 1, 0, 0, 1 };
    const idx = [_]u16{ 0, 1, 2 };
    // 1x1 white PNG appended after indices (bufferView 4).
    const px = [_]u8{ 255, 255, 255, 255 };
    const png_bytes = try png.encodeRgba(alloc, &px, 1, 1);
    defer alloc.free(png_bytes);
    var json_aw: std.Io.Writer.Allocating = .init(alloc);
    defer json_aw.deinit();
    const w = &json_aw.writer;
    try w.writeAll("{\"asset\":{\"version\":\"2.0\"},\"scene\":0,\"scenes\":[{\"nodes\":[0]}],\"nodes\":[{\"mesh\":0}],");
    try w.writeAll("\"meshes\":[{\"primitives\":[{\"attributes\":{\"POSITION\":0,\"NORMAL\":1,\"TEXCOORD_0\":2},\"indices\":3,\"material\":0}]}],");
    try w.writeAll("\"accessors\":[");
    try w.writeAll("{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},");
    try w.writeAll("{\"bufferView\":1,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},");
    try w.writeAll("{\"bufferView\":2,\"componentType\":5126,\"count\":3,\"type\":\"VEC2\"},");
    try w.writeAll("{\"bufferView\":3,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"}],");
    try w.print("\"bufferViews\":[{{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36}},{{\"buffer\":0,\"byteOffset\":36,\"byteLength\":36}},{{\"buffer\":0,\"byteOffset\":72,\"byteLength\":24}},{{\"buffer\":0,\"byteOffset\":96,\"byteLength\":6,\"target\":34963}},{{\"buffer\":0,\"byteOffset\":104,\"byteLength\":{d}}}],", .{png_bytes.len});
    try w.writeAll("\"buffers\":[{\"byteLength\":104}],");
    try w.writeAll("\"materials\":[{\"pbrMetallicRoughness\":{\"baseColorTexture\":{\"index\":0,\"texCoord\":1}}}],");
    try w.writeAll("\"textures\":[{\"source\":0}],\"images\":[{\"bufferView\":4,\"mimeType\":\"image/png\"}]}");
    while (json_aw.writer.end % 4 != 0) try w.writeByte(0x20);
    const json_bytes = try json_aw.toOwnedSlice();
    defer alloc.free(json_bytes);
    return assembleGlb(alloc, json_bytes, &pos, &nrm, &uv, &idx, png_bytes);
}

/// Assemble a GLB from JSON + BIN attribute slices (pos/nrm/uv/idx + optional png).
/// BIN layout: pos@0, nrm@36, uv@72, idx@96, png@104 (when provided).
fn assembleGlb(
    alloc: std.mem.Allocator,
    json_bytes: []const u8,
    pos: []const f32,
    nrm: []const f32,
    uv: []const f32,
    idx: []const u16,
    png_bytes: ?[]const u8,
) ![]u8 {
    const png_len: u32 = if (png_bytes) |p| @intCast(p.len) else 0;
    const base_len: u32 = 104; // pos36+nrm36+uv24+idx6=102 → 4-align 104
    const bin_total: u32 = base_len + png_len;
    const bin_padded = (bin_total + 3) & ~@as(u32, 3);
    var bin = try alloc.alloc(u8, bin_padded);
    defer alloc.free(bin);
    @memset(bin, 0);
    var off: usize = 0;
    for (pos) |f| {
        std.mem.writeInt(u32, bin[off..][0..4], @bitCast(f), .little);
        off += 4;
    }
    off = 36;
    for (nrm) |f| {
        std.mem.writeInt(u32, bin[off..][0..4], @bitCast(f), .little);
        off += 4;
    }
    off = 72;
    for (uv) |f| {
        std.mem.writeInt(u32, bin[off..][0..4], @bitCast(f), .little);
        off += 4;
    }
    off = 96;
    for (idx) |u| {
        std.mem.writeInt(u16, bin[off..][0..2], u, .little);
        off += 2;
    }
    if (png_bytes) |p| @memcpy(bin[base_len..][0..p.len], p);

    // JSON must be 4-aligned; callers pass pre-padded JSON or we pad here.
    const json_len: u32 = @intCast(json_bytes.len);
    const json_pad: u32 = (4 - (json_len % 4)) % 4;
    const json_padded = json_len + json_pad;

    const glb_len: u32 = 12 + 8 + json_padded + 8 + bin_padded;
    var glb = try alloc.alloc(u8, glb_len);
    var goff: usize = 0;
    @memcpy(glb[goff..][0..4], "glTF");
    goff += 4;
    std.mem.writeInt(u32, glb[goff..][0..4], 2, .little);
    goff += 4;
    std.mem.writeInt(u32, glb[goff..][0..4], glb_len, .little);
    goff += 4;
    std.mem.writeInt(u32, glb[goff..][0..4], json_padded, .little);
    goff += 4;
    @memcpy(glb[goff..][0..4], "JSON");
    goff += 4;
    @memcpy(glb[goff..][0..json_len], json_bytes);
    goff += json_len;
    var pad: u32 = 0;
    while (pad < json_pad) : (pad += 1) {
        glb[goff] = 0x20;
        goff += 1;
    }
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
