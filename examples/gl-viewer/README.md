# gl-viewer — standalone declarative 3D product viewer

The smallest complete app built on **`verve.gl`**: a PBR + image-based-lit mesh
declared in Zig and rendered in WebGL2, with orbit, pick, hover, and a
scroll-scrub turntable — no scene graph JSON, no JS render loop, no Chromium.

Two SSR routes share one scene declaration; only the interaction mode differs.

```sh
cd examples/gl-viewer
zig build run        # http://127.0.0.1:8080  (override with -- --port 9090)
```

- **`/`** — scroll-scrub product viewer. `scrub(true)` makes the builder own a
  300vh scroll section + sticky viewport; scroll drives a full-rotation
  turntable timeline (P5). Drag still orbits, wheel still zooms, clicks still
  pick.
- **`/orbit`** — plain interactive orbit/pick. `scrub(false)` + `autoRotate(0.2)`:
  the model spins gently until you grab it.

## What it demonstrates

The entire viewer is one fluent builder call (`src/app/components.zig`):

```zig
ctx.glScene(.{ .src = "/gl/demo.vmesh", .env = "/gl/studio.venv", .poster = <inline svg> })
    .camera(.{ .distance = 4, .pitch = 0.3, .yaw = 0.6 })
    .light(.{ .dir = .{ -0.4, -0.7, -0.6 }, .intensity = 3.0 })
    .onPick("Cube", 0)
    .scrub(true)        // or .autoRotate(0.2).scrub(false) on /orbit
    .build();
```

- **PBR + IBL** — the mesh is lit by a prefiltered studio environment
  (`studio.venv`); a directional light adds the key. Both assets are generated
  at build time and embedded in the server binary.
- **Orbit drag / wheel zoom** — pointer-captured drag spins the camera; the
  wheel dollies in and out with clamped distance.
- **Click pick → `data-gl-pick`** — clicking a named submesh stamps the canvas
  with `data-gl-pick`; `onPick(name, id)` can also fire an SSR-registered
  closure (id 0 here = name-only).
- **Hover** — the same ray path, throttled to one raycast per frame while not
  dragging, stamps `data-gl-hover`.
- **Scroll-scrub turntable (P5)** — `scrub(true)`: scroll position maps to model
  yaw across the 300vh section the island renders.
- **Poster swap** — an inline SVG `<img data-gl-poster>` shows until the chunk
  paints its first frame, then it is hidden.
- **Context-restore** — the GlScene chunk replays its GPU resources from a
  Registry after a WebGL context loss, so the scene survives a GPU reset.

## One stateful chunk per page

Per-island wasm chunks share the main client's linear memory and each links its
static data at the same base, so **at most one stateful gl chunk may live on a
page** (the framework `build.zig` invariant). Each route here hosts exactly one
`GlScene` — never co-located with another stateful gl island.

## Layout

```
build.zig                  mirrors the framework build; adds the gl_core chunk
                           module + the gl asset pipeline + framework-chunk fallback
build.zig.zon              package manifest
src/app/api.zig            re-exports routes/components/islands; empty Actions
src/app/islands.zig        GlScene registry entry (typed Props mirror)
src/app/components.zig     the two SSR pages + document shell
src/app/routes.zig         "/" and "/orbit"
```

This example ships **no chunk source and no gl tools of its own**. The build
resolves the island chunk example-local → framework
(`../../src/client/islands/GlScene.zig`, used here verbatim) → `_default`, and
runs the framework's `gen_demo_glb` / `gen_demo_hdr` / `gl_asset_gen` tools and
`src/core/gl/gl.zig` directly by relative path.

## Guides

- [24 — verve.gl](../../docs/24-gl.md) — the full 3D engine reference: the
  declarative scene API, the `.vmesh` / `.venv` asset pipeline, the command
  stream, and context-restore.
