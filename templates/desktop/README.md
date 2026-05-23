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
- **Windows**: requires the Microsoft Edge WebView2 Evergreen runtime
  at run time. Win11 ships with it; Win10 may not — install from
  <https://developer.microsoft.com/microsoft-edge/webview2/>. The
  build-time SDK (`WebView2Loader.dll.lib`) is fetched automatically
  by `tools/fetch_webview2.ps1` when `third_party/webview2/` is empty;
  the script honours the version pinned in
  `tools/webview2.pinned.txt`. To skip the fetch (CI cache hits, air-
  gapped builds) pass `-Dwebview2-no-fetch=true` and supply the SDK
  via `-Dwebview2-sdk=PATH`.
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
window.verve.send({ type: "ping", payload: 42 });
```

Zig → Frontend:

```zig
window.evalJs("window.verve._dispatch({ type: \"pong\", value: 43 })");
```

`window.verve` is injected at document-start, so it is available to
inline scripts immediately — no `verve:ready` event listener needed.

See `src/handlers.zig` for routing.

## Cookies

Per-window cookie store. Sync wrappers around the platform-native
async cookie manager:

```zig
const store = window.cookies();
try store.set(.{ .name = "session", .value = "abc123", .domain = "localhost" });
const got = try store.get(allocator, "session");
if (got) |c| { /* c.name, c.value, c.domain, c.path are allocator-owned */ }
try store.delete("session");
try store.clear();
```

`Cookie` fields default to `path="/"`, no expiry (session cookie),
`secure=false`, `http_only=false`, `same_site=.default`. Returned
strings are allocator-owned — free `name`/`value`/`domain`/`path`
after use.

The scaffolded frontend includes Set / Get / Clear demo buttons
wired through the `cookie_set` / `cookie_get` / `cookie_clear` IPC
routes in `src/handlers.zig`.

## Multi-window

`Window.openChildWindow(opts)` mints a second window in the same app
session, sharing the parent allocator. The app terminates when the
last live window closes (Cocoa tracks this natively on macOS; Win32
and GTK do it through internal counters).

```zig
const child = try window.openChildWindow(.{
    .title = "Inspector",
    .width = 640,
    .height = 400,
    .assets = asset_entries,
    .initial_path = "inspector.html",
});
```

The demo `Open child window` button uses the same `index.html` for
the child.
