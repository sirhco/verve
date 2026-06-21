//! GLB container + glTF JSON → Model intermediate.
//!
//! Native-side only (uses std.json, alloc-heavy). NOT compiled into wasm in P2;
//! gating is handled by gl.zig / build.zig (lazy analysis — chunks that never
//! reference gl.gltf pay zero size / compat cost).
//!
//! Limitations:
//! - Node transforms are BAKED into vertex pos/normal/tangent at parse time
//!   (P8): each mesh inherits the world matrix of the first node that
//!   references it, composed down the scene-graph hierarchy. A mesh instanced
//!   by multiple nodes still bakes only the first node's transform (no
//!   instancing; first node wins, matching the name fallback).
//! - Multiple meshes/nodes: all flatten into one vertex+index pool (no runtime scene graph).
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
//! - Neutral-texture baking: tex_base/tex_mr/tex_occlusion are always white-baked
//!   when unset. tex_emissive is white-baked only when the emissive factor is non-zero
//!   (else left -1). tex_normal is always left -1 when absent. The -1 sentinels let
//!   vmesh.Reader.submeshVariant select leaner shader variants per submesh.

const std = @import("std");
const vmesh = @import("vmesh.zig");
const png = @import("png.zig");
const tangent = @import("tangent.zig");
const math = @import("math.zig");

// ── public surface ─────────────────────────────────────────────────────────────

/// A texture kept as ORIGINAL compressed bytes (not baked to RGBA). `index` is
/// the position in `Model.textures` whose RGBA was dropped; `ext` is the file
/// extension (e.g. "png"); `bytes` is the original compressed image. The
/// asset-gen writes these out as separate files (Task D2).
pub const ExternalTex = struct { index: u32, ext: []const u8, bytes: []const u8 };

