# Changelog

All notable changes to Verve are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added — Desktop framework polish (2026-05-24)

- **`--dev <dir>` runtime asset fallback.** Desktop scheme handler
  checks `<dir>/<path>` before the embedded `public_assets` table
  on every request, so hand-written frontend assets (`style.css`,
  `verve_desktop.js`, …) reload with Cmd+R instead of triggering a
  full process-restart rebuild. Rejects `..` and post-strip
  absolute paths; 16 MB per-file ceiling. Wired through
  `WindowOptions.dev_assets: ?DevAssetsConfig`.
- **Win + Linux ports of `openFileDialog` / `saveFileDialog` /
  `showAlert`.** Linux uses `GtkFileChooserNative` + `GtkMessageDialog`;
  Windows uses `GetOpenFileNameW` / `GetSaveFileNameW` + `MessageBoxW`.
  Win folder-picking returns `Unsupported` (needs `IFileOpenDialog`);
  custom alert labels honored on mac + Linux, mapped to standard
  buttons on Windows.
- **Win + Linux `takeSnapshotPng` ports.** Linux uses
  `webkit_web_view_get_snapshot` → cairo PNG; Windows uses
  `ICoreWebView2::CapturePreview` → `IStream` → `WriteFile`. Same
  byte-deterministic PNG output as the macOS reference.
- **Single-instance enforcement.**
  `desktop.single_instance.acquire(allocator, name)` returns an
  opaque `Lock` held for process lifetime. macOS + Linux use POSIX
  `flock(LOCK_EX | LOCK_NB)` on `<TMPDIR>/verve.<name>.lock`;
  Windows uses `CreateMutexW` under `Local\Verve.<name>`. Scaffold
  template wires it at startup automatically.
- **Cross-platform clipboard read/write.** `Window.clipboard()`
  returns a handle with `writeText` / `readText`. macOS:
  `NSPasteboard.generalPasteboard`; Windows: `OpenClipboard` +
  `CF_UNICODETEXT` + HGLOBAL ownership transfer; Linux:
  `gtk_clipboard_get(CLIPBOARD)` + `set_text` / `wait_for_text` +
  `gtk_clipboard_store`.
- **`Window.colorScheme()`** returns `.light` / `.dark` /
  `.unknown`. macOS: `[NSApp.effectiveAppearance].name`; Windows:
  `RegGetValueW(HKCU\…\Personalize\AppsUseLightTheme)`; Linux:
  GtkSettings' `gtk-application-prefer-dark-theme`. Pair with
  `Window.setColorSchemeHandler(cb, ctx)` for live change events
  via NSDistributedNotificationCenter (mac), WM_SETTINGCHANGE
  (win), GtkSettings notify signal (linux).
- **App icons (macOS `.app` bundle).** Scaffold `build.zig` gains
  a `-Dicon=<path>` option. Bundle step copies the supplied
  `.icns` into `Contents/Resources/AppIcon.icns` and injects
  `CFBundleIconFile = "AppIcon"` into the generated Info.plist.
  Absolute and build-root-relative paths both work.

### Fixed — Desktop framework

- **`openChildWindow` crash on multi-window apps.** The macOS
  backend re-registered `VerveSchemeHandler` and
  `VerveMessageHandler` Obj-C classes for every `Window.init`,
  but the Objective-C runtime rejects duplicate class names with
  `objc_allocateClassPair failed`. Classes are now cached at
  module scope and reused for every window.
- **`webview2.pinned.txt` SHA-512 populated.** Previously blank
  with TODO; reproducible Windows builds now actually verify the
  downloaded SDK. Also fixed `fetch_webview2.sh` `cut -d= -f2`
  truncating the trailing `==` base64 padding.
- **CI smoke server CSRF.** `--csrf=disable` added to the
  workflow's smoke-test invocation; form-encoded `/api/<fn>` POSTs
  no longer fail with `403`.
- **`verve-cli new <hyphenated-dir>`.** Basename-derived package
  names previously errored with `InvalidName` on hyphens. Hyphens
  / dots in basename now sanitize to `_`; explicit `--name=<n>`
  keeps the strict validation.

### Fixed — Docs

- **`docs/11-desktop-roadmap.md` #18 status.** Item was marked open
  even though commits 49b053d (J1 build-time SSR) and 3338d45
  (J2+J3 WASM + bridge) had landed. Doc now reflects shipped state.

## [0.1.0] — 2026-05-21

