//! The tool-use loop: drives a `Provider` against a `Registry`'s tools until
//! the model stops asking for more, `policy.Policy.max_steps` is hit, or the
//! provider can't do tool use at all.
//!
//! Security note: when `Reg.invoke` reports `.needs_confirmation`, the token
//! it carries is the sole authorization a human's approval will later redeem
//! (see `policy.claimToken`) — this loop must never let that value reach the
//! provider. It doesn't: the `tool_result` built for that case below is a
//! fixed, token-free string. The token itself has no path out of this
//! function at all: `Outcome` (below) carries only `{ text, steps, stopped }`,
//! so a caller of `run` cannot learn that a confirmation is pending, which
//! `(tool, args)` it is for, or what token would redeem it. A host that wants
//! the approval flow must bypass this loop and call `Reg.invoke` directly —
//! see `docs/25-ai.md`'s "The confirmation round-trip" section. Widening
//! `Outcome` to surface a pending confirmation is a known gap, deliberately
//! deferred.

const std = @import("std");
const message = @import("message.zig");
const provider = @import("provider.zig");
const policy = @import("policy.zig");

pub const Outcome = struct {
    text: []const u8,
    steps: u8,
    stopped: message.StopReason,
};

/// Run the tool-use loop to completion.
///
/// Synchronous on the calling thread. In a server route that is the request
/// thread, which is fine for non-streaming turns and keeps this clear of the
/// cross-thread reactivity problem (`Signal` is not thread-safe and the
/// effect scheduler is threadlocal).
///
/// `confirm_token` is always `null` on the call into `Reg.invoke` below —
/// this loop never holds one to spend. `verve.ai.run` does not surface a
/// pending confirmation to its caller (see the module doc comment above):
/// a `.needs_confirmation` outcome is reported to the model as a fixed
/// refusal string and otherwise dropped. A host that wants the
/// human-approval flow has to call `Reg.invoke` directly, outside this
/// loop, with a real `confirm_token` once it has one.
pub fn run(
    arena: std.mem.Allocator,
    prov: provider.Provider,
    comptime Reg: type,
    p: policy.Policy,
    convo: *std.ArrayList(message.Message),
    system: []const u8,
    model: []const u8,
) !Outcome {
    const has_tools = Reg.tool_decls.len > 0;
    if (has_tools and !prov.capabilities().native_tools) return error.ProviderLacksToolSupport;

    var step: u8 = 0;
    var last_text: []const u8 = "";
    while (step < p.max_steps) {
        step += 1;
        const res = try prov.complete(arena, .{
            .model = model,
            .system = system,
            .messages = convo.items,
            .tools_json = if (has_tools) Reg.tools_json else "[]",
        });

        try convo.append(arena, .{ .role = .assistant, .blocks = res.blocks });
        for (res.blocks) |b| {
            if (b == .text) last_text = b.text;
        }

        if (res.stop_reason != .tool_use) {
            return .{ .text = last_text, .steps = step, .stopped = res.stop_reason };
        }

        // One user message carrying every result for this assistant turn —
        // splitting them across several trains the model out of parallel
        // tool calls (see the Messages API note on this).
        var results: std.ArrayList(message.Block) = .empty;
        for (res.blocks) |b| {
            if (b != .tool_use) continue;
            const call = b.tool_use;
            // Always null: this loop never carries a confirmation token
            // forward (see the module doc comment above).
            const outcome = Reg.invoke(arena, call.name, call.input_json, p, null);
            const rb: message.ToolResult = switch (outcome) {
                .ok => |json| .{ .tool_use_id = call.id, .content = json },
                .err => |reason| .{ .tool_use_id = call.id, .content = reason, .is_error = true },
                .needs_confirmation => .{
                    .tool_use_id = call.id,
                    .content = "this tool requires human confirmation; ask the user to approve it",
                    .is_error = true,
                },
            };
            try results.append(arena, .{ .tool_result = rb });
        }

        // A response can report `stop_reason == .tool_use` while carrying no
        // `tool_use` blocks at all (empty or malformed turn) — `results`
        // would then be empty, and appending
        // `{"role":"user","content":[]}` to the conversation is not just
        // pointless, it's a guaranteed 400 from the Messages API on the next
        // round trip (an empty `content` array is invalid). Stop here with a
        // clear outcome instead.
        if (results.items.len == 0) {
            return .{ .text = last_text, .steps = step, .stopped = res.stop_reason };
        }

        try convo.append(arena, .{ .role = .user, .blocks = try results.toOwnedSlice(arena) });
    }
    return .{ .text = last_text, .steps = step, .stopped = .tool_use };
}

