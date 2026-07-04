//! Inverse mesh prediction scheme — faithful port of the Draco decode step that
//! turns a stream of decoded integer *corrections* (residuals) back into the
//! per-point quantized integer values, run over Slice B's corner table.
//!
//! Ports (Draco `main`, `src/draco/compression/`):
//!   attributes/prediction_schemes/mesh_prediction_scheme_parallelogram_decoder.h
//!     `ComputeOriginalValues` — the parallelogram inverse with delta fallback.
//!   attributes/prediction_schemes/mesh_prediction_scheme_parallelogram_shared.h
//!     `ComputeParallelogramPrediction` / `GetParallelogramEntries` — predict a
//!     vertex value from the parallelogram `next + prev - opp` of the adjacent
//!     face (only when all three tip entries were decoded earlier).
//!   attributes/prediction_schemes/prediction_scheme_delta_decoder.h
//!     `ComputeOriginalValues` — the running prefix inverse (`PREDICTION_DIFFERENCE`).
//!   attributes/prediction_schemes/prediction_scheme_wrap_decoding_transform.h
//!   attributes/prediction_schemes/prediction_scheme_wrap_transform_base.h
//!     `PredictionSchemeWrapDecodingTransform::ComputeOriginalValue` — clamp the
//!     prediction to `[min,max]`, add the correction with unsigned wraparound,
//!     then unwrap any result that falls outside `[min,max]` by ±`max_dif`.
//!   mesh/traverser/depth_first_traverser.h + traverser_base.h +
//!   mesh/traverser/mesh_attribute_indices_encoding_observer.h +
//!   mesh/traverser/mesh_traversal_sequencer.h
//!     the DEPTH_FIRST attribute traversal that assigns each vertex its
//!     *encoding order* (`vertex_to_data_map`) and records the corner used
//!     (`data_to_corner_map`). All three committed fixtures (quad/cube/torus)
//!     pin `traversal_method == MESH_TRAVERSAL_DEPTH_FIRST (0)` and
//!     `scheme_method == MESH_PREDICTION_PARALLELOGRAM (1)` with WRAP bits=14.
//!
//! ★ Index spaces (the crux): residuals arrive in **data-entry order** (the
//! attribute-value / encoding order produced by the traversal). The prediction
//! inverse produces `out_data` in that same order. Because Slice B's
//! position-only connectivity has `point_id == vertex_id`
//! (`AssignPointsToCorners`), the final result is re-indexed into **per-vertex
//! (== per-point) order** via `vertex_to_data_map`, so it lines up 1:1 with
//! `Connectivity.indices`. That remap is what makes the output directly
//! consumable (dequantized) by Task 4.
//!
//! The residuals themselves (zigzag-decoded signed corrections, produced by
//! `SequentialIntegerAttributeDecoder::DecodeIntegerValues` after
//! `ConvertSymbolsToSignedInts`) are Task 4's input to this function; this
//! module never touches the entropy stream.
const std = @import("std");
const draco = @import("draco.zig");
const attributes = @import("attributes.zig");
const corner_table = @import("corner_table.zig");

pub const Error = draco.Error;
const CornerTable = corner_table.CornerTable;
const kInvalidCorner = corner_table.kInvalidCorner;
const kInvalidVertex = corner_table.kInvalidVertex;
const next = corner_table.next;
const previous = corner_table.previous;

/// Sentinel used only for face bookkeeping inside the traversal (mirrors
/// Draco's `kInvalidFaceIndex`, which `IsFaceVisited` treats as "visited").
const kInvalidFace: u32 = 0xffffffff;

/// `PredictionSchemeMethod` values this port inverts. `MULTI_PARALLELOGRAM (2)`
/// and `CONSTRAINED_MULTI_PARALLELOGRAM (4)` are rejected (no fixture exercises
/// them — see attributes.zig).
const method_difference: i8 = 0;
const method_parallelogram: i8 = 1;
const transform_wrap: i8 = 1;
const traversal_depth_first: u8 = 0;

