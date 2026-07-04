//! Test-only paired encoder — a faithful port of Draco's `RAnsBitEncoder`
//! (`src/draco/compression/bit_coders/rans_bit_encoder.{h,cc}`) plus the
//! `rabs_desc_write` / `ans_write_init` / `ans_write_end` primitives and
//! `EncodeVarint` from Draco. It exists solely to produce the exact byte layout
//! `RAnsBitDecoder.startDecoding` consumes, so a round-trip proves the decoder.
//!
//! Not part of the shipping decode path; imported only from `rans.zig`'s tests.

const std = @import("std");
const draco = @import("draco.zig");
const Error = draco.Error;

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

// ═══════════════════════════════════════════════════════════════════════════
// Multi-symbol rANS symbol encoder — a faithful, INDEPENDENT port of Draco's
// `EncodeSymbols` (`compression/entropy/symbol_encoding.cc`), `RAnsSymbolEncoder`
// (`rans_symbol_encoder.h`) and the `RAnsEncoder<>::{write_init, rans_write,
// write_end}` primitives (`ans.h`). It is NOT a mirror of the decoder: it picks
// RAW vs TAGGED via Draco's own heuristic (Shannon-entropy estimate), rescales
// the frequency table into a valid rANS probability table and runs the forward
// rANS coder. This is what makes the round-trip in `rans.zig` a real gate.
//
// Test-only; imported only from `rans.zig`'s tests.
// ═══════════════════════════════════════════════════════════════════════════

const SYMBOL_CODING_TAGGED: u8 = 0;
const SYMBOL_CODING_RAW: u8 = 1;
const K_MAX_TAG_SYMBOL_BIT_LENGTH: u32 = 32;
const K_MAX_RAW_ENCODING_BIT_LENGTH: i32 = 18;
// kDefaultSymbolCodingCompressionLevel = 7 -> the bit-length adjustment in
// EncodeRawSymbols is a no-op (7 is not < 4, < 6, > 7 or > 9), so it is omitted.

fn mostSignificantBit(n: u32) u32 {
    // Defined for n > 0 (matches Draco `MostSignificantBit`).
    return @as(u32, 31) - @as(u32, @clz(n));
}

fn ransPrecisionBits(symbols_bit_length: u32) u5 {
    const unclamped = (3 * symbols_bit_length) / 2;
    const clamped: u32 = if (unclamped < 12) 12 else if (unclamped > 20) 20 else unclamped;
    return @intCast(clamped);
}

fn memPutLe32(m: []u8, val: u32) void {
    m[0] = @intCast(val & 0xff);
    m[1] = @intCast((val >> 8) & 0xff);
    m[2] = @intCast((val >> 16) & 0xff);
    m[3] = @intCast((val >> 24) & 0xff);
}

fn encodeVarintU64(out: *std.ArrayList(u8), a: std.mem.Allocator, value: u64) !void {
    var v = value;
    while (v >= 0x80) {
        try out.append(a, @intCast((v & 0x7f) | 0x80));
        v >>= 7;
    }
    try out.append(a, @intCast(v));
}

const RansSymE = struct { prob: u32 = 0, cum_prob: u32 = 0 };

/// Port of `ComputeShannonEntropy` (`shannon_entropy.cc`). Returns
/// `static_cast<int64_t>(-total_bits)` and the number of unique symbols.
fn computeShannonEntropy(a: std.mem.Allocator, symbols: []const u32, max_value: u32, out_num_unique: *i32) Error!i64 {
    const freq = try a.alloc(i32, @as(usize, max_value) + 1);
    defer a.free(freq);
    @memset(freq, 0);
    for (symbols) |s| freq[s] += 1;
    var total_bits: f64 = 0;
    const num_symbols_d: f64 = @floatFromInt(symbols.len);
    var num_unique: i32 = 0;
    for (0..@as(usize, max_value) + 1) |i| {
        if (freq[i] > 0) {
            num_unique += 1;
            total_bits += @as(f64, @floatFromInt(freq[i])) * @log2(@as(f64, @floatFromInt(freq[i])) / num_symbols_d);
        }
    }
    out_num_unique.* = num_unique;
    return @intFromFloat(-total_bits);
}

/// Port of `ApproximateRAnsFrequencyTableBits` (`rans_symbol_coding.h`).
fn approximateRAnsFrequencyTableBits(max_value: i64, num_unique_symbols: i32) i64 {
    const nu: i64 = num_unique_symbols;
    const table_zero_frequency_bits = 8 * (nu + @divTrunc(max_value - nu, 64));
    return 8 * nu + table_zero_frequency_bits;
}

