# Verve desktop runtime

`src/desktop/` is the platform-abstraction layer that powers
`verve-cli new --desktop`. It exposes one unified `Window` type backed
by each OS's native webview:

| Host    | Window         | Webview      | Backend file |
| ------- | -------------- | ------------ | ------------ |
| macOS   | `NSWindow`     | `WKWebView`  | `macos.zig`  |
| Windows | Win32 `HWND`   | WebView2     | `windows.zig`|
| Linux   | `GtkWindow`    | WebKitGTK    | `linux.zig`  |

No Chromium is bundled. macOS uses the system WebKit, Windows relies
on the user-installed Edge WebView2 Evergreen runtime, and Linux loads
WebKitGTK from the distro package set.

## Pieces

- `window.zig` — public façade. Comptime-dispatches to the matching
  backend by `builtin.os.tag` and re-exports `Window`. Includes a
  comptime backend-conformance check that fails fast if a backend
  drops a required method.
- `options.zig` — `WindowOptions`, `AssetEntry`, `MessageHandler`,
  `FileDialogOptions`, `AlertOptions`, `Cookie`, `SameSite`,
  `DialogError`, `CookieError`, `SnapshotError`. The asset table
  reuses the shape `build.zig:buildPublicAssets` produces, so a
  desktop app can pass `public_assets.entries` directly.
- `asset_router.zig` — pure-Zig resolver for the `verve://app/<path>`
  custom URL scheme. Linear scan over the entry table; MIME guess
  from extension; static result, no allocations. Mime table covers
  `wasm` → `application/wasm` and `mjs`/`js` →
  `application/javascript` for `WebAssembly.instantiateStreaming`
  under the custom scheme.
- `ipc.zig` — document-start JS shim. Defines `window.verve.send`,
  `window.verve.request` (Promise correlated via internal
  `__verve_id`), `window.verve.onMessage`, and `window.verve._dispatch`
  once per page load.
- `ipc_router.zig` — `Router(Ctx, Routes)` comptime typed router.
  Each route declares `Args` + `Reply` types; the router
  JSON-parses the inbound payload against an arena allocator, calls
  the handler, JSON-encodes the reply, and ships it through
  `evalJs("window.verve._dispatch(...)")`.
- `cookies.zig` — `CookieStore` comptime dispatch facade. Backend
  impls plug in via `@hasDecl` checks. Each backend wraps its
  platform-native async cookie manager in a sync facade.
- `macos.zig` / `windows.zig` / `linux.zig` — backends. Each one
  registers the custom scheme handler, attaches the IPC shim, hooks
  the postMessage channel, manages a per-window `WindowCtx`, and
  owns the platform event loop. Per-platform ctx-routing strategies:
  - macOS: `AutoHashMap` keyed by WKWebView ptr
  - Windows: embedded back-pointer in COM handler structs + AutoHashMap keyed by HWND
  - Linux: native `user_data` threaded through GSignal + per-window `webkit_web_context_new()`
- `msg.zig` — Objective-C `objc_msgSend` cast helper used only by
  the macOS backend (avoids Zig 0.16's restrictions on calling C
  variadics). Header comment documents the ABI audit findings (no
  `_stret` needed; NSRect is HFA; BOOL = `_Bool` on 64-bit darwin).
- `asset_router_test.zig` — aggregator test entry imported by
  `zig build test`. Pulls in `cookies_test.zig` (Cookie defaults +
  SameSite stability + CookieStore method presence) and
  `surface_test.zig` (WindowOptions defaults, ipc.shim_js markers,
  AssetEntry ABI shape).

## Lifecycle

```
Window.init(opts)
  ├─ create native window
  ├─ register `verve://` scheme handler
  ├─ add `verve` script-message handler
  ├─ inject ipc.shim_js at document-start
  └─ navigate to `verve://app/<initial_path>`

(running event loop)

frontend              backend                Zig
--------              -------                ---
window.verve.send  → platform postMessage → MessageHandler(payload)
                                              ↓
                                            std.json.parseFromSlice
                                              ↓
                                            Router.dispatch (typed)
                                              ↓
                                            evalJs(_dispatch reply)
                                              ↓
window.verve.onMessage listeners fire
window.verve.request promise resolves
```

## Cross-platform method surface

The `comptime` block in `window.zig` enforces that every backend
exposes:

```
init, setTitle, loadUrl, loadHtml, evalJs, setMessageHandler, run,
deinit, terminate, close, openFileDialog, saveFileDialog, showAlert,
openChildWindow, cookies, takeSnapshotPng
```

Stubs returning `error.Unsupported` are acceptable where the OS lacks
the underlying primitive — the surface still compiles cross-platform.
Today: `openFileDialog`, `saveFileDialog`, `showAlert`,
`takeSnapshotPng` are macOS-only with Win/Linux stubs.

## Async-to-sync wrappers (cookies + snapshot)

Several platform APIs are inherently async (completion blocks on
macOS, COM completion handlers on Windows, `GAsyncReadyCallback` on
Linux). The desktop surface exposes them as sync Zig calls via three
pieces:

1. **NSBlock impostor / COM handler struct / GAsyncReadyCallback cell**
   — a Zig extern struct laid out to match the platform ABI so we
   can construct callbacks without `__block` syntax / COM macros /
   GLib helpers.
2. **`done: *bool` capture** — the callback flips this to true.
3. **Nested event-loop pump** —
   `pumpUntilDone(done)` spins `[NSRunLoop runMode:beforeDate:]`
   (macOS), Win32 message pump (Windows), or
   `g_main_context_iteration` (Linux) until the bool flips.

Trade-off: the nested loop processes other input sources, so callers
must be re-entrant safe. Cookie/snapshot calls from IPC handlers are
fine (the IPC handler IS the active call stack). Calls from inside
another modal run loop (a file picker, for example) are risky.

## Platform prerequisites

- **macOS**: ships with WebKit. No install needed. Builds against
  the `Cocoa`, `WebKit`, and `Foundation` frameworks.
- **Windows**: requires the Edge WebView2 Evergreen runtime. Win11
  has it preinstalled; Win10 returns a failing HRESULT. The build-
  time SDK is auto-vendored via `tools/fetch_webview2.{sh,ps1}`.
- **Linux**: install `libgtk-3-dev` + `libwebkit2gtk-4.1-dev`
  (Debian/Ubuntu) or `gtk3-devel` + `webkit2gtk4.1-devel` (Fedora).

## GTK4 follow-up

WebKitGTK 6.0 (GTK4) is the next-generation toolkit but ships on
fewer LTS distros today. The platform-neutral surface in `window.zig`
does not change between toolkits, so a second backend can be added
later behind a `-Dgtk4` build option without touching call sites.
