//! Binary rANS ("rABS") bit decoder — a faithful port of Draco's
//! `RAnsBitDecoder` (`src/draco/compression/bit_coders/rans_bit_decoder.{h,cc}`)
//! and the `rabs_desc_read` / `ans_read_init` primitives from
//! `src/draco/compression/entropy/ans.h`.
//!
//! Draco encodes a sequence of bits with a single static zero-probability
//! (`prob_zero_`) computed from the total bit counts; the stream layout is
//!   [prob_zero : u8][size_in_bytes : varint][rANS body : size_in_bytes bytes]
//! and the rANS state is seeded from the *tail* of the body, consumed
//! backwards. Bitstream v2.2 (varint size prefix).
//!
//! The paired test-only encoder (`rans_test_encoder.zig`) produces exactly this
//! layout; the round-trip tests at the bottom are the correctness gate.

const std = @import("std");
const draco = @import("draco.zig");
const DecoderBuffer = draco.DecoderBuffer;
pub const Error = draco.Error;

// ── rANS constants (ans.h) ───────────────────────────────────────────────────
// DRACO_ANS_P8_PRECISION 256u, DRACO_ANS_L_BASE 4096u, DRACO_ANS_IO_BASE 256.
const ANS_P8_PRECISION: u32 = 256;
const ANS_L_BASE: u32 = 4096;
const ANS_IO_BASE: u32 = 256;

fn memGetLe16(m: []const u8) u32 {
    return @as(u32, m[0]) | (@as(u32, m[1]) << 8);
}
fn memGetLe24(m: []const u8) u32 {
    return @as(u32, m[0]) | (@as(u32, m[1]) << 8) | (@as(u32, m[2]) << 16);
}

/// Faithful port of Draco `RAnsBitDecoder` (binary rABS, static prob_zero_).
pub const RAnsBitDecoder = struct {
    // AnsDecoder state (ans.h). `buf` is the rANS body region; `buf_offset`
    // indexes into it and only ever *decreases* (bytes are read from the tail),
    // so `buf[buf_offset]` is always in bounds — no read can go OOB.
    buf: []const u8 = &.{},
    buf_offset: usize = 0,
    state: u32 = 0,
    prob_zero: u8 = 0,

    /// Reads `prob_zero_`, the varint body size, seeds the rANS state from the
    /// body tail, and advances `source` past the body.
    pub fn startDecoding(self: *RAnsBitDecoder, source: *DecoderBuffer) Error!void {
        self.* = .{};

        self.prob_zero = try source.readInt(u8);

        const size_in_bytes = try source.decodeVarint(u32);
        if (size_in_bytes > source.remaining()) return Error.Truncated;

        // data_head() region of length size_in_bytes, then Advance(size).
        const region = try source.readBytes(size_in_bytes);
        try self.ansReadInit(region);
    }

    /// Port of `ans_read_init` (ans.h). A non-zero C return maps to an Error.
    fn ansReadInit(self: *RAnsBitDecoder, region: []const u8) Error!void {
        const offset = region.len;
        if (offset < 1) return Error.Corrupt;
        self.buf = region;
        const x = region[offset - 1] >> 6;
        if (x == 0) {
            self.buf_offset = offset - 1;
            self.state = region[offset - 1] & 0x3F;
        } else if (x == 1) {
            if (offset < 2) return Error.Corrupt;
            self.buf_offset = offset - 2;
            self.state = memGetLe16(region[offset - 2 ..]) & 0x3FFF;
        } else if (x == 2) {
            if (offset < 3) return Error.Corrupt;
            self.buf_offset = offset - 3;
            self.state = memGetLe24(region[offset - 3 ..]) & 0x3FFFFF;
        } else {
            return Error.Corrupt;
        }
        self.state += ANS_L_BASE;
        if (self.state >= ANS_L_BASE * ANS_IO_BASE) return Error.Corrupt;
    }

    /// Port of `rabs_desc_read` + `RAnsBitDecoder::DecodeNextBit`.
    /// Cannot fail or read OOB (see `buf_offset` invariant above). Wrapping
    /// arithmetic mirrors C unsigned semantics and keeps malformed input from
    /// panicking; on a valid stream no wrap ever occurs.
    pub fn decodeNextBit(self: *RAnsBitDecoder) u1 {
        const p0: u32 = self.prob_zero;
        const p: u32 = ANS_P8_PRECISION - p0;
        if (self.state < ANS_L_BASE and self.buf_offset > 0) {
            self.buf_offset -= 1;
            self.state = self.state *% ANS_IO_BASE +% self.buf[self.buf_offset];
        }
        const xx = self.state;
        const quot = xx / ANS_P8_PRECISION;
        const rem = xx % ANS_P8_PRECISION;
        const xn = quot *% p;
        const val = rem < p;
        if (val) {
            self.state = xn +% rem;
        } else {
            self.state = xx -% xn -% p;
        }
        return if (val) 1 else 0;
    }

    /// Port of `RAnsBitDecoder::DecodeLeastSignificantBits32`. `nbits` must be
    /// > 0; the u5 type bounds it to <= 31 (Draco allows <= 32).
    pub fn decodeLeastSignificantBits32(self: *RAnsBitDecoder, nbits: u5) u32 {
        var n = nbits;
        var result: u32 = 0;
        while (n != 0) : (n -= 1) {
            result = (result << 1) + self.decodeNextBit();
        }
        return result;
    }

    /// Port of `EndDecoding` — a no-op (state is discarded).
    pub fn endDecoding(self: *RAnsBitDecoder) void {
        _ = self;
    }
};

