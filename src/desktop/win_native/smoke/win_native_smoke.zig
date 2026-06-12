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
var g_close_attempts: u32 = 0;
// Child window opened by the "child window" button. Kept so it can be
// deinit'd at process exit rather than leaked.
var g_child: ?wn.Window = null;

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
    \\  <div class="grp"><h3>Bundle 4 · events &amp; lifecycle</h3>
    \\    <button onclick="window.verve.post('cmd:close')">close() (1st close vetoed, 2nd allowed — see console)</button>
    \\    <br>
    \\    Drag files onto this window (drop handler logs paths to console).
    \\    Drag the window edge (resize handler logs w&times;h). Alt-tab away/back
    \\    (focus handler logs focus/blur).
    \\    <br>
    \\    <button onclick="window.verve.post('cmd:deliver-url')">deliverUrl("verve://deep/link")</button>
    \\    <a href="https://example.com">https://example.com</a>
    \\    (external link — legacy backend does NOT auto-route this; use the button)
    \\  </div>
    \\
    \\  <div class="grp"><h3>Bundle 5 · dialogs &amp; child windows</h3>
    \\    <button onclick="window.verve.post('cmd:open-file')">openFileDialog (txt/json)</button>
    \\    <button onclick="window.verve.post('cmd:save-file')">saveFileDialog (default note.txt)</button>
    \\    <button onclick="window.verve.post('cmd:alert')">showAlert (Yes/No → index)</button>
    \\    <button onclick="window.verve.post('cmd:child')">openChildWindow (2nd window)</button>
    \\  </div>
    \\
    \\  <div class="grp"><h3>Bundle 6 · cookies (ICoreWebView2CookieManager)</h3>
    \\    <button onclick="window.verve.post('cmd:cookie-set')">cookie set (verve_smoke)</button>
    \\    <button onclick="window.verve.post('cmd:cookie-get')">cookie get</button>
    \\    <button onclick="window.verve.post('cmd:cookie-delete')">cookie delete</button>
    \\    <button onclick="window.verve.post('cmd:cookie-clear')">cookie clear</button>
    \\    <br>(uses this page's own origin; load over a real http(s) page to exercise fully)
    \\  </div>
    \\
    \\  <div class="grp"><h3>Bundle 7 · clipboard (Win32 clipboard + WIC)</h3>
    \\    <button onclick="window.verve.post('cmd:clip-write-text')">clip write text</button>
    \\    <button onclick="window.verve.post('cmd:clip-read-text')">clip read text</button>
    \\    <button onclick="window.verve.post('cmd:clip-write-html')">clip write html</button>
    \\    <button onclick="window.verve.post('cmd:clip-read-html')">clip read html</button>
    \\    <button onclick="window.verve.post('cmd:clip-write-image')">clip write image</button>
    \\    <button onclick="window.verve.post('cmd:clip-read-image')">clip read image</button>
    \\    <br>(text/html/image round-trip through the native Win32 clipboard; paste into Notepad/Word to confirm)
    \\  </div>
    \\
    \\  <div class="grp"><h3>Bundle 8 · print, a11y, snapshot, toast, terminate</h3>
    \\    <button onclick="window.verve.post('cmd:print')">print (opens print UI)</button>
    \\    <button onclick="window.verve.post('cmd:snapshot')">snapshot &rarr; snapshot.png</button>
    \\    <button onclick="window.verve.post('cmd:toast')">toast (Action Center)</button>
    \\    <br>
    \\    <button onclick="window.verve.post('cmd:a11y-label')">a11y label</button>
    \\    <button onclick="window.verve.post('cmd:a11y-help')">a11y help</button>
    \\    <button onclick="window.verve.post('cmd:a11y-role')">a11y role-desc</button>
    \\    <button onclick="window.verve.post('cmd:a11y-subrole')">a11y subrole (dialog)</button>
    \\    <br>
    \\    <button onclick="if(confirm('terminate quits the app — continue?')) window.verve.post('cmd:terminate')"
    \\            style="background:#fdd">terminate (QUITS THE APP)</button>
    \\    <br>(snapshot writes next to the exe; toast logs ok/Unsupported; a11y label updates the title-bar name)
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
    } else if (std.mem.eql(u8, cmd, "close")) {
        win.close();
    } else if (std.mem.eql(u8, cmd, "deliver-url")) {
        win.deliverUrl("verve://deep/link");
    } else if (std.mem.eql(u8, cmd, "open-file")) {
        runOpenFile(win);
    } else if (std.mem.eql(u8, cmd, "save-file")) {
        runSaveFile(win);
    } else if (std.mem.eql(u8, cmd, "alert")) {
        runAlert(win);
    } else if (std.mem.eql(u8, cmd, "child")) {
        runChild(win);
    } else if (std.mem.eql(u8, cmd, "cookie-set")) {
        runCookieSet(win);
    } else if (std.mem.eql(u8, cmd, "cookie-get")) {
        runCookieGet(win);
    } else if (std.mem.eql(u8, cmd, "cookie-delete")) {
        runCookieDelete(win);
    } else if (std.mem.eql(u8, cmd, "cookie-clear")) {
        runCookieClear(win);
    } else if (std.mem.eql(u8, cmd, "clip-write-text")) {
        runClipWriteText(win);
    } else if (std.mem.eql(u8, cmd, "clip-read-text")) {
        runClipReadText(win);
    } else if (std.mem.eql(u8, cmd, "clip-write-html")) {
        runClipWriteHtml(win);
    } else if (std.mem.eql(u8, cmd, "clip-read-html")) {
        runClipReadHtml(win);
    } else if (std.mem.eql(u8, cmd, "clip-write-image")) {
        runClipWriteImage(win);
    } else if (std.mem.eql(u8, cmd, "clip-read-image")) {
        runClipReadImage(win);
    } else if (std.mem.eql(u8, cmd, "print")) {
        runPrint(win);
    } else if (std.mem.eql(u8, cmd, "snapshot")) {
        runSnapshot(win);
    } else if (std.mem.eql(u8, cmd, "toast")) {
        runToast(win);
    } else if (std.mem.eql(u8, cmd, "a11y-label")) {
        win.setAccessibilityLabel("Verve (a11y label)");
        win.evalJs("verveLog('a11y label: applied (check title-bar / screen reader name)');");
    } else if (std.mem.eql(u8, cmd, "a11y-help")) {
        win.setAccessibilityHelp("Verve smoke window help text");
        win.evalJs("verveLog('a11y help: applied (UIA HelpText — inspect with Narrator/Accessibility Insights)');");
    } else if (std.mem.eql(u8, cmd, "a11y-role")) {
        win.setAccessibilityRoleDescription("Verve panel");
        win.evalJs("verveLog('a11y role-desc: applied (UIA LocalizedControlType)');");
    } else if (std.mem.eql(u8, cmd, "a11y-subrole")) {
        win.setAccessibilitySubrole(.dialog);
        win.evalJs("verveLog('a11y subrole: applied (UIA IsDialog=true)');");
    } else if (std.mem.eql(u8, cmd, "terminate")) {
        std.debug.print("[zig] terminate -> quitting app\n", .{});
        win.terminate();
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

/// "open file" button — modal open dialog filtered to txt/json. Logs the chosen
/// path or "cancelled" both to the console and into the page.
fn runOpenFile(win: *wn.Window) void {
    const alloc = std.heap.page_allocator;
    const path = win.openFileDialog(alloc, .{
        .title = "Open a file",
        .allowed_extensions = &.{ "txt", "json" },
    }) catch |err| {
        std.debug.print("[zig] openFileDialog: {s}\n", .{@errorName(err)});
        win.evalJs("verveLog('open: cancelled / unsupported');");
        return;
    };
    defer alloc.free(path);
    std.debug.print("[zig] openFileDialog -> {s}\n", .{path});
    var buf: [4096]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "verveLog('open: {s}');", .{path}) catch return;
    win.evalJs(line);
}

