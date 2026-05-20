//! Owner-bound storage cell for a single value of type T. Mirrors
//! Leptos's `StoredValue` / `ArenaItem`: a place to park a non-reactive
//! value (a parsed config, a connection handle, a string buffer) inside
//! the current reactive scope so that disposing the owner reclaims it
//! deterministically.
//!
//! Unlike `Signal`, reading a `StoredValue` does not subscribe the
//! current effect — it's a value handle, not a reactive primitive.

const std = @import("std");
const Owner = @import("owner.zig").Owner;

pub fn StoredValue(comptime T: type) type {
    return struct {
        value: T,

        const Self = @This();

        pub fn get(self: *const Self) T {
            return self.value;
        }

        pub fn getPtr(self: *Self) *T {
            return &self.value;
        }

        pub fn set(self: *Self, new_value: T) void {
            self.value = new_value;
        }
    };
}

/// Allocate a StoredValue under `owner`, initialize it with
/// `initial_value`, and return the handle. The memory lives in the
/// owner's arena and is reclaimed when the owner disposes.
pub fn create(comptime T: type, owner: *Owner, initial_value: T) !*StoredValue(T) {
    const stored = try owner.allocator().create(StoredValue(T));
    stored.* = .{ .value = initial_value };
    return stored;
}

test "StoredValue stores and updates a value" {
    var owner = Owner.init(std.testing.allocator);
    defer owner.dispose();

    const sv = try create(i32, &owner, 7);
    try std.testing.expectEqual(@as(i32, 7), sv.get());
    sv.set(42);
    try std.testing.expectEqual(@as(i32, 42), sv.get());
}

test "StoredValue holds a struct" {
    const Config = struct { name: []const u8, max: u32 };
    var owner = Owner.init(std.testing.allocator);
    defer owner.dispose();

    const sv = try create(Config, &owner, .{ .name = "alpha", .max = 10 });
    try std.testing.expectEqualStrings("alpha", sv.get().name);
    try std.testing.expectEqual(@as(u32, 10), sv.get().max);
}
