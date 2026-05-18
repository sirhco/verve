# Verve — Session Handoff

A working snapshot of where the framework stands and what's left to do, so the next session (or a fresh contributor) can pick up cleanly.

---

## Where we are

**Status: way past MVP. Production-shaped server with reactive client, form fallback, static assets, concurrency, and live server push.**

- Builds and runs on Zig **0.16.0** (no third-party deps).
- 34+ commits ahead of initial scaffold.
- `zig build` → `zig-out/bin/verve-server` (~2.4 MB native binary).
- `zig build test --summary all` → **19/19 green** (9 core + 5 server + 5 integration).
- Single-binary distribution: wasm client + JS bridge are `@embedFile`d.

### What's shipped

**Core library (`src/core/`)**
- `Node`, `Attr` (recursive HTML tree, no VDOM)
- `Signal(T)` with listeners (server-side reactivity)
- `Context` (per-request ArenaAllocator)
- `Renderer.render(writer, node)` streaming to `std.Io.Writer`, with HTML/attribute escaping and void-tag handling

**Server (`src/server/`)**
- `std.http.Server` on `std.Io.net` TCP
- **Per-connection detached worker threads** — accept loop spawns `std.Thread` per accept; concurrent requests fully parallelized
- Comptime route matcher
- Comptime `/api/<fn>` dispatcher walks `@typeInfo(Actions).decls`; supports `void`, `!void`, `T`, `!T` return shapes
- **Dual-mode action dispatch**: JSON bodies (`application/json`) → return `{"ok":true}` or `{"value":...}`; form bodies (`application/x-www-form-urlencoded`) → parse via URL-decoded key=value, return 303 See Other to Referer
- **Streaming SSR** via `respondStreaming` — renderer writes straight to socket, chunked transfer-encoding, no full-body buffering
- **HTML error pages** for 404, 405, 500, 403, 413 (via `components.errorPage`)
- 405 for non-GET on page routes
- **Static assets** at `/public/*` from `--public-dir DIR`; content-type by extension; 4 MB cap; rejects `..` and absolute paths
- **Server-Sent Events** at `/events` — pushes `event: count\ndata: <n>\n\n` every second, chunked
- `/health` endpoint with uptime + (atomic) request count
- `std.log.scoped(.verve)` for all diagnostics (info on access log + lifecycle, err on failures); signal handler + `printUsage` intentionally on `std.debug.print`
- **LISTEN_FDS** env var support: adopts fd 3 as listening socket (systemd activation)
- Graceful shutdown on SIGINT/SIGTERM via `std.posix.sigaction`
- CLI flags: `--host`, `--port` (rejects 0), `--body-limit` (k/m/g suffix), `--public-dir`, `--help`/`-h`
- Unknown-arg detection with discovery hint

**WASM client (`src/client/`)**
- Compiles to wasm32-freestanding, ReleaseSmall
- Current binary size: **565 B** (budget was 30 KB)
- `ClientSignal(T)` generic for multi-bind support
- Two signals shipped: `count` + `clicks` — proves multi-bind end-to-end
- Exports: `verve_hydrate`, `verve_init_count`, `verve_init_clicks`, `increment_counter`, `decrement_counter`, `current_count`
- SSR-to-client state sync: JS bridge auto-matches every `verve_init_<bind>` export to `[z-bind="<bind>"]` text

**JS bridge (`src/bridge/verve.js`)**
- ~80 lines. Streaming `WebAssembly.instantiateStreaming`
- Delegated click listener → wasm export lookup by name
- Auto-scans `verve_init_*` exports for hydration
- **EventSource subscription to `/events`** — mirrors `event: <name>` messages into `[z-bind="<name>"]` text
- Externs: `set_text_by_bind`, `set_text_by_bind_i32`, `post_json_i32`, `console_log_i32`

**Example app (`src/app/`)**
- Counter demo at `/counter` with shared server-side `last_count` (atomic) — live-updates across tabs via SSE
- Distinct Home page at `/` with links to `/counter` and `/todos`
- **TodoList demo at `/todos`** — pure server-rendered, form submissions, no wasm needed. Demonstrates the form-fallback path
- Five Zerver actions: `updateDatabase(new_count: i32)`, `logMessage(text: []const u8)`, `getCount() i32`, `addTodo(text: []const u8)`, `removeTodo(index: usize)`
- Todo storage = fixed pool (32 × 200 B) guarded by `std.atomic.Mutex` spin-lock

