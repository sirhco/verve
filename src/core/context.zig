//! Per-render context. Owns an arena that is wiped at end of request.

const std = @import("std");
const Signal = @import("signal.zig").Signal;

pub const Context = struct {
    arena: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    pub fn init(arena: *std.heap.ArenaAllocator) Context {
        return .{
            .arena = arena,
            .allocator = arena.allocator(),
        };
    }

    /// Allocate a Signal in the arena. Returned pointer is valid until the
    /// arena is reset/deinit.
    pub fn useSignal(self: *const Context, comptime T: type, initial: T) !*Signal(T) {
        const sig = try self.allocator.create(Signal(T));
        sig.* = Signal(T).init(initial);
        return sig;
    }

    /// Pass-through helper for components that want the arena allocator.
    pub fn alloc(self: *const Context) std.mem.Allocator {
        return self.allocator;
    }
};

test "Context allocates signals in arena" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const ctx = Context.init(&arena);
    const sig = try ctx.useSignal(i32, 7);
    try std.testing.expectEqual(@as(i32, 7), sig.get());
    sig.set(8);
    try std.testing.expectEqual(@as(i32, 8), sig.get());
}
