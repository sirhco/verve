# Verve documentation

Topic-by-topic guides. Read in order if you're new; jump around if
you know what you need.

## Reading order for a newcomer

1. [Getting started](01-getting-started.md) — install, build, run, write your first page
2. [Component model](02-components.md) — `Node`, `Context`, head slots, NodeRef, Slot
3. [Actions / Server Functions](03-actions.md) — `/api/<fn>` dispatcher, `ctx.serverFn`, CSRF on forms
4. [Routing](04-routing.md) — path params, nested layouts, Outlet, Redirect, ProtectedRoute, Link
5. [Reactivity](05-reactivity.md) — Owner tree, Signal, Effect, Store, Resource, ErrorBoundary
6. [Realtime: SSE + WebSocket](06-realtime.md) — push state to the browser
7. [Static assets](07-static-assets.md) — hashed URLs, public-dir LRU, precompressed brotli
8. [Observability](08-observability.md) — `/health`, `/metrics`, logging
9. [Performance & hardening](09-performance.md) — thread pool, admission cap, gzip
10. [CLI scaffolder](10-scaffolder.md) — `verve-cli new`
11. [Deployment](11-deployment.md) — CLI flags, systemd `LISTEN_FDS`, `--dev`, `VERVE_CSRF_KEY`
12. [WASM client](12-wasm-client.md) — wasm32-freestanding runtime, growable bump heap
13. [Security](13-security.md) — CSRF, CSP nonce, Origin pinning, ProtectedRoute
14. [i18n](14-i18n.md) — Catalog + locale resolution
15. [Islands](15-islands.md) — opt-in hydration boundary API + Phase 8 roadmap
16. [SPA router](16-spa-router.md) — `verve.link`, head merge + body swap, prefetch

## Reference

- [Top-level README](../README.md) — quickstart + feature matrix
- [HANDOFF.md](../HANDOFF.md) — non-obvious context across sessions
- [Examples](../examples/README.md) — runnable sample apps

## Conventions used throughout

- `verve-server` is the framework's runnable binary. Build with
  `zig build` at the repo root.
- `<repo>` refers to the directory containing this `docs/` folder.
- Code blocks tagged `zig`, `sh`, or `console` mean exactly that:
  Zig source, shell commands, terminal output.
- File paths like `src/server/main.zig:138` use the `path:line` format
  that most editors will jump to on click.

## Glossary

- **Action / Server Function** — a `pub fn` on `app.Actions` that the
  framework exposes as `POST /api/<fn>`. Convention: takes a single
  struct argument. Callable from render code via `ctx.serverFn(fn, args)`.
- **Bridge** — `src/bridge/verve.js`, ~250 lines of glue that loads
  the wasm client, registers the SPA router, runs server-fn POSTs,
  and registers `<verve-island>` as a custom element.
- **Context** — per-request handle. Owns the arena, the reactive
  Owner, the head accumulator, captured route params, the current
  Location, the request header snapshot, and the asset resolver.
- **Owner** — reactive scope. Disposes its child owners and `on_cleanup`
  hooks in LIFO when the request ends.
- **Signal / Effect** — reactive primitives. Effects re-run when any
  Signal they read changes. Cleanup via the enclosing Owner.
- **Store** — comptime struct wrapper with one Signal per field —
  field-grained reactivity.
- **Resource** — async-value wrapper exposing
  `.loading | .ready(T) | .err`.
- **Island** — opt-in hydration boundary marked with
  `<verve-island data-name=… data-props=…>`. Phase 8 will fetch the
  matching WASM chunk and hydrate the subtree.
- **NodeRef** — typed handle to a DOM node that survives hydration.
  Server emits `data-ref="<id>"`; client resolves via `verveQueryRef`.
- **Redirect** — sentinel return value from a render fn or guard
  that triggers a 302/303 instead of HTML.
