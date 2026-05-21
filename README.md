# Verve

Full-stack Zig web framework. Server-side rendering with fine-grained reactivity, a wasm32-freestanding client runtime that hosts the real Signal/Effect graph, per-island WASM code-splitting, and a single-binary distribution. No VDOM. No macros. No third-party dependencies.

Targets **Zig 0.16.0**.

📚 **[Documentation](docs/README.md)** — 18 topic guides covering every feature.
🧪 **[Examples](examples/README.md)** — runnable sample apps including a full [showcase](examples/showcase/).

```sh
zig build                           # native server + wasm client + per-island chunks
zig build test --summary all        # 155+ tests across core + server + client + integration
zig build docs                      # zig-out/docs/api/index.html — Zig autodoc for the public verve module
./zig-out/bin/verve-server          # open http://127.0.0.1:8080
```

## Why Verve

Most web frameworks force a trade between **time-to-first-byte** (SSR), **interactive feel** (client-side reactivity), and **operational shape** (one binary vs. a Node/Bun/Deno toolchain alongside a backend service). Pick two; live with the third.

Verve is the bet that you can have all three in **pure Zig**:

- **SSR-first.** Pages render server-side as `*Node` trees streamed straight to the socket. Search engines and noscript clients see real content. No hydration handshake required to read the page.
- **Real reactivity on the client.** The same `Signal` / `Effect` / `Owner` / `Resource` graph the server uses ships into a wasm32-freestanding client runtime. DOM updates are a *consequence* of `Signal.set` — not a parallel write path tacked on for "JS interactivity."
- **One binary.** No Node runtime. No build server. No bundler config. `zig build` produces a single executable with the WASM client, per-island chunks, JS bridge, public assets, and manifest baked in. Deploy by `scp`.
- **Pure Zig.** Zero third-party dependencies. The framework, scaffolder, server-fn codegen, island chunker, and reactive runtime are all in this repo, in one language, behind the same `zig fmt` rules.

If the goal is to ship a server-rendered, reactive web app with the operational profile of a Go binary and the type ergonomics of a hand-written `view!` macro — without taking on Rust's compile times, npm's lockfile churn, or React's hydration cost — that's what Verve exists for.

## Why "Verve"

**Verve**: *vigor, spirit, energy of expression*. A reactive update arrives with no waiting — `Signal.set` and the DOM is already different. The framework's job is to keep that feeling honest from the first byte the server flushes to the last keystroke a user types into a hydrated input.

It's also short, unique on crates.io / npm / pypi (none of which Verve ships to), and easy to type. The bigger half of the meaning, though, is the energetic one: the framework is opinionated about *not* getting in the way of code that wants to react instantly.

## What's in the box

### Routing + rendering
- Comptime route parser with **path parameters** (`/work/:slug`), **wildcards** (`/files/*rest`), and **nested layouts** with `ctx.outlet()`.
- **ProtectedRoute** guards + **Redirect** sentinel (`ctx.redirect("/login")`).
- **`useLocation`** — `ctx.location` with lazy query parsing + `isActive`.
- `RequestMeta` exposes cookies, Accept-Language, User-Agent, Origin, Host.

### Reactivity (server + WASM client)
- **Signal / Effect / Store / Resource** — full SolidJS/Leptos-style runtime, shared between server-side render and the WASM client.
- **Owner tree** with `on_cleanup` (LIFO disposal).
- **`untrack` / `batch`** escape hatches.
- **Typed NodeRef** + `data-ref` markers.
- **Reactive ErrorBoundary** — `Signal(?anyerror)` with `captureError` / `reset`.
- **Client-side runtime** — the wasm bundle hosts the real reactive graph. `registerI32` / `registerStr` / `registerBool` / `registerF32` allocate Signals whose `on_set` hook drives DOM updates. Per-frame scratch allocator keeps memory bounded across re-runs.
- **Keyed-list reconciler** — LIS-based planner emits the minimum (insert | move | remove) op sequence; `ForEachHandle` caches key order so subsequent updates only diff the delta.