pub const Model = struct {
    arena: std.heap.ArenaAllocator,
    vertices: []f32, // interleaved pos3/normal3/tangent4/uv2, stride 48 — vmesh-ready
    indices: []u16,
    submeshes: []vmesh.Submesh, // index_byte_off/count into `indices`
    textures: []vmesh.Texture, // decoded RGBA8 via png.zig
    names: []const []const u8, // one per submesh; owning mesh's name (fallback "mesh{n}")
    external_textures: []const ExternalTex = &.{}, // textures >64×64: original bytes kept, RGBA dropped
    // Skinning (slice 1). `skinned` is set when the glTF has a skin; then
    // `joints`/`weights` are 1:1 with `vertices` (vertex order) and `skel` is the
    // joint hierarchy. Empty / false for non-skinned meshes.
    skinned: bool = false,
    joints: []const [4]u8 = &.{}, // per-vertex joint indices (into skel)
    weights: []const [4]u8 = &.{}, // per-vertex weights, u8 (sum 255)
    skel: []const vmesh.Joint = &.{}, // joint list: parent + inverse_bind + bind_local
    // Animation (slice 3). One `vmesh.Clip` per glTF animation (empty if none).
    // Each clip's `tracks` is directory order (joint-major, then channel
    // T=0/R=1/S=2), length == skel.len*3; one baked track per joint per channel.
    anim_clips: []const vmesh.Clip = &.{},
    // GPU instancing (Task 2). Set when the first node in `nodes[]` carries the
    // EXT_mesh_gpu_instancing extension. `instances` is a flat []f32 with
    // instance_count × 20 floats (16 for the col-major mat4, then 4 for rgba).
    // Absent extension → instance_count == 0 and instances == &.{}.
    instance_count: u32 = 0,
    instances: []const f32 = &.{},

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

    // skins[] (skinning slice 1): when present, the mesh is skinned and we read
    // JOINTS_0/WEIGHTS_0 per primitive + build the joint hierarchy from skins[0].
    const skins_arr = blk: {
        if (root.get("skins")) |sv| {
            switch (sv) {
                .array => |a| break :blk a.items,
                else => return error.Malformed,
            }
        }
        break :blk &[_]std.json.Value{};
    };
    const model_skinned = skins_arr.len > 0;
    const nodes_arr: []const std.json.Value = blk: {
        if (root.get("nodes")) |nv| {
            if (nv == .array) break :blk nv.array.items;
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
    // Textures larger than 64×64 (>4096 px) are externalized: their original
    // compressed bytes are kept here and the RGBA in tex_list is dropped.
    var ext_list: std.ArrayList(ExternalTex) = .empty;

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

        // Decode PNG into a temporary Image (gives w/h + validates the bytes),
        // then either externalize (large) or copy RGBA into the arena (small).
        var img = png.decode(backing_alloc, bv_slice) catch return error.Malformed;
        defer img.deinit(backing_alloc);

        const px_count: u64 = @as(u64, img.width) * @as(u64, img.height);
        if (px_count > 4096) {
            // Externalize: keep the original compressed bytes; drop the RGBA.
            const ext_bytes = try aa.alloc(u8, bv_slice.len);
            @memcpy(ext_bytes, bv_slice);
            try ext_list.append(aa, .{ .index = @intCast(tex_list.items.len), .ext = "png", .bytes = ext_bytes });
            try tex_list.append(aa, .{ .width = 0, .height = 0, .rgba = &.{}, .format = .png });
        } else {
            const rgba_copy = try aa.alloc(u8, img.rgba.len);
            @memcpy(rgba_copy, img.rgba);
            try tex_list.append(aa, .{
                .width = img.width,
                .height = img.height,
                .rgba = rgba_copy,
                .format = .raw,
            });
        }
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

    // ── 6c. Per-mesh world matrices (node-transform baking) ────────────────────
    // Compose each mesh's world matrix down the node hierarchy. A mesh inherits
    // the world matrix of the FIRST node that references it (first visit wins,
    // matching the name fallback). Orphan meshes (no referencing node) keep
    // identity. The matrices are baked into vertex pos/normal/tangent in §7.
    const mesh_world = try aa.alloc(math.Mat4, meshes.len);
    for (mesh_world) |*m| m.* = math.Mat4.identity;
    if (root.get("nodes")) |nodes_val| {
        if (nodes_val == .array and nodes_val.array.items.len > 0) {
            const nodes_items = nodes_val.array.items;
            const mesh_set = try aa.alloc(bool, meshes.len);
            @memset(mesh_set, false);
            const visited = try aa.alloc(bool, nodes_items.len);
            @memset(visited, false);

            // Roots = the active scene's node list when present, else any node
            // not referenced as another node's child.
            var used_scene_roots = false;
            if (root.get("scenes")) |scenes_val| {
                if (scenes_val == .array and scenes_val.array.items.len > 0) {
                    const scene_idx: usize = blk: {
                        if (root.get("scene")) |sv| {
                            if (jsonInt(sv)) |si| {
                                if (std.math.cast(usize, si)) |su| {
                                    if (su < scenes_val.array.items.len) break :blk su;
                                }
                            }
                        }
                        break :blk 0;
                    };
                    if (scenes_val.array.items[scene_idx] == .object) {
                        if (scenes_val.array.items[scene_idx].object.get("nodes")) |rn| {
                            if (rn == .array) {
                                for (rn.array.items) |nv| {
                                    if (jsonInt(nv)) |ni| {
                                        if (std.math.cast(usize, ni)) |nu|
                                            accumulateWorld(nodes_items, meshes.len, nu, math.Mat4.identity, mesh_world, mesh_set, visited);
                                    }
                                }
                                used_scene_roots = true;
                            }
                        }
                    }
                }
            }
            if (!used_scene_roots) {
                const is_child = try aa.alloc(bool, nodes_items.len);
                @memset(is_child, false);
                for (nodes_items) |nv| {
                    if (nv != .object) continue;
                    if (nv.object.get("children")) |cv| {
                        if (cv == .array) {
                            for (cv.array.items) |c| {
                                if (jsonInt(c)) |ci| {
                                    if (std.math.cast(usize, ci)) |cu| {
                                        if (cu < is_child.len) is_child[cu] = true;
                                    }
                                }
                            }
                        }
                    }
                }
                for (0..nodes_items.len) |i| {
                    if (!is_child[i])
                        accumulateWorld(nodes_items, meshes.len, i, math.Mat4.identity, mesh_world, mesh_set, visited);
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
    // Per-vertex skin data (skinning slice 1), 1:1 with `vert_list` vertices.
    var jnt_list: std.ArrayList([4]u8) = .empty;
    var wgt_list: std.ArrayList([4]u8) = .empty;

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

        // World transform for this mesh and the matching normal matrix
        // (inverse-transpose upper-3×3), baked into every vertex below.
        const world = mesh_world[mesh_i];
        const nmat = math.normalMatrix(world);

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
                // pos — transformed as a point (w=1, translation applies).
                const p = math.transformPoint(world, math.Vec3.init(
                    pos_f32[vi * 3 + 0],
                    pos_f32[vi * 3 + 1],
                    pos_f32[vi * 3 + 2],
                ));
                vert_list.appendAssumeCapacity(p.x);
                vert_list.appendAssumeCapacity(p.y);
                vert_list.appendAssumeCapacity(p.z);
                // normal — transformed by the normal matrix (inverse-transpose),
                // renormalized (col-major nmat: [col*3+row]).
                const n = normalize3(.{
                    nmat[0] * nrm_f32[vi * 3 + 0] + nmat[3] * nrm_f32[vi * 3 + 1] + nmat[6] * nrm_f32[vi * 3 + 2],
                    nmat[1] * nrm_f32[vi * 3 + 0] + nmat[4] * nrm_f32[vi * 3 + 1] + nmat[7] * nrm_f32[vi * 3 + 2],
                    nmat[2] * nrm_f32[vi * 3 + 0] + nmat[5] * nrm_f32[vi * 3 + 1] + nmat[8] * nrm_f32[vi * 3 + 2],
                });
                vert_list.appendAssumeCapacity(n[0]);
                vert_list.appendAssumeCapacity(n[1]);
                vert_list.appendAssumeCapacity(n[2]);
                // tangent xyz — transformed as a direction (covariant with pos),
                // renormalized; w (handedness) preserved.
                const td = normalize3(blk: {
                    const t = math.transformDir(world, math.Vec3.init(
                        tan_f32[vi * 4 + 0],
                        tan_f32[vi * 4 + 1],
                        tan_f32[vi * 4 + 2],
                    ));
                    break :blk .{ t.x, t.y, t.z };
                });
                vert_list.appendAssumeCapacity(td[0]);
                vert_list.appendAssumeCapacity(td[1]);
                vert_list.appendAssumeCapacity(td[2]);
                vert_list.appendAssumeCapacity(tan_f32[vi * 4 + 3]);
                // uv
                vert_list.appendAssumeCapacity(uv_f32[vi * 2 + 0]);
                vert_list.appendAssumeCapacity(uv_f32[vi * 2 + 1]);
            }

            // ── Skin attributes (JOINTS_0 / WEIGHTS_0) ────────────────────────
            // When the model is skinned, append one [4]u8 joint-index + one
            // [4]u8 weight (sum 255) per vertex, in the same order as the verts
            // appended above. A skinned primitive missing them gets a default
            // (joint 0, weight {255,0,0,0}) so the arrays stay 1:1 with vertices.
            if (model_skinned) {
                try jnt_list.ensureUnusedCapacity(aa, vert_count);
                try wgt_list.ensureUnusedCapacity(aa, vert_count);
                const jnt_idx_opt: ?usize = if (attrs.get("JOINTS_0")) |v|
                    @intCast(jsonInt(v) orelse return error.Malformed)
                else
                    null;
                const wgt_idx_opt: ?usize = if (attrs.get("WEIGHTS_0")) |v|
                    @intCast(jsonInt(v) orelse return error.Malformed)
                else
                    null;
                if (jnt_idx_opt != null and wgt_idx_opt != null) {
                    const jnt_u8 = try readAccessorJointsU8(accessors, buffer_views, bin, jnt_idx_opt.?, aa);
                    const wgt_f32 = try readAccessorVec4F32(accessors, buffer_views, bin, wgt_idx_opt.?, aa);
                    if (jnt_u8.len != vert_count or wgt_f32.len != vert_count * 4) return error.Malformed;
                    for (0..vert_count) |vi| {
                        jnt_list.appendAssumeCapacity(jnt_u8[vi]);
                        wgt_list.appendAssumeCapacity(quantizeWeights(.{
                            wgt_f32[vi * 4 + 0],
                            wgt_f32[vi * 4 + 1],
                            wgt_f32[vi * 4 + 2],
                            wgt_f32[vi * 4 + 3],
                        }));
                    }
                } else {
                    for (0..vert_count) |_| {
                        jnt_list.appendAssumeCapacity(.{ 0, 0, 0, 0 });
                        wgt_list.appendAssumeCapacity(.{ 255, 0, 0, 0 });
                    }
                }
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
            var alpha_mode: u32 = 0;
            var alpha_cutoff: f32 = 0.5;
            var double_sided: u32 = 0;

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
                    // alphaMode: "BLEND"→1, "MASK"→2, else (OPAQUE/absent)→0.
                    if (mat_obj.get("alphaMode")) |am| {
                        if (am == .string) {
                            if (std.mem.eql(u8, am.string, "BLEND")) alpha_mode = 1 else if (std.mem.eql(u8, am.string, "MASK")) alpha_mode = 2;
                        }
                    }
                    // alphaCutoff: glTF default 0.5 when absent.
                    if (mat_obj.get("alphaCutoff")) |ac| {
                        alpha_cutoff = jsonFloat(ac) orelse 0.5;
                    }
                    // doubleSided: false by default.
                    if (mat_obj.get("doubleSided")) |ds| {
                        if (ds == .bool and ds.bool) double_sided = 1;
                    }
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
                .alpha_mode = alpha_mode,
                .alpha_cutoff = alpha_cutoff,
                .double_sided = double_sided,
            });
            try name_list.append(aa, mesh_name);
        }
    }

    // ── 7b. Neutral-texture baking ─────────────────────────────────────────────
    // tex_base, tex_mr, tex_occlusion: always white-neutral-baked when unset
    //   (the base PBR path always samples these slots).
    // tex_emissive: white-neutral-baked ONLY when the material has a non-zero
    //   emissive factor (so a texture-less factor-driven emissive still has a
    //   sampler); left as -1 when no emissive texture AND factor ≈ 0.
    // tex_normal: left as -1 when the material has no normal map — the -1
    //   sentinel is read by vmesh.Reader.submeshVariant to select a leaner
    //   shader variant (no normal-map branch).
    // The white neutral texture is appended once (deduped) only if referenced.
    {
        var white_idx: i32 = -1;
        for (sub_list.items) |*s| {
            // Always white-backed: base / mr / occlusion.
            inline for (.{ "tex_base", "tex_mr", "tex_occlusion" }) |field| {
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
            // Emissive: white-baked only when the factor is non-zero.
            if (s.tex_emissive < 0) {
                const ef = s.emissive;
                const has_factor = ef[0] != 0.0 or ef[1] != 0.0 or ef[2] != 0.0;
                if (has_factor) {
                    if (white_idx < 0) {
                        const px = try aa.alloc(u8, 4);
                        px[0] = 255;
                        px[1] = 255;
                        px[2] = 255;
                        px[3] = 255;
                        white_idx = @intCast(tex_list.items.len);
                        try tex_list.append(aa, .{ .width = 1, .height = 1, .rgba = px });
                    }
                    s.tex_emissive = white_idx;
                }
                // else: leave tex_emissive == -1 (no-emissive sentinel)
            }
            // tex_normal: leave as -1 (no-normal-map sentinel); downstream
            // vmesh.Reader.submeshVariant uses -1 to select the lean variant.
        }
    }

    // ── 7c. Skeleton (skins[0]) ────────────────────────────────────────────────
    // joint list = skins[0].joints (node indices); per joint: bind_local from the
    // node's TRS, inverse_bind from the inverseBindMatrices accessor, parent =
    // joint-list index of the node's parent in the hierarchy (-1 if not a joint).
    var skel_slice: []const vmesh.Joint = &.{};
    var anim_clips_slice: []const vmesh.Clip = &.{};
    if (model_skinned) {
        const skin0 = switch (skins_arr[0]) {
            .object => |o| o,
            else => return error.Malformed,
        };
        const joints_val = skin0.get("joints") orelse return error.Malformed;
        const joint_nodes = switch (joints_val) {
            .array => |a| a.items,
            else => return error.Malformed,
        };
        const jc = joint_nodes.len;
        if (jc == 0) return error.Malformed;

        const ibm_acc_val = skin0.get("inverseBindMatrices") orelse return error.Malformed;
        const ibm_acc: usize = @intCast(jsonInt(ibm_acc_val) orelse return error.Malformed);
        const ibm = try readAccessorF32(accessors, buffer_views, bin, ibm_acc, aa);
        if (ibm.len != jc * 16) return error.Malformed;

        // Per-joint bind-TRS components (for baking single-key tracks on the
        // channels a glTF animation doesn't drive). Defaults: 0 / identity / 1.
        const bind_t = try aa.alloc([3]f32, jc);
        const bind_r = try aa.alloc([4]f32, jc);
        const bind_s = try aa.alloc([3]f32, jc);

        // node index → parent node index (walk every node's children once).
        const parent_of = try aa.alloc(i32, nodes_arr.len);
        @memset(parent_of, -1);
        for (nodes_arr, 0..) |nv, ni| {
            const no = switch (nv) {
                .object => |o| o,
                else => continue,
            };
            if (no.get("children")) |cv| {
                if (cv == .array) {
                    for (cv.array.items) |c| {
                        if (jsonInt(c)) |ci| {
                            if (std.math.cast(usize, ci)) |cu| {
                                if (cu < parent_of.len) parent_of[cu] = @intCast(ni);
                            }
                        }
                    }
                }
            }
        }

        const skel_buf = try aa.alloc(vmesh.Joint, jc);
        for (joint_nodes, 0..) |jn_val, k| {
            const node_idx: usize = @intCast(jsonInt(jn_val) orelse return error.Malformed);
            if (node_idx >= nodes_arr.len) return error.Malformed;
            const node_obj = switch (nodes_arr[node_idx]) {
                .object => |o| o,
                else => return error.Malformed,
            };
            const local = nodeLocalMatrix(node_obj);
            // Capture this joint node's bind-TRS components (glTF defaults).
            bind_t[k] = .{ 0, 0, 0 };
            bind_r[k] = .{ 0, 0, 0, 1 };
            bind_s[k] = .{ 1, 1, 1 };
            if (node_obj.get("translation")) |tv| {
                if (tv == .array and tv.array.items.len == 3)
                    for (0..3) |c| {
                        bind_t[k][c] = jsonFloat(tv.array.items[c]) orelse 0;
                    };
            }
            if (node_obj.get("rotation")) |rv| {
                if (rv == .array and rv.array.items.len == 4)
                    for (0..4) |c| {
                        bind_r[k][c] = jsonFloat(rv.array.items[c]) orelse 0;
                    };
            }
            if (node_obj.get("scale")) |sv| {
                if (sv == .array and sv.array.items.len == 3)
                    for (0..3) |c| {
                        bind_s[k][c] = jsonFloat(sv.array.items[c]) orelse 1;
                    };
            }
            // parent joint = index in joint_nodes whose node == this node's parent.
            var parent_joint: i32 = -1;
            const pn = parent_of[node_idx];
            if (pn >= 0) {
                for (joint_nodes, 0..) |jn2, k2| {
                    if ((jsonInt(jn2) orelse continue) == pn) {
                        parent_joint = @intCast(k2);
                        break;
                    }
                }
            }
            var inv: [16]f32 = undefined;
            @memcpy(&inv, ibm[k * 16 ..][0..16]);
            skel_buf[k] = .{ .parent = parent_joint, .inverse_bind = inv, .bind_local = local.m };
        }
        skel_slice = skel_buf;

        // ── 7d. Animation clips (slice 3: ALL animations[]) ───────────────────
        // One vmesh.Clip per glTF animation. For each: bake ALL 3 tracks
        // (T=0,R=1,S=2) for EVERY joint — a glTF channel's keys when present,
        // else a single keyframe of the joint's bind component.
        if (root.get("animations")) |anims_val| {
            if (anims_val == .array and anims_val.array.items.len > 0) {
                var clip_list: std.ArrayList(vmesh.Clip) = .empty;
                for (anims_val.array.items, 0..) |anim_val, ci| {
                    const anim_obj = switch (anim_val) {
                        .object => |o| o,
                        else => return error.Malformed,
                    };
                    const channels = switch (anim_obj.get("channels") orelse return error.Malformed) {
                        .array => |a| a.items,
                        else => return error.Malformed,
                    };
                    const samplers = switch (anim_obj.get("samplers") orelse return error.Malformed) {
                        .array => |a| a.items,
                        else => return error.Malformed,
                    };
                    // (joint, channel) → glTF sampler index, or -1.
                    const refs = try aa.alloc(i32, jc * 3);
                    @memset(refs, -1);
                    for (channels) |ch_val| {
                        const ch = switch (ch_val) {
                            .object => |o| o,
                            else => return error.Malformed,
                        };
                        const target = switch (ch.get("target") orelse return error.Malformed) {
                            .object => |o| o,
                            else => return error.Malformed,
                        };
                        const node_ref = target.get("node") orelse continue;
                        const node_idx: i64 = jsonInt(node_ref) orelse continue;
                        var jidx: i32 = -1;
                        for (joint_nodes, 0..) |jn2, k2| {
                            if ((jsonInt(jn2) orelse continue) == node_idx) {
                                jidx = @intCast(k2);
                                break;
                            }
                        }
                        if (jidx < 0) continue; // channel targets a non-joint node
                        const path_str = switch (target.get("path") orelse return error.Malformed) {
                            .string => |s| s,
                            else => return error.Malformed,
                        };
                        const chan: usize = if (std.mem.eql(u8, path_str, "translation"))
                            0
                        else if (std.mem.eql(u8, path_str, "rotation"))
                            1
                        else if (std.mem.eql(u8, path_str, "scale"))
                            2
                        else
                            continue; // weights/other — ignored
                        const samp_idx: i32 = @intCast(jsonInt(ch.get("sampler") orelse return error.Malformed) orelse return error.Malformed);
                        refs[@as(usize, @intCast(jidx)) * 3 + chan] = samp_idx;
                    }

                    var clip_dur: f32 = 0;
                    const tracks = try aa.alloc(vmesh.Track, jc * 3);
                    for (0..jc) |j| {
                        for (0..3) |c| {
                            const comps: usize = if (c == 1) 4 else 3;
                            const samp_idx = refs[j * 3 + c];
                            if (samp_idx >= 0) {
                                const samp = switch (samplers[@intCast(samp_idx)]) {
                                    .object => |o| o,
                                    else => return error.Malformed,
                                };
                                const interp_str = if (samp.get("interpolation")) |iv| (switch (iv) {
                                    .string => |s| s,
                                    else => return error.Malformed,
                                }) else "LINEAR";
                                const interp: u8 = if (std.mem.eql(u8, interp_str, "LINEAR"))
                                    0
                                else if (std.mem.eql(u8, interp_str, "STEP"))
                                    1
                                else if (std.mem.eql(u8, interp_str, "CUBICSPLINE"))
                                    2
                                else
                                    return error.Unsupported;
                                const in_idx: usize = @intCast(jsonInt(samp.get("input") orelse return error.Malformed) orelse return error.Malformed);
                                const out_idx: usize = @intCast(jsonInt(samp.get("output") orelse return error.Malformed) orelse return error.Malformed);
                                const times = try readAccessorF32(accessors, buffer_views, bin, in_idx, aa);
                                const values = try readAccessorF32(accessors, buffer_views, bin, out_idx, aa);
                                const vstride: usize = if (interp == 2) 3 else 1;
                                if (values.len != times.len * comps * vstride) return error.Malformed;
                                if (times.len > 0 and times[times.len - 1] > clip_dur) clip_dur = times[times.len - 1];
                                tracks[j * 3 + c] = .{ .interp = interp, .times = times, .values = values };
                            } else {
                                // single keyframe holding the joint's bind component
                                const one_t = try aa.alloc(f32, 1);
                                one_t[0] = 0;
                                const v = try aa.alloc(f32, comps);
                                if (c == 0) {
                                    @memcpy(v, &bind_t[j]);
                                } else if (c == 1) {
                                    @memcpy(v, &bind_r[j]);
                                } else {
                                    @memcpy(v, &bind_s[j]);
                                }
                                tracks[j * 3 + c] = .{ .interp = 0, .times = one_t, .values = v };
                            }
                        }
                    }
                    const name_hash: u32 = if (anim_obj.get("name")) |nv| (switch (nv) {
                        .string => |s| vmesh.fnv1a32(s),
                        else => vmesh.fnv1a32(try std.fmt.allocPrint(aa, "clip{d}", .{ci})),
                    }) else vmesh.fnv1a32(try std.fmt.allocPrint(aa, "clip{d}", .{ci}));
                    try clip_list.append(aa, .{ .name_hash = name_hash, .duration = clip_dur, .tracks = tracks });
                }
                anim_clips_slice = clip_list.items;
            }
        }
    }

    // ── 7e. EXT_mesh_gpu_instancing ───────────────────────────────────────────
    // Walk nodes[]; the FIRST node carrying the extension wins (v1 — "first node
    // wins" matching the existing name / world-matrix fallback policy). Read
    // TRANSLATION (VEC3), ROTATION (VEC4 quat), SCALE (VEC3) per-instance
    // accessors (each optional → identity component) and optionally _COLOR_0
    // (VEC4, default [1,1,1,1]). Compose mat4_i = T·R·S via math.Mat4.fromTrs —
    // the same compose used by nodeLocalMatrix / accumulateWorld above, ensuring
    // column-major convention consistency. Output: model.instances flat []f32,
    // instance_count × 20 f32: 16 mat4 then 4 rgba.
    var inst_count: u32 = 0;
    var inst_slice: []const f32 = &.{};
    for (nodes_arr) |node_val| {
        const node_obj2 = switch (node_val) {
            .object => |o| o,
            else => continue,
        };
        const ext_val = node_obj2.get("extensions") orelse continue;
        const ext_obj = switch (ext_val) {
            .object => |o| o,
            else => continue,
        };
        const gpu_ext = ext_obj.get("EXT_mesh_gpu_instancing") orelse continue;
        const gpu_obj = switch (gpu_ext) {
            .object => |o| o,
            else => continue,
        };
        const inst_attrs_val = gpu_obj.get("attributes") orelse continue;
        const inst_attrs = switch (inst_attrs_val) {
            .object => |o| o,
            else => continue,
        };

        // Read optional per-instance attribute accessors.
        const trans_opt: ?[]const f32 = if (inst_attrs.get("TRANSLATION")) |v|
            try readAccessorF32(accessors, buffer_views, bin, @intCast(jsonInt(v) orelse return error.Malformed), aa)
        else
            null;
        const rot_opt: ?[]const f32 = if (inst_attrs.get("ROTATION")) |v|
            try readAccessorF32(accessors, buffer_views, bin, @intCast(jsonInt(v) orelse return error.Malformed), aa)
        else
            null;
        const scale_opt: ?[]const f32 = if (inst_attrs.get("SCALE")) |v|
            try readAccessorF32(accessors, buffer_views, bin, @intCast(jsonInt(v) orelse return error.Malformed), aa)
        else
            null;
        const color_opt: ?[]const f32 = if (inst_attrs.get("_COLOR_0")) |v|
            try readAccessorF32(accessors, buffer_views, bin, @intCast(jsonInt(v) orelse return error.Malformed), aa)
        else
            null;

        // Determine instance count from whichever accessor is present.
        const n: u32 = blk: {
            if (trans_opt) |t| break :blk @intCast(t.len / 3);
            if (rot_opt) |r| break :blk @intCast(r.len / 4);
            if (scale_opt) |s| break :blk @intCast(s.len / 3);
            if (color_opt) |c| break :blk @intCast(c.len / 4);
            break :blk 0;
        };
        if (n == 0) break; // extension present but no attributes → skip

        // Allocate flat instances buffer: n × 20 f32.
        const inst_buf = try aa.alloc(f32, n * 20);
        for (0..n) |k| {
            // Per-instance TRS — defaults: t=(0,0,0), r=identity, s=(1,1,1).
            const t = math.Vec3.init(
                if (trans_opt) |tr| tr[k * 3 + 0] else 0,
                if (trans_opt) |tr| tr[k * 3 + 1] else 0,
                if (trans_opt) |tr| tr[k * 3 + 2] else 0,
            );
            const rq = math.Quat{
                .x = if (rot_opt) |rr| rr[k * 4 + 0] else 0,
                .y = if (rot_opt) |rr| rr[k * 4 + 1] else 0,
                .z = if (rot_opt) |rr| rr[k * 4 + 2] else 0,
                .w = if (rot_opt) |rr| rr[k * 4 + 3] else 1,
            };
            const sc = math.Vec3.init(
                if (scale_opt) |ss| ss[k * 3 + 0] else 1,
                if (scale_opt) |ss| ss[k * 3 + 1] else 1,
                if (scale_opt) |ss| ss[k * 3 + 2] else 1,
            );
            // Compose mat4 = T·R·S (column-major, same as nodeLocalMatrix).
            const mat = math.Mat4.fromTrs(t, rq, sc);
            @memcpy(inst_buf[k * 20 ..][0..16], &mat.m);
            // Per-instance color — default (1,1,1,1) when absent.
            inst_buf[k * 20 + 16] = if (color_opt) |cc| cc[k * 4 + 0] else 1;
            inst_buf[k * 20 + 17] = if (color_opt) |cc| cc[k * 4 + 1] else 1;
            inst_buf[k * 20 + 18] = if (color_opt) |cc| cc[k * 4 + 2] else 1;
            inst_buf[k * 20 + 19] = if (color_opt) |cc| cc[k * 4 + 3] else 1;
        }
        inst_count = n;
        inst_slice = inst_buf;
        break; // first EXT node wins
    }

    // ── 8. Package Model ───────────────────────────────────────────────────────
    return Model{
        .arena = arena,
        .vertices = vert_list.items,
        .indices = idx_list.items,
        .submeshes = sub_list.items,
        .textures = tex_list.items,
        .names = name_list.items,
        .external_textures = try ext_list.toOwnedSlice(aa),
        .skinned = model_skinned,
        .joints = if (model_skinned) jnt_list.items else &.{},
        .weights = if (model_skinned) wgt_list.items else &.{},
        .skel = skel_slice,
        .anim_clips = anim_clips_slice,
        .instance_count = inst_count,
        .instances = inst_slice,
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

/// Normalize a 3-vector; a zero-length vector is returned unchanged.
fn normalize3(v: [3]f32) [3]f32 {
    const len = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (len == 0) return v;
    const inv = 1.0 / len;
    return .{ v[0] * inv, v[1] * inv, v[2] * inv };
}

/// A node's local transform: explicit `matrix` (16 col-major f32) when present,
/// else composed from translation/rotation/scale (glTF defaults 0 / identity / 1).
fn nodeLocalMatrix(node_obj: std.json.ObjectMap) math.Mat4 {
    if (node_obj.get("matrix")) |mv| {
        if (mv == .array and mv.array.items.len == 16) {
            var m: math.Mat4 = undefined;
            for (mv.array.items, 0..) |e, i| m.m[i] = jsonFloat(e) orelse 0;
            return m;
        }
    }
    var t = math.Vec3.init(0, 0, 0);
    var r = math.Quat.identity;
    var s = math.Vec3.init(1, 1, 1);
    if (node_obj.get("translation")) |tv| {
        if (tv == .array and tv.array.items.len == 3) {
            t = math.Vec3.init(jsonFloat(tv.array.items[0]) orelse 0, jsonFloat(tv.array.items[1]) orelse 0, jsonFloat(tv.array.items[2]) orelse 0);
        }
    }
    if (node_obj.get("rotation")) |rv| {
        if (rv == .array and rv.array.items.len == 4) {
            r = .{ .x = jsonFloat(rv.array.items[0]) orelse 0, .y = jsonFloat(rv.array.items[1]) orelse 0, .z = jsonFloat(rv.array.items[2]) orelse 0, .w = jsonFloat(rv.array.items[3]) orelse 1 };
        }
    }
    if (node_obj.get("scale")) |sv| {
        if (sv == .array and sv.array.items.len == 3) {
            s = math.Vec3.init(jsonFloat(sv.array.items[0]) orelse 1, jsonFloat(sv.array.items[1]) orelse 1, jsonFloat(sv.array.items[2]) orelse 1);
        }
    }
    return math.Mat4.fromTrs(t, r, s);
}

/// DFS the node hierarchy from `idx`, composing world = parent · local. Records
/// the world matrix on the first node that references each mesh. `visited`
/// guards against cycles (hostile input); `mesh_count` bounds the mesh index.
fn accumulateWorld(
    nodes: []const std.json.Value,
    mesh_count: usize,
    idx: usize,
    parent: math.Mat4,
    mesh_world: []math.Mat4,
    mesh_set: []bool,
    visited: []bool,
) void {
    if (idx >= nodes.len or visited[idx]) return;
    visited[idx] = true;
    const node_obj = switch (nodes[idx]) {
        .object => |o| o,
        else => return,
    };
    const world = parent.mul(nodeLocalMatrix(node_obj));
    if (node_obj.get("mesh")) |mref| {
        if (jsonInt(mref)) |mi64| {
            if (std.math.cast(usize, mi64)) |mi| {
                if (mi < mesh_count and !mesh_set[mi]) {
                    mesh_world[mi] = world;
                    mesh_set[mi] = true;
                }
            }
        }
    }
    if (node_obj.get("children")) |cv| {
        if (cv == .array) {
            for (cv.array.items) |c| {
                if (jsonInt(c)) |ci| {
                    if (std.math.cast(usize, ci)) |cu|
                        accumulateWorld(nodes, mesh_count, cu, world, mesh_world, mesh_set, visited);
                }
            }
        }
    }
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

/// Read a JOINTS_0 accessor (VEC4 of u8 5121 or u16 5123) → per-vertex [4]u8.
/// u16 indices are clamped to u8 (joint lists in slice 1 are ≤64, well within u8).
fn readAccessorJointsU8(
    accessors: []const std.json.Value,
    buffer_views: []const std.json.Value,
    bin: []const u8,
    acc_idx: usize,
    aa: std.mem.Allocator,
) ![]const [4]u8 {
    if (acc_idx >= accessors.len) return error.Malformed;
    const acc_obj = switch (accessors[acc_idx]) {
        .object => |o| o,
        else => return error.Malformed,
    };
    const ct = jsonInt(acc_obj.get("componentType") orelse return error.Malformed) orelse return error.Malformed;
    const count: usize = @intCast(jsonInt(acc_obj.get("count") orelse return error.Malformed) orelse return error.Malformed);
    const type_str = switch (acc_obj.get("type") orelse return error.Malformed) {
        .string => |s| s,
        else => return error.Malformed,
    };
    if (!std.mem.eql(u8, type_str, "VEC4")) return error.Unsupported;

    const bv_idx: usize = @intCast(jsonInt(acc_obj.get("bufferView") orelse return error.Malformed) orelse return error.Malformed);
    const byte_off_in_acc: usize = if (acc_obj.get("byteOffset")) |bov|
        @intCast(jsonInt(bov) orelse return error.Malformed)
    else
        0;
    const bv_slice = try getBufferViewSlice(buffer_views, bv_idx, bin);

    const comp_size: usize = switch (ct) {
        5121 => 1, // u8
        5123 => 2, // u16
        else => return error.Unsupported,
    };
    const total = count * 4 * comp_size;
    if (byte_off_in_acc > bv_slice.len or total > bv_slice.len - byte_off_in_acc) return error.Malformed;
    const raw = bv_slice[byte_off_in_acc .. byte_off_in_acc + total];

    const result = try aa.alloc([4]u8, count);
    for (0..count) |i| {
        inline for (0..4) |c| {
            const v: u16 = if (comp_size == 1)
                raw[i * 4 + c]
            else
                std.mem.readInt(u16, raw[(i * 4 + c) * 2 ..][0..2], .little);
            result[i][c] = std.math.cast(u8, v) orelse 255;
        }
    }
    return result;
}

/// Quantize a 4-weight vector to u8 with an exact sum of 255 (matches the
/// shader's /255). Renormalizes to the input's total (so any non-negative input
/// — including sums ≠ 1 — is handled), floors each scaled weight, then hands the
/// remaining counts to the largest fractional remainders (largest-remainder
/// method). An all-zero input degenerates to {255,0,0,0}.
fn quantizeWeights(w: [4]f32) [4]u8 {
    var c: [4]f32 = undefined;
    var total: f32 = 0;
    for (0..4) |i| {
        c[i] = @max(0.0, w[i]);
        total += c[i];
    }
    if (total <= 0) return .{ 255, 0, 0, 0 };

    var q: [4]u16 = undefined;
    var rem: [4]f32 = undefined;
    var assigned: i32 = 0;
    for (0..4) |i| {
        const scaled = c[i] / total * 255.0;
        const fl = @floor(scaled);
        q[i] = @intFromFloat(fl);
        rem[i] = scaled - fl;
        assigned += @intCast(q[i]);
    }
    // Distribute the remaining (255 − assigned) units to the largest remainders.
    var need: i32 = 255 - assigned;
    while (need > 0) : (need -= 1) {
        var mi: usize = 0;
        var mr: f32 = -1;
        for (0..4) |i| {
            if (rem[i] > mr) {
                mr = rem[i];
                mi = i;
            }
        }
        q[mi] += 1;
        rem[mi] = -1; // don't pick the same slot twice
    }
    return .{ @intCast(q[0]), @intCast(q[1]), @intCast(q[2]), @intCast(q[3]) };
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
    // baseColorTexture → tex_base 0; mr/occlusion white-baked; normal/emissive → -1
    // (no normal map, no emissive texture, no emissive factor).
    try testing.expectEqual(@as(i32, 0), s.tex_base);
    try testing.expect(s.tex_mr >= 0);
    try testing.expectEqual(@as(i32, -1), s.tex_normal);
    try testing.expectEqual(@as(i32, -1), s.tex_emissive);
    try testing.expect(s.tex_occlusion >= 0);
    // 1 original + 1 white (shared mr/occlusion); normal/emissive not baked.
    try testing.expectEqual(@as(usize, 2), model.textures.len);
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

// GLB container invariants (magic/version/total-length/JSON-chunk alignment).
// Same magic/version/chunk-alignment checks the pbrCubeGlb fixture tests run,
// but material-count-agnostic so it also fits the mixed (2-material) asset.
fn mixedGlbContainerInvariants(glb: []const u8) !void {
    try testing.expectEqualSlices(u8, "glTF", glb[0..4]);
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, glb[4..8], .little));
    try testing.expectEqual(@as(u32, @intCast(glb.len)), std.mem.readInt(u32, glb[8..12], .little));
    try testing.expectEqualSlices(u8, "JSON", glb[16..20]);
    const json_len = std.mem.readInt(u32, glb[12..16], .little);
    try testing.expectEqual(@as(u32, 0), json_len % 4); // JSON chunk 4-aligned
}

test "parse pbrCubeMixedMaterialGlb: 2 submeshes, variant fan-out (full vs base-only)" {
    const command = @import("command.zig");
    const glb = try @import("fixture.zig").pbrCubeMixedMaterialGlb(testing.allocator);
    defer testing.allocator.free(glb);
    // GLB container invariants (magic/version/length/JSON chunk alignment) before
    // we trust the parse — same guard the pbrCubeGlb fixture tests apply.
    try mixedGlbContainerInvariants(glb);
    var model = try parseGlb(testing.allocator, glb);
    defer model.deinit();

    // ── 1. exactly two submeshes (one per mesh/primitive) ─────────────────────
    try testing.expectEqual(@as(usize, 2), model.submeshes.len);

    // Parse order follows mesh order: submesh 0 = mesh 0 "MixedFull" = full PBR,
    // submesh 1 = mesh 1 "MixedBase" = base-only. Don't assume the order: pick the
    // full submesh by material signature (it has a normal map) and swap aliases if
    // primitive/parse order ever flips, so a regression fails clearly here instead
    // of with an opaque tex_normal>=0 got -1.
    var full_i: usize = 0;
    var base_i: usize = 1;
    if (model.submeshes[0].tex_normal < 0) {
        // submesh 0 has no normal map → it is the base-only one; swap.
        full_i = 1;
        base_i = 0;
    }
    const full = model.submeshes[full_i];
    const base = model.submeshes[base_i];

    // ── 2. full-material submesh: all five tex_* >= 0 ─────────────────────────
    try testing.expect(full.tex_base >= 0);
    try testing.expect(full.tex_mr >= 0);
    try testing.expect(full.tex_normal >= 0);
    try testing.expect(full.tex_emissive >= 0);
    try testing.expect(full.tex_occlusion >= 0);

    // ── 3. base-only submesh: base/mr/occlusion white-baked, normal/emissive==-1 ─
    try testing.expect(base.tex_base >= 0); // neutral-baked ok
    try testing.expect(base.tex_mr >= 0); // white-baked (regression guard: not -1)
    try testing.expect(base.tex_occlusion >= 0); // white-baked (regression guard)
    try testing.expectEqual(@as(i32, -1), base.tex_normal);
    try testing.expectEqual(@as(i32, -1), base.tex_emissive);

    // ── 3b. distinct submesh names: name-based addressing reaches both ────────
    try testing.expectEqual(model.submeshes.len, model.names.len);
    try testing.expectEqualStrings("MixedFull", model.names[full_i]);
    try testing.expectEqualStrings("MixedBase", model.names[base_i]);

    // ── 4. pack → read → variant: prove writer→reader→variant end to end ──────
    const bytes = try vmesh.pack(
        testing.allocator,
        model.vertices,
        model.indices,
        model.submeshes,
        model.textures,
        &.{}, // no bvh
        &.{}, // no tri_perm
        model.names,
        false,
        &.{},
        &.{},
        &.{},
        null,
        &.{},
        0,
    );
    defer testing.allocator.free(bytes);
    const r = try vmesh.Reader.init(bytes);

    const pbr = command.variant_pbr;
    const nm = command.variant_normal_map;
    const em = command.variant_emissive;

    // full submesh → pbr | normal_map | emissive; base-only → pbr.
    try testing.expectEqual(pbr | nm | em, r.submeshVariant(@intCast(full_i)));
    try testing.expectEqual(pbr, r.submeshVariant(@intCast(base_i)));
    // Two distinct variants in one asset → GlScene fan-out fires.
    try testing.expect(r.submeshVariant(@intCast(full_i)) != r.submeshVariant(@intCast(base_i)));
}

test "neutral-texture baking: no textures, zero factor → sentinels for normal/emissive" {
    // Minimal glb: a single triangle, material with NO textures and no emissive factor.
    // New behavior: tex_base/mr/occlusion white-baked; tex_normal == -1, tex_emissive == -1.
    const glb = try minimalNoTextureGlb(testing.allocator);
    defer testing.allocator.free(glb);
    var model = try parseGlb(testing.allocator, glb);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 1), model.submeshes.len);
    const s = model.submeshes[0];
    // base/mr/occlusion white-baked.
    try testing.expect(s.tex_base >= 0);
    try testing.expect(s.tex_mr >= 0);
    try testing.expect(s.tex_occlusion >= 0);
    // White shared across base/mr/occlusion.
    try testing.expectEqual(s.tex_base, s.tex_mr);
    try testing.expectEqual(s.tex_base, s.tex_occlusion);
    // normal and emissive left as -1 (no map, no non-zero factor).
    try testing.expectEqual(@as(i32, -1), s.tex_normal);
    try testing.expectEqual(@as(i32, -1), s.tex_emissive);
    // Started with 0 textures; grows by exactly 1 (white only).
    try testing.expectEqual(@as(usize, 1), model.textures.len);
    // White texel = (255,255,255,255).
    const white = model.textures[@intCast(s.tex_base)];
    try testing.expectEqual(@as(u32, 1), white.width);
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, white.rgba);
}

test "neutral-texture baking: no emissive texture + non-zero factor → tex_emissive white-baked" {
    // Material with NO emissive texture but emissiveFactor = [1,0,0] → tex_emissive >= 0.
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
        "\"materials\":[{\"pbrMetallicRoughness\":{\"metallicFactor\":0.0,\"roughnessFactor\":0.5}," ++
        "\"emissiveFactor\":[1.0,0.0,0.0]}]}";
    const glb = try assembleGlb(testing.allocator, json, &pos, &nrm, &uv, &idx, null);
    defer testing.allocator.free(glb);
    var model = try parseGlb(testing.allocator, glb);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 1), model.submeshes.len);
    const s = model.submeshes[0];
    // Emissive factor non-zero → tex_emissive must be white-baked (>= 0).
    try testing.expect(s.tex_emissive >= 0);
    // Verify white texel.
    const white = model.textures[@intCast(s.tex_emissive)];
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, white.rgba);
    // tex_normal still -1 (no normal map).
    try testing.expectEqual(@as(i32, -1), s.tex_normal);
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

