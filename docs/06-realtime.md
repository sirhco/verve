# 06 — Realtime: SSE + WebSocket

Two endpoints, two transports, same underlying integer counter.

## `/events` — Server-Sent Events

A long-lived HTTP/1.1 chunked response with `Content-Type:
text/event-stream`. The framework's handler pushes the current
`last_count` once per second:

```
GET /events HTTP/1.1
Host: 127.0.0.1
Accept: text/event-stream
Connection: keep-alive
```

Response:

```
HTTP/1.1 200 OK
content-type: text/event-stream
cache-control: no-cache
x-accel-buffering: no

retry: 2000

event: count
data: 7

event: count
data: 8

event: count
data: 8
```

Browser API:

```js
const es = new EventSource("/events");
es.addEventListener("count", (e) => {
  console.log("count is now", e.data);
});
es.onerror = () => { /* auto-reconnects after `retry:` ms */ };
```

The bridge sets this up automatically and mirrors `event: count`
messages into `[z-bind="count"]` elements.

### Server-side details

```zig
// src/server/main.zig:streamEvents
fn streamEvents(io: std.Io, request: *std.http.Server.Request) !void {
    var stream_buf: [1024]u8 = undefined;
    var body_writer = try request.respondStreaming(&stream_buf, .{
        .respond_options = .{
            .status = .ok,
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/event-stream" },
                .{ .name = "cache-control", .value = "no-cache" },
                .{ .name = "x-accel-buffering", .value = "no" },
            },
        },
    });

    try body_writer.writer.writeAll("retry: 2000\n\n");
    try flushBodyWriter(&body_writer);

    while (true) {
        const count = app.last_count.load(.monotonic);
        body_writer.writer.print("event: count\ndata: {d}\n\n", .{count}) catch break;
        flushBodyWriter(&body_writer) catch break;
        std.Io.sleep(io, SSE_TICK, .awake) catch break;
    }
    body_writer.end() catch {};
}
```

Three things to notice:

1. **Streaming response** — `respondStreaming` gives a `BodyWriter`
   that chunk-encodes its output. We pass `keep_alive = false` so
   the connection closes cleanly when the client goes away.
2. **Double-flush** — `flushBodyWriter` does both `w.writer.flush()`
   (serializes the chunk into the protocol output) and `w.flush()`
   (pushes the protocol output to TCP). Without the second flush
   the chunk sits in the inner writer's buffer.
3. **Break on any write failure** — when the client disconnects the
   next write returns an error; we break the loop, body ends,
   defers run, the worker thread releases its admission slot.

### Pushing your own event types

The current handler is hardcoded to push `count`. To add a new event
type, edit `streamEvents` to also emit `event: notifications\ndata:
<json>\n\n` driven by your own atomic counter or queue. The bridge's
SSE handler already pattern-matches by event name:

```js
es.addEventListener("notifications", (e) => { /* ... */ });
```

## `/ws` — WebSocket

Same data, bidirectional. Used by the counter page when WS is
available — clients can send `+` and `-` text frames to mutate state.

### Handshake

Standard RFC 6455 GET upgrade:

```
GET /ws HTTP/1.1
Host: 127.0.0.1
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
Sec-WebSocket-Version: 13
```

Server response:

```
HTTP/1.1 101 Switching Protocols
upgrade: websocket
sec-websocket-accept: <sha1(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") | base64>
```

`std.http.Server.Request.respondWebSocket` does the
key-mixing and writes the accept header. We hand it the key parsed
from `upgradeRequested()`.

### Wire format

Frames are RFC 6455:

- Client → server: text frames `"+"` or `"-"`. Mask bit must be set
  (the protocol requires client-to-server frames be masked).
- Server → client: text frames `"<integer>"`. Mask bit cleared.

### Connection lifetime

One worker thread per WS connection (counts against the admission
cap). Inside:

