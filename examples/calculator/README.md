# Example: calculator

Four-function calculator. Two registers, one pending op, IEEE-754
double-precision math, all in wasm. Click buttons or use the keyboard.

## Run

```sh
cd examples/calculator
zig build
./zig-out/bin/calculator-server
# Open http://127.0.0.1:8080/
```

Tap digits, ops, equals. Keyboard works too: `0-9`, `+`, `-`, `*`,
`/`, `=` / Enter, `Esc` / `c` (clear).

## What this demonstrates

- **Many small wasm exports.** One export per digit (`digit_0` ...
  `digit_9`), one per op (`op_add`, `op_sub`, `op_mul`, `op_div`),
  plus `op_equals` and `clear`. The bridge's delegated click handler
  maps `z-on-click` attribute values directly to export names.
- **f64 math inside wasm.** `current = lhs / current` with a
  divide-by-zero guard that flips an `error_state` flag and renders
  "Err".
- **Single shared display.** `[z-bind="display"]` updated from every
  export via `dom.set_text_by_bind`. Wasm formats with
  `std.fmt.allocPrint` against a 4 KB FBA.
- **Comptime-built keypad.** `KeyDef` array iterated by the page
  renderer to emit 16 buttons; adding a row is one entry plus a CSS
  tweak.
- **Keyboard ↔ click parity.** The bridge listens for `keydown`
  and dispatches to the same wasm exports as the click handler.
  Wasm doesn't know whether the input came from mouse or keyboard.

## Files

| Path | Purpose |
|---|---|
| `build.zig`               | Wires the example wasm + bridge |
| `src/client/main.zig`     | State + dispatch helpers + 16 exports |
| `src/client/dom.zig`      | Externs (just `set_text_by_bind`) |
| `src/bridge/verve.js`     | Click handler + keyboard shortcuts |
| `src/app/{api,components,routes}.zig` | Page chrome + keypad layout |

## Things to try

- Press `1`, `+`, `2`, `*`, `3`, `=`. The current implementation
  evaluates left-to-right (no precedence) — so you get `(1+2)*3 = 9`.
  Note: change to standard precedence by extending the state machine
  in `src/client/main.zig:pressOp`.
- Press `1`, `/`, `0`, `=` to see the "Err" path.
- Add decimal-point handling — add `decimal_point` export and a `.`
  button, track a `decimal_place: u8` field that scales the current
  digit.
- Watch the wasm binary size when you optimize the layout: switching
  the 10 `digit_N` exports to a single `digit(n: u32)` export shrinks
  the binary noticeably.
