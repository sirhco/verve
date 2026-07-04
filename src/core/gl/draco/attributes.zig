//! Attribute-section header parse — faithful port of the Draco call chain
//! that runs immediately after `MeshEdgebreakerDecoderImpl::DecodeConnectivity`
//! (Slice B's `decodeConnectivity`), up to (but not including) the actual
//! reconstruction of attribute values:
//!
//!   `PointCloudDecoder::DecodePointAttributes`                  (point_cloud_decoder.cc)
//!     -> `MeshEdgebreakerDecoderImpl::CreateAttributesDecoder`   (mesh_edgebreaker_decoder_impl.cc ~L129)
//!     -> `AttributesDecoder::DecodeAttributesDecoderData`        (attributes_decoder.cc)
//!     -> `SequentialAttributeDecodersController::DecodeAttributesDecoderData` (sequential_attribute_decoders_controller.cc, adds the per-attribute sequential-encoder-type byte)
//!     -> `AttributesDecoder::DecodeAttributes`                   (attributes_decoder.h, inline)
//!        -> `DecodePortableAttributes` -> `SequentialAttributeDecoder::DecodePortableAttribute`
//!           -> `SequentialIntegerAttributeDecoder::DecodeValues` (prediction_scheme_method/transform_type)
//!              -> `SequentialIntegerAttributeDecoder::DecodeIntegerValues` (compressed-flag + the value blob itself)
//!              -> `PredictionSchemeDecoder::DecodePredictionData` -> `PredictionSchemeWrapDecodingTransform::DecodeTransformData` (WRAP clamp bounds, 2x int32)
//!        -> `DecodeDataNeededByPortableTransforms` -> `SequentialQuantizationAttributeDecoder::DecodeQuantizedDataInfo` -> `attr_quant.parseQuantParams`
//!
//! ★ Key ordering fact (NOT obvious from a casual read of the quant-decoder
//! alone): the quantization parameters (`attr_quant.QuantParams`) are encoded
//! *after* the attribute's value blob and the WRAP-transform clamp bounds,
//! not immediately after the attribute descriptor. `AttributesDecoder::DecodeAttributes`
//! runs `DecodePortableAttributes` (which decodes prediction metadata + the
//! actual compressed/raw value blob + the WRAP min/max) fully *before*
//! `DecodeDataNeededByPortableTransforms` (which is where the quantization
//! decoder finally reads its min/range/bits). So reaching the quant params
//! byte-exactly requires walking (not reinterpreting) past the value blob —
//! this module reuses the already-shipped, already-tested `draco.decodeSymbols`
//! (Slice A) to do that walk for the compressed path; it does not add new
//! value-reconstruction semantics (sign conversion / WRAP unwrap / parallelogram
//! prediction / dequantization all remain Tasks 2-4).
const std = @import("std");
const draco = @import("draco.zig");
const DecoderBuffer = draco.DecoderBuffer;
pub const Error = draco.Error;

const attr_quant = @import("attr_quant.zig");
pub const QuantParams = attr_quant.QuantParams;
const edgebreaker = @import("edgebreaker.zig");
const Connectivity = edgebreaker.Connectivity;

/// `SequentialAttributeEncoderType` (compression_shared.h): `QUANTIZATION == 2`
/// is the only encoder this port accepts (`GENERIC=0`/`INTEGER=1`/`NORMALS=3`
/// are rejected below).
pub const seq_encoder_quantization: u8 = 2;

/// `PredictionSchemeMethod` (compression_shared.h). `NONE`/`UNDEFINED` and the
/// normal/tex-coord-specific methods (3/5/6) are intentionally excluded from
/// this port's accepted set — see `parseAttrHeader`'s reject comment.
pub const prediction_difference: i8 = 0;
pub const prediction_parallelogram: i8 = 1;
pub const prediction_multi_parallelogram: i8 = 2;
pub const prediction_constrained_multi_parallelogram: i8 = 4;

/// `PredictionSchemeTransformType` (compression_shared.h): `WRAP == 1`.
pub const transform_wrap: i8 = 1;

