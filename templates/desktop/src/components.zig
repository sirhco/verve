//! Desktop scaffold components.
//!
//! Built into HTML at build time by `tools/render_index.zig` via
//! `verve.Renderer.render`. The output replaces the on-disk
//! `frontend/index.html` (which no longer exists) inside the
//! `public_assets` table.
//!
//! IDs on interactive elements (`#ping`, `#cookie-*`, `#open-child`,
//! `#log`) are referenced by the inline script in `page()` and by any
//! future WASM client hydration (J2/J3).

const verve = @import("verve");

pub fn page(ctx: *const verve.Context, body: *verve.Node) !*verve.Node {
    return ctx.el("html").attr("lang", "en").children(.{
        ctx.el("head").children(.{
            ctx.el("meta").attr("charset", "utf-8"),
            ctx.el("meta").attr("name", "viewport").attr("content", "width=device-width, initial-scale=1"),
            ctx.title("Verve Desktop"),
            ctx.link("stylesheet", "style.css"),
            ctx.script("verve_desktop.js").attr("defer", ""),
        }),
        ctx.el("body").children(.{
            body,
            ctx.scriptInline(inline_js),
        }),
    }).build();
}

pub fn home(ctx: *const verve.Context) !*verve.Node {
    return ctx.div().children(.{
        ctx.header().children(.{
            ctx.h1("Verve Desktop"),
            ctx.p().class("subtitle").text("Native window, native webview, zero Electron."),
        }),
        ctx.main_().children(.{
            ctx.section().class("card").children(.{
                ctx.h2("IPC round-trip"),
                ctx.div().class("row").children(.{
                    ctx.button("Send ping").id("ping"),
                }),
            }),
            ctx.section().class("card").children(.{
                ctx.h2("Cookies"),
                ctx.div().class("row").children(.{
                    ctx.input().id("cookie-name").type_("text").value("verve_demo"),
                    ctx.input().id("cookie-value").type_("text").value("hello"),
                    ctx.button("Set").id("cookie-set"),
                    ctx.button("Get").id("cookie-get"),
                    ctx.button("Clear all").id("cookie-clear"),
                }),
            }),
            ctx.section().class("card").children(.{
                ctx.h2("Multi-window"),
                ctx.div().class("row").children(.{
                    ctx.button("Open child window").id("open-child"),
                }),
            }),
            ctx.section().class("card").children(.{
                ctx.h2("Counter (WASM hydration)"),
                ctx.div().class("row").children(.{
                    ctx.span().class("count").bind("count").textInt(@as(i32, 0)),
                    ctx.button("-").onClick("decrement_counter"),
                    ctx.button("+").onClick("increment_counter"),
                }),
                ctx.p().children(.{
                    ctx.span().text("Total clicks: "),
                    ctx.span().bind("clicks").text("0"),
                }),
            }),
            ctx.section().class("card").children(.{
                ctx.h2("Notifications"),
                ctx.div().class("row").children(.{
                    ctx.button("Notify").id("notify"),
                }),
            }),
            ctx.section().class("card").children(.{
                ctx.h2("Deep link"),
                ctx.p().text("Open verve://app/anything from a terminal (or click a link on a registered scheme) — the URL appears here."),
                ctx.pre().id("deep-link-url").text("(no URL received yet)"),
            }),
            ctx.section().class("card").children(.{
                ctx.h2("Tray menu"),
                ctx.p().text("Click the status-bar icon (right-click on Windows) for Show window, Notify, and Quit. Item clicks dispatch to handlers.onTrayItem in native code."),
            }),
            ctx.section().class("card").children(.{
                ctx.h2("System info"),
                ctx.p().text("Read-only OS / runtime fields from desktop.system + desktop.disk."),
                ctx.div().class("row").children(.{
                    ctx.button("Read").id("sysinfo-read"),
                }),
                ctx.div().id("sysinfo-result").class("result-panel").text(""),
            }),
            ctx.section().class("card").children(.{
                ctx.h2("Disk space"),
                ctx.p().text("desktop.disk.spaceAt(home) — POSIX statvfs / Win GetDiskFreeSpaceExW."),
                ctx.div().class("row").children(.{
                    ctx.button("Check home directory").id("disk-check"),
                }),
                ctx.div().id("disk-result").class("result-panel").text(""),
            }),
            ctx.section().class("card").children(.{
                ctx.h2("File dialog"),
                ctx.p().text("Native file-open panel (NSOpenPanel / IFileOpenDialog / GtkFileChooser). Cancel returns ok:false."),
                ctx.div().class("row").children(.{
                    ctx.button("Open file…").id("file-open"),
                }),
                ctx.div().id("file-result").class("result-panel").text(""),
            }),
            ctx.section().class("card").children(.{
                ctx.h2("Window controls"),
                ctx.p().text("Hits the cross-platform Window lifecycle methods."),
                ctx.div().class("row").children(.{
                    ctx.button("Minimize").id("win-min"),
                    ctx.button("Maximize").id("win-max"),
                    ctx.button("Restore").id("win-restore"),
                    ctx.button("Center").id("win-center"),
                    ctx.button("Fullscreen").id("win-fs-on"),
                    ctx.button("Exit FS").id("win-fs-off"),
                }),
            }),
            ctx.section().class("card").children(.{
                ctx.h2("HTTP fetch"),
                ctx.p().text("Hits the GitHub public API for the Zig repo via std.http.Client in a Zig IPC handler. JSON parsed server-side; only the headline fields cross the bridge."),
                ctx.div().class("row").children(.{
                    ctx.button("Fetch ziglang/zig").id("fetch-zig"),
                }),
                ctx.div().id("fetch-result").class("result-panel").text(""),
            }),
            ctx.section().class("card").children(.{
                ctx.h2("Print"),
                ctx.p().text("Native print dialog via NSPrintOperation (macOS), ICoreWebView2_16::ShowPrintUI (Windows), or webkit_print_operation_run_dialog (Linux). 'System' forces the OS dialog on Windows; default uses the browser preview."),
                ctx.div().class("row").children(.{
                    ctx.button("Print (default)").id("print-default"),
                    ctx.button("Print (system)").id("print-system"),
                }),
            }),
            ctx.section().class("card").children(.{
                ctx.h2("Log"),
                ctx.pre().id("log").text("bridge ready"),
            }),
        }),
    }).build();
}

