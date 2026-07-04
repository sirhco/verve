const std = @import("std");
const draco = @import("draco.zig");
pub const Error = draco.Error;

pub const kInvalidCorner: u32 = 0xffffffff;
pub const kInvalidVertex: u32 = 0xffffffff;

/// Corner c belongs to face c/3; the three corners of a face are consecutive.
pub fn next(c: u32) u32 {
    return if (c % 3 == 2) c - 2 else c + 1;
}
pub fn previous(c: u32) u32 {
    return if (c % 3 == 0) c + 2 else c - 1;
}
pub fn face(c: u32) u32 {
    return c / 3;
}

/// Half-edge corner table. `opposite_corners` and `corner_to_vertex` are the two
/// core per-corner arrays the connectivity decode populates.
pub const CornerTable = struct {
    alloc: std.mem.Allocator,
    opposite_corners: []u32, // len = 3*num_faces; kInvalidCorner when open
    corner_to_vertex: []u32, // len = 3*num_faces
    num_faces_: u32,
    num_vertices_: u32,

    pub fn initEmpty(alloc: std.mem.Allocator, num_faces: u32, num_vertices: u32) Error!CornerTable {
        const nc = num_faces * 3;
        const opp = try alloc.alloc(u32, nc);
        errdefer alloc.free(opp);
        const c2v = try alloc.alloc(u32, nc);
        @memset(opp, kInvalidCorner);
        @memset(c2v, kInvalidVertex);
        return .{ .alloc = alloc, .opposite_corners = opp, .corner_to_vertex = c2v, .num_faces_ = num_faces, .num_vertices_ = num_vertices };
    }
    pub fn deinit(self: *CornerTable) void {
        self.alloc.free(self.opposite_corners);
        self.alloc.free(self.corner_to_vertex);
    }
    pub fn numCorners(self: *const CornerTable) u32 {
        return @intCast(self.opposite_corners.len);
    }
    pub fn numFaces(self: *const CornerTable) u32 {
        return self.num_faces_;
    }
    pub fn opposite(self: *const CornerTable, c: u32) u32 {
        return self.opposite_corners[c];
    }
    pub fn setOpposite(self: *CornerTable, c: u32, opp: u32) void {
        self.opposite_corners[c] = opp;
    }
    pub fn vertex(self: *const CornerTable, c: u32) u32 {
        return self.corner_to_vertex[c];
    }
    pub fn mapCornerToVertex(self: *CornerTable, c: u32, v: u32) void {
        self.corner_to_vertex[c] = v;
    }
};

test "corner ring arithmetic: next/previous/face" {
    // face 0 = corners 0,1,2 ; face 1 = corners 3,4,5
    try std.testing.expectEqual(@as(u32, 1), next(0));
    try std.testing.expectEqual(@as(u32, 2), next(1));
    try std.testing.expectEqual(@as(u32, 0), next(2)); // wraps within face
    try std.testing.expectEqual(@as(u32, 2), previous(0)); // wraps within face
    try std.testing.expectEqual(@as(u32, 0), previous(1));
    try std.testing.expectEqual(@as(u32, 0), face(0));
    try std.testing.expectEqual(@as(u32, 0), face(2));
    try std.testing.expectEqual(@as(u32, 1), face(3));
    try std.testing.expectEqual(@as(u32, 1), face(5));
}

test "opposite + vertex maps round-trip" {
    const a = std.testing.allocator;
    var ct = try CornerTable.initEmpty(a, 2, 4); // 2 faces, 4 verts
    defer ct.deinit();
    try std.testing.expectEqual(@as(u32, 6), ct.numCorners());
    try std.testing.expectEqual(@as(u32, kInvalidCorner), ct.opposite(0)); // empty default
    ct.setOpposite(0, 4);
    ct.setOpposite(4, 0);
    try std.testing.expectEqual(@as(u32, 4), ct.opposite(0));
    try std.testing.expectEqual(@as(u32, 0), ct.opposite(4));
    ct.mapCornerToVertex(0, 3);
    try std.testing.expectEqual(@as(u32, 3), ct.vertex(0));
}
