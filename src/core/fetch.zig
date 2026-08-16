//! Server-side outbound HTTP. Thin wrapper over `std.http.Client.fetch`
//! so route renders can call upstream services without re-doing TLS,
//! redirect handling, and response decoding for each call site.
//!
//! `ctx.fetch(url, opts)` returns a `FetchResponse { status, body }`
//! where `body` is allocated from the request arena (so it lives
//! exactly as long as the render). Use `.json(T)` to decode the body
//! into a typed Zig value.
//!
//! The wasm client target stubs this out — outbound HTTP from the
//! browser goes through `fetch()` / XHR, exposed in a future phase as
//! `Resource(T)` or a typed Server Function.

const std = @import("std");
const builtin = @import("builtin");
const Writer = std.Io.Writer;

const is_wasm = builtin.target.cpu.arch.isWasm();

pub const FetchOptions = struct {
    method: std.http.Method = .GET,
    body: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    extra_headers: []const std.http.Header = &.{},
    /// Bound on the response body; oversized responses are truncated to
    /// this limit and `.truncated = true` is set. Defaults to 1 MB.
    max_body: usize = 1 * 1024 * 1024,
    /// Accepted, but **not enforced** — the underlying `std.http.Client.fetch`
    /// call has no deadline hook this wrapper can attach to, so a hung
    /// upstream blocks the caller indefinitely regardless of this value.
    /// Callers on a path that cannot tolerate that (an agent loop waiting on
    /// a model response) must wrap the call themselves (e.g. race it against
    /// a timer on a separate task). Setting this logs a warning so the gap
    /// isn't silently invisible.
    timeout_ns: ?u64 = null,
    /// The `std.Io` implementation to run the request on. `std.http.Client`
    /// requires one (Zig 0.16 has no ambient default) — when omitted, a
    /// process-lifetime single-threaded `Io` is used, which is enough for a
    /// simple blocking fetch but shares no connection pool or thread budget
    /// with the caller's own `Io`. Prefer passing the caller's `Io`
    /// (`ctx.fetch` does this automatically from `Context.io`).
    io: ?std.Io = null,
};

pub const FetchResponse = struct {
    status: u16,
    body: []const u8,
    truncated: bool = false,
    arena: std.mem.Allocator,

    /// Parse the body as JSON into the provided type. The allocated
    /// value lives in the arena the response was allocated from.
    ///
    /// Returns `error.ResponseTruncated` rather than attempting to parse a
    /// body that was cut short by `max_body` — a truncated JSON document
    /// either fails to parse (informative) or, worse, parses into a
    /// partially-populated value that looks legitimate. Callers that want
    /// the truncated bytes anyway can still read `.body` directly.
    pub fn json(self: FetchResponse, comptime T: type) !T {
        if (self.truncated) return error.ResponseTruncated;
        const parsed = try std.json.parseFromSliceLeaky(T, self.arena, self.body, .{
            .ignore_unknown_fields = true,
        });
        return parsed;
    }
};

pub const FetchError = error{
    UnsupportedOnClient,
    HttpError,
    OutOfMemory,
};

/// One-shot fetch. `arena` is typically the request arena so the body
/// is freed when the render completes.
pub fn fetch(arena: std.mem.Allocator, url: []const u8, opts: FetchOptions) !FetchResponse {
    if (is_wasm) return error.UnsupportedOnClient;

    if (opts.timeout_ns != null) {
        // Log the fact only, never the URL: query strings carry credentials
        // (API keys, signed URLs) often enough that logging them
        // unconditionally is a habit worth not forming.
        std.log.scoped(.verve_fetch).warn(
            "fetch: timeout_ns is set but not enforced — a hung upstream will block indefinitely",
            .{},
        );
    }

    // `std.http.Client.io` has no default in Zig 0.16 (ambient process Io
    // was removed) — it must always be supplied. `ctx.fetch` threads the
    // server's own `Io` through automatically; a caller with no `Io` of its
    // own (a standalone tool, a test) falls back to a process-lifetime
    // single-threaded instance.
    const io: std.Io = opts.io orelse std.Io.Threaded.global_single_threaded.io();

    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    var aw: Writer.Allocating = .init(arena);
    defer aw.deinit();

    var headers_buf = std.ArrayList(std.http.Header).empty;
    defer headers_buf.deinit(arena);
    if (opts.content_type) |ct| try headers_buf.append(arena, .{ .name = "content-type", .value = ct });
    for (opts.extra_headers) |h| try headers_buf.append(arena, h);

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = opts.method,
        .payload = opts.body,
        .extra_headers = headers_buf.items,
        .response_writer = &aw.writer,
    }) catch return error.HttpError;

    var body = aw.toOwnedSlice() catch return error.OutOfMemory;
    var truncated = false;
    if (body.len > opts.max_body) {
        body = body[0..opts.max_body];
        truncated = true;
    }

    return .{
        .status = @intFromEnum(result.status),
        .body = body,
        .truncated = truncated,
        .arena = arena,
    };
}

// ---- tests ------------------------------------------------------------
// Network tests are skipped here — std.http.Client is exercised by stdlib's
// own suite. We test the FetchOptions / FetchResponse shape and the json
// decode helper directly.

const testing = std.testing;

test "fetch: truncated response.json() errors instead of parsing garbage" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const body = try arena.allocator().dupe(u8, "{\"name\":\"al");
    const resp: FetchResponse = .{
        .status = 200,
        .body = body,
        .truncated = true,
        .arena = arena.allocator(),
    };

    const Result = struct { name: []const u8 };
    try testing.expectError(error.ResponseTruncated, resp.json(Result));
}

test "FetchResponse.json decodes body into typed struct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const body = try arena.allocator().dupe(u8, "{\"name\":\"alice\",\"age\":33}");
    const resp: FetchResponse = .{
        .status = 200,
        .body = body,
        .arena = arena.allocator(),
    };

    const Result = struct { name: []const u8, age: u32 };
    const parsed = try resp.json(Result);
    try testing.expectEqualStrings("alice", parsed.name);
    try testing.expectEqual(@as(u32, 33), parsed.age);
}
