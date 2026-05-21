//! Phase 11 — typed client stubs for `app.Actions`.
//!
//! `tools/server_fn_codegen.zig` walks `app.Actions` at build time and
//! emits a per-action wrapper in `app_client.zig`. Each wrapper carries
//! the action's real argument struct + return type and delegates the
//! actual call to `invoke` below.
//!
//! On the native target `invoke` short-circuits to a direct call — same
//! body as `ctx.serverFn(f, args)` but reachable without a Context.
//! WASM-side typed stubs await Phase 12's async runtime; the generated
//! file is therefore imported by the server module only.

const std = @import("std");

/// Direct-call wrapper used by every generated stub. The arena is kept
/// in the signature for forward-compatibility with the Phase 12 WASM
/// path (which will use it for JSON serialization) — the native body
/// discards it.
pub fn invoke(
    comptime f: anytype,
    arena: std.mem.Allocator,
    args: @typeInfo(@TypeOf(f)).@"fn".params[0].type.?,
    comptime name: []const u8,
) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    _ = arena;
    _ = name;
    return f(args);
}

const testing = std.testing;

test "invoke calls action directly" {
    const Actions = struct {
        pub fn double(args: struct { n: i32 }) i32 {
            return args.n * 2;
        }
    };
    const result = invoke(Actions.double, testing.allocator, .{ .n = 7 }, "double");
    try testing.expectEqual(@as(i32, 14), result);
}

test "invoke propagates errors" {
    const Actions = struct {
        pub fn maybeFail(args: struct { ok: bool }) !i32 {
            if (!args.ok) return error.Boom;
            return 99;
        }
    };
    try testing.expectEqual(
        @as(i32, 99),
        try invoke(Actions.maybeFail, testing.allocator, .{ .ok = true }, "maybeFail"),
    );
    try testing.expectError(
        error.Boom,
        invoke(Actions.maybeFail, testing.allocator, .{ .ok = false }, "maybeFail"),
    );
}

test "invoke handles void return" {
    const State = struct {
        var hit: bool = false;
    };
    const Actions = struct {
        pub fn ping(_: struct {}) void {
            State.hit = true;
        }
    };
    State.hit = false;
    invoke(Actions.ping, testing.allocator, .{}, "ping");
    try testing.expect(State.hit);
}
