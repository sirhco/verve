const std = @import("std");
const draco = @import("draco.zig");
const DecoderBuffer = draco.DecoderBuffer;
pub const Error = draco.Error;

const ct_mod = @import("corner_table.zig");
const CornerTable = ct_mod.CornerTable;
const kInvalidCorner = ct_mod.kInvalidCorner;
const kInvalidVertex = ct_mod.kInvalidVertex;
const cNext = ct_mod.next;
const cPrev = ct_mod.previous;
const TraversalDecoder = @import("traversal_standard.zig").TraversalDecoder;

// Faithful port of Draco `mesh_edgebreaker_decoder.cc::InitializeDecoder` (the
// traversal-type byte) plus `mesh_edgebreaker_decoder_impl.cc`'s
// `DecodeConnectivity()` header-counts section (~line 247) and
// `DecodeHoleAndTopologySplitEvents` (~line 978).
//
// ★ Scope: this ports the bitstream-version 2.2 field layout ONLY (our
// fixtures — draco3dgltf always emits 2.2). Draco's `DRACO_BACKWARDS_COMPATIBILITY_SUPPORTED`
// branches read several fields differently (raw ints vs varints, an extra
// `num_new_verts` field, an `encoded_connectivity_size`-prefixed sub-buffer
// for hole/split events, 2-bit vs 1-bit split edges, and a hole-event count
// that IS read for bitstream < 2.1) for older streams. None of that is
// ported here. `header.zig`'s `parseHeader` rejects any bitstream version
// other than 2.2 (`error.UnsupportedDracoVersion`), so this module only
// ever runs on a confirmed-2.2 stream — there is no separate version check
// in this file.
//
// Preamble: per `PointCloudDecoder::Decode` (point_cloud_decoder.cc), the
// call order is DecodeHeader -> (DecodeMetadata if flag set) ->
// InitializeDecoder -> DecodeGeometryData (-> DecodeConnectivity). Nothing
// else is read between the file header and `InitializeDecoder`'s
// `traversal_decoder_type` byte, so for a metadata-free stream (our
// fixtures, flags == 0) that byte is the very next byte after the 11-byte
// file header.

/// MESH_EDGEBREAKER_STANDARD_ENCODING (0) is the only traversal-decoder type
/// this port implements; PREDICTIVE (1) and VALENCE (2) are rejected.
pub const kStandardEncoding: u8 = 0;

pub const ConnState = struct {
    traversal_type: u8,
};

/// Reads the `InitializeDecoder` traversal-type byte. Caller must have
/// already consumed the file header (and metadata, if any) via
/// `draco.parseHeader` / `draco.skipMetadata`.
pub fn beginConnectivity(buf: *DecoderBuffer) Error!ConnState {
    const traversal_type = try buf.readInt(u8);
    if (traversal_type != kStandardEncoding) return Error.UnsupportedDracoFeature;
    return .{ .traversal_type = traversal_type };
}

/// Header counts read at the top of `DecodeConnectivity()`. `num_new_verts`
/// is always 0 here — it is only present for bitstream < 2.2 (not ported).
pub const ConnHeader = struct {
    num_new_verts: u32,
    num_encoded_vertices: u32,
    num_faces: u32,
    num_attribute_data: u8,
    num_encoded_symbols: u32,
    num_encoded_split_symbols: u32,
};

/// Port of `DecodeConnectivity()`'s count-parsing preamble (impl.cc:247),
/// v2.2 field order exactly: num_encoded_vertices (varint), num_faces
/// (varint), num_attribute_data (raw u8), num_encoded_symbols (varint),
/// num_encoded_split_symbols (varint). Enforces Draco's sanity bounds.
pub fn parseConnHeader(buf: *DecoderBuffer) Error!ConnHeader {
    const num_encoded_vertices = try buf.decodeVarint(u32);
    const num_faces = try buf.decodeVarint(u32);

    // Draco cannot handle more faces than fit a signed 32-bit corner index / 3.
    if (num_faces > std.math.maxInt(i32) / 3) return Error.Corrupt;
    // There cannot be more vertices than 3 * num_faces.
    if (num_encoded_vertices > num_faces * 3) return Error.Corrupt;

    // Graph-theory sanity: the maximum number of edges realizable among
    // num_encoded_vertices must be able to cover the minimum edges implied by
    // num_faces (each face has 3 edges, each edge shared by at most 2 faces).
    const min_num_face_edges: u64 = @as(u64, num_faces) * 3 / 2;
    const v64: u64 = num_encoded_vertices;
    const max_num_vertex_edges: u64 = if (v64 == 0) 0 else v64 * (v64 - 1) / 2;
    if (max_num_vertex_edges < min_num_face_edges) return Error.Corrupt;

    const num_attribute_data = try buf.readInt(u8);
    if (num_attribute_data != 0) return Error.UnsupportedDracoFeature;

    const num_encoded_symbols = try buf.decodeVarint(u32);
    // Number of faces must be >= number of symbols (the initial face may not
    // be encoded as a symbol).
    if (num_faces < num_encoded_symbols) return Error.Corrupt;
    // Faces can only be 1 1/3 times bigger than the number of encoded symbols.
    const max_encoded_faces = num_encoded_symbols + num_encoded_symbols / 3;
    if (num_faces > max_encoded_faces) return Error.Corrupt;

    const num_encoded_split_symbols = try buf.decodeVarint(u32);
    if (num_encoded_split_symbols > num_encoded_symbols) return Error.Corrupt; // subset of all symbols

    return .{
        .num_new_verts = 0,
        .num_encoded_vertices = num_encoded_vertices,
        .num_faces = num_faces,
        .num_attribute_data = num_attribute_data,
        .num_encoded_symbols = num_encoded_symbols,
        .num_encoded_split_symbols = num_encoded_split_symbols,
    };
}