/// Port of `PredictionSchemeWrapDecodingTransform` /
/// `PredictionSchemeWrapTransformBase` (decode side only). Holds the clamp
/// bounds `[min,max]` read from the stream and the derived `max_dif`.
const WrapTransform = struct {
    min_value: i32,
    max_value: i32,
    max_dif: i32,

    /// `InitCorrectionBounds`: `max_dif = 1 + (max - min)`. Rejects a malformed
    /// range instead of overflowing.
    fn init(min_value: i32, max_value: i32) Error!WrapTransform {
        const dif: i64 = @as(i64, max_value) - @as(i64, min_value);
        if (dif < 0 or dif >= std.math.maxInt(i32)) return Error.Corrupt;
        return .{ .min_value = min_value, .max_value = max_value, .max_dif = 1 + @as(i32, @intCast(dif)) };
    }

    /// `ClampPredictedValue` (per component).
    fn clamp(self: WrapTransform, v: i32) i32 {
        if (v > self.max_value) return self.max_value;
        if (v < self.min_value) return self.min_value;
        return v;
    }

    /// `ComputeOriginalValue` (single component): unsigned-add the correction to
    /// the clamped prediction, then unwrap out-of-range results by ±`max_dif`.
    /// Wrapping arithmetic throughout so malformed input can never panic.
    fn originalValue(self: WrapTransform, predicted: i32, corr: i32) i32 {
        const cp: u32 = @bitCast(self.clamp(predicted));
        var out: i32 = @bitCast(cp +% @as(u32, @bitCast(corr)));
        if (out > self.max_value) {
            out -%= self.max_dif;
        } else if (out < self.min_value) {
            out +%= self.max_dif;
        }
        return out;
    }
};

/// The two maps the mesh prediction inverse needs, produced by the DEPTH_FIRST
/// attribute traversal (Draco `MeshAttributeIndicesEncodingData`).
const TraversalMaps = struct {
    /// data entry id -> corner processed when that entry was decoded.
    data_to_corner: []u32,
    /// vertex id -> data entry id (-1 until the vertex is visited).
    vertex_to_data: []i32,
    num_values: usize,

    fn deinit(self: *TraversalMaps, alloc: std.mem.Allocator) void {
        alloc.free(self.data_to_corner);
        alloc.free(self.vertex_to_data);
    }
};

