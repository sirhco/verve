# Verve desktop app

Scaffolded by `verve-cli new --desktop`. Opens a native OS window
backed by the system webview (WKWebView on macOS, WebView2 on
Windows, WebKitGTK on Linux) and serves all assets through a custom
`verve://app/` URL scheme. No Chromium bundled. No Electron.

The framework's SSR + WASM pipeline runs end-to-end: a Verve `Node`
tree is rendered to HTML at build time, a tiny wasm client is
compiled from your `src/client/main.zig`, and a stripped JS bridge
fetches + hydrates the page under the custom scheme.

## Quickstart

```sh
zig build run     # build + open the window
zig build dev     # watch sources, auto-rebuild + respawn
zig build smoke   # Level-3 golden-diff harness (macOS)
zig build bundle  # macOS .app bundle (Info.plist + Mach-O)
zig build test    # any zig tests in the project
```

## Platform prerequisites

- **macOS**: WebKit/Cocoa ship with the OS. Nothing to install.
- **Windows**: requires the Microsoft Edge WebView2 Evergreen runtime
  at run time. Win11 ships with it; Win10 may not — install from
  <https://developer.microsoft.com/microsoft-edge/webview2/>. The
  build-time SDK (`WebView2Loader.dll.lib`) is fetched automatically
  by `tools/fetch_webview2.ps1` when `third_party/webview2/` is empty;
  the script honours the version pinned in `tools/webview2.pinned.txt`.
  To skip the fetch (CI cache hits, air-gapped builds) pass
  `-Dwebview2-no-fetch=true` and supply the SDK via `-Dwebview2-sdk=PATH`.
- **Linux (Debian/Ubuntu)**: `sudo apt install libgtk-3-dev libwebkit2gtk-4.1-dev`
- **Linux (Fedora)**: `sudo dnf install gtk3-devel webkit2gtk4.1-devel`

## Project layout

```
src/main.zig         Entry point — opens Window, runs event loop.
src/handlers.zig     Typed IPC routes (Router pattern).
src/components.zig   Verve component tree — rendered to HTML at build time.
src/client/main.zig  WASM client — compiled to wasm32-freestanding.
src/desktop/         Platform abstraction (vendored, do not edit casually).
tools/render_index.zig  Build-time SSR binary — runs verve.Renderer.
tools/dev.zig        Dev-loop watcher — rebuild + respawn on file change.
tools/fetch_webview2.{sh,ps1}  WebView2 SDK auto-vendor (Windows).
frontend/style.css   Static stylesheet (CSS, fonts, images go here).
frontend/verve_desktop.js  Desktop bridge — fetches client.wasm + hydrates.
public/              Optional extra assets.
tests/golden/        Smoke-harness goldens (checksum + reference shot).
```

## SSR pipeline

The window's main HTML is produced at build time by walking a Verve
`Node` tree:

1. `src/components.zig` defines `home(ctx)` and `page(ctx, body)`
   using the framework's fluent factory API
   (`ctx.div().class(...).children(...)`).
2. `tools/render_index.zig` runs during `zig build` as a host-target
   program. It imports `verve` + `components`, constructs the tree,
   and prints HTML to stdout via `verve.Renderer.render`.
3. `build.zig` captures that stdout into `index.html` via
   `addRunArtifact(...).captureStdOut(...)` and overlays it onto the
   `public_assets` table. The on-disk `frontend/` directory holds
   static assets only (CSS + bridge JS); `index.html` is regenerated
   on every build.

To change the markup, edit `src/components.zig`. To add stylesheets
or images, drop them in `frontend/` and reference them by path.

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

## IPC — typed Router (recommended)

The scaffold uses `desktop.Router(Ctx, Routes)` for typed,
request/response-style IPC between the frontend and Zig. Each route
declares its `Args` + `Reply` types; the router JSON-parses incoming
payloads, calls the handler with a per-dispatch arena, and ships the
reply back through `evalJs`. JS callers `await` a Promise that
resolves with the typed reply value.

### Define a route

