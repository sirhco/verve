//! Test-only paired encoder — a faithful port of Draco's `RAnsBitEncoder`
//! (`src/draco/compression/bit_coders/rans_bit_encoder.{h,cc}`) plus the
//! `rabs_desc_write` / `ans_write_init` / `ans_write_end` primitives and
//! `EncodeVarint` from Draco. It exists solely to produce the exact byte layout
//! `RAnsBitDecoder.startDecoding` consumes, so a round-trip proves the decoder.
//!
//! Not part of the shipping decode path; imported only from `rans.zig`'s tests.

const std = @import("std");

// ── rANS constants (ans.h), identical to the decoder side ────────────────────
const ANS_P8_PRECISION: u32 = 256;
const ANS_L_BASE: u32 = 4096;
const ANS_IO_BASE: u32 = 256;

fn memPutLe16(m: []u8, val: u32) void {
    m[0] = @intCast(val & 0xff);
    m[1] = @intCast((val >> 8) & 0xff);
}
fn memPutLe24(m: []u8, val: u32) void {
    m[0] = @intCast(val & 0xff);
    m[1] = @intCast((val >> 8) & 0xff);
    m[2] = @intCast((val >> 16) & 0xff);
}

// AnsCoder (ans.h): forward-writing byte buffer + rANS state.
const AnsCoder = struct {
    buf: []u8,
    buf_offset: usize,
    state: u32,
};

/// Port of `rabs_desc_write` (ans.h). `bit` takes the place of `val`.
fn rabsWrite(ans: *AnsCoder, bit: u1, p0: u8) void {
    const p: u32 = ANS_P8_PRECISION - @as(u32, p0);
    const l_s: u32 = if (bit != 0) p else @as(u32, p0);
    // L_BASE / P8_PRECISION * IO_BASE * l_s == 16 * 256 * l_s.
    if (ans.state >= (ANS_L_BASE / ANS_P8_PRECISION) * ANS_IO_BASE * l_s) {
        ans.buf[ans.buf_offset] = @intCast(ans.state % ANS_IO_BASE);
        ans.buf_offset += 1;
        ans.state /= ANS_IO_BASE;
    }
    const quot = ans.state / l_s;
    const rem = ans.state % l_s;
    ans.state = quot * ANS_P8_PRECISION + rem + (if (bit != 0) @as(u32, 0) else p);
}

/// Port of `ans_write_end` (ans.h). Returns the total encoded size in bytes.
fn ansWriteEnd(ans: *AnsCoder) usize {
    const state = ans.state - ANS_L_BASE;
    if (state < (1 << 6)) {
        ans.buf[ans.buf_offset] = @intCast((0 << 6) + state);
        return ans.buf_offset + 1;
    } else if (state < (1 << 14)) {
        memPutLe16(ans.buf[ans.buf_offset..], (@as(u32, 1) << 14) + state);
        return ans.buf_offset + 2;
    } else if (state < (1 << 22)) {
        memPutLe24(ans.buf[ans.buf_offset..], (@as(u32, 2) << 22) + state);
        return ans.buf_offset + 3;
    } else {
        // "State is too large to be serialized" — unreachable for our sizes.
        return ans.buf_offset;
    }
}

/// Port of Draco `CopyBits32` (bit_utils.h). Copies `nbits` from `src` (starting
/// at `src_offset`) into `dst` at `dst_offset`. All shift amounts stay < 32.
fn copyBits32(dst: *u32, dst_offset: u6, src: u32, src_offset: u6, nbits: u6) void {
    const mask: u32 = (~@as(u32, 0) >> @intCast(32 - nbits)) << @intCast(dst_offset);
    dst.* = (dst.* & ~mask) | (((src >> @intCast(src_offset)) << @intCast(dst_offset)) & mask);
}

/// Standard unsigned LEB128 varint (matches Draco `EncodeVarint`).
fn encodeVarintU32(out: *std.ArrayList(u8), a: std.mem.Allocator, value: u32) !void {
    var v = value;
    while (v >= 0x80) {
        try out.append(a, @intCast((v & 0x7f) | 0x80));
        v >>= 7;
    }
    try out.append(a, @intCast(v));
}

