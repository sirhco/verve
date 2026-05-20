# 12 — WASM client

The browser-side runtime. ~650 bytes of wasm + ~100 lines of JS bridge.
Compiles from `src/client/` against `wasm32-freestanding`, optimized
for size.

## Surface

| Module | Purpose |
|---|---|
| `src/client/main.zig`      | Exported wasm symbols + signal wiring |
| `src/client/signal.zig`    | `ClientSignal(T)` generic |
| `src/client/dom.zig`       | Externs supplied by the JS bridge |
| `src/client/allocator.zig` | Fixed-buffer allocator over a static heap |
| `src/client/render.zig`    | `escapeHtml` wrapped against the FBA |
| `src/bridge/verve.js`      | Boot, hydrate, DOM ↔ wasm glue |

## Exports

What the wasm module exposes to JS:

```
verve_hydrate()                  re-emit current signal values
verve_init_count(value: i32)     seed `count` signal from SSR'd DOM
verve_init_clicks(value: i32)    seed `clicks` signal
increment_counter()              count.increment(); clicks.increment(); POST /api/updateDatabase
decrement_counter()              count.decrement(); clicks.increment();
current_count() i32              count.get()
verve_alloc_used() u32           FBA bytes consumed
verve_alloc_capacity() u32       FBA total bytes
verve_alloc_reset()              FBA reclaim
```

The bridge enumerates these on boot:

```js
for (const name of Object.keys(exp)) {
  const m = /^verve_init_(.+)$/.exec(name);
  if (!m || typeof exp[name] !== "function") continue;
  const el = document.querySelector(`[z-bind="${CSS.escape(m[1])}"]`);
  if (!el) continue;
  const n = parseInt(el.textContent, 10);
  if (!Number.isNaN(n)) exp[name](n | 0);
}
if (typeof exp.verve_hydrate === "function") exp.verve_hydrate();
```

So any wasm module that adds a `verve_init_<bind>` export is auto-hydrated
from its matching DOM element.

## Externs

Strings pass as `(ptr, len)` pairs since wasm32 has no native string type:

```zig
// src/client/dom.zig
pub extern "verve" fn set_text_by_bind(bp: [*]const u8, bl: usize, tp: [*]const u8, tl: usize) void;
pub extern "verve" fn set_text_by_bind_i32(bp: [*]const u8, bl: usize, value: i32) void;
pub extern "verve" fn post_json_i32(pp: [*]const u8, pl: usize, fp: [*]const u8, fl: usize, value: i32) void;
pub extern "verve" fn console_log_i32(value: i32) void;
```

Each lands in `env.verve.<name>` on the JS side:

```js
const env = {
  verve: {
    set_text_by_bind: (bp, bl, tp, tl) => setTextByBind(readStr(bp, bl), readStr(tp, tl)),
    set_text_by_bind_i32: (bp, bl, v) => setTextByBind(readStr(bp, bl), String(v | 0)),
    post_json_i32: (pp, pl, fp, fl, v) => fetch(readStr(pp, pl), {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ [readStr(fp, fl)]: v | 0 }),
    }).catch(/* swallow */),
    console_log_i32: (v) => console.log("verve:", v | 0),
  },
};
```

Adding a new extern is symmetric:

1. Declare `pub extern "verve" fn my_helper(...) void;` in
   `src/client/dom.zig`.
2. Add the implementation to `env.verve` in `src/bridge/verve.js`.
3. Call `dom.my_helper(...)` from your wasm code.

## ClientSignal

```zig
// src/client/signal.zig
pub fn ClientSignal(comptime T: type) type {
    return struct {
        bind: []const u8,
        value: T,

        pub fn init(bind: []const u8, initial: T) Self { ... }
        pub fn get(self: *const Self) T { ... }
        pub fn set(self: *Self, new_value: T) void {
            self.value = new_value;
            emit(T, self.bind, new_value);
        }
        pub fn increment(self: *Self) void { self.set(self.value + 1); }
        pub fn decrement(self: *Self) void { self.set(self.value - 1); }
    };
}

fn emit(comptime T: type, bind: []const u8, value: T) void {
    if (T == i32) {
        dom.set_text_by_bind_i32(bind.ptr, bind.len, value);
        return;
    }
    @compileError("ClientSignal: unsupported value type " ++ @typeName(T));
}
```

Only `i32` is wired. Adding `[]const u8` is a few lines:

```zig
fn emit(comptime T: type, bind: []const u8, value: T) void {
    if (T == i32) { dom.set_text_by_bind_i32(bind.ptr, bind.len, value); return; }
    if (T == []const u8) { dom.set_text_by_bind(bind.ptr, bind.len, value.ptr, value.len); return; }
    @compileError("ClientSignal: unsupported value type " ++ @typeName(T));
}
```