```zig
// src/handlers.zig
const Routes = struct {
    pub const ping = struct {
        pub const Args  = struct { sent_at: i64 = 0 };
        pub const Reply = struct { echo: bool, sent_at: i64 };
        pub fn handle(_: *RouterCtx, _: std.mem.Allocator, args: Args) !Reply {
            return .{ .echo = true, .sent_at = args.sent_at };
        }
    };
};
```

`RouterCtx` is your own struct — typically holds the `*Window`, the
asset table, any per-app state. The handler receives a pointer to it
plus a per-dispatch arena allocator for any string allocation needed
to build the `Reply`.

### Call from JS

```js
const reply = await window.verve.request({ type: "ping", sent_at: Date.now() });
console.log(reply.echo, reply.sent_at);
```

The bridge correlates the response via an internal `__verve_id`
field. Fire-and-forget messages (no `await`) also work — handlers
that return a `Reply` simply log it unobserved.

### Wire the router in `main.zig`

```zig
window = try desktop.Window.init(allocator, .{ ..., .assets = asset_entries });
const ctx_ptr = handlers.attach(&window, asset_entries, smoke_dir, io);
window.setMessageHandler(handlers.onMessage, ctx_ptr);
window.run();
```

The two-step (init Window → attach handler → setMessageHandler) is
required because the Router needs a stable pointer to its Ctx, which
captures the Window pointer that itself didn't exist before init.

### Low-level send / dispatch

For non-typed messages you can still hit the raw channel:

```js
window.verve.send({ type: "log", message: "hi" });   // no reply
```

```zig
window.evalJs("window.verve._dispatch({ type: 'event', ... })");
```

## Window API reference

```zig
const desktop = @import("desktop");
```

### Construction

```zig
const window = try desktop.Window.init(allocator, .{
    .title          = "My App",                  // default "Verve"
    .width          = 1100,                       // default 1024
    .height         = 760,                        // default 768
    .devtools       = true,                       // default false
    .scheme         = "verve",                    // default "verve"
    .initial_path   = "index.html",               // default "index.html"
    .assets         = asset_entries,              // default &.{}
    .on_message     = null,                       // default null
    .on_message_ctx = null,                       // default null
    .install_default_menu = true,                 // all 3 platforms; default true
});
```

### Methods

| Method | Effect |
|--------|--------|
| `setTitle(text)` | Update title bar text |
| `loadUrl(url)` | Navigate the webview |
| `loadHtml(html, base_url)` | Load inline HTML |
| `evalJs(script)` | Run JS in the page context |
| `setMessageHandler(fn, ctx)` | Register the IPC callback |
| `run()` | Block on the platform event loop |
| `close()` | Close just this window (app keeps running) |
| `terminate()` | Quit the app (stops `run()` immediately) |
| `deinit()` | Release native resources |
| `openChildWindow(opts)` | Mint a second window in the same app session |
| `cookies()` | Return a `CookieStore` for this window |
| `openFileDialog(alloc, opts)` | Modal file picker (macOS); stub elsewhere |
| `saveFileDialog(alloc, opts)` | Modal save-as panel (macOS); stub elsewhere |
| `showAlert(opts)` | Modal alert dialog (macOS); stub elsewhere |
| `takeSnapshotPng(path)` | Render webview contents to PNG (macOS); stub elsewhere |
| `print()` | Open the native print dialog (legacy no-error wrapper) |
| `printWithOptions(opts)` | Native print dialog with cancel / unsupported / backend error reporting |

## Cookies

Per-window cookie store. Sync wrappers around the platform-native
async cookie manager:

```zig
const store = window.cookies();
try store.set(.{
    .name     = "session",
    .value    = "abc123",
    .domain   = "localhost",
    .path     = "/",
    .secure   = false,
    .http_only = false,
    .same_site = .lax,
});
const got = try store.get(allocator, "session");
if (got) |c| { /* c.name, c.value, c.domain, c.path are allocator-owned */ }
try store.delete("session");
try store.clear();
```

Defaults: `path="/"`, no expiry (session cookie), `secure=false`,
`http_only=false`, `same_site=.default`. Returned strings are
allocator-owned — free `name`/`value`/`domain`/`path` after use.