/// Port of `ApproximateTaggedSchemeBits`.
fn approximateTaggedSchemeBits(a: std.mem.Allocator, bit_lengths: []const u32, num_components: u32) Error!i64 {
    var total_bit_length: u64 = 0;
    for (bit_lengths) |bl| total_bit_length += bl;
    var num_unique: i32 = 0;
    const tag_bits = try computeShannonEntropy(a, bit_lengths, K_MAX_TAG_SYMBOL_BIT_LENGTH, &num_unique);
    const tag_table_bits = approximateRAnsFrequencyTableBits(num_unique, num_unique);
    return tag_bits + tag_table_bits + @as(i64, @intCast(total_bit_length)) * @as(i64, num_components);
}

/// Port of `ApproximateRawSchemeBits`.
fn approximateRawSchemeBits(a: std.mem.Allocator, symbols: []const u32, max_value: u32, out_num_unique: *i32) Error!i64 {
    var num_unique: i32 = 0;
    const data_bits = try computeShannonEntropy(a, symbols, max_value, &num_unique);
    const table_bits = approximateRAnsFrequencyTableBits(@intCast(max_value), num_unique);
    out_num_unique.* = num_unique;
    return table_bits + data_bits;
}

/// Port of `RAnsSymbolEncoder<>` + the `RAnsEncoder<>` it embeds. Precision is a
/// runtime value (the C++ template parameter). Output goes to two places: the
/// probability table is written straight to `out`, while the rANS body is built
/// in a scratch buffer and appended (with its varint size prefix) by
/// `endEncoding` — byte-identical to Draco's in-place memmove.
const SymEncoder = struct {
    precision: u32,
    precision_bits: u5,
    l_rans_base: u32,
    num_symbols: u32 = 0,
    table: []RansSymE = &.{},
    body: []u8 = &.{},
    body_offset: usize = 0,
    state: u32 = 0,

    fn init(precision_bits: u5) SymEncoder {
        const precision = @as(u32, 1) << precision_bits;
        return .{ .precision = precision, .precision_bits = precision_bits, .l_rans_base = precision *% 4 };
    }

    /// Port of `RAnsSymbolEncoder::Create`: build the rANS probability table from
    /// the raw frequencies (rescale to sum == precision) and encode it to `out`.
    fn create(self: *SymEncoder, sa: std.mem.Allocator, a: std.mem.Allocator, out: *std.ArrayList(u8), frequencies: []const u64) Error!void {
        var total_freq: u64 = 0;
        var max_valid_symbol: usize = 0;
        for (frequencies, 0..) |f, idx| {
            total_freq += f;
            if (f > 0) max_valid_symbol = idx;
        }
        const num_symbols: u32 = @intCast(max_valid_symbol + 1);
        self.num_symbols = num_symbols;
        self.table = try sa.alloc(RansSymE, num_symbols);
        for (self.table) |*e| e.* = .{};

        const total_freq_d: f64 = @floatFromInt(total_freq);
        const precision_d: f64 = @floatFromInt(self.precision);
        var total_rans_prob: i64 = 0;
        for (0..num_symbols) |i| {
            const freq = frequencies[i];
            const prob = @as(f64, @floatFromInt(freq)) / total_freq_d;
            var rans_prob: u32 = @intFromFloat(prob * precision_d + 0.5);
            if (rans_prob == 0 and freq > 0) rans_prob = 1;
            self.table[i].prob = rans_prob;
            total_rans_prob += rans_prob;
        }
        if (total_rans_prob != @as(i64, self.precision)) {
            try self.rescaleProbabilities(sa, total_rans_prob);
        }

        // Cumulative probabilities.
        var total_prob: u32 = 0;
        for (0..num_symbols) |i| {
            self.table[i].cum_prob = total_prob;
            total_prob += self.table[i].prob;
        }
        if (total_prob != self.precision) return Error.Corrupt;

        try self.encodeTable(a, out);
    }

    /// Port of the rounding-error fix-up in `RAnsSymbolEncoder::Create`: sort
    /// symbol ids by probability (stable) and add/remove precision so the total
    /// equals `precision` exactly.
    fn rescaleProbabilities(self: *SymEncoder, a: std.mem.Allocator, total_in: i64) Error!void {
        const n = self.num_symbols;
        const sorted = try a.alloc(u32, n);
        defer a.free(sorted);
        for (0..n) |i| sorted[i] = @intCast(i);
        // std::stable_sort by prob asc == unstable sort with an index tiebreak.
        std.sort.pdq(u32, sorted, self.table, struct {
            fn lt(table: []RansSymE, x: u32, y: u32) bool {
                if (table[x].prob != table[y].prob) return table[x].prob < table[y].prob;
                return x < y;
            }
        }.lt);

        var total_rans_prob = total_in;
        if (total_rans_prob < @as(i64, self.precision)) {
            // Give the shortfall to the most frequent symbol.
            const add: u32 = @intCast(@as(i64, self.precision) - total_rans_prob);
            self.table[sorted[n - 1]].prob += add;
        } else {
            // Over-allocated: rescale symbols from least to most frequent.
            var err: i64 = total_rans_prob - @as(i64, self.precision);
            const precision_d: f64 = @floatFromInt(self.precision);
            while (err > 0) {
                const act_total_prob_d: f64 = @floatFromInt(total_rans_prob);
                const act_rel_error_d = precision_d / act_total_prob_d;
                var j: usize = n - 1;
                while (j > 0) : (j -= 1) {
                    const symbol_id = sorted[j];
                    const prob = self.table[symbol_id].prob;
                    if (prob <= 1) {
                        if (j == n - 1) return Error.Corrupt; // most frequent would be empty
                        break;
                    }
                    const new_prob: i32 = @intFromFloat(@floor(act_rel_error_d * @as(f64, @floatFromInt(prob))));
                    var fix: i32 = @as(i32, @intCast(prob)) - new_prob;
                    if (fix == 0) fix = 1;
                    if (fix >= @as(i32, @intCast(prob))) fix = @as(i32, @intCast(prob)) - 1;
                    if (fix > err) fix = @intCast(err);
                    self.table[symbol_id].prob -= @intCast(fix);
                    total_rans_prob -= fix;
                    err -= fix;
                    if (total_rans_prob == @as(i64, self.precision)) break;
                }
            }
        }
    }

    /// Port of `RAnsSymbolEncoder::EncodeTable`.
    fn encodeTable(self: *SymEncoder, a: std.mem.Allocator, out: *std.ArrayList(u8)) Error!void {
        try encodeVarintU32(out, a, self.num_symbols);
        var i: u32 = 0;
        while (i < self.num_symbols) : (i += 1) {
            const prob = self.table[i].prob;
            var num_extra_bytes: u32 = 0;
            if (prob >= (1 << 6)) {
                num_extra_bytes += 1;
                if (prob >= (1 << 14)) {
                    num_extra_bytes += 1;
                    if (prob >= (1 << 22)) return Error.Corrupt;
                }
            }
            if (prob == 0) {
                // Run-length of zero-probability symbols (max run 63).
                var offset: u32 = 0;
                while (offset < (1 << 6) - 1) : (offset += 1) {
                    const next_prob = self.table[i + offset + 1].prob;
                    if (next_prob > 0) break;
                }
                try out.append(a, @intCast((offset << 2) | 3));
                i += offset;
            } else {
                try out.append(a, @intCast(((prob << 2) | (num_extra_bytes & 3)) & 0xFF));
                var b: u32 = 0;
                while (b < num_extra_bytes) : (b += 1) {
                    try out.append(a, @intCast((prob >> @intCast(8 * (b + 1) - 2)) & 0xFF));
                }
            }
        }
    }

    /// Port of `RAnsEncoder::write_init` (with a scratch body sized for
    /// `num_values` symbols).
    fn startEncoding(self: *SymEncoder, a: std.mem.Allocator, num_values: usize) Error!void {
        // <= ceil(precision_bits/8)+1 bytes per symbol, plus write_end's 4.
        const per_symbol: usize = (@as(usize, self.precision_bits) + 7) / 8 + 1;
        self.body = try a.alloc(u8, num_values * per_symbol + 64);
        self.body_offset = 0;
        self.state = self.l_rans_base;
    }

    /// Port of `RAnsEncoder::rans_write` (== `EncodeSymbol`).
    fn encodeSymbol(self: *SymEncoder, symbol: u32) void {
        const p = self.table[symbol].prob;
        const cum = self.table[symbol].cum_prob;
        while (self.state >= (self.l_rans_base / self.precision) * ANS_IO_BASE * p) {
            self.body[self.body_offset] = @intCast(self.state % ANS_IO_BASE);
            self.body_offset += 1;
            self.state /= ANS_IO_BASE;
        }
        self.state = (self.state / p) * self.precision + self.state % p + cum;
    }

    /// Port of `RAnsSymbolEncoder::EndEncoding`: finalize the rANS state
    /// (`write_end`) and append `varint(bytes_written)` + body to `out`.
    fn endEncoding(self: *SymEncoder, a: std.mem.Allocator, out: *std.ArrayList(u8)) Error!void {
        const bytes_written = self.writeEnd();
        try encodeVarintU64(out, a, bytes_written);
        try out.appendSlice(a, self.body[0..bytes_written]);
    }

    /// Port of `RAnsEncoder::write_end` (includes the 4-byte case for higher
    /// precisions).
    fn writeEnd(self: *SymEncoder) usize {
        const st = self.state - self.l_rans_base;
        if (st < (1 << 6)) {
            self.body[self.body_offset] = @intCast(st);
            return self.body_offset + 1;
        } else if (st < (1 << 14)) {
            memPutLe16(self.body[self.body_offset..], (@as(u32, 1) << 14) + st);
            return self.body_offset + 2;
        } else if (st < (1 << 22)) {
            memPutLe24(self.body[self.body_offset..], (@as(u32, 2) << 22) + st);
            return self.body_offset + 3;
        } else {
            memPutLe32(self.body[self.body_offset..], (@as(u32, 3) << 30) +% st);
            return self.body_offset + 4;
        }
    }
};

