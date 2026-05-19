# Example: stopwatch

Pure client-side timer. State lives entirely in the wasm module; the
server delivers the page + wasm + bridge and is never contacted again.

## Run

```sh
cd examples/stopwatch
zig build
./zig-out/bin/stopwatch-server
# Open http://127.0.0.1:8080/
```

Click Start, watch the display tick. Stop pauses it. Reset zeroes it.

## What this demonstrates

- **Custom wasm client** (`src/client/main.zig`) replacing the
  framework's default. The example owns its own export surface
  (`start_stopwatch`, `stop_stopwatch`, `reset_stopwatch`, `tick`,
  `verve_hydrate`).
- **JS-driven tick loop.** Wasm stays timer-agnostic. The bridge runs
  `setInterval(50ms)` and calls `exp.tick(dt_ms)`; wasm decides whether
  to accumulate based on its `running` flag.
- **String formatting from wasm.** Each tick formats `MM:SS.mmm` via
  `std.fmt.allocPrint` over a 4 KB `FixedBufferAllocator`. The
  allocator resets every frame.
- **z-bind reactive updates.** A single `[z-bind="display"]` element
  is rewritten by wasm via `dom.set_text_by_bind`. No DOM diffing,
  no virtual tree — just `textContent` updates.
- **z-on-click click routing.** The bridge's delegated click listener
  looks up `exp[action_name]` and calls it; the buttons say which
  wasm export to fire.

## Files

| Path | Purpose |
|---|---|
| `build.zig`               | Wires the example wasm + bridge (overrides framework defaults) |
| `src/client/main.zig`     | Wasm: state + 4 exports + display emit |
| `src/client/dom.zig`      | Externs from the bridge |
| `src/bridge/verve.js`     | Tick loop + click handler |
| `src/app/{api,components,routes}.zig` | Page structure (no actions) |

## Things to try

- Open devtools, type `exp = wasm.exports` (after instantiation) and
  call `start_stopwatch()` / `stop_stopwatch()` / `reset_stopwatch()`
  manually. No server roundtrip — everything is in the browser.
- Edit `src/client/main.zig` to print elapsed in hours:minutes:seconds
  (the math is one line). Rebuild and reload.
- Watch `/metrics` — only the GET / appears. No `/api/*` traffic
  because the app has no actions.