Then in your wasm:

```zig
var status = ClientSignal([]const u8).init("status", "");

export fn say_hello() void {
    status.set("Hello from wasm!");
}
```

## Growable bump allocator

`src/client/allocator.zig` is a growable bump arena over linear
memory:

```zig
// src/client/allocator.zig — abridged
pub const MAX_HEAP: usize = 16 * 1024 * 1024;

pub fn allocator() std.mem.Allocator { … }
pub fn reset() void { /* rewinds bump pointer */ }
pub fn bytesUsed() usize { … }
pub fn capacity() usize { … }
```

The allocator anchors at the end of statically-reserved wasm memory
(via `@wasmMemorySize`) and grows by 64 KB pages on demand
(`@wasmMemoryGrow`) up to `MAX_HEAP`. No free list; `reset()` rewinds
the bump pointer in O(1) — call it between render passes when the
previous frame's buffers are unreachable. Memory is never returned
to the wasm host (decommit isn't supported by `memory.grow`).

Native builds (running client unit tests on the host) fall back to a
static `MAX_HEAP`-sized buffer since `@wasmMemoryGrow` is wasm-only.

Diagnostic exports surface allocator state to JS:

```js
const used = exp.verve_alloc_used();
const cap = exp.verve_alloc_capacity();
console.log(`wasm heap: ${used}/${cap}`);
exp.verve_alloc_reset();
```

For very large client-side state (megabytes), pre-grow at startup by
making one large allocation immediately; subsequent allocations
inside the reserved region won't trigger further grows.

## NodeRef hydration (Phase 8 roadmap)

`ctx.nodeRef(.input, "email")` emits `data-ref="email"` on the
server-rendered HTML. The client-side runtime exposes
`verveQueryRef("email") -> ?Element` so wasm effects can resolve a
typed handle to the live DOM node. The Phase 8 hydration loader will
walk `<verve-island>` markers and invoke per-island wasm bundles that
read these refs to attach handlers + subscribe to reactive state.

Phase 7 ships the marker emission only — the Phase 8 loader and
per-island bundling are the next round of work on the client side.

## Escape helper

```zig
// src/client/render.zig
pub fn escapeHtmlAlloc(unsafe: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(client_alloc.allocator());
    errdefer aw.deinit();
    try verve.escapeHtml(&aw.writer, unsafe);
    return aw.toOwnedSlice();
}

pub fn escapeHtmlAllocWith(gpa: std.mem.Allocator, unsafe: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try verve.escapeHtml(&aw.writer, unsafe);
    return aw.toOwnedSlice();
}
```

When wasm code assembles an HTML fragment to inject via a
hypothetical `set_inner_html_by_bind` extern, route the user-supplied
parts through `escapeHtmlAlloc` first. The framework's textContent
extern (`set_text_by_bind`) already escapes natively in the browser
— so for plain-text updates you don't need this helper.

## Build pipeline

```zig
// build.zig (excerpt)
const client_mod = b.createModule(.{
    .root_source_file = b.path("src/client/main.zig"),
    .target = wasm_target,                  // wasm32-freestanding
    .optimize = .ReleaseSmall,
    .imports = &.{ .{ .name = "verve", .module = verve_mod } },
});
const wasm = b.addExecutable(.{ .name = "client", .root_module = client_mod });
wasm.entry = .disabled;                     // no _start in wasm
wasm.rdynamic = true;                       // export everything pub'd
```

After `zig build`, the compiled wasm is copied into a write-files dir
along with `bridge/verve.js`, and a manifest `assets.zig` is generated
with `@embedFile` references the server imports as the `assets`
module. The single server binary contains both client and bridge.

## Binary size budget

```
$ ls -la zig-out/bin/verve-server
~3.1 MB
# of which the wasm client is ~650 B and the JS bridge is ~3.8 KB
```

The server includes the whole framework stdlib build, so 3 MB is most
of it. The wasm client itself is tiny: a few hundred bytes of code +
exports.

## Native testing

Client modules participate in `zig build test`:

```zig
// src/client/tests.zig
test {
    _ = @import("allocator.zig");
    _ = @import("render.zig");
}
```

`build.zig` compiles them against the native target — every algorithm
in `client/` is platform-agnostic, so unit tests work without a wasm
runtime. Tests assert FBA capacity / reset / OOM and escapeHtml on
entity-bearing strings.

To exercise the wasm-running path, the integration tests load
`/client.wasm` over HTTP and verify it parses; deeper behaviour is
covered by Playwright-style tests in apps that consume the framework.

## Next

- [Index](README.md) — full doc tree.
- [Examples](../examples/README.md) — three running apps.
