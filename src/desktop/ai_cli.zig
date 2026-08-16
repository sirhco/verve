//! The Claude Code CLI (`claude -p ... --output-format=json`) as a
//! `provider.Provider`, run via subprocess. Lives under `src/desktop/`
//! (not `src/core/`) because it needs `process.zig`'s `std.process.Child`
//! wrapper, which `src/core/` — target-agnostic, no OS handles — cannot
//! have.
//!
//! This is delegation, not tool-calling. Claude Code runs its own tools in
//! its own sandbox; it never sees or uses this framework's tool registry.
//! `capabilities().native_tools` is therefore `false`, and `complete`
//! refuses outright (`error.ProviderLacksToolSupport`) if a caller declares
//! any tools — `agent.run` already checks `native_tools` before ever
//! calling `complete` when tools are declared (see `agent.zig`), but a
//! caller that invokes `complete` directly gets the same refusal here. The
//! vtable must never silently drop a tool list it was handed.
//!
//! ---- What is actually verified about the CLI's JSON envelope ----------
//!
//! No live `claude` subprocess was run to produce this file (the task this
//! module was built for explicitly forbids spawning one from a test — see
//! `parseCliOutput`'s tests), and no network fetch was available to consult
//! Anthropic's documentation directly. The only contract this module treats
//! as verified is the one pinned by this task's own golden test: a
//! `--output-format=json` run yields a JSON object with a string `result`
//! field and a boolean `is_error` field, e.g. `{"result":"Done.",
//! "is_error":false}`. `parseCliOutput` reads exactly those two fields and
//! nothing else — no `usage`, `session_id`, `duration_ms`, or other field
//! some real invocations may also carry is depended on here. Extra fields
//! are inherently harmless: they're parsed into a generic `std.json.Value`
//! tree and simply never looked up.

const std = @import("std");
// A module rooted at `src/desktop/` cannot reach `src/core/` via a relative
// `../` import — Zig 0.16 confines an import to the module's own root
// subtree — so these come through the `verve` package import instead (see
// `verve.ai.message`/`verve.ai.provider`'s doc comment in `core/ai/ai.zig`
// for why those two submodules, specifically, are re-exported wholesale).
const verve = @import("verve");
const message = verve.ai.message;
const provider_mod = verve.ai.provider;
const process = @import("process.zig");
const Writer = std.Io.Writer;

/// A Claude Code CLI client, wired as a `provider.Provider`.
pub const Client = struct {
    /// The `Io` `process.runCapture` runs the subprocess on.
    io: std.Io,
    /// Executable name or path. Resolved via `PATH` when it has no path
    /// separator, same as any other `std.process.Child` argv[0].
    binary: []const u8 = "claude",

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
        // See the module doc comment: delegation, not tool-calling.
        return .{ .native_tools = false };
    }

    fn complete(ptr: *anyopaque, arena: std.mem.Allocator, req: provider_mod.Request) anyerror!provider_mod.Response {
        const self: *Client = @ptrCast(@alignCast(ptr));

        if (!std.mem.eql(u8, req.tools_json, "[]")) return error.ProviderLacksToolSupport;

        const prompt = try flattenPrompt(arena, req.system, req.messages);

        var argv_buf: [4][]const u8 = undefined;
        const argv = buildArgv(&argv_buf, self.binary, prompt);

        const result = process.runCapture(arena, self.io, argv) catch return error.CliSpawnFailed;
        if (result.code != 0) {
            // stderr can echo the prompt (and whatever the model produced)
            // back verbatim — log only the exit code, same stance
            // `anthropic.zig` takes toward its HTTP error bodies.
            std.log.scoped(.verve_ai).err("ai_cli: claude exited {d}", .{result.code});
            return error.CliFailed;
        }

        return parseCliOutput(arena, result.stdout);
    }
};

/// Build the argv for `claude -p <prompt> --output-format=json`. `buf` must
/// have exactly 4 elements of storage — caller-owned so this stays
/// allocation-free. Model selection is deliberately not threaded through:
/// Claude Code manages its own model choice, which is exactly the
/// delegation this provider exists to hand off to.
pub fn buildArgv(buf: *[4][]const u8, binary: []const u8, prompt: []const u8) []const []const u8 {
    buf[0] = binary;
    buf[1] = "-p";
    buf[2] = prompt;
    buf[3] = "--output-format=json";
    return buf;
}

/// Flatten a conversation into the single string `-p` takes. Each `claude
/// -p` run is a fresh, self-contained invocation — there is no per-call
/// wire slot for a multi-turn `messages` array the way the Anthropic
/// Messages API has one — so a `req.messages` with more than one turn is
/// rendered as a role-labeled transcript rather than replayed turn by turn.
/// Only `.text` blocks are rendered; `.tool_use`/`.tool_result` blocks
/// cannot legitimately appear in a request built for this provider (see the
/// `tools_json` guard in `complete`) and are skipped defensively rather than
/// erroring, in case a caller reuses a conversation built for a
/// native-tools provider.
fn flattenPrompt(arena: std.mem.Allocator, system: []const u8, messages: []const message.Message) ![]const u8 {
    var aw: Writer.Allocating = .init(arena);
    if (system.len > 0) {
        try aw.writer.print("{s}\n\n", .{system});
    }
    for (messages) |m| {
        const label: []const u8 = switch (m.role) {
            .user => "Human",
            .assistant => "Assistant",
        };
        for (m.blocks) |b| {
            if (b != .text) continue;
            try aw.writer.print("{s}: {s}\n\n", .{ label, b.text });
        }
    }
    return aw.written();
}

