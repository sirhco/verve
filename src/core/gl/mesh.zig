//! verve.gl P1 geometry — unit cube in the variant_vertex_color layout
//! (position f32x3 @ 0, color f32x3 @ 12, stride 24; see command.zig).
//! Corner colors are distinct so rotation is visible with unlit shading.

const std = @import("std");

pub const cube_stride: u32 = 24;

// x, y, z, r, g, b per corner.
pub const cube_vertices = [_]f32{
    -1, -1, -1, 0, 0, 0,
    1,  -1, -1, 1, 0, 0,
    1,  1,  -1, 1, 1, 0,
    -1, 1,  -1, 0, 1, 0,
    -1, -1, 1,  0, 0, 1,
    1,  -1, 1,  1, 0, 1,
    1,  1,  1,  1, 1, 1,
    -1, 1,  1,  0, 1, 1,
};

// CCW winding viewed from outside each face (front faces survive
// gl.cullFace(BACK) with the default CCW front-face).
pub const cube_indices = [_]u16{
    4, 5, 6, 4, 6, 7, // +z
    1, 0, 3, 1, 3, 2, // -z
    0, 4, 7, 0, 7, 3, // -x
    5, 1, 2, 5, 2, 6, // +x
    3, 7, 6, 3, 6, 2, // +y
    0, 1, 5, 0, 5, 4, // -y
};

// ── PBR cube (variant_pbr / vmesh stride-48 layout) ──────────────────────────
//
// 24 vertices (one per face-corner so normals/uvs are per-face), interleaved in
// the vmesh layout `gl.vmesh.vertex_stride` describes:
//   pos f32x3 @0, normal f32x3 @12, tangent f32x4 @24, uv f32x2 @40 → 12 f32.
// Used by the WebGPU PBR demo chunk (GlSceneWebgpu) which has no asset fetch and
// needs a static lit mesh, mirroring the stride-48 geometry GlScene loads from a
// vmesh Reader. Tangents are per-face (matching the UV gradient) so normal
// mapping would be correct, though the F0 PBR variant ignores them.

pub const pbr_cube_stride: u32 = 48; // bytes; == gl.vmesh.vertex_stride

// pos(3) normal(3) tangent(4) uv(2) per vertex.
pub const pbr_cube_vertices = [_]f32{
    // +Z face (normal 0,0,1; tangent +X)
    -1, -1, 1,  0,  0,  1,  1,  0, 0,  1, 0, 0,
    1,  -1, 1,  0,  0,  1,  1,  0, 0,  1, 1, 0,
    1,  1,  1,  0,  0,  1,  1,  0, 0,  1, 1, 1,
    -1, 1,  1,  0,  0,  1,  1,  0, 0,  1, 0, 1,
    // -Z face (normal 0,0,-1; tangent -X)
    1,  -1, -1, 0,  0,  -1, -1, 0, 0,  1, 0, 0,
    -1, -1, -1, 0,  0,  -1, -1, 0, 0,  1, 1, 0,
    -1, 1,  -1, 0,  0,  -1, -1, 0, 0,  1, 1, 1,
    1,  1,  -1, 0,  0,  -1, -1, 0, 0,  1, 0, 1,
    // +X face (normal 1,0,0; tangent -Z)
    1,  -1, 1,  1,  0,  0,  0,  0, -1, 1, 0, 0,
    1,  -1, -1, 1,  0,  0,  0,  0, -1, 1, 1, 0,
    1,  1,  -1, 1,  0,  0,  0,  0, -1, 1, 1, 1,
    1,  1,  1,  1,  0,  0,  0,  0, -1, 1, 0, 1,
    // -X face (normal -1,0,0; tangent +Z)
    -1, -1, -1, -1, 0,  0,  0,  0, 1,  1, 0, 0,
    -1, -1, 1,  -1, 0,  0,  0,  0, 1,  1, 1, 0,
    -1, 1,  1,  -1, 0,  0,  0,  0, 1,  1, 1, 1,
    -1, 1,  -1, -1, 0,  0,  0,  0, 1,  1, 0, 1,
    // +Y face (normal 0,1,0; tangent +X)
    -1, 1,  1,  0,  1,  0,  1,  0, 0,  1, 0, 0,
    1,  1,  1,  0,  1,  0,  1,  0, 0,  1, 1, 0,
    1,  1,  -1, 0,  1,  0,  1,  0, 0,  1, 1, 1,
    -1, 1,  -1, 0,  1,  0,  1,  0, 0,  1, 0, 1,
    // -Y face (normal 0,-1,0; tangent +X)
    -1, -1, -1, 0,  -1, 0,  1,  0, 0,  1, 0, 0,
    1,  -1, -1, 0,  -1, 0,  1,  0, 0,  1, 1, 0,
    1,  -1, 1,  0,  -1, 0,  1,  0, 0,  1, 1, 1,
    -1, -1, 1,  0,  -1, 0,  1,  0, 0,  1, 0, 1,
};

// CCW winding viewed from outside each face (front faces survive back-face cull
// under the default CCW front-face). Two triangles per face, 0-3 per face quad.
pub const pbr_cube_indices = [_]u16{
    0, 1, 2, 0, 2, 3, // +Z
    4, 5, 6, 4, 6, 7, // -Z
    8, 9, 10, 8, 10, 11, // +X
    12, 13, 14, 12, 14, 15, // -X
    16, 17, 18, 16, 18, 19, // +Y
    20, 21, 22, 20, 22, 23, // -Y
};

// ── PBR ground plane (stride-48 layout) ──────────────────────────────────────
//
// A unit quad in the XZ plane (y=0), normal +Y, tangent +X, uv 0..1. Position +
// scale via a model matrix. Used by the WebGPU shadow demo (GlSceneWebgpu) as the
// receiver the cube casts its shadow onto. Winding (0,2,1 / 0,3,2) makes the top
// face front-facing (CCW-from-above) so it survives back-face cull.
pub const pbr_plane_vertices = [_]f32{
    // pos        normal     tangent      uv
    -1, 0, -1, 0, 1, 0, 1, 0, 0, 1, 0, 0,
    1,  0, -1, 0, 1, 0, 1, 0, 0, 1, 1, 0,
    1,  0, 1,  0, 1, 0, 1, 0, 0, 1, 1, 1,
    -1, 0, 1,  0, 1, 0, 1, 0, 0, 1, 0, 1,
};

pub const pbr_plane_indices = [_]u16{ 0, 2, 1, 0, 3, 2 };

const testing = std.testing;

test "cube shape invariants" {
    try testing.expectEqual(@as(usize, 8 * 6), cube_vertices.len); // 8 verts * 6 floats
    try testing.expectEqual(@as(usize, 36), cube_indices.len); // 12 triangles
    for (cube_indices) |i| try testing.expect(i < 8);
}

test "pbr cube shape invariants" {
    try testing.expectEqual(@as(usize, 24 * 12), pbr_cube_vertices.len); // 24 verts * 12 f32
    try testing.expectEqual(@as(usize, 36), pbr_cube_indices.len); // 12 triangles
    for (pbr_cube_indices) |i| try testing.expect(i < 24);
}

test "pbr plane shape invariants" {
    try testing.expectEqual(@as(usize, 4 * 12), pbr_plane_vertices.len); // 4 verts * 12 f32
    try testing.expectEqual(@as(usize, 6), pbr_plane_indices.len); // 2 triangles
    for (pbr_plane_indices) |i| try testing.expect(i < 4);
}
