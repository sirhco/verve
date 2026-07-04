const std = @import("std");
const draco = @import("draco.zig");
const corner_table = @import("corner_table.zig");

const kInvalidCorner: u32 = corner_table.kInvalidCorner;
const kInvalidVertex: u32 = corner_table.kInvalidVertex;

/// Invalid-guarded ring arithmetic (Draco's `CornerTable::Next`/`Previous`
/// return the invalid corner unchanged; the swing operators depend on that).
fn nextG(c: u32) u32 {
    return if (c == kInvalidCorner) kInvalidCorner else corner_table.next(c);
}
fn prevG(c: u32) u32 {
    return if (c == kInvalidCorner) kInvalidCorner else corner_table.previous(c);
}

/// Port of Draco `mesh/mesh_attribute_corner_table.{h,cc}`. Stores attribute
/// connectivity as a difference from a base `CornerTable`: attribute seam edges
/// split shared position vertices into distinct attribute vertices. This is the
/// connectivity-only (no mesh / no attribute) path — `RecomputeVertices(nullptr,
/// nullptr)` — with identity vertex↔attribute-entry mapping.
pub const MeshAttrCornerTable = struct {
    alloc: std.mem.Allocator,
    corner_table_: *const draco.CornerTable, // borrowed
    is_edge_on_seam_: []bool, // len = num_corners
    is_vertex_on_seam_: []bool, // len = num position vertices
    corner_to_vertex_map_: []u32, // len = num_corners; attribute vertex per corner
    vertex_to_left_most_corner_map_: std.ArrayList(u32), // grows; attr vertex -> corner
    vertex_to_attribute_entry_id_map_: std.ArrayList(u32), // grows; its len = num_vertices()
    no_interior_seams_: bool,

    /// `MeshAttributeCornerTable::InitEmpty`: allocate the per-corner seam +
    /// mapping arrays and reserve the per-attribute-vertex maps.
    pub fn init(alloc: std.mem.Allocator, ct: *const draco.CornerTable) draco.Error!MeshAttrCornerTable {
        const nc = ct.numCorners();
        const nv = ct.numVertices();
        const eos = try alloc.alloc(bool, nc);
        errdefer alloc.free(eos);
        const vos = try alloc.alloc(bool, nv);
        errdefer alloc.free(vos);
        const c2v = try alloc.alloc(u32, nc);
        errdefer alloc.free(c2v);
        @memset(eos, false);
        @memset(vos, false);
        @memset(c2v, kInvalidVertex);
        var vlm = std.ArrayList(u32).empty;
        errdefer vlm.deinit(alloc);
        try vlm.ensureTotalCapacity(alloc, nv);
        var vae = std.ArrayList(u32).empty;
        errdefer vae.deinit(alloc);
        try vae.ensureTotalCapacity(alloc, nv);
        return .{
            .alloc = alloc,
            .corner_table_ = ct,
            .is_edge_on_seam_ = eos,
            .is_vertex_on_seam_ = vos,
            .corner_to_vertex_map_ = c2v,
            .vertex_to_left_most_corner_map_ = vlm,
            .vertex_to_attribute_entry_id_map_ = vae,
            .no_interior_seams_ = true,
        };
    }

    pub fn deinit(self: *MeshAttrCornerTable) void {
        self.alloc.free(self.is_edge_on_seam_);
        self.alloc.free(self.is_vertex_on_seam_);
        self.alloc.free(self.corner_to_vertex_map_);
        self.vertex_to_left_most_corner_map_.deinit(self.alloc);
        self.vertex_to_attribute_entry_id_map_.deinit(self.alloc);
    }

    fn markVertexOnSeam(self: *MeshAttrCornerTable, c: u32) void {
        // c is guaranteed valid (a Next/Previous of a valid corner). Guard the
        // base vertex lookup against a corrupt table rather than panic.
        const v = self.corner_table_.vertex(c);
        if (v != kInvalidVertex and v < self.is_vertex_on_seam_.len) {
            self.is_vertex_on_seam_[v] = true;
        }
    }

    /// `MeshAttributeCornerTable::AddSeamEdge(c)`: mark the edge opposite corner
    /// `c` (and its opposite corner) as an attribute seam, and flag the two
    /// endpoint position vertices on each side as seam vertices.
    pub fn addSeamEdge(self: *MeshAttrCornerTable, c: u32) void {
        if (c == kInvalidCorner or c >= self.is_edge_on_seam_.len) return;
        self.is_edge_on_seam_[c] = true;
        self.markVertexOnSeam(corner_table.next(c));
        self.markVertexOnSeam(corner_table.previous(c));

        const opp = self.corner_table_.opposite(c);
        if (opp != kInvalidCorner and opp < self.is_edge_on_seam_.len) {
            self.no_interior_seams_ = false;
            self.is_edge_on_seam_[opp] = true;
            self.markVertexOnSeam(corner_table.next(opp));
            self.markVertexOnSeam(corner_table.previous(opp));
        }
    }

    /// `IsCornerOppositeToSeamEdge`.
    fn isCornerOppositeToSeamEdge(self: *const MeshAttrCornerTable, c: u32) bool {
        if (c == kInvalidCorner or c >= self.is_edge_on_seam_.len) return false;
        return self.is_edge_on_seam_[c];
    }

    /// `MeshAttributeCornerTable::Opposite`: like the base table's, but returns
    /// the invalid corner across a seam edge.
    fn oppositeMod(self: *const MeshAttrCornerTable, c: u32) u32 {
        if (c == kInvalidCorner or self.isCornerOppositeToSeamEdge(c)) return kInvalidCorner;
        return self.corner_table_.opposite(c);
    }

    /// `MeshAttributeCornerTable::SwingLeft` = Next(Opposite(Next(c))) using the
    /// seam-aware Opposite (does not cross a seam edge).
    fn swingLeftMod(self: *const MeshAttrCornerTable, c: u32) u32 {
        return nextG(self.oppositeMod(nextG(c)));
    }

    pub fn numVertices(self: *const MeshAttrCornerTable) u32 {
        return @intCast(self.vertex_to_attribute_entry_id_map_.items.len);
    }
    pub fn numFaces(self: *const MeshAttrCornerTable) u32 {
        return self.corner_table_.numFaces();
    }
    pub fn numCorners(self: *const MeshAttrCornerTable) u32 {
        return self.corner_table_.numCorners();
    }

    /// `MeshAttributeCornerTable::Vertex`: the attribute vertex of corner `c`.
    pub fn vertex(self: *const MeshAttrCornerTable, c: u32) u32 {
        if (c == kInvalidCorner or c >= self.corner_to_vertex_map_.len) return kInvalidVertex;
        return self.corner_to_vertex_map_[c];
    }

    pub fn leftMostCorner(self: *const MeshAttrCornerTable, v: u32) u32 {
        if (v >= self.vertex_to_left_most_corner_map_.items.len) return kInvalidCorner;
        return self.vertex_to_left_most_corner_map_.items[v];
    }

    /// `MeshAttributeCornerTable::RecomputeVertices(nullptr, nullptr)`: rebuild
    /// the attribute-vertex partition from the current seam edges. Identity
    /// vertex↔attribute-entry mapping (connectivity-only path).
    pub fn recomputeVertices(self: *MeshAttrCornerTable, ct: *const draco.CornerTable) draco.Error!void {
        std.debug.assert(ct == self.corner_table_);
        self.vertex_to_attribute_entry_id_map_.clearRetainingCapacity();
        self.vertex_to_left_most_corner_map_.clearRetainingCapacity();
        @memset(self.corner_to_vertex_map_, kInvalidVertex);

        const num_corners = self.corner_table_.numCorners();
        var num_new_vertices: u32 = 0;
        const pos_vertex_count = self.corner_table_.numVertices();
        var v: u32 = 0;
        while (v < pos_vertex_count) : (v += 1) {
            const c = self.corner_table_.leftMostCorner(v);
            if (c == kInvalidCorner) continue; // isolated vertex

            var first_vert_id: u32 = num_new_vertices;
            num_new_vertices += 1;
            try self.vertex_to_attribute_entry_id_map_.append(self.alloc, first_vert_id); // identity

            var first_c: u32 = c;
            var act_c: u32 = undefined;
            // On a seam vertex, swing left (seam-aware) to the first corner that
            // defines a seam, so we start the CCW walk at a seam boundary.
            if (v < self.is_vertex_on_seam_.len and self.is_vertex_on_seam_[v]) {
                act_c = self.swingLeftMod(first_c);
                var guard: u32 = 0;
                while (act_c != kInvalidCorner) {
                    first_c = act_c;
                    act_c = self.swingLeftMod(act_c);
                    if (act_c == c) return draco.Error.Corrupt; // reached start: bad table
                    guard += 1;
                    if (guard > num_corners) return draco.Error.Corrupt;
                }
            }
            if (first_c >= num_corners) return draco.Error.Corrupt;
            self.corner_to_vertex_map_[first_c] = first_vert_id;
            try self.vertex_to_left_most_corner_map_.append(self.alloc, first_c);

            // Walk the ring CW via the BASE table's SwingRight (crosses seams),
            // starting a new attribute vertex each time a seam edge is crossed.
            act_c = self.corner_table_.swingRight(first_c);
            var guard: u32 = 0;
            while (act_c != kInvalidCorner and act_c != first_c) {
                if (self.isCornerOppositeToSeamEdge(corner_table.next(act_c))) {
                    first_vert_id = num_new_vertices;
                    num_new_vertices += 1;
                    try self.vertex_to_attribute_entry_id_map_.append(self.alloc, first_vert_id); // identity
                    try self.vertex_to_left_most_corner_map_.append(self.alloc, act_c);
                }
                if (act_c >= num_corners) return draco.Error.Corrupt;
                self.corner_to_vertex_map_[act_c] = first_vert_id;
                act_c = self.corner_table_.swingRight(act_c);
                guard += 1;
                if (guard > num_corners) return draco.Error.Corrupt;
            }
        }
    }
};

