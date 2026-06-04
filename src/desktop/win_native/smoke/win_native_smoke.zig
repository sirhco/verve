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
    \\  button { margin: .15rem; padding: .4rem .7rem; }
    \\  .grp { margin-top: 1rem; }
    \\  .grp h3 { margin: .4rem 0 .2rem; font-size: .9rem; color: #446; }
    \\</style></head><body>
    \\  <h1>Verve · WebView2 native-host</h1>
    \\  <p>Native C++ host + Zig backend (windows_native.Window). No WRL, no hand-rolled Zig COM.</p>
    \\  <button onclick="window.verve.post('ping ' + Date.now())">ping &rarr; Zig</button>
    \\
    \\  <div class="grp"><h3>Bundle 2 · geometry &amp; state (click → command → Zig backend)</h3>
    \\    <button onclick="window.verve.post('cmd:title')">setTitle("Changed")</button>
    \\    <button onclick="window.verve.post('cmd:resize')">setSize(640,480)</button>
    \\    <button onclick="window.verve.post('cmd:move')">setPosition(80,80)</button>
    \\    <button onclick="window.verve.post('cmd:center')">center</button>
    \\    <br>
    \\    <button onclick="window.verve.post('cmd:min')">minimize</button>
    \\    <button onclick="window.verve.post('cmd:max')">maximize</button>
    \\    <button onclick="window.verve.post('cmd:restore')">restore</button>
    \\    <button onclick="window.verve.post('cmd:hide')">hide (then re-show via taskbar/timer)</button>
    \\    <button onclick="window.verve.post('cmd:show')">show</button>
    \\    <button onclick="window.verve.post('cmd:focus')">focus</button>
    \\    <br>
    \\    <button onclick="window.verve.post('cmd:topmost-on')">alwaysOnTop on</button>
    \\    <button onclick="window.verve.post('cmd:topmost-off')">alwaysOnTop off</button>
    \\    <button onclick="window.verve.post('cmd:opacity-dim')">opacity 0.6</button>
    \\    <button onclick="window.verve.post('cmd:opacity-full')">opacity 1.0</button>
    \\    <br>
    \\    <button onclick="window.verve.post('cmd:resizable-off')">resizable off</button>
    \\    <button onclick="window.verve.post('cmd:resizable-on')">resizable on</button>
    \\    <button onclick="window.verve.post('cmd:minsize')">minSize(400,300)</button>
    \\    <button onclick="window.verve.post('cmd:maxsize')">maxSize(1200,900)</button>
    \\    <button onclick="window.verve.post('cmd:clearsize')">clear min/max</button>
    \\    <br>
    \\    <button onclick="window.verve.post('cmd:fs-on')">fullscreen on</button>
    \\    <button onclick="window.verve.post('cmd:fs-off')">fullscreen off</button>
    \\    <button onclick="window.verve.post('cmd:flash')">requestAttention(false)</button>
    \\    <button onclick="window.verve.post('cmd:flash-crit')">requestAttention(true)</button>
    \\    <br>
    \\    <button onclick="window.verve.post('cmd:report')">report state &rarr; Zig &rarr; here</button>
    \\  </div>
    \\
    \\  <div class="grp"><h3>Bundle 3 · navigation &amp; webview state</h3>
    \\    <a href="#a">anchor A</a> <a href="#b">anchor B</a> <a href="#c">anchor C</a>
    \\    (click a few to populate session history)
    \\    <br>
    \\    <button onclick="window.verve.post('cmd:reload')">reload</button>
    \\    <button onclick="window.verve.post('cmd:back')">goBack</button>
    \\    <button onclick="window.verve.post('cmd:forward')">goForward</button>
    \\    <button onclick="window.verve.post('cmd:zoom-in')">setZoom(1.5)</button>
    \\    <button onclick="window.verve.post('cmd:zoom-reset')">setZoom(1.0)</button>
    \\    <button onclick="window.verve.post('cmd:nav-report')">report nav &rarr; Zig &rarr; here</button>
    \\  </div>
    \\
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
/// Dispatch a `cmd:<name>` bridge message to a backend Window method. Returns
/// true if it handled the payload (so the echo below is skipped).
fn dispatchCommand(win: *wn.Window, payload: []const u8) bool {
    const prefix = "cmd:";
    if (!std.mem.startsWith(u8, payload, prefix)) return false;
    const cmd = payload[prefix.len..];

    if (std.mem.eql(u8, cmd, "title")) {
        win.setTitle("Changed");
    } else if (std.mem.eql(u8, cmd, "resize")) {
        win.setSize(640, 480);
    } else if (std.mem.eql(u8, cmd, "move")) {
        win.setPosition(80, 80);
    } else if (std.mem.eql(u8, cmd, "center")) {
        win.center();
    } else if (std.mem.eql(u8, cmd, "min")) {
        win.minimize();
    } else if (std.mem.eql(u8, cmd, "max")) {
        win.maximize();
    } else if (std.mem.eql(u8, cmd, "restore")) {
        win.restore();
    } else if (std.mem.eql(u8, cmd, "hide")) {
        win.hide();
    } else if (std.mem.eql(u8, cmd, "show")) {
        win.show();
    } else if (std.mem.eql(u8, cmd, "focus")) {
        win.focus();
    } else if (std.mem.eql(u8, cmd, "topmost-on")) {
        win.setAlwaysOnTop(true);
    } else if (std.mem.eql(u8, cmd, "topmost-off")) {
        win.setAlwaysOnTop(false);
    } else if (std.mem.eql(u8, cmd, "opacity-dim")) {
        win.setOpacity(0.6);
    } else if (std.mem.eql(u8, cmd, "opacity-full")) {
        win.setOpacity(1.0);
    } else if (std.mem.eql(u8, cmd, "resizable-off")) {
        win.setResizable(false);
    } else if (std.mem.eql(u8, cmd, "resizable-on")) {
        win.setResizable(true);
    } else if (std.mem.eql(u8, cmd, "minsize")) {
        win.setMinSize(400, 300);
    } else if (std.mem.eql(u8, cmd, "maxsize")) {
        win.setMaxSize(1200, 900);
    } else if (std.mem.eql(u8, cmd, "clearsize")) {
        win.setMinSize(0, 0);
        win.setMaxSize(0, 0);
    } else if (std.mem.eql(u8, cmd, "fs-on")) {
        win.setFullscreen(true);
    } else if (std.mem.eql(u8, cmd, "fs-off")) {
        win.setFullscreen(false);
    } else if (std.mem.eql(u8, cmd, "flash")) {
        win.requestAttention(false);
    } else if (std.mem.eql(u8, cmd, "flash-crit")) {
        win.requestAttention(true);
    } else if (std.mem.eql(u8, cmd, "report")) {
        reportState(win);
    } else if (std.mem.eql(u8, cmd, "reload")) {
        win.reload();
    } else if (std.mem.eql(u8, cmd, "back")) {
        win.goBack();
    } else if (std.mem.eql(u8, cmd, "forward")) {
        win.goForward();
    } else if (std.mem.eql(u8, cmd, "zoom-in")) {
        win.setZoom(1.5);
    } else if (std.mem.eql(u8, cmd, "zoom-reset")) {
        win.setZoom(1.0);
    } else if (std.mem.eql(u8, cmd, "nav-report")) {
        reportNav(win);
    } else {
        std.debug.print("[zig] unknown cmd: {s}\n", .{cmd});
        return true;
    }
    std.debug.print("[zig] ran cmd: {s}\n", .{cmd});
    return true;
}

/// Read back the is*/scaleFactor queries and push a human-readable line into
/// the page — proves the bool/float-returning host fns round-trip.
fn reportState(win: *wn.Window) void {
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buf,
        "verveLog('state: minimized={} maximized={} fullscreen={} scale={d:.2}');",
        .{ win.isMinimized(), win.isMaximized(), win.isFullscreen(), win.scaleFactor() },
    ) catch return;
    win.evalJs(line);
}