/// One `TopologySplitEventData` (mesh_edgebreaker_shared.h).
pub const TopologySplitEvent = struct {
    split_symbol_id: u32,
    source_symbol_id: u32,
    source_edge: u1,
};

/// One `HoleEventData`. Never populated for bitstream >= 2.1 (see below) —
/// kept only so callers have a stable, always-present field.
pub const HoleEvent = struct {
    symbol_id: u32,
};

pub const Events = struct {
    alloc: std.mem.Allocator,
    topology_splits: []TopologySplitEvent,
    holes: []HoleEvent,

    pub fn deinit(self: *Events) void {
        self.alloc.free(self.topology_splits);
        self.alloc.free(self.holes);
    }
};

/// Port of `DecodeHoleAndTopologySplitEvents`, v2.2 path exactly:
///   - num_topology_splits: varint, bounded by hdr.num_faces.
///   - per split: source_symbol_id = delta(varint) + running source id;
///     split_symbol_id = source_symbol_id - delta(varint) (delta must not
///     exceed source_symbol_id).
///   - split source_edge bits: a direct (no size-prefix) 1-bit-per-split
///     bit region (bitstream >= 2.2 reads 1 bit; older streams read 2 — not
///     ported).
///   - num_hole_events: for bitstream >= 2.1 this field is NEVER read (Draco
///     leaves it 0 and decodes zero hole events) — so nothing further is
///     consumed here. `holes` is always returned empty by this port.
/// Caller owns the returned `Events` and must call `.deinit()`.
pub fn decodeEvents(alloc: std.mem.Allocator, buf: *DecoderBuffer, hdr: ConnHeader) Error!Events {
    const num_topology_splits = try buf.decodeVarint(u32);
    if (num_topology_splits > hdr.num_faces) return Error.Corrupt;

    const splits = try alloc.alloc(TopologySplitEvent, num_topology_splits);
    errdefer alloc.free(splits);

    if (num_topology_splits > 0) {
        var last_source_symbol_id: u32 = 0;
        for (splits) |*ev| {
            const source_delta = try buf.decodeVarint(u32);
            // Draco's C++ does a plain uint32 wraparound add here; we
            // deliberately deviate and reject overflow as Corrupt instead —
            // consistent with this port's never-panic/never-silent-misdecode
            // posture (a wrapped id would otherwise silently point at the
            // wrong symbol downstream).
            const source_symbol_id = std.math.add(u32, source_delta, last_source_symbol_id) catch return Error.Corrupt;
            const split_delta = try buf.decodeVarint(u32);
            if (split_delta > source_symbol_id) return Error.Corrupt;
            ev.* = .{
                .source_symbol_id = source_symbol_id,
                .split_symbol_id = source_symbol_id - split_delta,
                .source_edge = 0,
            };
            last_source_symbol_id = source_symbol_id;
        }
        // Direct bit region (StartBitDecoding(decode_size=false, ...)): no
        // size-prefix varint — the region is exactly ceil(nbits/8) bytes,
        // matching Draco's EndBitDecoding() byte-advance.
        const nbytes = (num_topology_splits + 7) / 8;
        var bd = try buf.bitDecoder(nbytes);
        for (splits) |*ev| ev.source_edge = bd.readBit();
    }

    // Never allocated for bitstream 2.2 (hole events are never decoded — see
    // doc comment above) — use an empty sentinel rather than a real
    // zero-length heap allocation. `Events.deinit` frees this via
    // `alloc.free`, which is a documented no-op for a zero-length slice
    // regardless of the slice's origin, so this stays safe.
    const holes: []HoleEvent = &[_]HoleEvent{};
    return .{ .alloc = alloc, .topology_splits = splits, .holes = holes };
}

// ── reverse-CLERS traversal → corner table → indices ─────────────────────────
// Faithful port of `MeshEdgebreakerDecoderImpl<>::DecodeConnectivity(int
// num_symbols)` (mesh_edgebreaker_decoder_impl.cc:535), v2.2 STANDARD path,
// num_attribute_data == 0. The reverse decoding keeps track of the active edge
// (identified by its opposite "active corner"); new faces are always added to
// the active edge. Multiple active edges live on a stack: TOPOLOGY_E pushes,
// TOPOLOGY_S pops-and-merges, TOPOLOGY_C/L/R extend the top. Topology-split
// events re-inject active edges keyed by the (decoder) symbol id.