/// Faithful port of Draco `RAnsBitEncoder`.
pub const RAnsBitEncoder = struct {
    bit_counts: [2]u64 = .{ 0, 0 },
    bits: std.ArrayList(u32) = .empty,
    local_bits: u32 = 0,
    num_local_bits: u32 = 0,

    pub fn init() RAnsBitEncoder {
        return .{};
    }

    pub fn deinit(self: *RAnsBitEncoder, a: std.mem.Allocator) void {
        self.bits.deinit(a);
    }

    /// Port of `EncodeBit`.
    pub fn encodeBit(self: *RAnsBitEncoder, a: std.mem.Allocator, bit: u1) !void {
        if (bit != 0) {
            self.bit_counts[1] += 1;
            self.local_bits |= @as(u32, 1) << @intCast(self.num_local_bits);
        } else {
            self.bit_counts[0] += 1;
        }
        self.num_local_bits += 1;
        if (self.num_local_bits == 32) {
            try self.bits.append(a, self.local_bits);
            self.num_local_bits = 0;
            self.local_bits = 0;
        }
    }

    /// Port of `EncodeLeastSignificantBits32`. `nbits` in (0, 32].
    pub fn encodeLeastSignificantBits32(self: *RAnsBitEncoder, a: std.mem.Allocator, nbits: u6, value: u32) !void {
        const reversed: u32 = @bitReverse(value) >> @intCast(32 - nbits);
        const ones: u64 = @popCount(reversed);
        self.bit_counts[0] += nbits - ones;
        self.bit_counts[1] += ones;

        const remaining: u32 = 32 - self.num_local_bits;

        if (nbits <= remaining) {
            copyBits32(&self.local_bits, @intCast(self.num_local_bits), reversed, 0, nbits);
            self.num_local_bits += nbits;
            if (self.num_local_bits == 32) {
                try self.bits.append(a, self.local_bits);
                self.local_bits = 0;
                self.num_local_bits = 0;
            }
        } else {
            copyBits32(&self.local_bits, @intCast(self.num_local_bits), reversed, 0, @intCast(remaining));
            try self.bits.append(a, self.local_bits);
            self.local_bits = 0;
            copyBits32(&self.local_bits, 0, reversed, @intCast(remaining), @intCast(nbits - remaining));
            self.num_local_bits = nbits - remaining;
        }
    }

    /// Port of `EndEncoding`: computes the static zero probability, flushes all
    /// bits through rABS (in reverse), and returns the owned wire blob
    /// `[prob_zero][varint size][rANS body]`. Caller owns the result.
    pub fn finish(self: *RAnsBitEncoder, a: std.mem.Allocator) ![]u8 {
        var total: u64 = self.bit_counts[1] + self.bit_counts[0];
        if (total == 0) total += 1;

        // zero_prob_raw = round( (bit_counts[0]/total) * 256 ), clamped to [1,255].
        const frac = @as(f64, @floatFromInt(self.bit_counts[0])) / @as(f64, @floatFromInt(total));
        const zero_prob_raw: u32 = @intFromFloat(frac * 256.0 + 0.5);
        var zero_prob: u8 = 255;
        if (zero_prob_raw < 255) zero_prob = @intCast(zero_prob_raw);
        if (zero_prob == 0) zero_prob += 1;

        // Space for 32-bit integer and some extra space (matches Draco sizing).
        const body = try a.alloc(u8, (self.bits.items.len + 8) * 8);
        defer a.free(body);
        var coder = AnsCoder{ .buf = body, .buf_offset = 0, .state = ANS_L_BASE };

        // Flush the trailing partial word, MSB-first, then each full word in
        // reverse — mirrors Draco's `EndEncoding`.
        if (self.num_local_bits > 0) {
            var i: i64 = @as(i64, self.num_local_bits) - 1;
            while (i >= 0) : (i -= 1) {
                const bit: u1 = @intCast((self.local_bits >> @intCast(i)) & 1);
                rabsWrite(&coder, bit, zero_prob);
            }
        }
        var w: usize = self.bits.items.len;
        while (w > 0) {
            w -= 1;
            const word = self.bits.items[w];
            var i: i64 = 31;
            while (i >= 0) : (i -= 1) {
                const bit: u1 = @intCast((word >> @intCast(i)) & 1);
                rabsWrite(&coder, bit, zero_prob);
            }
        }

        const size_in_bytes = ansWriteEnd(&coder);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        try out.append(a, zero_prob);
        try encodeVarintU32(&out, a, @intCast(size_in_bytes));
        try out.appendSlice(a, body[0..size_in_bytes]);
        return out.toOwnedSlice(a);
    }
};
