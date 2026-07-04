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

    pub fn start(self: *TraversalDecoder, buf: *DecoderBuffer) Error!void {
        // StartBitDecoding(decode_size=true): varint byte size, then that region.
        const size = try buf.decodeVarint(u32);
        self.symbols = try buf.bitDecoder(size);
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