test "node transform: translation baked into positions" {
    // Triangle at (0,0,0)/(1,0,0)/(0,1,0), node translation (10,2,3).
    const glb = try nodeXformGlb(testing.allocator, "\"translation\":[10,2,3]");
    defer testing.allocator.free(glb);
    var model = try parseGlb(testing.allocator, glb);
    defer model.deinit();
    // vertex 0 pos (stride 12, pos@0) → (10,2,3).
    try testing.expectApproxEqAbs(@as(f32, 10), model.vertices[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 2), model.vertices[1], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 3), model.vertices[2], 1e-5);
    // vertex 1 pos (1,0,0) → (11,2,3).
    try testing.expectApproxEqAbs(@as(f32, 11), model.vertices[12], 1e-5);
    // normals (0,0,1) unchanged by pure translation (normal@3).
    try testing.expectApproxEqAbs(@as(f32, 1), model.vertices[5], 1e-5);
}

test "node transform: rotation baked into positions and normals" {
    // +90° about Y as a quat: (0, sin45, 0, cos45).
    const glb = try nodeXformGlb(testing.allocator, "\"rotation\":[0,0.70710678,0,0.70710678]");
    defer testing.allocator.free(glb);
    var model = try parseGlb(testing.allocator, glb);
    defer model.deinit();
    // pos (1,0,0): +90°Y maps +X → -Z → (0,0,-1).
    try testing.expectApproxEqAbs(@as(f32, 0), model.vertices[12], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), model.vertices[13], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -1), model.vertices[14], 1e-4);
    // normal (0,0,1): +Z → +X → (1,0,0).
    try testing.expectApproxEqAbs(@as(f32, 1), model.vertices[3], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), model.vertices[4], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), model.vertices[5], 1e-4);
}

