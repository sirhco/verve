//! Phase 11 + 11B — typed client stubs for `app.Actions`.
//!
//! `tools/server_fn_codegen.zig` walks `app.Actions` at build time and
//! emits a pair of per-action wrappers in `app_client.zig`:
//!
//!   - `<name>(arena, args) → Ret` — typed synchronous invocation.
//!     Native callers reach the action directly via `invoke`. WASM
//!     callers needing a typed return wait for the streaming async
//!     runtime; today this path is server-side only.
//!
//!   - `<name>_post(arena, args)` — fire-and-forget JSON POST. The
//!     WASM target serializes `args` to JSON via the scratch arena
//!     and hands the bytes to a JS-bridge fetch; the native target
//!     invokes the action directly and drops the result so the same
//!     symbol stays callable across targets without a `comptime if`
//!     at every call site.

const std = @import("std");
const builtin = @import("builtin");

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

/// Fire-and-forget dispatch. On WASM, serializes `args` to JSON and
/// hands the bytes to the JS bridge via the `server_fn_post` extern;
/// the bridge posts to `/api/<name>` and discards the response. On
/// native, falls back to calling the action directly so the same
/// symbol works in either build. Errors during serialization or the
/// native call are silently absorbed — `post` is the fire-and-forget
/// path by definition.
pub fn post(
    comptime f: anytype,
    arena: std.mem.Allocator,
    args: @typeInfo(@TypeOf(f)).@"fn".params[0].type.?,
    comptime name: []const u8,
) void {
    if (builtin.target.cpu.arch.isWasm()) {
        const json = std.json.Stringify.valueAlloc(arena, args, .{}) catch return;
        const wasm_bridge = struct {
            extern "verve" fn server_fn_post(
                name_ptr: [*]const u8,
                name_len: usize,
                body_ptr: [*]const u8,
                body_len: usize,
            ) void;
        };
        wasm_bridge.server_fn_post(name.ptr, name.len, json.ptr, json.len);
    } else {
        // Native path: invoke directly, discard the result. Matches
        // the contract that `_post` is best-effort. `arena` + `name`
        // are unused on this branch — the comptime-dead WASM branch
        // counts as the "use" Zig requires.
        const ret = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
        const ret_info = @typeInfo(ret);
        if (ret_info == .error_union) {
            _ = f(args) catch return;
        } else {
            _ = f(args);
        }
    }
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