/// "save file" button — modal save dialog seeded with a default name. Logs the
/// chosen path or "cancelled".
fn runSaveFile(win: *wn.Window) void {
    const alloc = std.heap.page_allocator;
    const path = win.saveFileDialog(alloc, .{
        .title = "Save a file",
        .default_name = "note.txt",
        .allowed_extensions = &.{"txt"},
    }) catch |err| {
        std.debug.print("[zig] saveFileDialog: {s}\n", .{@errorName(err)});
        win.evalJs("verveLog('save: cancelled / unsupported');");
        return;
    };
    defer alloc.free(path);
    std.debug.print("[zig] saveFileDialog -> {s}\n", .{path});
    var buf: [4096]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "verveLog('save: {s}');", .{path}) catch return;
    win.evalJs(line);
}

/// "alert" button — modal Yes/No alert. Logs the chosen button index (0 = Yes,
/// 1 = No), proving the button/return-index mapping round-trips.
fn runAlert(win: *wn.Window) void {
    const idx = win.showAlert(.{
        .title = "Confirm",
        .message = "Pick a button — its index comes back to Zig.",
        .buttons = &.{ "Yes", "No" },
        .style = .warning,
    });
    std.debug.print("[zig] showAlert -> index {d}\n", .{idx});
    var buf: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "verveLog('alert: chose index {d}');", .{idx}) catch return;
    win.evalJs(line);
}

