//! Per-render registry of (island vid → serialized state blob) plus a tiny
//! primitive codec. Used to serialize a server-resolved Resource's ready value
//! into the page so the client can hydrate without re-fetching.
//!
//! Wire format (per entry, concatenated in the blob):
//!   name_len: u16 LE | name bytes | tag: u8 | payload
//!
//! Payloads:
//!   i32  → 4 bytes LE
//!   str  → len:u32 LE + bytes
//!   bool → 1 byte (0/1)
//!   f32  → 4 bytes LE (u32 bitcast)

const std = @import("std");

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const Tag = enum(u8) {
    i32 = 0,
    str = 1,
    bool = 2,
    f32 = 3,
};

pub const Value = union(Tag) {
    i32: i32,
    str: []const u8,
    bool: bool,
    f32: f32,
};

// ---------------------------------------------------------------------------
// Encode
// ---------------------------------------------------------------------------

/// Append one (name, value) entry to `buf` in the wire format.
pub fn encodeEntry(
    gpa: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    name: []const u8,
    value: Value,
) !void {
    // name_len: u16 LE
    var nl_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &nl_buf, @intCast(name.len), .little);
    try buf.appendSlice(gpa, &nl_buf);
    // name bytes
    try buf.appendSlice(gpa, name);
    // tag byte
    try buf.append(gpa, @intFromEnum(@as(Tag, value)));
    // payload
    switch (value) {
        .i32 => |v| {
            var b: [4]u8 = undefined;
            std.mem.writeInt(i32, &b, v, .little);
            try buf.appendSlice(gpa, &b);
        },
        .str => |v| {
            var lb: [4]u8 = undefined;
            std.mem.writeInt(u32, &lb, @intCast(v.len), .little);
            try buf.appendSlice(gpa, &lb);
            try buf.appendSlice(gpa, v);
        },
        .bool => |v| {
            try buf.append(gpa, if (v) 1 else 0);
        },
        .f32 => |v| {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, @bitCast(v), .little);
            try buf.appendSlice(gpa, &b);
        },
    }
}

// ---------------------------------------------------------------------------
// Lookup / decode
// ---------------------------------------------------------------------------

pub const DecodeError = error{Corrupt};