test "parse skinnedBarGlb: skinned, joints/weights 1:1, 3-joint chain" {
    const glb = try @import("fixture.zig").skinnedBarGlb(testing.allocator);
    defer testing.allocator.free(glb);
    var model = try parseGlb(testing.allocator, glb);
    defer model.deinit();

    try testing.expect(model.skinned);
    const vert_count = model.vertices.len / 12;
    try testing.expectEqual(@as(usize, 40), vert_count);
    try testing.expectEqual(vert_count, model.joints.len);
    try testing.expectEqual(vert_count, model.weights.len);
    // 3-joint chain: root parent -1, mid parent 0, top parent 1.
    try testing.expectEqual(@as(usize, 3), model.skel.len);
    try testing.expectEqual(@as(i32, -1), model.skel[0].parent);
    try testing.expectEqual(@as(i32, 0), model.skel[1].parent);
    try testing.expectEqual(@as(i32, 1), model.skel[2].parent);
    // mid joint inverse-bind translates by −1.5 in Y (column-major element 13).
    try testing.expectApproxEqAbs(@as(f32, -1.5), model.skel[1].inverse_bind[13], 1e-5);
    // mid joint bind_local translates by +1.5 in Y.
    try testing.expectApproxEqAbs(@as(f32, 1.5), model.skel[1].bind_local[13], 1e-5);
    // every vertex's weights sum to exactly 255, and joint indices are < 3.
    for (model.weights, model.joints) |w, j| {
        const sum: u32 = @as(u32, w[0]) + w[1] + w[2] + w[3];
        try testing.expectEqual(@as(u32, 255), sum);
        for (j) |ji| try testing.expect(ji < 3);
    }
}

