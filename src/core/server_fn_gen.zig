//! Phase 11 + 11B — typed client stubs for `app.Actions`.
//!
//! `tools/server_fn_codegen.zig` walks `app.Actions` at build time and
//! emits per-action wrappers in `app_client.zig`:
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
//!
//!   - `<name>_call(arena, args, on_reply)` — typed callback. Native runs
//!     the action synchronously and fires `on_reply`. WASM serializes args,
//!     registers a correlated one-shot decoder (`registerCall`/`Decoder`),
//!     and posts with a request id; the reply decodes the typed value and
//!     fires `on_reply`. The client wires this up via `installWasmHooks`.

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
                rid: u32,
            ) void;
        };
        // `_post` is fire-and-forget — no correlation (rid 0).
        wasm_bridge.server_fn_post(name.ptr, name.len, json.ptr, json.len, 0);
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

/// Typed call with a result callback. On native this runs synchronously —
/// invokes the action and hands the unwrapped success value to `on_reply`;
/// errors skip the callback. On wasm, serializes `args` to JSON, registers
/// a correlated typed decoder via `registerCall`, and posts to the JS bridge;
/// `on_reply` fires later when the bridge delivers the reply. Void actions
/// on wasm post fire-and-forget (no rid, no decoder registered).
///
/// Precondition (wasm): the client must have called `installWasmHooks`
/// (done at hydrate) before any value-returning `_call`. If the hooks are
/// unset, `registerCall` returns rid 0 and the request posts fire-and-forget
/// — `on_reply` never fires. In normal use `_call` is user-triggered after
/// hydration, so the hooks are always installed by then.
pub fn call(
    comptime f: anytype,
    arena: std.mem.Allocator,
    args: @typeInfo(@TypeOf(f)).@"fn".params[0].type.?,
    comptime name: []const u8,
    comptime on_reply: anytype,
) void {
    const RetT = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
    const SuccessT = switch (@typeInfo(RetT)) {
        .error_union => |eu| eu.payload,
        else => RetT,
    };

    if (builtin.target.cpu.arch.isWasm()) {
        const json = std.json.Stringify.valueAlloc(arena, args, .{}) catch return;
        const wasm_bridge = struct {
            extern "verve" fn server_fn_post(
                name_ptr: [*]const u8,
                name_len: usize,
                body_ptr: [*]const u8,
                body_len: usize,
                rid: u32,
            ) void;
        };
        if (SuccessT == void) {
            // Nothing to deliver — behave like `_post` (fire-and-forget).
            wasm_bridge.server_fn_post(name.ptr, name.len, json.ptr, json.len, 0);
        } else {
            const rid = registerCall(SuccessT, name, on_reply);
            wasm_bridge.server_fn_post(name.ptr, name.len, json.ptr, json.len, rid);
        }
    } else {
        // Native: run the action synchronously, hand the unwrapped value
        // to on_reply. Errors skip the callback.
        const ret = invoke(f, arena, args, name);
        if (@typeInfo(RetT) == .error_union) {
            const v = ret catch return;
            on_reply(v);
        } else {
            on_reply(ret);
        }
    }
}

/// Installed by the wasm client at startup so the target-agnostic `call`
/// glue can reach the client runtime's correlation + allocation surface
/// without `core/` importing `client/`. Null on native and until install.
pub const RegisterOnceFn =
    *const fn (route: []const u8, rid: u32, handler: *const fn ([*]const u8, u32) void) void;
pub const NextRidFn = *const fn () u32;
pub const DecodeAllocFn = *const fn () std.mem.Allocator;

// NOTE: wasm-only by design (single-threaded); not synchronized. On native
// they stay null except in this file's own tests.
var register_once_hook: ?RegisterOnceFn = null;
var next_rid_hook: ?NextRidFn = null;
var decode_alloc_hook: ?DecodeAllocFn = null;

/// Wire the wasm `_call` round-trip to the client runtime. Called once
/// from `src/client/main.zig` at hydrate.
pub fn installWasmHooks(
    next_rid: NextRidFn,
    register_once: RegisterOnceFn,
    decode_alloc: DecodeAllocFn,
) void {
    next_rid_hook = next_rid;
    register_once_hook = register_once;
    decode_alloc_hook = decode_alloc;
}

/// Comptime-monomorphic reply decoder. One distinct `handle` per
/// `(SuccessT, on_reply)` call site. Parses the server reply shape
/// `{"rid":N,"value":<T>}` against the installed decode allocator and
/// fires `on_reply` with the unwrapped value. Malformed or value-less
/// replies skip the callback. NOTE: for slice-typed `SuccessT`, the
/// decoded value is freed when `handle` returns — `on_reply` must copy
/// anything it keeps.
fn Decoder(comptime SuccessT: type, comptime on_reply: anytype) type {
    return struct {
        fn handle(ptr: [*]const u8, len: u32) void {
            const body = ptr[0..len];
            // Hooks cleared between registration and reply (e.g. test
            // teardown) → silently drop this reply rather than crash.
            const a = decode_alloc_hook orelse return;
            // rid correlation already happened in the client runtime's
            // dispatchResponse (it matches slot.rid == reply_rid before
            // invoking this handler), so decode only the typed value; any
            // other reply fields (rid, ok, …) are ignored.
            const Reply = struct { value: SuccessT };
            const parsed = std.json.parseFromSlice(
                Reply,
                a(),
                body,
                .{ .ignore_unknown_fields = true },
            ) catch return;
            defer parsed.deinit();
            on_reply(parsed.value.value);
        }
    };
}

