//! Server-function bridge. Already-existing `app.Actions` provides
//! the wire endpoint side: each `pub fn` in that namespace becomes a
//! `POST /api/<name>` handler with JSON/form arg decoding handled at
//! comptime via reflection on the arg struct.
//!
//! This module adds two ergonomic pieces on top:
//!
//!   - `ctx.serverFn(fn_ref, args)` — invoke the same fn directly
//!     from a render, no network roundtrip. Returns the function's
//!     real return type so callers don't have to manually re-decode
//!     `{ "value": ... }`.
//!
//!   - A small JS helper `verveServerFn(name, args)` exposed via the
//!     bridge that issues the corresponding POST from WASM/JS land
//!     with sane defaults (CSRF cookie included by the browser, JSON
//!     body, type-tagged response).
//!
//! Phase 3's plan deferred full comptime-generated client-side stubs
//! to Phase 8 (where the WASM client gets its own reactive runtime).
//! Until then, `verveServerFn(name, args)` is the unified call site.

const std = @import("std");

/// Direct-call helper. `f` must be a function whose single arg is a
/// struct type (matches the existing `app.Actions` convention). When
/// the call originates from a render — i.e. server-side — we can
/// invoke it directly and skip the JSON-encode → HTTP → JSON-decode
/// roundtrip the client-side path uses.
pub fn call(comptime f: anytype, args: anytype) blk: {
    const ret = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
    break :blk ret;
} {
    return f(args);
}

// ---- tests ------------------------------------------------------------

const testing = std.testing;

test "call invokes a function with struct arg" {
    const Args = struct { name: []const u8 };
    const Greeter = struct {
        fn run(args: Args) []const u8 {
            return args.name;
        }
    };
    const result = call(Greeter.run, Args{ .name = "alice" });
    try testing.expectEqualStrings("alice", result);
}