/// Result of the attribute-section header parse. Tasks 3-4 reuse this shape
/// verbatim — `min`/`range`/`bits` (via `quant`) are exactly what the
/// dequantization step needs; `scheme_method`/`transform_type` are exactly
/// what selecting + running the prediction-scheme inverse needs.
pub const DecodedAttrHeader = struct {
    scheme_method: i8,
    transform_type: i8,
    quant: QuantParams,
    num_components: u8,
    /// `MeshTraversalMethod` byte (`DEPTH_FIRST == 0`, `PREDICTION_DEGREE == 1`).
    /// The attribute-value decode order (and thus the prediction-scheme inverse
    /// in `predict_mesh.zig`) depends on which traversal generated the sequence,
    /// so Task 3 needs it verbatim.
    traversal_method: u8,
    /// WRAP-transform clamp bounds (`PredictionSchemeWrapDecodingTransform::
    /// DecodeTransformData`). `predict_mesh.wrapInverse` unwraps the corrected
    /// value into `[wrap_min, wrap_max]`.
    wrap_min: i32,
    wrap_max: i32,
};

/// Port of the header-parse chain documented in the module doc comment.
/// `buf` must be positioned right after `decodeConnectivity` (the start of
/// the attribute section). `conn` supplies `num_points` (== `point_ids.size()`
/// in the C++ — the sequencer's generated sequence has exactly one entry per
/// decoded point for our position-only, attribute-data-free connectivity) and
/// the allocator used for `decodeSymbols`' scratch decode table.
///
/// REJECTS (`Error.UnsupportedDracoFeature`) anything outside this port's
/// scope: more than one attributes decoder, a non-QUANTIZATION sequential
/// encoder, a non-WRAP prediction transform, or a prediction-scheme method
/// outside `{DIFFERENCE, PARALLELOGRAM, MULTI_PARALLELOGRAM, CONSTRAINED_MULTI_PARALLELOGRAM}`.
pub fn parseAttrHeader(buf: *DecoderBuffer, conn: *const Connectivity) Error!DecodedAttrHeader {
    const section = try parseAttrSection(conn.alloc, buf, conn);
    conn.alloc.free(section.residuals);
    return section.header;
}

/// Draco `ConvertSymbolToSignedInt` (`core/symbol_decoding.h`), the per-value
/// portable/zigzag inverse `SequentialIntegerAttributeDecoder::DecodeIntegerValues`
/// applies (`ConvertSymbolsToSignedInts`) after entropy-decoding the blob and
/// before running the prediction inverse: `is = symbol >> 1; if (symbol & 1) is
/// = -is - 1`. `symbol >> 1` always clears the top bit so the `@bitCast` is a
/// non-negative `i32`; wrapping negation keeps `symbol == UINT32_MAX` (→ exactly
/// `i32` min) from panicking.
fn symbolToSignedInt(sym: u32) i32 {
    const half: i32 = @bitCast(sym >> 1);
    if (sym & 1 == 0) return half;
    return -%half -% 1;
}

/// `parseAttrHeader`'s result plus the decoded, signed residual corrections. The
/// two are produced in one pass because Draco interleaves them: the value blob
/// is entropy-decoded in the *middle* of the attribute section — after the
/// prediction metadata, before the WRAP clamp bounds and the quantization params
/// (see `SequentialIntegerAttributeDecoder::DecodeIntegerValues`). `residuals`
/// is owned by the allocator passed to `parseAttrSection`; its length is
/// `num_points * num_components`, in data-entry (encoding) order.
const AttrSection = struct {
    header: DecodedAttrHeader,
    residuals: []i32,
};

