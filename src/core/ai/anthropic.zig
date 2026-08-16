//! The Anthropic Messages API (`POST /v1/messages`) as a `provider.Provider`.
//!
//! Wire facts here are authoritative, not guessed:
//! - headers: `x-api-key`, `anthropic-version: 2023-06-01`, `content-type:
//!   application/json`.
//! - the default model, `claude-opus-5`, rejects `temperature`, `top_p`,
//!   `top_k`, and `thinking.budget_tokens` with HTTP 400 — this codec never
//!   sends any of them.
//! - a refusal arrives as HTTP 200 with `stop_reason: "refusal"` and empty
//!   or partial `content`; `message.parseResponse` already surfaces that
//!   correctly, so `complete` just hands its result straight back.
//! - on `claude-opus-5`, thinking is on by default and `max_tokens` caps
//!   thinking *and* visible response text together — callers sizing
//!   `max_tokens` for "just the answer" will get truncated early.

const std = @import("std");
const fetch_mod = @import("../fetch.zig");
const message = @import("message.zig");
const provider_mod = @import("provider.zig");

/// `resolveApiKey`'s environment fallback needs a live process environment,
/// and Zig 0.16 deliberately has no ambient way to read one — `std.process`
/// removed `getEnvVarOwned`; `std.process.Environ` only ever *looks up* a
/// block someone already captured at the real process entry point. The host
/// (see `src/server/main.zig`'s `verve.ai.anthropic.initEnviron` call, next
/// to the CSRF/confirmation-token key seeding) hands that block in once at
/// startup, the same way the Zig test runner populates `std.testing.environ`
/// for tests. Left unset (as it is in every test in this file), the
/// `ANTHROPIC_API_KEY` fallback simply always misses — safe, just inert.
var process_environ_map: ?*const std.process.Environ.Map = null;

/// Call once at process startup with the real environment. See
/// `process_environ_map` for why this exists instead of an ambient lookup.
pub fn initEnviron(map: *const std.process.Environ.Map) void {
    process_environ_map = map;
}

/// An Anthropic Messages API client, wired as a `provider.Provider`.
///
/// `io` and `api_key` default to `null` deliberately: a caller that only
/// wants the environment-variable key resolution and the framework's
/// default `Io` fallback can construct `.{}` and go. Never dereferences
/// `api_key` or logs it — see `resolveApiKey`.
pub const Client = struct {
    /// Explicit key. Takes priority over `ANTHROPIC_API_KEY` when set.
    api_key: ?[]const u8 = null,
    /// The `Io` to run requests on. `null` falls back to `fetch.zig`'s own
    /// process-lifetime default (see `fetch.fetch`).
    io: ?std.Io = null,
    base_url: []const u8 = "https://api.anthropic.com",
    model: []const u8 = "claude-opus-5",
    max_tokens: u32 = 4096,

    /// Build the `Provider` vtable value for this instance. `self` must
    /// outlive the returned `Provider` — it holds `self`'s address, not a
    /// copy.
    pub fn provider(self: *Client) provider_mod.Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: provider_mod.Provider.VTable = .{
        .capabilities = capabilities,
        .complete = complete,
    };

    fn capabilities(ptr: *anyopaque) provider_mod.Capabilities {
        _ = ptr;
        return .{ .native_tools = true };
    }

    fn complete(ptr: *anyopaque, arena: std.mem.Allocator, req: provider_mod.Request) anyerror!provider_mod.Response {
        const self: *Client = @ptrCast(@alignCast(ptr));
        const api_key = try resolveApiKey(self.api_key);

        const body = try buildRequestBody(arena, self.resolveRequest(req));
        const url = try std.fmt.allocPrint(arena, "{s}/v1/messages", .{self.base_url});

        const headers = [_]std.http.Header{
            .{ .name = "x-api-key", .value = api_key },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
        };

        const res = try fetch_mod.fetch(arena, url, .{
            .method = .POST,
            .body = body,
            .content_type = "application/json",
            .extra_headers = &headers,
            // LLM responses with long tool arguments routinely exceed the
            // 1 MB default; 8 MB is the budget for this call specifically.
            .max_body = 8 * 1024 * 1024,
            .io = self.io,
        });

        switch (classifyHttpResult(res)) {
            .http_error => {
                // Status only — the body can echo request content
                // (including tool arguments an app might consider
                // sensitive) back verbatim.
                std.log.scoped(.verve_ai).err("anthropic: http {d}", .{res.status});
                return error.AnthropicHttpError;
            },
            .truncated => return error.ResponseTruncated,
            .ok => {},
        }

        // `message.Response`/`message.Usage` are the literal same types as
        // `provider.Response`/`provider.Usage` (aliased in provider.zig) —
        // handed straight back, no field copy.
        return message.parseResponse(arena, res.body);
    }

    /// Apply this client's configured defaults to whichever `Request` fields
    /// the caller left unset. Split out from `complete()` so the defaulting
    /// itself is unit-testable without a network call — see the
    /// "Client defaults" tests below.
    fn resolveRequest(self: Client, req: provider_mod.Request) ResolvedRequest {
        return .{
            .model = req.model orelse self.model,
            .system = req.system,
            .messages = req.messages,
            .tools_json = req.tools_json,
            .max_tokens = req.max_tokens orelse self.max_tokens,
        };
    }
};

