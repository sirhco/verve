# 16 — SPA router (client-side navigation)

`verve.link` + the client-side router in `verve.js` upgrade
multi-page navigation into smooth in-page transitions without giving
up SSR. Anchors are real `<a>` tags with real `href`s — the router
intercepts left-clicks on tagged anchors and fetches the new URL in
the background.

## Server-side: emitting links

```zig
verve.link(ctx, "/work",   "Work",    .{}),
verve.link(ctx, "/about",  "About",   .{ .class = "nav-link" }),
verve.link(ctx, "/contact","Contact", .{ .prefetch_on_hover = true }),
```

The helper emits:

```html
<a href="/work" data-vlink="1">Work</a>
<a href="/about" data-vlink="1" class="nav-link">About</a>
<a href="/contact" data-vlink="1" data-vprefetch="hover">Contact</a>
```

When the current path matches `href`, an `aria-current="page"`
attribute is added automatically. Disable with `.active_aware =
false`.

## Client wire

`verve.js` registers a single delegated click handler on `document`:

```js
document.addEventListener("click", (e) => {
    if (isModifiedClick(e)) return;
    const anchor = e.target.closest("a[data-vlink]");
    if (!anchor) return;
    // … fetch the URL, swap content, pushState
});
```

The handler:

1. Skips modified clicks (cmd/ctrl/shift, middle/right button).
2. Skips `target="_blank"` and cross-origin hrefs.
3. Skips fragment-only navigation (`#section`).
4. `preventDefault`s, then fetches the target URL.
5. Parses the response as HTML.
6. Merges `<head>`:
   - Replaces the document title.
   - Replaces existing `<meta name=...>` / `<meta property=...>` by
     key.
   - Replaces existing `<link rel=...>` by rel.
   - Appends anything else (JSON-LD scripts).
7. Replaces `document.body.innerHTML`.
8. `history.pushState`.
9. `window.scrollTo({ top: 0, behavior: "instant" })`.

On fetch failure the router falls back to a full page load
(`location.href = href`), so a broken router never strands the user.

## Prefetch on hover

Anchors with `data-vprefetch="hover"` trigger a low-priority GET on
`mouseover`. Each URL prefetches at most once per page lifetime.
Browser cache absorbs the response so the actual navigation a
moment later returns instantly.

```zig
verve.link(ctx, "/work", "Work", .{ .prefetch_on_hover = true }),
```

Server sees the prefetch as a normal GET with an
`x-verve-prefetch: 1` header — useful for excluding from analytics
counts.

## Back/forward

`popstate` fires when the user clicks back or forward. The router
re-fetches `location.pathname + search + hash` and re-runs the swap
without pushing a new history entry. Scroll position restoration is
left to the browser default (it remembers scroll on its own when the
body content is replaced).

## When NOT to use `verve.link`

- External hrefs (`https://example.com/...`): leave as plain `ctx.a(href, label)`. The router skips them anyway.
- Anchors that download a file (`<a download>`): native navigation
  is what you want.
- Forms: `ctx.actionForm` handles its own progressive enhancement.

## Composing with islands

When the router swaps body content it first calls
`verve_unmount_route()`, which disposes the outgoing route's reactive
scope — every signal, effect, `ForEachHandle`, event handler, and
registered cleanup is torn down (cleanups run LIFO while the old DOM is
still present, so DOM-touching teardown sees live nodes). The incoming
body's islands then re-hydrate into a fresh scope as their markers
appear in the DOM. Disposal is route-granular today; per-instance
(single island) disposal is a planned follow-on — the server already
stamps a `data-vid` on each `<verve-island>` and the client dispatch
records it, dormant, for that future work.

This means SPA navigation between two heavy-island pages still
costs a WASM hydration on arrival — same as a hard reload, just
without the cold cache. For pages that share islands, the bundle
cache means the same chunk doesn't re-download.

## Disabling per-page

Some pages benefit from full page loads (auth flows, payment
redirects, OAuth callbacks). To opt out of SPA navigation on those:

- Don't use `verve.link` to link to them — `ctx.a(href, label)`
  produces a plain anchor the router ignores.
- Or set `<meta name="verve-spa" content="off">` (not yet
  implemented; track in Phase 8).

## Implementation summary

| Piece | Where |
|---|---|
| `verve.link(ctx, href, label, opts)` helper | `src/core/link.zig` |
| Server emits `data-vlink="1"`         | same |
| Client click handler                  | `src/bridge/verve.js` |
| Head merge logic                      | `src/bridge/verve.js` |
| popstate handler                      | `src/bridge/verve.js` |

## Next

- [04 — Routing](04-routing.md) — server-side routing with nested
  layouts and Redirect.
- [15 — Islands](15-islands.md) — hydration boundaries that survive
  SPA navigations.
