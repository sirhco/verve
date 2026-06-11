//! GLB container + glTF JSON → Model intermediate.
//!
//! Native-side only (uses std.json, alloc-heavy). NOT compiled into wasm in P2;
//! gating is handled by gl.zig / build.zig (lazy analysis — chunks that never
//! reference gl.gltf pay zero size / compat cost).
//!
//! Limitations (P2):
//! - Node transforms IGNORED — geometry is flattened in bind-pose. P-later bakes them.
//! - Normals lit in model space (no u_normal_matrix). P3 adds it.
//! - Multiple meshes/nodes: all flatten into one vertex+index pool (no scene graph).
//! - byteStride (interleaved sources) rejected with error.Unsupported; tight packing only.
//! - Only a single BIN buffer (buffers[0]) is supported; URIs rejected.
//! - Only componentType 5126 (f32) for vertex attributes, 5123 (u16) for indices.

const std = @import("std");
const vmesh = @import("vmesh.zig");
const png = @import("png.zig");

// ── public surface ─────────────────────────────────────────────────────────────

pub const Model = struct {
    arena: std.heap.ArenaAllocator,
    vertices: []f32, // interleaved pos3/normal3/uv2, stride 32 — vmesh-ready
    indices: []u16,
    submeshes: []vmesh.Submesh, // index_byte_off/count into `indices`
    textures: []vmesh.Texture, // decoded RGBA8 via png.zig

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

    // ── 7. Process all mesh primitives ────────────────────────────────────────
    // Flatten all meshes / all primitives into one vertex pool + index pool.
    // Each primitive becomes one Submesh.
    var vert_list: std.ArrayList(f32) = .empty;
    var idx_list: std.ArrayList(u16) = .empty;
    var sub_list: std.ArrayList(vmesh.Submesh) = .empty;

    for (meshes) |mesh_val| {
        const mesh_obj = switch (mesh_val) {
            .object => |o| o,
            else => return error.Malformed,
        };
        const prims_val = mesh_obj.get("primitives") orelse return error.Malformed;
        const prims = switch (prims_val) {
            .array => |a| a.items,
            else => return error.Malformed,
        };

        for (prims) |prim_val| {
            const prim_obj = switch (prim_val) {
                .object => |o| o,
                else => return error.Malformed,
            };

            // Vertex base offset before appending this primitive's verts
            const vert_base: u32 = @intCast(vert_list.items.len / 8); // # of vertices so far

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

            const uv_idx_opt: ?usize = blk: {
                if (attrs.get("TEXCOORD_0")) |v| {
                    break :blk @intCast(jsonInt(v) orelse return error.Malformed);
                }
                break :blk null;
            };

            // Read POSITION accessor → f32 slice
            const pos_f32 = try readAccessorF32(accessors, buffer_views, bin, pos_idx, aa);
            const vert_count = pos_f32.len / 3;

            // Read NORMAL accessor if present
            const nrm_f32: ?[]const f32 = if (nrm_idx_opt) |ni|
                try readAccessorF32(accessors, buffer_views, bin, ni, aa)
            else
                null; // missing → default (0,0,1) below; noted as limitation

            // Read TEXCOORD_0 accessor if present
            const uv_f32: ?[]const f32 = if (uv_idx_opt) |ui|
                try readAccessorF32(accessors, buffer_views, bin, ui, aa)
            else
                null; // missing → (0,0)

            // Interleave pos/normal/uv into stride-32 layout
            try vert_list.ensureUnusedCapacity(aa, vert_count * 8);
            for (0..vert_count) |vi| {
                // pos
                vert_list.appendAssumeCapacity(pos_f32[vi * 3 + 0]);
                vert_list.appendAssumeCapacity(pos_f32[vi * 3 + 1]);
                vert_list.appendAssumeCapacity(pos_f32[vi * 3 + 2]);
                // normal (default (0,0,1) if missing — limitation: no source normal)
                if (nrm_f32) |nrm| {
                    vert_list.appendAssumeCapacity(nrm[vi * 3 + 0]);
                    vert_list.appendAssumeCapacity(nrm[vi * 3 + 1]);
                    vert_list.appendAssumeCapacity(nrm[vi * 3 + 2]);
                } else {
                    vert_list.appendAssumeCapacity(0);
                    vert_list.appendAssumeCapacity(0);
                    vert_list.appendAssumeCapacity(1);
                }
                // uv (default (0,0) if missing)
                if (uv_f32) |uv| {
                    vert_list.appendAssumeCapacity(uv[vi * 2 + 0]);
                    vert_list.appendAssumeCapacity(uv[vi * 2 + 1]);
                } else {
                    vert_list.appendAssumeCapacity(0);
                    vert_list.appendAssumeCapacity(0);
                }
            }

            // ── Indices ───────────────────────────────────────────────────────
            const idx_acc_val = prim_obj.get("indices") orelse return error.Malformed;
            const idx_acc_idx: usize = @intCast(jsonInt(idx_acc_val) orelse return error.Malformed);
            const raw_indices = try readAccessorU16(accessors, buffer_views, bin, idx_acc_idx, aa);

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

            // ── Material ──────────────────────────────────────────────────────
            var base_color: [4]f32 = .{ 1, 1, 1, 1 };
            var tex_index: i32 = -1;

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
                        // baseColorTexture
                        if (pbr.get("baseColorTexture")) |bct_val| {
                            const bct = switch (bct_val) {
                                .object => |o| o,
                                else => return error.Malformed,
                            };
                            if (bct.get("index")) |tidx_val| {
                                tex_index = @intCast(jsonInt(tidx_val) orelse return error.Malformed);
                            }
                        }
                    }
                }
            }

            try sub_list.append(aa, .{
                .index_byte_off = index_byte_off,
                .index_count = @intCast(raw_indices.len),
                .base_color = base_color,
                .tex_index = tex_index,
            });
        }
    }

    // ── 8. Package Model ───────────────────────────────────────────────────────
    return Model{
        .arena = arena,
        .vertices = vert_list.items,
        .indices = idx_list.items,
        .submeshes = sub_list.items,
        .textures = tex_list.items,
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

test "parse fixture cube" {
    const glb = try @import("fixture.zig").texturedCubeGlb(testing.allocator);
    defer testing.allocator.free(glb);
    var model = try parseGlb(testing.allocator, glb);
    defer model.deinit();
    try testing.expectEqual(@as(usize, 24 * 8), model.vertices.len); // stride 32 interleaved
    try testing.expectEqual(@as(usize, 36), model.indices.len);
    try testing.expectEqual(@as(usize, 1), model.submeshes.len);
    try testing.expectEqual(@as(i32, 0), model.submeshes[0].tex_index);
    try testing.expectEqual(@as(usize, 1), model.textures.len);
    try testing.expectEqual(@as(u32, 8), model.textures[0].width);
    // a +z face vertex has normal (0,0,1): find any vertex with nz≈1
    var found = false;
    var i: usize = 0;
    while (i < model.vertices.len) : (i += 8) {
        if (model.vertices[i + 5] > 0.99) found = true;
    }
    try testing.expect(found);
}

test "rejects non-glb" {
    try testing.expectError(error.BadMagic, parseGlb(testing.allocator, "junk0000junk0000"));
}