/// LSB-first bit writer for the tagged scheme's value fields — the inverse of
/// `buffer.zig`'s `BitDecoder`, matching Draco's `EncoderBuffer::BitEncoder`.
const BitWriter = struct {
    bytes: std.ArrayList(u8) = .empty,
    bit_pos: usize = 0,

    fn deinit(self: *BitWriter, a: std.mem.Allocator) void {
        self.bytes.deinit(a);
    }

    fn putBit(self: *BitWriter, a: std.mem.Allocator, bit: u1) !void {
        const byte_i = self.bit_pos >> 3;
        if (byte_i >= self.bytes.items.len) try self.bytes.append(a, 0);
        if (bit != 0) self.bytes.items[byte_i] |= @as(u8, 1) << @intCast(self.bit_pos & 7);
        self.bit_pos += 1;
    }

    fn putBits(self: *BitWriter, a: std.mem.Allocator, value: u32, nbits: u32) !void {
        var bit: u32 = 0;
        while (bit < nbits) : (bit += 1) {
            try self.putBit(a, @intCast((value >> @intCast(bit)) & 1));
        }
    }
};

/// Faithful port of Draco `EncodeSymbols`. Public test entry point: encodes
/// `vals` (unsigned symbols, `num_components` per tuple) into a self-contained
/// blob that `decodeSymbols` consumes. Caller owns the returned slice.
pub const SymbolEncoder = struct {
    pub fn encode(a: std.mem.Allocator, vals: []const u32, num_components: u32) Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        // All scratch lives in an arena over `a`; the returned blob is owned by `a`.
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        try encodeSymbols(a, arena.allocator(), &out, vals, num_components);
        return out.toOwnedSlice(a);
    }
};