/// "child window" button — opens a second independent top-level window with its
/// own page. Kept in g_child so main() can deinit it on exit. Re-clicking
/// replaces the reference (the old child leaks its HWND until process exit —
/// acceptable for the smoke).
fn runChild(win: *wn.Window) void {
    const child = win.openChildWindow(.{
        .title = "Verve child window",
        .width = 500,
        .height = 360,
    }) catch |err| {
        std.debug.print("[zig] openChildWindow: {s}\n", .{@errorName(err)});
        return;
    };
    g_child = child;
    if (g_child) |*c| {
        c.loadHtml(
            \\<!doctype html><html><body style="font-family:system-ui;padding:2rem">
            \\<h1>Child window</h1><p>Independent top-level window + WebView2.</p>
            \\</body></html>
        , null) catch {};
        c.show();
    }
    std.debug.print("[zig] openChildWindow -> opened\n", .{});
    win.evalJs("verveLog('child: opened a second window');");
}

// ---- Bundle 6 · cookies -----------------------------------------------------
//
// All four route through win.cookies() -> the CookieStore -> the native-host
// cookie ABI. They use the page's own origin (empty domain lets WebView2 apply
// it), so loading the smoke over the verve:// HTML page exercises the plumbing;
// a real http(s) page exercises full round-trips.

const COOKIE_NAME = "verve_smoke";

/// "cookie set" — write a test cookie and log success/failure.
fn runCookieSet(win: *wn.Window) void {
    win.cookies().set(.{
        .name = COOKIE_NAME,
        .value = "hello-from-zig",
        // Concrete domain so WebView2 actually stores it: the smoke page is a
        // NavigateToString opaque origin, so an empty/origin-derived domain has
        // nothing to bind to. GetCookies(null) is profile-wide, so a real
        // domain round-trips through set -> get -> delete regardless of origin.
        .domain = "verve.local",
        .path = "/",
        .same_site = .lax,
    }) catch |err| {
        std.debug.print("[zig] cookie set: {s}\n", .{@errorName(err)});
        win.evalJs("verveLog('cookie set: error / unsupported');");
        return;
    };
    std.debug.print("[zig] cookie set ok\n", .{});
    win.evalJs("verveLog('cookie set: ok');");
}

/// "cookie get" — read the test cookie back and log its fields.
fn runCookieGet(win: *wn.Window) void {
    const alloc = std.heap.page_allocator;
    const maybe = win.cookies().get(alloc, COOKIE_NAME) catch |err| {
        std.debug.print("[zig] cookie get: {s}\n", .{@errorName(err)});
        win.evalJs("verveLog('cookie get: error / unsupported');");
        return;
    };
    if (maybe) |c| {
        defer {
            alloc.free(c.name);
            alloc.free(c.value);
            alloc.free(c.domain);
            alloc.free(c.path);
        }
        std.debug.print(
            "[zig] cookie get -> name={s} value={s} domain={s} path={s} expires={d} secure={} httpOnly={} sameSite={s}\n",
            .{ c.name, c.value, c.domain, c.path, c.expires_unix, c.secure, c.http_only, @tagName(c.same_site) },
        );
        var buf: [1024]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buf,
            "verveLog('cookie get: {s}={s} domain=\"{s}\" path=\"{s}\" sameSite={s}');",
            .{ c.name, c.value, c.domain, c.path, @tagName(c.same_site) },
        ) catch return;
        win.evalJs(line);
    } else {
        std.debug.print("[zig] cookie get -> (none)\n", .{});
        win.evalJs("verveLog('cookie get: (no match)');");
    }
}

