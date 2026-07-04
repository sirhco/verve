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

/// Invalid-guarded Next/Previous: Draco's `CornerTable::Next`/`Previous` return
/// the invalid corner unchanged instead of overflowing. Needed by the swing
/// operators, whose intermediate `Opposite(...)` can be `kInvalidCorner`.
fn nextGuarded(c: u32) u32 {
    return if (c == kInvalidCorner) kInvalidCorner else next(c);
}
fn previousGuarded(c: u32) u32 {
    return if (c == kInvalidCorner) kInvalidCorner else previous(c);
}

/// Half-edge corner table. `opposite_corners` and `corner_to_vertex` are the two
/// core per-corner arrays the connectivity decode populates. `vertex_corners`
/// is the per-vertex left-most-corner map that *grows* as new vertices are
/// created during the reverse-edgebreaker traversal (`AddNewVertex`); its
/// length is the live vertex count. Port of Draco `mesh/corner_table.{h,cc}`.
pub const CornerTable = struct {
    alloc: std.mem.Allocator,
    opposite_corners: []u32, // len = 3*num_faces; kInvalidCorner when open
    corner_to_vertex: []u32, // len = 3*num_faces
    vertex_corners: std.ArrayList(u32), // vertex -> left-most corner; grows via addNewVertex
    num_faces_: u32,

    /// `CornerTable::Reset(num_faces, num_vertices)`: allocate the two per-corner
    /// arrays (3*num_faces, marked invalid) and *reserve* capacity for the
    /// vertex map. The live vertex count starts at 0 — vertices are added one at
    /// a time by the traversal via `addNewVertex`.
    pub fn initEmpty(alloc: std.mem.Allocator, num_faces: u32, num_vertices: u32) Error!CornerTable {
        const nc = num_faces * 3;
        const opp = try alloc.alloc(u32, nc);
        errdefer alloc.free(opp);
        const c2v = try alloc.alloc(u32, nc);
        errdefer alloc.free(c2v);
        @memset(opp, kInvalidCorner);
        @memset(c2v, kInvalidVertex);
        var vc = std.ArrayList(u32).empty;
        errdefer vc.deinit(alloc);
        try vc.ensureTotalCapacity(alloc, num_vertices);
        return .{ .alloc = alloc, .opposite_corners = opp, .corner_to_vertex = c2v, .vertex_corners = vc, .num_faces_ = num_faces };
    }
    pub fn deinit(self: *CornerTable) void {
        self.alloc.free(self.opposite_corners);
        self.alloc.free(self.corner_to_vertex);
        self.vertex_corners.deinit(self.alloc);
    }
    pub fn numCorners(self: *const CornerTable) u32 {
        return @intCast(self.opposite_corners.len);
    }
    pub fn numFaces(self: *const CornerTable) u32 {
        return self.num_faces_;
    }
    pub fn numVertices(self: *const CornerTable) u32 {
        return @intCast(self.vertex_corners.items.len);
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

    /// `CornerTable::AddNewVertex`: append an isolated vertex, return its index.
    pub fn addNewVertex(self: *CornerTable) Error!u32 {
        try self.vertex_corners.append(self.alloc, kInvalidCorner);
        return @intCast(self.vertex_corners.items.len - 1);
    }
    /// `CornerTable::LeftMostCorner`.
    pub fn leftMostCorner(self: *const CornerTable, v: u32) u32 {
        return self.vertex_corners.items[v];
    }
    /// `CornerTable::SetLeftMostCorner` (no-op for the invalid vertex).
    pub fn setLeftMostCorner(self: *CornerTable, v: u32, c: u32) void {
        if (v != kInvalidVertex) self.vertex_corners.items[v] = c;
    }
    /// `CornerTable::MakeVertexIsolated`.
    pub fn makeVertexIsolated(self: *CornerTable, v: u32) void {
        self.vertex_corners.items[v] = kInvalidCorner;
    }

    /// `Opposite` guarded against the invalid corner (used by the swing ops).
    fn oppositeGuarded(self: *const CornerTable, c: u32) u32 {
        return if (c == kInvalidCorner) kInvalidCorner else self.opposite_corners[c];
    }
    /// `CornerTable::SwingLeft` = Next(Opposite(Next(c))): the corner on the
    /// adjacent left face that maps to the same vertex; invalid at a boundary.
    pub fn swingLeft(self: *const CornerTable, c: u32) u32 {
        return nextGuarded(self.oppositeGuarded(nextGuarded(c)));
    }
    /// `CornerTable::SwingRight` = Previous(Opposite(Previous(c))).
    pub fn swingRight(self: *const CornerTable, c: u32) u32 {
        return previousGuarded(self.oppositeGuarded(previousGuarded(c)));
    }

    /// `CornerTable::GetLeftCorner` = Opposite(Previous(c)): the corner of the
    /// adjacent face across the edge left of `c` (invalid at a boundary).
    /// Used by the attribute-order depth-first traverser.
    pub fn getLeftCorner(self: *const CornerTable, c: u32) u32 {
        if (c == kInvalidCorner) return kInvalidCorner;
        return self.oppositeGuarded(previous(c));
    }
    /// `CornerTable::GetRightCorner` = Opposite(Next(c)).
    pub fn getRightCorner(self: *const CornerTable, c: u32) u32 {
        if (c == kInvalidCorner) return kInvalidCorner;
        return self.oppositeGuarded(next(c));
    }
    /// `CornerTable::IsOnBoundary`: a vertex is on a boundary when swinging left
    /// from its left-most corner immediately falls off the mesh. Mirrors Draco:
    /// `SwingLeft(LeftMostCorner(v)) == kInvalidCorner`.
    pub fn isOnBoundary(self: *const CornerTable, v: u32) bool {
        const c = self.leftMostCorner(v);
        return self.swingLeft(c) == kInvalidCorner;
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

test "addNewVertex grows the vertex map; leftMostCorner round-trips" {
    const a = std.testing.allocator;
    var ct = try CornerTable.initEmpty(a, 2, 4);
    defer ct.deinit();
    try std.testing.expectEqual(@as(u32, 0), ct.numVertices()); // reserve only, live count 0
    try std.testing.expectEqual(@as(u32, 0), try ct.addNewVertex());
    try std.testing.expectEqual(@as(u32, 1), try ct.addNewVertex());
    try std.testing.expectEqual(@as(u32, 2), ct.numVertices());
    try std.testing.expectEqual(@as(u32, kInvalidCorner), ct.leftMostCorner(0)); // isolated on creation
    ct.setLeftMostCorner(0, 5);
    try std.testing.expectEqual(@as(u32, 5), ct.leftMostCorner(0));
    ct.makeVertexIsolated(0);
    try std.testing.expectEqual(@as(u32, kInvalidCorner), ct.leftMostCorner(0));
    // SetLeftMostCorner on the invalid vertex is a no-op (must not index OOB).
    ct.setLeftMostCorner(kInvalidVertex, 1);
}

test "getLeftCorner/getRightCorner/isOnBoundary over a two-triangle fan" {
    const a = std.testing.allocator;
    // Two faces (0,1,2) and (3,4,5) glued along the edge opposite corner 0 and
    // corner 4 (opposite(0)=4, opposite(4)=0). All other edges are open.
    var ct = try CornerTable.initEmpty(a, 2, 4);
    defer ct.deinit();
    _ = try ct.addNewVertex();
    _ = try ct.addNewVertex();
    _ = try ct.addNewVertex();
    _ = try ct.addNewVertex();
    ct.setOpposite(0, 4);
    ct.setOpposite(4, 0);
    // GetRightCorner(0) = Opposite(Next(0)) = Opposite(1) = invalid (open edge).
    try std.testing.expectEqual(kInvalidCorner, ct.getRightCorner(0));
    // GetLeftCorner(0) = Opposite(Previous(0)) = Opposite(2) = invalid.
    try std.testing.expectEqual(kInvalidCorner, ct.getLeftCorner(0));
    // Across the shared edge: GetLeftCorner(1) = Opposite(Previous(1)=0) = 4.
    try std.testing.expectEqual(@as(u32, 4), ct.getLeftCorner(1));
    // GetRightCorner(2) = Opposite(Next(2)=0) = 4.
    try std.testing.expectEqual(@as(u32, 4), ct.getRightCorner(2));
    // Invalid input corner is passed through unchanged.
    try std.testing.expectEqual(kInvalidCorner, ct.getLeftCorner(kInvalidCorner));
    try std.testing.expectEqual(kInvalidCorner, ct.getRightCorner(kInvalidCorner));

    // Boundary test: vertex 0 sits only on corner 0 (open on both sides) → on a
    // boundary. Set its left-most corner and confirm SwingLeft falls off.
    ct.setLeftMostCorner(0, 0);
    try std.testing.expect(ct.isOnBoundary(0));
    // Give vertex 1 a left-most corner whose SwingLeft crosses the shared edge
    // and returns to a valid corner → not a boundary. SwingLeft(3) =
    // Next(Opposite(Next(3)=4)=0) = Next(0) = 1 (valid) ⇒ interior.
    ct.setLeftMostCorner(1, 3);
    try std.testing.expect(!ct.isOnBoundary(1));
}

test "swingLeft/swingRight follow opposite ring; invalid at a boundary" {
    const a = std.testing.allocator;
    // Two faces (0,1,2) and (3,4,5) glued along corner 1 <-> corner 5.
    var ct = try CornerTable.initEmpty(a, 2, 4);
    defer ct.deinit();
    ct.setOpposite(1, 5);
    ct.setOpposite(5, 1);
    // SwingLeft(0) = Next(Opposite(Next(0))) = Next(Opposite(1)) = Next(5) = 3.
    try std.testing.expectEqual(@as(u32, 3), ct.swingLeft(0));
    // SwingRight(3) = Previous(Opposite(Previous(3))) = Previous(Opposite(5)) = Previous(1) = 0.
    try std.testing.expectEqual(@as(u32, 0), ct.swingRight(3));
    // At an open edge the swing yields the invalid corner (no overflow/panic).
    try std.testing.expectEqual(@as(u32, kInvalidCorner), ct.swingLeft(1));
    try std.testing.expectEqual(@as(u32, kInvalidCorner), ct.swingRight(0));
}
