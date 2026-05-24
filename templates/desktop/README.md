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
src/components.zig   Verve component tree — rendered to HTML at build time.
src/client/main.zig  WASM client — compiled to wasm32-freestanding.
src/desktop/         Platform abstraction (vendored, do not edit casually).
tools/render_index.zig  Build-time SSR binary — walks components.page().
frontend/style.css   Static stylesheet (CSS, fonts, images go here).
frontend/verve_desktop.js  Desktop bridge — fetches client.wasm + hydrates.
public/              Optional extra assets.
```

## SSR pipeline

The window's main HTML is produced at build time by walking a Verve
`Node` tree, not handwritten:

1. `src/components.zig` defines `home(ctx)` and `page(ctx, body)` using
   the framework's fluent factory API (`ctx.div().class(...).children(...)`).
2. `tools/render_index.zig` runs during `zig build` as a host-target
   program. It imports `verve` + `components`, constructs the tree, and
   prints HTML to stdout via `verve.Renderer.render`.
3. `build.zig` captures that stdout into `index.html` via
   `addRunArtifact(...).captureStdOut(...)` and overlays it onto the
   `public_assets` table — so the on-disk `frontend/` directory holds
   static assets only (CSS + the bridge JS), while `index.html` is
   regenerated on every build.

To change the markup, edit `src/components.zig`. To add stylesheets or
images, drop them in `frontend/` and reference them by path.

## WASM hydration

Interactive state lives in `src/client/main.zig`, compiled to
`wasm32-freestanding` (ReleaseSmall) and served at
`verve://app/client.wasm`. The `verve_desktop.js` bridge in
`frontend/` instantiates it and wires it up:

- Every `verve_init_<bind>` export is matched to `[z-bind="<bind>"]`
  in the SSR'd DOM and seeded with the parsed `i32` text content.
- After seeding, `verve_hydrate()` runs once for final setup.
- Click delegate dispatches `[z-on-click="<name>"]` to the matching
  WASM export.

To add a new reactive piece:

1. Mark the element in `components.zig` with `.bind("name")` and an
   initial value via `.textInt(0)` or `.text("...")`.
2. Add a `verve_init_name(value: i32)` export in
   `src/client/main.zig` to receive the seed.
3. Update state inside an `export fn handler() void` and call the
   `set_text_by_bind_*` extern to re-render the bound element.
4. Wire any UI control with `.onClick("handler")` to dispatch the
   handler.

The wasm currently uses direct DOM externs (no reactive graph yet).
Once `verve.Signal` is exposed for `wasm32-freestanding`, the
`verve_hydrate` body becomes the place to register signals + on_set
hooks for fine-grained updates.

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
