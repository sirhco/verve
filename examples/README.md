# Verve examples

Twelve self-contained sample apps. Each is a regular Zig project — a
`build.zig`, a `build.zig.zon`, and a `src/app/` tree with the
`Actions` / `routes` / `components` triple the framework expects.

The framework itself is referenced via `../../src/...`, so you can edit
both sides in the same checkout and see changes immediately. To make an
example fully standalone (for export to a different repo), either copy
the framework source tree in next to it or run `verve-cli new` to
generate a scaffolded variant.

## At a glance

### Comprehensive tour

| Example | Pattern showcased |
|---|---|
| [`showcase/`](showcase/README.md) | **Every Phase 0-10 surface** — nested routes, signals/effects/stores, Resource + Suspense, ErrorBoundary, ActionForm + CSRF, SPA Link, head slots, i18n, NodeRef, islands marker, path params, wildcards, fragment + `contentType`, ProtectedRoute, dev auto-reload. Pair with `zig build --watch run -- --dev`. |

### Server-driven examples

| Example | Pattern showcased | Live? | No-JS fallback? |
|---|---|---|---|
| [`chat/`](chat/README.md)           | Form actions + SSE-driven reload     | Yes via SSE      | Yes |
| [`poll/`](poll/README.md)           | Atomic counter array + SSE reload    | Yes via SSE      | Yes |
| [`bookmarks/`](bookmarks/README.md) | Multi-route + validation + app stats | No (static pages)| Yes |
| [`dashboard/`](dashboard/README.md) | Multi-page admin layout              | Background fetcher | Yes |
| [`markdown/`](markdown/README.md)   | `ctx.markdown` GFM + syntax highlighting (pure-Zig, replaces marked + highlight.js) | No (static page) | Yes |

### Wasm-driven examples

| Example | Pattern showcased | Wasm size |
|---|---|---|
| [`stopwatch/`](stopwatch/README.md)   | JS-driven tick into wasm, FBA-formatted display, z-on-click → exports | ~3 KB |
| [`calculator/`](calculator/README.md) | Many small exports, f64 math, keyboard ↔ click parity                | ~7 KB |
| [`keystrokes/`](keystrokes/README.md) | JS → wasm string passing via shared memory                            | ~440 B |
| [`client-runtime/`](client-runtime/README.md) | All v0.1.30 primitives in one island — typed IPC, events-with-data, timers/storage/clipboard, forms/measurement, JS interop, chunk arena + drag-drop | ~3.6 KB |
| [`islands-demo/`](islands-demo/README.md) | Island stack end-to-end — `encodeProps`/`decodeProps` typed props, `ctx.islandState`/`islandStateValue` resource-state, per-island lifecycle, chunk-side click handler, **two** independent Counter islands (shared component, independent state via per-vid namespacing) | ~3 KB |
| [`viz-live/`](viz-live/README.md) | Live `verve.viz` graph over **SSE push** — `/push?channel=viz` broadcast hub, seq-ordered wire deltas (`diffGraphs`/`writeDeltaJson`), snapshot resync on gaps, plus the full interactive island (pointer-captured drag, dblclick collapse, layout-cycle tweens) reused from the framework | ~107 KB |

The wasm-driven examples each ship their own `src/client/main.zig`
overriding the framework's default client. The framework's server,
core types, and `/health` + `/metrics` + `/events` + `/ws` endpoints
come along for free.

For a WebSocket demo, see the counter at the root of the repository:
`./zig-out/bin/verve-server` from the repo root, then visit
<http://127.0.0.1:8080/counter>.

## Build any example

```sh
cd examples/<name>
zig build
./zig-out/bin/<name>-server          # default port 8080
./zig-out/bin/<name>-server --help   # full CLI surface (inherited from the framework)
```

All examples share the framework's CLI flags: `--host`, `--port`,
`--body-limit`, `--public-dir`, `--workers`, `--csrf=enforce|disable`,
`--dev`. They also automatically get `/health`, `/metrics`, `/events`,
`/ws` from the framework — even if the example app doesn't use them.

## Dev mode

Every example supports `--dev` auto-reload:

```sh
cd examples/showcase
zig build --watch run -- --dev
```

`zig build --watch` rebuilds + restarts the server on `.zig` changes;
the browser refreshes within ~500 ms via the injected dev-WS client.

## Layout

```
examples/
├── README.md            ← this file
├── showcase/            ← full Phase 0-10 tour (start here)
├── chat/
│   ├── build.zig
│   ├── build.zig.zon
│   ├── README.md
│   └── src/app/{api,components,routes}.zig
├── poll/
│   └── ... same shape ...
└── bookmarks/, dashboard/, markdown/, stopwatch/, calculator/, keystrokes/, client-runtime/, islands-demo/
```

Every `src/app/api.zig` must export:

- `pub const components` — namespace with at least `page`, `notFound`, `errorPage`.
- `pub const routes` — `[]const verve.Route` built via `verve.Route.init` (leaf) / `verve.Route.layout` (with nested children).
- `pub const Actions` — struct of `pub fn name(args: struct {...}) Ret`. Form posts to `/api/<name>` are CSRF-protected by default.
- `pub var last_count: std.atomic.Value(i32)` — the tick the framework's
  `/events` and `/ws` broadcast. Apps that don't care can leave it at
  `.init(0)` and ignore it; apps that want SSE-driven UI refresh bump it
  on every state change.