test "parse skinnedBarGlb: three clips (Bend + Twist + Smooth) baked" {
    const glb = try @import("fixture.zig").skinnedBarGlb(testing.allocator);
    defer testing.allocator.free(glb);
    var model = try parseGlb(testing.allocator, glb);
    defer model.deinit();
    try testing.expectEqual(@as(usize, 3), model.anim_clips.len);
    try testing.expectEqual(vmesh.fnv1a32("Bend"), model.anim_clips[0].name_hash);
    try testing.expectEqual(vmesh.fnv1a32("Twist"), model.anim_clips[1].name_hash);
    try testing.expectEqual(vmesh.fnv1a32("Smooth"), model.anim_clips[2].name_hash);
    // each clip has one track per joint per channel (T,R,S)
    try testing.expectEqual(model.skel.len * 3, model.anim_clips[0].tracks.len);
    // Bend: jmid (joint 1) rotation keyed; jtop (joint 2) rotation single-key.
    try testing.expect(model.anim_clips[0].tracks[1 * 3 + 1].times.len >= 2);
    try testing.expectEqual(@as(usize, 1), model.anim_clips[0].tracks[2 * 3 + 1].times.len);
    // Twist: jtop (joint 2) rotation keyed (Bend left it single-key).
    try testing.expect(model.anim_clips[1].tracks[2 * 3 + 1].times.len >= 2);
    // Smooth: jmid (joint 1) rotation is CUBICSPLINE (interp==2) with 3× values (in/point/out).
    const sm = model.anim_clips[2].tracks[1 * 3 + 1];
    try testing.expectEqual(@as(u8, 2), sm.interp);
    try testing.expect(sm.times.len >= 2);
    try testing.expectEqual(sm.times.len * 4 * 3, sm.values.len);
    // root (joint 0) translation: single bind keyframe in every clip.
    try testing.expectEqual(@as(usize, 1), model.anim_clips[0].tracks[0 * 3 + 0].times.len);
    try testing.expect(model.anim_clips[0].duration > 0 and model.anim_clips[2].duration > 0);
}