**Tests (`tests/integration.zig` + module tests)**
- Boots `verve-server` as subprocess via `std.process.spawn`, talks raw TCP via `std.Io.net`, kills via `Child.kill`
- 5 integration tests:
  1. Basic endpoint coverage (`/`, `/counter`, `/missing`, POST 405, `/health`, `/client.wasm`)
  2. Form-encoded `/api/addTodo` + `/api/removeTodo` updates `/todos`
  3. **Concurrent** `addTodo` (16 OS threads in parallel, all 16 items survive)
  4. `--public-dir` serves `/public/*` with traversal protection
  5. `/events` SSE emits initial count and live updates
- Fixture dir: `tests/public_fixture/{hello.txt,style.css}`

**CI (`.github/workflows/ci.yml`)**
- Matrix: ubuntu-latest + macos-latest
- Steps: `zig fmt --check`, build, test (includes integration), broadened smoke (hits `/todos`, `/public/*`, form-encoded POST, 404)

---

## Remaining work

Three categories: blocked, premature, or substantial. Items not picked up are listed here in priority order — none are urgent.

### Documentation (blocked unless explicitly requested)

1. **README.** Repo still has no project documentation. Should explain what Verve is, how to build, how to write a component, the Zerver/Action convention, and the runtime surface (pages, /api, /public, /events, /health, env vars).
   *Why not done in last session:* the assistant's system prompt forbids creating `*.md` files without an explicit user request. Backlog inclusion was treated as indirect. Say the word and it gets written.

### Substantial new features

2. **WebSocket support.** SSE is one-way; bidirectional needs `std.http.Server.Request.respondWebSocket`. Worth adding for actions that need to push and receive without polling.
3. **CLI scaffolder (`verve-cli new my-app`).** Generates a starter project. Needs a design choice: embed Verve sources, depend on a git-cloned copy, or use a Zig package URL. Probably wait until Zig package distribution stabilizes a bit more.
4. **Comptime-embedded `/public/*` for production builds.** Today's `--public-dir` is a runtime disk read. Add a build flag that uses `b.addWriteFiles` + a manifest so files are baked into the binary like the wasm/JS pair.
5. **Form fallback for the Counter page.** Counter currently only updates server state via wasm. Wrap the +/- buttons in `<form action="/api/incrementCount">` (new action) so they work without JS. Pairs with `addTodo`-style action design.

### Premature (wait for a consumer)

6. **WASM allocator.** Client currently has none. Once a component needs client-side state beyond fixed-size primitives (strings, lists), wire `FixedBufferAllocator` over a static `var heap: [N]u8` or implement a wasm-page-grow allocator.
7. **`Renderer.escapeHtml` in WASM path.** Server already escapes; client uses `set_text_by_bind` which the JS bridge writes via `textContent` (safe). If the client ever generates HTML strings directly, escape there too.

### Quality / hardening

8. **Thread-pool with bounded workers.** Current model spawns one OS thread per connection (detached). Trivially DoS-able. Replace with a bounded pool: N workers fetching from a thread-safe queue. `std.Thread.spawn` is the only primitive in 0.16; you'll need a hand-rolled mutex + condvar queue.
9. **Per-action timing / metrics.** Add latency histograms per route, expose at `/metrics` in Prometheus format.
10. **Compression.** `Accept-Encoding: gzip` for HTML/JS/wasm responses. Wasm is already small but the JS bridge + page HTML benefit.

---

## Non-obvious context (saves rediscovery time)

### Zig 0.16 stdlib quirks discovered this session

