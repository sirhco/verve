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
const octahedron = @import("octahedron.zig");
const OctahedronToolBox = octahedron.OctahedronToolBox;

/// `SequentialAttributeEncoderType` (compression_shared.h): `QUANTIZATION == 2`
/// is the POSITION encoder; `NORMALS == 3` selects `SequentialNormalAttributeDecoder`
/// (decoder 1). `GENERIC=0`/`INTEGER=1` are rejected.
pub const seq_encoder_quantization: u8 = 2;
pub const seq_encoder_normals: u8 = 3;

/// `GeometryAttribute::Type`: `POSITION == 0`, `NORMAL == 1`, `TEX_COORD == 3`.
const geom_attr_position: u8 = 0;
const geom_attr_normal: u8 = 1;
const geom_attr_texcoord: u8 = 3;

/// `PredictionSchemeTransformType`: `NORMAL_OCTAHEDRON_CANONICALIZED == 3` — the
/// only NORMAL transform this port accepts (`NORMAL_OCTAHEDRON == 2`, the older
/// non-canonicalized variant, is rejected: no fixture exercises it).
pub const transform_octahedron_canonicalized: i8 = 3;

/// `PredictionSchemeMethod` (compression_shared.h). `NONE`/`UNDEFINED` and the
/// normal/tex-coord-specific methods (3/5/6) are intentionally excluded from
/// this port's accepted set — see `parseAttrHeader`'s reject comment.
pub const prediction_difference: i8 = 0;
pub const prediction_parallelogram: i8 = 1;
pub const prediction_multi_parallelogram: i8 = 2;
pub const prediction_constrained_multi_parallelogram: i8 = 4;

/// `PredictionSchemeTransformType` (compression_shared.h): `WRAP == 1`.
pub const transform_wrap: i8 = 1;

/// `MeshEncoderElementType` (the per-decoder `decoder_type` byte read in phase 1,
/// right after `att_data_id`): `MESH_VERTEX_ATTRIBUTE == 0` (the attribute rides
/// the shared position connectivity — decode over the base corner table),
/// `MESH_CORNER_ATTRIBUTE == 1` (the attribute has its own seam-aware corner
/// table — decode over `conn.attr_maps[att_data_id]`).
pub const decoder_type_vertex: u8 = 0;
pub const decoder_type_corner: u8 = 1;

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
    /// Descriptor of the NORMAL attributes decoder (the non-position decoder
    /// whose first attribute has `att_type == NORMAL`), or null when the mesh
    /// carries no NORMAL decoder. Captured by *attribute type*, not decoder
    /// index: seamcube (POSITION + UV, 2 decoders) has decoder 1 == TEXCOORD, so
    /// its `normal` stays null and its UV lands in `texcoord`. `decodeAttributes`
    /// inspects it to decide whether/how to decode the NORMAL value section.
    normal: ?DecoderInfo,
    /// Descriptor of the TEXCOORD attributes decoder (the non-position decoder
    /// whose first attribute has `att_type == TEX_COORD`), or null when the mesh
    /// carries no TEXCOORD decoder. Its `traversal_method`/`decoder_type` are
    /// captured from phase 1 (each decoder carries its own).
    texcoord: ?DecoderInfo,
};

/// Phase-1/phase-2 descriptor of a non-POSITION decoder (its first attribute +
/// sequential-encoder byte + its own traversal method). For decoder 1 (NORMAL),
/// `encoder_type == NORMALS (3)` + `att_type == NORMAL (1)` + `num_components ==
/// 3` marks a decoder this port can reconstruct via `decodeNormals`. For decoder
/// 2 (TEXCOORD), `encoder_type == QUANTIZATION (2)` + `att_type == TEX_COORD (3)`
/// + `num_components == 2` marks one this port reconstructs via the same
/// parallelogram+WRAP+dequant path as POSITION (`decodeParallelogramAttr`).
const DecoderInfo = struct {
    att_type: u8,
    num_components: u8,
    encoder_type: u8,
    num_attributes: u32,
    traversal_method: u8,
    /// The phase-1 `decoder_type` byte: `MESH_VERTEX_ATTRIBUTE (0)` → decode over
    /// the base position corner table; `MESH_CORNER_ATTRIBUTE (1)` → decode over
    /// the attribute's own seam-aware `MeshAttrCornerTable`.
    decoder_type: u8,
    /// This decoder's ordinal index (the `i` in the phase-1/phase-2 loops).
    /// Phase 3 (`DecodeAllAttributes`) iterates decoders in index order, so the
    /// value sections appear in decoder-index order. `decodeAttributes` reads the
    /// NORMAL section before the TEXCOORD section, which is only correct when the
    /// NORMAL decoder's index is less than the TEXCOORD decoder's — this field
    /// lets it reject the reverse order rather than silently misdecode.
    decoder_index: u8,
};

