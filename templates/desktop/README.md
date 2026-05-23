# Verve desktop app

Scaffolded by `verve-cli new --desktop`. The binary opens a native
window backed by the OS's standard webview (WKWebView on macOS,
WebView2 on Windows, WebKitGTK on Linux) and serves the bundled
`frontend/` tree through a custom `verve://app/` URL scheme.

## Run

```sh
zig build run
```

The build wires platform-native libraries automatically per target.

## Platform prerequisites

- **macOS**: WebKit/Cocoa ship with the OS. Nothing to install.
- **Windows**: requires the Microsoft Edge WebView2 Evergreen runtime.
  Win11 ships with it; Win10 may not. Install from
  <https://developer.microsoft.com/microsoft-edge/webview2/> and copy
  the `WebView2Loader.dll.lib` into `third_party/webview2/` (or pass
  `-Dwebview2-sdk=PATH`).
- **Linux (Debian/Ubuntu)**: `sudo apt install libgtk-3-dev libwebkit2gtk-4.1-dev`.
- **Linux (Fedora)**: `sudo dnf install gtk3-devel webkit2gtk4.1-devel`.

## Project layout

```
src/main.zig         Entry point — opens Window, runs event loop.
src/handlers.zig     Example IPC routes.
src/desktop/         Platform abstraction (vendored, do not edit casually).
frontend/            HTML/JS/CSS served via `verve://app/*`.
public/              Optional extra assets.
```

## Smoke test (macOS)

```sh
zig build smoke
```

Launches the app, waits for its window to appear, captures a
screenshot to `./.smoke/shot.png`, and validates the image is
non-trivial. The `osascript` window-id lookup needs Accessibility
access; the screenshot itself needs Screen Recording permission. Grant
both to the terminal (or CI runner) under
**System Settings → Privacy & Security**.

Override via env vars:
- `SMOKE_MIN_BYTES` — minimum acceptable PNG size (default 5000)
- `SMOKE_WAIT_SECS` — paint settling delay (default 1.5)
- second arg — output directory (default `./.smoke`)

## IPC

Frontend → Zig:

```js
window.verve.send(JSON.stringify({ type: "ping", payload: 42 }));
```

Zig → Frontend:

```zig
window.evalJs("window.verve._dispatch({ type: \"pong\", value: 43 })");
```

See `src/handlers.zig` for routing.
