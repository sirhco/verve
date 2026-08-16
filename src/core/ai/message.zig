//! Conversation types and the Anthropic Messages API JSON codec.
//!
//! The wire shapes here are fixed by the API, not invented:
//! - a request message is `{"role":...,"content":[...blocks...]}`;
//! - a tool result is a **user**-role message whose blocks are
//!   `{"type":"tool_result","tool_use_id":"...","content":"...","is_error":false}`
//!   — every result for one assistant turn belongs in a single user message,
//!   never split across several (splitting trains the model out of parallel
//!   tool calls);
//! - a response's `content` array carries `{"type":"text",...}` and
//!   `{"type":"tool_use","id":...,"name":...,"input":{...}}` blocks;
//! - `stop_reason` is one of `end_turn`, `max_tokens`, `stop_sequence`,
//!   `tool_use`, `pause_turn`, `refusal` — plus `.other` here, for whatever
//!   the API adds later that this codec doesn't know about yet.
//!
//! This module only encodes what a request needs and parses what a response
//! contains; it does not round-trip every field the API defines.

const std = @import("std");
const Writer = std.Io.Writer;

pub const Role = enum { user, assistant };

/// A model-issued tool call, decoded from a response's `tool_use` block.
///
/// `input` is a JSON *object* on the wire; `input_json` is that object
/// re-serialized (compact) into memory the caller controls. Parsing never
/// keeps a slice into the original response body — the body may not outlive
/// the call that produced it.
pub const ToolUse = struct {
    id: []const u8,
    name: []const u8,
    input_json: []const u8,
};

/// One tool's outcome, destined for a `tool_result` block in a user message.
pub const ToolResult = struct {
    tool_use_id: []const u8,
    content: []const u8,
    is_error: bool = false,
};

pub const Block = union(enum) {
    text: []const u8,
    tool_use: ToolUse,
    tool_result: ToolResult,
};

pub const Message = struct {
    role: Role,
    blocks: []const Block,
};

/// Anthropic's `stop_reason`. `.other` is the forward-compatible catch-all:
/// mapping an unrecognized value here rather than erroring keeps the API
/// adding a new reason from becoming a hard failure for every app already
/// deployed against this codec.
pub const StopReason = enum {
    end_turn,
    tool_use,
    max_tokens,
    stop_sequence,
    pause_turn,
    refusal,
    other,
};

fn stopReasonFromString(s: []const u8) StopReason {
    inline for (.{
        .{ "end_turn", StopReason.end_turn },
        .{ "tool_use", StopReason.tool_use },
        .{ "max_tokens", StopReason.max_tokens },
        .{ "stop_sequence", StopReason.stop_sequence },
        .{ "pause_turn", StopReason.pause_turn },
        .{ "refusal", StopReason.refusal },
    }) |pair| {
        if (std.mem.eql(u8, s, pair[0])) return pair[1];
    }
    return .other;
}

pub const Usage = struct {
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
};

/// The parsed shape of a `POST /v1/messages` response — field-for-field the
/// same shape `provider.Response` carries. Kept as its own type here (rather
/// than importing `provider.zig`) so the codec has no dependency on the
/// provider abstraction; nothing stops a future provider implementation from
/// constructing a `provider.Response` by copying these three fields.
pub const Response = struct {
    stop_reason: StopReason,
    blocks: []const Block,
    usage: Usage = .{},
};

/// Encode `messages` as the Anthropic `messages` request array.
pub fn encodeMessages(arena: std.mem.Allocator, messages: []const Message) ![]const u8 {
    var aw: Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    try jw.beginArray();
    for (messages) |m| try encodeMessage(&jw, m);
    try jw.endArray();
    return aw.written();
}

fn encodeMessage(jw: *std.json.Stringify, m: Message) !void {
    try jw.beginObject();
    try jw.objectField("role");
    try jw.write(switch (m.role) {
        .user => "user",
        .assistant => "assistant",
    });
    try jw.objectField("content");
    try jw.beginArray();
    for (m.blocks) |b| try encodeBlock(jw, b);
    try jw.endArray();
    try jw.endObject();
}

fn encodeBlock(jw: *std.json.Stringify, b: Block) !void {
    switch (b) {
        .text => |t| {
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("text");
            try jw.objectField("text");
            try jw.write(t);
            try jw.endObject();
        },
        .tool_use => |tu| {
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("tool_use");
            try jw.objectField("id");
            try jw.write(tu.id);
            try jw.objectField("name");
            try jw.write(tu.name);
            try jw.objectField("input");
            // `input_json` is already a compact, well-formed JSON object —
            // it was produced either by re-serializing a parsed response
            // (see `parseResponse`) or by a tool call this process built
            // itself — so it is written raw rather than re-parsed.
            try jw.beginWriteRaw();
            try jw.writer.writeAll(if (tu.input_json.len == 0) "{}" else tu.input_json);
            jw.endWriteRaw();
            try jw.endObject();
        },
        .tool_result => |tr| {
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("tool_result");
            try jw.objectField("tool_use_id");
            try jw.write(tr.tool_use_id);
            try jw.objectField("content");
            try jw.write(tr.content);
            try jw.objectField("is_error");
            try jw.write(tr.is_error);
            try jw.endObject();
        },
    }
}

