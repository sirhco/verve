# 15 — Islands

Islands are opt-in hydration boundaries: zero JS by default, with
selected subtrees marked for client-side reactivity. Each declared
island ships its own WASM chunk fetched on demand. Chunks import
linear memory from the main `client.wasm`, so adding islands
doesn't multiply the runtime bytes the browser downloads.

## Marker API

```zig
return verve.island(ctx, .{
    .name = "Counter",
    .props = "{\"initial\":7}",
}, try counterInline(ctx, 7));
```

Server renders the inline HTML (for search engines + noscript
clients), then wraps it in a `<verve-island>` custom element
carrying the component name + JSON-serialized props:

```html
<verve-island data-name="Counter" data-props='{"initial":7}'>
  <div class="counter">7</div>
</verve-island>
```

The wrapper costs ~20 bytes of HTML per island — cheap enough to add
to every interactive subtree.

`IslandOpts`:

| Field | Default | Notes |
|---|---|---|
| `name`    | required | Component identifier. Must match a `pub const <Name>` in `src/app/islands.zig` for the chunk to ship. |
| `props`   | `""`     | Pre-encoded props blob. Caller chooses JSON, the binary codec (`verve.encode`), or something else. |
| `state_id`| `null`   | Optional reference to a pre-resolved Resource's state slot. |
| `hydrate` | `true`   | When false the wrapper is skipped — pure SSR subtree, useful for build-time A/B. |

## Declaring an island

Each island gets a `pub const <Name> = struct { ... }` in
`src/app/islands.zig`. `build.zig` parses the file at configure
time and fans WASM chunks out across every top-level decl:

```zig
// src/app/islands.zig
pub const Counter = struct {
    pub const props_schema: []const u8 = "{\"initial\":\"i32\"}";
};

pub const Greeting = struct {
    pub const props_schema: []const u8 = "{\"name\":\"string\"}";
};
```

`props_schema` is metadata only today — the Phase 13F binary codec
will read it to type-check `data-props` decoding. The schema isn't
required for the chunk to ship.

## Custom per-island logic

Each chunk's source lives at `src/client/islands/<Name>.zig`. When
that file is absent the chunk falls back to the shared
`src/client/islands/_default.zig` stub. A chunk source exports a
`hydrate` entry point plus any click / submit / etc. handlers it
needs:

```zig
// src/client/islands/Counter.zig
const verve = @import("verve");

const BIND: []const u8 = "counter_island";

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;
    // Register the per-island Signal in the main runtime's slot
    // table. Its `on_set` hook wires straight to the matching
    // `[z-bind="counter_island"]` element via the JS bridge.
    verve.registerI32(BIND, 0);
}

export fn counter_island_bump() void {
    verve.signalSetI32(BIND, verve.signalGetI32(BIND) + 1);
}
```

The chunk runs *after* the universal `data-vh` walker in the main
`client.wasm` has already hydrated every reactive span inside the
island. `hydrate` is the place island-specific bring-up lives —
multi-step initialization, prop-driven Signal seeding, custom
event handlers that aren't expressible via `[z-on-click]`.

### Chunk-side `verve` API

The `verve` module imported above is the chunk-side façade at
`src/client/island_runtime.zig`. It carries `extern "verve_runtime"
fn ...` declarations the bridge JS resolves against the main client's
exports at instantiation. Surface:

| Function | Purpose |
|---|---|
| `registerI32` / `registerStr` / `registerBool` / `registerF32` | Allocate a Signal under the main runtime's root Owner |
| `signalSetI32` / `Str` / `Bool` / `F32` | Lookup-by-name + `Signal.set` (no-op on miss) |
| `signalGetI32` / `Bool` / `F32` / `Str(name, buf)` / `signalGetStrLen` | Lookup-by-name + `Signal.peek` (zero / empty on miss) |
| `queryRef(ref)` | Resolve `data-ref="<id>"` → handle (null on miss) |
| `setRefText` / `setRefTextI32` / `setRefAttr` / `setRefValue` / `setRefClass` / `focusRef` / `removeRef` | Per-handle DOM mutation |
| `refValueI32` / `refValueF32` | Per-handle value read (form inputs) |

### Closure-style event handlers from chunks

Chunks can register closure handlers in the main runtime's
`event_slots` table just like the main client does, via
`verve.registerEvent(handler)`:

```zig
const verve = @import("verve");

var bump_id: u32 = 0;

fn handleBump() void {
    if (verve.signalSetI32("counter_island", verve.signalGetI32("counter_island") + 1)) |_| {}
}

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;
    verve.registerI32("counter_island", 0);
    bump_id = verve.registerEvent(&handleBump);
}
```