const HttpOutcome = enum { ok, http_error, truncated };

/// Status is checked before truncation: a non-2xx response with an
/// oversized body (a proxy or WAF error page, say) classifies as
/// `.http_error` — the more actionable signal — not masked by `.truncated`.
/// A pure classification with no logging side effect, split out from
/// `complete()` specifically so this ordering is unit-testable: Zig's test
/// runner fails any test that triggers a `std.log.err` call, so the actual
/// logging has to live in `complete()`, one level up from what's tested
/// here.
fn classifyHttpResult(res: fetch_mod.FetchResponse) HttpOutcome {
    if (res.status < 200 or res.status >= 300) return .http_error;
    if (res.truncated) return .truncated;
    return .ok;
}

/// An explicit key wins; otherwise the value the host captured into
/// `process_environ_map` via `initEnviron` (typically `ANTHROPIC_API_KEY`
/// from the real process environment). Neither path ever proceeds without a
/// key — `error.MissingApiKey` when both are absent, never an unauthenticated
/// request.
fn resolveApiKey(explicit: ?[]const u8) ![]const u8 {
    if (explicit) |k| return k;
    if (process_environ_map) |m| {
        if (m.get("ANTHROPIC_API_KEY")) |v| return v;
    }
    return error.MissingApiKey;
}

/// The fields `buildRequestBody` actually encodes, after `Client` defaults
/// have already been applied to whatever `provider.Request` left unset
/// (see `Client.resolveRequest`). Deliberately distinct from
/// `provider.Request` — `model`/`max_tokens` are optional there precisely
/// so a caller can omit them, which means something has to have already
/// picked a concrete value by the time this function runs; it never guesses
/// a fallback itself. `max_tokens` keeps its own default here (matching
/// `Client.max_tokens`'s) only for callers exercising this function
/// directly, as the golden tests below do, with no `Client` in the loop.
const ResolvedRequest = struct {
    model: []const u8,
    system: []const u8 = "",
    messages: []const message.Message,
    tools_json: []const u8 = "[]",
    max_tokens: u32 = 4096,
};

/// Build the `POST /v1/messages` request body. Exposed (not `fn`-private)
/// so the golden test can assert the exact bytes with no network involved.
///
/// Deliberately omits `temperature`, `top_p`, `top_k`, and
/// `thinking.budget_tokens` — see the module doc comment.
pub fn buildRequestBody(arena: std.mem.Allocator, req: ResolvedRequest) ![]const u8 {
    const messages_json = try message.encodeMessages(arena, req.messages);

    var aw: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    try jw.beginObject();

    try jw.objectField("model");
    try jw.write(req.model);

    try jw.objectField("max_tokens");
    try jw.write(req.max_tokens);

    try jw.objectField("system");
    try jw.write(req.system);

    try jw.objectField("tools");
    try jw.beginWriteRaw();
    try jw.writer.writeAll(req.tools_json);
    jw.endWriteRaw();

    try jw.objectField("messages");
    try jw.beginWriteRaw();
    try jw.writer.writeAll(messages_json);
    jw.endWriteRaw();

    try jw.endObject();
    return aw.written();
}

// ---- tests ------------------------------------------------------------