/// Full attribute-section walk (see the module doc comment for the C++ chain),
/// capturing the signed residual corrections instead of discarding them.
/// `parseAttrHeader` wraps this and frees `residuals`; `decodeAttributes`
/// consumes them for the prediction inverse.
fn parseAttrSection(alloc: std.mem.Allocator, buf: *DecoderBuffer, conn: *const Connectivity) Error!AttrSection {
    // `PointCloudDecoder::DecodePointAttributes` is three *separate* passes over
    // all N attributes decoders (confirmed from point_cloud_decoder.cc — the
    // `CreateAttributesDecoder`, `DecodeAttributesDecoderData` and
    // `DecodeAllAttributes` loops are distinct, each iterating every decoder):
    //
    //   PHASE 1  CreateAttributesDecoder × N        — att_data_id / decoder_type / traversal
    //   PHASE 2  DecodeAttributesDecoderData × N    — per-decoder descriptors + seq-encoder byte
    //   PHASE 3  DecodeAllAttributes (in order)     — the actual value blobs, decoder 0 first
    //
    // Task 4's probe established POSITION is *decoder 0* (att_data_id == -1), so
    // its phase-3 values come first — but only *after* every decoder's phase-1
    // and phase-2 headers. This port therefore walks phases 1 and 2 for ALL
    // decoders (reading, not reconstructing, the NORMAL/UV descriptors — no
    // value data lives in phase 2), then decodes only decoder 0 in phase 3 and
    // stops. NORMAL/UV *value* reconstruction (octahedron / tex-coord-portable)
    // is C2b/C2c and is never entered here.
    const num_attributes_decoders = try buf.readInt(u8);
    if (num_attributes_decoders == 0) return Error.UnsupportedDracoFeature;

    // ── PHASE 1 — `MeshEdgebreakerDecoderImpl::CreateAttributesDecoder` × N ──
    // Each decoder reads att_data_id (i8), decoder_type (u8: MESH_VERTEX_ATTRIBUTE
    // / MESH_CORNER_ATTRIBUTE) and traversal_method (u8: DEPTH_FIRST /
    // PREDICTION_DEGREE — bitstream >= 1.2, always true for our 2.2-only port).
    // `att_data_id < 0` marks the position attribute (no per-attribute
    // connectivity); every valid combination reads the same 3 bytes.
    const dec_decoder_type = try alloc.alloc(u8, num_attributes_decoders);
    defer alloc.free(dec_decoder_type);
    const dec_traversal = try alloc.alloc(u8, num_attributes_decoders);
    defer alloc.free(dec_traversal);
    {
        var i: u8 = 0;
        while (i < num_attributes_decoders) : (i += 1) {
            const att_data_id = try buf.readInt(i8);
            dec_decoder_type[i] = try buf.readInt(u8); // decoder_type
            // `MeshEncoderElementType`: only MESH_VERTEX_ATTRIBUTE (0) and
            // MESH_CORNER_ATTRIBUTE (1) exist. Draco's `CreateAttributesDecoder`
            // rejects any other value; mirror that here so an unknown decoder
            // type is a loud reject, not a silent fall-through to the vertex
            // (base-table) decode path.
            if (dec_decoder_type[i] != decoder_type_vertex and dec_decoder_type[i] != decoder_type_corner) {
                return Error.UnsupportedDracoFeature;
            }
            dec_traversal[i] = try buf.readInt(u8); // traversal_method
            if (i == 0) {
                // Probe (Task 4) established POSITION leads (att_data_id == -1).
                // If a future fixture violates that, POSITION is not decoder 0
                // and reaching its values would require decoding the intervening
                // NORMAL/UV value sections first — reject rather than silently
                // misdecode.
                if (att_data_id != -1) return Error.UnsupportedDracoFeature;
            }
        }
    }
    const traversal_method = dec_traversal[0]; // POSITION (decoder 0)

    // ── PHASE 2 — `AttributesDecoder::DecodeAttributesDecoderData` × N ──
    // Decoder 0 (POSITION) is captured + validated; decoders 1+ (NORMAL/UV) are
    // walked (descriptors + the per-attribute sequential-encoder byte that
    // `SequentialAttributeDecodersController::DecodeAttributesDecoderData` adds)
    // but never value-decoded — their value blobs live in phase 3, before which
    // we stop. Per attribute the descriptor is att_type (u8), data_type (u8),
    // num_components (u8), normalized (u8), unique_id (varint); the encoder-type
    // bytes are a *separate* trailing loop (matches the two C++ loops).
    var num_components: u8 = 0;
    var normal_info: ?DecoderInfo = null;
    var texcoord_info: ?DecoderInfo = null;
    {
        var i: u8 = 0;
        while (i < num_attributes_decoders) : (i += 1) {
            const num_attributes = try buf.decodeVarint(u32);
            if (i == 0) {
                // POSITION decoder: exactly one attribute, POSITION type, 3
                // components, QUANTIZATION sequential encoder.
                if (num_attributes != 1) return Error.UnsupportedDracoFeature;
                const att_type = try buf.readInt(u8); // GeometryAttribute::Type
                _ = try buf.readInt(u8); // data_type
                num_components = try buf.readInt(u8);
                _ = try buf.readInt(u8); // normalized
                _ = try buf.decodeVarint(u32); // unique_id
                // `att_type == 0` is POSITION (the only geometry attribute type
                // this port accepts); `num_components == 3` is required by
                // `attr_quant.parseQuantParams`.
                if (att_type != 0) return Error.UnsupportedDracoFeature;
                if (num_components != 3) return Error.UnsupportedDracoFeature;
                const seq_encoder_type = try buf.readInt(u8);
                if (seq_encoder_type != seq_encoder_quantization) return Error.UnsupportedDracoFeature;
            } else {
                // Non-POSITION decoder: walk its descriptor block. All
                // descriptors first, then all encoder-type bytes (the two
                // distinct C++ loops). Classify by *attribute type* (not decoder
                // index) so seamcube (POSITION + UV, 2 decoders) routes its
                // decoder-1 UV into `texcoord_info` — leaving `normal_info` null —
                // while cube_nrm_uv routes decoder 1 (NORMAL) → `normal_info` and
                // decoder 2 (UV) → `texcoord_info`. Decoders whose first attribute
                // is neither NORMAL nor TEX_COORD are walked but not captured.
                var att_type_0: u8 = 0;
                var num_comp_0: u8 = 0;
                var j: u32 = 0;
                while (j < num_attributes) : (j += 1) {
                    const at = try buf.readInt(u8); // att_type
                    _ = try buf.readInt(u8); // data_type
                    const ncomp = try buf.readInt(u8); // num_components
                    _ = try buf.readInt(u8); // normalized
                    _ = try buf.decodeVarint(u32); // unique_id
                    if (j == 0) {
                        att_type_0 = at;
                        num_comp_0 = ncomp;
                    }
                }
                var enc_0: u8 = 0;
                var k: u32 = 0;
                while (k < num_attributes) : (k += 1) {
                    const et = try buf.readInt(u8); // sequential-encoder-type byte
                    if (k == 0) enc_0 = et;
                }
                const info = DecoderInfo{
                    .att_type = att_type_0,
                    .num_components = num_comp_0,
                    .encoder_type = enc_0,
                    .num_attributes = num_attributes,
                    .traversal_method = dec_traversal[i],
                    .decoder_type = dec_decoder_type[i],
                    .decoder_index = i,
                };
                if (att_type_0 == geom_attr_normal) {
                    if (normal_info == null) normal_info = info;
                } else if (att_type_0 == geom_attr_texcoord) {
                    if (texcoord_info == null) texcoord_info = info;
                }
            }
        }
    }

    // ── PHASE 3 — `DecodeAllAttributes`, decoder 0 (POSITION) only ──
    // The value-section read is shared with the TEXCOORD decoder (same
    // parallelogram+WRAP+quant wire shape) via `readValueSection`. POSITION is
    // always a base attribute → `num_value_verts = conn.num_points`.
    const vs = try readValueSection(alloc, buf, conn.num_points, num_components, traversal_method);

    return .{
        .header = vs.header,
        .residuals = vs.residuals,
        .normal = normal_info,
        .texcoord = texcoord_info,
    };
}

/// One decoded parallelogram/WRAP/quantization value section (`header` +
/// signed `residuals`, length `num_points * num_components`), shared by decoder
/// 0 (POSITION, `num_components == 3`) and decoder 2 (TEXCOORD, `num_components
/// == 2`). Owned by the passed allocator.
const ValueSection = struct {
    header: DecodedAttrHeader,
    residuals: []i32,
};

