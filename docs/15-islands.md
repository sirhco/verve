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
`src/client/islands/_default.zig` stub. A chunk source exports
exactly one entry point:

```zig
// src/client/islands/Counter.zig
export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    // `props_ptr` points into shared memory with the main runtime.
    // `root_id` is reserved for the multi-instance case.
    _ = props_ptr;
    _ = props_len;
    _ = root_id;
}
```

The chunk runs *after* the universal `data-vh` walker in the main
`client.wasm` has already hydrated every reactive span inside the
island. `hydrate` is the place island-specific bring-up lives —
multi-step initialization, prop-driven Signal seeding, custom
event handlers that aren't expressible via `[z-on-click]`.

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

Result: each chunk weighs **~73 bytes**. Pages without an island
skip its chunk entirely; pages with one pay only the
~73-byte cost plus the network round-trip.

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

- **Phase 13F** — export the main runtime's Signal-registration +
  DOM-primitive symbols to per-chunk imports so chunks can wire
  reactive state from inside their own `hydrate` body. Today the
  universal `data-vh` walker still handles every reactive span,
  and per-chunk `hydrate` stays a no-op hook.
- **Binary codec dispatch** — parse `props_schema` at chunk
  hydration time and decode `data-props` into typed args.
- **Per-island Effect ownership** — `root_id` will dispatch slots
  in a multi-instance table so two `<verve-island data-name="Counter">`
  on the same page can keep distinct Signal subscriptions.

## Next

- [17 — Reconciler](17-reconciler.md) — keyed-list reconciliation
  that pairs naturally with island-local lists.
- [16 — SPA router](16-spa-router.md) — SPA navigation pairs well
  with islands because the head-merge + body-swap keeps already-
  hydrated islands alive across navigations.
- [12 — WASM client](12-wasm-client.md) — main runtime architecture.