/// True if COOKIE_NAME currently exists (frees any returned cookie). Used to
/// show real before/after status so delete/clear visibly do something.
fn cookiePresent(win: *wn.Window) bool {
    const alloc = std.heap.page_allocator;
    const maybe = win.cookies().get(alloc, COOKIE_NAME) catch return false;
    if (maybe) |c| {
        alloc.free(c.name);
        alloc.free(c.value);
        alloc.free(c.domain);
        alloc.free(c.path);
        return true;
    }
    return false;
}

/// "cookie delete" — remove the test cookie, then re-query to report whether it
/// is actually gone (visible confirmation the op took effect).
fn runCookieDelete(win: *wn.Window) void {
    win.cookies().delete(COOKIE_NAME) catch |err| {
        std.debug.print("[zig] cookie delete: {s}\n", .{@errorName(err)});
        win.evalJs("verveLog('cookie delete: error / unsupported');");
        return;
    };
    const still = cookiePresent(win);
    std.debug.print("[zig] cookie delete ok, still_present={}\n", .{still});
    win.evalJs(if (still)
        "verveLog('cookie delete: ran, but cookie STILL present (backend no-op)');"
    else
        "verveLog('cookie delete: ok — cookie now absent');");
}

/// "cookie clear" — wipe the store, then re-query to report whether the test
/// cookie is actually gone.
fn runCookieClear(win: *wn.Window) void {
    win.cookies().clear() catch |err| {
        std.debug.print("[zig] cookie clear: {s}\n", .{@errorName(err)});
        win.evalJs("verveLog('cookie clear: error / unsupported');");
        return;
    };
    const still = cookiePresent(win);
    std.debug.print("[zig] cookie clear ok, still_present={}\n", .{still});
    win.evalJs(if (still)
        "verveLog('cookie clear: ran, but cookie STILL present (backend no-op)');"
    else
        "verveLog('cookie clear: ok — cookie now absent');");
}

// ---- Bundle 7 · clipboard ---------------------------------------------------
//
// All six route through win.clipboard() -> the Clipboard handle -> the
// native-host clipboard ABI. Text is CF_UNICODETEXT, HTML is the registered
// "HTML Format" (built/parsed by the pure-Zig clipboard_codec), images are
// CF_DIBV5 transcoded PNG<->DIB via WIC. Paste into Notepad / Word / an image
// editor to confirm the round-trip on real hardware.

/// A 2x2 RGBA PNG (red/green/blue/white). Used by the image round-trip buttons.
const TINY_PNG = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x72, 0xb6, 0x0d, 0x24, 0x00, 0x00, 0x00,
    0x1d, 0x49, 0x44, 0x41, 0x54, 0x08, 0xd7, 0x63, 0xf8, 0xcf, 0xc0, 0xf0,
    0x9f, 0x81, 0x81, 0x01, 0x86, 0xa0, 0x4c, 0x10, 0xc3, 0x7f, 0x0c, 0x0c,
    0x0c, 0x00, 0x24, 0x06, 0x03, 0x01, 0x6d, 0x95, 0x84, 0x5b, 0x00, 0x00,
    0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
};

const CLIP_TEXT = "verve clipboard test";
const CLIP_HTML = "<b>verve</b> clipboard <i>html</i>";

fn runClipWriteText(win: *wn.Window) void {
    win.clipboard().writeText(CLIP_TEXT) catch |err| {
        std.debug.print("[zig] clip write text: {s}\n", .{@errorName(err)});
        win.evalJs("verveLog('clip write text: error / unsupported');");
        return;
    };
    std.debug.print("[zig] clip write text ok\n", .{});
    win.evalJs("verveLog('clip write text: ok (\"" ++ CLIP_TEXT ++ "\")');");
}