test "anthropic: request body golden" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = try buildRequestBody(arena.allocator(), .{
        .model = "claude-opus-5",
        .system = "You are terse.",
        .messages = &.{.{ .role = .user, .blocks = &.{.{ .text = "hi" }} }},
        .tools_json = "[]",
        .max_tokens = 1024,
    });
    try std.testing.expectEqualStrings(
        \\{"model":"claude-opus-5","max_tokens":1024,"system":"You are terse.","tools":[],"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}
    , body);
}

test "anthropic: no sampling or thinking-budget params are ever sent" {
    // claude-opus-5 returns HTTP 400 for temperature / top_p / top_k and for
    // thinking.budget_tokens. The body must contain none of them.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = try buildRequestBody(arena.allocator(), .{ .model = "claude-opus-5", .messages = &.{} });
    for ([_][]const u8{ "temperature", "top_p", "top_k", "budget_tokens" }) |banned| {
        try std.testing.expect(std.mem.indexOf(u8, body, banned) == null);
    }
}

test "anthropic: refusal is surfaced, not treated as content" {
    // stop_reason "refusal" arrives as HTTP 200 with empty or partial content.
    // Reading content[0] unconditionally would break here.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const res = try message.parseResponse(arena.allocator(),
        \\{"stop_reason":"refusal","content":[],"usage":{"input_tokens":5,"output_tokens":0}}
    );
    try std.testing.expectEqual(message.StopReason.refusal, res.stop_reason);
    try std.testing.expectEqual(@as(usize, 0), res.blocks.len);
}

test "anthropic: an unspecified model/max_tokens falls back to Client defaults on the wire" {
    // The whole point of Client.model/max_tokens: a Request that doesn't
    // set them must still produce claude-opus-5 (the required default
    // model) and Client.max_tokens on the wire, not an empty/zero field.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var client: Client = .{}; // model="claude-opus-5", max_tokens=4096 (defaults)
    const req: provider_mod.Request = .{ .messages = &.{} }; // model/max_tokens omitted
    const body = try buildRequestBody(arena.allocator(), client.resolveRequest(req));
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"claude-opus-5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":4096") != null);
}

test "anthropic: an explicit Request model/max_tokens overrides Client defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var client: Client = .{ .model = "claude-haiku-x", .max_tokens = 999 };
    const req: provider_mod.Request = .{ .model = "claude-opus-5", .max_tokens = 1024, .messages = &.{} };
    const body = try buildRequestBody(arena.allocator(), client.resolveRequest(req));
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"claude-opus-5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":1024") != null);
}

test "anthropic: non-2xx status wins over a truncated body" {
    // A proxy/WAF error page can be both non-2xx and oversized; the status
    // is the more actionable signal and must not be masked by truncation.
    const res: fetch_mod.FetchResponse = .{
        .status = 502,
        .body = "",
        .truncated = true,
        .arena = std.testing.allocator,
    };
    try std.testing.expectEqual(HttpOutcome.http_error, classifyHttpResult(res));
}

test "anthropic: a truncated 2xx body classifies as truncated" {
    const res: fetch_mod.FetchResponse = .{
        .status = 200,
        .body = "",
        .truncated = true,
        .arena = std.testing.allocator,
    };
    try std.testing.expectEqual(HttpOutcome.truncated, classifyHttpResult(res));
}

test "anthropic: capabilities report native_tools" {
    var client: Client = .{};
    const p = client.provider();
    try std.testing.expect(p.capabilities().native_tools);
}

test "anthropic: resolveApiKey returns the explicit key when given" {
    try std.testing.expectEqualStrings("sk-explicit", try resolveApiKey("sk-explicit"));
}

test "anthropic: resolveApiKey returns MissingApiKey with no explicit key and no environ" {
    // No `initEnviron` call has happened in this test binary — the module
    // global stays null, so the env fallback must miss cleanly rather than
    // reading the *test runner's* real environment.
    try std.testing.expectError(error.MissingApiKey, resolveApiKey(null));
}

test "anthropic: resolveApiKey falls back to ANTHROPIC_API_KEY from the captured environ" {
    var map: std.process.Environ.Map = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("ANTHROPIC_API_KEY", "sk-from-env");

    initEnviron(&map);
    // The global is process-wide (shared across every test in this
    // binary) — reset it afterward so later tests still see "unset".
    defer process_environ_map = null;

    try std.testing.expectEqualStrings("sk-from-env", try resolveApiKey(null));
}
