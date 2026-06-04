//! win_native_smoke.zig — smoke driver for the WebView2 native-host backend.
//!
//! Unlike the original spike (which declared its own `extern fn wv2_*`), this
//! routes through the REAL backend — `src/desktop/windows_native.zig` — via its
//! public `Window` surface. It proves the full seam end-to-end:
//!
//!   Zig (windows_native.Window) -> host.cpp -> Win32 window + WebView2 -> HTML
//!   JS postMessage -> host.cpp -> bridge trampoline -> THIS onMsg callback
//!     -> Window.evalJs -> visible echo
//!
//! Build:  zig build win-native   (produces zig-out/bin/verve-win-native.exe)
//! Then run the exe on Windows (WebView2 Runtime installed). Success = a window
//! shows the page, and clicking "ping" round-trips text back through Zig.

const std = @import("std");
const wn = @import("windows_native");

var g_win: ?*wn.Window = null;

const page =
    \\<!doctype html><html><head><meta charset="utf-8"><style>
    \\  body { font-family: system-ui, sans-serif; padding: 2rem; }
    \\  #log { margin-top: 1rem; padding: .75rem; background: #eef; border-radius: 6px; }
    \\</style></head><body>
    \\  <h1>Verve · WebView2 native-host</h1>
    \\  <p>Native C++ host + Zig backend (windows_native.Window). No WRL, no hand-rolled Zig COM.</p>
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

/// Fired by the backend on the UI thread whenever JS posts a message. Echo the
/// text back into the page through `Window.evalJs` — that visible echo is the
/// proof the JS -> host -> Zig -> JS loop closed.
fn onMsg(ctx: ?*anyopaque, payload: []const u8) void {
    _ = ctx;
    std.debug.print("[zig] onMsg received: {s}\n", .{payload});

    // Build  verveLog('Zig received: <text>');  escaping for a JS single-quoted
    // string literal (\, ', and newlines).
    var buf: [4096]u8 = undefined;
    var w: usize = 0;
    const prefix = "verveLog('Zig received: ";
    const suffix = "');";
    @memcpy(buf[0..prefix.len], prefix);
    w += prefix.len;
    for (payload) |c| {
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

    if (g_win) |h| h.evalJs(buf[0..w]);
}

pub fn main() void {
    const alloc = std.heap.page_allocator;

    var win = wn.Window.init(alloc, .{
        .title = "Verve win-native",
        .width = 900,
        .height = 640,
    }) catch {
        std.debug.print("[zig] Window.init failed\n", .{});
        return;
    };
    defer win.deinit();
    g_win = &win;

    win.setMessageHandler(onMsg, null);
    win.loadHtml(page, null) catch {};
    win.run();
}
