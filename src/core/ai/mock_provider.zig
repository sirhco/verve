//! A scripted `Provider` for deterministic tests and CI without a live API
//! key. Ships in the module rather than staying test-only — an app's own
//! test suite (and Task 8's example app) drive `agent.run` against a fixed
//! script the same way a real host drives it against `anthropic.zig`.

const std = @import("std");
const prov = @import("provider.zig");

pub const MockProvider = struct {
    /// The turns to hand back, in order — one `complete` call per entry.
    turns: []const prov.Response,
    cursor: usize = 0,

    /// Build the `Provider` vtable value for this instance. `self` must
    /// outlive the returned `Provider` — it holds `self`'s address, not a
    /// copy.
    pub fn provider(self: *MockProvider) prov.Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: prov.Provider.VTable = .{
        .capabilities = capabilities,
        .complete = complete,
    };

    fn capabilities(ptr: *anyopaque) prov.Capabilities {
        _ = ptr;
        return .{ .native_tools = true };
    }

    fn complete(ptr: *anyopaque, arena: std.mem.Allocator, req: prov.Request) anyerror!prov.Response {
        _ = arena;
        _ = req;
        const self: *MockProvider = @ptrCast(@alignCast(ptr));
        if (self.cursor >= self.turns.len) return error.MockExhausted;
        const res = self.turns[self.cursor];
        self.cursor += 1;
        return res;
    }
};

// ---- tests ------------------------------------------------------------

test "mock_provider: scripted turns return in order, then MockExhausted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var mock: MockProvider = .{ .turns = &.{
        .{ .stop_reason = .end_turn, .blocks = &.{.{ .text = "first" }} },
        .{ .stop_reason = .end_turn, .blocks = &.{.{ .text = "second" }} },
    } };
    const p = mock.provider();

    try std.testing.expect(p.capabilities().native_tools);

    const req: prov.Request = .{ .model = "m", .messages = &.{} };

    const r1 = try p.complete(arena.allocator(), req);
    try std.testing.expectEqualStrings("first", r1.blocks[0].text);

    const r2 = try p.complete(arena.allocator(), req);
    try std.testing.expectEqualStrings("second", r2.blocks[0].text);

    try std.testing.expectError(error.MockExhausted, p.complete(arena.allocator(), req));
}