// ---- tests ------------------------------------------------------------

const registry = @import("registry.zig");

const TestActions = struct {
    pub fn getCount(_: struct {}) !i32 {
        return 7;
    }
};

const R = registry.Registry(TestActions, &.{
    .{ .fn_name = "getCount", .description = "Read the counter.", .risk = .safe },
});

const NoToolsR = registry.Registry(TestActions, &.{});

fn userTurn(text: []const u8) message.Message {
    return .{ .role = .user, .blocks = &.{.{ .text = text }} };
}

test "agent: single text turn returns immediately" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mock: @import("mock_provider.zig").MockProvider = .{ .turns = &.{
        .{ .stop_reason = .end_turn, .blocks = &.{.{ .text = "hi there" }} },
    } };

    var convo: std.ArrayList(message.Message) = .empty;
    try convo.append(a, userTurn("hello"));

    const outcome = try run(a, mock.provider(), NoToolsR, .{}, &convo, "sys", "model-x");
    try std.testing.expectEqualStrings("hi there", outcome.text);
    try std.testing.expectEqual(@as(u8, 1), outcome.steps);
    try std.testing.expectEqual(message.StopReason.end_turn, outcome.stopped);
}

test "agent: tool_use turn executes the tool and continues" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mock: @import("mock_provider.zig").MockProvider = .{ .turns = &.{
        .{ .stop_reason = .tool_use, .blocks = &.{
            .{ .tool_use = .{ .id = "toolu_1", .name = "getCount", .input_json = "{}" } },
        } },
        .{ .stop_reason = .end_turn, .blocks = &.{.{ .text = "The count is 7" }} },
    } };

    var convo: std.ArrayList(message.Message) = .empty;
    try convo.append(a, userTurn("what's the count?"));

    const outcome = try run(a, mock.provider(), R, .{}, &convo, "sys", "model-x");
    try std.testing.expectEqualStrings("The count is 7", outcome.text);
    try std.testing.expectEqual(@as(u8, 2), outcome.steps);
    try std.testing.expectEqual(message.StopReason.end_turn, outcome.stopped);

    // convo: [user(what's the count?), assistant(tool_use), user(tool_result), assistant(text)]
    try std.testing.expectEqual(@as(usize, 4), convo.items.len);
    const results_msg = convo.items[2];
    try std.testing.expectEqual(message.Role.user, results_msg.role);
    try std.testing.expectEqual(@as(usize, 1), results_msg.blocks.len);
    try std.testing.expect(results_msg.blocks[0] == .tool_result);
    try std.testing.expectEqualStrings("7", results_msg.blocks[0].tool_result.content);
    try std.testing.expect(!results_msg.blocks[0].tool_result.is_error);
}

test "agent: unknown tool feeds an is_error result back rather than aborting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mock: @import("mock_provider.zig").MockProvider = .{ .turns = &.{
        .{ .stop_reason = .tool_use, .blocks = &.{
            .{ .tool_use = .{ .id = "toolu_2", .name = "nope", .input_json = "{}" } },
        } },
        .{ .stop_reason = .end_turn, .blocks = &.{.{ .text = "ok" }} },
    } };

    var convo: std.ArrayList(message.Message) = .empty;
    try convo.append(a, userTurn("call a bogus tool"));

    const outcome = try run(a, mock.provider(), R, .{}, &convo, "sys", "model-x");
    try std.testing.expectEqual(@as(u8, 2), outcome.steps);

    const results_msg = convo.items[2];
    try std.testing.expect(results_msg.blocks[0].tool_result.is_error);
    try std.testing.expectEqualStrings("unknown tool", results_msg.blocks[0].tool_result.content);
}