/// Full attribute-section walk (see the module doc comment for the C++ chain),
/// capturing the signed residual corrections instead of discarding them.
/// `parseAttrHeader` wraps this and frees `residuals`; `decodeAttributes`
/// consumes them for the prediction inverse.
fn parseAttrSection(alloc: std.mem.Allocator, buf: *DecoderBuffer, conn: *const Connectivity) Error!AttrSection {
    // `PointCloudDecoder::DecodePointAttributes`.
    const num_attributes_decoders = try buf.readInt(u8);
    if (num_attributes_decoders != 1) return Error.UnsupportedDracoFeature;

    // `MeshEdgebreakerDecoderImpl::CreateAttributesDecoder`. `att_data_id < 0`
    // is the position-attribute case (no per-attribute connectivity data —
    // Slice B already rejected `num_attribute_data != 0`, so this is the only
    // case our connectivity port can ever hand back). `decoder_type` (vertex
    // vs. corner attribute) and `traversal_method` (bitstream >= 1.2, always
    // true for our 2.2-only port) are read but not further validated: neither
    // is on this task's reject list, and every valid combination reads the
    // same 2 bytes here regardless of value.
    _ = try buf.readInt(i8); // att_data_id
    _ = try buf.readInt(u8); // decoder_type (MESH_VERTEX_ATTRIBUTE / MESH_CORNER_ATTRIBUTE)
    const traversal_method = try buf.readInt(u8); // MeshTraversalMethod (DEPTH_FIRST/PREDICTION_DEGREE)

    // `AttributesDecoder::DecodeAttributesDecoderData`. Only the first (and,
    // per this task's scope, only) attribute descriptor is kept.
    const num_attributes = try buf.decodeVarint(u32);
    if (num_attributes != 1) return Error.UnsupportedDracoFeature;

    const att_type = try buf.readInt(u8); // att_type (GeometryAttribute::Type)
    _ = try buf.readInt(u8); // data_type
    const num_components = try buf.readInt(u8);
    _ = try buf.readInt(u8); // normalized
    _ = try buf.decodeVarint(u32); // unique_id

    // Validate attribute type and component count before quantization parse.
    // `att_type == 0` is POSITION (the only geometry attribute type this port
    // accepts), and `num_components == 3` is required by `attr_quant.parseQuantParams`.
    if (att_type != 0) return Error.UnsupportedDracoFeature;
    if (num_components != 3) return Error.UnsupportedDracoFeature;

    // `SequentialAttributeDecodersController::DecodeAttributesDecoderData`'s
    // addition: one sequential-encoder-type byte per attribute.
    const seq_encoder_type = try buf.readInt(u8);
    if (seq_encoder_type != seq_encoder_quantization) return Error.UnsupportedDracoFeature;

    // `SequentialIntegerAttributeDecoder::DecodeValues`: prediction metadata.
    const scheme_method = try buf.readInt(i8);
    switch (scheme_method) {
        prediction_difference, prediction_parallelogram, prediction_multi_parallelogram, prediction_constrained_multi_parallelogram => {},
        else => return Error.UnsupportedDracoFeature,
    }
    // Real Draco only reads `transform_type` when `scheme_method !=
    // PREDICTION_NONE`; every method this port accepts is `!= PREDICTION_NONE`
    // (`-2`), so the byte is unconditionally present here.
    const transform_type = try buf.readInt(i8);
    if (transform_type != transform_wrap) return Error.UnsupportedDracoFeature;

    // `SequentialIntegerAttributeDecoder::DecodeIntegerValues`: the value blob
    // itself. This port does not interpret the values (Tasks 2-4 own that) —
    // it only needs to land `buf.pos` exactly where the real decoder would.
    const num_values: usize = @as(usize, conn.num_points) * @as(usize, num_components);
    const residuals = try alloc.alloc(i32, num_values);
    errdefer alloc.free(residuals);
    const compressed = try buf.readInt(u8);
    if (compressed > 0) {
        // `DecodeSymbols(num_values, num_components, in_buffer, out)` — Slice A's
        // rANS/raw symbol decoder. The decoded unsigned symbols become the signed
        // residual corrections via `ConvertSymbolsToSignedInts` (WRAP corrections
        // are not positive-only, so the conversion always runs for this port).
        const scratch = try alloc.alloc(u32, num_values);
        defer alloc.free(scratch);
        try draco.decodeSymbols(alloc, buf, num_values, num_components, scratch);
        for (scratch, 0..) |s, i| residuals[i] = symbolToSignedInt(s);
    } else {
        // Direct (uncompressed) path: `num_bytes` little-endian bytes per scalar
        // value, each an unsigned symbol converted the same way. No committed
        // fixture exercises this path, but it costs nothing to decode faithfully.
        const num_bytes = try buf.readInt(u8);
        if (num_bytes == 0 or num_bytes > 4) return Error.UnsupportedDracoFeature;
        var i: usize = 0;
        while (i < num_values) : (i += 1) {
            var sym: u32 = 0;
            var b: usize = 0;
            while (b < num_bytes) : (b += 1) {
                const byte = try buf.readInt(u8);
                sym |= @as(u32, byte) << @intCast(b * 8);
            }
            residuals[i] = symbolToSignedInt(sym);
        }
    }

    // If `scheme_method` needed a prediction scheme (always true for the
    // methods this port accepts), `PredictionSchemeXxxDecoder::DecodePredictionData`
    // runs next. Only `CONSTRAINED_MULTI_PARALLELOGRAM` overrides this with
    // extra data (per-context crease-edge flags, each its own
    // `RAnsBitDecoder`-backed bit region keyed by a varint flag count, up to
    // `kMaxNumParallelograms` contexts) read *before* the generic
    // WRAP-transform clamp bounds; `DIFFERENCE`/`PARALLELOGRAM`/`MULTI_PARALLELOGRAM`
    // go straight to the generic step.
    //
    // ★ NOT PORTED: no fixture in this repo exercises `scheme_method == 4`
    // (quad/cube/torus.drc all pin `PARALLELOGRAM == 1` — see the golden test
    // below), so the extra crease-edge decode has no real bitstream to verify
    // byte-exactness against. Rejecting rather than guessing keeps this port's
    // "never silently misdecode" posture; add the extra decode (mirroring
    // `MeshPredictionSchemeConstrainedMultiParallelogramDecoder::DecodePredictionData`)
    // once a fixture that actually encodes with this scheme exists.
    if (scheme_method == prediction_constrained_multi_parallelogram) return Error.UnsupportedDracoFeature;

    // Generic path (`DIFFERENCE` / `PARALLELOGRAM` / `MULTI_PARALLELOGRAM`):
    // `PredictionSchemeDecoder::DecodePredictionData` ->
    // `PredictionSchemeWrapDecodingTransform::DecodeTransformData` — the WRAP
    // clamp bounds, 2x `int32_t` (`DataTypeT` for a position attribute is
    // always `int32_t` post-quantization). Consumed only to advance `buf`;
    // Tasks 3-4 own re-deriving/using these for the actual unwrap.
    const wrap_min = try buf.readInt(i32);
    const wrap_max = try buf.readInt(i32);
    if (wrap_min > wrap_max) return Error.Corrupt;

    // `SequentialQuantizationAttributeDecoder::DecodeQuantizedDataInfo`.
    const quant = try attr_quant.parseQuantParams(buf);

    return .{
        .header = .{ .scheme_method = scheme_method, .transform_type = transform_type, .quant = quant, .num_components = num_components, .traversal_method = traversal_method, .wrap_min = wrap_min, .wrap_max = wrap_max },
        .residuals = residuals,
    };
}