/// Decode `claude --output-format=json`'s stdout. See the module doc
/// comment for exactly what's verified vs. assumed about this shape.
///
/// Pure and non-logging by design — this is tested directly (including for
/// the failure cases below), and Zig's test runner fails any test that
/// triggers a `std.log.err` call. `complete` is the layer that logs, same
/// stance `anthropic.zig`'s `classifyHttpResult` takes toward its own
/// non-2xx/truncated split.
///
/// `is_error: true` means the CLI itself reported failure inside a 0-exit
/// JSON envelope (distinct from a non-zero process exit, handled in
/// `complete`) — this codec doesn't know what stop-reason story such an
/// envelope actually tells, so it's surfaced as `error.CliReportedError`
/// rather than guessed at. Anything that isn't a well-formed JSON object
/// with a string `result` field — malformed JSON included — is
/// `error.InvalidCliOutput` rather than a silent empty response.
pub fn parseCliOutput(arena: std.mem.Allocator, stdout: []const u8) !message.Response {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, stdout, .{}) catch return error.InvalidCliOutput;
    if (root != .object) return error.InvalidCliOutput;
    const obj = root.object;

    const result_val = obj.get("result") orelse return error.InvalidCliOutput;
    if (result_val != .string) return error.InvalidCliOutput;

    const is_error = if (obj.get("is_error")) |v| (v == .bool and v.bool) else false;
    if (is_error) return error.CliReportedError;

    var blocks: std.ArrayList(message.Block) = .empty;
    try blocks.append(arena, .{ .text = result_val.string });

    return .{
        .stop_reason = .end_turn,
        .blocks = try blocks.toOwnedSlice(arena),
    };
}

// ---- tests --------------------------------------------------------------
//
// No test here spawns a real `claude` subprocess or makes a network call —
// `buildArgv` and `parseCliOutput` are pure functions, tested as such.

test "ai_cli: reports that it does not support framework tools" {
    // The CLI runs its own tools in its own sandbox. Claiming native_tools
    // here would make the agent loop hand it a tool list it silently ignores.
    var c: Client = .{ .io = undefined };
    try std.testing.expect(!c.provider().capabilities().native_tools);
}

test "ai_cli: builds the expected argv" {
    var buf: [4][]const u8 = undefined;
    const argv = buildArgv(&buf, "claude", "summarise this repo");
    try std.testing.expectEqualStrings("claude", argv[0]);
    try std.testing.expectEqualStrings("-p", argv[1]);
    try std.testing.expectEqualStrings("summarise this repo", argv[2]);
    try std.testing.expectEqualStrings("--output-format=json", argv[3]);
}

test "ai_cli: parses the CLI json envelope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const res = try parseCliOutput(arena.allocator(),
        \\{"result":"Done.","is_error":false}
    );
    try std.testing.expectEqualStrings("Done.", res.blocks[0].text);
    try std.testing.expectEqual(message.StopReason.end_turn, res.stop_reason);
}

test "ai_cli: unrecognized envelope fields are ignored, not fatal" {
    // Defensive parsing per the module doc comment: fields this codec
    // doesn't depend on (session_id, usage, duration_ms, ...) must not
    // break decoding just because a real invocation also sends them.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const res = try parseCliOutput(arena.allocator(),
        \\{"type":"result","subtype":"success","result":"ok","is_error":false,"session_id":"abc","duration_ms":42,"usage":{"input_tokens":3}}
    );
    try std.testing.expectEqualStrings("ok", res.blocks[0].text);
}

test "ai_cli: is_error true is a hard failure, not a stop reason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.CliReportedError, parseCliOutput(arena.allocator(),
        \\{"result":"something went wrong","is_error":true}
    ));
}

test "ai_cli: a body missing result is InvalidCliOutput, not a silent empty response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidCliOutput, parseCliOutput(arena.allocator(), "{}"));
    try std.testing.expectError(error.InvalidCliOutput, parseCliOutput(arena.allocator(), "[]"));
    try std.testing.expectError(error.InvalidCliOutput, parseCliOutput(arena.allocator(), "not json"));
}

test "ai_cli: complete refuses tools rather than silently dropping them" {
    var c: Client = .{ .io = undefined };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // The tools_json check happens before anything touches `io` or spawns
    // a subprocess, so `io = undefined` above is safe here.
    const req: provider_mod.Request = .{
        .messages = &.{},
        .tools_json = "[{\"name\":\"getCount\"}]",
    };
    try std.testing.expectError(error.ProviderLacksToolSupport, c.provider().complete(arena.allocator(), req));
}

test "ai_cli: flattenPrompt renders a role-labeled transcript with the system prompt first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const prompt = try flattenPrompt(arena.allocator(), "You are terse.", &.{
        .{ .role = .user, .blocks = &.{.{ .text = "hi" }} },
        .{ .role = .assistant, .blocks = &.{.{ .text = "hello" }} },
    });
    try std.testing.expectEqualStrings("You are terse.\n\nHuman: hi\n\nAssistant: hello\n\n", prompt);
}

test "ai_cli: flattenPrompt skips a system prompt of empty length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const prompt = try flattenPrompt(arena.allocator(), "", &.{
        .{ .role = .user, .blocks = &.{.{ .text = "hi" }} },
    });
    try std.testing.expectEqualStrings("Human: hi\n\n", prompt);
}
