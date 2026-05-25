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
                ctx.h2("Deep link"),
                ctx.p().text("Open verve://app/anything from a terminal (or click a link on a registered scheme) — the URL appears here."),
                ctx.pre().id("deep-link-url").text("(no URL received yet)"),
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
;
