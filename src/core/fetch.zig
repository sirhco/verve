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
    /// Time budget for the whole roundtrip. Not enforced when null;
    /// callers wanting hard deadlines must wrap the call themselves.
    timeout_ns: ?u64 = null,
};

pub const FetchResponse = struct {
    status: u16,
    body: []const u8,
    truncated: bool = false,
    arena: std.mem.Allocator,

    /// Parse the body as JSON into the provided type. The allocated
    /// value lives in the arena the response was allocated from.
    pub fn json(self: FetchResponse, comptime T: type) !T {
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

    var client: std.http.Client = .{ .allocator = arena };
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
