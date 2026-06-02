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

// ---- decoder ----------------------------------------------------------

pub const DecodeError = std.mem.Allocator.Error || error{
    Corrupt,
    TypeMismatch,
    EndOfStream,
};

/// Bounds-checked reader over a borrowed byte slice. Every read validates
/// `pos`/`len` before indexing so arbitrary client-controlled input can
/// never trigger an out-of-bounds panic. Invariant: `pos <= buf.len`.
const Cursor = struct {
    buf: []const u8,
    pos: usize = 0,

    fn byte(c: *Cursor) DecodeError!u8 {
        if (c.pos >= c.buf.len) return error.EndOfStream;
        const b = c.buf[c.pos];
        c.pos += 1;
        return b;
    }

    /// Returns a sub-slice of `n` bytes, advancing the cursor. Checks the
    /// length against the *remaining* buffer using subtraction that cannot
    /// underflow (pos <= len invariant), so a bogus huge `n` errors out
    /// before any allocation rather than reading OOB.
    fn take(c: *Cursor, n: usize) DecodeError![]const u8 {
        if (n > c.buf.len - c.pos) return error.EndOfStream;
        const out = c.buf[c.pos .. c.pos + n];
        c.pos += n;
        return out;
    }

    /// uleb128 length reader, guarded against shift overflow: a malicious
    /// varint with the continuation bit set forever is rejected once the
    /// shift would exceed the width of `usize`, so it cannot loop or wrap.
    fn uleb(c: *Cursor) DecodeError!usize {
        var result: usize = 0;
        var shift: usize = 0;
        while (true) {
            const b = try c.byte();
            if (shift >= @bitSizeOf(usize)) return error.Corrupt;
            result |= (@as(usize, b & 0x7f) << @intCast(shift));
            if (b & 0x80 == 0) break;
            shift += 7;
        }
        return result;
    }

    fn expect(c: *Cursor, tag: Tag) DecodeError!void {
        const b = try c.byte();
        if (b != @intFromEnum(tag)) return error.TypeMismatch;
    }
};

/// Comptime mapping from an int type's info to its wire tag. Mirrors
/// `writeIntTag` and `@compileError`s on widths the encoder cannot emit,
/// so the decoder can never be asked to read an int it didn't write.
fn intTag(comptime info: std.builtin.Type.Int) Tag {
    return switch (info.signedness) {
        .signed => switch (info.bits) {
            8 => .i8_t,
            16 => .i16_t,
            32 => .i32_t,
            64 => .i64_t,
            else => @compileError("unsupported signed int width"),
        },
        .unsigned => switch (info.bits) {
            8 => .u8_t,
            16 => .u16_t,
            32 => .u32_t,
            64 => .u64_t,
            else => @compileError("unsupported unsigned int width"),
        },
    };
}

/// Decode a `T` from `bytes`, allocating owned storage (slices/strings)
/// from `alloc`. Trailing bytes after the value are ignored. Panic-free
/// on arbitrary input: every read is bounds-checked, lengths are validated
/// before allocation, and the uleb reader is shift-guarded.
pub fn decode(comptime T: type, bytes: []const u8, alloc: std.mem.Allocator) DecodeError!T {
    var c = Cursor{ .buf = bytes };
    return decodeTyped(T, &c, alloc);
}

fn decodeTyped(comptime T: type, c: *Cursor, alloc: std.mem.Allocator) DecodeError!T {
    switch (@typeInfo(T)) {
        .bool => {
            try c.expect(.bool_t);
            return (try c.byte()) != 0;
        },
        .int => |info| {
            try c.expect(intTag(info));
            const raw = try c.take(@sizeOf(T));
            var tmp: [@sizeOf(T)]u8 = undefined;
            @memcpy(&tmp, raw);
            return std.mem.readInt(T, &tmp, .little);
        },
        .float => |info| {
            switch (info.bits) {
                32 => {
                    try c.expect(.f32_t);
                    const raw = try c.take(4);
                    var tmp: [4]u8 = undefined;
                    @memcpy(&tmp, raw);
                    return @bitCast(std.mem.readInt(u32, &tmp, .little));
                },
                64 => {
                    try c.expect(.f64_t);
                    const raw = try c.take(8);
                    var tmp: [8]u8 = undefined;
                    @memcpy(&tmp, raw);
                    return @bitCast(std.mem.readInt(u64, &tmp, .little));
                },
                else => @compileError("unsupported float width"),
            }
        },
        .pointer => |p| {
            if (p.size != .slice) @compileError("only slice pointers are supported");
            if (p.child == u8) {
                try c.expect(.bytes_t);
                const n = try c.uleb();
                const src = try c.take(n);
                return try alloc.dupe(u8, src);
            } else {
                try c.expect(.slice_t);
                const n = try c.uleb();
                // Cap the element count against the remaining buffer BEFORE
                // allocating — every encoded element is at least one tag byte,
                // so a valid `n` can never exceed the bytes left. This stops an
                // attacker-controlled length from allocation-bombing (OOM-DoS)
                // before the per-element decode hits EndOfStream. (pos <= len
                // invariant holds, so the subtraction can't underflow.)
                if (n > c.buf.len - c.pos) return error.EndOfStream;
                const out = try alloc.alloc(p.child, n);
                errdefer alloc.free(out);
                for (out) |*elem| {
                    elem.* = try decodeTyped(p.child, c, alloc);
                }
                return out;
            }
        },
        .optional => |opt| {
            try c.expect(.optional_t);
            const present = try c.byte();
            if (present != 0) {
                return try decodeTyped(opt.child, c, alloc);
            }
            return null;
        },
        .@"struct" => |s| {
            try c.expect(.struct_t);
            const count = try c.uleb();
            if (count != s.fields.len) return error.TypeMismatch;
            var result: T = undefined;
            inline for (s.fields) |f| {
                @field(result, f.name) = try decodeTyped(f.type, c, alloc);
            }
            return result;
        },
        .@"enum" => |e| {
            try c.expect(.enum_t);
            const raw = try decodeTyped(e.tag_type, c, alloc);
            return std.enums.fromInt(T, raw) orelse return error.Corrupt;
        },
        else => @compileError("unsupported type for decode: " ++ @typeName(T)),
    }
}

