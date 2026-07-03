# viz-live — live graph streaming over SSE push

A `verve.viz` graph demo covering three rendering modes: interactive SVG with
live SSE deltas, multi-instance SVG with multi-parent-aware collapse and
orthogonal edge routing, and a canvas2d render path with live binary streaming.

```sh
zig build run        # http://127.0.0.1:8080
```

## Routes

- **`/`** — interactive SVG graph. Click **● live** to start the server's
  once-per-second mutation cycle; wire deltas arrive over SSE and the graph
  updates in place while zoom, pan, selection, and subtree collapse all survive
  every tick. The initial graph (small dependency topology) is SSR-rendered so
  it appears before any wasm loads.
- **`/multi`** — two independent `VizGraphInteractive` islands on one page.
  Graph 1 uses a multi-parent topology (both `server` and `viz` feed into
  `client`): double-click `server` to collapse its subtree — `client` stays
  visible because the `viz` parent remains open. Graph 2 uses
  `edge_routing = .orthogonal`, routing edges as Manhattan runs with rounded
  corners instead of straight lines.
- **`/canvas`** — canvas2d render path (`VizGraphCanvas` island). On load it
  fetches the server-authored graph from `/viz/graph.bin` (1 500 nodes,
  2 949 edges), lays it out, and paints it to a `<canvas>`. Click **● live**
  to stream live binary frames from `/viz/live-graph.bin` (a 256-node live
  model); the canvas repaints each frame.

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
- **SSR-first** — the `/` page renders the full graph with JS off; the SSR
  tree and the hydration props share one `graphPositions` call so the island's
  model lands exactly on the server-rendered pixels.
- **Multi-parent-aware collapse** (`/multi`) — the `VizGraphInteractive` chunk
  tracks parent counts; collapsing a node hides its children only when all
  parents are collapsed.
- **Orthogonal edge routing** (`/multi`) — `edge_routing = .orthogonal`
  switches the layout engine to route edges as axis-aligned segments.
- **Canvas2d render path** (`/canvas`) — `VizGraphCanvas` fetches a binary
  graph blob, lays it out server-side, and paints to `<canvas>` rather than
  SVG; live frames stream as binary over the vizcanvas publisher.
- **The rest of the interactive island**, since it comes along for free on `/`:
  pointer-captured pan/drag, hover tooltips, click select, double-click
  subtree collapse (`+N` badge), ⟳ layout cycling with tweens (the chunk
  recomputes tree/radial/dag layouts via the `viz_core` module), and local
  +/− node mutation through the keyed reconciler.

## Layout

```
build.zig                  mirrors the framework build; adds the viz_core
                           chunk module + framework-chunk source fallback
src/app/api.zig            evolving graph model, vizAdvanceTick (publisher
                           opt-in), vizCanvasAdvanceTick + packLiveGraph
                           (vizcanvas publisher), Actions.vizGraph (snapshot)
src/app/islands.zig        VizGraphInteractive + VizGraphCanvas registry entries
src/app/components.zig     SSR pages: index, vizMulti, vizCanvas
src/app/routes.zig         "/", "/multi", "/canvas"
src/app/viz_live.zig       live graph model for the canvas binary stream
```

No chunk source of its own: `build.zig` resolves the island chunks
example-local → framework → `_default` stub.

## Guides

- [22 — Visualization](../../docs/22-visualization.md) — the full `verve.viz`
  reference, including the wire-delta grammar and the collapse semantics.
- [06 — Realtime](../../docs/06-realtime.md) — the `/push` channel hub.
- [20 — Client runtime](../../docs/20-client-runtime.md) — `pushSubscribe` /
  `fetchToExport` / named-export dispatch.