/// Decoded POSITION values, `num_points * 3` `f32`s in per-point order (lines up
/// 1:1 with `Connectivity.indices`). Caller must `deinit`.
pub const PositionData = struct {
    values: []f32,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *PositionData) void {
        self.alloc.free(self.values);
        self.values = &.{};
    }
};

/// End-to-end POSITION decode: header + residual entropy stream (`parseAttrSection`)
/// → prediction inverse (`predict_mesh.inversePredict`, per-point quantized ints)
/// → dequantization (`attr_quant.dequantize`). `buf` must be positioned right
/// after `decodeConnectivity`. Returns owned `PositionData` (`values.len ==
/// num_points * 3`, decoded-vertex order). Never panics on malformed input —
/// bounds/consistency violations map to `draco.Error`.
pub fn decodeAttributes(alloc: std.mem.Allocator, buf: *DecoderBuffer, conn: *const Connectivity) Error!PositionData {
    const section = try parseAttrSection(alloc, buf, conn);
    defer alloc.free(section.residuals);
    const h = section.header;
    const nc: usize = h.num_components;

    const q = try draco.inversePredict(alloc, h, section.residuals, h.num_components, conn);
    defer alloc.free(q);

    const values = try alloc.alloc(f32, q.len);
    errdefer alloc.free(values);
    for (q, 0..) |qi, i| {
        // Post-WRAP quantized values are clamped into `[wrap_min, wrap_max]`,
        // which for a quantized position is `[0, (1<<bits)-1]` — always
        // non-negative. Guard rather than `@intCast`-panic on a corrupt stream.
        if (qi < 0) return Error.Corrupt;
        values[i] = attr_quant.dequantize(@intCast(qi), i % nc, h.quant);
    }
    return .{ .values = values, .alloc = alloc };
}

test "parseAttrHeader(quad.drc): QUANTIZATION, 3 components, WRAP transform" {
    const a = std.testing.allocator;
    const quad_drc = @import("draco_fixtures").quad_drc;
    var buf = DecoderBuffer.init(quad_drc);
    _ = try draco.parseHeader(&buf);
    var conn = try draco.decodeConnectivity(a, &buf);
    defer conn.deinit();
    const h = try parseAttrHeader(&buf, &conn);
    try std.testing.expectEqual(@as(u8, 3), h.num_components);
    try std.testing.expectEqual(@as(i8, 1), h.transform_type); // WRAP
    // scheme_method is one of {0,1,2,4}; assert it parsed into that set.
    try std.testing.expect(h.scheme_method == 0 or h.scheme_method == 1 or h.scheme_method == 2 or h.scheme_method == 4);
    try std.testing.expect(h.quant.bits > 0 and h.quant.bits <= 30);
}

