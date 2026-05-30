# client-runtime

A runnable demo of every **wasm client-runtime primitive** from
[`docs/20-client-runtime.md`](../../docs/20-client-runtime.md) (v0.1.30). One
page mounts a single island — `JsonProbe` — whose chunk exercises all six
phases. The build compiles a real per-island WASM chunk (shared memory +
indirect function table) from `src/client/islands/JsonProbe.zig`.

```sh
zig build run
# open http://127.0.0.1:8080
```

Every control writes to the **status line** at the top of the card, so you can
*watch* each primitive fire — no need to dig through the console. Refresh also
bumps the **server count**.

## How to validate it's working

1. **On load** — the network tab shows `GET /islands/JsonProbe.wasm` (the
   island chunk fetched and hydrated). If hydration failed you'd see nothing
   change below.
2. **Click "Refresh (typed IPC)"** — the status line shows `POST
   /api/json_probe …` then `typed reply ok`, the **count increments**, and the
   network tab shows the `POST /api/json_probe` round trip.
3. **Click the other buttons** — each updates the status line (caps → storage +
   clipboard message; form → the collected form JSON; host → the interop note).
4. **Focus the input, press ⌘K / Ctrl+K** — status updates and a Refresh fires.
5. **Drag a file onto the drop zone** — the status line shows its name.

If clicking does nothing, hydration didn't run — check the console for a chunk
fetch error.

## What each control demonstrates

| Control | Phase | Primitive |
|---|---|---|
| **Refresh (typed IPC)** | 17 | `serverFnPost("json_probe", "{}")` → `/api/json_probe`; reply read via `parseJson`/`JsonDoc` accessors **and** `readStruct(Reply, …)`; server `count` pushed into the `[z-bind=json_probe_count]` span. |
| **Input + ⌘K / Ctrl+K** | 18 | A registered keydown closure reads `eventMods()` + `eventKey()`, calls `eventPreventDefault()`, then refires the request. |
| **Run caps** | 19 | `setTimeout`, `storage.{set,get}`, `clipboardWrite`. |
| **Inspect form + DOM** | 20 | `formCollect(bind, buf)` → JSON (shown in the status line), plus `viewport()` / `matchMedia()`. |
| **Call JS host** | 21 | `host("fmtDate", …)` (sync) + `hostAsync("renderMd", …, route)` (async). Register `window.verveHost.fmtDate` / `renderMd` in the console to see real results. |
| **Drop zone** | 22 | `registerDrop("json_probe_drop", …)` + `currentDrop(buf)` read the dropped file's bytes from the chunk arena. |

## How the wiring works (the important bit)

Island-chunk handlers are **not** reachable by `z-on-click="name"` string
actions — the bridge's string-action delegate only looks up exports on the
*main* `client.wasm`. Chunk handlers must go through the closure path:
`hydrate` calls `registerEvent(&fn)` (returning a slot id), and the SSR stamps
`z-on-click-id="<id>"`; the click delegate then calls
`verve_event_dispatch(id)`, which dispatches into the chunk over the **shared
indirect function table**. The ids in `components.zig` (0-4) match the
`registerEvent` order in `JsonProbe.zig`.

The typed-IPC reply is enveloped as `{"value": …}` by the server-fn dispatcher;
the island unwraps it in `onReply`.

> CLI `curl` POSTs hit CSRF enforcement — the in-browser island sends the
> double-submit token via the bridge automatically. Use `--csrf=disable` to
> `curl /api/json_probe` directly.

## Files

- `src/client/islands/JsonProbe.zig` — the island chunk (all six phases).
- `src/app/components.zig` — the SSR subtree carrying the binds / refs /
  handler hooks the chunk wires up on hydrate.
- `src/app/api.zig` — the `json_probe` server function (typed-IPC endpoint).
- `src/app/islands.zig` — declares `JsonProbe` so the build emits its chunk.
- `build.zig` — mirrors the framework's island pipeline (manifest codegen +
  per-island chunk with shared memory + table).

See [`docs/20-client-runtime.md`](../../docs/20-client-runtime.md) for the full
API reference.
