//! /ai-chat demo island — a minimal chat UI over the app's `aiChat` server
//! action (`src/app/api.zig`, Task 8).
//!
//! The transcript is NOT passed as island props: island props are capped
//! at 8192 bytes (`src/client/runtime_exports.zig`'s `island_scratch`) and
//! a multi-turn transcript would exceed that. Instead this chunk keeps its
//! own bounded message history and re-renders it into a `<div>` after each
//! server-fn round trip — the same request/typed-reply pattern
//! `JsonProbe.zig` and `WsDemo.zig` already use (`serverFnPostRid` +
//! `registerResponseHandlerOnce` + `parseJson`).

const std = @import("std");
const verve = @import("verve");

/// `Actions.aiChat`'s route name — `/api/aiChat`.
const ROUTE = "aiChat";

/// Cap on what's read out of the input element per send. The server side
/// has its own reply cap (`AI_REPLY_MAX` in api.zig); this is this chunk's
/// own bound on the prompt it echoes into the transcript.
const PROMPT_MAX = 500;

/// Bounded message history — oldest entries drop off once full, mirroring
/// `WsDemo.zig`'s ring-buffer-of-lines approach.
const MSGS = 12;
const MSG_MAX = 800;
const LOG_BUF_LEN = MSGS * (MSG_MAX + 32);

const Role = enum { user, assistant };

var input_h: ?i32 = null;
var transcript_h: ?i32 = null;

var msg_role: [MSGS]Role = undefined;
var msg_text: [MSGS][MSG_MAX]u8 = undefined;
var msg_len: [MSGS]usize = @splat(0);
var msg_count: usize = 0;

var log_buf: [LOG_BUF_LEN]u8 = undefined;

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;
    input_h = verve.queryRef(@as([]const u8, "aichat-input"));
    transcript_h = verve.queryRef(@as([]const u8, "aichat-transcript"));
    msg_count = 0;
}

/// Append one message to the bounded history, dropping the oldest entry
/// when full, then re-render the transcript.
fn pushMessage(role: Role, text: []const u8) void {
    const n = @min(text.len, MSG_MAX);
    if (msg_count < MSGS) {
        msg_role[msg_count] = role;
        @memcpy(msg_text[msg_count][0..n], text[0..n]);
        msg_len[msg_count] = n;
        msg_count += 1;
    } else {
        var i: usize = 0;
        while (i < MSGS - 1) : (i += 1) {
            msg_role[i] = msg_role[i + 1];
            @memcpy(msg_text[i][0..msg_len[i + 1]], msg_text[i + 1][0..msg_len[i + 1]]);
            msg_len[i] = msg_len[i + 1];
        }
        msg_role[MSGS - 1] = role;
        @memcpy(msg_text[MSGS - 1][0..n], text[0..n]);
        msg_len[MSGS - 1] = n;
    }
    renderTranscript();
}

fn renderTranscript() void {
    var w: usize = 0;
    var i: usize = 0;
    while (i < msg_count) : (i += 1) {
        const label: []const u8 = if (msg_role[i] == .user) "You: " else "Assistant: ";
        if (w + label.len <= log_buf.len) {
            @memcpy(log_buf[w .. w + label.len], label);
            w += label.len;
        }
        const body = msg_text[i][0..msg_len[i]];
        const room = log_buf.len -| w;
        const take = @min(body.len, room);
        @memcpy(log_buf[w .. w + take], body[0..take]);
        w += take;
        if (w + 2 <= log_buf.len) {
            log_buf[w] = '\n';
            log_buf[w + 1] = '\n';
            w += 2;
        }
    }
    if (transcript_h) |h| verve.setRefText(h, log_buf[0..w]);
}

/// Send button: `[z-on-click="aichat_send"]`.
export fn aichat_send() void {
    const h = input_h orelse return;
    var raw: [PROMPT_MAX]u8 = undefined;
    const val = verve.refValueStr(h, &raw);
    const trimmed = std.mem.trim(u8, val, " \t\r\n");
    if (trimmed.len == 0) return;

    pushMessage(.user, trimmed);
    verve.setRefValue(h, "");

    // Chunk-arena scratch for the outbound JSON body only — freed (reset)
    // before this function returns, same pattern `fetchSignal` uses
    // internally. The reply arrives later, asynchronously, in `onReply`.
    const mark = verve.chunkArenaMark();
    defer verve.chunkArenaReset(mark);
    const json = std.json.Stringify.valueAlloc(verve.chunkArena(), .{ .prompt = trimmed }, .{}) catch return;

    const rid = verve.nextReqId();
    verve.registerResponseHandlerOnce(ROUTE, rid, &onReply);
    verve.serverFnPostRid(ROUTE, json, rid);
}

/// Reply handler for `aiChat`: `{"rid":N,"value":"<reply text>"}` on
/// success, or a body with no `value` on a server-side error.
fn onReply(ptr: [*]const u8, len: u32) void {
    const doc = verve.parseJson(ptr[0..len]) orelse {
        pushMessage(.assistant, "(no reply)");
        return;
    };
    defer doc.free();

    const v = doc.get("value") orelse {
        pushMessage(.assistant, "(error)");
        return;
    };

    const mark = verve.chunkArenaMark();
    defer verve.chunkArenaReset(mark);
    const buf = verve.chunkArena().alloc(u8, v.strLen()) catch {
        pushMessage(.assistant, "(reply too large)");
        return;
    };
    pushMessage(.assistant, v.str(buf));
}
