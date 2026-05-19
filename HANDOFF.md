# Verve — Session Handoff

A working snapshot of where the framework stands and what's left to do, so the next session (or a fresh contributor) can pick up cleanly.

---

## Where we are

**Status: feature-complete framework with documentation, scaffolder, and production-shaped server.**

- Builds and runs on Zig **0.16.0** (no third-party deps).
- `zig build` → `zig-out/bin/verve-server` (~3.1 MB native binary) + `zig-out/bin/verve-cli` (~2.2 MB scaffolder).
- `zig build test --summary all` → **37/37 green** (9 core + 12 server + 5 client + 11 integration).
- Single-binary distribution: wasm client + JS bridge are `@embedFile`d; `-Dpublic-dir=DIR` bakes additional static files in.
- README.md ships project documentation.

### What's shipped

**Core library (`src/core/`)**
- `Node`, `Attr` (recursive HTML tree, no VDOM)
- `Signal(T)` with listeners (server-side reactivity)
- `Context` (per-request ArenaAllocator)
- `Renderer.render(writer, node)` streaming, with HTML/attribute escaping and void-tag handling

**Server (`src/server/`)**
- `std.http.Server` on `std.Io.net` TCP
- **Bounded admission pool** (`pool.zig`) — atomic `tryAdmit/release` caps concurrent connections; excess returns immediate 503 with `Retry-After: 1`. CLI flag `--workers N` (default `clamp(cpu*2, 4, 1024)`).
- Comptime page router + comptime `/api/<fn>` dispatcher (walks `@typeInfo(Actions).decls`)
- **Dual-mode action dispatch**: JSON bodies (`application/json`) → `{"ok":true}` / `{"value":...}`; form bodies (`application/x-www-form-urlencoded`) → 303 See Other to Referer
- **Per-route metrics** (`metrics.zig`) — `std.atomic.Value` counters, labels collected at comptime from `app.routes` + `app.Actions` + fixed endpoints. JSON at `/metrics`: `{uptime_sec, total_requests, rejected, routes: {label: {count, avg_ns, max_ns}}}`.
- **Gzip compression** (`gzip.zig`) — `std.compress.flate` with `.gzip` container. `Accept-Encoding: gzip` triggers compression of HTML / JS / JSON / CSS / SVG / text responses ≥ 256 B. WASM, PNG, WEBP, error pages stay raw.
- **Static assets** at `/public/*`:
  - Runtime: `--public-dir DIR`, 4 MB cap, `..` and absolute paths rejected.
  - Comptime: `-Dpublic-dir=DIR` build flag walks the directory at configure time and bakes each file via `@embedFile` into `public_assets.zig`. Runtime overlay wins on collision.
- **Server-Sent Events** at `/events` — pushes `event: count\ndata: <n>\n\n` every second.
- **Bidirectional WebSocket** at `/ws` — server pushes the current `last_count` on connect + whenever it changes (250 ms tick); client sends `"+"` / `"-"` text frames to mutate state. Mutex-guarded writes between the reader loop and the broadcaster thread.
- `/health` endpoint with uptime + atomic request count
- `std.log.scoped(.verve)` for all diagnostics; signal handler + `printUsage` on `std.debug.print`
- **LISTEN_FDS** env var support: adopts fd 3 as listening socket (systemd activation)
- Graceful shutdown on SIGINT/SIGTERM
- CLI flags: `--host`, `--port`, `--body-limit`, `--public-dir`, `--workers`, `--help`/`-h`
- Unknown-arg detection with discovery hint