fn encodeSymbols(a: std.mem.Allocator, sa: std.mem.Allocator, out: *std.ArrayList(u8), symbols: []const u32, num_components_in: u32) Error!void {
    if (symbols.len == 0) return; // EncodeSymbols: num_values == 0 -> empty output.
    var num_components = num_components_in;
    if (num_components == 0) num_components = 1;
    const num_values = symbols.len;

    // ComputeBitLengths: one bit-length per component tuple + overall max value.
    var bit_lengths: std.ArrayList(u32) = .empty;
    defer bit_lengths.deinit(sa);
    var max_value: u32 = 0;
    {
        var i: usize = 0;
        while (i < num_values) : (i += num_components) {
            var max_component: u32 = symbols[i];
            var j: usize = 1;
            while (j < num_components) : (j += 1) {
                if (i + j < num_values and max_component < symbols[i + j]) max_component = symbols[i + j];
            }
            var msb: u32 = 0;
            if (max_component > 0) msb = mostSignificantBit(max_component);
            if (max_component > max_value) max_value = max_component;
            try bit_lengths.append(sa, msb + 1);
        }
    }

    // Choose RAW vs TAGGED with Draco's heuristic.
    const tagged_scheme_total_bits = try approximateTaggedSchemeBits(sa, bit_lengths.items, num_components);
    var num_unique_symbols: i32 = 0;
    const raw_scheme_total_bits = try approximateRawSchemeBits(sa, symbols, max_value, &num_unique_symbols);
    const max_value_bit_length: i32 = @as(i32, @intCast(mostSignificantBit(@max(1, max_value)))) + 1;

    const method: u8 = if (tagged_scheme_total_bits < raw_scheme_total_bits or max_value_bit_length > K_MAX_RAW_ENCODING_BIT_LENGTH)
        SYMBOL_CODING_TAGGED
    else
        SYMBOL_CODING_RAW;

    try out.append(a, method);
    if (method == SYMBOL_CODING_TAGGED) {
        try encodeTaggedSymbols(a, sa, out, symbols, num_components, bit_lengths.items);
    } else {
        try encodeRawSymbols(a, sa, out, symbols, max_value, num_unique_symbols);
    }
}