/// Port of `DepthFirstTraverser` + `MeshAttributeIndicesEncodingObserver`, run
/// by `MeshTraversalSequencer::GenerateSequenceInternal` over every face in id
/// order (`ProcessCorner(3*i)`). All corner/vertex indexing is bounds-guarded
/// so a corrupt corner table yields `Error.Corrupt`, never a panic.
const Traverser = struct {
    ct: *const CornerTable,
    alloc: std.mem.Allocator,
    is_face_visited: []bool,
    is_vertex_visited: []bool,
    stack: std.ArrayList(u32),
    vertex_to_data: []i32,
    data_to_corner: std.ArrayList(u32),
    num_values: usize,
    num_faces: u32,
    num_vertices: u32,
    num_corners: u32,

    fn onNewVertexVisited(self: *Traverser, vert: u32, corner: u32) Error!void {
        try self.data_to_corner.append(self.alloc, corner);
        self.vertex_to_data[vert] = @intCast(self.num_values);
        self.num_values += 1;
    }

    /// `TraverserBase::IsFaceVisited(CornerIndex)`.
    fn faceVisitedByCorner(self: *const Traverser, corner: u32) bool {
        if (corner == kInvalidCorner or corner >= self.num_corners) return true;
        return self.is_face_visited[corner / 3];
    }
    /// `TraverserBase::IsFaceVisited(FaceIndex)`.
    fn faceVisitedByFace(self: *const Traverser, face_id: u32) bool {
        if (face_id == kInvalidFace or face_id >= self.num_faces) return true;
        return self.is_face_visited[face_id];
    }
    fn vertexOf(self: *const Traverser, corner: u32) Error!u32 {
        if (corner >= self.num_corners) return Error.Corrupt;
        const v = self.ct.vertex(corner);
        if (v == kInvalidVertex or v >= self.num_vertices) return Error.Corrupt;
        return v;
    }

    /// `DepthFirstTraverser::TraverseFromCorner`.
    fn traverseFromCorner(self: *Traverser, start_corner: u32) Error!void {
        if (self.faceVisitedByCorner(start_corner)) return; // already traversed / invalid

        self.stack.clearRetainingCapacity();
        try self.stack.append(self.alloc, start_corner);

        // The first face's remaining two corners may still be unprocessed.
        const next_corner = next(start_corner);
        const prev_corner = previous(start_corner);
        const next_vert = try self.vertexOf(next_corner);
        const prev_vert = try self.vertexOf(prev_corner);
        if (!self.is_vertex_visited[next_vert]) {
            self.is_vertex_visited[next_vert] = true;
            try self.onNewVertexVisited(next_vert, next_corner);
        }
        if (!self.is_vertex_visited[prev_vert]) {
            self.is_vertex_visited[prev_vert] = true;
            try self.onNewVertexVisited(prev_vert, prev_corner);
        }

        while (self.stack.items.len > 0) {
            var corner_id = self.stack.items[self.stack.items.len - 1];
            if (corner_id == kInvalidCorner or self.faceVisitedByCorner(corner_id)) {
                _ = self.stack.pop();
                continue;
            }
            var face_id = corner_id / 3;
            inner: while (true) {
                if (face_id >= self.num_faces) return Error.Corrupt;
                self.is_face_visited[face_id] = true;
                const vert_id = try self.vertexOf(corner_id);
                if (!self.is_vertex_visited[vert_id]) {
                    const on_boundary = self.ct.isOnBoundary(vert_id);
                    self.is_vertex_visited[vert_id] = true;
                    try self.onNewVertexVisited(vert_id, corner_id);
                    if (!on_boundary) {
                        corner_id = self.ct.getRightCorner(corner_id);
                        if (corner_id == kInvalidCorner) return Error.Corrupt;
                        face_id = corner_id / 3;
                        continue :inner;
                    }
                }
                // Vertex already visited or on a boundary — try to descend into a
                // neighboring face.
                const right_corner = self.ct.getRightCorner(corner_id);
                const left_corner = self.ct.getLeftCorner(corner_id);
                const right_face = if (right_corner == kInvalidCorner) kInvalidFace else right_corner / 3;
                const left_face = if (left_corner == kInvalidCorner) kInvalidFace else left_corner / 3;
                if (self.faceVisitedByFace(right_face)) {
                    if (self.faceVisitedByFace(left_face)) {
                        _ = self.stack.pop();
                        break :inner;
                    } else {
                        corner_id = left_corner;
                        face_id = left_face;
                    }
                } else {
                    if (self.faceVisitedByFace(left_face)) {
                        corner_id = right_corner;
                        face_id = right_face;
                    } else {
                        // Split: process the right face first, the left one later.
                        self.stack.items[self.stack.items.len - 1] = left_corner;
                        try self.stack.append(self.alloc, right_corner);
                        break :inner;
                    }
                }
            }
        }
    }
};

fn buildTraversalMaps(alloc: std.mem.Allocator, ct: *const CornerTable) Error!TraversalMaps {
    const num_faces = ct.numFaces();
    const num_vertices = ct.numVertices();
    const num_corners = ct.numCorners();

    const vertex_to_data = try alloc.alloc(i32, num_vertices);
    errdefer alloc.free(vertex_to_data);
    @memset(vertex_to_data, -1);

    var t = Traverser{
        .ct = ct,
        .alloc = alloc,
        .is_face_visited = try alloc.alloc(bool, num_faces),
        .is_vertex_visited = try alloc.alloc(bool, num_vertices),
        .stack = std.ArrayList(u32).empty,
        .vertex_to_data = vertex_to_data,
        .data_to_corner = std.ArrayList(u32).empty,
        .num_values = 0,
        .num_faces = num_faces,
        .num_vertices = num_vertices,
        .num_corners = num_corners,
    };
    defer alloc.free(t.is_face_visited);
    defer alloc.free(t.is_vertex_visited);
    defer t.stack.deinit(alloc);
    errdefer t.data_to_corner.deinit(alloc);
    @memset(t.is_face_visited, false);
    @memset(t.is_vertex_visited, false);

    var fi: u32 = 0;
    while (fi < num_faces) : (fi += 1) {
        try t.traverseFromCorner(3 * fi);
    }

    return .{
        .data_to_corner = try t.data_to_corner.toOwnedSlice(alloc),
        .vertex_to_data = vertex_to_data,
        .num_values = t.num_values,
    };
}

