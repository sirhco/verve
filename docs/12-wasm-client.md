# 12 — WASM client

The browser-side runtime. ~4 KB of wasm + the JS bridge.
Compiles from `src/client/` against `wasm32-freestanding`, optimized
for size. Hosts the same `Signal` / `Effect` / `Owner` graph the
server uses — DOM updates are a *consequence* of `Signal.set`, not
a parallel write path.

## Surface

| Module | Purpose |
|---|---|
| `src/client/verve_client.zig` | Public façade for downstream wasm clients — re-exports `Signal` / `Effect` / `Owner` + `registerI32` / `registerStr` / `registerBool` / `registerF32` + `bindForEach` |
| `src/client/main.zig`      | Exported wasm symbols + per-bind Signal wiring |
| `src/client/runtime.zig`   | `registerI32` / `registerStr` / `registerBool` / `registerF32` + `ForEachHandle` + `bindForEach` |
| `src/client/reconciler.zig`| LIS-based keyed-list planner. See [17 — Reconciler](17-reconciler.md). |
| `src/client/island.zig`    | Per-binary island dispatch + registry |
| `src/client/signal.zig`    | Legacy `ClientSignal(T)` — kept for pre-Phase-12 callers |
| `src/client/dom.zig`       | Externs supplied by the JS bridge + native no-op stubs |
| `src/client/allocator.zig` | Growable bump allocator — long-lived state (Signals, Owner, key caches) |
| `src/client/scratch.zig`   | Fixed 256 KB scratch bump — reset between effect re-runs |
| `src/client/islands/`      | Per-island chunk sources (`<Name>.zig` or fallback `_default.zig`) |
| `src/client/render.zig`    | `escapeHtml` wrapped against the long-lived allocator |
| `src/bridge/verve.js`      | Boot, hydrate, DOM ↔ wasm glue, island chunk loader, `verveSwap` |

## Reactive runtime

The WASM client allocates a root `Owner` lazily over the bump
allocator and registers one `verve.Signal(T)` per `[data-vh="<name>"]`
binding the server rendered. Each Signal's `on_set` hook fires into
a DOM primitive — `set_text_by_bind_i32`, `set_class_present_by_bind`,
`set_text_by_bind_f32`, `set_text_by_bind_str`, … — so any
`signal.set(value)` mutation lands in the DOM through the existing
reactive graph rather than a parallel write path.

```zig
// src/client/main.zig
const count_sig = runtime.registerI32("count", count_initial);

export fn increment_counter() void {
    count_sig.?.set(count_sig.?.peek() + 1);   // → on_set → DOM
}
```

Available registrars:

| Function | Signal type | DOM effect |
|---|---|---|
| `runtime.registerI32(name, initial)` | `Signal(i32)` | Replaces text content via `set_text_by_bind_i32` |
| `runtime.registerStr(name, initial)` | `Signal([]const u8)` | Replaces text content via `set_text_by_bind_str` |
| `runtime.registerBool(name, class, initial)` | `Signal(bool)` | Toggles `class` via `set_class_present_by_bind` |
| `runtime.registerF32(name, initial)` | `Signal(f32)` | Replaces text content via `set_text_by_bind_f32` |
| `runtime.registerForEach(parent, initial_keys)` | `*ForEachHandle` | Reconciler-driven keyed children — see [17 — Reconciler](17-reconciler.md) |
| `runtime.bindForEach(handle, ctx, render_fn)` | `*verve.Effect` | Re-runs `render_fn` and calls `handle.update` on any tracked Signal change |
| `runtime.autoHydrate(bindings)` | — | Batch-register a declarative slice of `Binding { name, initial }` entries. Mixes i32 / str / bool / f32 freely. |

`autoHydrate` is the recommended entry point for apps with more than
a handful of bindings — collapses the per-bind `register*` calls into
one declarative slice:

```zig
export fn verve_hydrate() void {
    verve.autoHydrate(&.{
        .{ .name = "count", .initial = .{ .i32 = initial_count } },
        .{ .name = "label", .initial = .{ .str = initial_label } },
        .{ .name = "open",  .initial = .{ .bool = .{ .class = "is-open", .value = false } } },
        .{ .name = "ratio", .initial = .{ .f32 = 0.0 } },
    });
}

export fn click_handler() void {
    if (verve.signalI32("count")) |c| c.increment();
}
```

Initial values come from caller-controlled state — the
`verve_init_<name>(value)` walker remains the recommended way to
source them from the server-rendered DOM.

## Closure-style event handlers

Alternative to the string-named `[z-on-click="exportName"]` dispatch.
Register a `*const fn () void` against the runtime, receive a `u32`
slot id, stamp it on the node with `.onClickFn(id)`:

```zig
const verve = @import("verve");

const Handlers = struct {
    fn bump() void {
        if (verve.signalI32("count")) |c| c.increment();
    }
};

var bump_id: u32 = 0;

export fn verve_hydrate() void {
    verve.autoHydrate(&.{ .{ .name = "count", .initial = .{ .i32 = 0 } } });
    bump_id = verve.registerEvent(Handlers.bump);
}
```

```zig
// components.zig — render-time
ctx.button().onClickFn(bump_id).text("+").build()
```

The renderer stamps `z-on-click-id="<id>"`; the bridge JS click
delegate dispatches it through the exported `verve_event_dispatch(id)`
function which invokes the registered fn pointer. Closure handlers
keep whatever state they captured at registration — no flat-namespace
export name required.

Both flavors coexist: `[z-on-click]` and `[z-on-click-id]` can land on
the same node, with id-style winning. The id table holds up to 256
entries (raise `MAX_EVENT_SLOTS` in `runtime.zig` if a real app
needs more).

## Consuming from a downstream app

Downstream wasm clients (the desktop template, future browser-only
apps) pull the same reactive surface via the public `verve_client`
module. The module re-exports the primitives from `verve` plus the
DOM-wired adapter from `src/client/runtime.zig` — same shape the
framework's own `client.wasm` uses internally.

```zig
// templates/desktop/build.zig
const verve_dep = b.dependency("verve", .{ ... });
const verve_client_mod = verve_dep.module("verve_client");

const client_mod = b.createModule(.{
    .root_source_file = b.path("src/client/main.zig"),
    .target = wasm_target,
    .optimize = .ReleaseSmall,
    .imports = &.{
        .{ .name = "verve", .module = verve_client_mod },
    },
});
```

```zig
// src/client/main.zig (downstream)
const verve = @import("verve");

var count_sig: ?*verve.Signal(i32) = null;
var initial_count: i32 = 0;

export fn verve_init_count(v: i32) void { initial_count = v; }

export fn verve_hydrate() void {
    count_sig = verve.registerI32("count", initial_count);
}

export fn increment_counter() void {
    if (count_sig) |c| c.increment();   // → on_set → DOM
}
```

The bridge JS must provide the DOM externs the adapter calls
(`set_text_by_bind_i32`, `set_class_present_by_bind`, the keyed-list
primitives, …). `templates/desktop/frontend/verve_desktop.js` is the
reference port; `src/bridge/verve.js` is the framework's own full
implementation.

## Exports

What the wasm module exposes to JS:

```
verve_hydrate()                       allocate Signal slots, hook on_set callbacks
verve_init_<bind>(value: i32)         seed the named bind from SSR'd DOM text
verve_set_count(value: i32)           drive `count` through the reactive graph (WS push)
increment_counter / decrement_counter app actions
current_count() i32                   peek the count Signal
verve_alloc_used / verve_alloc_capacity / verve_alloc_reset
                                      growable bump heap introspection
verve_scratch_used / verve_scratch_capacity
                                      256 KB scratch region introspection
verve_island_count() u32              number of entries in the build-time manifest
verve_island_scratch_ptr() u32        shared scratch base address for per-island chunks
verve_island_scratch_capacity() u32   shared scratch size
verve_island_dispatch(name_len, props_len) i32
                                      in-process island dispatch — returns 1 when a
                                      hydrator was registered for the named island, 0 otherwise
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