The scaffolded frontend includes Set / Get / Clear demo buttons wired
through the `cookie_set` / `cookie_get` / `cookie_clear` IPC routes
in `src/handlers.zig`.

## Multi-window

`Window.openChildWindow(opts)` mints a second window in the same app
session, sharing the parent allocator. The app terminates when the
last live window closes (Cocoa tracks this natively on macOS; Win32
and GTK do it through internal counters).

```zig
const child = try window.openChildWindow(.{
    .title         = "Inspector",
    .width         = 640,
    .height        = 400,
    .assets        = asset_entries,
    .initial_path  = "inspector.html",
    .scheme        = "verve",
});
```

The demo `Open child window` button reuses the same `index.html`.

Per-backend ctx-routing:
- macOS: HashMap keyed by WKWebView ptr
- Windows: COM handler structs embed a back-pointer + HashMap keyed by HWND
- Linux: native `user_data` threaded through GSignal + per-window
  `webkit_web_context_new()`

## Native dialogs (macOS)

```zig
// File picker
const path = window.openFileDialog(allocator, .{
    .title           = "Pick a file",
    .default_path    = "/Users/me",
    .allowed_extensions = &.{ "txt", "json" },
    .allow_multiple  = false,
    .pick_directory  = false,
}) catch |err| switch (err) {
    error.Cancelled => return,
    else => return err,
};
defer allocator.free(path);

// Save-as
const out = try window.saveFileDialog(allocator, .{
    .title        = "Save report",
    .default_name = "report.json",
    .allowed_extensions = &.{ "json" },
});
defer allocator.free(out);
```

Returns `error.Cancelled` if the user dismissed the panel.
Win/Linux backends return `error.Unsupported` — wrap the call in a
backend-aware code path if you need broader coverage.

## Native alerts (macOS)

```zig
const clicked_idx = window.showAlert(.{
    .title    = "Save changes?",
    .message  = "Your work will be lost.",
    .buttons  = &.{ "Save", "Discard", "Cancel" },
    .style    = .warning,   // .informational | .warning | .critical
});
// clicked_idx == 0 → first button, 1 → second, ...
```

`buttons` empty defaults to `["OK"]`. Win/Linux return 0.

## Native menu bar

The default `install_default_menu = true` stamps a menu bar on every
platform:

**macOS** — three menus on first window:

- **App menu** — Quit (Cmd+Q)
- **Edit menu** — Undo / Redo / Cut / Copy / Paste / Select All. The
  Edit menu is what makes WKWebView's keyboard clipboard shortcuts
  fire; without it, Cmd+C / Cmd+V in a text input does nothing.
- **Window menu** — Minimize / Close

**Windows + Linux** — File + Edit:

- **File menu** — Quit (Ctrl+Q). Routes through `WM_CLOSE` (Win) or
  `gtk_widget_destroy` (Linux) so multi-window last-window-quit
  semantics keep working.
- **Edit menu** — Undo / Redo / Cut / Copy / Paste / Select All.
  Items render their shortcut hint in the label but the embedded
  webview (WebView2 / WebKitGTK) keeps owning the actual
  Ctrl+C/V/X/Z/Y/A keystrokes. Binding an OS-level accelerator for
  those keys would consume the event before the webview saw it and
  silently break clipboard inside HTML inputs.

Set `.install_default_menu = false` to suppress the bar entirely
(apps building their own).

## Tray icon

```zig
var tray = try desktop.tray.init(allocator, &window, .{
    .label   = "V",                // macOS status-bar text; ignored on Win/Linux
    .tooltip = "Verve Desktop",    // hover tooltip
});
defer tray.deinit();

// Optional later update:
tray.setTooltip("Now with 30% more cowbell");
```

Platform delivery:

- **macOS** — `NSStatusItem` from `[NSStatusBar systemStatusBar]`.
  `label` renders next to the icon in the menubar.
- **Windows** — `Shell_NotifyIconW(NIM_ADD)` with stock
  `IDI_APPLICATION` icon. Tooltip shows on hover.