### Head + components
- **Head slot accumulator** — `ctx.setTitle / metaTag / linkTag / jsonLd` with explicit priority + replace-not-append semantics.
- **`provide` / `use` DI** through the owner chain.
- **Slot / SlotMap** — named children API.
- **`show` / `forEach` / `portal`** — control-flow helpers (server + reactive client-side via the reconciler).

### Auth + security
- **CSRF** — HMAC-SHA256 token, auto-issued cookie + `__csrf` form field. `ctx.actionForm` injects the field automatically.
- **CSP nonce** — per-request 12-byte hex nonce in `Content-Security-Policy: script-src 'nonce-…' 'strict-dynamic'`.
- **Origin pinning** on form POSTs.
- **`SameSite=Strict`** on the CSRF cookie.

### SSR + client
- Streaming SSR via `std.http.Server`, chunked transfer-encoding, no full-body buffering.
- **`ctx.fetch`** wrapper around `std.http.Client`.
- **`ctx.serverFn`** — server-side direct call into `app.Actions`.
- **Typed server-fn client stubs** — `build.zig` codegen walks `app.Actions` at build time and emits `app_client.zig` with `<name>(arena, args)` (native, typed return) plus `<name>_post(arena, args)` (fire-and-forget JSON POST, WASM-callable).
- **Out-of-order Suspense streaming** — `Renderer.streamRender` flushes the shell first, then drains parked boundaries as `<template id="verve-vs-N">{real}</template>` + `verveSwap(N)` chunks. `withStreamRegistry` activates the threadlocal for a build's scope.
- **SPA navigation** via `verve.link` — delegated click intercept, head merge, body swap, prefetch-on-hover, popstate handler.
- **Growable WASM heap** (`@wasmMemoryGrow`) + 256 KB per-frame scratch region for reconciler scratch.

### i18n
- `verve.I18nCatalog` + `resolveLocale` — cookie → query → Accept-Language → default with language-prefix fallback.

### Assets
- Static asset routing at `/public/*` — runtime (`--public-dir`) or comptime-embedded (`-Dpublic-dir=…`).
- **Hashed URLs**: `/public/style-d5a73163.css` with `Cache-Control: public, max-age=31536000, immutable`. `ctx.assetHref("style.css")` resolves to the hashed form.
- **mtime-aware LRU** for `--public-dir` reads.
- **Precompressed `.br` / `.gz`** siblings served when present.

### Islands (per-island WASM chunks)
- `verve.island(ctx, opts, inner)` emits `<verve-island data-name=… data-props=…>` markers.
- **Build-time manifest codegen** walks `app.islands` at comptime and emits `client_manifest.zig` listing every island's name, props schema, and chunk URL.
- **Per-island WASM chunks** — `build.zig` parses `src/app/islands.zig` and builds one chunk per declared island (`src/client/islands/<Name>.zig` for custom logic, `_default.zig` as a shared stub).
- **Shared linear memory** — chunks import their memory from the main `client.wasm` via `env.memory`, dropping per-chunk size to **~73 bytes** vs. ~180 B standalone. Total bytes-on-wire stays flat as you add more islands.
- **Lazy dispatch** — JS bridge fetches each chunk on first encounter, caches the instantiation, copies props through shared scratch, and calls `hydrate(ptr, len, root_id)`.

### Dev + ops
- **`--dev`** auto-reload: injects a WS-disconnect-reconnect script. Pair with `zig build --watch run -- --dev`.
- **`--csrf=enforce|disable`** flag (default enforce).
- `/events` SSE + `/ws` bidirectional WebSocket.
- `/health` (uptime + request count) + `/metrics` (per-route latency JSON).
- Per-connection worker pool with bounded admission (`--workers N`).
- LISTEN_FDS env-var support for systemd socket activation.
- Graceful shutdown on `SIGINT` / `SIGTERM`.

## Quickstart

```sh
zig version                              # expect 0.16.0
zig build                                # produces zig-out/bin/verve-server
zig build test --summary all
zig fmt --check build.zig src tests

./zig-out/bin/verve-server --help        # CLI surface
./zig-out/bin/verve-server               # boots on 127.0.0.1:8080
```