/// Faithful port of the phase-3 value section for a QUANTIZATION sequential
/// attribute decoded with a WRAP transform: prediction metadata + the entropy
/// value blob + the WRAP clamp bounds + the quantization params. `buf` must be
/// positioned at the section's first byte (`prediction_scheme_method`).
/// `num_components` is the attribute's component count (3 POSITION / 2 TEXCOORD);
/// `traversal_method` is that decoder's phase-1 traversal byte (threaded into
/// the header for the prediction inverse). Never panics — malformed input maps
/// to `draco.Error`.
fn readValueSection(alloc: std.mem.Allocator, buf: *DecoderBuffer, num_value_verts: usize, num_components: u8, traversal_method: u8) Error!ValueSection {
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

    // `SequentialIntegerAttributeDecoder::DecodeIntegerValues`: the value blob.
    // `num_value_verts` is the attribute's vertex count — `conn.num_points` for a
    // base/position attribute, `attr_map.numVertices()` for a seamed corner attr.
    const num_values: usize = num_value_verts * @as(usize, num_components);
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
    // (quad/cube/torus.drc + cube_nrm_uv's UV all pin `PARALLELOGRAM == 1` — see
    // the golden tests below), so the extra crease-edge decode has no real
    // bitstream to verify byte-exactness against. Rejecting rather than guessing
    // keeps this port's "never silently misdecode" posture; add the extra decode
    // (mirroring `MeshPredictionSchemeConstrainedMultiParallelogramDecoder::
    // DecodePredictionData`) once a fixture that actually encodes with it exists.
    if (scheme_method == prediction_constrained_multi_parallelogram) return Error.UnsupportedDracoFeature;

    // Generic path (`DIFFERENCE` / `PARALLELOGRAM` / `MULTI_PARALLELOGRAM`):
    // `PredictionSchemeDecoder::DecodePredictionData` ->
    // `PredictionSchemeWrapDecodingTransform::DecodeTransformData` — the WRAP
    // clamp bounds, 2x `int32_t` (`DataTypeT` post-quantization). Consumed only
    // to advance `buf`; `inversePredict` re-derives/uses these for the unwrap.
    const wrap_min = try buf.readInt(i32);
    const wrap_max = try buf.readInt(i32);
    if (wrap_min > wrap_max) return Error.Corrupt;

    // `SequentialQuantizationAttributeDecoder::DecodeQuantizedDataInfo` —
    // `num_components` `min_values_` floats (3 POSITION / 2 TEXCOORD).
    const quant = try attr_quant.parseQuantParams(buf, num_components);

    return .{
        .header = .{ .scheme_method = scheme_method, .transform_type = transform_type, .quant = quant, .num_components = num_components, .traversal_method = traversal_method, .wrap_min = wrap_min, .wrap_max = wrap_max },
        .residuals = residuals,
    };
}

/// End-to-end decode of one parallelogram+WRAP+quantization attribute value
/// section into per-point `f32`s: `readValueSection` (prediction metadata +
/// residual entropy stream + WRAP bounds + quant params) → `inversePredict`
/// (parallelogram/difference inverse over `conn`'s corner table, per-point
/// quantized ints) → `dequantize`. `buf` must be positioned at the section's
/// first byte. Shared by POSITION (`num_components == 3`) and TEXCOORD
/// (`num_components == 2`). Returns owned `[]f32` (`num_points * num_components`,
/// decoded-vertex order). Never panics.
fn decodeParallelogramAttr(alloc: std.mem.Allocator, buf: *DecoderBuffer, num_components: u8, traversal_method: u8, view: draco.TableView, num_value_verts: usize) Error![]f32 {
    const vs = try readValueSection(alloc, buf, num_value_verts, num_components, traversal_method);
    defer alloc.free(vs.residuals);
    return finishParallelogramAttr(alloc, vs.header, vs.residuals, num_components, view, num_value_verts);
}

/// Prediction inverse + dequantization shared by POSITION and TEXCOORD:
/// `inversePredictView` (per-(attr-)vertex quantized ints over `view`) →
/// `dequantize` per component. `num_components` selects the component stride for
/// `dequantize`'s `min[comp]`; `num_value_verts` is the attribute's vertex count
/// (`view.numVertices()`). Returns owned `[]f32` (`num_value_verts * nc`) in
/// per-(attr-)vertex order — the caller expands it to per-point order.
fn finishParallelogramAttr(alloc: std.mem.Allocator, header: DecodedAttrHeader, residuals: []const i32, num_components: u8, view: draco.TableView, num_value_verts: usize) Error![]f32 {
    const nc: usize = num_components;
    const q = try draco.inversePredictView(alloc, header, residuals, num_components, view, num_value_verts);
    defer alloc.free(q);
    const values = try alloc.alloc(f32, q.len);
    errdefer alloc.free(values);
    for (q, 0..) |qi, i| {
        // Post-WRAP quantized values are clamped into `[wrap_min, wrap_max]`,
        // which for a quantized attribute is `[0, (1<<bits)-1]` — always
        // non-negative. Guard rather than `@intCast`-panic on a corrupt stream.
        if (qi < 0) return Error.Corrupt;
        values[i] = attr_quant.dequantize(@intCast(qi), i % nc, header.quant);
    }
    return values;
}

/// Expand per-(attr-)vertex `values` (nc components each) to per-point order.
/// For each of `conn.num_output_points` points, resolve its representative
/// corner (`conn.point_to_corner[p]`) → the attribute vertex on that corner
/// (`view.vertexPub`) → its decoded value. Returns an owned `[]f32`
/// (`num_output_points * nc`) that lines up 1:1 with `conn.indices`.
///
/// Fast path: when `conn.point_to_corner` is empty (position-only stream — no
/// attribute dedup ran), per-point == per-vertex, so this is the identity dupe of
/// `values`. For a 0-seam attribute mesh (cube_nrm/cube_nrm_uv) the map is
/// non-empty but point id == vertex id, so the expansion is still an identity in
/// value (regression-safe — the POSITION/NORMAL/TEXCOORD goldens are unchanged).
/// Never panics — a corner/vertex out of range maps to `Error.Corrupt`.
fn expandToPoints(alloc: std.mem.Allocator, conn: *const Connectivity, values: []const f32, nc: usize, view: draco.TableView) Error![]f32 {
    if (conn.point_to_corner.len == 0) {
        // Position-only / no attribute dedup: per-point == per-vertex.
        return alloc.dupe(f32, values);
    }
    const n = conn.num_output_points;
    const out = try alloc.alloc(f32, @as(usize, n) * nc);
    errdefer alloc.free(out);
    var p: usize = 0;
    while (p < n) : (p += 1) {
        const corner = conn.point_to_corner[p];
        // Corners are internally constructed and never exceed the table, but the
        // vertex accessor indexes by corner — guard rather than let a corrupt
        // `point_to_corner` entry run off the corner table (never-panic invariant).
        if (corner >= conn.corner_table.numCorners()) return Error.Corrupt;
        const av = view.vertexPub(corner); // per-point attribute vertex
        const src: usize = @as(usize, av) * nc;
        if (src + nc > values.len) return Error.Corrupt;
        var c: usize = 0;
        while (c < nc) : (c += 1) out[p * nc + c] = values[src + c];
    }
    return out;
}