fn runClipReadText(win: *wn.Window) void {
    const alloc = std.heap.page_allocator;
    const maybe = win.clipboard().readText(alloc) catch |err| {
        std.debug.print("[zig] clip read text: {s}\n", .{@errorName(err)});
        win.evalJs("verveLog('clip read text: error / unsupported');");
        return;
    };
    if (maybe) |t| {
        defer alloc.free(t);
        std.debug.print("[zig] clip read text -> {s}\n", .{t});
        var buf: [1024]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "verveLog('clip read text: \"{s}\"');", .{t}) catch return;
        win.evalJs(line);
    } else {
        std.debug.print("[zig] clip read text -> (none)\n", .{});
        win.evalJs("verveLog('clip read text: (no text)');");
    }
}

fn runClipWriteHtml(win: *wn.Window) void {
    win.clipboard().writeHtml(CLIP_HTML) catch |err| {
        std.debug.print("[zig] clip write html: {s}\n", .{@errorName(err)});
        win.evalJs("verveLog('clip write html: error / unsupported');");
        return;
    };
    std.debug.print("[zig] clip write html ok\n", .{});
    win.evalJs("verveLog('clip write html: ok');");
}

fn runClipReadHtml(win: *wn.Window) void {
    const alloc = std.heap.page_allocator;
    const maybe = win.clipboard().readHtml(alloc) catch |err| {
        std.debug.print("[zig] clip read html: {s}\n", .{@errorName(err)});
        win.evalJs("verveLog('clip read html: error / unsupported');");
        return;
    };
    if (maybe) |h| {
        defer alloc.free(h);
        std.debug.print("[zig] clip read html -> {s}\n", .{h});
        // The fragment is itself HTML; log it as a length + console dump rather
        // than injecting raw markup into the page.
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "verveLog('clip read html: {d} fragment bytes (see console)');", .{h.len}) catch return;
        win.evalJs(line);
    } else {
        std.debug.print("[zig] clip read html -> (none)\n", .{});
        win.evalJs("verveLog('clip read html: (no html)');");
    }
}

fn runClipWriteImage(win: *wn.Window) void {
    win.clipboard().writeImage(&TINY_PNG) catch |err| {
        std.debug.print("[zig] clip write image: {s}\n", .{@errorName(err)});
        win.evalJs("verveLog('clip write image: error / unsupported');");
        return;
    };
    std.debug.print("[zig] clip write image ok ({d} PNG bytes in)\n", .{TINY_PNG.len});
    win.evalJs("verveLog('clip write image: ok (2x2 PNG)');");
}

fn runClipReadImage(win: *wn.Window) void {
    const alloc = std.heap.page_allocator;
    const maybe = win.clipboard().readImage(alloc) catch |err| {
        std.debug.print("[zig] clip read image: {s}\n", .{@errorName(err)});
        win.evalJs("verveLog('clip read image: error / unsupported');");
        return;
    };
    if (maybe) |png| {
        defer alloc.free(png);
        std.debug.print("[zig] clip read image -> {d} PNG bytes\n", .{png.len});
        var buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "verveLog('clip read image: {d} PNG bytes');", .{png.len}) catch return;
        win.evalJs(line);
    } else {
        std.debug.print("[zig] clip read image -> (none)\n", .{});
        win.evalJs("verveLog('clip read image: (no image)');");
    }
}

// ---- Bundle 8 · print / snapshot / toast ------------------------------------

/// "print" button — opens the WebView2 print UI (browser preview kind).
fn runPrint(win: *wn.Window) void {
    win.printWithOptions(.{}) catch |err| {
        std.debug.print("[zig] print: {s}\n", .{@errorName(err)});
        win.evalJs("verveLog('print: error / unsupported (needs WebView2 runtime ~v111+)');");
        return;
    };
    std.debug.print("[zig] print: opened print UI\n", .{});
    win.evalJs("verveLog('print: opened the print UI');");
}