Then open:

- <http://127.0.0.1:8080/> — landing page
- <http://127.0.0.1:8080/counter> — live counter (WASM reactive runtime drives DOM, WS bidirectional sync)
- <http://127.0.0.1:8080/todos> — pure server-rendered todo list (no wasm needed)
- <http://127.0.0.1:8080/work/hello-world> — path-parameter + per-page head slots demo
- <http://127.0.0.1:8080/app/dashboard> — nested layout route

Or run the **showcase** for a tour of every feature:

```sh
cd examples/showcase
zig build run -- --dev
```

Static-asset demo:

```sh
./zig-out/bin/verve-server --port 9000 --public-dir ./tests/public_fixture
curl http://127.0.0.1:9000/public/hello.txt
```

Comptime-embedded `/public/*` (production-shaped — files baked into the binary):

```sh
zig build -Dpublic-dir=tests/public_fixture
./zig-out/bin/verve-server                # no --public-dir; same files served
curl http://127.0.0.1:8080/public/hello.txt
```

## Writing a page

A page is a function that builds a `*Node` tree via the fluent chain. Each
method on `Node` mutates the arena-backed node and returns `*Node` so calls
compose left-to-right. The renderer streams the tree to the socket.

```zig
// src/app/components.zig
pub fn home(ctx: *const verve.Context) !*verve.Node {
    return ctx.main_().children(.{
        ctx.h1("Verve"),
        ctx.p().text("Hello from Zig."),
        ctx.p().children(.{ verve.link(ctx, "/about", "About →", .{}) }),
    }).build();
}
```

Register it in the route table — `Route.init` for leaf routes,
`Route.layout` for nested layouts:

```zig
// src/app/routes.zig
pub const routes: []const verve.Route = &.{
    verve.Route.init("/",        renderHome),
    verve.Route.init("/work/:slug", renderWorkDetail),
    verve.Route.layout("/app",   renderShell, &.{
        verve.Route.init("/dashboard",        renderDashboard),
        verve.Route.init("/settings/:section", renderSettings),
    }),
};

fn renderHome(ctx: *verve.Context) !*verve.Node {
    try ctx.setTitle("Verve");
    const body = try components.home(ctx);
    return components.page(ctx, body);   // wraps in <html>/<head>/<body>
}
```

`ctx.alloc()` returns the per-request `ArenaAllocator` if you need it
directly. Element factories on `Context` cover the common HTML tags
(`div`, `span`, `h1`–`h4`, `a`, `button`, `form`, `input`, `ul`, `li`,
`nav`, `main_`, `section`, ...); the generic `ctx.el(tag)` is the
escape hatch. Chain methods include `.class()`, `.id()`, `.href()`,
`.attr(k,v)`, `.attrFmt(k,fmt,args)`, `.text(t)`, `.textFmt(fmt,args)`,
`.textInt(n)`, `.bind(name)`, `.onClick(action)`, `.children(.{ a, b, ... })`.
Errors encountered mid-chain are deferred to the terminating `.build()`.

## Writing an Action (Zerver)

Each Action is `fn(args: struct { ... }) Ret`. The dispatcher walks `app.Actions` at comptime and routes `POST /api/<name>` to the matching function. Form-encoded bodies are URL-decoded into the struct's fields; JSON bodies are parsed via `std.json`. Return types may be `void`, `!void`, `T`, or `!T`.

```zig
// src/app/api.zig
pub const Actions = struct {
    pub fn incrementCount(_: struct {}) i32 {
        return last_count.fetchAdd(1, .monotonic) + 1;
    }

    pub fn addTodo(args: struct { text: []const u8 }) !void {
        if (args.text.len == 0) return error.EmptyTodo;
        // ...
    }
};
```

`build.zig` generates `app_client.zig` at build time with two wrappers per action:

```zig
// generated — used from server-side render code
const after = try app_client.incrementCount(ctx.alloc(), .{});

// generated — used from WASM client; serializes args to JSON,
// POSTs to /api/incrementCount via the JS bridge
app_client.incrementCount_post(scratch, .{});
```

