# Verve Showcase — Hybrid Product Hub

The canonical "what a Verve app looks like" demo. One Zig binary,
three integrated sub-products, every public Verve export exercised
in context.

```sh
cd examples/showcase
zig build run -- --dev
# open http://127.0.0.1:8080
```

Pair with `zig build --watch run -- --dev` for auto-reload on every
rebuild.

## Three sub-products

### `/blog/*` — Content area
- Hero + keyed `forEach` post grid with `data-vkey` reconciliation
- Category pills with `aria-current="page"` active highlighting
- Per-post layout uses `verve.Slot` / `verve.SlotMap` for named
  children (header, body, aside)
- Path-prefix locale: `/blog/:lang/p/:slug` with hreflang alternates
- Hashed-asset preload via `ctx.assetHref("style.css")`
- Per-page head slots: title + description + canonical + og:title
  + og:type + JSON-LD (BlogPosting)
- RSS 2.0 + sitemap as fragment nodes with `contentType` override

### `/app/*` — Project tracker
- Three-level nested routes: `/app/o/:org/p/:project/i/:num`
- `verve.Route.layout` + `ctx.outlet()` slots all the way down
- `ctx.provide(CurrentUser, …)` at org-shell level; descendants
  read it via `ctx.use(CurrentUser)` (DI through the owner chain)
- Project board: `verve.createStore(Filter, …)` with three effects,
  each subscribing to a single field — mutations are field-grained
- `verve.batch` + `verve.untrack` escape hatches demonstrated
- Issue detail: **three independent Suspense boundaries** (comments,
  activity, related) on the same page
- `verve.createAction` wraps the comment submit with
  pending/value/version signals
- `verve.createErrorBoundary` captures a synthetic failure on the
  related-issues panel; siblings keep rendering
- `verve.actionForm` + auto-CSRF for the comment form
- `/team` route guarded by `.protect(teamGuard)` — redirect without
  `?token=`
- `/realtime` page wires **WebSocket + SSE on the same page** via
  one CSP-nonced inline script + `verve.NodeRef` typed handles

### `/admin/*` — Role-gated admin area
- Every route guarded by `.protect(adminGuard)` — requires
  `role=admin` cookie. Set it in devtools or hit `/admin/settings`.
- `/admin/analytics`: two parallel Suspense panels, each backed by
  a `verve.Resource(HealthPayload)`
- `/admin/settings`: locale picker via `ctx.actionForm`
- `/admin/jobs`: `verve.batch` coalesces three writes into one
  effect re-run; `verve.untrack` reads without subscribing
- `/admin/audit`: live counter via `/events` SSE + activity log
  rendered from in-memory ring buffer
- `/admin/users/:id`: `verve.StoredValue` cell + `owner.onCleanup`
  hook (look for `cleanup fired: user-page` in the server's stderr)

## Other routes

| Path                  | Demonstrates |
|---|---|
| `/`                   | Home: hero, KPI tiles, feature cards, prefetch-on-hover links |
| `/blog/rss.xml`       | RSS 2.0 fragment + `contentType("application/xml")` |
| `/blog/sitemap.xml`   | Sitemap fragment |
| `/island-demo`        | `verve.island` marker with JSON-encoded props |

## i18n

Cookie + query + `Accept-Language` resolution chain. Three locales:
EN / ES / FR. Click the language picker in the header, or visit
`/blog/es/p/welcome` to override via the URL.

## Auth model

Two cookies the demo respects:

- `role=admin|member|viewer` — gates `/admin/*` (only `admin` passes)
- The team-only route (`/app/.../team`) also accepts `?token=` as a
  shortcut bypass

Set them in devtools' Application tab to flip between authenticated
states without a real session store.

## CSRF + CSP

Every HTML response carries:

- `Set-Cookie: __verve_csrf=…; HttpOnly; SameSite=Strict` when a
  fresh token is needed
- `Content-Security-Policy: script-src 'nonce-…' 'strict-dynamic'
  'wasm-unsafe-eval'; …`

Every `<script>` and `<style>` tag in the response is auto-stamped
with the matching nonce by the renderer — including the dev-mode
auto-reload script and the realtime page's inline WS/SSE wiring.

## Verve exports demonstrated

This single app covers ~95% of the public exports in `src/verve.zig`:

```
Context, alloc, useSignal, useEffect, params, location, request_meta,
head, owner, asset_resolver, csrf_token, csp_nonce, outlet_node,
setTitle / setTitleIfUnset / metaTag / linkTag / jsonLd,
provide / use / usePtr, redirect / redirectWithStatus,
assetHref, raw, contentType, scriptInline, errorBoundary,
useEffect, fetch, serverFn, csrfField, actionForm, nodeRef,

Route, Route.init, Route.layout, .protect, RouteSegment, Redirect,
RouteGuard, Location, QueryPair, Method, Cookie, RequestMeta,

Signal, Effect, Owner, untrack, batch, setReactivePendingAllocator,
setDiTablesAllocator, setRendererNonce, AssetResolver,
NodeRef, NodeRefTag, StoredValue,
Head, HeadMeta, HeadLink, HeadScript, FetchOptions, FetchResponse,
Resource, ResourceState, createResource, createLocalResource,
Action, createAction, suspense, transition, markSuspended, encode,
csrf, show, forEach, portal, Slot, SlotMap, link, LinkOpts,
serverFn, island, IslandOpts,
Store, createStore, I18nCatalog, I18nEntry, resolveLocale,
ErrorBoundary, createErrorBoundary,
Node, Attr, Renderer, escapeHtml.
```

Read `src/app/components/**/*.zig` — each file's `Demonstrates:`
comment header names the surfaces it exercises.

## Source layout

```
src/app/
├── api.zig                              types, seed data, Actions, guards, currentUser
├── routes.zig                           23-route table
├── components.zig                       barrel re-exports
└── components/
    ├── shell.zig                        page(), shellHeader, footer, locale picker, tokens.css + app.css
    ├── ui.zig                           card, badge, kpi, alert, breadcrumb, avatar, tag
    ├── notFound.zig                     framework hooks
    ├── i18n.zig                         Catalog + resolve + t()
    ├── blog/
    │   ├── list.zig                     keyed forEach grid + category nav
    │   ├── post.zig                     post layout with Slot/SlotMap + head slots
    │   └── feed.zig                     RSS + sitemap fragments
    ├── tracker/
    │   ├── org.zig                      level-1 layout + DI provide
    │   ├── project.zig                  level-2 layout + DI use
    │   ├── board.zig                    Store + 3 effects + batch + untrack
    │   ├── issue.zig                    level-3 + 3 Suspense + ErrorBoundary + Action
    │   ├── issues.zig                   keyed forEach + tally Effect
    │   ├── team.zig                     guarded page
    │   └── realtime.zig                 WS + SSE + NodeRef + scriptInline
    └── admin/
        ├── index.zig                    admin home (role-gated)
        ├── analytics.zig                multi-Suspense + Resource
        ├── settings.zig                 actionForm + locale picker
        ├── jobs.zig                     batch + untrack tally
        ├── audit.zig                    SSE counter + activity log
        └── users.zig                    StoredValue + on_cleanup
```

## Deferred

- Chunked HTML streaming with out-of-order Suspense `<template>` chunks
  (waits for async Resources in the WASM client).
- `ctx.fetch` analytics panel: synthesized payload in the demo (the
  surface is in place; stdlib's http.Client signature is in flux on
  Zig 0.16, so the example doesn't hit a real upstream).