// ── multi-symbol rANS symbol decoder ─────────────────────────────────────────
// Faithful port of Draco's multi-symbol rANS entropy decoder:
//   * `DecodeSymbols` / `DecodeTaggedSymbols` / `DecodeRawSymbols`
//     (`compression/entropy/symbol_decoding.cc`)
//   * `RAnsSymbolDecoder<>` (`rans_symbol_decoder.h`) — reads `num_symbols`, the
//     probability table (token bits + zero-run varints) and the rANS body.
//   * `RAnsDecoder<>::{read_init, rans_read, rans_build_look_up_table}` plus the
//     precision helpers (`ans.h`, `rans_symbol_coding.h`).
// This is a DIFFERENT code path from the binary rABS above: multi-symbol rANS
// with a runtime precision in [12,20] bits and `l_rans_base = precision * 4`
// (the binary path used a fixed L_BASE = 4096).
//
// Scratch (probability table + the rANS look-up table, up to 2^20 u32 entries)
// is allocated from an internal arena over `std.heap.page_allocator`. This
// decoder is build-time only (native asset pipeline), so a heap is available and
// the brief's fixed 4-arg public signature (no allocator) is preserved. All
// malformed input is bounds-checked into `Error`, never a panic.

const BitDecoder = @import("buffer.zig").BitDecoder;

const SYMBOL_CODING_TAGGED: u8 = 0;
const SYMBOL_CODING_RAW: u8 = 1;
const K_MAX_RAW_ENCODING_BIT_LENGTH: u8 = 18;

fn memGetLe32(m: []const u8) u32 {
    return @as(u32, m[0]) | (@as(u32, m[1]) << 8) | (@as(u32, m[2]) << 16) | (@as(u32, m[3]) << 24);
}

/// `ComputeRAnsPrecisionFromUniqueSymbolsBitLength` (`rans_symbol_coding.h`):
/// unclamped precision `(3 * bit_length) / 2` clamped to [12, 20].
fn ransPrecisionBits(symbols_bit_length: u32) u5 {
    const unclamped = (3 * symbols_bit_length) / 2;
    const clamped: u32 = if (unclamped < 12) 12 else if (unclamped > 20) 20 else unclamped;
    return @intCast(clamped);
}

const RansSym = struct { prob: u32 = 0, cum_prob: u32 = 0 };