/// EdgeFaceName (mesh_edgebreaker_shared.h): RIGHT_FACE_EDGE == 1.
const RIGHT_FACE_EDGE: u1 = 1;

/// Decoded position-only connectivity. `indices` are Draco-native vertex ids,
/// 3 per face. Caller owns everything and must call `deinit`.
pub const Connectivity = struct {
    alloc: std.mem.Allocator,
    indices: []u32,
    corner_table: CornerTable,
    num_points: u32,

    pub fn deinit(self: *Connectivity) void {
        self.alloc.free(self.indices);
        self.corner_table.deinit();
    }
};

/// A corner known to come from the active stack / Next / Previous of a valid
/// corner is provably in `[0, num_corners)`. Corners derived from
/// `LeftMostCorner` (which may be `kInvalidCorner`) are validated here before
/// they index a per-corner array. Never panics on malformed input.
inline fn reqCorner(ct: *const CornerTable, c: u32) Error!u32 {
    if (c == kInvalidCorner or c >= ct.numCorners()) return Error.Corrupt;
    return c;
}
/// A vertex about to index `vertex_corners` / `is_vert_hole` must be live.
inline fn reqVertex(v: u32, num_vertices: u32) Error!u32 {
    if (v == kInvalidVertex or v >= num_vertices) return Error.Corrupt;
    return v;
}

/// Port of `VertexCornersIterator` (corner_table_iterators.h): visits every
/// corner attached to a vertex by swinging left from the left-most corner to
/// the boundary, then right from the start corner.
const VertexCornersIter = struct {
    ct: *const CornerTable,
    start_corner: u32,
    corner: u32,
    left_traversal: bool,

    fn init(ct: *const CornerTable, vert: u32) VertexCornersIter {
        const sc = ct.leftMostCorner(vert);
        return .{ .ct = ct, .start_corner = sc, .corner = sc, .left_traversal = true };
    }
    fn end(self: *const VertexCornersIter) bool {
        return self.corner == kInvalidCorner;
    }
    fn advance(self: *VertexCornersIter) void {
        if (self.left_traversal) {
            self.corner = self.ct.swingLeft(self.corner);
            if (self.corner == kInvalidCorner) {
                self.corner = self.ct.swingRight(self.start_corner);
                self.left_traversal = false;
            } else if (self.corner == self.start_corner) {
                self.corner = kInvalidCorner;
            }
        } else {
            self.corner = self.ct.swingRight(self.corner);
        }
    }
};

/// `IsTopologySplit` (mesh_edgebreaker_decoder_impl.h). `splits` is consumed
/// from the back (`split_count` shrinks). Returns whether `encoder_symbol_id`
/// starts a split; on a mismatched (already-passed) source id it flags an
/// error by setting `out_split_id` to -1 and still returning true.
fn isTopologySplit(
    splits: []const TopologySplitEvent,
    split_count: *usize,
    encoder_symbol_id: i64,
    out_edge: *u1,
    out_split_id: *i64,
) bool {
    if (split_count.* == 0) return false;
    const back = splits[split_count.* - 1];
    if (@as(i64, back.source_symbol_id) > encoder_symbol_id) {
        out_split_id.* = -1;
        return true;
    }
    if (@as(i64, back.source_symbol_id) != encoder_symbol_id) return false;
    out_edge.* = back.source_edge;
    out_split_id.* = @as(i64, back.split_symbol_id);
    split_count.* -= 1;
    return true;
}

