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
- <http://127.0.0.1:8080/health> — JSON liveness probe
- <http://127.0.0.1:8080/metrics> — JSON per-route latency

Stop the server with `Ctrl-C` (SIGINT) or `kill -TERM <pid>` — both
trigger a clean shutdown.

## Run the tests

```sh
zig build test --summary all
# Build Summary: 16/16 steps succeeded; 37/37 tests passed
```

The suite covers:

- **Core** — node tree, signal, context, renderer (9 tests)
- **Server** — api_handler dispatch, pool admission, metrics, gzip (12 tests)
- **Client** — wasm allocator, escape helpers on native target (5 tests)
- **Integration** — spawns `verve-server` and hits every endpoint (11 tests)

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
pub const routes: []const Route = &.{
    .{ .path = "/", .render = renderHome },
    .{ .path = "/counter", .render = renderCounter },
    .{ .path = "/todos", .render = renderTodos },
    .{ .path = "/hello", .render = renderHello },   // <— new
};

fn renderHello(ctx: *const verve.Context) !*verve.Node {
    return components.page(ctx, ctx.h1("Hello, Verve!"));
}
```

Rebuild + reload — your route is live. No restart shortcuts, no
codegen, no macros. Just a struct field in a comptime table.

## Next

- [02 — Component model](02-components.md) — how the renderer turns
  `Node` trees into HTML.
- [03 — Actions](03-actions.md) — how `pub fn` becomes `POST /api/<fn>`.
