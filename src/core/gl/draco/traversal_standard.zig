const std = @import("std");
const draco = @import("draco.zig");
const DecoderBuffer = draco.DecoderBuffer;
pub const Error = draco.Error;

pub const Symbol = enum { c, s, l, r, e };

/// STANDARD edgebreaker traversal decoder: CLERS symbols are stored as plain
/// bits (NOT rANS). Port of Draco mesh_edgebreaker_traversal_decoder.h for the
/// num_attribute_data == 0 path.
pub const TraversalDecoder = struct {
    symbols: draco.BitDecoder,
    start_faces: draco.RAnsBitDecoder = .{},
    attribute_connectivity_decoders: []draco.RAnsBitDecoder = &.{},
    attr_alloc: ?std.mem.Allocator = null,

    pub fn start(self: *TraversalDecoder, buf: *DecoderBuffer) Error!void {
        // StartBitDecoding(decode_size=true): varint byte size, then that region.
        const size = try buf.decodeVarint(u32);
        self.symbols = try buf.bitDecoder(size);
    }

    /// Port of the attribute-connectivity part of `Start`/`DecodeAttributeSeams`
    /// (`mesh_edgebreaker_traversal_decoder.h`): (1) the CLERS symbol region
    /// (identical to `start`), THEN (2) `num_attribute_data` consecutive
    /// `RAnsBitDecoder`s, each seeded via `StartDecoding(&buffer_)` from wherever
    /// the previous one left `buf` — i.e. the attribute-connectivity rABS
    /// streams are back to back in attribute order, immediately after the
    /// symbol region. Decoders are owned via `alloc`; free with `deinitAttr`.
    ///
    /// NOTE: real Draco's full `Start()` also runs `DecodeStartFaces()` between
    /// steps (1) and (2) (ported separately above as `startFaces`, already
    /// exercised by the num_attribute_data == 0 path). This function only
    /// covers the two phases in its own contract — a caller assembling the
    /// complete v2.2 bitstream with attributes must sequence
    /// `start` -> `startFaces` -> the attribute-decoder loop itself; it must
    /// NOT call both `start`/`startFaces` and then `startWithAttributes` (which
    /// would re-decode the symbol region).
    pub fn startWithAttributes(self: *TraversalDecoder, buf: *DecoderBuffer, num_attribute_data: u32, alloc: std.mem.Allocator) Error!void {
        try self.start(buf);
        const decoders = try alloc.alloc(draco.RAnsBitDecoder, num_attribute_data);
        errdefer alloc.free(decoders);
        for (decoders) |*d| d.* = .{};
        for (decoders) |*d| try d.startDecoding(buf);
        self.attribute_connectivity_decoders = decoders;
        self.attr_alloc = alloc;
    }

    /// Port of `DecodeAttributeSeam(attribute)`. Bounds-guarded (never panics):
    /// an out-of-range `attr` returns `0` rather than trapping.
    pub fn decodeAttributeSeam(self: *TraversalDecoder, attr: usize) u1 {
        if (attr >= self.attribute_connectivity_decoders.len) return 0;
        return self.attribute_connectivity_decoders[attr].decodeNextBit();
    }

    /// Frees the attribute-connectivity decoders allocated by
    /// `startWithAttributes`. Safe to call even if `startWithAttributes` was
    /// never called (no-op), and idempotent.
    pub fn deinitAttr(self: *TraversalDecoder) void {
        if (self.attr_alloc) |alloc| {
            alloc.free(self.attribute_connectivity_decoders);
            self.attribute_connectivity_decoders = &.{};
            self.attr_alloc = null;
        }
    }

    /// Port of `DecodeStartFaces` (v2.2 path): after the symbol bit region, the
    /// start-face configuration bits are an rANS-binary stream. `buf` must be
    /// positioned immediately after `start` (i.e. right after the symbols).
    /// Advances `buf` past the rANS body, leaving it at the traversal end (no
    /// attribute-seam streams exist for the num_attribute_data == 0 path).
    pub fn startFaces(self: *TraversalDecoder, buf: *DecoderBuffer) Error!void {
        try self.start_faces.startDecoding(buf);
    }

    /// Port of `DecodeStartFaceConfiguration` (v2.2): one rANS bit. `true` means
    /// the start face is interior.
    pub fn decodeStartFaceConfiguration(self: *TraversalDecoder) bool {
        return self.start_faces.decodeNextBit() != 0;
    }

    pub fn decodeSymbol(self: *TraversalDecoder) Error!Symbol {
        const b0 = self.symbols.readBit();
        if (b0 == 0) return .c;
        const b1 = self.symbols.readBit();
        const b2 = self.symbols.readBit();
        // 3-bit pattern (LSB-first): 0x1->S, 0x3->L, 0x5->R, 0x7->E.
        const pat: u3 = @as(u3, b0) | (@as(u3, b1) << 1) | (@as(u3, b2) << 2);
        return switch (pat) {
            0x1 => .s,
            0x3 => .l,
            0x5 => .r,
            0x7 => .e,
            else => Error.Corrupt,
        };
    }
};