/// Decode the mesh connectivity. `buf` must be positioned right after
/// `parseHeader` (the traversal-type byte is read here). Produces the
/// index/corner-table pair consumed by later slices.
pub fn decodeConnectivity(alloc: std.mem.Allocator, buf: *DecoderBuffer) Error!Connectivity {
    _ = try beginConnectivity(buf); // traversal-type byte (STANDARD only)
    const h = try parseConnHeader(buf);

    // `is_vert_hole_` is sized to the max possible vertex count (extra vertices
    // may be created by split symbols and later removed). This is also the
    // upper bound checked against `corner_table.num_vertices()`.
    const max_num_vertices = std.math.add(u32, h.num_encoded_vertices, h.num_encoded_split_symbols) catch return Error.Corrupt;

    var ct = try CornerTable.initEmpty(alloc, h.num_faces, max_num_vertices);
    errdefer ct.deinit();

    // Start with all vertices marked as holes; only TOPOLOGY_C and interior
    // start faces clear the flag. Kept for faithful parity — it does not affect
    // the emitted indices (used by attribute decode only), but the reorder
    // pass below swaps it alongside the vertex remap.
    const is_vert_hole = try alloc.alloc(bool, max_num_vertices);
    defer alloc.free(is_vert_hole);
    @memset(is_vert_hole, true);

    // Topology-split + hole events, then the traversal streams (symbols +
    // start-face rANS). Read order mirrors `DecodeConnectivity` exactly.
    var events = try decodeEvents(alloc, buf, h);
    defer events.deinit();

    var td: TraversalDecoder = undefined;
    try td.start(buf); // CLERS symbol bit region
    try td.startFaces(buf); // start-face configuration rANS stream

    // active_corner_stack: the LIFO of active edges (by opposite corner).
    var active_stack = std.ArrayList(u32).empty;
    defer active_stack.deinit(alloc);

    // topology_split_active_corners: symbol-id -> re-injected active corner.
    const split_corners = try alloc.alloc(u32, h.num_encoded_symbols);
    defer alloc.free(split_corners);
    @memset(split_corners, kInvalidCorner);

    // Vertices marked isolated by TOPOLOGY_S (removed after the traversal).
    var invalid_vertices = std.ArrayList(u32).empty;
    defer invalid_vertices.deinit(alloc);

    var split_count: usize = events.topology_splits.len;
    const num_symbols: i64 = h.num_encoded_symbols;

    var num_faces: u32 = 0;
    var symbol_id: u32 = 0;
    while (symbol_id < h.num_encoded_symbols) : (symbol_id += 1) {
        const face = num_faces;
        num_faces += 1;
        var check_topology_split = false;
        const sym = try td.decodeSymbol();
        switch (sym) {
            .c => {
                // New face between the top active edge (opposite corner "a") and
                // the edge reachable CCW around vertex "x".
                if (active_stack.items.len == 0) return Error.Corrupt;
                const corner_a = active_stack.items[active_stack.items.len - 1];
                const vertex_x = try reqVertex(ct.vertex(cNext(corner_a)), ct.numVertices());
                const corner_b = cNext(try reqCorner(&ct, ct.leftMostCorner(vertex_x)));
                if (corner_a == corner_b) return Error.Corrupt;
                if (ct.opposite(corner_a) != kInvalidCorner or ct.opposite(corner_b) != kInvalidCorner) return Error.Corrupt;

                const corner = 3 * face;
                setOppositeCorners(&ct, corner_a, corner + 1);
                setOppositeCorners(&ct, corner_b, corner + 2);

                const vert_a_prev = ct.vertex(cPrev(corner_a));
                const vert_b_next = ct.vertex(cNext(corner_b));
                if (vertex_x == vert_a_prev or vertex_x == vert_b_next) return Error.Corrupt;
                ct.mapCornerToVertex(corner, vertex_x);
                ct.mapCornerToVertex(corner + 1, vert_b_next);
                ct.mapCornerToVertex(corner + 2, vert_a_prev);
                ct.setLeftMostCorner(try reqVertex(vert_a_prev, ct.numVertices()), corner + 2);
                is_vert_hole[vertex_x] = false;
                active_stack.items[active_stack.items.len - 1] = corner;
            },
            .r, .l => {
                if (active_stack.items.len == 0) return Error.Corrupt;
                const corner_a = active_stack.items[active_stack.items.len - 1];
                if (ct.opposite(corner_a) != kInvalidCorner) return Error.Corrupt;

                const corner = 3 * face;
                var opp_corner: u32 = undefined;
                var corner_l: u32 = undefined;
                var corner_r: u32 = undefined;
                if (sym == .r) {
                    opp_corner = corner + 2;
                    corner_l = corner + 1;
                    corner_r = corner;
                } else {
                    opp_corner = corner + 1;
                    corner_l = corner;
                    corner_r = corner + 2;
                }
                setOppositeCorners(&ct, opp_corner, corner_a);
                const new_vert = try ct.addNewVertex();
                if (ct.numVertices() > max_num_vertices) return Error.Corrupt;
                ct.mapCornerToVertex(opp_corner, new_vert);
                ct.setLeftMostCorner(new_vert, opp_corner);

                const vertex_r = ct.vertex(cPrev(corner_a));
                ct.mapCornerToVertex(corner_r, vertex_r);
                ct.setLeftMostCorner(try reqVertex(vertex_r, ct.numVertices()), corner_r);
                ct.mapCornerToVertex(corner_l, ct.vertex(cNext(corner_a)));
                active_stack.items[active_stack.items.len - 1] = corner;
                check_topology_split = true;
            },
            .s => {
                // Merge the two top active edges; no new vertex, but vertices at
                // "p" and "n" are unified.
                if (active_stack.items.len == 0) return Error.Corrupt;
                const corner_b = active_stack.pop().?;

                if (symbol_id < split_corners.len and split_corners[symbol_id] != kInvalidCorner) {
                    try active_stack.append(alloc, split_corners[symbol_id]);
                }
                if (active_stack.items.len == 0) return Error.Corrupt;
                const corner_a = active_stack.items[active_stack.items.len - 1];
                if (corner_a == corner_b) return Error.Corrupt;
                if (ct.opposite(corner_a) != kInvalidCorner or ct.opposite(corner_b) != kInvalidCorner) return Error.Corrupt;

                const corner = 3 * face;
                setOppositeCorners(&ct, corner_a, corner + 2);
                setOppositeCorners(&ct, corner_b, corner + 1);

                const vertex_p = try reqVertex(ct.vertex(cPrev(corner_a)), ct.numVertices());
                ct.mapCornerToVertex(corner, vertex_p);
                ct.mapCornerToVertex(corner + 1, ct.vertex(cNext(corner_a)));
                const vert_b_prev = ct.vertex(cPrev(corner_b));
                ct.mapCornerToVertex(corner + 2, vert_b_prev);
                ct.setLeftMostCorner(try reqVertex(vert_b_prev, ct.numVertices()), corner + 2);

                var corner_n = cNext(corner_b);
                const vertex_n = try reqVertex(ct.vertex(corner_n), ct.numVertices());
                // MergeVertices is a no-op for the STANDARD decoder.
                ct.setLeftMostCorner(vertex_p, ct.leftMostCorner(vertex_n));

                const first_corner = corner_n;
                while (corner_n != kInvalidCorner) {
                    ct.mapCornerToVertex(try reqCorner(&ct, corner_n), vertex_p);
                    corner_n = ct.swingLeft(corner_n);
                    if (corner_n == first_corner) return Error.Corrupt;
                }
                ct.makeVertexIsolated(vertex_n);
                try invalid_vertices.append(alloc, vertex_n);
                active_stack.items[active_stack.items.len - 1] = corner;
            },
            .e => {
                const corner = 3 * face;
                const first_vert = try ct.addNewVertex();
                ct.mapCornerToVertex(corner, first_vert);
                ct.mapCornerToVertex(corner + 1, try ct.addNewVertex());
                ct.mapCornerToVertex(corner + 2, try ct.addNewVertex());
                if (ct.numVertices() > max_num_vertices) return Error.Corrupt;
                ct.setLeftMostCorner(first_vert, corner);
                ct.setLeftMostCorner(first_vert + 1, corner + 1);
                ct.setLeftMostCorner(first_vert + 2, corner + 2);
                try active_stack.append(alloc, corner);
                check_topology_split = true;
            },
        }
        // NewActiveCornerReached is a no-op for the STANDARD decoder.

        if (check_topology_split) {
            const encoder_symbol_id: i64 = num_symbols - @as(i64, symbol_id) - 1;
            var split_edge: u1 = 0;
            var encoder_split_symbol_id: i64 = 0;
            while (isTopologySplit(events.topology_splits, &split_count, encoder_symbol_id, &split_edge, &encoder_split_symbol_id)) {
                if (encoder_split_symbol_id < 0) return Error.Corrupt;
                const act_top = active_stack.items[active_stack.items.len - 1];
                const new_active = if (split_edge == RIGHT_FACE_EDGE) cNext(act_top) else cPrev(act_top);
                const decoder_split_symbol_id = num_symbols - encoder_split_symbol_id - 1;
                if (decoder_split_symbol_id < 0 or decoder_split_symbol_id >= num_symbols) return Error.Corrupt;
                split_corners[@intCast(decoder_split_symbol_id)] = new_active;
            }
        }
    }
    if (ct.numVertices() > max_num_vertices) return Error.Corrupt;

    // Decode start faces and connect them to the faces from the active stack.
    while (active_stack.items.len != 0) {
        const corner = active_stack.pop().?;
        const interior_face = td.decodeStartFaceConfiguration();
        if (interior_face) {
            if (num_faces >= ct.numFaces()) return Error.Corrupt;
            const corner_a = corner;
            const vert_n = try reqVertex(ct.vertex(cNext(corner_a)), ct.numVertices());
            const corner_b = cNext(try reqCorner(&ct, ct.leftMostCorner(vert_n)));
            const vert_x = try reqVertex(ct.vertex(cNext(corner_b)), ct.numVertices());
            const corner_c = cNext(try reqCorner(&ct, ct.leftMostCorner(vert_x)));
            if (corner == corner_b or corner == corner_c or corner_b == corner_c) return Error.Corrupt;
            if (ct.opposite(corner) != kInvalidCorner or ct.opposite(corner_b) != kInvalidCorner or ct.opposite(corner_c) != kInvalidCorner) return Error.Corrupt;

            const vert_p = ct.vertex(cNext(corner_c));

            const face2 = num_faces;
            num_faces += 1;
            const new_corner = 3 * face2;
            setOppositeCorners(&ct, new_corner, corner);
            setOppositeCorners(&ct, new_corner + 1, corner_b);
            setOppositeCorners(&ct, new_corner + 2, corner_c);
            ct.mapCornerToVertex(new_corner, vert_x);
            ct.mapCornerToVertex(new_corner + 1, vert_p);
            ct.mapCornerToVertex(new_corner + 2, vert_n);
            var ci: u32 = 0;
            while (ci < 3) : (ci += 1) {
                is_vert_hole[try reqVertex(ct.vertex(new_corner + ci), ct.numVertices())] = false;
            }
        }
        // Non-interior start faces add no face — only a boundary record we omit.
    }
    if (num_faces != ct.numFaces()) return Error.Corrupt;

    // Remove vertices that were marked as isolated by split symbols so that all
    // ids in <0, num_vertices) are valid. Safe here because attribute_data is
    // empty (num_attribute_data == 0).
    var num_vertices = ct.numVertices();
    for (invalid_vertices.items) |invalid_vert| {
        if (num_vertices == 0) return Error.Corrupt;
        var src_vert = num_vertices - 1;
        while (ct.leftMostCorner(src_vert) == kInvalidCorner) {
            if (num_vertices == 0) return Error.Corrupt;
            num_vertices -= 1;
            if (num_vertices == 0) return Error.Corrupt;
            src_vert = num_vertices - 1;
        }
        if (src_vert < invalid_vert) continue;

        var it = VertexCornersIter.init(&ct, src_vert);
        while (!it.end()) : (it.advance()) {
            const cid = try reqCorner(&ct, it.corner);
            if (ct.vertex(cid) != src_vert) return Error.Corrupt;
            ct.mapCornerToVertex(cid, invalid_vert);
        }
        ct.setLeftMostCorner(invalid_vert, ct.leftMostCorner(src_vert));
        ct.makeVertexIsolated(src_vert);
        is_vert_hole[invalid_vert] = is_vert_hole[src_vert];
        is_vert_hole[src_vert] = false;
        num_vertices -= 1;
    }

    // Position-only face extraction: point id == vertex id (AssignPointsToCorners).
    const indices = try alloc.alloc(u32, ct.numFaces() * 3);
    errdefer alloc.free(indices);
    var fi: u32 = 0;
    while (fi < ct.numFaces()) : (fi += 1) {
        const start_corner = 3 * fi;
        var c: u32 = 0;
        while (c < 3) : (c += 1) {
            indices[start_corner + c] = ct.vertex(start_corner + c);
        }
    }

    return .{ .alloc = alloc, .indices = indices, .corner_table = ct, .num_points = num_vertices };
}

