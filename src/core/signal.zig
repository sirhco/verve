//! Reactive value holder. Server uses Signal only as a value carrier during
//! render (no listeners fire). WASM client wires listeners on hydrate.

const std = @import("std");

pub fn Signal(comptime T: type) type {
    return struct {
        value: T,
        listeners: std.ArrayList(Listener),

        const Self = @This();
        pub const Listener = *const fn (new_value: T) void;

        pub fn init(initial: T) Self {
            return .{
                .value = initial,
                .listeners = .empty,
            };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.listeners.deinit(gpa);
        }

        pub fn get(self: *const Self) T {
            return self.value;
        }

        pub fn set(self: *Self, new_value: T) void {
            if (std.meta.eql(self.value, new_value)) return;
            self.value = new_value;
            for (self.listeners.items) |listener| {
                listener(new_value);
            }
        }

        pub fn subscribe(self: *Self, gpa: std.mem.Allocator, listener: Listener) !void {
            try self.listeners.append(gpa, listener);
        }

        pub fn increment(self: *Self) void {
            comptime if (@typeInfo(T) != .int and @typeInfo(T) != .float) {
                @compileError("Signal.increment only valid for numeric T");
            };
            self.set(self.value + 1);
        }

        pub fn decrement(self: *Self) void {
            comptime if (@typeInfo(T) != .int and @typeInfo(T) != .float) {
                @compileError("Signal.decrement only valid for numeric T");
            };
            self.set(self.value - 1);
        }
    };
}

test "Signal stores and updates value" {
    var sig = Signal(i32).init(0);
    defer sig.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i32, 0), sig.get());
    sig.set(42);
    try std.testing.expectEqual(@as(i32, 42), sig.get());
    sig.increment();
    try std.testing.expectEqual(@as(i32, 43), sig.get());
    sig.decrement();
    sig.decrement();
    try std.testing.expectEqual(@as(i32, 41), sig.get());
}

test "Signal listeners fire on change, not on no-op set" {
    const Counter = struct {
        var fire_count: u32 = 0;
        fn onChange(_: i32) void {
            fire_count += 1;
        }
    };
    Counter.fire_count = 0;

    var sig = Signal(i32).init(0);
    defer sig.deinit(std.testing.allocator);
    try sig.subscribe(std.testing.allocator, &Counter.onChange);

    sig.set(1);
    sig.set(1);
    sig.set(2);
    try std.testing.expectEqual(@as(u32, 2), Counter.fire_count);
}