- **Linux** — `libayatana-appindicator3` (`app_indicator_new`).
  Requires `libayatana-appindicator3-1` at runtime; nearly every
  GNOME/KDE distro ships it.

Click handlers + submenus are deferred to a future bundle. The
tray icon is purely presence + tooltip in this release.

## Notifications

```zig
try desktop.notifications.show(allocator, .{
    .title = "Hello",
    .body  = "From the native side.",
});
```

- **macOS** — `NSUserNotification` + `NSUserNotificationCenter`.
  Deprecated by Apple but still works without a permission grant.
- **Linux** — `libnotify` (`notify_init` + `notify_notification_new`
  + `notify_notification_show`). Requires `libnotify` at runtime.
- **Windows** — returns `error.Unsupported`. Toast notifications
  need COM + AUMID + Start-menu registration; deferred. Apps that
  need Win notifications today combine `desktop.tray` with a manual
  `Shell_NotifyIconW(NIF_INFO)` call against the tray icon.

## Deep-link URLs

```zig
window.setUrlOpenHandler(onUrlOpen, ctx_ptr);
// Optional: feed an argv-derived URL through the same callback.
if (cold_launch_url) |u| window.deliverUrl(u);
```

`setUrlOpenHandler(cb, ctx)` registers a callback fired when the OS
delivers a `verve://...` URL (or whatever scheme you register). The
callback receives the full URL string; the slice is **not** retained
across the call — copy if you need to outlive the trampoline.

Platform delivery:

- **macOS** — installs an `NSAppleEventManager` handler for
  `kInternetEventClass`/`kAEGetURL`. Both warm-launch and
  cold-launch URLs route through the same path; Cocoa queues
  pre-launch URLs until the AEH installs, then drains them.
- **Windows + Linux** — both cold-launch and warm-launch.
  Cold-launch: the OS spawns the binary with the URL in argv; the
  scaffold template's `main.zig` parses `--url <u>` or any
  positional starting with `verve://` and calls
  `Window.deliverUrl(url)` after the window opens. Warm-launch: the
  same template detects `single_instance.acquire` returning
  `AlreadyRunning`, calls
  `desktop.deep_link.forwardToRunningInstance(allocator, name, url)`,
  and exits — the forwarder uses `FindWindowW` + `WM_COPYDATA` on
  Win and an abstract `AF_UNIX SOCK_DGRAM` socket on Linux. The
  receive side is auto-installed: Win sits in the wndProc, Linux
  binds via `desktop.deep_link.startListener(&window, name)` after
  the window opens.

Registering the scheme with the OS is install-time:

- **macOS** — `zig build bundle -Durl-scheme=verve` injects
  `CFBundleURLTypes` into the generated `Info.plist`. The .app
  must be in `/Applications/` (or otherwise registered with
  Launch Services) for the OS to route URLs to it.
- **Windows** — write `HKCU\Software\Classes\verve\shell\open\command`
  pointing at the exe (the framework does not ship a helper yet;
  see the section in `docs/19-desktop.md` for the registry shape).
- **Linux** — install a `.desktop` file with
  `MimeType=x-scheme-handler/verve` and run
  `update-desktop-database ~/.local/share/applications`.

## Print

Native OS print dialog on all three backends.

```zig
// Legacy no-error wrapper. Swallows Cancelled / Unsupported / Backend.
window.print();

// Full surface with error reporting.
try window.printWithOptions(.{ .kind = .system });
```

`PrintOptions.kind`:
- `default` — backend's natural choice (macOS / Linux: native
  dialog; Windows: WebView2 browser print preview).
- `browser` — Windows only distinction (`PRINT_DIALOG_KIND_BROWSER`);
  ignored on macOS / Linux.
- `system` — OS print dialog. macOS = `NSPrintOperation`; Windows =
  `ShowPrintUI(SYSTEM)`; Linux = `webkit_print_operation_run_dialog`.

Errors: `Unsupported` | `Backend` | `Cancelled` | `OutOfMemory`.
`Unsupported` on Windows means the Edge WebView2 runtime is older
than version 111 (March 2023) — `QueryInterface` for
`ICoreWebView2_16` returns `E_NOINTERFACE`.

