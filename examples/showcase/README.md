# showcase

Single-binary tour of every Phase 0-10 surface in Verve.

## Build + run

```sh
cd examples/showcase
zig build run -- --dev
# browse http://127.0.0.1:8080
```

`--dev` injects the auto-reload script; pair with `zig build --watch
run -- --dev` to refresh the browser on every rebuild.

## Routes

| Path | Phase | Surface |
|---|---|---|
| `/`                          | overview     | landing page + nav |
| `/counter-reactive`          | 1, 5         | Signal + Effect + legacy z-bind + CSRF form |
| `/store-demo`                | 9            | `verve.Store(T)` — field-grained signals |
| `/resource-demo`             | 3            | `verve.Resource(T)` — SSR-resolved async value |
| `/suspense-demo`             | 4            | Suspense boundary catches `markSuspended` from a loading Resource |
| `/error-boundary`            | 9            | reactive `ErrorBoundary` captures + reset |
| `/forms-demo`                | 5            | `actionForm` + auto-CSRF + per-page CSP nonce |
| `/i18n/:locale`              | 9            | locale resolution + catalog lookup |
| `/app` (layout)              | 7            | nested layout + outlet |
| `/app/dashboard`             | 7            | nested child |
| `/app/settings/:section`     | 7            | nested child with path param |
| `/private`                   | 7            | ProtectedRoute guard redirects without ?token= |
| `/work/:slug`                | 0, 2         | path param + per-page title/canonical/og/json-ld |
| `/files/*rest`               | 0            | wildcard segment |
| `/spa-tour`                  | 7            | walkthrough of `verve.link` SPA wire |
| `/island-demo`               | 8            | `<verve-island>` marker (hydration loader: Phase 8) |
| `/sitemap.xml`               | 0            | non-HTML fragment with `contentType` override |

## Notable per-route demos

- **`/work/:slug`** — open devtools → Elements; the `<head>` is
  populated with charset, title, canonical link, `og:title`, and a
  JSON-LD block. All contributed by the component via
  `ctx.setTitle / metaTag / linkTag / jsonLd`.
- **`/forms-demo`** — submit the form, refresh, observe new entries.
  Remove the hidden `__csrf` field with devtools and resubmit → 403.
- **`/i18n/:locale`** — switch between EN / ES / FR via the buttons
  or change your browser's Accept-Language; the resolver picks the
  first supported candidate.
- **`/private`** — guard returns a Redirect when `?token=` is
  missing. With the token, the page renders normally.
- **SPA tour** — click any nav link with devtools' Network tab open.
  Notice only the new HTML is fetched; the document stays loaded.

## What's deferred

- Phase 8 islands hydration loader — the marker emits today but the
  per-island WASM chunks + manifest aren't built yet.
- Phase 4 chunked streaming — Suspense fallback emits inline; out-of-
  order `<template>` swap chunks await async Resources.
- Brotli encoder + server-side TLS — ecosystem-blocked (see top-level
  HANDOFF for details).

## Source layout

```
src/app/api.zig         # Actions, Todo state, i18n catalog, route guards
src/app/routes.zig      # Route table + render fn wrappers
src/app/components.zig  # One render fn per demo route
```

Components import `verve` from `../../src/verve.zig`, so changes in
the framework appear immediately on `zig build`.
