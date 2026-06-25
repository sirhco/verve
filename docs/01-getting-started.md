# 01 — Getting started

Verve runs on **Zig 0.16.0** with no third-party dependencies. Everything
in the box is pure stdlib.

## Install Zig

The official installer / package manager varies by platform. Once it's
on your path:

```sh
zig version          # expect 0.16.0
```

Older versions will not compile this codebase — stdlib reshuffled
between 0.13 and 0.16.

## Clone and build

```sh
git clone https://github.com/sirhco/verve
cd verve
zig build
```

After a successful build:

```
zig-out/bin/verve-server      # native HTTP server (~3.1 MB)
zig-out/bin/verve-cli         # scaffolder for new projects (~2.2 MB)
```

## Run the demo

```sh
./zig-out/bin/verve-server
# info(verve): listening on http://127.0.0.1:8080
# info(verve): max concurrent connections: 36
# info(verve): pages:
#   GET  /
#   GET  /counter
#   GET  /todos
# info(verve): actions:
#   POST /api/updateDatabase
#   POST /api/logMessage
#   POST /api/getCount
#   POST /api/incrementCount
#   POST /api/decrementCount
#   POST /api/addTodo
#   POST /api/removeTodo
# ...
```

Open the browser at:

- <http://127.0.0.1:8080/> — landing page
- <http://127.0.0.1:8080/counter> — live counter, updates over WebSocket
- <http://127.0.0.1:8080/todos> — server-rendered todo list
- <http://127.0.0.1:8080/viz> — interactive graph + chart gallery (`verve.viz`)
- <http://127.0.0.1:8080/anim> — animation engine demo (`verve.anim`)
- <http://127.0.0.1:8080/smooth> — ScrollSmoother + scroll-snap page
- <http://127.0.0.1:8080/health> — JSON liveness probe
- <http://127.0.0.1:8080/metrics> — JSON per-route latency

Stop the server with `Ctrl-C` (SIGINT) or `kill -TERM <pid>` — both
trigger a clean shutdown.

## Run the tests

```sh
zig build test --summary all
# Build Summary: N/N steps succeeded; all tests passed (exact counts grow with the framework)
```

The suite groups five sub-suites (exact counts grow with the framework
— trust the build output):

- **Core** — node tree, reactive graph, renderer, routes, i18n,
  markdown/highlight, viz, anim (incl. the wire-format golden tests)
- **Server** — api_handler dispatch, pool admission, metrics, gzip
- **Client** — wasm data structures, run on the native target
- **Integration** — spawns `verve-server` and hits every endpoint
- **Desktop** — the pure-Zig pieces (native backends aren't exercised)

Format check:

```sh
zig fmt --check build.zig src tests
```

## Scaffold a new project

```sh
./zig-out/bin/verve-cli new ~/code/my-app
cd ~/code/my-app
zig build
./zig-out/bin/verve-server
```

The scaffolder embeds the entire Verve source tree at build time and
writes it into your target directory, plus a fresh `build.zig.zon`
with a Zig-validated fingerprint. See [`10-scaffolder.md`](10-scaffolder.md)
for details.

## First edit

Open `src/app/routes.zig` and add a route:

```zig
pub const routes: []const verve.Route = &.{
    verve.Route.init("/",         renderHome),
    verve.Route.init("/counter",  renderCounter),
    verve.Route.init("/todos",    renderTodos),
    verve.Route.init("/hello",    renderHello),   // <— new
    verve.Route.init("/hi/:name", renderHi),      // <— with a path param
};

fn renderHello(ctx: *verve.Context) !*verve.Node {
    return components.page(ctx, ctx.h1("Hello, Verve!"));
}

fn renderHi(ctx: *verve.Context) !*verve.Node {
    const name = ctx.param("name") orelse "world";
    try ctx.setTitle(try std.fmt.allocPrint(ctx.alloc(), "Hi {s}", .{name}));
    return components.page(ctx, ctx.h1(name));
}
```

Rebuild + reload — your route is live. No restart shortcuts, no
codegen, no macros. Just a slice of comptime-parsed routes.

## Dev auto-reload

`--dev` injects an auto-reload `<script>` into every page. Pair with
`zig build --watch run -- --dev` and the browser refreshes on every
rebuild.

```sh
zig build --watch run -- --dev --public-dir ./public
```

## What you get out of the box

Beyond the route → render plumbing:

- **Signals + effects** — reactive primitives for shared state
  (`ctx.useSignal`, `ctx.useEffect`).
- **Stores** — field-grained reactive structs (`verve.createStore`).
- **Resources** — async-value wrappers with loading / ready / err
  states.
- **Nested routes** — layouts with `Route.layout` + `ctx.outlet()`,
  guards via `.protect(fn)`, redirects via `ctx.redirect(href)`.
- **Head accumulator** — `ctx.setTitle / metaTag / linkTag / jsonLd`
  drained into `<head>` in priority order.
- **CSRF + CSP** — auto-issued HMAC token + per-request nonce. The
  `ctx.actionForm` helper handles the form-field side.
- **SPA navigation** — `verve.link(...)` anchors are intercepted
  client-side for seamless navigation.
- **Islands** — opt-in hydration boundaries via `verve.island(...)`.
- **i18n** — locale resolution (cookie → query → Accept-Language)
  with `verve.resolveLocale + I18nCatalog`.

Each topic has its own doc — read on.

## Next

- [02 — Component model](02-components.md) — how the renderer turns
  `Node` trees into HTML, head slots, NodeRef, Slot system.
- [03 — Actions](03-actions.md) — how `pub fn` becomes `POST /api/<fn>`.
- [04 — Routing](04-routing.md) — path params, nested routes, guards.
- [05 — Reactivity](05-reactivity.md) — Owner, Signal, Effect, Store.
