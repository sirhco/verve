# Example: keystrokes

Counts every keystroke and shows the last key pressed. Demonstrates
**JS → wasm string passing via shared memory** — the cleanest pattern
for non-trivial data transfer across the wasm boundary.

## Run

```sh
cd examples/keystrokes
zig build
./zig-out/bin/keystrokes-server
# Open http://127.0.0.1:8080/
```

Tap keys (or hold one down). Each keydown bumps the counter and the
"Last key" panel shows the latest character.

## What this demonstrates

- **Shared-memory string transfer.** Wasm owns a `var key_buf:
  [32]u8` and exports `key_buffer_ptr()` / `key_buffer_len()`. The
  bridge:
  ```js
  const keyBufPtr = exp.key_buffer_ptr();
  const keyBufLen = exp.key_buffer_len();
  const view = new Uint8Array(memory.buffer, keyBufPtr, keyBufLen);
  view.set(bytes.subarray(0, n));  // write UTF-8 into wasm
  exp.record_key(n);               // commit
  ```
  No allocator dance, no double-copy. JS writes directly into wasm's
  linear memory.
- **Two `[z-bind]` targets driven from one export.** `record_key`
  re-emits both `total` (an i32 counter) and `last` (a string
  view into the shared buffer).
- **Mixing `set_text_by_bind_i32` and `set_text_by_bind`.** Integer
  bind for counters; string bind for the key character. Both externs
  come from the framework's standard surface.
- **The wasm binary is tiny.** ~440 bytes — no `std.fmt`, no
  allocator (the counter is a plain `u32 +%= 1`).
- **Document-level event capture.** No need to focus an input field
  — the bridge listens at the document level so any keydown fires.

## Files

| Path | Purpose |
|---|---|
| `build.zig`               | Wires the example wasm + bridge |
| `src/client/main.zig`     | Counter + buffer + 4 exports |
| `src/client/dom.zig`      | Externs |
| `src/bridge/verve.js`     | Keydown listener + memory write |
| `src/app/{api,components,routes}.zig` | Page chrome + bound displays |

## Things to try

- Inspect the wasm memory in devtools: `wasm.instance.exports.memory.buffer`
  is a regular `ArrayBuffer`. You can read/write it from JS the same
  way the bridge does.
- Press a multi-byte key like Arabic, Cyrillic, or an emoji. The
  TextEncoder produces multi-byte UTF-8; wasm just stores raw bytes
  and the browser renders them via `textContent` correctly.
- Add a histogram: track which characters appear most often. A 256-byte
  array indexed by the first byte is enough for ASCII frequency.
- Bump `KEY_BUF_LEN` to handle longer paste strings, then add a
  bridge listener for `paste` events that writes the clipboard content
  in one go.
