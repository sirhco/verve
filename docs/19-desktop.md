# 19 — Desktop apps

Verve ships a native-desktop scaffold alongside the HTTP server. The
desktop binary opens an OS-native window (WKWebView on macOS,
WebView2 on Windows, WebKitGTK on Linux), serves all assets through
a custom `verve://app/` URL scheme, runs the framework's SSR
pipeline at build time, and hydrates the page with a wasm client
compiled from your project. No Chromium bundled. No Electron.

## Quickstart

```sh
# 1. Build the framework + verve-cli
zig build

# 2. Scaffold a desktop project
./zig-out/bin/verve-cli new ~/code/my-app --desktop --name=my_app

# 3. Build + run the new project
cd ~/code/my-app
zig build run
```

The first window opens with a demo page that exercises every wired
feature (typed IPC, cookies, multi-window, WASM-hydrated counter).

## Layout the scaffolder writes

```
my-app/
├── build.zig                            ← per-OS link wiring + bundle + smoke + dev steps
├── build.zig.zon                        ← verve path-baked + canonicalised
├── README.md                            ← full feature docs (see scaffold's README)
├── LICENSE
├── src/
│   ├── main.zig                         ← opens Window, runs event loop
│   ├── components.zig                   ← Verve component tree (SSR'd at build time)
│   ├── handlers.zig                     ← typed IPC routes (Router pattern)
│   ├── client/main.zig                  ← WASM client (wasm32-freestanding)
│   └── desktop/                         ← framework's platform layer, vendored
├── frontend/
│   ├── style.css
│   └── verve_desktop.js                 ← bridge: fetches client.wasm + hydrates
├── tools/
│   ├── render_index.zig                 ← build-time SSR binary
│   ├── dev.zig                          ← dev-loop watcher
│   ├── smoke_{macos,linux,windows}.{sh,ps1}
│   ├── fetch_webview2.{sh,ps1}          ← Windows: auto-vendor WebView2 SDK
│   └── webview2.pinned.txt
├── tests/golden/
│   └── checksum.txt                     ← smoke harness golden
└── public/                              ← optional extra assets (-Dpublic-dir override)
```

The scaffolder bakes the framework's `src/desktop/` tree into the
project so the app builds without depending on the Verve repo
checkout staying alive at the original path. Update the dep via
`zig fetch --save <release-url>` once a release is tagged.

## Build steps

| Step | Effect |
|------|--------|
| `zig build` | Compile native exe + wasm client + SSR'd index.html |
| `zig build run` | Build + open the window |
| `zig build dev` | Watch sources, auto-rebuild + respawn on change |
| `zig build smoke` | Level-3 golden-diff harness (macOS) |
| `zig build bundle` | Lay out `.app` (macOS): `Info.plist` + `MacOS/<name>` |
| `zig build codesign` | Sign the bundle (when `-Dcodesign=<identity>` is set) |
| `zig build test` | Any zig tests in the project |

## Feature surface

The desktop scaffold's `README.md` is the authoritative API + feature
reference. Headline list:

- **SSR pipeline** — Verve `Node` tree → `Renderer.render` → embedded
  `index.html` at build time
- **WASM hydration** — `src/client/main.zig` compiled to
  wasm32-freestanding, served at `verve://app/client.wasm`, seeded
  by `verve_init_*` exports and click-delegated via `z-on-click`
- **Typed IPC** — `desktop.Router(Ctx, Routes)` with `Args`/`Reply`
  types per route; JS callers `await window.verve.request({type, ...})`
- **Cookies** — per-window `CookieStore` with `set`/`get`/`delete`/`clear`,
  real implementations on all three backends (sync wrappers around
  platform-native async cookie managers)
- **Multi-window** — `Window.openChildWindow(opts)`; last-window-quit
  semantics on all three platforms
- **Native dialogs** — `Window.openFileDialog`, `saveFileDialog`,
  `showAlert`. macOS uses NSOpenPanel/NSSavePanel/NSAlert; Linux uses
  `GtkFileChooserNative` + `GtkMessageDialog`; Windows uses
  `GetOpenFileNameW` / `GetSaveFileNameW` (`comdlg32`) + `MessageBoxW`.
  Per-platform caveats: Win32 alerts honor the button *count* (1/2/3
  → MB_OK / MB_YESNO / MB_YESNOCANCEL) but not arbitrary labels;
  directory-picking via `pick_directory` is macOS + Linux only on this
  surface (Win32 splits dir-picking into `IFileOpenDialog` — port TBD).