/// Read back the nav queries (canGo*, getZoom, currentUrl/Title, colorScheme)
/// and push a human-readable line into the page — proves the bool/double/
/// buffer-grow/enum host fns round-trip.
fn reportNav(win: *wn.Window) void {
    const alloc = std.heap.page_allocator;
    const url = win.currentUrl(alloc) catch "<err>";
    defer if (!std.mem.eql(u8, url, "<err>")) alloc.free(url);
    const title = win.currentTitle(alloc) catch "<err>";
    defer if (!std.mem.eql(u8, title, "<err>")) alloc.free(title);

    var buf: [4096]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buf,
        "verveLog('nav: back={} fwd={} zoom={d:.2} scheme={s} title=\"{s}\" url=\"{s}\"');",
        .{
            win.canGoBack(),             win.canGoForward(), win.getZoom(),
            @tagName(win.colorScheme()), title,              url,
        },
    ) catch return;
    win.evalJs(line);
}

/// Registered via setColorSchemeHandler; logs OS light/dark toggles. Operator
/// flips the Windows theme to exercise it.
fn onColorScheme(ctx: ?*anyopaque, scheme: wn.ColorScheme) void {
    _ = ctx;
    std.debug.print("[zig] color scheme changed: {s}\n", .{@tagName(scheme)});
    if (g_win) |w| {
        var buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buf,
            "verveLog('OS theme -> {s}');",
            .{@tagName(scheme)},
        ) catch return;
        w.evalJs(line);
    }
}

fn onMsg(ctx: ?*anyopaque, payload: []const u8) void {
    _ = ctx;
    std.debug.print("[zig] onMsg received: {s}\n", .{payload});

    if (g_win) |w| {
        if (dispatchCommand(w, payload)) return;
    }

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
    win.setColorSchemeHandler(onColorScheme, null);
    win.loadHtml(page, null) catch {};
    win.run();
}