/// Walk the blob and return the decoded Value for `key`, or null if absent.
/// Returns error.Corrupt if the blob is malformed.
pub fn lookup(blob: []const u8, key: []const u8) DecodeError!?Value {
    var i: usize = 0;
    while (i < blob.len) {
        // name_len
        if (i + 2 > blob.len) return error.Corrupt;
        const name_len = std.mem.readInt(u16, blob[i..][0..2], .little);
        i += 2;

        // name bytes
        if (i + name_len > blob.len) return error.Corrupt;
        const entry_name = blob[i .. i + name_len];
        i += name_len;

        // tag
        if (i >= blob.len) return error.Corrupt;
        const tag_byte = blob[i];
        i += 1;
        const tag: Tag = switch (tag_byte) {
            @intFromEnum(Tag.i32) => .i32,
            @intFromEnum(Tag.str) => .str,
            @intFromEnum(Tag.bool) => .bool,
            @intFromEnum(Tag.f32) => .f32,
            else => return error.Corrupt,
        };

        // payload
        const value: Value = switch (tag) {
            .i32 => blk: {
                if (i + 4 > blob.len) return error.Corrupt;
                const v = std.mem.readInt(i32, blob[i..][0..4], .little);
                i += 4;
                break :blk .{ .i32 = v };
            },
            .str => blk: {
                if (i + 4 > blob.len) return error.Corrupt;
                const str_len = std.mem.readInt(u32, blob[i..][0..4], .little);
                i += 4;
                if (i + str_len > blob.len) return error.Corrupt;
                const s = blob[i .. i + str_len];
                i += str_len;
                break :blk .{ .str = s };
            },
            .bool => blk: {
                if (i >= blob.len) return error.Corrupt;
                const v = blob[i] != 0;
                i += 1;
                break :blk .{ .bool = v };
            },
            .f32 => blk: {
                if (i + 4 > blob.len) return error.Corrupt;
                const bits = std.mem.readInt(u32, blob[i..][0..4], .little);
                i += 4;
                break :blk .{ .f32 = @bitCast(bits) };
            },
        };

        if (std.mem.eql(u8, entry_name, key)) return value;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

pub const Registry = struct {
    pub const Entry = struct {
        vid: u32,
        blob: []const u8,
    };

    entries: std.ArrayListUnmanaged(Entry) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(a: std.mem.Allocator) Registry {
        return .{ .allocator = a };
    }

    pub fn deinit(self: *Registry) void {
        self.entries.deinit(self.allocator);
    }

    /// Record a (vid, blob) pair. The blob slice is stored by reference —
    /// the caller owns the backing memory for the lifetime of the Registry.
    pub fn record(self: *Registry, vid: u32, blob: []const u8) !void {
        try self.entries.append(self.allocator, .{ .vid = vid, .blob = blob });
    }

    pub fn reset(self: *Registry) void {
        self.entries.clearRetainingCapacity();
    }
};

// ---------------------------------------------------------------------------
// Thread-local current registry
// ---------------------------------------------------------------------------

pub threadlocal var current: ?*Registry = null;

pub fn setCurrent(reg: ?*Registry) void {
    current = reg;
}

// ---------------------------------------------------------------------------
// Script body builder
// ---------------------------------------------------------------------------

/// Write `{"<vid>":"<base64(blob)>",...}` into `out`.
/// Writes nothing when `entries` is empty.
pub fn buildStateScriptBody(
    gpa: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    entries: []const Registry.Entry,
) !void {
    if (entries.len == 0) return;

    const enc = std.base64.standard.Encoder;

    try out.append(gpa, '{');
    for (entries, 0..) |entry, idx| {
        if (idx > 0) try out.append(gpa, ',');

        // "vid":
        try out.append(gpa, '"');
        var vid_buf: [20]u8 = undefined;
        const vid_str = std.fmt.bufPrint(&vid_buf, "{d}", .{entry.vid}) catch unreachable;
        try out.appendSlice(gpa, vid_str);
        try out.appendSlice(gpa, "\":\"");

        // base64(blob)
        const b64_len = enc.calcSize(entry.blob.len);
        const old_len = out.items.len;
        try out.resize(gpa, old_len + b64_len);
        _ = enc.encode(out.items[old_len..], entry.blob);

        try out.append(gpa, '"');
    }
    try out.append(gpa, '}');
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "encode/decode round-trips each primitive" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try encodeEntry(testing.allocator, &buf, "a", .{ .i32 = 7 });
    try encodeEntry(testing.allocator, &buf, "b", .{ .str = "hi" });
    try encodeEntry(testing.allocator, &buf, "c", .{ .bool = true });
    try encodeEntry(testing.allocator, &buf, "d", .{ .f32 = 1.5 });

    try testing.expectEqual(@as(i32, 7), (try lookup(buf.items, "a")).?.i32);
    try testing.expectEqualStrings("hi", (try lookup(buf.items, "b")).?.str);
    try testing.expectEqual(true, (try lookup(buf.items, "c")).?.bool);
    try testing.expectEqual(@as(f32, 1.5), (try lookup(buf.items, "d")).?.f32);
    try testing.expect((try lookup(buf.items, "missing")) == null);
}

test "registry maps vid to blob and builds a script body" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();

    try reg.record(2, "blobB");
    try reg.record(1, "blobA");
    try testing.expectEqual(@as(usize, 2), reg.entries.items.len);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try buildStateScriptBody(testing.allocator, &out, reg.entries.items);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"2\":") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"1\":") != null);
}

test "empty registry yields empty script body" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try buildStateScriptBody(testing.allocator, &out, &.{});
    try testing.expectEqual(@as(usize, 0), out.items.len);
}