// Build a symbol bit region the way Draco does: a varint byte-size prefix, then
// the CLERS bits LSB-first. Encode symbols C=`0`, S=`100`, L=`110`, R=`101`,
// E=`111` (first bit first, i.e. lowest bit position first).
fn buildSymbolStream(a: std.mem.Allocator, syms: []const Symbol) ![]u8 {
    var bits = std.ArrayList(u1).empty;
    defer bits.deinit(a);
    for (syms) |s| switch (s) {
        .c => try bits.append(a, 0), // '0'
        // S/L/R/E: 3 bits, LSB-first = the pattern read as bit0,bit1,bit2
        .s => {
            try bits.appendSlice(a, &[_]u1{ 1, 0, 0 });
        }, // 0x1 = 100b LSB-first
        .l => {
            try bits.appendSlice(a, &[_]u1{ 1, 1, 0 });
        }, // 0x3
        .r => {
            try bits.appendSlice(a, &[_]u1{ 1, 0, 1 });
        }, // 0x5
        .e => {
            try bits.appendSlice(a, &[_]u1{ 1, 1, 1 });
        }, // 0x7
    };
    // pack bits LSB-first into bytes
    const nbytes = (bits.items.len + 7) / 8;
    var body = try a.alloc(u8, nbytes);
    @memset(body, 0);
    for (bits.items, 0..) |b, i| body[i >> 3] |= @as(u8, b) << @intCast(i & 7);
    // prefix: varint size (nbytes). For nbytes < 128 that's a single byte.
    var out = try a.alloc(u8, 1 + nbytes);
    out[0] = @intCast(nbytes);
    @memcpy(out[1..], body);
    a.free(body);
    return out;
}

test "decodeSymbol reads C then S/L/R/E patterns" {
    const a = std.testing.allocator;
    const want = [_]Symbol{ .c, .s, .l, .r, .e, .c };
    const stream = try buildSymbolStream(a, &want);
    defer a.free(stream);
    var buf = DecoderBuffer.init(stream);
    var td: TraversalDecoder = undefined;
    try td.start(&buf);
    for (want) |w| try std.testing.expectEqual(w, try td.decodeSymbol());
}

// ── startWithAttributes round-trip (the gate) ────────────────────────────────
const RAnsBitEncoder = @import("rans_test_encoder.zig").RAnsBitEncoder;

fn buildRabsStream(a: std.mem.Allocator, bits: []const u1) ![]u8 {
    var enc = RAnsBitEncoder.init();
    defer enc.deinit(a);
    for (bits) |b| try enc.encodeBit(a, b);
    return enc.finish(a); // owned bytes
}

test "startWithAttributes: symbol region then N attribute rABS seam streams, in order" {
    const a = std.testing.allocator;

    // Draco layout: [CLERS symbol region][attr0 rABS stream][attr1 rABS stream].
    const want_syms = [_]Symbol{ .c, .s, .l, .r, .e, .c };
    const sym_stream = try buildSymbolStream(a, &want_syms);
    defer a.free(sym_stream);

    const attr0_bits = [_]u1{ 1, 0, 1, 1, 0 };
    const attr1_bits = [_]u1{ 0, 0, 1, 0, 1, 1, 1 };
    const attr0_blob = try buildRabsStream(a, &attr0_bits);
    defer a.free(attr0_blob);
    const attr1_blob = try buildRabsStream(a, &attr1_bits);
    defer a.free(attr1_blob);

    const stream = try a.alloc(u8, sym_stream.len + attr0_blob.len + attr1_blob.len);
    defer a.free(stream);
    @memcpy(stream[0..sym_stream.len], sym_stream);
    @memcpy(stream[sym_stream.len..][0..attr0_blob.len], attr0_blob);
    @memcpy(stream[sym_stream.len + attr0_blob.len ..], attr1_blob);

    var buf = DecoderBuffer.init(stream);
    var td: TraversalDecoder = undefined;
    try td.startWithAttributes(&buf, 2, a);
    defer td.deinitAttr();

    for (want_syms) |w| try std.testing.expectEqual(w, try td.decodeSymbol());
    for (attr0_bits) |b| try std.testing.expectEqual(b, td.decodeAttributeSeam(0));
    for (attr1_bits) |b| try std.testing.expectEqual(b, td.decodeAttributeSeam(1));
}

test "startWithAttributes: num_attribute_data == 0 behaves like plain start" {
    const a = std.testing.allocator;
    const want = [_]Symbol{ .c, .l, .c };
    const stream = try buildSymbolStream(a, &want);
    defer a.free(stream);
    var buf = DecoderBuffer.init(stream);
    var td: TraversalDecoder = undefined;
    try td.startWithAttributes(&buf, 0, a);
    defer td.deinitAttr();
    for (want) |w| try std.testing.expectEqual(w, try td.decodeSymbol());
    // Out-of-range attribute seam lookups never panic.
    try std.testing.expectEqual(@as(u1, 0), td.decodeAttributeSeam(0));
}
