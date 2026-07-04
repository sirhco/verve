const std = @import("std");
const draco = @import("draco.zig");
const DecoderBuffer = draco.DecoderBuffer;
pub const Error = draco.Error;

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
