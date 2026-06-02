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
    .props = try verve.encodeProps(&ctx, Counter.Props{ .initial = 7 }),
}, try counterInline(ctx, 7));
```

Server renders the inline HTML (for search engines + noscript
clients), then wraps it in a `<verve-island>` custom element
carrying the component name + base64-encoded binary props:

```html
<verve-island data-name="Counter" data-props="<base64>">
  <div class="counter">7</div>
</verve-island>
```

`data-props` is always base64 of the binary codec output from
`verve.encodeProps`. The JS bridge base64-decodes and stages the raw
bytes for the chunk. See [Typed props](#typed-props) for the full
encode/decode pattern.

The wrapper costs ~20 bytes of HTML per island — cheap enough to add
to every interactive subtree.

`IslandOpts`:

| Field | Default | Notes |
|---|---|---|
| `name`    | required | Component identifier. Must match a `pub const <Name>` in `src/app/islands.zig` for the chunk to ship. |
| `props`   | `""`     | Pre-encoded props blob. Use `verve.encodeProps(&ctx, Props{...})`; the result is base64 of the binary codec, which `data-props` always carries. |
| `state`   | `null`   | Serialized resource-state blob from `ctx.islandState(...)`. Staged under this island's `vid` for client hydration without re-fetching. |
| `hydrate` | `true`   | When false the wrapper is skipped — pure SSR subtree, useful for build-time A/B. |

## Declaring an island

Each island gets a `pub const <Name> = struct { ... }` in
`src/app/islands.zig`. `build.zig` parses the file at configure
time and fans WASM chunks out across every top-level decl:

```zig
// src/app/islands.zig
pub const Counter = struct {
    pub const Props = struct { initial: i32 };
};

pub const Greeting = struct {
    pub const Props = struct { name: []const u8 };
};
```

The comptime `Props` type is the real contract — `verve.encodeProps`
encodes it server-side and `verve.decodeProps` validates the bytes
against it chunk-side. `props_schema` (a JSON string) is now
**optional documentation only** and not required for the chunk to
ship. See [Typed props](#typed-props) for the full encode/decode
pattern.

## Custom per-island logic

Each chunk's source lives at `src/client/islands/<Name>.zig`. When
that file is absent the chunk falls back to the shared
`src/client/islands/_default.zig` stub. A chunk source exports a
`hydrate` entry point plus any click / submit / etc. handlers it
needs:

```zig
// src/client/islands/Counter.zig
const verve = @import("verve");

const BIND: []const u8 = "counter";

export fn hydrate(props_ptr: u32, props_len: u32, vid: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = vid;
    // Register the per-island Signal in the main runtime's slot
    // table. Its `on_set` hook wires straight to the matching
    // `[z-bind="counter"]` element via the JS bridge.
    // The framework suffixes the bind-name by vid (counter__v1,
    // counter__v2, …) automatically for multi-instance support.
    verve.registerI32(BIND, 0);
}

export fn counter_bump() void {
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
    if (verve.signalSetI32("counter", verve.signalGetI32("counter") + 1)) |_| {}
}