- The **reader loop** consumes incoming frames via
  `ws.readSmallMessage()` and mutates `last_count`.
- A **broadcaster thread** polls `last_count` every 250 ms; when it
  changes, it writes the new value to the WS.
- Both halves use a `std.atomic.Mutex` to serialize writes (the
  reader writes an immediate ack; the broadcaster writes on tick).
- Reader-loop exit signals the broadcaster via an atomic shutdown
  flag; the broadcaster joins on next tick.

```zig
// src/server/main.zig:streamWebSocket
var ws = try request.respondWebSocket(.{ .key = key });
try ws.flush();

var write_mu: std.atomic.Mutex = .unlocked;
var shutdown: std.atomic.Value(bool) = .init(false);
writeCount(&ws, &write_mu);                       // initial state push

var ctx = WsBroadcastCtx{ .io = io, .ws = &ws, ... };
const broadcaster = try std.Thread.spawn(.{}, wsBroadcastLoop, .{&ctx});
defer { shutdown.store(true, .release); broadcaster.join(); }

while (true) {
    const msg = ws.readSmallMessage() catch break;
    if (msg.opcode != .text and msg.opcode != .binary) continue;
    if (std.mem.eql(u8, msg.data, "+")) { _ = app.last_count.fetchAdd(1, .monotonic); }
    else if (std.mem.eql(u8, msg.data, "-")) { _ = app.last_count.fetchSub(1, .monotonic); }
    writeCount(&ws, &write_mu);
}
```

### Bridge-side

```js
let ws = null;
const setCount = (raw) => { /* update [z-bind="count"] */ };

try {
  const proto = location.protocol === "https:" ? "wss:" : "ws:";
  ws = new WebSocket(`${proto}//${location.host}/ws`);
  ws.onmessage = (e) => setCount(e.data);
} catch { ws = null; }

const wsCounterAction = (action) => {
  if (!ws || ws.readyState !== WebSocket.OPEN) return false;
  if (action === "increment_counter") { ws.send("+"); return true; }
  if (action === "decrement_counter") { ws.send("-"); return true; }
  return false;
};
```

When `wsCounterAction` returns false (WS not open, or action isn't
one of the counter actions), the bridge falls through to wasm
exports — which fall through to native `<form>` submission via the
form fallback wrapper.

## Choosing between SSE and WS

| | SSE | WebSocket |
|---|---|---|
| Direction | server → client only | bidirectional |
| Transport | HTTP/1.1 chunked | TCP after upgrade |
| Reconnect | built-in via `retry:` | manual |
| Proxies | usually friendly | upgrade can be blocked |
| Browser support | excellent | excellent |
| Implementation cost (client) | a few lines of `addEventListener` | needs frame handling on send |
| Worker-slot cost (server) | one per subscriber | one per connection |

Use SSE for broadcast-style "something changed, re-render" patterns
(see the chat and poll examples). Reach for WebSocket when the client
needs to send back something more than an HTTP POST cycle every few
hundred ms.

## Both at once

The framework wires both endpoints unconditionally. A page that needs
neither just doesn't subscribe. A page that needs both (the counter
demo) prefers WS and falls back to SSE — the bridge guarantees only
one path drives `setCount` at a time so updates aren't doubled.

## Testing

The repo's integration tests cover both:

- `/events emits initial count and live updates via SSE` — opens a
  raw TCP connection, sends a GET, reads bytes until a `data: 7`
  frame appears (after seeding `last_count = 7` via
  `updateDatabase`).
- `/ws upgrades, accepts +/- frames, broadcasts count` — hand-crafts
  the Upgrade request, validates the 101 response, sends a masked
  `+` frame, reads the echoed value.

Both tests live in `tests/integration.zig`.

## Next

- [07 — Static assets](07-static-assets.md) — runtime / comptime
  `/public/*` serving.
- [12 — WASM client](12-wasm-client.md) — the wasm side of the WS
  handshake.
