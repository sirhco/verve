# Verve documentation

Topic-by-topic guides. Read in order if you're new; jump around if
you know what you need.

## Reading order for a newcomer

1. [Getting started](01-getting-started.md) — install, build, run, write your first page
2. [Component model](02-components.md) — `Node`, `Context`, head slots, NodeRef, Slot
3. [Actions / Server Functions](03-actions.md) — `/api/<fn>` dispatcher, `ctx.serverFn`, generated `app_client.zig` stubs, CSRF on forms
4. [Routing](04-routing.md) — path params, nested layouts, Outlet, Redirect, ProtectedRoute, Link
5. [Reactivity](05-reactivity.md) — Owner tree, Signal, Effect, Store, Resource, ErrorBoundary
6. [Realtime: SSE + WebSocket](06-realtime.md) — push state to the browser
7. [Static assets](07-static-assets.md) — hashed URLs, public-dir LRU, precompressed brotli
8. [Observability](08-observability.md) — `/health`, `/metrics`, logging
9. [Performance & hardening](09-performance.md) — thread pool, admission cap, gzip
10. [CLI scaffolder](10-scaffolder.md) — `verve-cli new`
11. [Deployment](11-deployment.md) — CLI flags, systemd `LISTEN_FDS`, `--dev`, `VERVE_CSRF_KEY`
12. [WASM client](12-wasm-client.md) — wasm32-freestanding runtime, reactive graph, typed bindings + auto-walker, closure events, NodeRef ops, slot introspection, `verve_client` façade for downstream apps
13. [Security](13-security.md) — CSRF, CSP nonce, Origin pinning, ProtectedRoute
14. [i18n](14-i18n.md) — Catalog + locale resolution
15. [Islands](15-islands.md) — per-island WASM chunks, shared-runtime memory, chunk-side reactive API (Phase 13F), cross-module closure events (Phase 13G), multi-instance support, manifest codegen
16. [SPA router](16-spa-router.md) — `verve.link`, head merge + body swap, prefetch
17. [Reconciler](17-reconciler.md) — keyed-list planner, `ForEachHandle`, reactive `bindForEach`
18. [Streaming SSR](18-streaming.md) — `Suspense`, `withStreamRegistry`, `streamRender`, `verveSwap`
19. [Desktop apps](19-desktop.md) — native window + system webview, SSR + WASM hydration under `verve://`, typed IPC, cookies, multi-window, `.app` bundle, dev loop, Level-3 smoke

## Reference

- [Top-level README](../README.md) — quickstart + feature matrix + why-Verve
- [CHANGELOG](../CHANGELOG.md) — what shipped, when
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
  struct argument. Callable from render code via `ctx.serverFn(fn, args)`
  or the generated typed stub `app_client.<fn>(arena, args)`.
- **app_client** — build-time generated module (`tools/server_fn_codegen.zig`)
  that emits one typed wrapper per `app.Actions` decl plus a
  fire-and-forget `<fn>_post` variant the WASM client can call.
- **Bridge** — `src/bridge/verve.js`, glue that loads the WASM client,
  registers the SPA router, dispatches server-fn POSTs, hosts the
  reactive-graph DOM primitives, loads per-island chunks on demand,
  and runs `verveSwap` for streamed Suspense chunks.
- **Context** — per-request handle. Owns the arena, the reactive
  Owner, the head accumulator, captured route params, the current
  Location, the request header snapshot, and the asset resolver.
- **ForEachHandle** — runtime cache over a keyed parent's current
  key order. `update(arena, new_keys, new_html)` runs the reconciler
  against the cache; `bindForEach` ties it into a reactive Signal.
- **Island** — opt-in hydration boundary marked with
  `<verve-island data-name=… data-props=…>`. Each declared island
  ships its own WASM chunk that imports linear memory from the
  main `client.wasm` for zero runtime duplication.
- **island_chunks** — generated assets table the server uses to
  serve `/islands/<Name>.wasm` from the embedded chunk bytes.
- **NodeRef** — typed handle to a DOM node that survives hydration.
  Server emits `data-ref="<id>"`; client resolves via `verveQueryRef`.
- **Owner** — reactive scope. Disposes its child owners and
  `on_cleanup` hooks in LIFO when the request ends.
- **Reconciler** — LIS-based keyed-list planner in
  `src/client/reconciler.zig`. Emits the minimum (insert | move |
  remove) op sequence that turns the live DOM into a new order.
- **Redirect** — sentinel return value from a render fn or guard
  that triggers a 302/303 instead of HTML.
- **Scratch** — fixed 256 KB bump allocator (`src/client/scratch.zig`)
  reset between effect re-runs. Separate from the growable
  long-lived heap that hosts Signals + the reactive graph.
- **Signal / Effect** — reactive primitives. Effects re-run when any
  Signal they read changes. Cleanup via the enclosing Owner.
- **Store** — comptime struct wrapper with one Signal per field —
  field-grained reactivity.
- **StreamRegistry** — per-request table of parked Suspense slots.
  `withStreamRegistry` activates it for a build's scope;
  `Renderer.streamRender` drains it after the shell.
- **Resource** — async-value wrapper exposing
  `.loading | .ready(T) | .err`.
- **verve_client** — sibling module published from `build.zig`
  alongside `verve`. Re-exports the full reactive surface plus the
  DOM-wired adapter for use in wasm-target client code. Imported as
  `@import("verve")` from downstream wasm clients (e.g. the desktop
  template).
- **Typed binding** — `Node.bindI32` / `bindStr` / `bindBool` /
  `bindF32`. Stamps `data-vh-type` + `data-vh-initial` on the
  rendered element so the bridge JS auto-walker can register the
  Signal without per-bind wasm exports.
- **Auto-walker (Phase 14)** — bridge JS step that walks every
  `[data-vh-type]` after `verve_hydrate`, stages name + initial
  bytes through the runtime's island scratch buffer, and calls the
  matching `verve_register_<kind>` export. Eliminates the per-bind
  `verve_init_<name>` boilerplate.
- **Chunk-side reactive runtime (Phase 13F)** — per-island chunks
  call into the main client's reactive API via a `verve_runtime`
  import the bridge JS resolves against the main client's exports
  at instantiation. Chunks `@import("verve")` (chunk-side façade)
  and use `registerI32` / `signalSetI32` / `queryRef` / etc.
- **Shared indirect function table (Phase 13G)** — main client
  exports its `__indirect_function_table`; chunks import it. Lets
  closure-style event handlers (`verve.registerEvent(&fn)`) cross
  the chunk → main-runtime boundary without going through JS.
- **Cleanup hook** — `verve.cleanup(handler)` registers a
  `*const fn () void` against the runtime's root Owner; runs LIFO
  on dispose. Dormant in production today (Owner only disposes on
  test reset); poised for SPA-navigation work.