Page-range / printer-selection / silent print are future polish
items; the v1 surface only carries the dialog-kind switch.

## Window snapshot (macOS)

```zig
try window.takeSnapshotPng("./shot.png");
```

Captures the WKWebView contents as PNG via
`takeSnapshotWithConfiguration:completionHandler:`, then encodes
through `NSBitmapImageRep` and writes via
`NSData.writeToFile:atomically:`. Sync-blocks on a nested NSRunLoop
pump until the completion handler fires.

Errors: `Unsupported` | `CaptureFailed` | `EncodeFailed` | `WriteFailed`.
Win/Linux stubs return `error.Unsupported`.

Used by `zig build smoke` for golden-diff CI; also useful for
ad-hoc bug reports.

## macOS .app bundle

```sh
zig build bundle
```

Lays out `zig-out/<name>.app/Contents/{Info.plist,MacOS/<name>}` —
the shape Finder, Launchpad, and Gatekeeper expect. The bare exe in
`zig-out/bin/` cannot be code-signed or notarized.

Build options:

| Flag | Default | Purpose |
|------|---------|---------|
| `-Dbundle-id=...` | `dev.verve.<name>` | `CFBundleIdentifier` in Info.plist |
| `-Dbundle-version=...` | `0.0.0` | `CFBundleVersion` + `CFBundleShortVersionString` |
| `-Dicon=<path>` | (none) | Copy `<path>` into `Contents/Resources/AppIcon.icns` and reference it from `CFBundleIconFile`. Accept absolute or build-root-relative paths. Without it the bundle falls back to the generic macOS app glyph. |
| `-Dcodesign=<identity>` | (none) | Sign the bundle after layout. Use `-` for ad-hoc |

Example:

```sh
zig build bundle \
  -Dbundle-id=com.example.app \
  -Dbundle-version=1.2.0 \
  -Dicon=assets/AppIcon.icns \
  -Dcodesign="Developer ID Application: ACME Inc"
```

Generate `AppIcon.icns` from a square master PNG:

```sh
mkdir -p AppIcon.iconset
for SZ in 16 32 64 128 256 512 1024; do
  sips -z $SZ $SZ master.png --out AppIcon.iconset/icon_${SZ}x${SZ}.png
done
iconutil -c icns AppIcon.iconset -o assets/AppIcon.icns
```

With `-Dcodesign=...` set a `zig build codesign` step also becomes
available; it signs the bundle in place.

## Dev loop

```sh
zig build dev
```

Watches `build.zig`, `src/{main,components,handlers,client/main}.zig`,
and `frontend/{style.css,verve_desktop.js}` for mtime changes (400 ms
poll). On change: kills the running app, runs `zig build`, respawns.
Press Ctrl-C to exit.

For changes to the Zig source (`src/components.zig`,
`src/handlers.zig`, `src/client/main.zig`), the rebuild + restart is
mandatory — the SSR'd `index.html` and the wasm-compiled client are
both baked at build time.

### `--dev` runtime fallback (hot CSS / JS)

For changes to **static frontend assets** (`style.css`,
`verve_desktop.js`, anything you drop into `frontend/`), restart the
app once with the `--dev <dir>` flag pointing at the same directory:

```sh
./zig-out/bin/app --dev ./frontend
```

The scheme handler now checks `<dir>/<path>` on every request first
and falls through to the embedded copy only when the file is missing.
Edit the file, press Cmd+R in the window, see the new bytes — no
rebuild, no respawn. Pair it with `zig build dev` to keep the
process-restart loop for code changes and use the runtime fallback
for asset iteration.

Sandboxing: requests with `..` segments or post-strip absolute paths
are rejected with 404 so a misconfigured `--dev` value can't expose
arbitrary files. The per-file ceiling is 16 MB.

## Smoke test (macOS — Level-3)

```sh
zig build smoke
```

End-to-end golden-diff harness. The app is launched with
`--smoke ./.smoke`, which makes the bridge JS load
`index.html?smoke=1` and run a deterministic interaction sequence
after hydration (click `#ping`, click `+`, compute
`document.body.innerText.length`). The `smoke_done` IPC handler:

