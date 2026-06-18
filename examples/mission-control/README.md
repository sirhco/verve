# mission-control — wind farm operations dashboard

Flagship full-stack Verve example: a wind farm operations centre that combines
3D rendering, animation, live telemetry, and presence — all from a single Zig
binary, zero third-party deps, no JS framework.

```sh
cd examples/mission-control
zig build run           # web server → http://127.0.0.1:8080
zig build -Ddesktop run-desktop  # native OS window (WKWebView / WebView2 / WebKitGTK)
```

## What it demonstrates

| Feature | How |
|---------|-----|
| **verve.gl** — 3D WebGL2 scene | Wind farm with 4 turbines; orbit camera, continuous rotor spin, per-turbine pick. Mesh generated at build time (`gen_windfarm_glb` → `gl_asset_gen` → `windfarm.vmesh`). |
| **verve.anim** — camera tweens + count-up | Declarative `ctx.animTimeline` on the hero; count-up animations on stat tiles drive by SSE data. |
| **verve.viz** — live rolling chart | Dashboard SVG area chart for turbine power history; patched live by the `Dashboard` island via `setRefAttr`. |
| **SSE push** | Metrics sim (`app/api.zig:metricsAdvanceTick`) ticks at ~2 Hz and broadcasts JSON to `/push?channel=metrics`; the Dashboard island subscribes and updates without page reload. |
| **WebSocket presence** | Presence widget connects to `/push-ws?channel=presence`; the server's presence publisher loop counts active subscribers and broadcasts `{"count":N}` on change. |
| **Per-island WASM chunks** | `FarmScene`, `Dashboard`, and `Presence` each compile to their own `.wasm` chunk that shares the main client's linear memory. |
| **Desktop build** | `-Ddesktop` wraps the same HTTP server in a native OS window via `src/desktop_main.zig`. No custom URL scheme needed — the webview talks HTTP to localhost. |

## Routes

| Path | Description |
|------|-------------|
| `/` | Single page: 3D farm scene + dashboard chart + presence widget |

### Endpoints (served by the embedded HTTP server)

| Endpoint | Purpose |
|----------|---------|
| `/push?channel=metrics` | SSE stream — JSON frames at ~2 Hz from the metrics sim |
| `/push-ws?channel=presence` | WebSocket — presence subscriber count broadcast |
| `/gl/windfarm.vmesh` | Binary mesh asset (generated at build time) |
| `/islands/FarmScene.wasm` | Island chunk — 3D wind farm scene |
| `/islands/Dashboard.wasm` | Island chunk — live telemetry chart |
| `/islands/Presence.wasm` | Island chunk — live-viewers counter |
| `/client.wasm` | Main wasm client runtime |
| `/verve.js` | JS bridge |
| `/health` | Health probe |
| `/metrics` | Prometheus-style request metrics |

## Running

### Web server (default)

```sh
cd examples/mission-control
zig build run
# → http://127.0.0.1:8080/
# Override port: zig build run -- --port 9090
```

### Desktop (native OS window)

```sh
cd examples/mission-control
zig build -Ddesktop run-desktop
# Opens a WKWebView (macOS) / WebView2 (Windows) / WebKitGTK (Linux)
# window pointing at http://127.0.0.1:8080/
# The HTTP server runs in an embedded background thread.
# Override port: zig build -Ddesktop run-desktop -- --port 9090
```

To compile the desktop binary without running it:

```sh
zig build -Ddesktop
# → zig-out/bin/mission-control-desktop
```

**Note:** The native window requires a display and WKWebView / WebView2 /
WebKitGTK to be present on the system. Pure-Zig compilation succeeds on all
platforms; the window itself is only launchable on the target OS with its
webview runtime installed.

## Layout

```
build.zig                 build graph: wasm client, island chunks, gl asset
                          pipeline, server binary, desktop binary (-Ddesktop)
build.zig.zon             package manifest
src/
  app/
    api.zig               app module: routes, islands, metrics sim, presence opt-in
    components.zig        SSR page: farm scene + dashboard chart + presence widget
    islands.zig           island registry: FarmScene, Dashboard, Presence
    routes.zig            route table: one route → "/"
    sim.zig               wind farm metrics simulation (turbine state + noise)
  client/
    islands/
      FarmScene.zig       3D wind farm chunk (local override)
  desktop_main.zig        desktop entry point: starts HTTP server + opens OS window
```

## Guides

- [24 — verve.gl](../../docs/24-gl.md) — 3D engine: scene API, vmesh/venv pipeline, command stream
- [23 — verve.anim](../../docs/23-anim.md) — animation engine: timelines, ScrollTrigger, SplitText
- [22 — verve.viz](../../docs/22-viz.md) — visualization: graphs, charts, live SSE push
- [19 — Desktop apps](../../docs/19-desktop.md) — native window backends
