//! Client-side signal. Mutating the value emits a single DOM update to all
//! elements with matching `z-bind` attribute via the JS bridge. Lighter than
//! the server-side Signal (no listener list, no allocator) — wasm has no
//! allocator at MVP scope and only needs one observer per binding.

const dom = @import("dom.zig");

pub fn ClientSignal(comptime T: type) type {
    return struct {
        bind: []const u8,
        value: T,

        const Self = @This();

        pub fn init(bind: []const u8, initial: T) Self {
            return .{ .bind = bind, .value = initial };
        }

        pub fn get(self: *const Self) T {
            return self.value;
        }

        pub fn set(self: *Self, new_value: T) void {
            self.value = new_value;
            emit(T, self.bind, new_value);
        }

        pub fn increment(self: *Self) void {
            comptime if (@typeInfo(T) != .int) {
                @compileError("ClientSignal.increment only valid for integer T");
            };
            self.set(self.value + 1);
        }

        pub fn decrement(self: *Self) void {
            comptime if (@typeInfo(T) != .int) {
                @compileError("ClientSignal.decrement only valid for integer T");
            };
            self.set(self.value - 1);
        }
    };
}

fn emit(comptime T: type, bind: []const u8, value: T) void {
    if (T == i32) {
        dom.set_text_by_bind_i32(bind.ptr, bind.len, value);
        return;
    }
    @compileError("ClientSignal: unsupported value type " ++ @typeName(T));
}