/// "snapshot" button — CapturePreview the page to "snapshot.png" next to the
/// exe and log the resolved path (or the error).
fn runSnapshot(win: *wn.Window) void {
    const path = "snapshot.png";
    win.takeSnapshotPng(path) catch |err| {
        std.debug.print("[zig] snapshot: {s}\n", .{@errorName(err)});
        win.evalJs("verveLog('snapshot: error (" ++ "see console)');");
        return;
    };
    std.debug.print("[zig] snapshot -> wrote {s} (next to the exe)\n", .{path});
    win.evalJs("verveLog('snapshot: wrote " ++ path ++ " next to the exe');");
}

/// "toast" button — fire an Action Center toast. Logs whether the WinRT path
/// ran or fell back (Unsupported / Backend).
fn runToast(win: *wn.Window) void {
    const alloc = std.heap.page_allocator;
    wn.showToast(alloc, "Verve", "Toast from the native-host backend.") catch |err| {
        std.debug.print("[zig] toast: {s}\n", .{@errorName(err)});
        var buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "verveLog('toast: {s} (no toast shown)');", .{@errorName(err)}) catch return;
        win.evalJs(line);
        return;
    };
    std.debug.print("[zig] toast: shown\n", .{});
    win.evalJs("verveLog('toast: shown (check the Action Center)');");
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

/// Registered via setResizeHandler; logs client-area size on every WM_SIZE.
fn onResize(ctx: ?*anyopaque, w: u32, h: u32) void {
    _ = ctx;
    std.debug.print("[zig] resize: {d}x{d}\n", .{ w, h });
}

/// Registered via setFocusHandler; logs window focus/blur on WM_ACTIVATE.
fn onFocus(ctx: ?*anyopaque, focused: bool) void {
    _ = ctx;
    std.debug.print("[zig] focus: {s}\n", .{if (focused) "focused" else "blurred"});
}

/// Registered via setCloseHandler. Vetoes the FIRST close attempt and allows
/// the second — exercises the veto path. Returns true to allow, false to veto.
fn onClose(ctx: ?*anyopaque) bool {
    _ = ctx;
    g_close_attempts += 1;
    const allow = g_close_attempts >= 2;
    std.debug.print("[zig] close attempt #{d} -> {s}\n", .{
        g_close_attempts, if (allow) "allow" else "VETO",
    });
    return allow;
}

/// Registered via setDragDropHandler; logs each dropped file path.
fn onDragDrop(ctx: ?*anyopaque, paths: []const []const u8) void {
    _ = ctx;
    std.debug.print("[zig] drop: {d} path(s)\n", .{paths.len});
    for (paths, 0..) |p, i| std.debug.print("[zig]   [{d}] {s}\n", .{ i, p });
}

/// Registered via setUrlOpenHandler; logs deep-link URLs (driven by deliverUrl).
fn onUrlOpen(ctx: ?*anyopaque, url: []const u8) void {
    _ = ctx;
    std.debug.print("[zig] url-open: {s}\n", .{url});
    if (g_win) |w| {
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "verveLog('url-open: {s}');", .{url}) catch return;
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
        // Window.init always navigates verve://app/index.html before the
        // loadHtml below replaces the page. Without an asset entry that
        // boot request logs a scheme-handler "not found" — give it a real
        // page so startup resolves cleanly (and the embedded asset router
        // gets exercised on hardware as a side effect).
        .assets = &.{.{
            .path = "index.html",
            .bytes = "<!doctype html><title>verve smoke</title>booting…",
            .content_type = "text/html",
        }},
    }) catch {
        std.debug.print("[zig] Window.init failed\n", .{});
        return;
    };
    defer win.deinit();
    g_win = &win;

    win.setMessageHandler(onMsg, null);
    win.setColorSchemeHandler(onColorScheme, null);
    win.setResizeHandler(onResize, null);
    win.setFocusHandler(onFocus, null);
    win.setCloseHandler(onClose, null);
    win.setDragDropHandler(onDragDrop, null);
    win.setUrlOpenHandler(onUrlOpen, null);
    win.loadHtml(page, null) catch {};
    win.run();

    // Clean up the child window if one was opened.
    if (g_child) |*c| c.deinit();
}