**WASM client (`src/client/`)**
- Compiles to wasm32-freestanding, ReleaseSmall
- Current binary size: **~650 B** (budget was 30 KB)
- `ClientSignal(T)` generic for multi-bind support
- Two signals shipped: `count` + `clicks` — proves multi-bind end-to-end
- **`FixedBufferAllocator`** (`allocator.zig`) over a 16 KB static heap, exposed as `client_alloc.allocator()`. Diagnostic exports: `verve_alloc_used`, `verve_alloc_capacity`, `verve_alloc_reset`. Monotonic by design; consumer calls `reset()` between render passes.
- **`render.escapeHtmlAlloc`** (`render.zig`) — XSS-safe primitive backed by the wasm client's FBA. Wraps `verve.escapeHtml` so consumer code assembling `innerHTML` strings has an allocator-backed helper. `escapeHtmlAllocWith` takes a caller-supplied allocator for ownership independence.
- Exports: `verve_hydrate`, `verve_init_count`, `verve_init_clicks`, `increment_counter`, `decrement_counter`, `current_count`, `verve_alloc_used`, `verve_alloc_capacity`, `verve_alloc_reset`
- SSR-to-client state sync: JS bridge auto-matches every `verve_init_<bind>` export to `[z-bind="<bind>"]` text

**JS bridge (`src/bridge/verve.js`)**
- ~100 lines. Streaming `WebAssembly.instantiateStreaming`
- Delegated click listener with WebSocket fast-path for counter actions (`+` / `-` frames) — falls through to wasm export otherwise
- Auto-scans `verve_init_*` exports for hydration
- **WebSocket subscription to `/ws`** when supported; falls back to **EventSource on `/events`** when WS isn't available
- Externs: `set_text_by_bind`, `set_text_by_bind_i32`, `post_json_i32`, `console_log_i32`

**Example app (`src/app/`)**
- Counter at `/counter` — shared atomic `last_count`, +/- buttons wrapped in `<form action="/api/incrementCount" method="POST">` so they work without JS (303 → Referer). With JS, the bridge intercepts clicks and routes through wasm or WebSocket.
- Distinct Home page at `/` with links to `/counter` and `/todos`
- **TodoList demo at `/todos`** — pure server-rendered, form submissions, no wasm needed.
- Seven Zerver actions: `updateDatabase`, `logMessage`, `getCount`, `incrementCount`, `decrementCount`, `addTodo`, `removeTodo`.
- Todo storage = fixed pool (32 × 200 B) guarded by `std.atomic.Mutex` spin-lock

**CLI scaffolder (`src/cli/main.zig` + `verve-cli` binary)**
- `verve-cli new <target-dir> [--name <pkg-name>]` writes a self-contained starter project: build.zig, build.zig.zon (fresh, fingerprinted), LICENSE, src/, tests/.
- Skeleton manifest (`buildCliSkeleton` in build.zig) walks `src/` and `tests/` at configure time and embeds every file via `@embedFile`.
- Auto-runs `zig build` once in the target directory to capture the suggested fingerprint and patches `build.zig.zon` (since the high half is name-derived).

**Tests (`tests/integration.zig` + module tests)**
- 11 integration tests spanning page rendering, form fallback, concurrent addTodo, --public-dir + traversal, /events SSE, /metrics JSON, /counter form fallback, --workers admission cap, /public comptime embed, /ws upgrade + frame echo, Accept-Encoding gzip.
- Module tests (9 core + 12 server) cover renderer, signals, api_handler, pool, metrics, gzip.

**CI (`.github/workflows/ci.yml`)**
- Matrix: ubuntu-latest + macos-latest
- Steps: `zig fmt --check`, build, test (includes integration), smoke test (curl across all endpoints including `/metrics`, `Accept-Encoding: gzip`, `/api/incrementCount`), scaffold + build + boot a starter project, build with `-Dpublic-dir` and serve embedded files.

---

## Remaining work

Nothing in the original ten-item backlog remains. Future directions if a
consumer arrives: per-action timing histograms, cookie/session helpers,
HTTPS, CSRF tokens, file-upload streaming, a wasm-page-grow allocator
to lift the 16 KB FBA ceiling.

---

## Non-obvious context (saves rediscovery time)

### Zig 0.16 stdlib quirks discovered across sessions

