# viz-live — live graph streaming over SSE push

The smallest complete app that streams **server-pushed wire deltas** into an
interactive `verve.viz` graph. One route, one island, one server function —
plus the framework's `/push` broadcast hub doing the realtime work.

```sh
zig build run        # http://127.0.0.1:8080
```

Click **● live**. The server starts mutating its graph once per second and
broadcasts the diff; the nodes appear and disappear on screen while zoom,
pan, selection, and subtree collapse all survive every tick.

## What it demonstrates

- **The `/push` hub** (`src/server/push.zig`) — declaring
  `pub fn vizAdvanceTick(buf: []u8) ?[]const u8` in `src/app/api.zig` opts
  this app into the framework server's publisher thread: once per second
  (and only while someone is subscribed) it advances the model and publishes
  the frame to the `viz` channel.
- **Wire deltas, not snapshots** — the server diffs old vs new with
  `verve.viz.diffGraphs` and serializes `{"seq":N,"ops":[...]}` via
  `verve.viz.writeDeltaJson`. Watch them live while ● live is on:

  ```sh
  curl -N 'http://127.0.0.1:8080/push?channel=viz'
  ```

  ```text
  id: 1
  event: viz
  data: {"seq":1,"ops":[{"op":"+n","id":"e0","label":"e0"},{"op":"+e","from":"core","to":"e0"}]}
  ```

- **Seq-ordered apply + resync** — the island
  (`../../src/client/islands/VizGraphInteractive.zig`, reused verbatim)
  subscribes its `viz_apply_delta` export via `pushSubscribe`, applies a
  delta only when `seq == last_seen + 1`, and on any gap pulls a fresh
  seq-stamped snapshot from `/api/vizGraph` via `fetchToExport`. Kill and
  restart the server while live — EventSource reconnects (`Last-Event-ID`
  replays from the hub's 32-frame ring) and the graph recovers.
- **SSR-first** — the page renders the full graph with JS off; the SSR tree
  and the hydration props share one `graphPositions` call so the island's
  model lands exactly on the server-rendered pixels.
- **The rest of the interactive island**, since it comes along for free:
  pointer-captured pan/drag, hover tooltips, click select, double-click
  subtree collapse (`+N` badge), ⟳ layout cycling with tweens (the chunk
  recomputes tree/radial/dag layouts via the `viz_core` module), and local
  +/− node mutation through the keyed reconciler.

## Layout

```
build.zig                  mirrors the framework build; adds the viz_core
                           chunk module + framework-chunk source fallback
src/app/api.zig            evolving graph model, vizAdvanceTick (publisher
                           opt-in), Actions.vizGraph (seq-stamped snapshot)
src/app/islands.zig        VizGraphInteractive registry entry (typed Props)
src/app/components.zig     SSR page: island + controls + CSS
src/app/routes.zig         "/"
```

No chunk source of its own: `build.zig` resolves the island chunk
example-local → framework (`../../src/client/islands/VizGraphInteractive.zig`,
used here) → `_default` stub.

## Guides

- [22 — Visualization](../../docs/22-visualization.md) — the full `verve.viz`
  reference, including the wire-delta grammar and the collapse semantics.
- [06 — Realtime](../../docs/06-realtime.md) — the `/push` channel hub.
- [20 — Client runtime](../../docs/20-client-runtime.md) — `pushSubscribe` /
  `fetchToExport` / named-export dispatch.