/// Port of `RAnsSymbolDecoder<>` + the `RAnsDecoder<>` it embeds. Precision is a
/// runtime value here (the C++ template parameter), so the state constants
/// (`precision`, `l_rans_base`) are stored per instance.
const RansSymbolDecoder = struct {
    precision: u32,
    l_rans_base: u32,
    num_symbols: u32 = 0,
    prob_table: []RansSym = &.{},
    lut: []u32 = &.{},
    // Embedded AnsDecoder state.
    buf: []const u8 = &.{},
    buf_offset: usize = 0,
    state: u32 = 0,

    fn init(precision_bits: u5) RansSymbolDecoder {
        const precision = @as(u32, 1) << precision_bits;
        return .{ .precision = precision, .l_rans_base = precision *% 4 };
    }

    /// Port of `RAnsSymbolDecoder::Create`: decode `num_symbols`, the probability
    /// table and build the look-up table. Leaves `num_symbols == 0` un-built (the
    /// caller rejects that when `num_values > 0`, mirroring the C++).
    fn create(self: *RansSymbolDecoder, a: std.mem.Allocator, src: *DecoderBuffer) Error!void {
        self.num_symbols = try src.decodeVarint(u32);
        // Sanity bound from Draco: the table needs at least num_symbols/64 bytes.
        if (self.num_symbols / 64 > src.remaining()) return Error.Corrupt;
        if (self.num_symbols == 0) return;
        self.prob_table = try a.alloc(RansSym, self.num_symbols);
        for (self.prob_table) |*e| e.* = .{};

        var i: u32 = 0;
        while (i < self.num_symbols) : (i += 1) {
            const prob_data = try src.readInt(u8);
            const token: u32 = prob_data & 3;
            if (token == 3) {
                // Run-length of zero-probability entries.
                const offset: u32 = prob_data >> 2;
                if (i + offset >= self.num_symbols) return Error.Corrupt;
                var j: u32 = 0;
                while (j < offset + 1) : (j += 1) self.prob_table[i + j].prob = 0;
                i += offset;
            } else {
                const extra_bytes = token;
                var prob: u32 = prob_data >> 2;
                var b: u32 = 0;
                while (b < extra_bytes) : (b += 1) {
                    const eb = try src.readInt(u8);
                    prob |= @as(u32, eb) << @intCast(8 * (b + 1) - 2);
                }
                self.prob_table[i].prob = prob;
            }
        }
        try self.buildLookUpTable(a);
    }

    /// Port of `RAnsDecoder::rans_build_look_up_table`.
    fn buildLookUpTable(self: *RansSymbolDecoder, a: std.mem.Allocator) Error!void {
        self.lut = try a.alloc(u32, self.precision);
        var cum_prob: u32 = 0;
        var act_prob: u32 = 0;
        var i: u32 = 0;
        while (i < self.num_symbols) : (i += 1) {
            self.prob_table[i].cum_prob = cum_prob;
            cum_prob += self.prob_table[i].prob;
            if (cum_prob > self.precision) return Error.Corrupt;
            var j: u32 = act_prob;
            while (j < cum_prob) : (j += 1) self.lut[j] = i;
            act_prob = cum_prob;
        }
        if (cum_prob != self.precision) return Error.Corrupt;
    }

    /// Port of `RAnsSymbolDecoder::StartDecoding`: read the rANS body size, seed
    /// the decoder from the body tail, advance `src` past it.
    fn startDecoding(self: *RansSymbolDecoder, src: *DecoderBuffer) Error!void {
        const bytes_encoded = try src.decodeVarint(u64);
        if (bytes_encoded > src.remaining()) return Error.Truncated;
        const region = try src.readBytes(@intCast(bytes_encoded));
        try self.readInit(region);
    }

    /// Port of `RAnsDecoder::read_init` (includes the 4-byte `x == 3` state used
    /// by higher-precision streams — absent from the binary `ans_read_init`).
    fn readInit(self: *RansSymbolDecoder, region: []const u8) Error!void {
        const offset = region.len;
        if (offset < 1) return Error.Corrupt;
        self.buf = region;
        const x = region[offset - 1] >> 6;
        if (x == 0) {
            self.buf_offset = offset - 1;
            self.state = region[offset - 1] & 0x3F;
        } else if (x == 1) {
            if (offset < 2) return Error.Corrupt;
            self.buf_offset = offset - 2;
            self.state = memGetLe16(region[offset - 2 ..]) & 0x3FFF;
        } else if (x == 2) {
            if (offset < 3) return Error.Corrupt;
            self.buf_offset = offset - 3;
            self.state = memGetLe24(region[offset - 3 ..]) & 0x3FFFFF;
        } else { // x == 3
            if (offset < 4) return Error.Corrupt;
            self.buf_offset = offset - 4;
            self.state = memGetLe32(region[offset - 4 ..]) & 0x3FFFFFFF;
        }
        self.state += self.l_rans_base;
        if (self.state >= self.l_rans_base *% ANS_IO_BASE) return Error.Corrupt;
    }

    /// Port of `RAnsDecoder::rans_read` (== `DecodeSymbol`). Wrapping arithmetic
    /// mirrors C unsigned semantics; on a valid stream no wrap occurs, and the
    /// LUT/table indices are always in range (`rem < precision`, `sym <
    /// num_symbols`), so this can neither fault nor read OOB.
    fn decodeSymbol(self: *RansSymbolDecoder) u32 {
        while (self.state < self.l_rans_base and self.buf_offset > 0) {
            self.buf_offset -= 1;
            self.state = self.state *% ANS_IO_BASE +% self.buf[self.buf_offset];
        }
        const quo = self.state / self.precision;
        const rem = self.state % self.precision;
        const sym = self.lut[rem];
        const prob = self.prob_table[sym].prob;
        const cum = self.prob_table[sym].cum_prob;
        self.state = quo *% prob +% rem -% cum;
        return sym;
    }
};

