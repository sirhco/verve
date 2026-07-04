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