- **`std.fs.cwd` is gone.** Use `std.Io.Dir.cwd()` (needs an `Io` for most operations). Inside `build.zig`, get one from `b.graph.io`.
- **`std.process.Child.init` is gone.** Use `std.process.spawn(io, .{ .argv = ..., .stdout = .ignore, ...})`.
- **`std.posix.socket`, `connect`, `read`, `write` are gone.** Use `std.Io.net.IpAddress.connect(io, .{ .mode = .stream })` → `Stream`, then `stream.writer(io, buf).interface` and `stream.reader(io, buf).interface`.
- **`std.Thread.sleep` is gone.** Use `std.Io.sleep(io, duration, .awake)` where `duration = std.Io.Duration.fromMilliseconds(N)`.
- **`std.Thread.Mutex` / `Condition` are gone.** Only `std.atomic.Mutex` (spin via `tryLock` loop with `std.atomic.spinLoopHint()`) and `std.Io.Mutex` exist. There is *no* condition variable primitive — the bounded admission pool sidesteps this by spawning a detached thread per accepted connection and gating with an atomic counter instead of a queue.
- **`std.http.Server.Request.iterateHeaders` panics if the reader has progressed past `received_head`.** Inspect headers *before* calling `readerExpectContinue` — `RequestMeta.fromRequest` is called once in `src/server/main.zig` before body read and threaded into every downstream handler (including api_handler.dispatch).
- **`BodyWriter.flush()` only flushes the outer writer, not its internal chunk encoder.** For SSE/streaming you have to call both `w.writer.flush()` and `w.flush()`. See `flushBodyWriter` in `src/server/main.zig`.
- **`request.respond` with `keep_alive = true` panics on a 4xx/5xx if the request body was not consumed.** Error responses must set `keep_alive = false`. See `renderError` in `src/server/main.zig`.
- **Anonymous array literals (`&.{...}`) holding runtime values dangle after function return.** Comptime-constant attrs are fine, but if any attr value is allocator-allocated, use `try alloc.alloc(verve.Attr, N)` explicitly.
- **`std.compress.gzip` doesn't exist as a top-level module.** Use `std.compress.flate` with `flate.Container.gzip` to get gzip-framed deflate output. Window buffer must be `flate.max_window_len` (64 KB).
- **`std.http.Server.Request.respondWebSocket` works in 0.16** — pass the `Sec-WebSocket-Key` from `request.upgradeRequested()`. The returned `WebSocket` struct has `readSmallMessage` (blocking, returns opcode + masked-decoded data) and `writeMessage` (auto-flushes after each frame). Writes from multiple threads need external mutex protection.
- **Build-time directory walking** in `build.zig`: `b.build_root.handle.openDir(b.graph.io, dir, .{ .iterate = true })` → `.walk(allocator)` → `walker.next(io)`. `walker.deinit()` takes no arguments.
- **Build.zig.zon `.fingerprint`**: the high 32 bits are name-derived and zig won't accept an arbitrary value. The CLI scaffolder runs `zig build` once in the target dir, parses `use this value: 0x...` from stderr, and patches the zon — works without reverse-engineering the algorithm.

### Verve-specific conventions

- **Zerver action convention:** each action is `fn(args: struct { ... }) Ret`. Param names aren't in `@typeInfo`; struct field names are. Don't try to use multi-param functions — the dispatcher relies on the single-struct-arg shape.
- **Embedded assets path:** `build.zig` does `b.addWriteFiles` → generated `assets.zig` / `public_assets.zig` / `skeleton.zig` (each `pub const ... = @embedFile(...);`) → server / cli modules import those names. Don't try to `@embedFile` the cache-output path directly; it's not stable.
- **Circular import:** `src/app/api.zig` imports `routes.zig`, which imports `api.zig` (for `last_count`). Zig handles it because the cycle resolves through a `pub var` reference, not a declaration.
- **Todo snapshot pattern:** never iterate `todo_slots` from outside `src/app/api.zig`. Always go through `copyTodosInto(arena)` which dupes under lock, so the render path never races a writer.
- **Integration test ports:** each test uses `TEST_PORT + N` (18765 + 0..10) to avoid port reuse between sequential tests.
- **Form-mode + gzip + referer detection happens in `main.zig` *before* body read** (see `api_handler.RequestMeta.fromRequest`). The result is passed into every downstream handler. If you add new header-dependent logic, extend `RequestMeta`; don't iterate headers again later.
- **WebSocket connection life:** each `/ws` connection holds one admission slot for its lifetime. With `--workers 4`, max 4 concurrent WS clients. Reader loop + broadcaster thread share the same connection thread; writes are mutex-guarded.
- **Counter form fallback:** the +/- buttons are wrapped in `<form action="/api/incrementCount" method="POST">`. Without JS the browser submits the form natively and the server's form-mode action dispatch redirects (303) back to `/counter`. With JS, the bridge intercepts the click, calls `preventDefault()`, and either sends a WebSocket text frame (preferred) or invokes the wasm export (fallback).
- **Metrics label cardinality:** comptime-walked from `app.routes` + `app.Actions` + fixed endpoints. Unknown paths fall into `__not_found__`. `/public/*` collapses into one bucket. Adding a new top-level route automatically adds a metrics label.

