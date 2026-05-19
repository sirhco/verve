# Verve

Full-stack Zig web framework. Server-side rendering with fine-grained reactivity, a wasm32-freestanding client, and a single-binary distribution. No VDOM. No macros. No third-party dependencies.

Targets **Zig 0.16.0**.

```sh
zig build                           # native server + wasm client
zig build test --summary all        # 19 tests across core + server + integration
./zig-out/bin/verve-server          # open http://127.0.0.1:8080
```

## What's in the box

- Streaming SSR via `std.http.Server`, chunked transfer-encoding, no full-body buffering
- Comptime page router and `/api/<fn>` dispatcher (walks `app.Actions` decls)
- Dual-mode actions: JSON bodies return `{"ok":true}` or `{"value":...}`; form bodies return `303 See Other` to the Referer
- Per-connection worker threads with a bounded admission cap (`--workers N`)
- Server-Sent Events at `/events`, bidirectional WebSocket at `/ws`
- Static asset routing at `/public/*` — runtime (`--public-dir`) or comptime-embedded (`-Dpublic-dir=...`)
- Gzip compression for HTML / JS / WASM / JSON / CSS / SVG / text when the client advertises `Accept-Encoding: gzip`
- `/health` (uptime + request count) and `/metrics` (per-route latency JSON)
- LISTEN_FDS env-var support for systemd-style socket activation
- Graceful shutdown on `SIGINT` / `SIGTERM`
- A 565 B wasm client + 80-line JS bridge, both `@embedFile`'d into the binary

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

A page is a function that builds a `Node` tree. The renderer streams the tree to the socket.

```zig
// src/app/components.zig
pub fn home(ctx: *const verve.Context) !verve.Node {
    const alloc = ctx.alloc();
    const kids = try alloc.alloc(verve.Node, 2);
    kids[0] = .{ .tag = "h1", .text = "Verve" };
    kids[1] = .{ .tag = "p", .text = "Hello from Zig." };
    return .{ .tag = "main", .children = kids };
}
```

Register it in the route table:

```zig
// src/app/routes.zig
pub const routes: []const Route = &.{
    .{ .path = "/", .render = renderHome },
};

fn renderHome(ctx: *const verve.Context) !verve.Node {
    const body = try components.home(ctx);
    return components.page(ctx, body);   // wraps in <html>/<head>/<body>
}
```

`Node` and `Attr` are plain structs; `ctx.alloc()` returns a per-request `ArenaAllocator`. Anonymous array literals (`&.{...}`) hold runtime values that dangle after function return — use `try alloc.alloc(verve.Attr, N)` explicitly for any attr whose value isn't comptime-known.

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
| GET  | `/`, `/counter`, `/todos`, …    | Pages from `app.routes` |
| POST | `/api/<fn>` | Dispatched to `app.Actions.<fn>`; JSON or form-encoded |
| GET  | `/client.wasm`, `/verve.js`     | Embedded client + bridge |
| GET  | `/public/<path>`                | Static assets (runtime or comptime) |
| GET  | `/events`                       | Server-Sent Events (text/event-stream) |
| GET  | `/ws`                           | WebSocket upgrade |
| GET  | `/health`                       | JSON: `{status, uptime_sec, requests}` |
| GET  | `/metrics`                      | JSON: per-route count / avg_ns / max_ns |

## CLI

```text
verve-server [--host HOST] [--port PORT] [--body-limit SIZE]
             [--public-dir DIR] [--workers N] [--help]
```

| Flag | Default | Notes |
|---|---|---|
| `--host`        | `127.0.0.1`      | IP literal. Use `0.0.0.0` for any interface. |
| `--port`        | `8080`           | TCP port; `0` rejected (ephemeral binding unsupported). |
| `--body-limit`  | `1m`             | Max POST body size. Accepts `k`/`m`/`g` suffix. |
| `--public-dir`  | (none)           | Serve files from `DIR` at `/public/*`. |
| `--workers`     | `CPU * 2`        | Max in-flight connections; excess returns `503`. |
| `-h, --help`    |                  | Print usage and exit. |

### Environment

- `LISTEN_FDS=N` — adopt file descriptor 3 as the listening socket (systemd activation). `--host` / `--port` ignored when set.

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