test "parse CUBICSPLINE animation sampler: interp=2, values.len==2*4*3" {
    // Build a minimal skinned GLB in-memory:
    //   1 mesh node (skin 0) + 1 joint node (jroot).
    //   1 skin with 1 joint, identity inverseBindMatrix.
    //   1 animation with 1 CUBICSPLINE rotation channel on jroot.
    //   Input accessor: 2 SCALAR f32 times.
    //   Output accessor: 2*3=6 VEC4 f32 (inTangent/point/outTangent per key).
    const alloc = testing.allocator;

    // BIN layout:
    //  off_pos   = 0          len=12  (1 triangle, 3×VEC3 pos — just 1 vert for simplicity; use 3)
    //  off_nrm   = 36         len=36
    //  off_uv    = 72         len=24
    //  off_jnt   = 96         len=4   (1 vert JOINTS_0 u8 VEC4: 0,0,0,0)  → pad to 4
    //  off_wgt   = 100        len=16  (1 vert WEIGHTS_0 f32 VEC4: 1,0,0,0) — wait, must match vert_count
    // Keep it simple: 3 verts matching the triangle.
    const vert_count: u32 = 3;
    const index_count: u32 = 3;
    const joint_count: u32 = 1;
    const key_count: u32 = 2; // CUBICSPLINE times
    const comps: u32 = 4; // VEC4 (rotation)

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
    const off_ibm: u32 = (off_idx + len_idx + 3) & ~@as(u32, 3); // MAT4 needs 4-align
    const len_ibm: u32 = joint_count * 64;
    const off_atime: u32 = off_ibm + len_ibm;
    const len_atime: u32 = key_count * 4; // 2 SCALAR f32
    const off_arot: u32 = off_atime + len_atime;
    const len_arot: u32 = key_count * 3 * comps * 4; // 2 keys × 3 (in/pt/out) × 4 comps × 4 bytes

    const bin_total: u32 = off_arot + len_arot;
    const bin_padded: u32 = (bin_total + 3) & ~@as(u32, 3);
    const bin = try alloc.alloc(u8, bin_padded);
    defer alloc.free(bin);
    @memset(bin, 0);

    // positions (3 verts, unit triangle)
    const pos = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    for (pos, 0..) |f, i| std.mem.writeInt(u32, bin[off_pos + i * 4 ..][0..4], @bitCast(f), .little);
    // normals (all +Z)
    const nrm = [_]f32{ 0, 0, 1, 0, 0, 1, 0, 0, 1 };
    for (nrm, 0..) |f, i| std.mem.writeInt(u32, bin[off_nrm + i * 4 ..][0..4], @bitCast(f), .little);
    // uvs (zero)
    // joints: all 0 (u8 VEC4 already zeroed by @memset)
    // weights: first weight = 1.0 for each vert
    for (0..vert_count) |v| {
        const one: f32 = 1.0;
        std.mem.writeInt(u32, bin[off_wgt + v * 16 ..][0..4], @bitCast(one), .little);
    }
    // indices: 0,1,2
    for (0..index_count) |i| std.mem.writeInt(u16, bin[off_idx + i * 2 ..][0..2], @intCast(i), .little);
    // inverseBindMatrix: identity (already zero; just set diagonal)
    const diag = [4]usize{ 0, 5, 10, 15 };
    for (diag) |d| {
        const one: f32 = 1.0;
        std.mem.writeInt(u32, bin[off_ibm + d * 4 ..][0..4], @bitCast(one), .little);
    }
    // animation times: 0.0, 1.0
    const a_times = [key_count]f32{ 0.0, 1.0 };
    for (a_times, 0..) |t, i| std.mem.writeInt(u32, bin[off_atime + i * 4 ..][0..4], @bitCast(t), .little);
    // animation output: 2 keys × 3 tangent slots × VEC4 — use identity quat (0,0,0,1) for all
    for (0..key_count * 3) |slot| {
        const base = off_arot + @as(u32, @intCast(slot)) * comps * 4;
        const one: f32 = 1.0;
        // w component (index 3) = 1.0; x,y,z stay 0
        std.mem.writeInt(u32, bin[base + 3 * 4 ..][0..4], @bitCast(one), .little);
    }

    // JSON chunk
    const json =
        "{\"asset\":{\"version\":\"2.0\"},\"scene\":0," ++
        "\"scenes\":[{\"nodes\":[0]}]," ++
        "\"nodes\":[{\"mesh\":0,\"skin\":0},{\"name\":\"jroot\"}]," ++
        "\"skins\":[{\"joints\":[1],\"inverseBindMatrices\":6}]," ++
        "\"meshes\":[{\"primitives\":[{\"attributes\":{\"POSITION\":0,\"NORMAL\":1,\"TEXCOORD_0\":2,\"JOINTS_0\":3,\"WEIGHTS_0\":4},\"indices\":5,\"material\":0}]}]," ++
        "\"accessors\":[" ++
        "{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}," ++
        "{\"bufferView\":1,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}," ++
        "{\"bufferView\":2,\"componentType\":5126,\"count\":3,\"type\":\"VEC2\"}," ++
        "{\"bufferView\":3,\"componentType\":5121,\"count\":3,\"type\":\"VEC4\"}," ++
        "{\"bufferView\":4,\"componentType\":5126,\"count\":3,\"type\":\"VEC4\"}," ++
        "{\"bufferView\":5,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"}," ++
        "{\"bufferView\":6,\"componentType\":5126,\"count\":1,\"type\":\"MAT4\"}," ++
        "{\"bufferView\":7,\"componentType\":5126,\"count\":2,\"type\":\"SCALAR\"}," ++
        "{\"bufferView\":8,\"componentType\":5126,\"count\":6,\"type\":\"VEC4\"}" ++
        "]," ++
        "\"bufferViews\":[" ++
        "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36}," ++
        "{\"buffer\":0,\"byteOffset\":36,\"byteLength\":36}," ++
        "{\"buffer\":0,\"byteOffset\":72,\"byteLength\":24}," ++
        "{\"buffer\":0,\"byteOffset\":96,\"byteLength\":12}," ++
        "{\"buffer\":0,\"byteOffset\":108,\"byteLength\":48}," ++
        "{\"buffer\":0,\"byteOffset\":156,\"byteLength\":6}," ++
        "{\"buffer\":0,\"byteOffset\":164,\"byteLength\":64}," ++
        "{\"buffer\":0,\"byteOffset\":228,\"byteLength\":8}," ++
        "{\"buffer\":0,\"byteOffset\":236,\"byteLength\":96}" ++
        "]," ++
        "\"buffers\":[{\"byteLength\":332}]," ++
        "\"materials\":[{\"pbrMetallicRoughness\":{}}]," ++
        "\"animations\":[{\"name\":\"CubicTest\"," ++
        "\"channels\":[{\"sampler\":0,\"target\":{\"node\":1,\"path\":\"rotation\"}}]," ++
        "\"samplers\":[{\"input\":7,\"output\":8,\"interpolation\":\"CUBICSPLINE\"}]}]}";

    // Pad JSON to 4-byte alignment
    const json_len: u32 = @intCast(json.len);
    const json_pad: u32 = (4 - (json_len % 4)) % 4;
    const json_padded = json_len + json_pad;

    const glb_len: u32 = 12 + 8 + json_padded + 8 + bin_padded;
    const glb = try alloc.alloc(u8, glb_len);
    defer alloc.free(glb);
    @memset(glb, 0x20); // pad bytes = space

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
    @memcpy(glb[goff..][0..json_len], json);
    goff += json_padded; // already padded with 0x20
    std.mem.writeInt(u32, glb[goff..][0..4], bin_padded, .little);
    goff += 4;
    glb[goff] = 0x42;
    glb[goff + 1] = 0x49;
    glb[goff + 2] = 0x4E;
    glb[goff + 3] = 0x00;
    goff += 4;
    @memcpy(glb[goff..][0..bin_padded], bin);

    // Verify the JSON byteOffsets actually match the computed bin layout.
    // off_ibm must be 164 (= (156+6+1)&~3 = 164). Confirm:
    try testing.expectEqual(@as(u32, 164), off_ibm);
    // off_atime = 164+64 = 228; off_arot = 228+8 = 236; off_arot+len_arot = 236+96 = 332.
    try testing.expectEqual(@as(u32, 228), off_atime);
    try testing.expectEqual(@as(u32, 236), off_arot);
    try testing.expectEqual(@as(u32, 332), off_arot + len_arot);

    var model = try parseGlb(alloc, glb);
    defer model.deinit();

    try testing.expect(model.skinned);
    try testing.expectEqual(@as(usize, 1), model.anim_clips.len);
    // 1 joint × 3 channels = 3 tracks
    try testing.expectEqual(@as(usize, 3), model.anim_clips[0].tracks.len);
    // rotation track = channel 1 (R)
    const rot_track = model.anim_clips[0].tracks[0 * 3 + 1];
    try testing.expectEqual(@as(u8, 2), rot_track.interp); // CUBICSPLINE
    try testing.expectEqual(@as(usize, 2), rot_track.times.len);
    try testing.expectEqual(@as(usize, 2 * 4 * 3), rot_track.values.len); // 24 floats
}

