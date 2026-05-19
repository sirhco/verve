# Verve examples

Three self-contained sample apps. Each is a regular Zig project — a
`build.zig`, a `build.zig.zon`, and a `src/app/` tree with the
`Actions` / `routes` / `components` triple the framework expects.

The framework itself is referenced via `../../src/...`, so you can edit
both sides in the same checkout and see changes immediately. To make an
example fully standalone (for export to a different repo), either copy
the framework source tree in next to it or run `verve-cli new` to
generate a scaffolded variant.

## At a glance

### Server-driven examples

| Example | Pattern showcased | Live? | No-JS fallback? |
|---|---|---|---|
| [`chat/`](chat/README.md)           | Form actions + SSE-driven reload     | Yes via SSE      | Yes |
| [`poll/`](poll/README.md)           | Atomic counter array + SSE reload    | Yes via SSE      | Yes |
| [`bookmarks/`](bookmarks/README.md) | Multi-route + validation + app stats | No (static pages)| Yes |

### Wasm-driven examples

| Example | Pattern showcased | Wasm size |
|---|---|---|
| [`stopwatch/`](stopwatch/README.md)   | JS-driven tick into wasm, FBA-formatted display, z-on-click → exports | ~3 KB |
| [`calculator/`](calculator/README.md) | Many small exports, f64 math, keyboard ↔ click parity                | ~7 KB |
| [`keystrokes/`](keystrokes/README.md) | JS → wasm string passing via shared memory                            | ~440 B |

The three wasm examples each ship their own `src/client/main.zig` and
`src/bridge/verve.js`, overriding the framework defaults. The framework's
server, core types, and `/health` + `/metrics` + `/events` + `/ws`
endpoints come along for free.

For a WebSocket demo, see the counter at the root of the repository:
`./zig-out/bin/verve-server` from the repo root, then visit
http://127.0.0.1:8080/counter.

## Build any example

```sh
cd examples/<name>
zig build
./zig-out/bin/<name>-server          # default port 8080
./zig-out/bin/<name>-server --help   # full CLI surface (inherited from the framework)
```

All examples share the framework's CLI flags: `--host`, `--port`,
`--body-limit`, `--public-dir`, `--workers`. They also automatically get
`/health`, `/metrics`, `/events`, `/ws` from the framework — even if the
example app doesn't use them.

## Layout

```
examples/
├── README.md            ← this file
├── chat/
│   ├── build.zig
│   ├── build.zig.zon
│   ├── README.md
│   └── src/app/{api,components,routes}.zig
├── poll/
│   └── ... same shape ...
└── bookmarks/
    └── ... same shape ...
```

Every `src/app/api.zig` must export:

- `pub const components` — namespace with at least `page`, `notFound`, `errorPage`.
- `pub const routes` — slice of `Route` (path + render fn).
- `pub const Actions` — struct of `pub fn name(args: struct {...}) Ret`.
- `pub var last_count: std.atomic.Value(i32)` — the tick the framework's
  `/events` and `/ws` broadcast. Apps that don't care can leave it at
  `.init(0)` and ignore it; apps that want SSE-driven UI refresh bump it
  on every state change.