test "decodeAttributes(quad.drc) → POSITION [0,1,0, 0,0,0, 1,1,0, 1,0,0]" {
    const a = std.testing.allocator;
    const quad_drc = @import("draco_fixtures").quad_drc;
    var buf = DecoderBuffer.init(quad_drc);
    _ = try draco.parseHeader(&buf);
    var conn = try draco.decodeConnectivity(a, &buf);
    defer conn.deinit();
    var pos = try decodeAttributes(a, &buf, &conn);
    defer pos.deinit();
    const want = [_]f32{ 0, 1, 0, 0, 0, 0, 1, 1, 0, 1, 0, 0 };
    try std.testing.expectEqualSlices(f32, &want, pos.values);
}

test "parseAttrHeader rejects num_components != 3" {
    const a = std.testing.allocator;
    // Minimal header with num_components=2 (invalid): should reject before quant parse.
    const minimal_buf_bytes = [_]u8{
        1, // num_attributes_decoders
        0xFF, // att_data_id (-1 as i8)
        0, // decoder_type
        0, // traversal_method_encoded
        1, // num_attributes (varint)
        0, // att_type (POSITION)
        0, // data_type
        2, // num_components (INVALID — not 3)
        0, // normalized
        0, // unique_id (varint)
        2, // seq_encoder_type (QUANTIZATION)
        0, // scheme_method
        1, // transform_type (WRAP)
    };

    // Create a minimal connectivity to pass the conn parameter.
    // parseAttrHeader rejects num_components before using conn.
    const empty_indices = try a.alloc(u32, 0);
    defer a.free(empty_indices);
    const empty_opposite = try a.alloc(u32, 0);
    defer a.free(empty_opposite);
    const empty_corner_to_vertex = try a.alloc(u32, 0);
    defer a.free(empty_corner_to_vertex);
    const vertex_corners = std.ArrayList(u32).empty;

    var conn = Connectivity{
        .num_points = 0,
        .alloc = a,
        .indices = empty_indices,
        .corner_table = .{
            .alloc = a,
            .opposite_corners = empty_opposite,
            .corner_to_vertex = empty_corner_to_vertex,
            .vertex_corners = vertex_corners,
            .num_faces_ = 0,
        },
    };

    var buf = DecoderBuffer.init(&minimal_buf_bytes);
    const result = parseAttrHeader(&buf, &conn);
    try std.testing.expectError(Error.UnsupportedDracoFeature, result);
}

test "parseAttrHeader rejects att_type != POSITION" {
    const a = std.testing.allocator;
    // Header with att_type=1 (not POSITION): should reject.
    const minimal_buf_bytes = [_]u8{
        1, // num_attributes_decoders
        0xFF, // att_data_id (-1 as i8)
        0, // decoder_type
        0, // traversal_method_encoded
        1, // num_attributes (varint)
        1, // att_type (NOT POSITION — invalid)
        0, // data_type
        3, // num_components
        0, // normalized
        0, // unique_id (varint)
        2, // seq_encoder_type (QUANTIZATION)
        0, // scheme_method
        1, // transform_type (WRAP)
    };

    const empty_indices = try a.alloc(u32, 0);
    defer a.free(empty_indices);
    const empty_opposite = try a.alloc(u32, 0);
    defer a.free(empty_opposite);
    const empty_corner_to_vertex = try a.alloc(u32, 0);
    defer a.free(empty_corner_to_vertex);
    const vertex_corners = std.ArrayList(u32).empty;

    var conn = Connectivity{
        .num_points = 0,
        .alloc = a,
        .indices = empty_indices,
        .corner_table = .{
            .alloc = a,
            .opposite_corners = empty_opposite,
            .corner_to_vertex = empty_corner_to_vertex,
            .vertex_corners = vertex_corners,
            .num_faces_ = 0,
        },
    };

    var buf = DecoderBuffer.init(&minimal_buf_bytes);
    const result = parseAttrHeader(&buf, &conn);
    try std.testing.expectError(Error.UnsupportedDracoFeature, result);
}