test "gltf parses alphaMode BLEND → alpha_mode 1" {
    const alloc = testing.allocator;
    const pos = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    const nrm = [_]f32{ 0, 0, 1, 0, 0, 1, 0, 0, 1 };
    const uv = [_]f32{ 0, 0, 1, 0, 0, 1 };
    const idx = [_]u16{ 0, 1, 2 };

    // Case 1: material has "alphaMode":"BLEND" → submesh alpha_mode must be 1.
    {
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
            "\"materials\":[{\"alphaMode\":\"BLEND\",\"pbrMetallicRoughness\":{\"metallicFactor\":0.0,\"roughnessFactor\":0.5}}]}";
        const glb = try assembleGlb(alloc, json, &pos, &nrm, &uv, &idx, null);
        defer alloc.free(glb);
        var model = try parseGlb(alloc, glb);
        defer model.deinit();
        try testing.expectEqual(@as(usize, 1), model.submeshes.len);
        try testing.expectEqual(@as(u32, 1), model.submeshes[0].alpha_mode);
    }

    // Case 2: material has no alphaMode → submesh alpha_mode must be 0 (opaque default).
    {
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
        const glb = try assembleGlb(alloc, json, &pos, &nrm, &uv, &idx, null);
        defer alloc.free(glb);
        var model = try parseGlb(alloc, glb);
        defer model.deinit();
        try testing.expectEqual(@as(usize, 1), model.submeshes.len);
        try testing.expectEqual(@as(u32, 0), model.submeshes[0].alpha_mode);
    }
}

test "gltf parses alphaMode MASK + alphaCutoff" {
    const alloc = testing.allocator;
    const pos = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    const nrm = [_]f32{ 0, 0, 1, 0, 0, 1, 0, 0, 1 };
    const uv = [_]f32{ 0, 0, 1, 0, 0, 1 };
    const idx = [_]u16{ 0, 1, 2 };

    // Case 1: "alphaMode":"MASK","alphaCutoff":0.3 → alpha_mode==2, alpha_cutoff==0.3.
    {
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
            "\"materials\":[{\"alphaMode\":\"MASK\",\"alphaCutoff\":0.3,\"pbrMetallicRoughness\":{\"metallicFactor\":0.0,\"roughnessFactor\":0.5}}]}";
        const glb = try assembleGlb(alloc, json, &pos, &nrm, &uv, &idx, null);
        defer alloc.free(glb);
        var model = try parseGlb(alloc, glb);
        defer model.deinit();
        try testing.expectEqual(@as(usize, 1), model.submeshes.len);
        try testing.expectEqual(@as(u32, 2), model.submeshes[0].alpha_mode);
        try testing.expectApproxEqAbs(@as(f32, 0.3), model.submeshes[0].alpha_cutoff, 1e-6);
    }

    // Case 2: "alphaMode":"MASK" with NO alphaCutoff → alpha_cutoff==0.5 (glTF default).
    {
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
            "\"materials\":[{\"alphaMode\":\"MASK\",\"pbrMetallicRoughness\":{\"metallicFactor\":0.0,\"roughnessFactor\":0.5}}]}";
        const glb = try assembleGlb(alloc, json, &pos, &nrm, &uv, &idx, null);
        defer alloc.free(glb);
        var model = try parseGlb(alloc, glb);
        defer model.deinit();
        try testing.expectEqual(@as(usize, 1), model.submeshes.len);
        try testing.expectEqual(@as(u32, 2), model.submeshes[0].alpha_mode);
        try testing.expectApproxEqAbs(@as(f32, 0.5), model.submeshes[0].alpha_cutoff, 1e-6);
    }
}

test "gltf parses doubleSided" {
    const alloc = testing.allocator;
    const pos = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    const nrm = [_]f32{ 0, 0, 1, 0, 0, 1, 0, 0, 1 };
    const uv = [_]f32{ 0, 0, 1, 0, 0, 1 };
    const idx = [_]u16{ 0, 1, 2 };

    // Case 1: material has "doubleSided":true → submesh double_sided must be 1.
    {
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
            "\"materials\":[{\"doubleSided\":true,\"pbrMetallicRoughness\":{\"metallicFactor\":0.0,\"roughnessFactor\":0.5}}]}";
        const glb = try assembleGlb(alloc, json, &pos, &nrm, &uv, &idx, null);
        defer alloc.free(glb);
        var model = try parseGlb(alloc, glb);
        defer model.deinit();
        try testing.expectEqual(@as(usize, 1), model.submeshes.len);
        try testing.expectEqual(@as(u32, 1), model.submeshes[0].double_sided);
    }

    // Case 2: material has no doubleSided → submesh double_sided must be 0 (default).
    {
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
        const glb = try assembleGlb(alloc, json, &pos, &nrm, &uv, &idx, null);
        defer alloc.free(glb);
        var model = try parseGlb(alloc, glb);
        defer model.deinit();
        try testing.expectEqual(@as(usize, 1), model.submeshes.len);
        try testing.expectEqual(@as(u32, 0), model.submeshes[0].double_sided);
    }
}