---

## Quickstart for the next session

```sh
zig version              # expect 0.16.0
zig build                # native server + cli + wasm client
zig build test --summary all   # 32/32 green expected
zig fmt --check build.zig src tests
./zig-out/bin/verve-server --help
./zig-out/bin/verve-server
# Then in a browser:
#   http://127.0.0.1:8080/
#   http://127.0.0.1:8080/counter        ← live-updating via WS (SSE fallback)
#   http://127.0.0.1:8080/todos          ← form fallback, no wasm
#   http://127.0.0.1:8080/health
#   http://127.0.0.1:8080/metrics
#
# Or with static assets + a different port:
#   ./zig-out/bin/verve-server --port 9000 --public-dir ./tests/public_fixture --workers 16
#
# Or with public assets baked into the binary:
#   zig build -Dpublic-dir=./tests/public_fixture
#   ./zig-out/bin/verve-server
#
# Or scaffold a new app:
#   ./zig-out/bin/verve-cli new ~/code/my-app --name=my_app
```

### Key files

| Path | Purpose |
|---|---|
| `build.zig` | Wasm32 → server pipeline; `-Dpublic-dir` option + comptime walker; `verve-server-embed` test target; CLI skeleton manifest generator |
| `src/verve.zig` | Public library entry — re-exports core types |
| `src/core/{node,signal,context,renderer}.zig` | Framework primitives |
| `src/server/main.zig` | HTTP server, accept loop + bounded admission, CLI parser, signal handlers, /health, /metrics, /events, /ws, /public, renderError, renderPage, respondBuffered (single-shot + optional gzip) |
| `src/server/{router,api_handler}.zig` | Page routing + comptime API dispatcher (JSON / form / gzip-accept) |
| `src/server/pool.zig` | Bounded admission (atomic counter + tryAdmit/release) |
| `src/server/metrics.zig` | Per-route count / avg_ns / max_ns + JSON serializer |
| `src/server/gzip.zig` | `std.compress.flate` wrapper with content-type eligibility test |
| `src/server/tests.zig` | Aggregator that imports every server test root |
| `src/client/{main,signal,dom,allocator,render,tests}.zig` | WASM runtime — signals, DOM externs, FixedBufferAllocator over a static heap, escapeHtml helper |
| `src/bridge/verve.js` | DOM externs, delegated click handler, EventSource + WebSocket subscriptions |
| `src/app/{components,api,routes}.zig` | Example application (Counter w/ form fallback, TodoList, Home) |
| `src/cli/main.zig` | `verve-cli new` scaffolder — writes skeleton + auto-fingerprints |
| `tests/integration.zig` | E2E tests (spawn server, hit endpoints, kill) |
| `tests/public_fixture/` | Static files used by --public-dir + -Dpublic-dir integration tests |
| `.github/workflows/ci.yml` | CI matrix (ubuntu + macos) — fmt + build + test + smoke + scaffold + embed |

### Where to start next

Nothing in the closed backlog is open. The framework is at feature parity for the original spec. Future directions are listed under "Remaining work" above.
