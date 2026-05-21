//! Phase 11 — exercise the generated `app_client.zig` stubs.
//!
//! `build.zig` runs `tools/server_fn_codegen.zig` over `app.Actions`
//! and feeds the result into the build's WriteFiles. The tests here
//! pull that generated module in and verify the typed wrappers reach
//! the matching action directly (no HTTP roundtrip).

const std = @import("std");
const app = @import("app");
const app_client = @import("app_client");
const testing = std.testing;

test "generated stub: getCount mirrors app.Actions counter" {
    app.last_count.store(7, .monotonic);
    defer app.last_count.store(0, .monotonic);

    const observed = try app_client.getCount(testing.allocator, .{});
    try testing.expectEqual(@as(i32, 7), observed);
}

test "generated stub: updateDatabase + getCount roundtrip" {
    defer app.last_count.store(0, .monotonic);

    try app_client.updateDatabase(testing.allocator, .{ .new_count = 42 });
    const observed = try app_client.getCount(testing.allocator, .{});
    try testing.expectEqual(@as(i32, 42), observed);
}

test "generated stub: incrementCount preserves return type" {
    app.last_count.store(0, .monotonic);
    defer app.last_count.store(0, .monotonic);

    const after = app_client.incrementCount(testing.allocator, .{});
    try testing.expectEqual(@as(i32, 1), after);
    try testing.expectEqual(@as(i32, 1), app.last_count.load(.monotonic));
}