/// Port of `ComputeParallelogramPrediction` (+ `GetParallelogramEntries`).
/// Writes the predicted value for data entry `p` into `pred` and returns true
/// only when the adjacent face exists and all three tip entries were decoded
/// before `p`. `out` is indexed by data entry id.
fn computeParallelogramPrediction(
    p: usize,
    ci: u32,
    ct: *const CornerTable,
    vertex_to_data: []const i32,
    out: []const i32,
    nc: usize,
    pred: []i32,
) Error!bool {
    if (ci >= ct.numCorners()) return Error.Corrupt;
    const oci = ct.opposite(ci);
    if (oci == kInvalidCorner) return false;
    if (oci >= ct.numCorners()) return Error.Corrupt;

    // GetParallelogramEntries(oci): opp = vertex(oci), next/prev around oci.
    const num_vertices: u32 = @intCast(vertex_to_data.len);
    const v_opp = ct.vertex(oci);
    const v_next = ct.vertex(next(oci));
    const v_prev = ct.vertex(previous(oci));
    if (v_opp >= num_vertices or v_next >= num_vertices or v_prev >= num_vertices) return Error.Corrupt;

    const e_opp = vertex_to_data[v_opp];
    const e_next = vertex_to_data[v_next];
    const e_prev = vertex_to_data[v_prev];
    if (e_opp < 0 or e_next < 0 or e_prev < 0) return false; // an entry not decoded yet

    const pi: i64 = @intCast(p);
    if (@as(i64, e_opp) < pi and @as(i64, e_next) < pi and @as(i64, e_prev) < pi) {
        const o_off = @as(usize, @intCast(e_opp)) * nc;
        const n_off = @as(usize, @intCast(e_next)) * nc;
        const p_off = @as(usize, @intCast(e_prev)) * nc;
        var c: usize = 0;
        while (c < nc) : (c += 1) {
            const result: i64 = (@as(i64, out[n_off + c]) + @as(i64, out[p_off + c])) - @as(i64, out[o_off + c]);
            pred[c] = @truncate(result); // static_cast<int32_t>
        }
        return true;
    }
    return false;
}

/// `PredictionSchemeDeltaDecoder::ComputeOriginalValues` — running prefix.
/// `out`/`residuals` are indexed by data entry id.
fn computeDifference(residuals: []const i32, out: []i32, nc: usize, wt: WrapTransform) void {
    var c: usize = 0;
    while (c < nc) : (c += 1) out[c] = wt.originalValue(0, residuals[c]); // predicted = 0
    var i: usize = nc;
    while (i < residuals.len) : (i += nc) {
        c = 0;
        while (c < nc) : (c += 1) out[i + c] = wt.originalValue(out[i - nc + c], residuals[i + c]);
    }
}

/// `MeshPredictionSchemeParallelogramDecoder::ComputeOriginalValues`.
fn computeParallelogram(
    residuals: []const i32,
    out: []i32,
    nc: usize,
    ct: *const CornerTable,
    maps: *const TraversalMaps,
    wt: WrapTransform,
    pred: []i32,
) Error!void {
    // First value: predicted from zero.
    var c: usize = 0;
    while (c < nc) : (c += 1) out[c] = wt.originalValue(0, residuals[c]);

    const corner_map_size = maps.data_to_corner.len;
    var p: usize = 1;
    while (p < corner_map_size) : (p += 1) {
        const ci = maps.data_to_corner[p];
        const dst = p * nc;
        if (try computeParallelogramPrediction(p, ci, ct, maps.vertex_to_data, out, nc, pred)) {
            c = 0;
            while (c < nc) : (c += 1) out[dst + c] = wt.originalValue(pred[c], residuals[dst + c]);
        } else {
            // Parallelogram unavailable → delta from the previously decoded entry.
            const src = (p - 1) * nc;
            c = 0;
            while (c < nc) : (c += 1) out[dst + c] = wt.originalValue(out[src + c], residuals[dst + c]);
        }
    }
}