- **Native menu bar (macOS)** — App + Edit + Window menus stamped by
  default (`install_default_menu = true`); Edit menu is what makes
  Cmd+C / Cmd+V actually fire inside WKWebView text inputs
- **Window snapshot** — `Window.takeSnapshotPng(path)` ships on all
  three backends. macOS uses
  `WKWebView.takeSnapshotWithConfiguration:completionHandler:` →
  NSBitmapImageRep → PNG. Linux uses
  `webkit_web_view_get_snapshot` (async, GMainContext-pumped) →
  cairo surface → `cairo_surface_write_to_png`. Windows uses
  `ICoreWebView2::CapturePreview` (PNG format, message-pumped) into
  an `SHCreateStreamOnHGlobal` IStream, then writes via `CreateFileW` /
  `WriteFile`.
- **macOS `.app` bundle** — `zig build bundle` + `-Dbundle-id` /
  `-Dbundle-version` / `-Dcodesign`
- **WebView2 auto-vendor** — Windows builds fetch the pinned SDK
  from NuGet on first build (idempotent)
- **Dev loop** — `zig build dev` watches sources, rebuilds, respawns
- **`--dev <dir>` runtime fallback** — scheme handler tries
  `<dir>/<path>` before the embedded asset table on every request, so
  hand-written frontend assets (`style.css`, `verve_desktop.js`, …)
  hot-reload with Cmd+R instead of a rebuild. Rejects `..` and
  post-strip absolute paths; 16 MB per-file cap.
- **Level-3 smoke** — golden-diff CI: scripted interaction sequence
  computes a DOM checksum + captures PNG, build step diffs vs
  `tests/golden/`

See [`templates/desktop/README.md`](../templates/desktop/README.md)
in the scaffolded project for the full API reference (Window
methods, `WindowOptions` fields, build flags, runtime flags) and a
[platform support matrix](../templates/desktop/README.md#platform-support-matrix)
showing which features are ✓ vs `stub` per backend.

## Architecture (internal)

The framework's [`src/desktop/README.md`](../src/desktop/README.md)
covers the platform abstraction layer in depth — how the comptime
dispatch in `window.zig` selects a backend, the per-platform ctx-
routing strategies for multi-window, and the async-to-sync wrappers
that turn completion-handler APIs (cookies, snapshot) into blocking
Zig calls via nested event-loop pumps.

## Platform support matrix

| Feature | macOS | Windows | Linux |
|---------|-------|---------|-------|
| Window lifecycle | ✓ | ✓ | ✓ |
| Custom-scheme assets | ✓ | ✓ | ✓ |
| IPC + typed Router | ✓ | ✓ | ✓ |
| Cookies | ✓ | ✓ | ✓ |
| Multi-window | ✓ | ✓ | ✓ |
| WASM hydration | ✓ | ✓ | ✓ |
| File / save dialogs | ✓ | ✓ (file only) | ✓ |
| Alerts | ✓ | ✓ (standard buttons) | ✓ |
| Native menu bar | ✓ | — | — |
| Window snapshot (PNG) | ✓ | ✓ | ✓ |
| `.app` bundle | ✓ | — | — |
| Level-3 smoke | ✓ | — | — |
| Dev-loop watcher | ✓ | ✓ | ✓ |
| `--dev` runtime fallback | ✓ | ✓ | ✓ |

✓ = real implementation. `stub` = the API exists and returns
`error.Unsupported` so cross-platform call sites compile.
— = not on the cross-platform surface yet.

## Roadmap status

All P1 desktop items per `docs/11-desktop-roadmap.md` are closed.
Remaining work is P2/P3 follow-ups: GTK4 + WebKitGTK 6.0 backend,
native menu bars on Windows + Linux, tray icons + system
notifications, drag-drop / clipboard programmatic access, deep-link
URL handlers, runtime disk-read fallback (true HMR), app icons /
icns / hicolor theme, accessibility (NSAccessibility / UIA / ATK),
auto-updater (Sparkle / Squirrel).

## Constraints

- The framework's public web surface (`src/verve.zig`) is unchanged
  by the desktop work — anything desktop-specific lives in
  `src/desktop/` or the template tree. A Verve web app and a Verve
  desktop app share the same `Node` / `Context` / `Renderer` API.
- The scaffolded project does not depend on a running HTTP server.
  All asset serving is in-process via the custom-scheme handler;
  there is no `/api/*`, `/ws`, `/events`, or `/islands/*` route, so
  the desktop bridge (`verve_desktop.js`) is a strict subset of the
  server-side bridge (`src/bridge/verve.js`).
