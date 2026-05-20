# 15 — Islands

Islands are opt-in hydration boundaries: zero JS by default, with
selected subtrees marked for client-side reactivity. The Phase 8
client runtime (deferred) will walk these markers, fetch each
island's WASM chunk on demand, and hydrate the subtree in place.

Phase 7 ships the API surface + SSR markers; Phase 8 adds the
per-island WASM bundling, manifest, and hydration loader.

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
| `name`    | required | Component identifier the Phase 8 loader resolves to a WASM chunk. Typically `@typeName(Component)`. |
| `props`   | `""`     | Pre-encoded props blob. Caller chooses JSON, the binary codec, or something else. |
| `state_id`| `null`   | Optional reference to a pre-resolved Resource's state slot. |
| `hydrate` | `true`   | When false the wrapper is skipped — pure SSR subtree, useful for build-time A/B. |

## Custom element registration

`verve.js` registers `<verve-island>` as a custom element so the
browser doesn't surface it as an unknown tag. The `connectedCallback`
is a stub today — Phase 8 will:

1. Read `data-name` + `data-props`.
2. Fetch the corresponding WASM chunk via the route manifest.
3. Instantiate the chunk's exports.
4. Call the island's hydrate fn with the decoded props.

Until Phase 8 lands, the framework's WASM client (Phase 1 reactive
runtime + Phase 6/7 SPA router) is loaded as a single bundle by
`<script src="/verve.js">` — fine for SSR-first apps, suboptimal for
JS-heavy pages where islands save payload.

## Server-fn integration

Islands typically call server functions for their interactivity:

```js
// Inside the (Phase 8) island's hydration script:
const result = await window.verveServerFn("addTodo", { text });
```

`verveServerFn` is the generic JSON-POST client stub; typed wrappers
land alongside per-island bundling.

## Phase 8 roadmap

What lands next on this surface:

- `build.zig` walker: scan the source tree for `VERVE_ISLAND =
  true` markers, emit per-island WASM chunks.
- `client_manifest.json`: route → list of (island name, wasm URL,
  shared chunk URL) entries.
- Per-island hydration loader in `verve.js`: dynamic import, call
  the chunk's `hydrate(props, root_element)` export.
- Shared chunk dedup so the reactive runtime ships once across all
  islands on a page.

## Next

- [16 — SPA router](16-spa-router.md) — SPA navigation pairs well
  with islands because the head-merge + body-swap keeps already-
  hydrated islands alive across navigations.
- [12 — WASM client](12-wasm-client.md) — current single-bundle
  client architecture.