/// Invert the mesh prediction scheme + WRAP transform for a position attribute.
///
/// Final signature (Task 4 consumes this):
///   `inversePredict(alloc, header, residuals, num_components, conn) Error![]i32`
///
/// - `header` — the `attributes.DecodedAttrHeader` produced by Task 1 (supplies
///   `scheme_method`, `transform_type`, `traversal_method`, and the WRAP
///   `wrap_min`/`wrap_max`).
/// - `residuals` — the zigzag-decoded signed corrections in **data-entry order**;
///   `residuals.len` must equal `num_points * num_components`.
/// - Returns an **owned** `[]i32` of the same length, re-indexed into per-point
///   (== per-vertex) order so it lines up with `conn.indices`. Caller frees.
///
/// Rejects (`Error.UnsupportedDracoFeature`) any scheme other than
/// PARALLELOGRAM/DIFFERENCE, any transform other than WRAP, and the
/// PREDICTION_DEGREE traversal (no fixture uses it). Never panics on malformed
/// connectivity — bounds violations map to `Error.Corrupt`.
pub fn inversePredict(
    alloc: std.mem.Allocator,
    header: attributes.DecodedAttrHeader,
    residuals: []const i32,
    num_components: u8,
    conn: *const draco.Connectivity,
) Error![]i32 {
    const nc: usize = num_components;
    if (nc == 0) return Error.Corrupt;
    if (header.num_components != num_components) return Error.Corrupt;
    if (header.transform_type != transform_wrap) return Error.UnsupportedDracoFeature;
    if (header.traversal_method != traversal_depth_first) return Error.UnsupportedDracoFeature;
    switch (header.scheme_method) {
        method_difference, method_parallelogram => {},
        else => return Error.UnsupportedDracoFeature,
    }

    const num_points: usize = conn.num_points;
    if (residuals.len != num_points * nc) return Error.Corrupt;
    if (num_points == 0) return alloc.alloc(i32, 0);

    const ct = &conn.corner_table;
    // `ct.numVertices()` is the corner table's *physical* `vertex_corners.items.len`,
    // which only ever grows (`addNewVertex`, used for topology-split handling —
    // see `edgebreaker.zig`'s "Remove vertices that were marked as isolated"
    // step). That step logically shrinks the live vertex count back down to
    // `num_points` by remapping every corner reference below `num_points` and
    // marking the (now-unreferenced) tail slots isolated, but it does not
    // truncate the backing array — so for genus>0 meshes that hit topology
    // splits during traversal (e.g. a torus), `ct.numVertices()` (104 here)
    // legitimately exceeds `num_points` (96): the extra slots are dead, never
    // targeted by any corner, and `buildTraversalMaps` below only ever visits
    // vertices reachable from a real face corner, so it never touches them.
    // Reject only when the array is *too small* to hold `num_points` — that's
    // the real corruption signal; equality was an over-strict leftover from
    // the split-free (quad/cube) fixtures that never exercised this path.
    if (ct.numVertices() < num_points) return Error.Corrupt;

    var maps = try buildTraversalMaps(alloc, ct);
    defer maps.deinit(alloc);
    // Every vertex must have been assigned exactly one data entry.
    if (maps.num_values != num_points or maps.data_to_corner.len != num_points) return Error.Corrupt;

    const wt = try WrapTransform.init(header.wrap_min, header.wrap_max);

    const out_data = try alloc.alloc(i32, num_points * nc);
    defer alloc.free(out_data);

    if (header.scheme_method == method_difference) {
        computeDifference(residuals, out_data, nc, wt);
    } else {
        const pred = try alloc.alloc(i32, nc);
        defer alloc.free(pred);
        try computeParallelogram(residuals, out_data, nc, ct, &maps, wt, pred);
    }

    // Re-index data-entry order -> per-point (== per-vertex) order.
    const result = try alloc.alloc(i32, num_points * nc);
    errdefer alloc.free(result);
    var v: usize = 0;
    while (v < num_points) : (v += 1) {
        const e = maps.vertex_to_data[v];
        if (e < 0 or @as(usize, @intCast(e)) >= num_points) return Error.Corrupt;
        const eu: usize = @intCast(e);
        var c: usize = 0;
        while (c < nc) : (c += 1) result[v * nc + c] = out_data[eu * nc + c];
    }
    return result;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "WrapTransform.originalValue: add, clamp, and ±max_dif unwrap" {
    // Matches the quad/cube/torus fixtures: 14-bit range [0, 16383].
    const wt = try WrapTransform.init(0, 16383);
    try std.testing.expectEqual(@as(i32, 16384), wt.max_dif);
    // In-range: 100 + 23 = 123.
    try std.testing.expectEqual(@as(i32, 123), wt.originalValue(100, 23));
    // Overflow past max wraps down by max_dif: 16383 + 1 = 16384 > max → 0.
    try std.testing.expectEqual(@as(i32, 0), wt.originalValue(16383, 1));
    // Underflow below min wraps up by max_dif: 0 + (-1) = -1 < min → 16383.
    try std.testing.expectEqual(@as(i32, 16383), wt.originalValue(0, -1));
    // Prediction clamps before the add: predicted 20000 → clamped 16383, +0 → 16383.
    try std.testing.expectEqual(@as(i32, 16383), wt.originalValue(20000, 0));
    // Malformed range rejected, not panicked.
    try std.testing.expectError(Error.Corrupt, WrapTransform.init(5, 4));
}

// Build a single, isolated triangle corner table: face 0 = corners (0,1,2) with
// vertices (0,1,2); all edges open (opposite = invalid); each vertex's left-most
// corner is its only corner. Used by the DIFFERENCE / parallelogram-fallback
// tests below. DEPTH_FIRST traversal of this yields data-entry order
// v1,v2,v0 → vertex_to_data = [2,0,1].
fn singleTriangle(alloc: std.mem.Allocator) Error!draco.Connectivity {
    var ct = try CornerTable.initEmpty(alloc, 1, 3);
    errdefer ct.deinit();
    ct.mapCornerToVertex(0, 0);
    ct.mapCornerToVertex(1, 1);
    ct.mapCornerToVertex(2, 2);
    _ = try ct.addNewVertex(); // v0
    _ = try ct.addNewVertex(); // v1
    _ = try ct.addNewVertex(); // v2
    ct.setLeftMostCorner(0, 0);
    ct.setLeftMostCorner(1, 1);
    ct.setLeftMostCorner(2, 2);
    const indices = try alloc.alloc(u32, 3);
    indices[0] = 0;
    indices[1] = 1;
    indices[2] = 2;
    return .{ .alloc = alloc, .indices = indices, .corner_table = ct, .num_points = 3 };
}

fn diffHeader(scheme: i8) attributes.DecodedAttrHeader {
    return .{
        .scheme_method = scheme,
        .transform_type = transform_wrap,
        .quant = .{ .min = .{ 0, 0, 0 }, .range = 1.0, .bits = 14 },
        .num_components = 1,
        .traversal_method = traversal_depth_first,
        // Wide bounds so no wraparound occurs in these small hand cases.
        .wrap_min = -1000000,
        .wrap_max = 1000000,
    };
}

test "traversal maps: single triangle → data-entry order v1,v2,v0" {
    const a = std.testing.allocator;
    var conn = try singleTriangle(a);
    defer conn.deinit();
    var maps = try buildTraversalMaps(a, &conn.corner_table);
    defer maps.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), maps.num_values);
    // vertex_to_data[v]: v0→2, v1→0, v2→1.
    try std.testing.expectEqualSlices(i32, &[_]i32{ 2, 0, 1 }, maps.vertex_to_data);
    // data_to_corner[p]: entry0 was reached via corner Next(0)=1 (vertex 1),
    // entry1 via Previous(0)=2 (vertex 2), entry2 via corner 0 (vertex 0).
    try std.testing.expectEqualSlices(u32, &[_]u32{ 1, 2, 0 }, maps.data_to_corner);
}