/// Decode the NORMAL value section (phase 3), positioned right after the
/// POSITION section. Faithful port of `SequentialNormalAttributeDecoder`
/// (+ `SequentialIntegerAttributeDecoder::DecodeIntegerValues`):
///
///   1. `DecodeValues`: `prediction_scheme_method` (i8, must be DIFFERENCE) +
///      `prediction_transform_type` (i8, must be NORMAL_OCTAHEDRON_CANONICALIZED).
///   2. `DecodeIntegerValues`: `compressed` (u8) then the entropy blob of
///      `num_points*2` symbols (2 octahedral components/normal). ★ The
///      octahedron transform's `AreCorrectionsPositive()` is TRUE, so — unlike
///      POSITION's WRAP transform — `ConvertSymbolsToSignedInts` is NOT applied:
///      the raw decoded symbols ARE the corrections.
///   3. `DecodePredictionData` → the canonicalized transform's
///      `DecodeTransformData`: `max_quantized_value` (i32) + `center_value`
///      (i32, unused — the box is rederived from `max_quantized_value`).
///   4. `ComputeOriginalValues` (delta scheme + octahedron-canonicalized
///      transform): running prefix where the first entry predicts from {0,0} and
///      each subsequent entry predicts from the previous decoded (s,t); the
///      per-entry combine is `octCanonicalizedOriginalValue(pred, corr)`.
///   5. `DecodeDataNeededByPortableTransform` → `AttributeOctahedronTransform::
///      DecodeParameters`: `quantization_bits` (u8), the box `StoreValues` uses.
///   6. `StoreValues` (`InverseTransformAttribute`):
///      `QuantizedOctahedralCoordsToUnitVector(s,t)` per entry → 3 f32s, then
///      re-index data-entry order → per-(attr-)vertex order (`buildVertexToDataView`
///      over `view`). For a shared-connectivity normal (MESH_VERTEX_ATTRIBUTE)
///      `view` is the base table and `num_value_verts == conn.num_points`; for a
///      seamed normal it is `conn.attr_maps[att_data_id]` — the caller then
///      expands per-attr-vertex → per-point (`expandToPoints`).
///
/// Returns owned `[]f32` (`num_value_verts*3`, per-(attr-)vertex order). Never
/// panics.
fn decodeNormals(alloc: std.mem.Allocator, buf: *DecoderBuffer, view: draco.TableView, num_value_verts: usize) Error![]f32 {
    // ── (1) DecodeValues: prediction metadata ──
    const scheme_method = try buf.readInt(i8);
    if (scheme_method != prediction_difference) return Error.UnsupportedDracoFeature;
    const transform_type = try buf.readInt(i8);
    if (transform_type != transform_octahedron_canonicalized) return Error.UnsupportedDracoFeature;

    const num_points: usize = num_value_verts;
    const nc: usize = 2; // octahedral (s,t) — `GetNumValueComponents() == 2`
    const num_values: usize = num_points * nc;

    // Guard: empty mesh → no normals to decode.
    if (num_points == 0) return try alloc.alloc(f32, 0);

    // ── (2) DecodeIntegerValues: compressed flag + symbol blob (raw, NO zigzag) ──
    const corr = try alloc.alloc(i32, num_values);
    defer alloc.free(corr);
    const compressed = try buf.readInt(u8);
    if (compressed > 0) {
        const scratch = try alloc.alloc(u32, num_values);
        defer alloc.free(scratch);
        try draco.decodeSymbols(alloc, buf, num_values, @intCast(nc), scratch);
        for (scratch, 0..) |s, i| corr[i] = @bitCast(s); // AreCorrectionsPositive → keep as-is
    } else {
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
            corr[i] = @bitCast(sym);
        }
    }

    // ── (3) DecodePredictionData → DecodeTransformData: max_quantized + center ──
    const max_quantized_value = try buf.readInt(i32);
    _ = try buf.readInt(i32); // center_value — unused (rederived from max_quantized)
    // `set_max_quantized_value`: value must be of the form 2^b-1 (odd, > 0).
    if (max_quantized_value <= 0 or @rem(max_quantized_value, 2) == 0) return Error.Corrupt;
    const mqv: u32 = @intCast(max_quantized_value);
    // q = MostSignificantBit(max_quantized_value) + 1 == bit length == 32 - clz.
    const q_transform: u8 = @intCast(32 - @as(u32, @clz(mqv)));
    if (q_transform < 2 or q_transform > 30) return Error.UnsupportedDracoFeature;
    const box_transform = OctahedronToolBox.init(q_transform);

    // ── (4) ComputeOriginalValues: delta prefix + octahedron-canonicalized ──
    const out_st = try alloc.alloc(i32, num_values);
    defer alloc.free(out_st);
    {
        const o0 = octahedron.octCanonicalizedOriginalValue(.{ 0, 0 }, .{ corr[0], corr[1] }, &box_transform);
        out_st[0] = o0[0];
        out_st[1] = o0[1];
        var e: usize = nc;
        while (e < num_values) : (e += nc) {
            const pred = [2]i32{ out_st[e - nc], out_st[e - nc + 1] };
            const c = [2]i32{ corr[e], corr[e + 1] };
            const o = octahedron.octCanonicalizedOriginalValue(pred, c, &box_transform);
            out_st[e] = o[0];
            out_st[e + 1] = o[1];
        }
    }

    // ── (5) DecodeDataNeededByPortableTransform: quantization_bits (u8) ──
    const quantization_bits = try buf.readInt(u8);
    if (quantization_bits < 2 or quantization_bits > 30) return Error.UnsupportedDracoFeature;
    const box_store = OctahedronToolBox.init(quantization_bits);

    // ── (6) StoreValues: (s,t) → unit vector, re-indexed to per-(attr-)vertex order ──
    const vtd = try draco.buildVertexToDataView(alloc, view, num_value_verts);
    defer alloc.free(vtd);
    const normals = try alloc.alloc(f32, num_points * 3);
    errdefer alloc.free(normals);
    var v: usize = 0;
    while (v < num_points) : (v += 1) {
        const e = vtd[v];
        if (e < 0 or @as(usize, @intCast(e)) >= num_points) return Error.Corrupt;
        const eu: usize = @intCast(e);
        const vec = box_store.quantizedOctahedralCoordsToUnitVector(out_st[eu * nc], out_st[eu * nc + 1]);
        normals[v * 3 + 0] = vec[0];
        normals[v * 3 + 1] = vec[1];
        normals[v * 3 + 2] = vec[2];
    }
    return normals;
}

/// Decoded POSITION values, `num_output_points * 3` `f32`s in per-point order
/// (lines up 1:1 with `Connectivity.indices`). For a 0-seam mesh
/// `num_output_points == num_points`, byte-identical to the pre-seam behavior.
/// Caller must `deinit`.
pub const PositionData = struct {
    values: []f32,
    alloc: std.mem.Allocator,
    /// Decoded NORMAL values, `num_output_points * 3` unit-vector `f32`s in
    /// per-point order (lines up 1:1 with `values`), or null when the mesh
    /// carries no NORMAL attributes decoder (quad/cube/torus/seamcube).
    normals: ?[]f32 = null,
    /// Decoded TEXCOORD (UV) values, `num_output_points * 2` `f32`s in per-point
    /// order (lines up 1:1 with `values`), or null when the mesh carries no
    /// TEXCOORD attributes decoder (quad/cube/torus/cube_nrm).
    texcoords: ?[]f32 = null,

    pub fn deinit(self: *PositionData) void {
        self.alloc.free(self.values);
        self.values = &.{};
        if (self.normals) |n| {
            self.alloc.free(n);
            self.normals = null;
        }
        if (self.texcoords) |t| {
            self.alloc.free(t);
            self.texcoords = null;
        }
    }
};