/// Port of `DecodeSymbols` (`symbol_decoding.cc`). Decodes `num_values` unsigned
/// symbols into `out` (`out.len` must be >= `num_values`). `num_components` is
/// only used by the tagged scheme (one bit-length tag shared by a component
/// tuple).
pub fn decodeSymbols(buf: *DecoderBuffer, num_values: usize, num_components: u32, out: []u32) Error!void {
    if (num_values == 0) return;
    if (out.len < num_values) return Error.Corrupt;
    var nc = num_components;
    if (nc == 0) nc = 1;

    const scheme = try buf.readInt(u8);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    if (scheme == SYMBOL_CODING_TAGGED) {
        try decodeTaggedSymbols(a, buf, num_values, nc, out);
    } else if (scheme == SYMBOL_CODING_RAW) {
        try decodeRawSymbols(a, buf, num_values, out);
    } else {
        return Error.Corrupt;
    }
}

/// Port of `DecodeRawSymbols` + `DecodeRawSymbolsInternal`.
fn decodeRawSymbols(a: std.mem.Allocator, buf: *DecoderBuffer, num_values: usize, out: []u32) Error!void {
    const max_bit_length = try buf.readInt(u8);
    if (max_bit_length < 1 or max_bit_length > K_MAX_RAW_ENCODING_BIT_LENGTH) return Error.Corrupt;
    var dec = RansSymbolDecoder.init(ransPrecisionBits(max_bit_length));
    try dec.create(a, buf);
    if (dec.num_symbols == 0) return Error.Corrupt; // num_values > 0 here
    try dec.startDecoding(buf);
    for (0..num_values) |i| out[i] = dec.decodeSymbol();
}

/// Port of `DecodeTaggedSymbols`. A `SymbolDecoder<5>` recovers a per-tuple
/// bit-length tag; the actual component values then follow as raw LSB-first bit
/// fields in the remainder of the buffer.
fn decodeTaggedSymbols(a: std.mem.Allocator, buf: *DecoderBuffer, num_values: usize, nc: u32, out: []u32) Error!void {
    var tag = RansSymbolDecoder.init(ransPrecisionBits(5));
    try tag.create(a, buf);
    try tag.startDecoding(buf);
    if (tag.num_symbols == 0) return Error.Corrupt; // num_values > 0 here

    // `StartBitDecoding(false)` — a bit reader over the rest of the buffer.
    var bd = BitDecoder{ .data = buf.data[buf.pos..] };
    var value_id: usize = 0;
    var i: usize = 0;
    while (i < num_values) : (i += nc) {
        const bit_length = tag.decodeSymbol();
        if (bit_length > 32) return Error.Corrupt;
        var j: u32 = 0;
        while (j < nc) : (j += 1) {
            if (value_id >= num_values) return Error.Corrupt;
            out[value_id] = bd.readBits(@intCast(bit_length));
            value_id += 1;
        }
    }
    // `EndBitDecoding`: advance the parent past the consumed value bytes.
    buf.pos += (bd.bit_pos + 7) / 8;
}

// ── round-trip tests (the gate) ──────────────────────────────────────────────
const RAnsBitEncoder = @import("rans_test_encoder.zig").RAnsBitEncoder;

fn expectBitRoundTrip(bits: []const u1) !void {
    const a = std.testing.allocator;
    var enc = RAnsBitEncoder.init();
    defer enc.deinit(a);
    for (bits) |bit| try enc.encodeBit(a, bit);
    const blob = try enc.finish(a); // owned bytes
    defer a.free(blob);

    var buf = DecoderBuffer.init(blob);
    var dec: RAnsBitDecoder = undefined;
    try dec.startDecoding(&buf);
    for (bits) |bit| try std.testing.expectEqual(bit, dec.decodeNextBit());
    dec.endDecoding();
}

