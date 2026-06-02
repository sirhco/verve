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

test "generated stub: _call delivers the typed result to on_reply (native)" {
    app.last_count.store(7, .monotonic);
    defer app.last_count.store(0, .monotonic);

    const Sink = struct {
        var got: i32 = -1;
        fn onReply(v: i32) void {
            got = v;
        }
    };
    Sink.got = -1;
    // Native path: runs synchronously, unwraps the `!i32`, fires the callback.
    // (The wasm `_call` round-trip — POST + correlated reply — now ships:
    // app_client is compiled into the wasm client and the path is exercised
    // via the `/counter` "call +" demo button. Automated browser execution is
    // not wired, so this test covers only the native branch.)
    app_client.getCount_call(testing.allocator, .{}, Sink.onReply);
    try testing.expectEqual(@as(i32, 7), Sink.got);
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

test "generated stub: _post variant runs the action and drops the return" {
    app.last_count.store(5, .monotonic);
    defer app.last_count.store(0, .monotonic);

    // `incrementCount` returns i32 — on native, `_post` invokes it
    // and silently discards the value. State still advances.
    app_client.incrementCount_post(testing.allocator, .{});
    try testing.expectEqual(@as(i32, 6), app.last_count.load(.monotonic));
}

test "generated stub: _post variant absorbs errors on void-returning actions" {
    // `updateDatabase` returns `!void`. On native, `_post` invokes it
    // and discards both the success and error paths.
    defer app.last_count.store(0, .monotonic);
    app_client.updateDatabase_post(testing.allocator, .{ .new_count = 99 });
    try testing.expectEqual(@as(i32, 99), app.last_count.load(.monotonic));
}