test "gltf parses EXT_mesh_gpu_instancing" {
    // GLB: one triangle mesh; node 0 has extensions.EXT_mesh_gpu_instancing with
    //   attributes TRANSLATION (2 instances: [0,0,0],[2,0,0]) and _COLOR_0
    //   ([1,1,1,1],[1,0,0,1]).
    // BIN layout:
    //   off_pos   = 0     len=36   (3 verts × VEC3 f32)
    //   off_nrm   = 36    len=36
    //   off_uv    = 72    len=24   (3 verts × VEC2 f32)
    //   off_idx   = 96    len=6    (3 × u16)
    //   pad to 4  = 2     → 104
    //   off_trans = 104   len=24   (2 × VEC3 f32)
    //   off_color = 128   len=32   (2 × VEC4 f32)
    //   total = 160
    const alloc = testing.allocator;

    const off_pos: u32 = 0;
    const off_nrm: u32 = 36;
    const off_idx: u32 = 96; // 6 bytes → 102 → pad 2 → 104
    const off_trans: u32 = 104; // 2 × VEC3 f32 = 24 bytes
    const off_color: u32 = 128; // 2 × VEC4 f32 = 32 bytes
    const bin_total: u32 = 160;
    const bin_padded: u32 = (bin_total + 3) & ~@as(u32, 3);

    const bin = try alloc.alloc(u8, bin_padded);
    defer alloc.free(bin);
    @memset(bin, 0);

    // POSITION: 3 verts forming a triangle
    const pos_data = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    for (pos_data, 0..) |f, i| std.mem.writeInt(u32, bin[off_pos + i * 4 ..][0..4], @bitCast(f), .little);

    // NORMAL: all +Z
    const nrm_data = [_]f32{ 0, 0, 1, 0, 0, 1, 0, 0, 1 };
    for (nrm_data, 0..) |f, i| std.mem.writeInt(u32, bin[off_nrm + i * 4 ..][0..4], @bitCast(f), .little);

    // TEXCOORD_0: zeroes (already zero)

    // indices: 0, 1, 2
    std.mem.writeInt(u16, bin[off_idx..][0..2], 0, .little);
    std.mem.writeInt(u16, bin[off_idx + 2 ..][0..2], 1, .little);
    std.mem.writeInt(u16, bin[off_idx + 4 ..][0..2], 2, .little);

    // TRANSLATION: instance 0 = (0,0,0), instance 1 = (2,0,0)
    const trans_data = [_]f32{ 0, 0, 0, 2, 0, 0 };
    for (trans_data, 0..) |f, i| std.mem.writeInt(u32, bin[off_trans + i * 4 ..][0..4], @bitCast(f), .little);

    // _COLOR_0: instance 0 = (1,1,1,1), instance 1 = (1,0,0,1)
    const color_data = [_]f32{ 1, 1, 1, 1, 1, 0, 0, 1 };
    for (color_data, 0..) |f, i| std.mem.writeInt(u32, bin[off_color + i * 4 ..][0..4], @bitCast(f), .little);

    // JSON: mesh node with EXT_mesh_gpu_instancing on node 0.
    // Accessors: 0=POSITION(VEC3), 1=NORMAL(VEC3), 2=TEXCOORD_0(VEC2), 3=indices(SCALAR u16),
    //            4=TRANSLATION(VEC3), 5=_COLOR_0(VEC4).
    const json =
        "{\"asset\":{\"version\":\"2.0\"},\"scene\":0," ++
        "\"scenes\":[{\"nodes\":[0]}]," ++
        "\"nodes\":[{\"mesh\":0,\"extensions\":{\"EXT_mesh_gpu_instancing\":{\"attributes\":{\"TRANSLATION\":4,\"_COLOR_0\":5}}}}]," ++
        "\"meshes\":[{\"primitives\":[{\"attributes\":{\"POSITION\":0,\"NORMAL\":1,\"TEXCOORD_0\":2},\"indices\":3,\"material\":0}]}]," ++
        "\"accessors\":[" ++
        "{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}," ++
        "{\"bufferView\":1,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}," ++
        "{\"bufferView\":2,\"componentType\":5126,\"count\":3,\"type\":\"VEC2\"}," ++
        "{\"bufferView\":3,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"}," ++
        "{\"bufferView\":4,\"componentType\":5126,\"count\":2,\"type\":\"VEC3\"}," ++
        "{\"bufferView\":5,\"componentType\":5126,\"count\":2,\"type\":\"VEC4\"}" ++
        "]," ++
        "\"bufferViews\":[" ++
        "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36}," ++
        "{\"buffer\":0,\"byteOffset\":36,\"byteLength\":36}," ++
        "{\"buffer\":0,\"byteOffset\":72,\"byteLength\":24}," ++
        "{\"buffer\":0,\"byteOffset\":96,\"byteLength\":6}," ++
        "{\"buffer\":0,\"byteOffset\":104,\"byteLength\":24}," ++
        "{\"buffer\":0,\"byteOffset\":128,\"byteLength\":32}" ++
        "]," ++
        "\"buffers\":[{\"byteLength\":160}]," ++
        "\"materials\":[{\"pbrMetallicRoughness\":{\"metallicFactor\":0.0,\"roughnessFactor\":0.5}}]}";

    const json_len: u32 = @intCast(json.len);
    const json_pad: u32 = (4 - (json_len % 4)) % 4;
    const json_padded: u32 = json_len + json_pad;
    const glb_len: u32 = 12 + 8 + json_padded + 8 + bin_padded;
    const glb = try alloc.alloc(u8, glb_len);
    defer alloc.free(glb);
    @memset(glb, 0x20);

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
    @memcpy(glb[goff..][0..json_len], json);
    goff += json_padded;
    std.mem.writeInt(u32, glb[goff..][0..4], bin_padded, .little);
    goff += 4;
    glb[goff] = 0x42;
    glb[goff + 1] = 0x49;
    glb[goff + 2] = 0x4E;
    glb[goff + 3] = 0x00;
    goff += 4;
    @memcpy(glb[goff..][0..bin_padded], bin);

    var model = try parseGlb(alloc, glb);
    defer model.deinit();

    // 2 instances from the EXT_mesh_gpu_instancing accessor count.
    try testing.expectEqual(@as(u32, 2), model.instance_count);
    // instances flat array: 2 × 20 f32 = 40 f32 total.
    try testing.expectEqual(@as(usize, 40), model.instances.len);

    // Instance 0: translation (0,0,0) + identity rotation + scale (1,1,1)
    //   → mat4 = identity. Column 3 (translation column) = (0,0,0,1).
    //   col-major mat4: index 12=tx, 13=ty, 14=tz, 15=1.
    //   color = (1,1,1,1).
    const inst0 = model.instances[0..20];
    // diagonal = 1 (identity scale+rot)
    try testing.expectApproxEqAbs(@as(f32, 1), inst0[0], 1e-5); // m[0]
    try testing.expectApproxEqAbs(@as(f32, 1), inst0[5], 1e-5); // m[5]
    try testing.expectApproxEqAbs(@as(f32, 1), inst0[10], 1e-5); // m[10]
    try testing.expectApproxEqAbs(@as(f32, 1), inst0[15], 1e-5); // m[15]
    // translation column
    try testing.expectApproxEqAbs(@as(f32, 0), inst0[12], 1e-5); // tx
    try testing.expectApproxEqAbs(@as(f32, 0), inst0[13], 1e-5); // ty
    try testing.expectApproxEqAbs(@as(f32, 0), inst0[14], 1e-5); // tz
    // color
    try testing.expectApproxEqAbs(@as(f32, 1), inst0[16], 1e-5); // r
    try testing.expectApproxEqAbs(@as(f32, 1), inst0[17], 1e-5); // g
    try testing.expectApproxEqAbs(@as(f32, 1), inst0[18], 1e-5); // b
    try testing.expectApproxEqAbs(@as(f32, 1), inst0[19], 1e-5); // a

    // Instance 1: translation (2,0,0) + identity rotation + scale (1,1,1)
    //   → col 3 = (2,0,0,1). color = (1,0,0,1).
    const inst1 = model.instances[20..40];
    try testing.expectApproxEqAbs(@as(f32, 1), inst1[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1), inst1[5], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1), inst1[10], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 2), inst1[12], 1e-5); // tx = 2
    try testing.expectApproxEqAbs(@as(f32, 0), inst1[13], 1e-5); // ty = 0
    try testing.expectApproxEqAbs(@as(f32, 0), inst1[14], 1e-5); // tz = 0
    try testing.expectApproxEqAbs(@as(f32, 1), inst1[15], 1e-5); // m[15] = 1
    // color (1,0,0,1)
    try testing.expectApproxEqAbs(@as(f32, 1), inst1[16], 1e-5); // r=1
    try testing.expectApproxEqAbs(@as(f32, 0), inst1[17], 1e-5); // g=0
    try testing.expectApproxEqAbs(@as(f32, 0), inst1[18], 1e-5); // b=0
    try testing.expectApproxEqAbs(@as(f32, 1), inst1[19], 1e-5); // a=1

    // Round-trip through vmesh pack → reader: instance_count preserved.
    const vmesh_bytes = try vmesh.pack(
        alloc,
        model.vertices,
        model.indices,
        model.submeshes,
        model.textures,
        &.{},
        &.{},
        model.names,
        false,
        &.{},
        &.{},
        &.{},
        null,
        model.instances,
        model.instance_count,
    );
    defer alloc.free(vmesh_bytes);
    const r = try vmesh.Reader.init(vmesh_bytes);
    try testing.expectEqual(@as(u32, 2), r.instanceCount());
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

/// Same triangle as minimalNoTextureGlb, but the node carries a transform
/// (`xform_json` injected into the node object, e.g. `"translation":[10,2,3]`).
fn nodeXformGlb(alloc: std.mem.Allocator, xform_json: []const u8) ![]u8 {
    const pos = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    const nrm = [_]f32{ 0, 0, 1, 0, 0, 1, 0, 0, 1 };
    const uv = [_]f32{ 0, 0, 1, 0, 0, 1 };
    const idx = [_]u16{ 0, 1, 2 };
    var json_aw: std.Io.Writer.Allocating = .init(alloc);
    defer json_aw.deinit();
    const w = &json_aw.writer;
    try w.writeAll("{\"asset\":{\"version\":\"2.0\"},\"scene\":0,\"scenes\":[{\"nodes\":[0]}],");
    try w.print("\"nodes\":[{{\"mesh\":0,{s}}}],", .{xform_json});
    try w.writeAll("\"meshes\":[{\"primitives\":[{\"attributes\":{\"POSITION\":0,\"NORMAL\":1,\"TEXCOORD_0\":2},\"indices\":3,\"material\":0}]}],");
    try w.writeAll("\"accessors\":[");
    try w.writeAll("{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},");
    try w.writeAll("{\"bufferView\":1,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},");
    try w.writeAll("{\"bufferView\":2,\"componentType\":5126,\"count\":3,\"type\":\"VEC2\"},");
    try w.writeAll("{\"bufferView\":3,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"}],");
    try w.writeAll("\"bufferViews\":[");
    try w.writeAll("{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36},");
    try w.writeAll("{\"buffer\":0,\"byteOffset\":36,\"byteLength\":36},");
    try w.writeAll("{\"buffer\":0,\"byteOffset\":72,\"byteLength\":24},");
    try w.writeAll("{\"buffer\":0,\"byteOffset\":96,\"byteLength\":6,\"target\":34963}],");
    try w.writeAll("\"buffers\":[{\"byteLength\":102}],");
    try w.writeAll("\"materials\":[{\"pbrMetallicRoughness\":{\"metallicFactor\":0.0,\"roughnessFactor\":0.5}}]}");
    while (json_aw.writer.end % 4 != 0) try w.writeByte(0x20);
    const json_bytes = try json_aw.toOwnedSlice();
    defer alloc.free(json_bytes);
    return assembleGlb(alloc, json_bytes, &pos, &nrm, &uv, &idx, null);
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
