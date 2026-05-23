# Verve desktop runtime

`src/desktop/` is the platform-abstraction layer that powers
`verve new --desktop`. It exposes one unified `Window` type backed by
each OS's native webview:

| Host    | Window         | Webview      | Backend file |
| ------- | -------------- | ------------ | ------------ |
| macOS   | `NSWindow`     | `WKWebView`  | `macos.zig`  |
| Windows | Win32 `HWND`   | WebView2     | `windows.zig`|
| Linux   | `GtkWindow`    | WebKitGTK    | `linux.zig`  |

No Chromium is bundled. macOS uses the system WebKit, Windows relies
on the user-installed Edge WebView2 Evergreen runtime, and Linux loads
WebKitGTK from the distro package set.

## Pieces

- `window.zig` — the public façade. Comptime-dispatches to the matching
  backend by `builtin.os.tag` and re-exports `Window`.
- `options.zig` — `WindowOptions`, `AssetEntry`, `MessageHandler`. The
  asset table reuses the same shape `build.zig:buildPublicAssets`
  produces, so a desktop app can pass `public_assets.entries` directly.
- `asset_router.zig` — pure-Zig resolver for the `verve://app/<path>`
  custom URL scheme. Linear scan over the entry table; MIME guess from
  extension; static result, no allocations.
- `ipc.zig` — document-start JS shim. Defines `window.verve.send` and
  `window.verve.onMessage` once per page load.
- `macos.zig` / `windows.zig` / `linux.zig` — backends. Each one
  registers the custom scheme handler, attaches the IPC shim, hooks the
  postMessage channel, and owns the platform event loop.
- `msg.zig` — Objective-C `objc_msgSend` cast helper used only by the
  macOS backend (avoids Zig 0.16's restrictions on calling C variadics).
- `asset_router_test.zig` — headless unit test wired into
  `zig build test` so the module participates in CI on every host.

## Lifecycle

```
Window.init(opts)
  ├─ create native window
  ├─ register `verve://` scheme handler
  ├─ add `verve` script-message handler
  ├─ inject ipc.shim_js at document-start
  └─ navigate to `verve://app/<initial_path>`

(running event loop)

frontend            backend                Zig
--------            -------                ---
window.verve.send → platform postMessage → MessageHandler(payload)
                                            ↓
                                          std.json.parseFromSlice
                                            ↓
                                          dispatch + (optional reply)
                                            ↓
Window.evalJs("window.verve._dispatch(...)")
   ↓
window.verve.onMessage listeners fire
```

## Platform prerequisites

- **macOS**: ships with WebKit. No install needed. Builds against the
  `Cocoa`, `WebKit`, and `Foundation` frameworks.
- **Windows**: requires the Edge WebView2 Evergreen runtime. Win11 has
  it preinstalled; on Win10 the loader returns a failing HRESULT and
  the runtime prints
  `https://developer.microsoft.com/microsoft-edge/webview2/`.
- **Linux**: install `libgtk-3-dev` + `libwebkit2gtk-4.1-dev` (Debian/
  Ubuntu) or `gtk3-devel` + `webkit2gtk4.1-devel` (Fedora).

## GTK4 follow-up

WebKitGTK 6.0 (GTK4) is the next-generation toolkit but ships on fewer
LTS distros today. The platform-neutral surface in `window.zig` does
not change between toolkits, so a second backend can be added later
behind a `-Dgtk4` build option without touching call sites.