/// Allocate a correlation id and register the typed one-shot decoder for
/// `name`'s reply. Target-agnostic (the wasm `call` branch posts after
/// this returns). Returns the rid, or 0 when hooks aren't installed.
fn registerCall(
    comptime SuccessT: type,
    comptime name: []const u8,
    comptime on_reply: anytype,
) u32 {
    const next_rid = next_rid_hook orelse return 0;
    const register_once = register_once_hook orelse return 0;
    const rid = next_rid();
    register_once(name, rid, &Decoder(SuccessT, on_reply).handle);
    return rid;
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

test "call delivers the unwrapped result to on_reply" {
    const Actions = struct {
        pub fn double(args: struct { n: i32 }) i32 {
            return args.n * 2;
        }
    };
    const Sink = struct {
        var got: i32 = 0;
        fn onReply(v: i32) void {
            got = v;
        }
    };
    Sink.got = 0;
    call(Actions.double, testing.allocator, .{ .n = 9 }, "double", Sink.onReply);
    try testing.expectEqual(@as(i32, 18), Sink.got);
}

test "call skips on_reply on error" {
    const Actions = struct {
        pub fn maybeFail(args: struct { ok: bool }) !i32 {
            if (!args.ok) return error.Boom;
            return 7;
        }
    };
    const Sink = struct {
        var fired: bool = false;
        var got: i32 = -1;
        fn onReply(v: i32) void {
            fired = true;
            got = v;
        }
    };
    Sink.fired = false;
    Sink.got = -1;
    call(Actions.maybeFail, testing.allocator, .{ .ok = false }, "maybeFail", Sink.onReply);
    try testing.expect(!Sink.fired);

    call(Actions.maybeFail, testing.allocator, .{ .ok = true }, "maybeFail", Sink.onReply);
    try testing.expect(Sink.fired);
    try testing.expectEqual(@as(i32, 7), Sink.got);
}

// Testing only — reset hook state between tests.
fn clearHooksForTesting() void {
    next_rid_hook = null;
    register_once_hook = null;
    decode_alloc_hook = null;
}

test "registerCall allocates a rid and registers a one-shot decoder under the action name" {
    const Fake = struct {
        var seq: u32 = 0;
        var route: []const u8 = "";
        var rid: u32 = 0;
        var handler: ?*const fn ([*]const u8, u32) void = null;
        fn nextRid() u32 {
            seq += 1;
            return seq;
        }
        fn registerOnce(r: []const u8, id: u32, h: *const fn ([*]const u8, u32) void) void {
            route = r;
            rid = id;
            handler = h;
        }
        fn alloc() std.mem.Allocator {
            return testing.allocator;
        }
    };
    Fake.seq = 0;
    Fake.handler = null;
    installWasmHooks(Fake.nextRid, Fake.registerOnce, Fake.alloc);
    defer clearHooksForTesting();

    const Sink = struct {
        var got: i32 = 0;
        fn onReply(v: i32) void {
            got = v;
        }
    };
    Sink.got = 0;

    const rid = registerCall(i32, "incrementCount", Sink.onReply);
    try testing.expectEqual(@as(u32, 1), rid);
    try testing.expectEqualStrings("incrementCount", Fake.route);
    try testing.expectEqual(@as(u32, 1), Fake.rid);
    try testing.expect(Fake.handler != null);

    const body = "{\"rid\":1,\"value\":42}";
    Fake.handler.?(body.ptr, @intCast(body.len));
    try testing.expectEqual(@as(i32, 42), Sink.got);
}

test "decoder skips on_reply when the reply has no value field" {
    const Fake = struct {
        var handler: ?*const fn ([*]const u8, u32) void = null;
        fn nextRid() u32 {
            return 7;
        }
        fn registerOnce(_: []const u8, _: u32, h: *const fn ([*]const u8, u32) void) void {
            handler = h;
        }
        fn alloc() std.mem.Allocator {
            return testing.allocator;
        }
    };
    Fake.handler = null;
    installWasmHooks(Fake.nextRid, Fake.registerOnce, Fake.alloc);
    defer clearHooksForTesting();

    const Sink = struct {
        var fired: bool = false;
        fn onReply(_: i32) void {
            fired = true;
        }
    };
    Sink.fired = false;

    _ = registerCall(i32, "getCount", Sink.onReply);
    const body = "{\"rid\":7,\"ok\":true}";
    Fake.handler.?(body.ptr, @intCast(body.len));
    try testing.expect(!Sink.fired);
}

test "registerCall returns 0 when hooks are not installed" {
    clearHooksForTesting();
    const Sink = struct {
        fn onReply(_: i32) void {}
    };
    try testing.expectEqual(@as(u32, 0), registerCall(i32, "noop", Sink.onReply));
}