/// `MeshEdgebreakerDecoderImpl::SetOppositeCorners` — set both directions.
fn setOppositeCorners(ct: *CornerTable, c0: u32, c1: u32) void {
    ct.setOpposite(c0, c1);
    ct.setOpposite(c1, c0);
}

test "decodeConnectivity(quad.drc) → exact indices [0,1,2,1,3,2]" {
    const quad_drc = @import("draco_fixtures").quad_drc;
    const a = std.testing.allocator;
    var buf = draco.DecoderBuffer.init(quad_drc);
    _ = try draco.parseHeader(&buf);
    var conn = try decodeConnectivity(a, &buf);
    defer conn.deinit();
    try std.testing.expectEqualSlices(u32, &[_]u32{ 0, 1, 2, 1, 3, 2 }, conn.indices);
    try std.testing.expectEqual(@as(u32, 4), conn.num_points);
}

test "parse quad.drc connectivity header: STANDARD, 4 verts, 2 faces, 0 attr-data" {
    const quad_drc = @import("draco_fixtures").quad_drc;
    var buf = draco.DecoderBuffer.init(quad_drc);
    _ = try draco.parseHeader(&buf); // consume the 11-byte file header (+ no metadata)
    const st = try beginConnectivity(&buf); // reads base preamble + traversal byte
    try std.testing.expectEqual(@as(u8, 0), st.traversal_type); // STANDARD
    const h = try parseConnHeader(&buf);
    try std.testing.expectEqual(@as(u32, 4), h.num_encoded_vertices);
    try std.testing.expectEqual(@as(u32, 2), h.num_faces);
    try std.testing.expectEqual(@as(u8, 0), h.num_attribute_data);
    try std.testing.expectEqual(@as(u32, 2), h.num_encoded_symbols);
    try std.testing.expectEqual(@as(u32, 0), h.num_encoded_split_symbols);

    var events = try decodeEvents(std.testing.allocator, &buf, h);
    defer events.deinit();
    try std.testing.expectEqual(@as(usize, 0), events.topology_splits.len);
    try std.testing.expectEqual(@as(usize, 0), events.holes.len);
}