First public release. Server-side rendering with fine-grained
reactivity, a wasm32-freestanding client runtime that hosts the
real Signal/Effect graph, per-island WASM code-splitting, and a
single-binary distribution — all in pure Zig 0.16, zero external
runtime dependencies.

### Added — Routing + rendering

- Comptime route parser with path parameters (`/work/:slug`),
  wildcards (`/files/*rest`), and nested layouts via
  `ctx.outlet()`.
- `Route.layout` for grouping child routes under a shared shell.
- `ProtectedRoute` guards + `Redirect` sentinel
  (`ctx.redirect("/login")`).
- `ctx.location` (`useLocation`) with lazy query parsing +
  `isActive`.
- `RequestMeta` exposing cookies, Accept-Language, User-Agent,
  Origin, Host.
- Streaming HTML output via `std.http.Server`, chunked transfer
  encoding, no full-body buffering.

### Added — Reactivity (server + WASM client)

- Full SolidJS/Leptos-style reactive runtime: `Signal`,
  `Effect`, `Owner`, `Store`, `Resource`.
- Reactive `ErrorBoundary` — `Signal(?anyerror)` with
  `captureError` / `reset`.
- `untrack` / `batch` escape hatches.
- Per-request Owner with LIFO `on_cleanup` disposal.
- WASM client hosts the real reactive graph — `registerI32` /
  `registerStr` / `registerBool` / `registerF32` allocate
  Signals whose `on_set` hook drives DOM updates.
- 256 KB per-frame scratch allocator separate from the
  long-lived bump heap so reactive memory usage stays bounded by
  the largest single-frame render.

### Added — Keyed-list reconciler

- LIS-based planner emits the minimum (insert | move | remove)
  op sequence to turn the live DOM into a new key order.
- `ForEachHandle` caches the parent's current key order;
  `update(arena, new_keys, new_html)` diffs against the cache
  and dispatches DOM ops.
- `bindForEach(handle, ctx, render_fn)` ties a list-valued
  computation into the reactive graph — closure re-runs when any
  tracked Signal changes, automatically reconciles.

### Added — Components + head slots

- Arena-backed `*Node` tree with fluent chain methods.
- Head slot accumulator — `setTitle` / `metaTag` / `linkTag` /
  `jsonLd` with explicit priority + replace-not-append semantics.
- `provide` / `use` DI through the owner chain.
- `Slot` / `SlotMap` named-children API.
- `show` / `forEach` / `portal` control-flow helpers (server +
  reactive client-side via the reconciler).
- `NodeRef` typed handles + `data-ref` markers.

### Added — Actions / server functions

- Comptime dispatcher walks `app.Actions` to expose every
  `pub fn` as `POST /api/<name>`.
- Form-encoded bodies URL-decoded; JSON bodies parsed via
  `std.json`. Return types may be `void`, `!void`, `T`, or `!T`.
- `ctx.serverFn(f, args)` — server-side direct call.
- **Build-time codegen** (`tools/server_fn_codegen.zig`) emits
  `app_client.zig` with one typed wrapper per Action: native
  `<name>(arena, args) → Ret` plus WASM-callable
  `<name>_post(arena, args) → void` (JSON-serialize + JS-bridge
  fetch).
- Auto-303 redirect to `Referer` on form POSTs — works without
  any client-side JS.

### Added — Islands (per-island WASM chunks)

- `verve.island(ctx, opts, inner)` emits `<verve-island
  data-name=… data-props=…>` markers.
- **Build-time manifest codegen**
  (`tools/island_manifest_gen.zig`) walks `app.islands` and
  emits `client_manifest.zig` listing each island's name, props
  schema, and chunk URL.
- **Per-island WASM chunks** — `build.zig` parses
  `src/app/islands.zig` at configure time and builds one chunk
  per declared island. Custom logic via
  `src/client/islands/<Name>.zig`; everything else picks up a
  shared `_default.zig` stub.
- **Shared linear memory** — chunks import their memory from
  the main `client.wasm` via `env.memory`. Per-chunk size drops
  to ~73 bytes (vs. ~180 B standalone).
- JS bridge fetches chunks lazily, caches per name, copies props
  through shared scratch, calls `hydrate(ptr, len, root_id)`.
- In-process `verve_island_dispatch` for islands registered via
  `island.register(name, hydrate_fn)` in the main bundle.

### Added — Streaming SSR (out-of-order Suspense)

- `Suspense` boundary parks a continuation on the active
  `StreamRegistry` when `markSuspended()` fires and a registry
  is in scope.
- `verve.withStreamRegistry(reg, ctx, build_fn)` activates the
  thread-local for the lifetime of `build_fn`.