/// Convenience wrapper that encodes `value` into a freshly allocated owned
/// slice. Mirrors how the rest of the repo turns an ArrayList into an owned
/// buffer via `toOwnedSlice(alloc)`.
pub fn encodeToBytes(value: anytype, alloc: std.mem.Allocator) EncodeError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try encode(value, &out, alloc);
    return out.toOwnedSlice(alloc);
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

test "decode round-trips every supported type" {
    const E = enum(u8) { a, b, c };
    const Inner = struct { x: i64, y: ?bool };
    const T = struct {
        flag: bool,
        n8: i8,
        n16: u16,
        n32: i32,
        n64: u64,
        fl: f32,
        dl: f64,
        name: []const u8,
        opt_present: ?u32,
        opt_absent: ?u32,
        nums: []const u32,
        strs: []const []const u8,
        inner: Inner,
        kind: E,
    };
    const value = T{
        .flag = true,
        .n8 = -5,
        .n16 = 600,
        .n32 = -123456,
        .n64 = 9_000_000_000,
        .fl = 1.5,
        .dl = 2.25,
        .name = "hello",
        .opt_present = 77,
        .opt_absent = null,
        .nums = &.{ 1, 2, 3 },
        .strs = &.{ "a", "bb" },
        .inner = .{ .x = -1, .y = true },
        .kind = .c,
    };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try encode(value, &buf, testing.allocator);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try decode(T, buf.items, arena.allocator());

    try testing.expectEqual(value.flag, got.flag);
    try testing.expectEqual(value.n8, got.n8);
    try testing.expectEqual(value.n16, got.n16);
    try testing.expectEqual(value.n32, got.n32);
    try testing.expectEqual(value.n64, got.n64);
    try testing.expectEqual(value.fl, got.fl);
    try testing.expectEqual(value.dl, got.dl);
    try testing.expectEqualStrings(value.name, got.name);
    try testing.expectEqual(@as(?u32, 77), got.opt_present);
    try testing.expectEqual(@as(?u32, null), got.opt_absent);
    try testing.expectEqualSlices(u32, value.nums, got.nums);
    try testing.expectEqual(@as(usize, 2), got.strs.len);
    try testing.expectEqualStrings("a", got.strs[0]);
    try testing.expectEqualStrings("bb", got.strs[1]);
    try testing.expectEqual(@as(i64, -1), got.inner.x);
    try testing.expectEqual(@as(?bool, true), got.inner.y);
    try testing.expectEqual(E.c, got.kind);
}

test "decode caps slice length against buffer (no allocation bomb)" {
    // slice_t + a huge uleb length (~268M) + no element bytes. The length cap
    // must reject this with EndOfStream BEFORE allocating ~268M elements.
    const bytes = [_]u8{ @intFromEnum(Tag.slice_t), 0xff, 0xff, 0xff, 0x7f };
    try testing.expectError(error.EndOfStream, decode([]const u32, &bytes, testing.allocator));
}

test "decode rejects wrong leading tag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try encode(@as(bool, true), &buf, testing.allocator);
    try testing.expectError(error.TypeMismatch, decode(u32, buf.items, arena.allocator()));
}

test "decode never panics or OOB-reads on truncated input" {
    const T = struct { a: u32, b: []const u8, c: ?[]const u32 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try encode(T{ .a = 9, .b = "xyz", .c = &.{ 1, 2 } }, &buf, testing.allocator);
    var n: usize = 0;
    while (n < buf.items.len) : (n += 1) {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        _ = decode(T, buf.items[0..n], arena.allocator()) catch {};
    }
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bogus = [_]u8{ @intFromEnum(Tag.bytes_t), 0xff, 0xff, 0xff, 0xff, 0x0f };
    _ = decode([]const u8, &bogus, arena.allocator()) catch {};
}