/// Absolute byte offset of the traversal-type byte into `quad.drc`: 11 bytes
/// of file header (5 magic + major + minor + etype + method + u16 flags),
/// no metadata section (flags == 0) — confirmed against source (see module
/// doc comment) and pinned by the hex dump of the committed fixture.
const TRAVERSAL_OFF: usize = 11;

test "reject VALENCE traversal + attribute-data>0" {
    const quad_drc = @import("draco_fixtures").quad_drc;
    var patched = quad_drc.*; // *const [N:0]u8 -> mutable array copy
    patched[TRAVERSAL_OFF] = 2; // MESH_EDGEBREAKER_VALENCE_ENCODING
    var buf = draco.DecoderBuffer.init(&patched);
    _ = try draco.parseHeader(&buf);
    try std.testing.expectError(draco.Error.UnsupportedDracoFeature, beginConnectivity(&buf));
}

test "decodeEvents: synthetic stream with 2 topology splits" {
    const a = std.testing.allocator;
    // source ids (absolute): 5, 9 -> deltas from 0: 5, then 4.
    // split ids: source0 - 2 = 3; source1 - 1 = 8.
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(a);
    try bytes.append(a, 2); // num_topology_splits = 2 (varint, fits in 1 byte)
    try bytes.append(a, 5); // delta -> source_symbol_id = 5
    try bytes.append(a, 2); // split delta -> split_symbol_id = 3
    try bytes.append(a, 4); // delta -> source_symbol_id = 9
    try bytes.append(a, 1); // split delta -> split_symbol_id = 8
    // edge bits: 2 splits -> 1 byte, LSB-first: split0 edge=1, split1 edge=0 -> 0b01
    try bytes.append(a, 0b01);

    var buf = DecoderBuffer.init(bytes.items);
    const hdr = ConnHeader{
        .num_new_verts = 0,
        .num_encoded_vertices = 10,
        .num_faces = 20, // must be >= num_topology_splits
        .num_attribute_data = 0,
        .num_encoded_symbols = 10,
        .num_encoded_split_symbols = 2,
    };
    var events = try decodeEvents(a, &buf, hdr);
    defer events.deinit();
    try std.testing.expectEqual(@as(usize, 2), events.topology_splits.len);
    try std.testing.expectEqual(@as(u32, 5), events.topology_splits[0].source_symbol_id);
    try std.testing.expectEqual(@as(u32, 3), events.topology_splits[0].split_symbol_id);
    try std.testing.expectEqual(@as(u1, 1), events.topology_splits[0].source_edge);
    try std.testing.expectEqual(@as(u32, 9), events.topology_splits[1].source_symbol_id);
    try std.testing.expectEqual(@as(u32, 8), events.topology_splits[1].split_symbol_id);
    try std.testing.expectEqual(@as(u1, 0), events.topology_splits[1].source_edge);
}