export fn hydrate(props_ptr: u32, props_len: u32, vid: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = vid;
    verve.registerI32("counter", 0);
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
JS click delegate looks up the export on the chunk's own instance:
dispatch is scoped to the click target's enclosing `<verve-island>`
by `data-name`, so two different components may export the same
handler name without colliding — each resolves to its own chunk.

### Multi-instance islands

Two `<verve-island>` markers with the same `data-name` share the
same chunk WASM but are kept independent **automatically** — no
author burden. Each marker gets a unique `vid` (stamped as
`data-vid`), and `island()` rewrites every `z-bind` / `data-ref` /
`data-vh` in the inner tree by that vid before rendering: plain
`"counter"` becomes `"counter__v1"` for the first instance,
`"counter__v2"` for the second, and so on. The chunk writes plain
binding names and the SSR template uses plain `bind("counter")` /
`data-ref="counter-label"`; the suffixing is invisible to the author.

The third argument to `hydrate` is `vid` (not `root_id`). Chunks
that don't need the vid can ignore it. See the
[Multiple instances](#multiple-instances-of-one-component) section
below for the full pattern and limitations.

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

## Lifecycle

Every `<verve-island>` carries a server-assigned, render-unique
`data-vid`. The JS bridge runs a `MutationObserver` over the body:

- **On insertion** (initial load, a mid-page conditional mount, or a
  post-SPA-nav body swap) it hydrates the island —
  `verve_island_dispatch_v(name, props, vid)` plus the per-island chunk
  load. Islands therefore hydrate whenever they appear, not only at
  first paint.
- **On removal** it calls `verve_unmount_island(vid)`, which disposes
  that island's reactive scope: its signals, effects, and registered
  cleanups (LIFO) are torn down and its slot-table entries freed, while
  sibling islands and the route scope are untouched.

In wasm, each `vid` gets its own `Owner` (a child of the route owner),
and the signal/event/response slot tables are keyed by `(vid, name)` —
so two instances of the same component hold independent state. Event and
response handlers run with their island's `vid` restored, so name-based
signal lookups inside a handler resolve that island's signals. The
route-level `verve_unmount_route()` (see
[16 — SPA router](16-spa-router.md)) disposes the root owner, which
cascades to every island owner at once.

**Limitations.** Up to `MAX_ISLAND_OWNERS` (64) islands may be live
simultaneously. `verve_unmount_island` frees an island's signal arena and
handlers, but its (small) `Owner` record stays on the route arena until
the next `verve_unmount_route()` re-arms it — so repeatedly mounting and
unmounting islands *without navigating* accumulates a slow residual.
Navigation reclaims it. The common case (islands disposed on route
change) has no residual.

## Typed props

`data-props` is decoded into a typed value at hydration via a binary codec
(`src/core/serialize.zig` — bool, ints, floats, `[]const u8`, optionals,
slices, nested structs, enums). The component declares a `Props` type and
encodes it server-side; the chunk decodes it:

```zig
// island component
pub const Props = struct { initial: i32, label: []const u8 };

// server-side render
return ctx.island(.{
    .name = "Counter",
    .props = try verve.encodeProps(&ctx, Props{ .initial = 0, .label = "Clicks" }),
}, inner);
```

```zig
// chunk-side hydrate
export fn hydrate(props_ptr: u32, props_len: u32, vid: u32) void {
    const bytes = @as([*]const u8, @ptrFromInt(props_ptr))[0..props_len];
    const p = verve.decodeProps(Props, bytes, alloc) catch return;
    // use p.initial / p.label ...
}
```

`encodeProps` serializes then base64-encodes into `data-props`; the JS bridge
base64-decodes and stages the raw bytes for the chunk. The decoder is
panic-free on arbitrary bytes (it parses client-controllable markup), erroring
rather than faulting on malformed input.

`props_schema` (the JSON string on island component types) is now optional
documentation — the comptime `Props` type is the real contract; `decodeProps`
validates the bytes against it.

For server-resolved **resource** state (not props), see
[Resource state hydration](#resource-state-hydration) below; `islandStateStruct`
+ `resourceStructFromState` carry struct values through the same codec.

### In a chunk

App island logic lives in a per-island chunk (`src/client/islands/<Name>.zig`,
compiled to a separate `.wasm` sharing the main client's memory). The chunk's
`verve` is `island_runtime.zig`, which exposes the codec for chunks:

```zig
const verve = @import("verve"); // island_runtime
export fn hydrate(props_ptr: u32, props_len: u32, vid: u32) void {
    const bytes = @as([*]const u8, @ptrFromInt(props_ptr))[0..props_len];
    const p = verve.decodeProps(MyProps, bytes, alloc) catch return;
    const seed = verve.islandStateValue(i32, "seed") orelse 0; // server state
    verve.registerI32("count", p.initial + seed);
    _ = verve.registerEvent(bump); // stamps z-on-click-id on the bound node
}
```

The bridge wraps the chunk's `hydrate` in `verve_enter_island(vid)` /
`verve_exit_island()`, so signals/effects/cleanups the chunk registers scope to
the island's `vid` owner — they dispose on per-island unmount and on route
navigation. `islandStateValue` string results are slices into shared memory,
valid only during `hydrate`; copy (e.g. seed a `registerStr`) to keep them.
A runnable end-to-end demo lives in `examples/islands-demo`.

### Multiple instances of one component

Two `<verve-island>` of the same component on one page work independently with
no author burden. The chunk writes plain binding names (`registerI32("counter")`,
`queryRef(.{ .id = "counter-label" })`) and the SSR template uses plain
`bind("counter")` / `data-ref="counter-label"`; the framework suffixes each
instance's binding by its `vid` on both sides — `island()` rewrites the inner
tree's `z-bind`/`data-ref`/`data-vh` to `counter__v1`, `counter__v2`, … and the
client drives the DOM (and resolves `queryRef`) with the matching suffixed name.
So instance 1's signal updates only its own span. The `__v{vid}` separator is
reserved. (Signals themselves are already `(vid, name)`-scoped; this closes the
DOM-side of multi-instance.) Route-scope binds (`vid` 0, outside any island) are
never suffixed. Keyed-list parent binds (`bindForEach`) are auto-namespaced
too: `registerForEach` suffixes its `parent_bind` by the enclosing island's
vid (matching the server-side suffix of the parent's `z-bind`), so two
instances of one component each reconcile only their own list — no manual
parent-bind disambiguation needed.

## Resource state hydration

When an island reads a `Resource` that the server already resolved, the
component serializes its ready value so the client uses it directly —
no re-fetch:

```zig
// server-side island component
const user = try ctx.createResource(User, ctx.io, owner, &args, fetchUser);
// ... render with user.get() ...
return ctx.island(.{
    .name = "Profile",
    .state = try ctx.islandState(.{ .name = user.get().?.name, .age = user.get().?.age }),
}, inner);
```

The page carries one `<script type="application/verve-state">` — a map of
`data-vid → base64(blob)`. The bridge parses it once (and again after each
SPA body swap) and stages each island's blob before its chunk hydrates.
The chunk reconstructs a `.ready` Resource without touching the network:

```zig
// chunk-side hydrate
const name = (try verve.resourceFromState([]const u8, owner, "name")).?;
const age = (try verve.resourceFromState(i32, owner, "age")).?;
```

The codec covers primitives only — `i32` / `[]const u8` / `bool` / `f32`
(an unsupported field type is a compile error). Struct / rich-`T`
serialization is future work, shared with the props binary codec.

## Deferred work

- **Client-side fetch of pending / local resources** — a `loading` or
  `LocalResource` resolved client-side via the server-function reply
  loop (`server_fn_post` → `dispatchResponse`), keyed by `data-vid` and
  scoped to the island's owner. Designed; the resolved-at-SSR common
  case above already avoids the round-trip.

## Next

- [17 — Reconciler](17-reconciler.md) — keyed-list reconciliation
  that pairs naturally with island-local lists.
- [16 — SPA router](16-spa-router.md) — SPA navigation pairs well
  with islands because the head-merge + body-swap keeps already-
  hydrated islands alive across navigations.
- [12 — WASM client](12-wasm-client.md) — main runtime architecture.
- [20 — Client runtime](20-client-runtime.md) — chunk-callable app
  primitives: typed IPC replies + shared JSON service, events with data,
  timers/storage/clipboard, forms/measurement, JS interop, chunk arena.