/// End-to-end decode of POSITION (decoder 0) + optional NORMAL (decoder 1) +
/// optional TEXCOORD (decoder 2): header + residual entropy stream
/// (`parseAttrSection`) → prediction inverse (`predict_mesh.inversePredict`) →
/// dequantization. POSITION and TEXCOORD share `finishParallelogramAttr` /
/// `decodeParallelogramAttr` (identical parallelogram+WRAP+quant wire shape,
/// differing only in `num_components`); NORMAL uses `decodeNormals`. `buf` must
/// be positioned right after `decodeConnectivity`. Returns owned `PositionData`
/// (`values.len == num_points * 3`, decoded-vertex order). Never panics on
/// malformed input — bounds/consistency violations map to `draco.Error`.
pub fn decodeAttributes(alloc: std.mem.Allocator, buf: *DecoderBuffer, conn: *const Connectivity) Error!PositionData {
    const section = try parseAttrSection(alloc, buf, conn);
    defer alloc.free(section.residuals);
    const h = section.header;

    // Phase 3 (`DecodeAllAttributes`) emits value sections in decoder-index
    // order, but the NORMAL/TEXCOORD sections below are read in a fixed order
    // (NORMAL first, then TEXCOORD). That fixed order is byte-correct only when
    // the NORMAL decoder's index precedes the TEXCOORD decoder's. All committed
    // fixtures satisfy this (POSITION, NORMAL, TEXCOORD), so this is unreachable
    // today — but reject the reverse rather than silently misdecode.
    if (section.normal) |ni| {
        if (section.texcoord) |ti| {
            if (ni.decoder_index > ti.decoder_index) return Error.UnsupportedDracoFeature;
        }
    }

    // POSITION (decoder 0): always a base attribute (no per-attribute seams on
    // the position itself). Decode per-base-vertex, then expand to per-point.
    const pos_view = draco.TableView{ .ct = &conn.corner_table, .attr = null };
    const pos_per_vtx = try finishParallelogramAttr(alloc, h, section.residuals, h.num_components, pos_view, conn.num_points);
    defer alloc.free(pos_per_vtx);
    const values = try expandToPoints(alloc, conn, pos_per_vtx, h.num_components, pos_view);
    errdefer alloc.free(values);

    // NORMAL decoder, if present and a supported NORMALS decoder. `buf` is
    // positioned exactly at its phase-3 value section (right after the POSITION
    // quant params `parseAttrSection` read). A `MESH_CORNER_ATTRIBUTE` normal
    // decodes over its own seam-aware `attr_maps[att_data_id]`; a
    // `MESH_VERTEX_ATTRIBUTE` one (cube_nrm/cube_nrm_uv) over the base table.
    //
    // NOTE: no committed fixture carries a *seamed* NORMAL (seamcube has UV only,
    // num_attribute_data == 1). The corner-attr NORMAL branch below is therefore
    // structurally in place but golden-verified only for shared (per-vertex)
    // normals; a NORMAL-seam fixture is a follow-on.
    var normals: ?[]f32 = null;
    errdefer if (normals) |n| alloc.free(n);
    if (section.normal) |ni| {
        if (ni.encoder_type == seq_encoder_normals) {
            // A NORMALS-encoded decoder we must reconstruct: reject anything
            // outside the octahedral 3-component normal shape rather than
            // silently misdecode.
            if (ni.num_attributes != 1 or ni.att_type != geom_attr_normal or ni.num_components != 3) {
                return Error.UnsupportedDracoFeature;
            }
            if (ni.decoder_type == decoder_type_corner) {
                const ai: usize = 0; // NORMAL is the first attribute-data decoder → att_data_id 0
                if (ai >= conn.attr_maps.len) return Error.Corrupt;
                const view = draco.TableView{ .ct = &conn.corner_table, .attr = &conn.attr_maps[ai] };
                const nvv: usize = conn.attr_maps[ai].numVertices();
                const per_vtx = try decodeNormals(alloc, buf, view, nvv);
                defer alloc.free(per_vtx);
                normals = try expandToPoints(alloc, conn, per_vtx, 3, view);
            } else {
                const view = draco.TableView{ .ct = &conn.corner_table, .attr = null };
                const per_vtx = try decodeNormals(alloc, buf, view, conn.num_points);
                defer alloc.free(per_vtx);
                normals = try expandToPoints(alloc, conn, per_vtx, 3, view);
            }
        }
    }

    // TEXCOORD decoder, if present and a supported TEXCOORD decoder. `buf` is
    // positioned exactly at its phase-3 value section (right after the NORMAL
    // section, if any). A `MESH_CORNER_ATTRIBUTE` UV (seamcube) decodes over its
    // own seam-aware `attr_maps[att_data_id]`; a `MESH_VERTEX_ATTRIBUTE` UV
    // (cube_nrm_uv, per-vertex) over the shared base corner table.
    var texcoords: ?[]f32 = null;
    if (section.texcoord) |ti| {
        if (ti.encoder_type == seq_encoder_quantization) {
            // A QUANTIZATION-encoded TEXCOORD decoder we reconstruct via the
            // same parallelogram+WRAP+dequant path as POSITION: reject anything
            // outside the 2-component UV shape rather than silently misdecode.
            if (ti.num_attributes != 1 or ti.att_type != geom_attr_texcoord or ti.num_components != 2) {
                return Error.UnsupportedDracoFeature;
            }
            if (ti.decoder_type == decoder_type_corner) {
                // att_data_id of the UV decoder: 1 when a NORMAL attr-data decoder
                // precedes it (cube_nrm_uv), else 0 (seamcube).
                const ai: usize = if (section.normal != null) 1 else 0;
                if (ai >= conn.attr_maps.len) return Error.Corrupt;
                const view = draco.TableView{ .ct = &conn.corner_table, .attr = &conn.attr_maps[ai] };
                const nvv: usize = conn.attr_maps[ai].numVertices();
                const per_vtx = try decodeParallelogramAttr(alloc, buf, 2, ti.traversal_method, view, nvv);
                defer alloc.free(per_vtx);
                texcoords = try expandToPoints(alloc, conn, per_vtx, 2, view);
            } else {
                const view = draco.TableView{ .ct = &conn.corner_table, .attr = null };
                const per_vtx = try decodeParallelogramAttr(alloc, buf, 2, ti.traversal_method, view, conn.num_points);
                defer alloc.free(per_vtx);
                texcoords = try expandToPoints(alloc, conn, per_vtx, 2, view);
            }
        }
    }

    return .{ .values = values, .alloc = alloc, .normals = normals, .texcoords = texcoords };
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

test "decodeAttributes(cube.drc) → POSITION golden (byte-exact ±1 verts)" {
    const a = std.testing.allocator;
    const cube_drc = @import("draco_fixtures").cube_drc;
    var buf = DecoderBuffer.init(cube_drc);
    _ = try draco.parseHeader(&buf);
    var conn = try draco.decodeConnectivity(a, &buf);
    defer conn.deinit();
    var pos = try decodeAttributes(a, &buf, &conn);
    defer pos.deinit();
    // Baked verbatim from tests/fixtures/draco/cube.golden.json's POSITION array
    // (`node -e "console.log(require('./tests/fixtures/draco/cube.golden.json').POSITION.join(', '))"`).
    const want = [_]f32{ -1, 1, 1, -1, -1, 1, 1, 1, 1, 1, -1, 1, -1, -1, -1, -1, 1, -1, 1, 1, -1, 1, -1, -1 };
    try std.testing.expectEqualSlices(f32, &want, pos.values);
}

test "decodeAttributes(torus.drc) → POSITION golden (real quantization)" {
    const a = std.testing.allocator;
    const torus_drc = @import("draco_fixtures").torus_drc;
    var buf = DecoderBuffer.init(torus_drc);
    _ = try draco.parseHeader(&buf);
    var conn = try draco.decodeConnectivity(a, &buf);
    defer conn.deinit();
    var pos = try decodeAttributes(a, &buf, &conn);
    defer pos.deinit();
    // Baked verbatim from tests/fixtures/draco/torus.golden.json's POSITION array
    // (`node -e "console.log(require('./tests/fixtures/draco/torus.golden.json').POSITION.join(', '))"`).
    // 288 values (96 verts x 3 components); byte-exact — Draco's dequantized f32
    // output, reproduced exactly by parsing the printed JS double back into the
    // nearest f32 literal (same value the JS Number originally rounded from).
    const want = [_]f32{
        1.1257827281951904,    -0.650155782699585,    9.1552734375e-05,     0.6501555442810059,    -1.12578284740448,     9.1552734375e-05,
        0.75266432762146,      -1.3034425973892212,   0.49483615159988403,  0.0001647472381591797, -1.999908447265625,    0.6998534798622131,
        2.1607582569122314,    1.2474088668823242,    0.49483615159988403,  0.0001647472381591797, -1.5051639080047607,   0.49483615159988403,
        0.0001647472381591797, -1.3001465797424316,   9.1552734375e-05,     0.0001647472381591797, -1.5051639080047607,   -0.49498260021209717,
        2.3384177684783936,    1.3499176502227783,    9.1552734375e-05,     0.75266432762146,      -1.3034425973892212,   -0.49498260021209717,
        1.3034427165985107,    -0.7526644468307495,   -0.49498260021209717, 1.5051639080047607,    0.0001647472381591797, -0.49498260021209717,
        1.3034427165985107,    0.75266432762146,      -0.49498260021209717, 2.700000047683716,     0.0001647472381591797, 9.1552734375e-05,
        1.3001463413238525,    0.0001647472381591797, 9.1552734375e-05,     1.3034427165985107,    -0.7526644468307495,   0.49483615159988403,
        0.9998717308044434,    -1.7319356203079224,   0.6998534798622131,   0.0001647472381591797, -2.4949827194213867,   0.49483615159988403,
        -1.2474089860916138,   -2.1607580184936523,   0.49483615159988403,  -0.9998718500137329,   -1.7319356203079224,   0.6998534798622131,
        -0.7526644468307495,   -1.3034425973892212,   0.49483615159988403,  -0.650155782699585,    -1.12578284740448,     9.1552734375e-05,
        -0.7526644468307495,   -1.3034425973892212,   -0.49498260021209717, 0.0001647472381591797, -1.999908447265625,    -0.699999988079071,
        -0.9998718500137329,   -1.7319356203079224,   -0.699999988079071,   0.0001647472381591797, -2.4949827194213867,   -0.49498260021209717,
        -1.2474089860916138,   -2.1607580184936523,   -0.49498260021209717, 0.0001647472381591797, -2.700000047683716,    9.1552734375e-05,
        -1.3499176502227783,   -2.3384180068969727,   9.1552734375e-05,     2.4949824810028076,    0.0001647472381591797, 0.49483615159988403,
        -2.3384180068969727,   -1.3499176502227783,   9.1552734375e-05,     -2.1607580184936523,   -1.2474089860916138,   0.49483615159988403,
        -1.7319356203079224,   -0.9998718500137329,   0.6998534798622131,   -1.3034425973892212,   -0.7526644468307495,   0.49483615159988403,
        -1.12578284740448,     -0.650155782699585,    9.1552734375e-05,     -1.3034425973892212,   -0.7526644468307495,   -0.49498260021209717,
        -1.7319356203079224,   -0.9998718500137329,   -0.699999988079071,   -2.1607580184936523,   -1.2474089860916138,   -0.49498260021209717,
        -2.4949827194213867,   0.0001647472381591797, -0.49498260021209717, -2.1607580184936523,   1.2474088668823242,    -0.49498260021209717,
        1.7319352626800537,    0.9998717308044434,    0.6998534798622131,   -2.700000047683716,    0.0001647472381591797, 9.1552734375e-05,
        -2.4949827194213867,   0.0001647472381591797, 0.49483615159988403,  -1.999908447265625,    0.0001647472381591797, 0.6998534798622131,
        -1.5051639080047607,   0.0001647472381591797, 0.49483615159988403,  -1.3001465797424316,   0.0001647472381591797, 9.1552734375e-05,
        -1.5051639080047607,   0.0001647472381591797, -0.49498260021209717, -1.999908447265625,    0.0001647472381591797, -0.699999988079071,
        -1.7319356203079224,   0.9998717308044434,    -0.699999988079071,   -0.9998718500137329,   1.7319352626800537,    -0.699999988079071,
        0.0001647472381591797, 1.999908208847046,     -0.699999988079071,   0.9998717308044434,    1.7319352626800537,    0.6998534798622131,
        -1.2474089860916138,   2.1607582569122314,    -0.49498260021209717, -2.3384180068969727,   1.3499176502227783,    9.1552734375e-05,
        -2.1607580184936523,   1.2474088668823242,    0.49483615159988403,  -1.7319356203079224,   0.9998717308044434,    0.6998534798622131,
        -1.3034425973892212,   0.75266432762146,      0.49483615159988403,  -1.12578284740448,     0.6501555442810059,    9.1552734375e-05,
        -1.3034425973892212,   0.75266432762146,      -0.49498260021209717, -0.7526644468307495,   1.3034427165985107,    -0.49498260021209717,
        0.0001647472381591797, 1.5051639080047607,    -0.49498260021209717, 0.75266432762146,      1.3034427165985107,    -0.49498260021209717,
        1.3499176502227783,    2.3384177684783936,    9.1552734375e-05,     1.2474088668823242,    2.1607582569122314,    0.49483615159988403,
        0.9998717308044434,    1.7319352626800537,    -0.699999988079071,   0.0001647472381591797, 2.4949824810028076,    -0.49498260021209717,
        -1.3499176502227783,   2.3384177684783936,    9.1552734375e-05,     -1.2474089860916138,   2.1607582569122314,    0.49483615159988403,
        -0.9998718500137329,   1.7319352626800537,    0.6998534798622131,   -0.7526644468307495,   1.3034427165985107,    0.49483615159988403,
        -0.650155782699585,    1.1257827281951904,    9.1552734375e-05,     0.0001647472381591797, 1.3001463413238525,    9.1552734375e-05,
        0.6501555442810059,    1.1257827281951904,    9.1552734375e-05,     1.1257827281951904,    0.6501555442810059,    9.1552734375e-05,
        1.5051639080047607,    0.0001647472381591797, 0.49483615159988403,  1.7319352626800537,    -0.9998718500137329,   0.6998534798622131,
        1.2474088668823242,    -2.1607580184936523,   0.49483615159988403,  1.3499176502227783,    -2.3384180068969727,   9.1552734375e-05,
        1.2474088668823242,    -2.1607580184936523,   -0.49498260021209717, 0.9998717308044434,    -1.7319356203079224,   -0.699999988079071,
        1.7319352626800537,    -0.9998718500137329,   -0.699999988079071,   1.999908208847046,     0.0001647472381591797, -0.699999988079071,
        1.7319352626800537,    0.9998717308044434,    -0.699999988079071,   1.2474088668823242,    2.1607582569122314,    -0.49498260021209717,
        0.0001647472381591797, 2.700000047683716,     9.1552734375e-05,     0.0001647472381591797, 2.4949824810028076,    0.49483615159988403,
        0.0001647472381591797, 1.999908208847046,     0.6998534798622131,   0.0001647472381591797, 1.5051639080047607,    0.49483615159988403,
        0.75266432762146,      1.3034427165985107,    0.49483615159988403,  1.3034427165985107,    0.75266432762146,      0.49483615159988403,
        1.999908208847046,     0.0001647472381591797, 0.6998534798622131,   2.1607582569122314,    -1.2474089860916138,   0.49483615159988403,
        2.3384177684783936,    -1.3499176502227783,   9.1552734375e-05,     2.1607582569122314,    -1.2474089860916138,   -0.49498260021209717,
        2.4949824810028076,    0.0001647472381591797, -0.49498260021209717, 2.1607582569122314,    1.2474088668823242,    -0.49498260021209717,
    };
    try std.testing.expectEqualSlices(f32, &want, pos.values);
}

test "decodeAttributes(cube_nrm.drc) → POSITION byte-exact (num_attribute_data=1)" {
    const a = std.testing.allocator;
    const cube_nrm_drc = @import("draco_fixtures").cube_nrm_drc;
    var buf = DecoderBuffer.init(cube_nrm_drc);
    _ = try draco.parseHeader(&buf);
    var conn = try draco.decodeConnectivity(a, &buf);
    defer conn.deinit();
    var pos = try decodeAttributes(a, &buf, &conn);
    defer pos.deinit();
    // Baked verbatim from tests/fixtures/draco/cube_nrm.golden.json's POSITION.
    const want = [_]f32{ -1, 1, 1, -1, -1, 1, 1, 1, 1, 1, -1, 1, -1, -1, -1, -1, 1, -1, 1, 1, -1, 1, -1, -1 };
    try std.testing.expectEqualSlices(f32, &want, pos.values);
}

test "decodeAttributes(cube_nrm_uv.drc) → POSITION byte-exact (num_attribute_data=2)" {
    const a = std.testing.allocator;
    const cube_nrm_uv_drc = @import("draco_fixtures").cube_nrm_uv_drc;
    var buf = DecoderBuffer.init(cube_nrm_uv_drc);
    _ = try draco.parseHeader(&buf);
    var conn = try draco.decodeConnectivity(a, &buf);
    defer conn.deinit();
    var pos = try decodeAttributes(a, &buf, &conn);
    defer pos.deinit();
    // Baked verbatim from tests/fixtures/draco/cube_nrm_uv.golden.json's POSITION.
    const want = [_]f32{ -1, 1, 1, -1, -1, 1, 1, 1, 1, 1, -1, 1, -1, -1, -1, -1, 1, -1, 1, 1, -1, 1, -1, -1 };
    try std.testing.expectEqualSlices(f32, &want, pos.values);
}

test "decodeAttributes(cube_nrm.drc) → NORMAL byte-exact (24 f32)" {
    const a = std.testing.allocator;
    const cube_nrm_drc = @import("draco_fixtures").cube_nrm_drc;
    var buf = DecoderBuffer.init(cube_nrm_drc);
    _ = try draco.parseHeader(&buf);
    var conn = try draco.decodeConnectivity(a, &buf);
    defer conn.deinit();
    var pos = try decodeAttributes(a, &buf, &conn);
    defer pos.deinit();
    try std.testing.expect(pos.normals != null);
    // Baked verbatim from tests/fixtures/draco/cube_nrm.golden.json's NORMAL
    // (`node -e "console.log(require('./tests/fixtures/draco/cube_nrm.golden.json').NORMAL.join(', '))"`).
    const want = [_]f32{
        -0.5762181282043457, 0.57621830701828,    0.5796077847480774,
        -0.5762181282043457, -0.57621830701828,   0.5796077847480774,
        0.5762181282043457,  0.57621830701828,    0.5796077847480774,
        0.5762181878089905,  -0.5762181878089905, 0.5796077847480774,
        -0.5762181878089905, -0.5762181878089905, -0.5796077847480774,
        -0.5762181878089905, 0.5762181878089905,  -0.5796077847480774,
        0.5762181282043457,  0.57621830701828,    -0.5796077847480774,
        0.5762181878089905,  -0.5762181878089905, -0.5796077847480774,
    };
    try std.testing.expectEqualSlices(f32, &want, pos.normals.?);
}

test "decodeAttributes(cube_nrm_uv.drc) → NORMAL byte-exact (stops before TEXCOORD)" {
    const a = std.testing.allocator;
    const cube_nrm_uv_drc = @import("draco_fixtures").cube_nrm_uv_drc;
    var buf = DecoderBuffer.init(cube_nrm_uv_drc);
    _ = try draco.parseHeader(&buf);
    var conn = try draco.decodeConnectivity(a, &buf);
    defer conn.deinit();
    var pos = try decodeAttributes(a, &buf, &conn);
    defer pos.deinit();
    try std.testing.expect(pos.normals != null);
    // Baked verbatim from cube_nrm_uv.golden.json's NORMAL (identical smooth-cube
    // normals to cube_nrm).
    const want = [_]f32{
        -0.5762181282043457, 0.57621830701828,    0.5796077847480774,
        -0.5762181282043457, -0.57621830701828,   0.5796077847480774,
        0.5762181282043457,  0.57621830701828,    0.5796077847480774,
        0.5762181878089905,  -0.5762181878089905, 0.5796077847480774,
        -0.5762181878089905, -0.5762181878089905, -0.5796077847480774,
        -0.5762181878089905, 0.5762181878089905,  -0.5796077847480774,
        0.5762181282043457,  0.57621830701828,    -0.5796077847480774,
        0.5762181878089905,  -0.5762181878089905, -0.5796077847480774,
    };
    try std.testing.expectEqualSlices(f32, &want, pos.normals.?);
}

test "decodeAttributes(cube_nrm_uv.drc) → TEXCOORD byte-exact (16 f32)" {
    const a = std.testing.allocator;
    const cube_nrm_uv_drc = @import("draco_fixtures").cube_nrm_uv_drc;
    var buf = DecoderBuffer.init(cube_nrm_uv_drc);
    _ = try draco.parseHeader(&buf);
    var conn = try draco.decodeConnectivity(a, &buf);
    defer conn.deinit();
    var pos = try decodeAttributes(a, &buf, &conn);
    defer pos.deinit();
    try std.testing.expect(pos.texcoords != null);
    // POSITION + NORMAL still decode (no regression).
    try std.testing.expect(pos.normals != null);
    // Baked verbatim from tests/fixtures/draco/cube_nrm_uv.golden.json's
    // TEXCOORD_0 (`node -e "console.log(require('./tests/fixtures/draco/
    // cube_nrm_uv.golden.json').TEXCOORD_0.join(', '))"`). 16 values (8 verts ×
    // 2 components); byte-exact — decoder 2 (TEXCOORD) rides the shared POSITION
    // connectivity and is reconstructed via the same parallelogram+WRAP+dequant
    // path as POSITION with `num_components == 2`.
    const want = [_]f32{ 0, 1, 0, 0, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 0 };
    try std.testing.expectEqualSlices(f32, &want, pos.texcoords.?);
}

test "decodeAttributes(seamcube.drc): 24-point POSITION + TEXCOORD byte-exact (UV seam)" {
    const a = std.testing.allocator;
    const seamcube_drc = @import("draco_fixtures").seamcube_drc;
    var buf = DecoderBuffer.init(seamcube_drc);
    _ = try draco.parseHeader(&buf);
    var conn = try draco.decodeConnectivity(a, &buf);
    defer conn.deinit();
    var pos = try decodeAttributes(a, &buf, &conn);
    defer pos.deinit();
    // seamcube carries a UV seam: 8 position vertices expand to 24 output points
    // (POSITION per-point == the position of the point's representative corner;
    // TEXCOORD decodes over its own seam-aware attr corner table). seamcube has
    // NO NORMAL attribute (num_attribute_data == 1, UV only), so the NORMAL-seam
    // branch is exercised only structurally, not golden-verified here.
    try std.testing.expectEqual(@as(usize, 24 * 3), pos.values.len);
    try std.testing.expect(pos.normals == null);
    try std.testing.expect(pos.texcoords != null);
    try std.testing.expectEqual(@as(usize, 24 * 2), pos.texcoords.?.len);
    // Baked verbatim from tests/fixtures/draco/seamcube.golden.json's POSITION /
    // TEXCOORD_0 (`node -e "const g=require('./tests/fixtures/draco/
    // seamcube.golden.json'); console.log(g.POSITION.join(', '));
    // console.log(g.TEXCOORD_0.join(', '))"`).
    const want_pos = [_]f32{
        -1, 1,  1,  -1, 1,  1,  -1, 1,  1,  -1, -1, 1,  -1, -1, 1,  -1, -1, 1,
        1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  -1, 1,  1,  -1, 1,  1,  -1, 1,
        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, 1,  -1, -1, 1,  -1, -1, 1,  -1,
        1,  1,  -1, 1,  1,  -1, 1,  1,  -1, 1,  -1, -1, 1,  -1, -1, 1,  -1, -1,
    };
    const want_uv = [_]f32{
        0.8333333134651184, 0.7501017451286316, 0.4999999701976776, 0.7501017451286316,
        0.1666666567325592, 0.7501017451286316, 0.3333333134651184, 0,
        0.8333333134651184, 0,                  0.1666666567325592, 0,
        0.4999999701976776, 0.4999999701976776, 0.6666666269302368, 0.4999999701976776,
        0.1666666567325592, 0.4999999701976776, 0.1666666567325592, 0.2501017451286316,
        0.6666666269302368, 0.2501017451286316, 0.3333333134651184, 0.2501017451286316,
        0.8333333134651184, 0,                  0.3333333134651184, 0,
        0,                  0,                  0,                  0.7501017451286316,
        0.4999999701976776, 0.7501017451286316, 0.8333333134651184, 0.7501017451286316,
        0.4999999701976776, 0.4999999701976776, 0,                  0.4999999701976776,
        0.6666666269302368, 0.4999999701976776, 0.6666666269302368, 0.2501017451286316,
        0,                  0.2501017451286316, 0.3333333134651184, 0.2501017451286316,
    };
    try std.testing.expectEqualSlices(f32, &want_pos, pos.values);
    try std.testing.expectEqualSlices(f32, &want_uv, pos.texcoords.?);
}

/// Absolute byte offset of `prediction_scheme_method` within `quad_drc`
/// (verified: instrumented `parseAttrSection` to print `buf.pos` right before
/// the `readInt(i8)` for `scheme_method`, ran the existing quad golden tests —
/// both landed on 34).
const SCHEME_OFF: usize = 34;

/// Absolute byte offset of decoder 1's (NORMAL) `prediction_scheme_method`
/// within `cube_nrm_drc` (found by instrumenting `decodeNormals` to print
/// `buf.pos` at entry, then running the cube_nrm NORMAL golden test → 94;
/// `[94]=scheme(DIFFERENCE 0)`, `[95]=transform(OCTAHEDRON_CANONICALIZED 3)`,
/// `[96]=compressed`). cube_nrm_uv's is 108 — this reject test uses cube_nrm.
const NORMAL_SCHEME_OFF: usize = 94;

test "reject unsupported NORMAL prediction scheme (patched → geometric normal)" {
    const a = std.testing.allocator;
    const cube_nrm_drc = @import("draco_fixtures").cube_nrm_drc;
    const copy = try a.dupe(u8, cube_nrm_drc);
    defer a.free(copy);
    // Patch decoder 1's prediction_scheme_method from DIFFERENCE(0) to 6
    // (a normal/geometric method outside this port's accepted DIFFERENCE-only
    // set for NORMAL) → the NORMAL decode must reject, not silently misdecode.
    copy[NORMAL_SCHEME_OFF] = 6;
    var buf = DecoderBuffer.init(copy);
    _ = try draco.parseHeader(&buf);
    var conn = try draco.decodeConnectivity(a, &buf);
    defer conn.deinit();
    try std.testing.expectError(Error.UnsupportedDracoFeature, decodeAttributes(a, &buf, &conn));
}

test "reject unsupported NORMAL prediction transform (patched → plain octahedron)" {
    const a = std.testing.allocator;
    const cube_nrm_drc = @import("draco_fixtures").cube_nrm_drc;
    const copy = try a.dupe(u8, cube_nrm_drc);
    defer a.free(copy);
    // Patch decoder 1's prediction_transform_type from
    // NORMAL_OCTAHEDRON_CANONICALIZED(3) to NORMAL_OCTAHEDRON(2), the older
    // non-canonicalized variant this port does not implement → reject.
    copy[NORMAL_SCHEME_OFF + 1] = 2;
    var buf = DecoderBuffer.init(copy);
    _ = try draco.parseHeader(&buf);
    var conn = try draco.decodeConnectivity(a, &buf);
    defer conn.deinit();
    try std.testing.expectError(Error.UnsupportedDracoFeature, decodeAttributes(a, &buf, &conn));
}

test "reject unsupported prediction scheme" {
    const a = std.testing.allocator;
    const quad_drc = @import("draco_fixtures").quad_drc;
    const copy = try a.dupe(u8, quad_drc);
    defer a.free(copy);
    // 5 == PredictionSchemeMethod TEX_COORDS_PORTABLE — outside this port's
    // accepted set {DIFFERENCE=0, PARALLELOGRAM=1, MULTI_PARALLELOGRAM=2,
    // CONSTRAINED_MULTI_PARALLELOGRAM=4}.
    copy[SCHEME_OFF] = 5;
    var buf = DecoderBuffer.init(copy);
    _ = try draco.parseHeader(&buf);
    var conn = try draco.decodeConnectivity(a, &buf);
    defer conn.deinit();
    try std.testing.expectError(Error.UnsupportedDracoFeature, decodeAttributes(a, &buf, &conn));
}

/// Absolute byte offset of decoder 2's (TEXCOORD) `prediction_scheme_method`
/// within `cube_nrm_uv_drc` (found by instrumenting `decodeAttributes` to print
/// `buf.pos` right before the TEXCOORD `decodeParallelogramAttr` call, then
/// running the TEXCOORD golden test → 151; `[151]=scheme(PARALLELOGRAM 1)`,
/// `[152]=transform(WRAP 1)`, `[153]=compressed`).
const TEXCOORD_SCHEME_OFF: usize = 151;

test "reject unsupported TEXCOORD prediction scheme (patched → tex-coords-portable)" {
    const a = std.testing.allocator;
    const cube_nrm_uv_drc = @import("draco_fixtures").cube_nrm_uv_drc;
    const copy = try a.dupe(u8, cube_nrm_uv_drc);
    defer a.free(copy);
    // Patch decoder 2's prediction_scheme_method from PARALLELOGRAM(1) to 5
    // (TEX_COORDS_PORTABLE — outside this port's accepted set) → the TEXCOORD
    // decode must reject via `readValueSection`, not silently misdecode. POSITION
    // and NORMAL (decoders 0/1) decode fully before reaching this byte.
    copy[TEXCOORD_SCHEME_OFF] = 5;
    var buf = DecoderBuffer.init(copy);
    _ = try draco.parseHeader(&buf);
    var conn = try draco.decodeConnectivity(a, &buf);
    defer conn.deinit();
    try std.testing.expectError(Error.UnsupportedDracoFeature, decodeAttributes(a, &buf, &conn));
}
