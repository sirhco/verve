//! Phase 17 — shared JSON value service for the main client.wasm.
//!
//! Per-island chunks deliberately avoid `@import("std")` to stay small
//! (each chunk is its own wasm module, so a `std.json.Scanner` would be
//! duplicated ~30 KB per chunk — the reason downstream apps hand-roll a
//! flat scanner). This service parses JSON *once* in the main client
//! (which already links std) and hands chunks a numeric handle plus a
//! set of accessor externs (`verve_json_*` in `runtime_exports.zig`).
//! Chunks read typed fields off the handle without pulling a parser.
//!
//! Handles index a fixed table. A `parse` call owns its `Parsed` tree
//! (and the arena behind it); child handles returned by `objGet` / `at`
//! are non-owning views into the same tree and stay valid until the
//! root is `free`d. Free the root last.

const std = @import("std");
const client_alloc = @import("allocator.zig");

/// Value-kind tags returned by `kind`. Mirrored in `island_runtime.zig`
/// as `JsonDoc.Kind`. `invalid` (bad/closed handle) is a distinct high
/// sentinel so callers can tell "missing key" (handle 0 → invalid) from
/// a real JSON `null`.
pub const KIND_NULL: u32 = 0;
pub const KIND_BOOL: u32 = 1;
pub const KIND_INT: u32 = 2;
pub const KIND_FLOAT: u32 = 3;
pub const KIND_STRING: u32 = 4;
pub const KIND_ARRAY: u32 = 5;
pub const KIND_OBJECT: u32 = 6;
pub const KIND_INVALID: u32 = 0xFFFFFFFF;

/// Table capacity. A chunk dispatch typically holds one root plus a few
/// transient child views, freed before the next reply — 64 is generous.
const MAX_DOCS = 64;

const Slot = struct {
    used: bool = false,
    /// Set only on root handles; child views leave it null and borrow.
    parsed: ?std.json.Parsed(std.json.Value) = null,
    value: ?*const std.json.Value = null,
};

var slots = [_]Slot{.{}} ** MAX_DOCS;

fn lookup(handle: u32) ?*const std.json.Value {
    if (handle == 0 or handle > MAX_DOCS) return null;
    const s = &slots[handle - 1];
    if (!s.used) return null;
    return s.value;
}

fn storeView(value: *const std.json.Value) u32 {
    for (&slots, 0..) |*s, i| {
        if (!s.used) {
            s.* = .{ .used = true, .parsed = null, .value = value };
            return @intCast(i + 1);
        }
    }
    return 0;
}

/// Parse `bytes` into the table. Returns a root handle (>=1) or 0 on
/// failure / no free slot. The bytes are not retained — the parser
/// copies everything it keeps into its own arena.
pub fn parse(bytes: []const u8) u32 {
    var parsed = std.json.parseFromSlice(std.json.Value, client_alloc.allocator(), bytes, .{}) catch return 0;
    for (&slots, 0..) |*s, i| {
        if (!s.used) {
            s.used = true;
            s.parsed = parsed;
            s.value = &s.parsed.?.value;
            return @intCast(i + 1);
        }
    }
    parsed.deinit();
    return 0;
}

/// Release a handle. Root handles deinit their parse arena (invalidating
/// every child view derived from them); child handles just free the
/// table slot.
pub fn free(handle: u32) void {
    if (handle == 0 or handle > MAX_DOCS) return;
    const s = &slots[handle - 1];
    if (!s.used) return;
    if (s.parsed) |*p| p.deinit();
    s.* = .{};
}

pub fn objGet(handle: u32, key: []const u8) u32 {
    const v = lookup(handle) orelse return 0;
    if (v.* != .object) return 0;
    const child = v.object.getPtr(key) orelse return 0;
    return storeView(child);
}

pub fn at(handle: u32, index: u32) u32 {
    const v = lookup(handle) orelse return 0;
    if (v.* != .array) return 0;
    if (index >= v.array.items.len) return 0;
    return storeView(&v.array.items[index]);
}

/// Array length, or -1 when the handle isn't an array.
pub fn len(handle: u32) i32 {
    const v = lookup(handle) orelse return -1;
    if (v.* != .array) return -1;
    return @intCast(v.array.items.len);
}

