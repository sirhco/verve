const std = @import("std");
const draco = @import("draco.zig");
pub const Error = draco.Error;

/// Cursor over a Draco byte stream. All reads are bounds-checked.
pub const DecoderBuffer = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) DecoderBuffer {
        return .{ .data = data };
    }

    pub fn remaining(self: *const DecoderBuffer) usize {
        return self.data.len - self.pos;
    }

    pub fn skip(self: *DecoderBuffer, n: usize) Error!void {
        if (n > self.remaining()) return Error.Truncated;
        self.pos += n;
    }

    pub fn readBytes(self: *DecoderBuffer, n: usize) Error![]const u8 {
        if (n > self.remaining()) return Error.Truncated;
        const out = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return out;
    }

    pub fn readInt(self: *DecoderBuffer, comptime T: type) Error!T {
        const n = @sizeOf(T);
        if (n > self.remaining()) return Error.Truncated;
        const v = std.mem.readInt(T, self.data[self.pos..][0..n], .little);
        self.pos += n;
        return v;
    }

    /// Unsigned LEB128 varint (7 bits/byte, MSB = continue).
    pub fn decodeVarint(self: *DecoderBuffer, comptime T: type) Error!T {
        var result: T = 0;
        var shift: std.math.Log2Int(T) = 0;
        while (true) {
            if (self.remaining() == 0) return Error.Truncated;
            const byte = self.data[self.pos];
            self.pos += 1;
            result |= @as(T, @intCast(byte & 0x7f)) << shift;
            if (byte & 0x80 == 0) break;
            shift = std.math.add(std.math.Log2Int(T), shift, 7) catch return Error.Corrupt;
        }
        return result;
    }

    /// Signed varint = unsigned varint + zigzag decode ((v>>1) ^ -(v&1)).
    pub fn decodeVarintSigned(self: *DecoderBuffer, comptime T: type) Error!T {
        const U = std.meta.Int(.unsigned, @bitSizeOf(T));
        const u = try self.decodeVarint(U);
        const s: T = @bitCast(u >> 1);
        return s ^ -@as(T, @intCast(u & 1));
    }

    pub fn bitDecoder(self: *DecoderBuffer, byte_len: usize) Error!BitDecoder {
        const region = try self.readBytes(byte_len); // advances the parent
        return BitDecoder{ .data = region };
    }
};

/// LSB-first bit reader over a fixed byte range (Draco bit-decoding regions).
pub const BitDecoder = struct {
    data: []const u8,
    bit_pos: usize = 0,

    pub fn readBit(self: *BitDecoder) u1 {
        const byte_i = self.bit_pos >> 3;
        if (byte_i >= self.data.len) return 0; // Draco pads with zeros past the end
        const shift: u3 = @intCast(self.bit_pos & 7);
        self.bit_pos += 1;
        return @intCast((self.data[byte_i] >> shift) & 1);
    }

    pub fn readBits(self: *BitDecoder, n: u6) u32 {
        const nn = @min(n, 32);
        var out: u32 = 0;
        var i: u6 = 0;
        while (i < nn) : (i += 1) out |= @as(u32, self.readBit()) << @intCast(i);
        return out;
    }
};

test "readInt little-endian + bounds" {
    var b = DecoderBuffer.init(&[_]u8{ 0x04, 0x02, 0x00, 0x00, 0xff });
    try std.testing.expectEqual(@as(u32, 0x0204), try b.readInt(u32));
    try std.testing.expectEqual(@as(u8, 0xff), try b.readInt(u8));
    try std.testing.expectError(Error.Truncated, b.readInt(u8));
}

test "decodeVarint unsigned LEB128 boundaries" {
    const cases = [_]struct { bytes: []const u8, val: u32 }{
        .{ .bytes = &[_]u8{0x00}, .val = 0 },
        .{ .bytes = &[_]u8{0x7f}, .val = 127 },
        .{ .bytes = &[_]u8{ 0x80, 0x01 }, .val = 128 },
        .{ .bytes = &[_]u8{ 0xff, 0x7f }, .val = 16383 },
    };
    for (cases) |c| {
        var b = DecoderBuffer.init(c.bytes);
        try std.testing.expectEqual(c.val, try b.decodeVarint(u32));
    }
}

test "decodeVarintSigned zigzag" {
    // zigzag: 0->0, 1->-1, 2->1, 3->-2, 4->2
    const enc = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04 };
    const want = [_]i32{ 0, -1, 1, -2, 2 };
    var b = DecoderBuffer.init(&enc);
    for (want) |w| try std.testing.expectEqual(w, try b.decodeVarintSigned(i32));
}

test "skip + remaining + truncated varint" {
    var b = DecoderBuffer.init(&[_]u8{ 0xde, 0xad, 0x80 }); // 0x80 = incomplete varint
    try b.skip(2);
    try std.testing.expectEqual(@as(usize, 1), b.remaining());
    try std.testing.expectError(Error.Truncated, b.decodeVarint(u32));
}

test "BitDecoder LSB-first extraction" {
    // byte 0b1011_0010 = 0xB2. LSB-first: bit0=0,1,0,0,1,1,0,1
    var b = DecoderBuffer.init(&[_]u8{ 0xB2, 0xFF });
    var bd = try b.bitDecoder(1); // consume 1 byte for the bit region
    try std.testing.expectEqual(@as(u1, 0), bd.readBit());
    try std.testing.expectEqual(@as(u1, 1), bd.readBit());
    try std.testing.expectEqual(@as(u32, 0b1100), bd.readBits(4)); // next 4 bits LSB-first = 0,0,1,1 -> 0b1100
    try std.testing.expectEqual(@as(usize, 1), b.remaining()); // parent advanced past the 1 bit-region byte
}

test "BitDecoder spanning bytes" {
    var b = DecoderBuffer.init(&[_]u8{ 0x01, 0x01 });
    var bd = try b.bitDecoder(2);
    try std.testing.expectEqual(@as(u32, 1), bd.readBits(8)); // 0x01
    try std.testing.expectEqual(@as(u32, 1), bd.readBits(8)); // 0x01
}

test "BitDecoder readBits n=32 full u32 + no panic when n>32" {
    var b = DecoderBuffer.init(&[_]u8{ 0x78, 0x56, 0x34, 0x12, 0xAA });
    var bd = try b.bitDecoder(5);
    try std.testing.expectEqual(@as(u32, 0x12345678), bd.readBits(32)); // LSB-first over 4 bytes
    // n>32 must not panic; clamped to 32 → reads the next 32 bits available (zero-padded past end)
    var b2 = DecoderBuffer.init(&[_]u8{ 0x01, 0x00, 0x00, 0x00 });
    var bd2 = try b2.bitDecoder(4);
    try std.testing.expectEqual(@as(u32, 1), bd2.readBits(40));
}