/// Parse a `POST /v1/messages` response body.
///
/// A refusal arrives as HTTP 200 with `stop_reason: "refusal"` and empty or
/// partial content — callers must check `stop_reason` before assuming
/// `blocks` holds anything, which is exactly what this returns: an empty
/// `blocks` slice is a valid, non-error result.
pub fn parseResponse(arena: std.mem.Allocator, body: []const u8) !Response {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    if (root != .object) return error.InvalidResponse;
    const obj = root.object;

    const stop_reason: StopReason = if (obj.get("stop_reason")) |v|
        (if (v == .string) stopReasonFromString(v.string) else .other)
    else
        .other;

    var blocks: std.ArrayList(Block) = .empty;
    if (obj.get("content")) |content_val| {
        if (content_val == .array) {
            for (content_val.array.items) |item| {
                if (item != .object) continue;
                if (try parseBlock(arena, item.object)) |b| try blocks.append(arena, b);
            }
        }
    }

    var usage: Usage = .{};
    if (obj.get("usage")) |uv| {
        if (uv == .object) {
            if (uv.object.get("input_tokens")) |iv| {
                if (iv == .integer) usage.input_tokens = @intCast(iv.integer);
            }
            if (uv.object.get("output_tokens")) |ov| {
                if (ov == .integer) usage.output_tokens = @intCast(ov.integer);
            }
        }
    }

    return .{
        .stop_reason = stop_reason,
        .blocks = try blocks.toOwnedSlice(arena),
        .usage = usage,
    };
}

/// Decode one `content` array entry. Returns `null` for a block type this
/// codec doesn't know about (`thinking`, `server_tool_use`, ...) or one
/// that's missing a required field — skipped rather than erroring the whole
/// response, the same forward-compatibility stance as `stopReasonFromString`.
fn parseBlock(arena: std.mem.Allocator, obj: std.json.ObjectMap) !?Block {
    const type_val = obj.get("type") orelse return null;
    if (type_val != .string) return null;
    const t = type_val.string;

    if (std.mem.eql(u8, t, "text")) {
        const text_val = obj.get("text") orelse return null;
        if (text_val != .string) return null;
        return .{ .text = text_val.string };
    }

    if (std.mem.eql(u8, t, "tool_use")) {
        const id_val = obj.get("id") orelse return null;
        const name_val = obj.get("name") orelse return null;
        if (id_val != .string or name_val != .string) return null;

        // `input` is a JSON object on the wire; re-serialize the parsed
        // value into arena memory rather than retaining any reference into
        // the response body it was parsed from.
        const input_json: []const u8 = if (obj.get("input")) |input_val| blk: {
            var aw: Writer.Allocating = .init(arena);
            try std.json.Stringify.value(input_val, .{}, &aw.writer);
            break :blk aw.written();
        } else "{}";

        return .{ .tool_use = .{
            .id = id_val.string,
            .name = name_val.string,
            .input_json = input_json,
        } };
    }

    // `tool_result` blocks are something this process sends, never something
    // a model response contains — no case needed here.
    return null;
}

// ---- tests ------------------------------------------------------------

test "message: encodes a user text turn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const convo: []const Message = &.{
        .{ .role = .user, .blocks = &.{.{ .text = "hello" }} },
    };
    const json = try encodeMessages(arena.allocator(), convo);
    try std.testing.expectEqualStrings(
        \\[{"role":"user","content":[{"type":"text","text":"hello"}]}]
    , json);
}

test "message: encodes tool results as one user message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const convo: []const Message = &.{
        .{ .role = .user, .blocks = &.{
            .{ .tool_result = .{ .tool_use_id = "toolu_1", .content = "4" } },
            .{ .tool_result = .{ .tool_use_id = "toolu_2", .content = "oops", .is_error = true } },
        } },
    };
    const json = try encodeMessages(arena.allocator(), convo);
    try std.testing.expectEqualStrings(
        \\[{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"4","is_error":false},{"type":"tool_result","tool_use_id":"toolu_2","content":"oops","is_error":true}]}]
    , json);
}

test "message: parses a tool_use response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const body =
        \\{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_abc","name":"getCount","input":{"x":1}}],"stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":5}}
    ;
    const res = try parseResponse(arena.allocator(), body);
    try std.testing.expectEqual(StopReason.tool_use, res.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), res.blocks.len);
    try std.testing.expect(res.blocks[0] == .tool_use);
    try std.testing.expectEqualStrings("toolu_abc", res.blocks[0].tool_use.id);
    try std.testing.expectEqualStrings("getCount", res.blocks[0].tool_use.name);
    try std.testing.expectEqualStrings("{\"x\":1}", res.blocks[0].tool_use.input_json);
    try std.testing.expectEqual(@as(u32, 10), res.usage.input_tokens);
    try std.testing.expectEqual(@as(u32, 5), res.usage.output_tokens);
}

test "message: parses a refusal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // A refusal arrives as HTTP 200 with empty or partial content — code
    // that reads content[0] unconditionally breaks on it.
    const body =
        \\{"id":"msg_2","type":"message","role":"assistant","content":[],"stop_reason":"refusal"}
    ;
    const res = try parseResponse(arena.allocator(), body);
    try std.testing.expectEqual(StopReason.refusal, res.stop_reason);
    try std.testing.expectEqual(@as(usize, 0), res.blocks.len);
}

test "message: unknown stop_reason maps to .other" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const body =
        \\{"id":"msg_3","type":"message","role":"assistant","content":[],"stop_reason":"some_future_reason"}
    ;
    const res = try parseResponse(arena.allocator(), body);
    try std.testing.expectEqual(StopReason.other, res.stop_reason);
}