test "DIFFERENCE inverse: residuals [5,3,-2] → data-entry [5,8,6], per-point [6,5,8]" {
    const a = std.testing.allocator;
    var conn = try singleTriangle(a);
    defer conn.deinit();
    // nc = 1. Data-entry prefix sums (no wrap): 5, 5+3=8, 8-2=6.
    // Remap to per-vertex order via vertex_to_data=[2,0,1]:
    //   v0=out[2]=6, v1=out[0]=5, v2=out[1]=8.
    const residuals = [_]i32{ 5, 3, -2 };
    const got = try inversePredict(a, diffHeader(method_difference), &residuals, 1, &conn);
    defer a.free(got);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 6, 5, 8 }, got);
}

test "PARALLELOGRAM on an open triangle degrades to the delta fallback" {
    const a = std.testing.allocator;
    var conn = try singleTriangle(a);
    defer conn.deinit();
    // No interior edges → every parallelogram lookup fails → identical to DELTA.
    const residuals = [_]i32{ 5, 3, -2 };
    const got = try inversePredict(a, diffHeader(method_parallelogram), &residuals, 1, &conn);
    defer a.free(got);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 6, 5, 8 }, got);
}

test "computeParallelogramPrediction: true branch = next + prev - opp" {
    const a = std.testing.allocator;
    // Two triangles sharing the edge opposite corner 0 / corner 4.
    // Face0 corners (0,1,2) = verts (0,1,2); Face1 corners (3,4,5) = verts (1,3,2).
    var ct = try CornerTable.initEmpty(a, 2, 4);
    defer ct.deinit();
    ct.mapCornerToVertex(0, 0);
    ct.mapCornerToVertex(1, 1);
    ct.mapCornerToVertex(2, 2);
    ct.mapCornerToVertex(3, 1);
    ct.mapCornerToVertex(4, 3);
    ct.mapCornerToVertex(5, 2);
    ct.setOpposite(0, 4);
    ct.setOpposite(4, 0);
    _ = try ct.addNewVertex();
    _ = try ct.addNewVertex();
    _ = try ct.addNewVertex();
    _ = try ct.addNewVertex();

    // Predict data entry p=3 at corner 4 (vertex 3). Opposite is corner 0, whose
    // face has tip verts opp=v0, next=vertex(Next(0)=1)=v1, prev=vertex(Prev(0)=2)=v2.
    // Give those vertices data entries 0,1,2 (all < 3) and known out values.
    const vertex_to_data = [_]i32{ 0, 1, 2, 3 }; // v0→0, v1→1, v2→2, v3→3
    // out_data (data-entry order), nc = 2:
    //   e0(v0)=(10,100)  e1(v1)=(20,200)  e2(v2)=(30,300)
    const out_data = [_]i32{ 10, 100, 20, 200, 30, 300 };
    var pred = [_]i32{ 0, 0 };
    const ok = try computeParallelogramPrediction(3, 4, &ct, &vertex_to_data, &out_data, 2, &pred);
    try std.testing.expect(ok);
    // pred = next(v1) + prev(v2) - opp(v0) = (20+30-10, 200+300-100) = (40, 400).
    try std.testing.expectEqual(@as(i32, 40), pred[0]);
    try std.testing.expectEqual(@as(i32, 400), pred[1]);

    // Same corner but with a tip entry not yet decoded (>= p) → no prediction.
    const vtd_future = [_]i32{ 0, 5, 2, 3 }; // v1 mapped to 5 > p=3
    try std.testing.expect(!try computeParallelogramPrediction(3, 4, &ct, &vtd_future, &out_data, 2, &pred));
}

test "inversePredict rejects unsupported scheme/transform/traversal" {
    const a = std.testing.allocator;
    var conn = try singleTriangle(a);
    defer conn.deinit();
    const residuals = [_]i32{ 0, 0, 0 };
    var h = diffHeader(method_difference);
    h.scheme_method = 2; // MULTI_PARALLELOGRAM
    try std.testing.expectError(Error.UnsupportedDracoFeature, inversePredict(a, h, &residuals, 1, &conn));
    h = diffHeader(method_difference);
    h.transform_type = 0; // not WRAP
    try std.testing.expectError(Error.UnsupportedDracoFeature, inversePredict(a, h, &residuals, 1, &conn));
    h = diffHeader(method_difference);
    h.traversal_method = 1; // PREDICTION_DEGREE
    try std.testing.expectError(Error.UnsupportedDracoFeature, inversePredict(a, h, &residuals, 1, &conn));
}