The SSR'd content stamps `[z-on-click-id="<id>"]` (via
`Node.onClickFn(id)` at render time) and the bridge JS click
delegate routes through `verve_event_dispatch(id)` — same path the
main client uses. The chunk's `&handleBump` is a fn pointer into
the shared `__indirect_function_table` (build.zig wires
`export_table = true` on the main client + `import_table = true`
on each chunk, and the bridge passes the table through as
`env.__indirect_function_table` at chunk instantiation). The main
runtime stores the same index in `event_slots` and `call_indirect`
dispatches into chunk code without further JS hops.

Chunks that prefer the simpler string-name path still work — export
a named handler and stamp `z-on-click="<exportName>"`. The bridge
JS click delegate looks up the export on the chunk's own instance.

### Multi-instance islands

`<verve-island>` markers on a page get a document-order id stamped
as `data-instance="N"` and passed to the chunk's `hydrate` as
`root_id`. Two markers with the same `data-name` share the same
chunk wasm but get distinct `root_id` values, so chunks can keep
per-instance state by namespacing their bind-names:

```zig
const std = @import("std");
const verve = @import("verve");

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    var buf: [32]u8 = undefined;
    const bind = std.fmt.bufPrint(&buf, "counter_island_{d}", .{root_id}) catch return;
    verve.registerI32(bind, 0);
}
```

The SSR'd content's `[z-bind="counter_island_{N}"]` must use the
matching namespaced form. Chunks that don't care about
multi-instance can ignore `root_id` entirely — `registerI32` is
idempotent on the bind-name, so a second `<verve-island
data-name="Counter">` marker just shares the same Signal slot
(no duplicate allocation, no warning).

## Shared linear memory

Per-island chunks declare zero static state and import their memory
from the main `client.wasm`:

```zig
// build.zig pins these on every island target
exe.import_memory = true;
exe.stack_size = 4 * 1024;
```

JS instantiates each chunk with `env.memory = <main runtime's memory>`,
and the props string is staged through the main runtime's
`verve_island_scratch_*` exports. The chunk reads from shared
memory directly — no per-chunk scratch buffer, no per-chunk runtime
preamble.

Result: a stub chunk weighs **~73 bytes**; a real chunk like
`Counter` that registers a Signal + ships a click handler weighs
**~290 bytes**. Pages without an island skip its chunk entirely;
pages with one pay only that cost plus the network round-trip.

## Build artifacts

`zig build` produces:

```
zig-out/bin/verve-server         # native binary (chunks embedded)
.zig-cache/.../client.wasm        # main runtime
.zig-cache/.../island_<Name>.wasm # one per app.islands decl
```

The generated `assets.zig` carries an `island_chunks` table the
server reads to serve `/islands/<Name>.wasm`. The generated
`client_manifest.zig` lists each island's name, props schema, and
chunk URL — both the WASM client (via `verve_island_count`) and
the native server (via `lookupIslandChunk`) consume it.

## JS bridge dispatch

The bridge runs two passes once the main runtime is up:

1. **In-process dispatch** — every `<verve-island>` marker is
   passed to `verve_island_dispatch(name_len, props_len)`, which
   routes to any `island.register("<Name>", hydrate)` callback the
   main client registered at startup. Returns 0 when no
   in-process handler claims the marker.
2. **Chunk loader** — for each marker, fetch `/islands/<Name>.wasm`
   lazily (cached per name across the session),
   `WebAssembly.instantiateStreaming` with `env.memory` pointing
   at the main runtime, then call the chunk's `hydrate(ptr, len,
   root_id)` with the props string copied into shared scratch.

Both paths are additive: in-process dispatch handles same-binary
hydration, the chunk loader handles per-island code-splitting.

## Server-fn integration

Islands typically call server functions for their interactivity:

```js
// Inside a per-island chunk or via the generic JS helper:
const result = await window.verveServerFn("addTodo", { text });
```

For type-safe calls from WASM, use the build-time generated
`app_client.<name>_post` variant — see
[03 — Actions](03-actions.md).

## Deferred work

- **Binary codec dispatch** — parse `props_schema` at chunk
  hydration time and decode `data-props` into typed args.
- **Per-island Effect ownership** — `root_id` is plumbed to chunks
  (see "Multi-instance islands" above) but the Owner is still
  global. Future work scopes the Effect tree per `root_id` so
  signals registered under one instance dispose when that instance
  unmounts.

## Next

- [17 — Reconciler](17-reconciler.md) — keyed-list reconciliation
  that pairs naturally with island-local lists.
- [16 — SPA router](16-spa-router.md) — SPA navigation pairs well
  with islands because the head-merge + body-swap keeps already-
  hydrated islands alive across navigations.
- [12 — WASM client](12-wasm-client.md) — main runtime architecture.
