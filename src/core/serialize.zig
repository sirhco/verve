//! Binary tagged-value codec for the SSR↔hydration boundary. Encodes a
//! comptime-known subset of Zig values into a self-describing byte
//! stream the WASM client can decode without RTTI. The codec is little-
//! endian and avoids allocator churn — the encoder appends to a
//! caller-provided `std.ArrayList(u8)` and the decoder reads from a
//! borrowed slice.
//!
//! Supported types:
//!   - Booleans
//!   - Signed/unsigned ints from 8 to 64 bits
//!   - f32, f64
//!   - `[]const u8` (length-prefixed)
//!   - Optionals
//!   - Slices `[]T` for any supported T
//!   - Structs (fields encoded in declaration order)
//!   - Enums (encoded as their tag int)
//!
//! Phase 4 ships the encoder; the decoder mirrors it. Later phases
//! layer typed-fn-generated dispatchers on top for Server Functions.

const std = @import("std");

pub const Tag = enum(u8) {
    bool_t = 1,
    i8_t = 2,
    i16_t = 3,
    i32_t = 4,
    i64_t = 5,
    u8_t = 6,
    u16_t = 7,
    u32_t = 8,
    u64_t = 9,
    f32_t = 10,
    f64_t = 11,
    bytes_t = 12,
    optional_t = 13,
    slice_t = 14,
    struct_t = 15,
    enum_t = 16,
};

pub const EncodeError = std.mem.Allocator.Error || error{
    Unsupported,
};

pub fn encode(value: anytype, out: *std.ArrayList(u8), alloc: std.mem.Allocator) EncodeError!void {
    const T = @TypeOf(value);
    try encodeTyped(T, value, out, alloc);
}

fn encodeTyped(comptime T: type, value: T, out: *std.ArrayList(u8), alloc: std.mem.Allocator) EncodeError!void {
    switch (@typeInfo(T)) {
        .bool => {
            try out.append(alloc, @intFromEnum(Tag.bool_t));
            try out.append(alloc, if (value) 1 else 0);
        },
        .int => |info| {
            try writeIntTag(info, out, alloc);
            try writeIntBytes(T, value, out, alloc);
        },
        .float => |info| {
            switch (info.bits) {
                32 => {
                    try out.append(alloc, @intFromEnum(Tag.f32_t));
                    var buf: [4]u8 = undefined;
                    std.mem.writeInt(u32, &buf, @bitCast(@as(f32, value)), .little);
                    try out.appendSlice(alloc, &buf);
                },
                64 => {
                    try out.append(alloc, @intFromEnum(Tag.f64_t));
                    var buf: [8]u8 = undefined;
                    std.mem.writeInt(u64, &buf, @bitCast(@as(f64, value)), .little);
                    try out.appendSlice(alloc, &buf);
                },
                else => return error.Unsupported,
            }
        },
        .pointer => |p| {
            if (p.size != .slice) return error.Unsupported;
            if (p.child == u8) {
                try out.append(alloc, @intFromEnum(Tag.bytes_t));
                try writeLen(value.len, out, alloc);
                try out.appendSlice(alloc, value);
            } else {
                try out.append(alloc, @intFromEnum(Tag.slice_t));
                try writeLen(value.len, out, alloc);
                for (value) |elem| try encodeTyped(p.child, elem, out, alloc);
            }
        },
        .optional => |opt| {
            try out.append(alloc, @intFromEnum(Tag.optional_t));
            if (value) |v| {
                try out.append(alloc, 1);
                try encodeTyped(opt.child, v, out, alloc);
            } else {
                try out.append(alloc, 0);
            }
        },
        .@"struct" => |s| {
            try out.append(alloc, @intFromEnum(Tag.struct_t));
            try writeLen(s.fields.len, out, alloc);
            inline for (s.fields) |f| {
                try encodeTyped(f.type, @field(value, f.name), out, alloc);
            }
        },
        .@"enum" => |e| {
            try out.append(alloc, @intFromEnum(Tag.enum_t));
            try encodeTyped(e.tag_type, @intFromEnum(value), out, alloc);
        },
        else => return error.Unsupported,
    }
}

fn writeIntTag(info: std.builtin.Type.Int, out: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    const tag: Tag = switch (info.signedness) {
        .signed => switch (info.bits) {
            8 => .i8_t,
            16 => .i16_t,
            32 => .i32_t,
            64 => .i64_t,
            else => return error.Unsupported,
        },
        .unsigned => switch (info.bits) {
            8 => .u8_t,
            16 => .u16_t,
            32 => .u32_t,
            64 => .u64_t,
            else => return error.Unsupported,
        },
    };
    try out.append(alloc, @intFromEnum(tag));
}

