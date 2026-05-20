//! Typed dependency-injection through the Owner tree. `provide(T, v)`
//! stores a value of type T on the current owner; `use(T)` walks the
//! owner chain from the deepest scope upward and returns the first
//! match. Children can override a parent's provided value for their
//! subtree without disturbing siblings.
//!
//! Storage is keyed by `@typeName(T)` — a compile-time string, so the
//! map lookup is a plain string-hash, no RTTI.

const std = @import("std");
const Owner = @import("owner.zig").Owner;

/// Map name: per-owner table of provided values. Owners that never
/// call `provide` skip the allocation entirely (the field stays null).
const Provided = std.StringHashMapUnmanaged(*anyopaque);

/// Per-owner storage. Allocated lazily on first `provide` to keep
/// memory usage flat for owners that don't use DI.
pub const ProvidedTable = struct {
    map: Provided = .empty,
};

/// Store `value` on `owner` keyed by T's name. Subsequent `use(T)`
/// calls on this owner or any descendant return a pointer to this
/// stored value until either the owner is disposed or a descendant
/// shadows it with its own `provide(T, _)`.
pub fn provide(owner: *Owner, comptime T: type, value: T) !void {
    const slot = try owner.allocator().create(T);
    slot.* = value;
    const table = try ensureTable(owner);
    try table.map.put(owner.allocator(), @typeName(T), @as(*anyopaque, @ptrCast(slot)));
}

/// Look up a previously-provided value. Walks from `owner` toward the
/// root; the nearest match wins. Returns null when no ancestor has
/// provided T.
pub fn use(owner: *Owner, comptime T: type) ?T {
    var cur: ?*Owner = owner;
    while (cur) |o| {
        if (getTable(o)) |table| {
            if (table.map.get(@typeName(T))) |raw| {
                const slot: *T = @ptrCast(@alignCast(raw));
                return slot.*;
            }
        }
        cur = o.parent;
    }
    return null;
}

/// Pointer variant — returns a mutable handle so callers can update
/// the stored value in place. Useful for shared state (theme, current
/// user) that toggles at runtime.
pub fn usePtr(owner: *Owner, comptime T: type) ?*T {
    var cur: ?*Owner = owner;
    while (cur) |o| {
        if (getTable(o)) |table| {
            if (table.map.get(@typeName(T))) |raw| {
                const slot: *T = @ptrCast(@alignCast(raw));
                return slot;
            }
        }
        cur = o.parent;
    }
    return null;
}

// ---- table plumbing ----------------------------------------------------

/// We don't want to add a field to Owner directly because that pulls a
/// large hashmap struct into the cold path. Instead, the table is a
/// side-allocation reached via an owner-keyed pointer table.
var owner_tables_init: bool = false;
threadlocal var owner_tables: std.AutoHashMapUnmanaged(usize, *ProvidedTable) = .empty;
threadlocal var owner_tables_alloc: ?std.mem.Allocator = null;

pub fn setOwnerTablesAllocator(a: std.mem.Allocator) void {
    owner_tables = .empty;
    owner_tables_alloc = a;
}

fn ensureTable(owner: *Owner) !*ProvidedTable {
    const alloc = owner_tables_alloc orelse owner.allocator();
    const key = @intFromPtr(owner);
    const gop = try owner_tables.getOrPut(alloc, key);
    if (!gop.found_existing) {
        const tbl = try owner.allocator().create(ProvidedTable);
        tbl.* = .{};
        gop.value_ptr.* = tbl;
    }
    return gop.value_ptr.*;
}

fn getTable(owner: *Owner) ?*ProvidedTable {
    const key = @intFromPtr(owner);
    return owner_tables.get(key);
}

// ---- tests ------------------------------------------------------------

const testing = std.testing;

test "provide + use roundtrip single owner" {
    var arena_gpa = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_gpa.deinit();
    setOwnerTablesAllocator(arena_gpa.allocator());

    var owner = Owner.init(testing.allocator);
    defer owner.dispose();

    const Theme = struct { primary: []const u8 };
    try provide(&owner, Theme, .{ .primary = "blue" });

    const got = use(&owner, Theme).?;
    try testing.expectEqualStrings("blue", got.primary);
}

test "child use walks to parent" {
    var arena_gpa = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_gpa.deinit();
    setOwnerTablesAllocator(arena_gpa.allocator());

    var root = Owner.init(testing.allocator);
    defer root.dispose();

    const User = struct { id: u32, name: []const u8 };
    try provide(&root, User, .{ .id = 42, .name = "alice" });

    const child = try root.createChild();
    const got = use(child, User).?;
    try testing.expectEqual(@as(u32, 42), got.id);
    try testing.expectEqualStrings("alice", got.name);
}

test "child shadows parent for its subtree" {
    var arena_gpa = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_gpa.deinit();
    setOwnerTablesAllocator(arena_gpa.allocator());

    var root = Owner.init(testing.allocator);
    defer root.dispose();

    const Theme = struct { primary: []const u8 };
    try provide(&root, Theme, .{ .primary = "blue" });

    const child = try root.createChild();
    try provide(child, Theme, .{ .primary = "red" });

    try testing.expectEqualStrings("red", use(child, Theme).?.primary);
    try testing.expectEqualStrings("blue", use(&root, Theme).?.primary);
}

test "use returns null when nothing was provided" {
    var arena_gpa = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_gpa.deinit();
    setOwnerTablesAllocator(arena_gpa.allocator());

    var owner = Owner.init(testing.allocator);
    defer owner.dispose();

    const T = struct { x: u32 };
    try testing.expect(use(&owner, T) == null);
}