const cube_drc = @import("draco_fixtures").cube_drc;

test "decodeConnectivity(cube.drc) → exact cube indices" {
    const a = std.testing.allocator;
    var buf = draco.DecoderBuffer.init(cube_drc);
    _ = try draco.parseHeader(&buf);
    var conn = try decodeConnectivity(a, &buf);
    defer conn.deinit();
    const want = [_]u32{ 0, 1, 2, 2, 1, 3, 3, 1, 4, 1, 0, 4, 0, 5, 4, 4, 5, 6, 5, 0, 6, 0, 2, 6, 6, 2, 7, 2, 3, 7, 3, 4, 7, 6, 7, 4 };
    try std.testing.expectEqualSlices(u32, &want, conn.indices);
    try std.testing.expectEqual(@as(u32, 8), conn.num_points);
}

/// Absolute byte offset of `num_attribute_data` in `quad.drc`: 11 bytes of
/// file header + 1 traversal-type byte + 2 varint bytes
/// (num_encoded_vertices=4, num_faces=2, each a single-byte varint) = 14.
/// Pinned by `parse quad.drc connectivity header` above, which asserts
/// `num_encoded_vertices == 4` and `num_faces == 2` decode from exactly those
/// two single bytes.
const ATTR_DATA_OFF: usize = 14;

test "reject num_attribute_data > 0" {
    // Patch a copy of quad.drc's num_attribute_data byte to 1.
    const quad_drc = @import("draco_fixtures").quad_drc;
    const a = std.testing.allocator;
    const copy = try a.dupe(u8, quad_drc);
    defer a.free(copy);
    try std.testing.expectEqual(@as(u8, 0), copy[ATTR_DATA_OFF]);
    copy[ATTR_DATA_OFF] = 1;
    var buf = draco.DecoderBuffer.init(copy);
    _ = try draco.parseHeader(&buf);
    try std.testing.expectError(draco.Error.UnsupportedDracoFeature, decodeConnectivity(a, &buf));
}

// ── torus: genus-1, exercises the TOPOLOGY_S / topology-split path ─────────
// quad.drc and cube.drc both decode with 0 topology splits (genus-0 meshes),
// leaving the hardest part of the traversal loop (the `.s` symbol arm +
// `isTopologySplit` re-injection) completely unexercised by those goldens.
// torus.drc (12x8 parametric torus, R=2 r=0.7 — see `tools/dev/draco_gen.mjs`)
// is genus-1 and its real encoded stream carries 8 split symbols / 2
// topology-split events (confirmed below), so this golden proves the split
// path decodes byte-exact against the reference decoder.
const torus_drc = @import("draco_fixtures").torus_drc;

