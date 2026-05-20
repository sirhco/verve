//! Field-grained reactive struct. `createStore(T, owner, init)`
//! returns a wrapper whose per-field reads subscribe the current
//! effect to a `Signal(field_type)` for THAT field only. Writes
//! through `set(.field, value)` notify just that field's
//! subscribers, leaving consumers of other fields undisturbed.
//!
//! This is the field-granular analog of `Signal(MyStruct)`, where
//! a single `Signal.set(new_struct)` would notify every reader even
//! if only one field changed.
//!
//! Implementation: signals are stored in a comptime-built tuple
//! parallel to T's field declaration order. Lookups by `.field_name`
//! resolve at comptime to a tuple index — same performance shape as
//! field access on the wrapped struct.

const std = @import("std");
const Owner = @import("owner.zig").Owner;
const Signal = @import("signal.zig").Signal;

pub fn Store(comptime T: type) type {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("Store requires a struct type, got " ++ @typeName(T));
    const fields = info.@"struct".fields;

    const SigTuple = blk: {
        var types: [fields.len]type = undefined;
        for (fields, 0..) |f, i| types[i] = *Signal(f.type);
        break :blk std.meta.Tuple(&types);
    };

    return struct {
        signals: SigTuple,
        owner: *Owner,

        const Self = @This();

        fn fieldIndex(comptime name: []const u8) comptime_int {
            inline for (fields, 0..) |f, i| {
                if (comptime std.mem.eql(u8, f.name, name)) return i;
            }
            @compileError("no field named '" ++ name ++ "' in Store(" ++ @typeName(T) ++ ")");
        }

        /// Read a field reactively. Subscribes the active effect to
        /// the field's signal so changes to other fields don't fire.
        pub fn get(self: *const Self, comptime field: anytype) fields[fieldIndex(@tagName(field))].type {
            const idx = comptime fieldIndex(@tagName(field));
            return self.signals[idx].get();
        }

        /// Read a field without tracking. Use when you need the value
        /// but the current effect should NOT re-run on field changes.
        pub fn peek(self: *const Self, comptime field: anytype) fields[fieldIndex(@tagName(field))].type {
            const idx = comptime fieldIndex(@tagName(field));
            return self.signals[idx].peek();
        }

        /// Update a single field. Only consumers of THIS field re-run.
        pub fn set(self: *Self, comptime field: anytype, value: fields[fieldIndex(@tagName(field))].type) void {
            const idx = comptime fieldIndex(@tagName(field));
            self.signals[idx].set(value);
        }
    };
}

/// Allocate a Store(T) under `owner`, initializing each field's
/// Signal with the corresponding value from `initial`.
pub fn create(comptime T: type, owner: *Owner, initial: T) !*Store(T) {
    const info = @typeInfo(T).@"struct";
    const StoreT = Store(T);
    const store = try owner.allocator().create(StoreT);
    store.owner = owner;

    inline for (info.fields, 0..) |f, i| {
        const sig = try owner.allocator().create(Signal(f.type));
        sig.* = Signal(f.type).init(@field(initial, f.name), owner.allocator());
        store.signals[i] = sig;
    }
    return store;
}

// ---- tests ------------------------------------------------------------

const testing = std.testing;
const effect_mod = @import("effect.zig");

test "Store creates per-field signals and supports get/set" {
    var owner = Owner.init(testing.allocator);
    effect_mod.setPendingAllocator(owner.allocator());
    defer owner.dispose();

    const User = struct { name: []const u8, age: u32 };
    const store = try create(User, &owner, .{ .name = "alice", .age = 30 });

    try testing.expectEqualStrings("alice", store.get(.name));
    try testing.expectEqual(@as(u32, 30), store.get(.age));

    store.set(.age, 31);
    try testing.expectEqual(@as(u32, 31), store.get(.age));
    try testing.expectEqualStrings("alice", store.get(.name));
}

test "Store reads are field-grained — name update doesn't fire age effect" {
    var owner = Owner.init(testing.allocator);
    effect_mod.setPendingAllocator(owner.allocator());
    defer owner.dispose();

    const User = struct { name: []const u8, age: u32 };
    const store = try create(User, &owner, .{ .name = "alice", .age = 30 });

    const AgeWatcher = struct {
        var hits: u32 = 0;
        s: *Store(User),
        fn run(self: *@This()) void {
            _ = self.s.get(.age);
            hits += 1;
        }
    };
    AgeWatcher.hits = 0;
    var w: AgeWatcher = .{ .s = store };
    _ = try effect_mod.createEffect(&owner, &w, AgeWatcher.run);

    try testing.expectEqual(@as(u32, 1), AgeWatcher.hits);

    store.set(.name, "bob");
    // Updating .name should not re-run an effect that only read .age.
    try testing.expectEqual(@as(u32, 1), AgeWatcher.hits);

    store.set(.age, 31);
    try testing.expectEqual(@as(u32, 2), AgeWatcher.hits);
}