test "agent: tool_use stop_reason with no tool_use blocks stops instead of round-tripping empty content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A malformed/empty turn: stop_reason claims tool_use but no tool_use
    // block is actually present. Without a guard, `results` stays empty and
    // the loop would append `{"role":"user","content":[]}` to the
    // conversation and call `complete` again — the Messages API rejects an
    // empty `content` array with a 400. The mock only scripts one turn, so
    // if the loop tried to continue past it, this test would fail with
    // `error.MockExhausted` instead of returning cleanly.
    var mock: @import("mock_provider.zig").MockProvider = .{ .turns = &.{
        .{ .stop_reason = .tool_use, .blocks = &.{.{ .text = "thinking..." }} },
    } };

    var convo: std.ArrayList(message.Message) = .empty;
    try convo.append(a, userTurn("do something"));

    const outcome = try run(a, mock.provider(), R, .{}, &convo, "sys", "model-x");
    try std.testing.expectEqual(@as(u8, 1), outcome.steps);
    try std.testing.expectEqual(message.StopReason.tool_use, outcome.stopped);
    try std.testing.expectEqualStrings("thinking...", outcome.text);

    // No tool_result message was appended — just the assistant's turn.
    try std.testing.expectEqual(@as(usize, 2), convo.items.len);
}

/// A provider that always returns a `tool_use` turn — used to pin
/// `max_steps` as a hard cap on provider calls, not just on tool executions.
const AlwaysToolUseProvider = struct {
    calls: u32 = 0,

    fn asProvider(self: *AlwaysToolUseProvider) provider.Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: provider.Provider.VTable = .{
        .capabilities = capabilities,
        .complete = complete,
    };

    fn capabilities(ptr: *anyopaque) provider.Capabilities {
        _ = ptr;
        return .{ .native_tools = true };
    }

    fn complete(ptr: *anyopaque, arena: std.mem.Allocator, req: provider.Request) anyerror!provider.Response {
        _ = arena;
        _ = req;
        const self: *AlwaysToolUseProvider = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        return .{ .stop_reason = .tool_use, .blocks = &.{
            .{ .tool_use = .{ .id = "toolu_x", .name = "getCount", .input_json = "{}" } },
        } };
    }
};

test "agent: max_steps is enforced" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var always: AlwaysToolUseProvider = .{};
    var convo: std.ArrayList(message.Message) = .empty;
    try convo.append(a, userTurn("loop forever"));

    const outcome = try run(a, always.asProvider(), R, .{ .max_steps = 3 }, &convo, "sys", "model-x");
    try std.testing.expectEqual(@as(u32, 3), always.calls);
    try std.testing.expectEqual(message.StopReason.tool_use, outcome.stopped);
    try std.testing.expectEqual(@as(u8, 3), outcome.steps);
}

test "agent: refusal stops the loop and surfaces it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mock: @import("mock_provider.zig").MockProvider = .{ .turns = &.{
        .{ .stop_reason = .refusal, .blocks = &.{} },
    } };

    var convo: std.ArrayList(message.Message) = .empty;
    try convo.append(a, userTurn("do something disallowed"));

    const outcome = try run(a, mock.provider(), NoToolsR, .{}, &convo, "sys", "model-x");
    try std.testing.expectEqual(message.StopReason.refusal, outcome.stopped);
    try std.testing.expectEqual(@as(u8, 1), outcome.steps);
    try std.testing.expectEqualStrings("", outcome.text);
    // No tool_result message was appended — just the assistant's (empty) turn.
    try std.testing.expectEqual(@as(usize, 2), convo.items.len);
}

/// A provider that reports no native tool support at all — the delegating
/// kind (`native_tools = false`).
const NoToolsProvider = struct {
    fn asProvider(self: *NoToolsProvider) provider.Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: provider.Provider.VTable = .{
        .capabilities = capabilities,
        .complete = complete,
    };

    fn capabilities(ptr: *anyopaque) provider.Capabilities {
        _ = ptr;
        return .{ .native_tools = false };
    }

    fn complete(ptr: *anyopaque, arena: std.mem.Allocator, req: provider.Request) anyerror!provider.Response {
        _ = ptr;
        _ = arena;
        _ = req;
        unreachable; // must never be reached: the loop must refuse before calling complete.
    }
};

test "agent: a provider without native_tools errors when tools are declared" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var no_tools: NoToolsProvider = .{};
    var convo: std.ArrayList(message.Message) = .empty;
    try convo.append(a, userTurn("hi"));

    try std.testing.expectError(
        error.ProviderLacksToolSupport,
        run(a, no_tools.asProvider(), R, .{}, &convo, "sys", "model-x"),
    );
}