test "decodeConnectivity(torus.drc) → exact torus indices, exercises topology splits" {
    const a = std.testing.allocator;

    // First prove the fixture actually carries split symbols (else this
    // fixture wouldn't be exercising anything new).
    var hdr_buf = draco.DecoderBuffer.init(torus_drc);
    _ = try draco.parseHeader(&hdr_buf);
    _ = try beginConnectivity(&hdr_buf);
    const h = try parseConnHeader(&hdr_buf);
    try std.testing.expectEqual(@as(u32, 8), h.num_encoded_split_symbols);
    try std.testing.expect(h.num_encoded_split_symbols > 0);
    var events = try decodeEvents(a, &hdr_buf, h);
    defer events.deinit();
    try std.testing.expectEqual(@as(usize, 2), events.topology_splits.len);

    var buf = draco.DecoderBuffer.init(torus_drc);
    _ = try draco.parseHeader(&buf);
    var conn = try decodeConnectivity(a, &buf);
    defer conn.deinit();
    const want = [_]u32{
        0,  1,  2,  3,  2,  5,  2,  1,  5,  5,  1,  6,  7,  6,  9,  6,  1,  9,
        9,  1,  10, 1,  0,  10, 10, 0,  11, 12, 11, 14, 11, 0,  14, 14, 0,  15,
        0,  2,  15, 15, 2,  16, 2,  3,  16, 16, 3,  17, 17, 3,  18, 18, 3,  19,
        3,  5,  19, 19, 5,  20, 5,  6,  20, 20, 6,  21, 6,  7,  21, 21, 7,  22,
        7,  23, 22, 22, 23, 24, 23, 25, 24, 24, 25, 26, 25, 27, 26, 26, 27, 28,
        27, 17, 28, 17, 18, 28, 28, 18, 30, 30, 18, 31, 18, 19, 31, 31, 19, 32,
        19, 20, 32, 32, 20, 33, 20, 21, 33, 33, 21, 34, 21, 22, 34, 34, 22, 35,
        22, 24, 35, 35, 24, 36, 24, 26, 36, 36, 26, 37, 26, 28, 37, 28, 30, 37,
        37, 30, 38, 39, 38, 41, 38, 30, 41, 30, 31, 41, 41, 31, 42, 31, 32, 42,
        42, 32, 43, 32, 33, 43, 43, 33, 44, 33, 34, 44, 44, 34, 45, 34, 35, 45,
        45, 35, 46, 35, 36, 46, 46, 36, 47, 36, 37, 47, 37, 38, 47, 47, 38, 48,
        38, 39, 48, 48, 39, 49, 50, 49, 52, 49, 39, 52, 52, 39, 53, 39, 41, 53,
        41, 42, 53, 53, 42, 54, 42, 43, 54, 54, 43, 55, 43, 44, 55, 55, 44, 56,
        44, 45, 56, 56, 45, 57, 45, 46, 57, 57, 46, 58, 46, 47, 58, 47, 48, 58,
        58, 48, 59, 48, 49, 59, 59, 49, 60, 49, 50, 60, 60, 50, 61, 12, 61, 64,
        61, 50, 64, 64, 50, 65, 50, 52, 65, 65, 52, 66, 52, 53, 66, 53, 54, 66,
        66, 54, 67, 54, 55, 67, 67, 55, 68, 55, 56, 68, 68, 56, 69, 56, 57, 69,
        69, 57, 70, 57, 58, 70, 58, 59, 70, 70, 59, 71, 59, 60, 71, 71, 60, 72,
        60, 61, 72, 72, 61, 73, 61, 12, 73, 12, 14, 73, 73, 14, 74, 14, 15, 74,
        74, 15, 75, 15, 16, 75, 75, 16, 76, 16, 17, 76, 17, 27, 76, 76, 27, 77,
        27, 25, 77, 77, 25, 78, 25, 23, 78, 78, 23, 79, 23, 7,  79, 7,  9,  79,
        79, 9,  80, 9,  10, 80, 80, 10, 81, 10, 11, 81, 81, 11, 82, 11, 12, 82,
        12, 64, 82, 82, 64, 83, 64, 65, 83, 83, 65, 84, 65, 66, 84, 66, 67, 84,
        84, 67, 85, 67, 68, 85, 85, 68, 86, 68, 69, 86, 86, 69, 87, 69, 70, 87,
        70, 71, 87, 87, 71, 88, 71, 72, 88, 88, 72, 89, 72, 73, 89, 73, 74, 89,
        89, 74, 90, 74, 75, 90, 90, 75, 91, 75, 76, 91, 76, 77, 91, 91, 77, 92,
        77, 78, 92, 92, 78, 93, 78, 79, 93, 79, 80, 93, 93, 80, 94, 80, 81, 94,
        94, 81, 95, 81, 82, 95, 82, 83, 95, 95, 83, 62, 83, 84, 62, 84, 85, 62,
        62, 85, 63, 85, 86, 63, 63, 86, 51, 86, 87, 51, 87, 88, 51, 51, 88, 40,
        88, 89, 40, 89, 90, 40, 40, 90, 29, 90, 91, 29, 91, 92, 29, 29, 92, 13,
        92, 93, 13, 93, 94, 13, 13, 94, 8,  94, 95, 8,  95, 62, 8,  62, 63, 8,
        8,  63, 4,  63, 51, 4,  51, 40, 4,  40, 29, 4,  29, 13, 4,  8,  4,  13,
    };
    try std.testing.expectEqualSlices(u32, &want, conn.indices);
    try std.testing.expectEqual(@as(u32, 96), conn.num_points);
}

test "decodeEvents rejects num_topology_splits > num_faces" {
    const a = std.testing.allocator;
    const bytes = [_]u8{1}; // num_topology_splits = 1
    var buf = DecoderBuffer.init(&bytes);
    const hdr = ConnHeader{
        .num_new_verts = 0,
        .num_encoded_vertices = 0,
        .num_faces = 0, // 1 > 0 -> Corrupt
        .num_attribute_data = 0,
        .num_encoded_symbols = 0,
        .num_encoded_split_symbols = 0,
    };
    try std.testing.expectError(Error.Corrupt, decodeEvents(a, &buf, hdr));
}
