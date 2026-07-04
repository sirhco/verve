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
