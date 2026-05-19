# Verve documentation

Topic-by-topic guides. Read in order if you're new; jump around if
you know what you need.

## Reading order for a newcomer

1. [Getting started](01-getting-started.md) — install, build, run, write your first page
2. [Component model](02-components.md) — `Node`, `Attr`, `Context`, the renderer
3. [Actions (Zerver)](03-actions.md) — the `/api/<fn>` dispatcher, JSON vs form, error returns
4. [Routing](04-routing.md) — page route table, the comptime API walk
5. [Reactivity](05-reactivity.md) — server signals + client signals + multi-bind
6. [Realtime: SSE + WebSocket](06-realtime.md) — push state to the browser
7. [Static assets](07-static-assets.md) — `--public-dir` runtime, `-Dpublic-dir` comptime
8. [Observability](08-observability.md) — `/health`, `/metrics`, logging
9. [Performance & hardening](09-performance.md) — thread pool, admission cap, gzip
10. [CLI scaffolder](10-scaffolder.md) — `verve-cli new`
11. [Deployment](11-deployment.md) — systemd `LISTEN_FDS`, signal handling, body limits
12. [WASM client](12-wasm-client.md) — the wasm32-freestanding runtime, FBA, HTML escape

## Reference

- [Top-level README](../README.md) — quickstart + feature matrix
- [HANDOFF.md](../HANDOFF.md) — non-obvious context across sessions
- [Examples](../examples/README.md) — three working sample apps

## Conventions used throughout

- `verve-server` is the framework's runnable binary. Build with
  `zig build` at the repo root.
- `<repo>` refers to the directory containing this `docs/` folder.
- Code blocks tagged `zig`, `sh`, or `console` mean exactly that:
  Zig source, shell commands, terminal output.
- File paths like `src/server/main.zig:138` use the `path:line` format
  that most editors will jump to on click.

## Glossary

- **Action** — a `pub fn` on `Actions` that the framework exposes as
  `POST /api/<fn>`. Convention: takes a single struct argument.
- **Bridge** — `src/bridge/verve.js`, ~100 lines of glue that loads
  the wasm client and routes DOM events to it.
- **Context** — per-request `ArenaAllocator` wrapper passed into render
  functions. Memory is freed when the request completes.
- **Signal** — server-side reactive value; mutations notify subscribed
  listeners (used by tests, not the request path today).
- **ClientSignal** — wasm-side reactive value; mutations call an extern
  to update the DOM via the bridge.
- **Zerver action** — Verve's name for an RPC-like server function that
  appears on the client without any boilerplate.