Form submissions also auto-redirect (303) to the `Referer`, so plain `<form action="/api/addTodo" method="POST">` works without any client-side JS.

## Reactive client

Each `bind("count")` in a server-rendered tree gets a matching `data-vh="count"` attribute. On startup the WASM client registers a Signal per bind, wires its `on_set` hook to a DOM primitive, and from that point on every state change flows through the reactive graph:

```zig
// src/client/main.zig
const count_sig = runtime.registerI32("count", count_initial);

export fn increment_counter() void {
    count_sig.?.set(count_sig.?.peek() + 1);    // → on_set → DOM update
}
```

For keyed lists, `runtime.registerForEach(parent_bind, initial_keys)` returns a `ForEachHandle`; `bindForEach(handle, ctx, render_fn)` ties a list-valued computation into the reactive graph and emits the minimum (insert | move | remove) ops via the LIS-based reconciler.

## Islands

Per-island WASM chunks ship lazily — pages that don't use a particular island skip the download:

```zig
// src/app/islands.zig (build.zig discovers entries here)
pub const Counter = struct {
    pub const props_schema: []const u8 = "{\"initial\":\"i32\"}";
};

// src/app/components.zig
return verve.island(ctx, .{ .name = "Counter", .props = "{}" }, inner);
```

The build system fans one WASM chunk out per declared island, each importing memory from the main `client.wasm` for zero-byte runtime duplication. Custom island logic lives in `src/client/islands/<Name>.zig`; everything else picks up the shared `_default.zig` stub.

## Streaming SSR

Suspense boundaries that mark themselves `markSuspended` register a continuation on the active stream registry instead of emitting fallback inline:

```zig
const reg = verve.StreamRegistry.init(ctx.alloc());
const root = try verve.withStreamRegistry(&reg, ctx, buildPage);
try verve.Renderer.streamRender(writer, root, &reg);
```

`streamRender` walks the tree, then drains every parked slot as `<template id="verve-vs-{id}">{real}</template>` + `verveSwap({id})` chunks. The client `verveSwap` helper unwraps the template in place of the `<div data-vs="{id}">` placeholder.

## Runtime surface

| Method | Path | Notes |
|---|---|---|
| GET  | `/`, `/counter`, `/todos`, …       | Pages from `app.routes` (supports `:param`, `*wildcard`, nested layouts) |
| POST | `/api/<fn>`                        | Dispatched to `app.Actions.<fn>`; JSON skips CSRF, form requires `__csrf` field |
| GET  | `/client.wasm`, `/verve.js`        | Embedded client + bridge |
| GET  | `/islands/<Name>.wasm`             | Per-island WASM chunk (one per `app.islands` decl) |
| GET  | `/public/<path>`                   | Static assets (hashed URL → immutable cache, plain → max-age=300) |
| GET  | `/events`                          | Server-Sent Events (text/event-stream) |
| GET  | `/ws`                              | WebSocket upgrade |
| GET  | `/__verve/dev_ws`                  | Dev auto-reload (only with `--dev`) |
| GET  | `/health`                          | JSON: `{status, uptime_sec, requests}` |
| GET  | `/metrics`                         | JSON: per-route count / avg_ns / max_ns |

## CLI

```text
verve-server [--host HOST] [--port PORT] [--body-limit SIZE]
             [--public-dir DIR] [--workers N] [--csrf=MODE] [--dev] [--help]
```

| Flag | Default | Notes |
|---|---|---|
| `--host`        | `127.0.0.1`      | IP literal. Use `0.0.0.0` for any interface. |
| `--port`        | `8080`           | TCP port; `0` rejected (ephemeral binding unsupported). |
| `--body-limit`  | `1m`             | Max POST body size. Accepts `k`/`m`/`g` suffix. |
| `--public-dir`  | (none)           | Serve files from `DIR` at `/public/*`, backed by mtime-aware LRU. |
| `--workers`     | `CPU * 2`        | Max in-flight connections; excess returns `503`. |
| `--csrf`        | `enforce`        | `disable` for integration tests; production should leave on. |
| `--dev`         | off              | Inject auto-reload script + accept `/__verve/dev_ws` upgrades. |
| `-h, --help`    |                  | Print usage and exit. |