fn writeIntBytes(comptime T: type, value: T, out: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    const size = @sizeOf(T);
    var buf: [16]u8 = undefined;
    if (size > buf.len) return error.Unsupported;
    std.mem.writeInt(T, buf[0..size], value, .little);
    try out.appendSlice(alloc, buf[0..size]);
}

/// Variable-length unsigned length encoding (uleb128). Small lengths
/// take one byte — important for the hydration payload where most
/// arrays are short.
fn writeLen(len: usize, out: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    var n = len;
    while (true) {
        var b: u8 = @truncate(n & 0x7f);
        n >>= 7;
        if (n != 0) b |= 0x80;
        try out.append(alloc, b);
        if (n == 0) break;
    }
}

// ---- tests ------------------------------------------------------------

const testing = std.testing;

test "encode i32 produces tag + 4 little-endian bytes" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try encode(@as(i32, 0x01020304), &buf, testing.allocator);

    try testing.expectEqual(@as(usize, 5), buf.items.len);
    try testing.expectEqual(@intFromEnum(Tag.i32_t), buf.items[0]);
    try testing.expectEqual(@as(u8, 0x04), buf.items[1]);
    try testing.expectEqual(@as(u8, 0x03), buf.items[2]);
    try testing.expectEqual(@as(u8, 0x02), buf.items[3]);
    try testing.expectEqual(@as(u8, 0x01), buf.items[4]);
}

test "encode bool and bytes" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try encode(true, &buf, testing.allocator);
    try encode(@as([]const u8, "hi"), &buf, testing.allocator);

    try testing.expectEqual(@intFromEnum(Tag.bool_t), buf.items[0]);
    try testing.expectEqual(@as(u8, 1), buf.items[1]);
    try testing.expectEqual(@intFromEnum(Tag.bytes_t), buf.items[2]);
    try testing.expectEqual(@as(u8, 2), buf.items[3]);
    try testing.expectEqual(@as(u8, 'h'), buf.items[4]);
    try testing.expectEqual(@as(u8, 'i'), buf.items[5]);
}

test "encode optional present and absent" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try encode(@as(?u8, 42), &buf, testing.allocator);
    try encode(@as(?u8, null), &buf, testing.allocator);

    try testing.expectEqual(@intFromEnum(Tag.optional_t), buf.items[0]);
    try testing.expectEqual(@as(u8, 1), buf.items[1]);
    try testing.expectEqual(@intFromEnum(Tag.u8_t), buf.items[2]);
    try testing.expectEqual(@as(u8, 42), buf.items[3]);

    try testing.expectEqual(@intFromEnum(Tag.optional_t), buf.items[4]);
    try testing.expectEqual(@as(u8, 0), buf.items[5]);
}

test "encode struct walks fields in declaration order" {
    const T = struct { a: u16, b: bool, c: []const u8 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try encode(T{ .a = 7, .b = true, .c = "ok" }, &buf, testing.allocator);

    try testing.expectEqual(@intFromEnum(Tag.struct_t), buf.items[0]);
    try testing.expectEqual(@as(u8, 3), buf.items[1]); // 3 fields, uleb128 short form
    try testing.expectEqual(@intFromEnum(Tag.u16_t), buf.items[2]);
    // a value
    try testing.expectEqual(@as(u8, 7), buf.items[3]);
    try testing.expectEqual(@as(u8, 0), buf.items[4]);
    // b
    try testing.expectEqual(@intFromEnum(Tag.bool_t), buf.items[5]);
    try testing.expectEqual(@as(u8, 1), buf.items[6]);
    // c
    try testing.expectEqual(@intFromEnum(Tag.bytes_t), buf.items[7]);
    try testing.expectEqual(@as(u8, 2), buf.items[8]);
    try testing.expectEqual(@as(u8, 'o'), buf.items[9]);
    try testing.expectEqual(@as(u8, 'k'), buf.items[10]);
}

test "encode slice of u32" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const arr = [_]u32{ 10, 20, 30 };
    try encode(@as([]const u32, &arr), &buf, testing.allocator);

    try testing.expectEqual(@intFromEnum(Tag.slice_t), buf.items[0]);
    try testing.expectEqual(@as(u8, 3), buf.items[1]);
    try testing.expectEqual(@intFromEnum(Tag.u32_t), buf.items[2]);
    try testing.expectEqual(@as(u8, 10), buf.items[3]);
}
