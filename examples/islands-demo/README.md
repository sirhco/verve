# islands-demo

A minimal Verve example that exercises the island stack end-to-end. The `/` route places **two** independent `Counter` islands from the same component:

| Instance | `initial` | `label` | `seed` | Starting value |
|---|---|---|---|---|
| A | `3` | `"Clicks"` | `100` | **103** |
| B | `50` | `"Taps"` | `0` | **50** |

Each island's per-island WASM chunk decodes **typed props** (`encodeProps`/`decodeProps`), reads **island resource-state** (`ctx.islandState` / `islandStateValue`), seeds a reactive `counter` signal to `initial + seed`, fills a `data-ref` label from props, and registers a **chunk-side closure event handler** wired to the `+` button (via `registerEvent` → `z-on-click-id`) that increments the signal. The two islands share the bind-name `"counter"` in source; the framework suffixes each with its own vid (`counter__v1`, `counter__v2`, …) so clicking one increments only that instance.

`/plain` is a plain SSR page with no island. Run with `zig build run` (serves on the default port; open `/`).