### Environment

- `LISTEN_FDS=N` — adopt file descriptor 3 as the listening socket (systemd activation). `--host` / `--port` ignored when set.
- `VERVE_CSRF_KEY` — hex-encoded 32 bytes for stable CSRF tokens across restarts. Random key drawn at startup when absent.

### Build options

- `-Dpublic-dir=DIR` — embed every file in `DIR` into the binary at compile time. Served at `/public/<path>` even when `--public-dir` is not given. Runtime `--public-dir` overrides any embedded entry with the same path.

## Repository layout

| Path | Purpose |
|---|---|
| `build.zig` | Wasm32 → server pipeline; per-island chunk fan-out; codegen wiring for `app_client.zig` + `client_manifest.zig`; `-Dpublic-dir` flag |
| `tools/server_fn_codegen.zig` | Build-time codegen for typed server-fn stubs |
| `tools/island_manifest_gen.zig` | Build-time codegen for the island manifest |
| `src/verve.zig` | Public library entry — re-exports core types |
| `src/core/{node,signal,context,renderer,server_fn_gen,stream_context}.zig` | Framework primitives |
| `src/server/main.zig` | HTTP server, accept loop, CLI parser, signal handlers, `/health`, `/metrics`, `/events`, `/ws`, `/public`, `/islands/<name>.wasm`, error rendering |
| `src/server/api_handler.zig` | `/api/<fn>` dispatcher; JSON and form body parsing |
| `src/server/pool.zig` | Bounded-admission worker pool |
| `src/server/metrics.zig` | Per-route latency counters |
| `src/server/gzip.zig` | `Accept-Encoding: gzip` helper |
| `src/client/{main,runtime,reconciler,scratch,island,signal,dom}.zig` | WASM client runtime + reactive graph + keyed reconciler |
| `src/client/islands/<Name>.zig` | Per-island WASM chunk sources |
| `src/bridge/verve.js` | DOM externs, reactive primitives, SPA router, island loader, verveSwap |
| `src/app/{components,api,routes,islands}.zig` | Example application |
| `src/cli/main.zig` | `verve-cli` scaffolder binary |
| `tests/integration.zig` | E2E tests (spawn server, hit endpoints, kill) |
| `tests/public_fixture/` | Files used by the `--public-dir` integration test |
| `.github/workflows/ci.yml` | CI matrix (ubuntu + macos) — fmt check + build + test + smoke |

## Scaffolding a new app

```sh
zig build cli                                  # builds zig-out/bin/verve-cli
./zig-out/bin/verve-cli new ~/code/my-app
cd ~/code/my-app
zig build && ./zig-out/bin/verve-server
```

The scaffolder embeds the entire Verve source tree at build time and writes it into the target directory. The generated app is self-contained — no Zig package-manager dependency, no git clone.

## API reference

`zig build docs` runs Zig's built-in autodoc generator over
`src/verve.zig` and writes a static bundle to `zig-out/docs/api/`:

```sh
zig build docs
open zig-out/docs/api/index.html        # macOS — or any browser
# or serve over HTTP for the live search:
python3 -m http.server -d zig-out/docs/api 8000
```

The bundle is a single `index.html` plus `main.js` + `main.wasm`
(the search runtime) + `sources.tar` (the indexed source set).
Every `pub` symbol with a `///` doc-comment shows up under its
declaring module in the navigation.

Browsable HTML guides live under [`docs/`](docs/) — the handwritten
companion to the auto-generated reference.

## Contributing

```sh
zig fmt --check build.zig src tests
zig build
zig build test --summary all
zig build docs                          # regenerate API reference
```

CI runs the same on ubuntu-latest and macos-latest and adds a curl smoke test against the live binary. See `.github/workflows/ci.yml`.

## License

MIT. See `LICENSE`.
