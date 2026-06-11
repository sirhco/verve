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

const testing = std.testing;

test "cube shape invariants" {
    try testing.expectEqual(@as(usize, 8 * 6), cube_vertices.len); // 8 verts * 6 floats
    try testing.expectEqual(@as(usize, 36), cube_indices.len); // 12 triangles
    for (cube_indices) |i| try testing.expect(i < 8);
}
