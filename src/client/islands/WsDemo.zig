//! WebSocket hub demo (/ws-demo). Connects to the "ws-demo" push channel over WS
//! (verveWsConnect); the Send button re-publishes the input over the channel, so
//! every connected tab (incl. this one) receives it (wsdemo_recv → log).
const std = @import("std");
const verve = @import("verve");

const CHANNEL = "ws-demo";
const LINES = 10;
const LINE_MAX = 200;

var input_h: ?i32 = null;
var log_h: ?i32 = null;
var lines: [LINES][LINE_MAX]u8 = undefined;
var line_len: [LINES]usize = @splat(0);
var line_count: usize = 0;
var log_buf: [LINES * (LINE_MAX + 1)]u8 = undefined;

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;
    input_h = verve.queryRef(@as([]const u8, "wsdemo-input"));
    log_h = verve.queryRef(@as([]const u8, "wsdemo-log"));
    line_count = 0;
    var out: [16]u8 = undefined;
    _ = verve.host("verveWsConnect", "{\"channel\":\"" ++ CHANNEL ++ "\",\"island\":\"WsDemo\",\"export\":\"wsdemo_recv\"}", &out);
}

/// Send button: read the input, re-publish over the channel as a host-fn arg
/// envelope `{channel,text}` (verveWsSend sends only `text` over the wire). The
/// text is escaped (", \, control chars) so the JSON arg is always valid.
export fn wsdemo_send() void {
    const h = input_h orelse return;
    var raw: [LINE_MAX]u8 = undefined;
    const val = verve.refValueStr(h, &raw);
    if (val.len == 0) return;
    var json: [LINE_MAX * 2 + 64]u8 = undefined;
    const prefix = "{\"channel\":\"" ++ CHANNEL ++ "\",\"text\":\"";
    @memcpy(json[0..prefix.len], prefix);
    var w: usize = prefix.len;
    for (val) |ch| {
        if (w + 2 >= json.len) break;
        if (ch == '"' or ch == '\\') {
            json[w] = '\\';
            json[w + 1] = ch;
            w += 2;
        } else if (ch < 0x20) {
            json[w] = ' ';
            w += 1;
        } else {
            json[w] = ch;
            w += 1;
        }
    }
    const suffix = "\"}";
    @memcpy(json[w .. w + suffix.len], suffix);
    w += suffix.len;
    var out: [16]u8 = undefined;
    _ = verve.host("verveWsSend", json[0..w], &out);
    verve.setRefValue(h, "");
}

/// Inbound frame from the channel (raw published bytes). Append to a ring + log.
export fn wsdemo_recv(ptr: u32, len: u32) void {
    const msg = @as([*]const u8, @ptrFromInt(@as(usize, ptr)))[0..len];
    const n = @min(msg.len, LINE_MAX);
    if (line_count < LINES) {
        @memcpy(lines[line_count][0..n], msg[0..n]);
        line_len[line_count] = n;
        line_count += 1;
    } else {
        var i: usize = 0;
        while (i < LINES - 1) : (i += 1) {
            @memcpy(lines[i][0..line_len[i + 1]], lines[i + 1][0..line_len[i + 1]]);
            line_len[i] = line_len[i + 1];
        }
        @memcpy(lines[LINES - 1][0..n], msg[0..n]);
        line_len[LINES - 1] = n;
    }
    var w: usize = 0;
    var i: usize = 0;
    while (i < line_count) : (i += 1) {
        @memcpy(log_buf[w .. w + line_len[i]], lines[i][0..line_len[i]]);
        w += line_len[i];
        if (w < log_buf.len) {
            log_buf[w] = '\n';
            w += 1;
        }
    }
    if (log_h) |lh| verve.setRefText(lh, log_buf[0..w]);
}