test "recomputeVertices: no seam shares, seam splits" {
    const a = std.testing.allocator;
    // Two triangles sharing edge (v0,v2). Face0 = corners 0,1,2 ; face1 = 3,4,5.
    // corner->vertex: c0=v0 c1=v1 c2=v2 c3=v0 c4=v2 c5=v3.
    // Shared edge (v0,v2) is opposite corner c1 (face0) and c5 (face1).
    var ct = try draco.CornerTable.initEmpty(a, 2, 4);
    defer ct.deinit();
    _ = try ct.addNewVertex();
    _ = try ct.addNewVertex();
    _ = try ct.addNewVertex();
    _ = try ct.addNewVertex();
    ct.mapCornerToVertex(0, 0);
    ct.mapCornerToVertex(1, 1);
    ct.mapCornerToVertex(2, 2);
    ct.mapCornerToVertex(3, 0);
    ct.mapCornerToVertex(4, 2);
    ct.mapCornerToVertex(5, 3);
    ct.setOpposite(1, 5);
    ct.setOpposite(5, 1);
    ct.setLeftMostCorner(0, 3); // v0 -> c3
    ct.setLeftMostCorner(1, 1); // v1 -> c1
    ct.setLeftMostCorner(2, 2); // v2 -> c2
    ct.setLeftMostCorner(3, 5); // v3 -> c5

    // No seams: attribute vertices == position vertices (shared).
    var mact = try draco.MeshAttrCornerTable.init(a, &ct);
    defer mact.deinit();
    try mact.recomputeVertices(&ct);
    try std.testing.expectEqual(@as(u32, 4), mact.numVertices());
    // v0's two incident corners c0 and c3 share the same attribute vertex.
    try std.testing.expectEqual(mact.vertex(3), mact.vertex(0));
    try std.testing.expectEqual(@as(u32, 0), mact.vertex(3));
    try std.testing.expectEqual(@as(u32, 0), mact.vertex(0));

    // Add the shared edge as an attribute seam (corner c1 is opposite it).
    var mact2 = try draco.MeshAttrCornerTable.init(a, &ct);
    defer mact2.deinit();
    mact2.addSeamEdge(1);
    try mact2.recomputeVertices(&ct);
    // Both endpoints of the seam edge (v0, v2) split -> +2 attribute vertices.
    try std.testing.expectEqual(@as(u32, 6), mact2.numVertices());
    // v0's two incident corners now map to DIFFERENT attribute vertices.
    try std.testing.expect(mact2.vertex(0) != mact2.vertex(3));
    try std.testing.expectEqual(@as(u32, 0), mact2.vertex(3));
    try std.testing.expectEqual(@as(u32, 1), mact2.vertex(0));
    // v2 splits too: c2 vs c4.
    try std.testing.expect(mact2.vertex(2) != mact2.vertex(4));
    try std.testing.expectEqual(@as(u32, 3), mact2.vertex(2));
    try std.testing.expectEqual(@as(u32, 4), mact2.vertex(4));
}
