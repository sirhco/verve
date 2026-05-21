//! Demonstrates:
//!   - WebSocket + SSE on the SAME page
//!   - verve.NodeRef (typed handle to a DOM node)
//!   - ctx.scriptInline (CSP-nonced inline script that drives the connections)
//!   - z-bind hook for the SSE counter

const std = @import("std");
const verve = @import("verve");
const ui = @import("../ui.zig");

pub fn realtimePage(ctx: *verve.Context) !*verve.Node {
    const presence_ref = ctx.nodeRef(.div, "presence-list");
    const activity_ref = ctx.nodeRef(.div, "activity-tick");

    return ctx.div().children(.{
        ctx.div().class("alert info").children(.{
            ctx.strong("WS + SSE on the same page"),
            ctx.div().text("The presence pane below talks to /ws (echo for any text frame except + / -). The activity counter listens to /events and bumps on every server-side change. Both transports are wired by ONE inline script — and the script carries the CSP nonce auto-stamped by the renderer."),
        }),
        ctx.div().class("grid grid-2").children(.{
            ctx.section().class("card").children(.{
                ctx.h3("Presence (WebSocket)"),
                ctx.p().class("muted").text("Open this page in two tabs; messages relay through /ws."),
                ctx.input().class("input").id("ws-input").type_("text").placeholder("Type and Enter to broadcast…"),
                ctx.div().class("card").ref(presence_ref).children(.{
                    ctx.p().class("muted").text("(messages appear here)"),
                }),
            }),
            ctx.section().class("card").children(.{
                ctx.h3("Activity tick (SSE)"),
                ctx.p().class("muted").text("Server-Sent Events — the /events stream pings every second with the current counter."),
                ctx.div().class("kpi").children(.{
                    ctx.span().class("kpi-label").text("last_count"),
                    ctx.span().class("kpi-value").ref(activity_ref).bind("count").text("0"),
                }),
            }),
        }),
        // CSP-nonced inline script wires up both transports. The
        // renderer auto-stamps `nonce="…"` on the <script> tag so
        // it loads under `script-src 'nonce-…' 'strict-dynamic'`.
        ctx.scriptInline(
            \\const presence = document.querySelector('[data-ref="presence-list"]');
            \\const input = document.getElementById('ws-input');
            \\const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
            \\const ws = new WebSocket(`${proto}//${location.host}/ws`);
            \\const append = (txt) => {
            \\  const row = document.createElement('div');
            \\  row.textContent = txt;
            \\  presence.appendChild(row);
            \\  if (presence.childElementCount > 12) presence.removeChild(presence.firstChild);
            \\};
            \\ws.onmessage = (e) => append(`◀ ${e.data}`);
            \\ws.onopen = () => append('· connected ·');
            \\input.addEventListener('keydown', (e) => {
            \\  if (e.key !== 'Enter') return;
            \\  const v = input.value.trim();
            \\  if (!v) return;
            \\  ws.send(v); append(`▶ ${v}`); input.value = '';
            \\});
            \\const es = new EventSource('/events');
            \\es.addEventListener('count', (e) => {
            \\  const el = document.querySelector('[data-ref="activity-tick"]');
            \\  if (el) el.textContent = e.data;
            \\});
        ),
    }).build();
}
