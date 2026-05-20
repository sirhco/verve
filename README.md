# Verve

Full-stack Zig web framework. Server-side rendering with fine-grained reactivity, a wasm32-freestanding client, and a single-binary distribution. No VDOM. No macros. No third-party dependencies.

Targets **Zig 0.16.0**.

📚 **[Documentation](docs/README.md)** — 16 topic guides covering every feature.
🧪 **[Examples](examples/README.md)** — 8 runnable sample apps including a full Phase 0-10 [showcase](examples/showcase/).

```sh
zig build                           # native server + wasm client
zig build test --summary all        # 19 tests across core + server + integration
./zig-out/bin/verve-server          # open http://127.0.0.1:8080
```

## What's in the box

### Routing + rendering
- Comptime route parser with **path parameters** (`/work/:slug`), **wildcards** (`/files/*rest`), and **nested layouts** with `ctx.outlet()`.
- **ProtectedRoute** guards + **Redirect** sentinel (`ctx.redirect("/login")`).
- **`useLocation`** — `ctx.location` with lazy query parsing + `isActive`.
- `RequestMeta` exposes cookies, Accept-Language, User-Agent, Origin, Host.

### Reactivity
- **Signal / Effect / Store / Resource** — full SolidJS/Leptos-style runtime.
- **Owner tree** with `on_cleanup` (LIFO disposal).
- **`untrack` / `batch`** escape hatches.
- **Typed NodeRef** + `data-ref` markers.
- **Reactive ErrorBoundary** — `Signal(?anyerror)` with `captureError` / `reset`.

### Head + components
- **Head slot accumulator** — `ctx.setTitle / metaTag / linkTag / jsonLd` with explicit priority + replace-not-append semantics.
- **`provide` / `use` DI** through the owner chain.
- **Slot / SlotMap** — named children API.
- **`show` / `forEach` / `portal`** — control-flow helpers.

### Auth + security
- **CSRF** — HMAC-SHA256 token, auto-issued cookie + `__csrf` form field. `ctx.actionForm` injects the field automatically.
- **CSP nonce** — per-request 12-byte hex nonce in `Content-Security-Policy: script-src 'nonce-…' 'strict-dynamic'`.
- **Origin pinning** on form POSTs.
- **`SameSite=Strict`** on the CSRF cookie.

### SSR + client
- Streaming SSR via `std.http.Server`, chunked transfer-encoding, no full-body buffering.
- **`ctx.fetch`** wrapper around `std.http.Client`.
- **`ctx.serverFn`** — server-side direct call into `app.Actions`.
- **SPA navigation** via `verve.link` — delegated click intercept, head merge, body swap, prefetch-on-hover, popstate handler.
- **Growable WASM heap** (`@wasmMemoryGrow`), `verveQueryRef("id")` for NodeRef lookup.

### i18n
- `verve.I18nCatalog` + `resolveLocale` — cookie → query → Accept-Language → default with language-prefix fallback.

### Assets
- Static asset routing at `/public/*` — runtime (`--public-dir`) or comptime-embedded (`-Dpublic-dir=…`).
- **Hashed URLs**: `/public/style-d5a73163.css` with `Cache-Control: public, max-age=31536000, immutable`. `ctx.assetHref("style.css")` resolves to the hashed form.
- **mtime-aware LRU** for `--public-dir` reads.
- **Precompressed `.br` / `.gz`** siblings served when present.

### Dev + ops
- **`--dev`** auto-reload: injects a WS-disconnect-reconnect script. Pair with `zig build --watch run -- --dev`.
- **`--csrf=enforce|disable`** flag (default enforce).
- `/events` SSE + `/ws` bidirectional WebSocket.
- `/health` (uptime + request count) + `/metrics` (per-route latency JSON).
- Per-connection worker pool with bounded admission (`--workers N`).
- LISTEN_FDS env-var support for systemd socket activation.
- Graceful shutdown on `SIGINT` / `SIGTERM`.

### Islands (scaffold)
- `verve.island(ctx, opts, inner)` emits `<verve-island data-name=… data-props=…>` markers. Full per-island WASM hydration loader = Phase 8 follow-up.

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
- <http://127.0.0.1:8080/counter> — live counter (updates via WebSocket when JS is available, native `<form>` submit otherwise)
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

Form submissions auto-redirect (303) to the `Referer`, so plain `<form action="/api/addTodo" method="POST">` works without any client-side JS.

## Runtime surface

| Method | Path | Notes |
|---|---|---|
| GET  | `/`, `/counter`, `/todos`, …       | Pages from `app.routes` (supports `:param`, `*wildcard`, nested layouts) |
| POST | `/api/<fn>`                        | Dispatched to `app.Actions.<fn>`; JSON skips CSRF, form requires `__csrf` field |
| GET  | `/client.wasm`, `/verve.js`        | Embedded client + bridge |
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
| `build.zig` | Wasm32 → server pipeline; injects integration test fixture path; `-Dpublic-dir` flag |
| `src/verve.zig` | Public library entry — re-exports core types |
| `src/core/{node,signal,context,renderer}.zig` | Framework primitives |
| `src/server/main.zig` | HTTP server, accept loop, CLI parser, signal handlers, `/health`, `/metrics`, `/events`, `/ws`, `/public`, error rendering |
| `src/server/api_handler.zig` | `/api/<fn>` dispatcher; JSON and form body parsing |
| `src/server/pool.zig` | Bounded-admission worker pool |
| `src/server/metrics.zig` | Per-route latency counters |
| `src/server/gzip.zig` | `Accept-Encoding: gzip` helper |
| `src/client/{main,signal,dom}.zig` | WASM client runtime |
| `src/bridge/verve.js` | DOM externs, delegated click handler, EventSource + WebSocket subscriptions |
| `src/app/{components,api,routes}.zig` | Example application (Counter, TodoList, Home) |
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

## Contributing

```sh
zig fmt --check build.zig src tests
zig build
zig build test --summary all
```

CI runs the same on ubuntu-latest and macos-latest and adds a curl smoke test against the live binary. See `.github/workflows/ci.yml`.

## License

MIT. See `LICENSE`.
