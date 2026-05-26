# Verve Desktop — minimal scaffold

A single-window native desktop app embedding the OS standard webview
(WKWebView on macOS, WebView2 on Windows, WebKitGTK on Linux). One IPC
route, one HTML page. Use this as a starting point.

For the demo-rich scaffold (cookies, multi-window, WASM hydration,
tray, notifications, deep links, print, …) generate with
`verve-cli new <dir> --desktop` (no `--template` flag).

## Run

```sh
zig build
./zig-out/bin/app
```

Type a name, click **Greet** → the page shows the greeting. The button
calls a Zig IPC handler that formats the string server-side and replies
over the bridge.

## Layout

```
build.zig              native link wiring + asset embedding
build.zig.zon          deps (verve)
src/
  main.zig             window init + IPC wiring + event loop
  handlers.zig         greet IPC route
  desktop/             vendored platform layer (do not edit)
frontend/
  index.html           single page
  style.css            responsive styling
public/                drop-in static files (served alongside frontend/)
tools/                 WebView2 SDK auto-vendor scripts (Windows)
```

## IPC

The bridge auto-injects `window.verve` at document-start. Use:

```js
const reply = await window.verve.request({ type: "greet", name: "Ada" });
// reply.message === "Hello, Ada"
```

Routes are declared as a comptime table in `src/handlers.zig` — each
public decl is a route with `Args`, `Reply`, and a `handle` fn.

## Platform notes

- **macOS**: bundles fine with `Cocoa` + `WebKit`. No extra deps.
- **Windows**: the build auto-downloads the pinned WebView2 SDK to
  `third_party/webview2/` on first run.
- **Linux**: needs `gtk+-3.0` + `webkit2gtk-4.1` dev packages.
