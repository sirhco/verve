# 05 — Reactivity

Verve splits state across three layers:

1. **Server signals** (`src/core/signal.zig`) — observable values inside
   a render pass. Available to both server and wasm builds.
2. **Client signals** (`src/client/signal.zig`) — wasm-side values
   whose `set()` calls a JS extern to update the DOM.
3. **Bridge subscriptions** — the JS bridge auto-wires `[z-bind="X"]`
   elements to `verve_init_X` exports and to SSE / WebSocket events
   named `X`.

## Server signal

```zig
const verve = @import("verve");

var count: verve.Signal(i32) = .init(0);

count.set(5);                       // mutate
const v = count.get();              // read
try count.subscribe(observer);      // notify on set
```

Today the request path doesn't use server signals — they're useful for
in-process listeners (tests, background tasks). The "live update over
SSE" pattern uses `std.atomic.Value(i32)` directly because the broadcast
loop polls without needing a listener registration.

## Client signal

A `ClientSignal(T)` is small — bind name + value:

```zig
const signal = @import("signal.zig");

var count = signal.ClientSignal(i32).init("count", 0);

count.set(7);            // updates DOM via dom.set_text_by_bind_i32
count.increment();       // count += 1, emit update
count.decrement();
const cur = count.get();
```

`set` calls `dom.set_text_by_bind_i32(bind_ptr, bind_len, value)` which
the JS bridge maps to `setTextByBind(name, String(value))` — written
into the `textContent` of every `[z-bind="<name>"]` element on the
page.

Only `i32` is wired today. Adding `[]const u8` is a few lines in
`src/client/signal.zig:emit` plus an extra extern in
`src/client/dom.zig`. Use the wasm FBA from
[`12-wasm-client.md`](12-wasm-client.md) to own the string buffer.

## Hydration

When the bridge boots, it scans wasm exports for every name matching
`verve_init_*` and seeds the client signal from the rendered DOM:

```js
// src/bridge/verve.js
for (const name of Object.keys(exp)) {
  const m = /^verve_init_(.+)$/.exec(name);
  if (!m || typeof exp[name] !== "function") continue;
  const el = document.querySelector(`[z-bind="${CSS.escape(m[1])}"]`);
  if (!el) continue;
  const n = parseInt(el.textContent, 10);
  if (!Number.isNaN(n)) exp[name](n | 0);
}
if (typeof exp.verve_hydrate === "function") exp.verve_hydrate();
```

So:

- Server renders `<span z-bind="count">7</span>`.
- Bridge sees `verve_init_count` export, parses `7` from the DOM,
  calls `verve_init_count(7)` which sets the wasm signal.
- `verve_hydrate()` runs to re-emit current state (in case multiple
  elements share a bind).

Now the wasm world and the DOM agree, and subsequent
`count.set(N)` calls flow to the DOM via the extern.

## Click → action

`<button z-on-click="increment_counter">` is intercepted by the
bridge's delegated click listener:

```js
document.addEventListener("click", (e) => {
  const target = e.target.closest("[z-on-click]");
  if (!target) return;
  const action = target.getAttribute("z-on-click");
  if (wsCounterAction(action)) {          // WS fast-path for "+"/"-"
    e.preventDefault();
    return;
  }
  const fn = exp[action];                 // fallback: wasm export
  if (typeof fn === "function") {
    e.preventDefault();
    fn();
  }
});
```

So the lookup order is:

1. WebSocket fast-path (for `increment_counter` / `decrement_counter`).
2. Direct wasm export by name.

A button wrapped in a `<form action="/api/...">` falls through to
native submit when neither path is available — the form-fallback
pattern (see [`03-actions.md`](03-actions.md)).

## Multi-bind

Multiple elements with the same `z-bind` all update together:

```html
<span z-bind="count" class="count">0</span>
<small z-bind="count" class="muted">Current value: 0</small>
```

`set_text_by_bind` uses `document.querySelectorAll`, so both nodes
receive every update.

You can also have multiple `ClientSignal`s on the same page with
different bind names:

```zig
var count = signal.ClientSignal(i32).init("count", 0);
var clicks = signal.ClientSignal(i32).init("clicks", 0);
```

That's why the counter demo tracks "count" (server-shared) and
"clicks" (per-tab) independently — two binds, one wasm module.

## SSE-driven binds (no wasm required)

The bridge also listens to `/events` named events:

```js
const es = new EventSource("/events");
es.addEventListener("count", (e) => {
  if (!ws || ws.readyState !== WebSocket.OPEN) setCount(e.data);
});
```

So even without invoking any wasm export, the page can have its
`[z-bind="count"]` elements updated when the server pushes
`event: count\ndata: <n>\n\n`.

This is how a tab open to `/counter` with JS but no `wasm`
interactions still sees live updates from other browsers.

## WebSocket priority

The bridge tries WebSocket first; on failure it falls back to SSE:

```js
try {
  const proto = location.protocol === "https:" ? "wss:" : "ws:";
  ws = new WebSocket(`${proto}//${location.host}/ws`);
  ws.onmessage = (e) => setCount(e.data);
} catch (err) {
  ws = null;
}
```

When the WS is open, the SSE listener becomes a no-op for the
`count` event — preventing double-updates. Same UI, two transports,
graceful degradation.

## Putting it together

The `/counter` page sends three signals on the wire:

1. Server renders `<span z-bind="count">N</span>` (SSR).
2. Bridge boots, calls `verve_init_count(N)` (hydrate).
3. User clicks `[z-on-click="increment_counter"]`. Bridge sees
   counter action, sends `"+"` over WS.
4. Server's WS reader bumps `last_count.fetchAdd(1)`, then
   `writeCount` broadcasts the new value to every connected client.
5. Each client's bridge receives the WS message → `setCount(data)`
   → `setTextByBind("count", String(v))` → DOM updates.

The whole chain is observable in the browser's devtools network +
console.

## Next

- [06 — Realtime](06-realtime.md) — protocol details for SSE and WS.
- [12 — WASM client](12-wasm-client.md) — how the wasm-side allocator,
  signals, and HTML escape interact.