pub fn kind(handle: u32) u32 {
    const v = lookup(handle) orelse return KIND_INVALID;
    return switch (v.*) {
        .null => KIND_NULL,
        .bool => KIND_BOOL,
        .integer => KIND_INT,
        .float, .number_string => KIND_FLOAT,
        .string => KIND_STRING,
        .array => KIND_ARRAY,
        .object => KIND_OBJECT,
    };
}

pub fn asI64(handle: u32) i64 {
    const v = lookup(handle) orelse return 0;
    return switch (v.*) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        .bool => |b| @intFromBool(b),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch 0,
        else => 0,
    };
}

pub fn asF64(handle: u32) f64 {
    const v = lookup(handle) orelse return 0;
    return switch (v.*) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        .number_string => |s| std.fmt.parseFloat(f64, s) catch 0,
        else => 0,
    };
}

pub fn asBool(handle: u32) bool {
    const v = lookup(handle) orelse return false;
    return switch (v.*) {
        .bool => |b| b,
        .integer => |n| n != 0,
        else => false,
    };
}

fn asSlice(handle: u32) ?[]const u8 {
    const v = lookup(handle) orelse return null;
    return switch (v.*) {
        .string => |s| s,
        .number_string => |s| s,
        else => null,
    };
}

pub fn asStrLen(handle: u32) u32 {
    const s = asSlice(handle) orelse return 0;
    return @intCast(s.len);
}

/// Copy up to `cap` bytes of the string value into `buf`. Returns the
/// number of bytes written (truncated to `cap`).
pub fn asStr(handle: u32, buf: [*]u8, cap: u32) u32 {
    const s = asSlice(handle) orelse return 0;
    const n: u32 = @min(@as(u32, @intCast(s.len)), cap);
    @memcpy(buf[0..n], s[0..n]);
    return n;
}

/// Drop every live handle. Test-only — production never resets the table
/// wholesale (callers free their own roots).
pub fn resetForTesting() void {
    for (&slots) |*s| {
        if (s.parsed) |*p| p.deinit();
        s.* = .{};
    }
}

// ---- tests ---------------------------------------------------------------

const testing = std.testing;

test "parse + scalar accessors" {
    resetForTesting();
    defer resetForTesting();

    const doc = parse(
        \\{"count": 42, "ratio": 1.5, "pinned": true, "title": "hello"}
    );
    try testing.expect(doc != 0);
    try testing.expectEqual(KIND_OBJECT, kind(doc));

    const count = objGet(doc, "count");
    try testing.expectEqual(KIND_INT, kind(count));
    try testing.expectEqual(@as(i64, 42), asI64(count));

    const ratio = objGet(doc, "ratio");
    try testing.expectEqual(@as(f64, 1.5), asF64(ratio));

    const pinned = objGet(doc, "pinned");
    try testing.expectEqual(true, asBool(pinned));

    const title = objGet(doc, "title");
    try testing.expectEqual(@as(u32, 5), asStrLen(title));
    var buf: [16]u8 = undefined;
    const n = asStr(title, &buf, buf.len);
    try testing.expectEqualStrings("hello", buf[0..n]);

    // missing key → 0 handle → invalid kind
    try testing.expectEqual(@as(u32, 0), objGet(doc, "nope"));
    try testing.expectEqual(KIND_INVALID, kind(objGet(doc, "nope")));

    free(doc);
}

test "parse arrays + nested objects" {
    resetForTesting();
    defer resetForTesting();

    const doc = parse(
        \\{"items": [{"id": "a"}, {"id": "b"}, {"id": "c"}]}
    );
    try testing.expect(doc != 0);

    const items = objGet(doc, "items");
    try testing.expectEqual(@as(i32, 3), len(items));
    try testing.expectEqual(@as(i32, -1), len(doc)); // object isn't an array

    const second = at(items, 1);
    const id = objGet(second, "id");
    var buf: [4]u8 = undefined;
    const n = asStr(id, &buf, buf.len);
    try testing.expectEqualStrings("b", buf[0..n]);

    // out-of-range index → 0
    try testing.expectEqual(@as(u32, 0), at(items, 9));

    free(doc);
}

test "malformed json returns 0" {
    resetForTesting();
    defer resetForTesting();
    try testing.expectEqual(@as(u32, 0), parse("{not valid"));
}