/// Port of `EncodeTaggedSymbols`. Tags (bit lengths) are rANS-coded in reverse;
/// the component values follow as LSB-first bit fields (forward order).
fn encodeTaggedSymbols(a: std.mem.Allocator, sa: std.mem.Allocator, out: *std.ArrayList(u8), symbols: []const u32, num_components: u32, bit_lengths: []const u32) Error!void {
    // Frequency of each bit length. Draco uses kMaxTagSymbolBitLength (32) slots;
    // we keep a 33rd guard slot so a (rare, Draco-UB) bit_length of 32 cannot OOB
    // — self-consistent with the decoder either way.
    var frequencies = [_]u64{0} ** (K_MAX_TAG_SYMBOL_BIT_LENGTH + 1);
    for (bit_lengths) |bl| frequencies[@min(bl, K_MAX_TAG_SYMBOL_BIT_LENGTH)] += 1;

    var tag = SymEncoder.init(ransPrecisionBits(5));
    try tag.create(sa, a, out, frequencies[0..]);
    try tag.startEncoding(sa, bit_lengths.len);
    // needs_reverse_encoding(): encode tags last-to-first.
    var i: usize = bit_lengths.len;
    while (i > 0) {
        i -= 1;
        tag.encodeSymbol(bit_lengths[i]);
    }
    try tag.endEncoding(a, out);

    // Value bit fields, forward order.
    var vb = BitWriter{};
    defer vb.deinit(sa);
    var chunk: usize = 0;
    var vi: usize = 0;
    while (vi < symbols.len) : (vi += num_components) {
        const bl = bit_lengths[chunk];
        chunk += 1;
        var c: usize = 0;
        while (c < num_components) : (c += 1) {
            if (vi + c < symbols.len) try vb.putBits(sa, symbols[vi + c], bl);
        }
    }
    try out.appendSlice(a, vb.bytes.items);
}

/// Port of `EncodeRawSymbols` + `EncodeRawSymbolsInternal`.
fn encodeRawSymbols(a: std.mem.Allocator, sa: std.mem.Allocator, out: *std.ArrayList(u8), symbols: []const u32, max_entry_value: u32, num_unique_symbols: i32) Error!void {
    var symbol_bits: u32 = 0;
    if (num_unique_symbols > 0) symbol_bits = mostSignificantBit(@intCast(num_unique_symbols));
    var unique_symbols_bit_length: i32 = @as(i32, @intCast(symbol_bits)) + 1;
    if (unique_symbols_bit_length > K_MAX_RAW_ENCODING_BIT_LENGTH) return Error.Corrupt;
    // compression_level 7 -> no bit-length adjustment (see note above).
    if (unique_symbols_bit_length < 1) unique_symbols_bit_length = 1;
    if (unique_symbols_bit_length > K_MAX_RAW_ENCODING_BIT_LENGTH) unique_symbols_bit_length = K_MAX_RAW_ENCODING_BIT_LENGTH;

    try out.append(a, @intCast(unique_symbols_bit_length));

    // Frequency of each entry value (0..max_entry_value).
    const frequencies = try sa.alloc(u64, @as(usize, max_entry_value) + 1);
    @memset(frequencies, 0);
    for (symbols) |s| frequencies[s] += 1;

    var enc = SymEncoder.init(ransPrecisionBits(@intCast(unique_symbols_bit_length)));
    try enc.create(sa, a, out, frequencies);
    try enc.startEncoding(sa, symbols.len);
    // needs_reverse_encoding(): encode values last-to-first.
    var i: usize = symbols.len;
    while (i > 0) {
        i -= 1;
        enc.encodeSymbol(symbols[i]);
    }
    try enc.endEncoding(a, out);
}
