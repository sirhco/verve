# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What Verve is

Full-stack **pure-Zig** framework (targets **Zig 0.16.0**, zero third-party deps) for both web apps and native desktop apps. Server-side rendering of `*Node` trees with fine-grained reactivity (`Signal`/`Effect`/`Owner`/`Resource`), a wasm32-freestanding client runtime that hosts that *same* reactive graph, per-island WASM code-splitting, and single-binary distribution. The same component tree + reactive runtime + asset pipeline drives an HTTP server **or** a native window backed by the OS webview (WKWebView / WebView2 / WebKitGTK) — target picked at `zig build` time. No VDOM, no macros, no Chromium, no Electron.

Pre-1.0 (v0.3.x): public APIs break between minor versions. All three desktop backends (macOS, Windows, Linux GTK4) are verified on real hardware as of v0.2.0. `CHANGELOG.md` tracks releases.

## Commands

```sh
zig build                        # native HTTP server + wasm client + per-island chunks → zig-out/bin/{verve-server,verve-cli}
zig build run                    # build + run the full-stack server (http://127.0.0.1:8080)
zig build test --summary all     # full suite: core + server + client + integration + desktop
zig build docs                   # Zig autodoc for public verve module → zig-out/docs/api/index.html
zig fmt --check build.zig src tests   # format gate

# Scaffold a new project
./zig-out/bin/verve-cli new ~/my-app               # web app (default)
./zig-out/bin/verve-cli new ~/my-app --desktop     # desktop app (OS webview)
```

`zig build test` runs five grouped suites wired in `build.zig`: core (`run_tests`), server, client (wasm data structures, run on native), integration (spawns `verve-server`, hits every endpoint), and desktop (pure-Zig pieces only — native backends not exercised). There is **no `-Dtest-filter` flag wired**; to narrow, run a single suite's module or its source file directly with `zig test`.

## Architecture

Source under `src/` splits into framework vs. user-app vs. target runtimes:

- **`src/core/`** — framework primitives, target-agnostic: `node.zig` (the `*Node` tree), `signal`/`effect`/`owner`/`resource`/`store` (reactive graph), `renderer`, `route`, `context` (the `ctx` passed to every render fn), `head`, `i18n`, `markdown`/`highlight` (server-side, replaces marked/highlight.js), `island`, `island_state`, `server_fn`, `csrf`, `sanitize`.
- **`src/verve.zig`** — the **public module surface**: re-exports everything apps are allowed to touch (`Node`, `Signal`, `Route`, `Context`, `island`, `createResource`, i18n helpers, …). This is the `verve` import in app code. Treat it as the API boundary.
- **`src/app/`** — the **user-editable demo app**, the part you change to build a site: `routes.zig` (the route table — `verve.Route.init(path, renderFn)`, `.layout(...)`, `.protect(guard)`), `components.zig`, `api.zig`, `islands.zig` (island registry — see below).
- **`src/server/`** — HTTP server: `router`, `api_handler`, `pool`, `metrics`, `gzip`, `public_dir`.
- **`src/client/`** — wasm32-freestanding client runtime: `signal`, `dom`, `render`, `runtime`, `island_runtime`, plus per-island impls in `src/client/islands/`.
- **`src/desktop/`** — three native backends behind one platform layer (`backend.zig` single-sources the selection): `macos.zig` (objc runtime + WKWebView), `windows_native.zig` (a thin Zig shim over a native C++ WebView2 host, `win_native/webview2_host.cpp`, behind a flat C ABI in `win_native/host.h`), `linux.zig` (GTK 3 + WebKit 4.1); plus `asset_router`, `ipc`/`ipc_router`, `clipboard`, `tray`, `notifications`, `deep_link`, etc. The framework **core stays pure-Zig**; the desktop native hosts are thin platform glue. Assets served to the webview over a `verve://` URL scheme from the embedded asset table.
- **`src/bridge/verve.js`** — the JS bridge loaded in the browser/webview.
- **`src/cli/main.zig`** — the scaffolder (`verve-cli new`).
- **`tools/`** — build-time codegen binaries invoked by `build.zig`: `server_fn_codegen.zig` (server-fn stubs) and `island_manifest_gen.zig` (client manifest). They must travel with the scaffold.

### Islands

An island is declared as a `pub const <Name> = struct { pub const props_schema = "..."; };` in `src/app/islands.zig`. Each decl becomes an entry in the build-time `client_manifest.zig`, powering both the SSR marker and the JS-side hydrator lookup. This declaration is intentionally decoupled from `verve.island(...)` calls in component code. The client-side hydrator implementation lives in `src/client/islands/<Name>.zig`.

### build.zig as embed pipeline

`build.zig` does more than compile: `verve-cli` embeds the **entire source tree** (`src`, `tests`, `tools`, build wiring) into its own binary via `@embedFile` (the `skeleton*` modules), so `verve-cli new` writes out a self-contained app with no compile-time dependency back on this checkout. Build steps guard on `tests_present` / `have_templates` (`templates/desktop`, `templates/desktop-minimal`) and degrade gracefully: when Verve is consumed as a Zig package, `build.zig.zon`'s `.paths` ship only `src` + `LICENSE`, so test/template artifacts must be skipped rather than panic.

## Gotchas

- **Fluent chain API, not struct literals.** Routes return `!*verve.Node`. Build node trees with `ctx` factory methods + chain methods (`ctx.h1(...)`, etc.), not POD struct literals.
- **For-loop pointer capture.** When a slice element's address (`&item`) is stored into the Node tree, `for (slice) |item|` captures by value and the pointer dangles. Use `for (slice) |*item|`.
- **`docs/11-desktop-roadmap.md`** is authoritative for the desktop workstream.

## Docs

`docs/` holds 22 numbered topic guides (`01-getting-started` … `22-visualization`); `docs/README.md` is the index. `examples/` has runnable apps including `examples/showcase/`. Note: counts/specs in older docs (e.g. getting-started's "37 tests") may lag the README — trust `build.zig` and the README.
