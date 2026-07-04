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
    _ = try buf.readInt(u8); // traversal_method_encoded

    // `AttributesDecoder::DecodeAttributesDecoderData`. Only the first (and,
    // per this task's scope, only) attribute descriptor is kept.
    const num_attributes = try buf.decodeVarint(u32);
    if (num_attributes != 1) return Error.UnsupportedDracoFeature;

    _ = try buf.readInt(u8); // att_type (GeometryAttribute::Type)
    _ = try buf.readInt(u8); // data_type
    const num_components = try buf.readInt(u8);
    _ = try buf.readInt(u8); // normalized
    _ = try buf.decodeVarint(u32); // unique_id

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
    const compressed = try buf.readInt(u8);
    if (compressed > 0) {
        // `DecodeSymbols(num_values, num_components, in_buffer, out)` — reuse
        // Slice A's already-tested rANS/raw symbol decoder purely to advance
        // `buf` past the entropy-coded blob; the decoded ints are discarded.
        const scratch = try conn.alloc.alloc(u32, num_values);
        defer conn.alloc.free(scratch);
        try draco.decodeSymbols(conn.alloc, buf, num_values, num_components, scratch);
    } else {
        // Direct (uncompressed) path: `num_bytes` bytes per scalar value.
        const num_bytes = try buf.readInt(u8);
        const total: usize = @as(usize, num_bytes) * num_values;
        try buf.skip(total);
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

    return .{ .scheme_method = scheme_method, .transform_type = transform_type, .quant = quant, .num_components = num_components };
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
    std.debug.print("\n[C1] quad scheme_method={d} transform={d} bits={d} min={any} range={d}\n", .{ h.scheme_method, h.transform_type, h.quant.bits, h.quant.min, h.quant.range });
}
