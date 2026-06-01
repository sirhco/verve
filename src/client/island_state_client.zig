//! Client-side resource-state hydration. The bridge stages the hydrating
//! island's serialized state blob (via `verve_set_island_state`); chunks read
//! it with `resourceFromState(T, key)` to reconstruct a `.ready` Resource.

const std = @import("std");
const verve = @import("verve");

var current_blob: []const u8 = &.{};

pub fn setCurrentBlob(blob: []const u8) void {
    current_blob = blob;
}

/// Decode a struct-valued state entry into a `.ready` Resource(T). The struct
/// (and its strings/slices) are allocated from `owner.allocator()`, so they
/// outlive the shared scratch buffer. Returns null when the key is absent.
pub fn resourceStructFromState(comptime T: type, owner: *verve.Owner, key: []const u8) !?*verve.Resource(T) {
    const v = (verve.islandStateLookup(current_blob, key) catch return null) orelse return null;
    if (v != .str) return null;
    const value = verve.serializeDecode(T, v.str, owner.allocator()) catch return null;
    return try verve.resourceReady(T, owner, value);
}

/// Reconstruct a `.ready` Resource(T) from the current island's serialized
/// state entry `key`. Returns null when absent / wrong type. T ∈ { i32,
/// []const u8, bool, f32 }.
pub fn resourceFromState(comptime T: type, owner: *verve.Owner, key: []const u8) !?*verve.Resource(T) {
    const v = (verve.islandStateLookup(current_blob, key) catch return null) orelse return null;
    const value: T = switch (T) {
        i32 => if (v == .i32) v.i32 else return null,
        bool => if (v == .bool) v.bool else return null,
        f32 => if (v == .f32) v.f32 else return null,
        // Dupe the string into the island's owner arena. `current_blob` aliases
        // a shared scratch buffer the NEXT island's hydrate overwrites, so a
        // borrowed slice would dangle once another island mounts; the arena
        // copy lives as long as the island (freed on its unmount).
        []const u8 => if (v == .str) try owner.allocator().dupe(u8, v.str) else return null,
        else => @compileError("resourceFromState: unsupported T " ++ @typeName(T)),
    };
    return try verve.resourceReady(T, owner, value);
}

// ---- tests ---------------------------------------------------------------

const testing = std.testing;

test "resourceFromState decodes a ready primitive without fetching" {
    var owner = verve.Owner.init(testing.allocator);
    verve.setReactivePendingAllocator(owner.allocator());
    defer owner.dispose();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try verve.islandStateEncodeEntry(testing.allocator, &buf, "n", .{ .i32 = 7 });
    try verve.islandStateEncodeEntry(testing.allocator, &buf, "label", .{ .str = "hi" });

    setCurrentBlob(buf.items);
    defer setCurrentBlob(&.{});

    const r_n = (try resourceFromState(i32, &owner, "n")).?;
    try testing.expectEqual(@as(i32, 7), r_n.get().?);

    const r_label = (try resourceFromState([]const u8, &owner, "label")).?;
    try testing.expectEqualStrings("hi", r_label.get().?);

    try testing.expect((try resourceFromState(i32, &owner, "nope")) == null);

    // The string value is duped into the owner arena, so it survives the next
    // island's blob overwriting the shared scratch buffer.
    var other: std.ArrayListUnmanaged(u8) = .empty;
    defer other.deinit(testing.allocator);
    try verve.islandStateEncodeEntry(testing.allocator, &other, "x", .{ .str = "ZZZZ" });
    setCurrentBlob(other.items);
    try testing.expectEqualStrings("hi", r_label.get().?);
}

test "resourceStructFromState decodes a struct value" {
    var owner = verve.Owner.init(testing.allocator);
    verve.setReactivePendingAllocator(owner.allocator());
    defer owner.dispose();

    const Cfg = struct { w: u32, name: []const u8 };
    const sbytes = try verve.serializeEncodeToBytes(Cfg{ .w = 9, .name = "hi" }, testing.allocator);
    defer testing.allocator.free(sbytes);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try verve.islandStateEncodeEntry(testing.allocator, &buf, "cfg", .{ .str = sbytes });
    setCurrentBlob(buf.items);
    defer setCurrentBlob(&.{});

    const r = (try resourceStructFromState(Cfg, &owner, "cfg")).?;
    try testing.expectEqual(@as(u32, 9), r.get().?.w);
    try testing.expectEqualStrings("hi", r.get().?.name);
}