1. Captures a PNG snapshot via `Window.takeSnapshotPng`.
2. Writes the checksum to `./.smoke/checksum.txt`.
3. Terminates the app.

The script then diffs the checksum against `tests/golden/checksum.txt`.
PNG comparison is not enforced — renders vary by display scale /
macOS version / installed fonts — but the snapshot is kept under
`./.smoke/shot.png` for eyeballing on failure.

First-run capture: if `tests/golden/checksum.txt` is missing, the
script copies the freshly-captured checksum + PNG into
`tests/golden/`, exits 65, and prints "commit it." The scaffolded
template already ships a default golden (checksum=284 for the demo
markup); update it when you change `src/components.zig` enough to
shift the DOM text length.

Overrides:

| Env / arg | Default | Purpose |
|-----------|---------|---------|
| `SMOKE_GOLDEN_DIR` | `./tests/golden` | Alternate golden directory |
| `SMOKE_APP_TIMEOUT` | `6` | Seconds to wait for app self-exit |
| 2nd arg to script | `./.smoke` | Output directory |

## Runtime flags

| Flag | Effect |
|------|--------|
| `--smoke <dir>` | Enable smoke harness; loads page with `?smoke=1`, writes `<dir>/{shot.png,checksum.txt}`, terminates |
| `--dev <dir>` | Enable runtime disk-read fallback for the asset router; scheme requests check `<dir>/<path>` before falling through to the embedded table. Hot-reload-friendly. Reject `..` segments + absolute paths; 16 MB per-file cap. |

## Build flags

| Flag | Default | Effect |
|------|---------|--------|
| `-Dtarget=<triple>` | host | Cross-compile target (e.g. `x86_64-windows-gnu`) |
| `-Doptimize=<mode>` | `Debug` | `Debug` / `ReleaseSafe` / `ReleaseSmall` / `ReleaseFast` |
| `-Dpublic-dir=<dir>` | `frontend` | Source directory walked at build time for `public_assets` |
| `-Dbundle-id=<id>` | `dev.verve.<name>` | macOS bundle identifier |
| `-Dbundle-version=<v>` | `0.0.0` | macOS bundle version |
| `-Dicon=<path>` | (none) | macOS bundle icon (`.icns`); copied to `Contents/Resources/AppIcon.icns` |
| `-Dcodesign=<identity>` | (none) | macOS bundle signing identity |
| `-Dwebview2-sdk=<path>` | `third_party/webview2` | Windows: WebView2 SDK location |
| `-Dwebview2-no-fetch=<bool>` | `false` | Windows: skip NuGet fetch (use existing SDK) |

## Platform support matrix

| Feature | macOS | Windows | Linux |
|---------|-------|---------|-------|
| Window lifecycle | ✓ | ✓ | ✓ |
| Custom-scheme assets | ✓ | ✓ | ✓ |
| IPC + typed Router | ✓ | ✓ | ✓ |
| Cookies | ✓ | ✓ | ✓ |
| Multi-window | ✓ | ✓ | ✓ |
| WASM hydration | ✓ | ✓ | ✓ |
| Single-instance lock | ✓ | ✓ | ✓ |
| Clipboard read / write | ✓ | ✓ | ✓ |
| Color scheme (light/dark) | ✓ | ✓ | ✓ |
| File / save dialogs | ✓ | ✓ (file only) | ✓ |
| Alerts | ✓ | ✓ (standard buttons) | ✓ |
| Native menu bar | ✓ | ✓ | ✓ |
| Tray icon | ✓ | ✓ | ✓ |
| Notifications | ✓ | stub | ✓ |
| Window snapshot (PNG) | ✓ | ✓ | ✓ |
| `.app` bundle | ✓ | — | — |
| Level-3 smoke | ✓ | — | — |
| Dev-loop watcher | ✓ | ✓ | ✓ |
| `--dev` runtime fallback | ✓ | ✓ | ✓ |

✓ = real implementation. `stub` = the API exists and returns
`error.Unsupported` so cross-platform call sites compile.
— = not on the cross-platform surface yet.
