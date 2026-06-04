//! spike.zig — Zig driver for the WebView2 native-host spike.
//!
//! Proves the full seam end-to-end:
//!   Zig -> host.cpp -> Win32 window + WebView2 -> HTML
//!   JS postMessage -> host.cpp -> THIS Zig callback -> ExecuteScript -> visible
//!
//! Build/run:  zig build win-spike  (produces zig-out/bin/verve-win-spike.exe)
//! Then run the exe on Windows (WebView2 Runtime installed). Success = a window
//! shows the page, and clicking "ping" round-trips text back through Zig.

const std = @import("std");

const Host = opaque {};

const BridgeFn = *const fn (ctx: ?*anyopaque, msg: [*]const u8, len: usize) callconv(.c) void;

extern fn wv2_create(title: [*:0]const u8, width: c_int, height: c_int) ?*Host;
extern fn wv2_load_html(host: *Host, html: [*]const u8, len: usize) void;
extern fn wv2_eval_js(host: *Host, js: [*]const u8, len: usize) void;
extern fn wv2_set_bridge(host: *Host, cb: BridgeFn, ctx: ?*anyopaque) void;
extern fn wv2_run(host: *Host) void;
extern fn wv2_destroy(host: *Host) void;

var g_host: ?*Host = null;

const page =
    \\<!doctype html><html><head><meta charset="utf-8"><style>
    \\  body { font-family: system-ui, sans-serif; padding: 2rem; }
    \\  #log { margin-top: 1rem; padding: .75rem; background: #eef; border-radius: 6px; }
    \\</style></head><body>
    \\  <h1>Verve · WebView2 host spike</h1>
    \\  <p>Native C++ host + Zig C-ABI. No WRL, no hand-rolled Zig COM.</p>
    \\  <button onclick="window.verve.post('ping ' + Date.now())">ping &rarr; Zig</button>
    \\  <div id="log">waiting for round-trip&hellip;</div>
    \\  <script>
    \\    function verveLog(s) { document.getElementById('log').textContent = s; }
    \\    window.addEventListener('DOMContentLoaded', function () {
    \\      window.verve.post('hello from JS on load');
    \\    });
    \\  </script>
    \\</body></html>
;

/// Called by the host on the UI thread whenever JS posts a message. Echo the
/// text back into the page through ExecuteScript — that visible echo is the
/// proof the JS -> host -> Zig -> JS loop closed.
fn bridge(ctx: ?*anyopaque, msg: [*]const u8, len: usize) callconv(.c) void {
    _ = ctx;
    const text = msg[0..len];
    std.debug.print("[zig] bridge received: {s}\n", .{text});

    // Build  verveLog('Zig received: <text>');  escaping for a JS single-quoted
    // string literal (\, ', and newlines).
    var buf: [4096]u8 = undefined;
    var w: usize = 0;
    const prefix = "verveLog('Zig received: ";
    const suffix = "');";
    @memcpy(buf[0..prefix.len], prefix);
    w += prefix.len;
    for (text) |c| {
        if (w + 2 + suffix.len > buf.len) break;
        switch (c) {
            '\\', '\'' => {
                buf[w] = '\\';
                w += 1;
                buf[w] = c;
                w += 1;
            },
            '\n', '\r' => {
                buf[w] = ' ';
                w += 1;
            },
            else => {
                buf[w] = c;
                w += 1;
            },
        }
    }
    @memcpy(buf[w .. w + suffix.len], suffix);
    w += suffix.len;

    if (g_host) |h| wv2_eval_js(h, buf[0..w].ptr, w);
}

pub fn main() void {
    const host = wv2_create("Verve WebView2 spike", 900, 640) orelse {
        std.debug.print("[zig] wv2_create failed\n", .{});
        return;
    };
    g_host = host;
    defer wv2_destroy(host);

    wv2_set_bridge(host, &bridge, null);
    wv2_load_html(host, page.ptr, page.len);
    wv2_run(host);
}
