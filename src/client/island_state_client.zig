//! Client-side resource-state hydration. The bridge stages the hydrating
//! island's serialized state blob (via `verve_set_island_state`); chunks read
//! it with `resourceFromState(T, key)` to reconstruct a `.ready` Resource.

const std = @import("std");
const verve = @import("verve");

var current_blob: []const u8 = &.{};

pub fn setCurrentBlob(blob: []const u8) void {
    current_blob = blob;
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
        []const u8 => if (v == .str) v.str else return null,
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
}