- `Renderer.streamRender(w, node, reg)` flushes the shell first,
  then drains every parked slot as
  `<template id="verve-vs-{id}">{real}</template>` +
  `verveSwap({id})` chunks.
- `window.verveSwap(id)` JS helper unwraps the matching template
  into the placeholder `<div data-vs="{id}">`. Reactive state
  on surrounding nodes survives.

### Added — SPA navigation

- `verve.link(ctx, href, label, opts)` emits anchors with
  `data-vlink`.
- Bridge intercepts same-origin clicks, fetches the page, merges
  `<head>` (title / meta by name|property / link by rel), swaps
  `<body>` innerHTML, pushes history.
- Optional prefetch-on-hover via `data-vprefetch="hover"`.
- `popstate` handler restores prior navigations.

### Added — Auth + security

- CSRF — HMAC-SHA256 token, auto-issued cookie + `__csrf` form
  field. `ctx.actionForm` injects the field automatically.
  `VERVE_CSRF_KEY` env var pins the secret across restarts.
- CSP nonce — per-request 12-byte hex nonce in
  `Content-Security-Policy: script-src 'nonce-…'
  'strict-dynamic'`.
- Origin pinning on form POSTs.
- `SameSite=Strict` on the CSRF cookie.
- `--csrf=enforce|disable` flag (default enforce).

### Added — Static assets

- `/public/*` routing — runtime via `--public-dir DIR`, or
  comptime-embedded via `-Dpublic-dir=DIR`.
- Hashed URLs (`/public/style-d5a73163.css`) with
  `Cache-Control: public, max-age=31536000, immutable`.
  `ctx.assetHref("style.css")` resolves the hashed form.
- mtime-aware LRU for `--public-dir` reads.
- Precompressed `.br` / `.gz` siblings served when present.

### Added — i18n

- `verve.I18nCatalog` + `resolveLocale` — cookie → query →
  Accept-Language → default with language-prefix fallback.

### Added — Dev + ops

- `--dev` auto-reload via injected WS-disconnect-reconnect
  script; `/__verve/dev_ws` upgrade endpoint.
- `/events` Server-Sent Events.
- `/ws` bidirectional WebSocket.
- `/health` — JSON: `{status, uptime_sec, requests}`.
- `/metrics` — per-route latency JSON.
- Bounded-admission worker pool (`--workers N`, default
  `CPU * 2`); excess returns 503.
- `LISTEN_FDS` env var for systemd socket activation.
- Graceful shutdown on `SIGINT` / `SIGTERM`.

### Added — Scaffolder

- `verve-cli new <dir>` writes the entire Verve source tree
  (sources + build wiring + test fixtures) into a target
  directory, emitting a fresh `build.zig.zon` with the chosen
  package name. Generated apps are self-contained — no Zig
  package-manager dependency, no git clone.

### Added — Build + tooling

- `zig build` produces a single-binary `verve-server` with the
  WASM client, per-island chunks, JS bridge, public assets, and
  manifest baked in. Plus `verve-cli` for scaffolding.
- `zig build test` runs 155+ tests spanning core / server /
  client / integration suites.
- `zig build docs` emits Zig autodoc HTML/JS to
  `zig-out/docs/api/`.
- 18 handwritten topic guides under `docs/`.
- 8 runnable example apps under `examples/`, including a full
  hybrid-product `showcase`.
- CI matrix (ubuntu-latest + macos-latest) runs `zig fmt`,
  `zig build`, `zig build test`, plus curl smoke tests against
  the live binary.

### Deferred (tracked for the 0.x line)

- **Phase 13F** — export the main runtime's Signal-registration
  + DOM-primitive symbols to per-island chunk imports so chunks
  can wire reactive state from inside their own `hydrate` body.
- **Phase 14C** — async `ctx.fetch` over `std.Io.async`
  (gated on Zig 0.16 ecosystem) so parked Suspense boundaries
  can genuinely wait on an upstream rather than re-running
  synchronously.
- **Typed WASM-side value returns** from server-fn calls
  (depends on Phase 14C's continuation shape).
- **Native TLS server** — production path today is to terminate
  TLS at a reverse proxy; revisit when `std.crypto.tls.Server`
  ships.
- **Brotli encoder** — gzip on the fly + precomputed `.br`
  siblings cover production today; revisit when a vetted
  pure-Zig brotli encoder lands.

[Unreleased]: https://github.com/sirhco/verve/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/sirhco/verve/releases/tag/v0.1.0