- **`std.process.Child.init` is gone.** Use `std.process.spawn(io, .{ .argv = ..., .stdout = .ignore, ...})` which returns a `Child`. Spawning requires `std.Io`.
- **`std.posix.socket`, `connect`, `read`, `write` are gone.** Use `std.Io.net.IpAddress.connect(io, .{ .mode = .stream })` → `Stream`, then `stream.writer(io, buf).interface` and `stream.reader(io, buf).interface`.
- **`std.Thread.sleep` is gone.** Use `std.Io.sleep(io, duration, .awake)` where `duration = std.Io.Duration.fromMilliseconds(N)`.
- **`std.Thread.Mutex` is gone.** Two replacements: `std.Io.Mutex` (proper blocking, requires `Io` to lock — not usable from Action functions that don't get `Io`), and `std.atomic.Mutex` (enum with only `tryLock`/`unlock` — spin-lock in a `tryLock` loop with `std.atomic.spinLoopHint()`).
- **`std.http.Server.Request.iterateHeaders` panics if the reader has progressed past `received_head`.** Inspect headers *before* calling `readerExpectContinue` — see how `RequestMeta.fromRequest` is called in `src/server/main.zig` before body read.
- **`BodyWriter.flush()` only flushes the outer writer, not its internal chunk encoder.** For SSE/streaming you have to call both `w.writer.flush()` (serializes the chunk into `http_protocol_output`) *and* `w.flush()` (pushes `http_protocol_output` to TCP). See `flushBodyWriter` in `src/server/main.zig`.
- **`request.respond` with `keep_alive = true` panics on a 4xx/5xx if the request body was not consumed.** Error responses must set `keep_alive = false`. See `renderError` in `src/server/main.zig`.
- **Anonymous array literals (`&.{...}`) holding runtime values dangle after function return.** Comptime-constant attrs are fine (Zig promotes them to static), but if any attr value is allocator-allocated, use `try alloc.alloc(verve.Attr, N)` explicitly. Burned us in `components.todoList` once already.

### Verve-specific conventions

- **Zerver action convention:** each action is `fn(args: struct { ... }) Ret`. Param names aren't in `@typeInfo`; struct field names are. Don't try to use multi-param functions — the dispatcher relies on the single-struct-arg shape.
- **Embedded assets path:** `build.zig` does `b.addWriteFiles` → generated `assets.zig` (`pub const wasm = @embedFile("client.wasm");` etc.) → server module imports `"assets"`. This works because `wf.getDirectory()` returns a `LazyPath` and the server module's build step depends on it transitively. Don't try to `@embedFile` the cache-output path directly; it's not stable.
- **Circular import:** `src/app/api.zig` imports `routes.zig`, which imports `api.zig` (for `last_count`). Zig handles it because the cycle resolves through a `pub var` reference, not a declaration. Be careful adding decls that would break the cycle.
- **Todo snapshot pattern:** never iterate `todo_slots` from outside `src/app/api.zig`. Always go through `copyTodosInto(arena)` which dupes under lock, so the render path never races a writer.
- **Integration test ports:** each test uses `TEST_PORT + N` (18765 + 0..4) to avoid port reuse between sequential tests in the same process. The integration test module spawns a fresh server per test.
- **Form-mode detection happens in `main.zig` *before* body read** (see `api_handler.RequestMeta.fromRequest`). The result is passed into `dispatch` as a struct. If you add new header-dependent logic, do the same — extract before body read.

---

## Quickstart for the next session

```sh
zig version              # expect 0.16.0
zig build                # native server + wasm client
zig build test --summary all   # 19/19 green expected
zig fmt --check build.zig src tests
./zig-out/bin/verve-server --help
./zig-out/bin/verve-server
# Then in a browser:
#   http://127.0.0.1:8080/
#   http://127.0.0.1:8080/counter        ← live-updating via SSE
#   http://127.0.0.1:8080/todos          ← form fallback, no wasm
#
# Or with static assets + a different port:
#   ./zig-out/bin/verve-server --port 9000 --public-dir ./tests/public_fixture
```

### Key files

| Path | Purpose |
|---|---|
| `build.zig` | Dual pipeline: wasm32 → server (@embedFile via addWriteFiles); injects integration test fixture path |
| `src/verve.zig` | Public library entry — re-exports core types |
| `src/core/{node,signal,context,renderer}.zig` | Framework primitives |
| `src/server/main.zig` | HTTP server, per-conn threading, CLI parser, signal handlers, banner, /public, /events, /health, renderError, renderPage |
| `src/server/{router,api_handler}.zig` | Page routing + comptime API dispatcher (handles both JSON and form bodies) |
| `src/client/{main,signal,dom}.zig` | WASM runtime |
| `src/bridge/verve.js` | JS shim — DOM externs, delegated click listener, EventSource subscription |
| `src/app/{components,api,routes}.zig` | Example application (Counter, TodoList, Home, 404 + error pages) |
| `tests/integration.zig` | E2E tests (spawn server, hit endpoints, kill) |
| `tests/public_fixture/` | Static files used by the `--public-dir` integration test |
| `.github/workflows/ci.yml` | CI matrix (ubuntu + macos), fmt check + build + test + smoke |

### Where to start

If you can only do one thing next session, **write the README** (item #1 above) — it's the single biggest gap from a contributor / user perspective and unblocks getting eyes on the project. The runtime is well past the point where a `README.md` is overdue.

Second priority: **bounded thread pool** (item #8). Detached `Thread.spawn` per accept is functional but DoS-able and not the right shape for production. Bonus: it forces a clean exit path that the current `accept`-forever loop dodges.