test "rabs round-trip: all zeros / all ones / alternating / skewed" {
    try expectBitRoundTrip(&[_]u1{ 0, 0, 0, 0, 0, 0, 0, 0 });
    try expectBitRoundTrip(&[_]u1{ 1, 1, 1, 1, 1, 1, 1, 1 });
    try expectBitRoundTrip(&[_]u1{ 0, 1, 0, 1, 0, 1, 0, 1 });
    var skewed: [200]u1 = undefined;
    for (&skewed, 0..) |*s, i| s.* = if (i % 17 == 0) 1 else 0;
    try expectBitRoundTrip(&skewed);
}

test "rabs decodeLeastSignificantBits32 round-trip" {
    const a = std.testing.allocator;
    var enc = RAnsBitEncoder.init();
    defer enc.deinit(a);
    try enc.encodeLeastSignificantBits32(a, 12, 0xABC);
    const blob = try enc.finish(a);
    defer a.free(blob);
    var buf = DecoderBuffer.init(blob);
    var dec: RAnsBitDecoder = undefined;
    try dec.startDecoding(&buf);
    try std.testing.expectEqual(@as(u32, 0xABC), dec.decodeLeastSignificantBits32(12));
    dec.endDecoding();
}

test "rabs round-trip: empty + spanning >32 bits + mixed LSB/bit" {
    // empty bit stream (encoder must still emit a valid, decodable blob)
    try expectBitRoundTrip(&[_]u1{});

    // 100 bits forces the encoder's 32-bit `bits_` word path + local remainder.
    var big: [100]u1 = undefined;
    for (&big, 0..) |*s, i| s.* = @intCast((i * 7 + 3) & 1);
    try expectBitRoundTrip(&big);

    // interleave individual bits with a multi-bit LSB field, then read back.
    const a = std.testing.allocator;
    var enc = RAnsBitEncoder.init();
    defer enc.deinit(a);
    try enc.encodeBit(a, 1);
    try enc.encodeLeastSignificantBits32(a, 5, 0b10110);
    try enc.encodeBit(a, 0);
    try enc.encodeLeastSignificantBits32(a, 20, 0xFACE & 0xFFFFF);
    const blob = try enc.finish(a);
    defer a.free(blob);
    var buf = DecoderBuffer.init(blob);
    var dec: RAnsBitDecoder = undefined;
    try dec.startDecoding(&buf);
    try std.testing.expectEqual(@as(u1, 1), dec.decodeNextBit());
    try std.testing.expectEqual(@as(u32, 0b10110), dec.decodeLeastSignificantBits32(5));
    try std.testing.expectEqual(@as(u1, 0), dec.decodeNextBit());
    try std.testing.expectEqual(@as(u32, 0xFACE & 0xFFFFF), dec.decodeLeastSignificantBits32(20));
    dec.endDecoding();
}

test "startDecoding rejects a truncated body" {
    // prob_zero=128, varint size=200, but no body bytes follow.
    var buf = DecoderBuffer.init(&[_]u8{ 128, 200, 1 });
    var dec: RAnsBitDecoder = undefined;
    try std.testing.expectError(Error.Truncated, dec.startDecoding(&buf));
}

// ── multi-symbol rANS round-trip (the gate) ──────────────────────────────────
const SymbolEncoder = @import("rans_test_encoder.zig").SymbolEncoder;

fn expectSymbolRoundTrip(vals: []const u32, num_components: u32) !void {
    const a = std.testing.allocator;
    const blob = try SymbolEncoder.encode(a, vals, num_components); // owned
    defer a.free(blob);
    var buf = DecoderBuffer.init(blob);
    const out = try a.alloc(u32, vals.len);
    defer a.free(out);
    try decodeSymbols(&buf, vals.len, num_components, out);
    try std.testing.expectEqualSlices(u32, vals, out);
}

test "symbols round-trip: uniform / skewed / single / large-values" {
    try expectSymbolRoundTrip(&[_]u32{ 3, 3, 3, 3, 3 }, 1);
    try expectSymbolRoundTrip(&[_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 }, 1);
    try expectSymbolRoundTrip(&[_]u32{7}, 1);
    try expectSymbolRoundTrip(&[_]u32{ 1000, 2, 999999, 0, 65535 }, 1);
}

test "symbols round-trip: multi-component" {
    try expectSymbolRoundTrip(&[_]u32{ 10, 20, 30, 11, 21, 31 }, 3);
}

test "symbols empty" {
    try expectSymbolRoundTrip(&[_]u32{}, 1);
}