const inline_js =
    \\// window.verve is injected at document-start by the framework,
    \\// so it's already defined before this inline script runs.
    \\const logEl = document.getElementById('log');
    \\function log(msg) {
    \\  logEl.textContent = msg + '\n' + logEl.textContent;
    \\}
    \\
    \\async function call(type, args) {
    \\  log('→ ' + type + ' ' + JSON.stringify(args || {}));
    \\  try {
    \\    const reply = await window.verve.request(Object.assign({ type }, args || {}));
    \\    log('← ' + JSON.stringify(reply));
    \\  } catch (err) {
    \\    log('✗ ' + err.message);
    \\  }
    \\}
    \\
    \\document.getElementById('ping').addEventListener('click', () => {
    \\  call('ping', { sent_at: Date.now() });
    \\});
    \\
    \\document.getElementById('cookie-set').addEventListener('click', () => {
    \\  call('cookie_set', {
    \\    name: document.getElementById('cookie-name').value,
    \\    value: document.getElementById('cookie-value').value,
    \\  });
    \\});
    \\
    \\document.getElementById('cookie-get').addEventListener('click', () => {
    \\  call('cookie_get', { name: document.getElementById('cookie-name').value });
    \\});
    \\
    \\document.getElementById('cookie-clear').addEventListener('click', () => {
    \\  call('cookie_clear');
    \\});
    \\
    \\document.getElementById('open-child').addEventListener('click', () => {
    \\  call('open_child');
    \\});
    \\
    \\document.getElementById('notify').addEventListener('click', () => {
    \\  call('notify', { title: 'Verve', body: 'Notification from the desktop demo.' });
    \\});
    \\
    \\function bytes(n) {
    \\  if (!n) return '0 B';
    \\  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
    \\  let i = 0;
    \\  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    \\  return n.toFixed(i ? 1 : 0) + ' ' + u[i];
    \\}
    \\function secs(n) {
    \\  const d = Math.floor(n / 86400);
    \\  const h = Math.floor((n % 86400) / 3600);
    \\  const m = Math.floor((n % 3600) / 60);
    \\  if (d) return d + 'd ' + h + 'h ' + m + 'm';
    \\  if (h) return h + 'h ' + m + 'm';
    \\  return m + 'm ' + (n % 60) + 's';
    \\}
    \\
    \\document.getElementById('sysinfo-read').addEventListener('click', async () => {
    \\  const out = document.getElementById('sysinfo-result');
    \\  out.textContent = 'reading…';
    \\  out.className = 'result-panel loading';
    \\  try {
    \\    const r = await window.verve.request({ type: 'system_info' });
    \\    out.className = 'result-panel ok';
    \\    out.innerHTML =
    \\      '<dl class="kv">' +
    \\      '<dt>OS</dt><dd>' + r.os_version + '</dd>' +
    \\      '<dt>Locale</dt><dd>' + r.locale + '</dd>' +
    \\      '<dt>CPUs</dt><dd>' + r.cpu_count + '</dd>' +
    \\      '<dt>RAM</dt><dd>' + bytes(r.total_memory_bytes) + '</dd>' +
    \\      '<dt>Uptime</dt><dd>' + secs(r.uptime_seconds) + '</dd>' +
    \\      '</dl>';
    \\  } catch (err) { out.textContent = '✗ ' + err.message; out.className = 'result-panel error'; }
    \\});
    \\
    \\document.getElementById('disk-check').addEventListener('click', async () => {
    \\  const out = document.getElementById('disk-result');
    \\  out.textContent = 'reading…';
    \\  out.className = 'result-panel loading';
    \\  try {
    \\    const r = await window.verve.request({ type: 'disk_space' });
    \\    if (!r.ok) { out.textContent = '✗ unavailable'; out.className = 'result-panel error'; return; }
    \\    out.className = 'result-panel ok';
    \\    out.innerHTML =
    \\      '<dl class="kv">' +
    \\      '<dt>Path</dt><dd>' + r.path + '</dd>' +
    \\      '<dt>Total</dt><dd>' + bytes(r.total_bytes) + '</dd>' +
    \\      '<dt>Available</dt><dd>' + bytes(r.available_bytes) + '</dd>' +
    \\      '</dl>';
    \\  } catch (err) { out.textContent = '✗ ' + err.message; out.className = 'result-panel error'; }
    \\});
    \\
    \\document.getElementById('file-open').addEventListener('click', async () => {
    \\  const out = document.getElementById('file-result');
    \\  out.textContent = 'opening…';
    \\  out.className = 'result-panel loading';
    \\  try {
    \\    const r = await window.verve.request({ type: 'open_file' });
    \\    if (!r.ok) { out.textContent = r.status; out.className = 'result-panel'; return; }
    \\    out.className = 'result-panel ok';
    \\    out.innerHTML =
    \\      '<dl class="kv">' +
    \\      '<dt>Path</dt><dd>' + r.path + '</dd>' +
    \\      '<dt>Size</dt><dd>' + bytes(r.size_bytes) + '</dd>' +
    \\      '</dl>';
    \\  } catch (err) { out.textContent = '✗ ' + err.message; out.className = 'result-panel error'; }
    \\});
    \\
    \\function winAction(a) { return () => call('window_action', { action: a }); }
    \\document.getElementById('win-min').addEventListener('click', winAction('minimize'));
    \\document.getElementById('win-max').addEventListener('click', winAction('maximize'));
    \\document.getElementById('win-restore').addEventListener('click', winAction('restore'));
    \\document.getElementById('win-center').addEventListener('click', winAction('center'));
    \\document.getElementById('win-fs-on').addEventListener('click', winAction('fullscreen_on'));
    \\document.getElementById('win-fs-off').addEventListener('click', winAction('fullscreen_off'));
    \\
    \\document.getElementById('fetch-zig').addEventListener('click', async () => {
    \\  const out = document.getElementById('fetch-result');
    \\  out.textContent = 'fetching…';
    \\  out.className = 'result-panel loading';
    \\  try {
    \\    const r = await window.verve.request({ type: 'fetch_url' });
    \\    if (!r.ok) {
    \\      out.textContent = '✗ ' + r.status;
    \\      out.className = 'result-panel error';
    \\      return;
    \\    }
    \\    out.className = 'result-panel ok';
    \\    out.innerHTML =
    \\      '<strong>' + r.full_name + '</strong>' +
    \\      '<div class="muted">' + (r.description || '(no description)') + '</div>' +
    \\      '<div class="stats">★ ' + r.stars.toLocaleString() + ' · ⑂ ' + r.forks.toLocaleString() + '</div>';
    \\  } catch (err) {
    \\    out.textContent = '✗ ' + err.message;
    \\    out.className = 'result-panel error';
    \\  }
    \\});
    \\
    \\document.getElementById('print-default').addEventListener('click', () => {
    \\  call('print_page', { kind: 'default' });
    \\});
    \\
    \\document.getElementById('print-system').addEventListener('click', () => {
    \\  call('print_page', { kind: 'system' });
    \\});
;
