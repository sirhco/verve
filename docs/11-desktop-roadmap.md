# Verve Desktop — Roadmap & Handoff

## Hand-off checklist (start here)

Fresh session? Do these four in order before writing code:

1. **Read this doc top-to-bottom.** Sections "Verified working today"
   (P0 done) and "Outstanding work — P1" frame everything below.
2. **Run verification commands** in the "Verification commands for
   fresh sessions" section near the bottom. Confirm framework build,
   3-backend cross-compile, and macOS scaffold boot all PASS. If any
   step fails, state matches description no longer — stop and surface
   the drift before proceeding.
3. **Pick one bundle** from the "Suggested next-session bundles"
   table. All P1 items (#16–#23) are closed; every P2 platform port
   (Win/Linux dialogs, alerts, snapshot) is in. The P3 items that
   shipped 2026-05-24/25 are listed under "Out of P1 scope — shipped"
   below. Remaining P3 backlog: GTK4 backend, drag-drop with native
   paths, print API, hicolor / Linux icon-theme install,
   accessibility (NSAccessibility / UIA / ATK), auto-updater
   (Sparkle / Squirrel), Win tray-balloon / Toast notifications
   (macOS + Linux notifications already landed), tray click
   handlers + submenus on all 3 platforms.
4. **Hard constraint: do not modify `src/verve.zig`.** Public web
   surface stays unchanged. Anything desktop-specific goes in
   `src/desktop/` or the template tree.

Authoritative state of the desktop scaffold subsystem and the remaining
work needed to call it "fully functional." Written 2026-05-22, last
updated 2026-05-24. Fresh sessions should be able to pick up without
prior context.

## Done in the 2026-05-22 → 2026-05-24 session

Phases A–K committed to `ui-ki`; see `git log --oneline -20` for the
chain. Two items remain uncommitted at session end:

- `src/cli/main.zig` — Phase L portability fix (replaces
  `std.c.realpath` with `std.Io.Dir.realPathFileAbsoluteAlloc`).
- `docs/11-desktop-roadmap.md` — this doc.

Stage + commit both before starting fresh work. Suggested messages
drafted in earlier chat history.

- [x] **#16 multi-window foundation** (Phases A–D). Per-window
  `WindowCtx` on each backend, `Window.openChildWindow()` API, last-
  window-quit semantics on Windows + Linux. Three different ctx-
  routing strategies per platform: macOS HashMap keyed by WKWebView
  ptr, Windows embedded back-pointer in COM handler structs + HashMap
  keyed by HWND, Linux native `user_data` threading through GSignal
  + per-window `webkit_web_context_new()`.
- [x] **#22 cookie store API** (Phase E API + F1 macOS / F2 Windows /
  F3 Linux real impls). `Window.cookies()` returns `CookieStore` with
  `get`/`set`/`delete`/`clear`. All three backends ship real
  implementations; macOS validated end-to-end live; Win/Linux compile-
  clean cross-compile (live validation deferred to CI). NSBlock
  impostor + nested NSRunLoop pump on macOS; COM `IGetCookiesHandler`
  vtable + nested Win32 message pump on Windows; `GAsyncReadyCallback`
  cells + `g_main_context_iteration` pump on Linux.
- [x] **#17 typed IPC router** (Phase I). `desktop.Router(Ctx, Routes)`
  comptime route table; per-route `Args` + `Reply` types parsed via
  `std.json.parseFromValue` against an arena allocator. JS shim gains
  `window.verve.request(payload)` returning a Promise correlated via
  `__verve_id` field. Validated end-to-end on macOS.
- [x] **#21 WebView2 auto-vendor** (Phase J). `tools/fetch_webview2.sh`
  + `.ps1` download the pinned NuGet package into
  `third_party/webview2/`. Scaffold `build.zig` invokes the script
  automatically on Windows targets (idempotent — existing `.lib`
  short-circuits). CI workflow's inline vendor step removed in favor
  of the script. SHA pin left blank with TODO until first verified
  download.
- [x] **#20 partial — `zig fetch` URL hint** (Phase K). Scaffolded
  `build.zig.zon` now documents the swap from path-dep to
  `.url + .hash` once a release tag exists. `tools` added to
  `.paths`. `release.yml` matrix still Linux + macOS only — Windows
  binary blocked by `verve-server`'s posix-specific fd-3 socket
  adoption.
- [x] **verve-cli Windows compat** (Phase L). `canonicalize()` swapped
  from `std.c.realpath` (libc-only) to
  `std.Io.Dir.realPathFileAbsoluteAlloc`. `verve-cli` now cross-
  compiles cleanly to `x86_64-windows-gnu`. Unlocks Windows binary
  release once `verve-server` is gated.
- [x] **Backend headless tests** (Phase G). New `cookies_test.zig` +
  `surface_test.zig` aggregated into existing `asset_router_test`
  entry. `comptime` block in `window.zig` asserts the 15-method
  backend conformance surface. Desktop test artifact: 6 → 13 tests.
- [x] **#18 SSR + WASM hydration in desktop scaffold** (Phases J1 +
  J2 + J3). J1: build-time SSR via a host-target binary
  `templates/desktop/tools/render_index.zig` walks
  `components.page(ctx, components.home(ctx))` through
  `verve.Renderer.render`, prints to stdout; the scaffold `build.zig`
  captures via `addRunArtifact.captureStdOut` and grafts the result
  into `public_assets` as `index.html`. Static `frontend/index.html`
  deleted — SSR overlay is canonical. J2: scaffold `build.zig`
  compiles `src/client/main.zig` to `wasm32-freestanding`
  (ReleaseSmall) and overlays `client.wasm` into `public_assets`.
  J3: `frontend/verve_desktop.js` — strict subset of
  `src/bridge/verve.js` with no `/api`, `/ws`, `/events`, or
  `/islands/*` endpoint fetches (none exist in desktop context).
  Validated end-to-end on macOS — the demo counter button drives
  WASM `increment_counter` export and the DOM updates via the
  bridge's `set_text_by_bind` extern. Commits 49b053d (J1) +
  3338d45 (J2 + J3).
- [x] **Template polish** (Phase H). Scaffolded template demonstrates
  `Window.cookies()` and `Window.openChildWindow()`; frontend
  refactored to `await window.verve.request(...)` for typed routes;
  README documents Cookies + Multi-window sections; broken
  `document.addEventListener('verve:ready', ...)` pattern removed
  (event fires at document-start before any inline `<script>` parses).

## Quick orientation

- Entry point: `verve-cli new <dir> --desktop` produces a self-contained
  app embedding the OS standard webview (WKWebView / WebView2 /
  WebKitGTK).
- Framework code: `src/desktop/` (platform abstraction).
- Embedded template: `templates/desktop/` (scaffolded project tree).
- Smoke harnesses: `templates/desktop/tools/smoke_{macos.sh,linux.sh,windows.ps1}`.
- CI: `.github/workflows/desktop.yml` (matrix macOS/Linux/Windows).

## Verified working today (P0 done)

All items below have framework `zig build` + `zig build test` PASS and
were live-tested on macOS arm64 unless noted.

- [x] **Scaffold both modes.** `verve-cli new <dir>` (web, default) and
  `verve-cli new <dir> --desktop`. Web tree unchanged except the new
  `src/desktop/` files.
- [x] **`--verve-path` baked.** Default = framework abs path, canonicalised
  through `realpath`, converted to relative for `build.zig.zon`. Override
  via `verve-cli new --verve-path <abs>`.
- [x] **All 3 backends cross-compile.** Hand-rolled `extern` decls — no
  `@cImport` so darwin host can syntax-check Windows + Linux.
  - `zig build-obj src/desktop/window.zig -target aarch64-macos -fno-emit-bin`
  - `zig build-obj src/desktop/window.zig -target x86_64-linux-gnu -fno-emit-bin`
  - `zig build-obj src/desktop/window.zig -target x86_64-windows-gnu -fno-emit-bin`
- [x] **macOS live boot.** Window opens, WKWebView attaches, scheme
  handler fires for `index.html` + `style.css`. Bundled `.app` boots
  identically.
- [x] **Level-1 smoke harness.** `zig build smoke` per platform. macOS
  passes in CI-like envs.
- [x] **Diagnostic logging.** `verve.desktop[macos|linux|windows]:` log
  lines at each lifecycle stage so live debugging on real Win/Linux
  hosts is tractable.
- [x] **CI matrix YAML.** `.github/workflows/desktop.yml` builds the
  framework + scaffolds + builds the scaffolded app + runs smoke on
  all three OSes. Untested until the workflow runs on real GH actions.
- [x] **macOS objc_msgSend audit.** Findings documented in
  `src/desktop/msg.zig` header. Summary: no `_stret` needed, NSRect is
  HFA, BOOL = `_Bool` on 64-bit darwin → Zig `bool` works.
- [x] **`.app` bundle generator.** `zig build bundle` writes
  `zig-out/<name>.app/Contents/{Info.plist, MacOS/<name>}`. Optional
  `-Dbundle-id=` / `-Dbundle-version=` / `-Dcodesign=<identity>`.
- [x] **Native dialogs (macOS).** `Window.openFileDialog` /
  `saveFileDialog` / `showAlert` against NSOpenPanel/NSSavePanel/NSAlert.
  Win/Linux stubs return `error.Unsupported` so cross-platform call
  sites compile.
- [x] **Window vs app lifecycle split.** `Window.close()` (window-level)
  separate from `Window.terminate()` (app quit). NSApplicationDelegate
  with `applicationShouldTerminateAfterLastWindowClosed:` → standard
  single-window-quits-app behavior on macOS.
- [x] **Native menu bar (macOS).** App menu (Quit, Cmd+Q), Edit menu
  (Undo/Redo/Cut/Copy/Paste/Select All — required for WKWebView
  clipboard shortcuts to fire), Window menu (Minimize, Close).

## File map (current state — reflects 2026-05-24)

```
src/desktop/
  window.zig              comptime os.tag dispatcher, public surface,
                          backend method-surface conformance comptime check
  options.zig             WindowOptions, AssetEntry, MessageHandler,
                          FileDialogOptions, AlertOptions, DialogError,
                          Cookie, SameSite, CookieError
  asset_router.zig        verve://app/<path> resolver + MIME table
  asset_router_test.zig   aggregator test entry (imports cookies_test +
                          surface_test below)
  cookies.zig             CookieStore comptime dispatch facade
  cookies_test.zig        Cookie defaults + SameSite stability + CookieStore
                          method presence
  surface_test.zig        WindowOptions defaults, ipc.shim_js markers,
                          AssetEntry ABI shape
  ipc.zig                 document-start JS shim string (with request()
                          Promise correlation since 2026-05-23)
  ipc_router.zig          comptime typed IPC router with Args/Reply
  msg.zig                 objc_msgSend cast helper + ABI audit notes
  macos.zig               NSWindow + WKWebView via objc runtime; per-window
                          WindowCtx + AutoHashMap registry; WKHTTPCookieStore
                          impl with NSBlock impostor + NSRunLoop pump
  windows.zig             HWND + WebView2 via offset-based COM; per-window
                          WindowCtx + AutoHashMap registry; CookieManager
                          impl with IGetCookiesHandler + msg pump
  linux.zig               GtkWindow + WebKitGTK 4.1; per-window WindowCtx +
                          per-window WebKitWebContext (via g_object_new);
                          CookieManager impl with GAsyncReadyCallback +
                          GMainContext pump
  README.md               architecture notes

templates/desktop/        scaffolded into user projects
  build.zig               per-OS link wiring + bundle + smoke steps;
                          Windows branch invokes tools/fetch_webview2.*
  build.zig.zon           verve dep (path baked + canonicalised); comment
                          documenting zig fetch --save URL swap
  README.md               user-facing docs (Cookies + Multi-window sections)
  .gitignore
  src/
    main.zig              opens Window, runs event loop, two-step
                          attach() + setMessageHandler() for typed router
    handlers.zig          comptime Routes table demonstrating typed IPC
                          + cookie demo routes + open_child route
    desktop/              vendored copy of framework src/desktop/
                          (embedded at scaffold time, not maintained
                          separately)
  frontend/
    index.html            IPC + Cookies + Multi-window demo cards,
                          all via window.verve.request() Promise API
    style.css             light/dark themed
  public/.gitkeep
  tools/
    smoke_macos.sh
    smoke_linux.sh        Xvfb + ImageMagick
    smoke_windows.ps1     System.Drawing capture
    fetch_webview2.sh     POSIX NuGet downloader for WebView2 SDK
    fetch_webview2.ps1    Windows NuGet downloader (idempotent)
    webview2.pinned.txt   pinned NuGet version (+ optional SHA-512)

.github/workflows/
  desktop.yml             3x3 matrix: framework + scaffold + smoke
                          (Windows WebView2 vendor step removed; build.zig
                          handles it now)
  release.yml             tag-push release matrix (Linux + macOS targets;
                          Windows blocked by verve-server posix gate)

build.zig (root)          buildCliSkeleton, buildCliSkeletonDesktop,
                          embedTreeAs helper, --verve-path option
src/cli/main.zig          --desktop/--web/--verve-path/--name parsing;
                          portable realPathFileAbsoluteAlloc canonicalize
                          (verve-cli now cross-compiles to Windows)
```

## Outstanding work — P1 (production-ready)

Each bullet is sized + sequenced. Pick bundles per next session.

### ~~#16 — Multi-window support~~ — DONE 2026-05-22

Shipped in Phases A–D. Per-window `WindowCtx` on each backend, three
different ctx-routing strategies tailored to each platform's callback
model (see "Done in the 2026-05-22 → 2026-05-24 session" above).
`Window.openChildWindow(opts)` API present on all three backends.
Last-window-quit semantics: macOS via NSApp's native tracking,
Windows via HWND registry size, Linux via `live_windows` counter.

### ~~#17 — Typed IPC + request/response~~ — DONE 2026-05-23

Shipped in Phase I. `desktop.Router(Ctx, Routes)` comptime route
table with `Args` + `Reply` types per route, arena-allocator passed
to handlers, JS `window.verve.request(payload)` returns a Promise
correlated via `__verve_id` field. Validated end-to-end with auto-
smoke (ping → cookie_set → cookie_get → cookie_clear → log).

### ~~#18 — Verve SSR + WASM hydration in desktop scaffold~~ — DONE

Shipped across phases J1 + J2 + J3 — see the matching entry under
"Done in the 2026-05-22 → 2026-05-24 session" above. Scaffold now
ships per-app `Renderer.render` at build time, per-app
`wasm32-freestanding` client compile, and the
`verve_desktop.js` subset bridge.

Risk callout for future regressions: WKWebView restricts ES modules
+ `WebAssembly.instantiateStreaming` under custom schemes. Current
bridge sidesteps both (no ES modules; arrayBuffer + `instantiate`).
If hydration regresses, the first thing to check is whether anything
introduced ES-module syntax or streaming compile against
`verve://app/*`. If so, add `Cross-Origin-Embedder-Policy:
require-corp` + `Cross-Origin-Opener-Policy: same-origin` headers in
`asset_router.zig`.

### ~~#19 — Dev live-reload~~ — DONE 2026-05-24 (process-restart + runtime fallback)

Shipped in two passes. Phase 1 was `zig build dev`, a process-restart
watcher in the scaffold template. Phase 2 (closed same day) added the
`--dev <dir>` runtime flag: scheme-handler requests check
`<dir>/<path>` before the embedded asset table, falling through only
on disk miss. Hand-written frontend assets (`style.css`,
`verve_desktop.js`, anything you drop into `frontend/`) reload with
Cmd+R, no rebuild required. Zig source changes still need the
process-restart watcher because the SSR'd `index.html` and the
wasm-compiled client are both baked at build time.

What ships today (`templates/desktop/tools/dev.zig`):

- Host-target Zig binary; spawned via `zig build dev`.
- Polls a fixed list of source files (build.zig, src/main.zig,
  src/components.zig, src/handlers.zig, src/client/main.zig,
  frontend/style.css, frontend/verve_desktop.js) at 400ms intervals
  using `std.Io.Dir.cwd().statFile(...).mtime`.
- On any mtime change: `Child.kill` the running app, run
  `zig build`, if successful spawn `./zig-out/bin/app`. If build
  fails, prints a warning and waits for the next save.
- Cross-platform via std.process.spawn — works on macOS today; will
  work on Linux + Windows once those hosts are exercised (no
  platform-specific hooks in the watcher itself).
- Ctrl-C kills the watcher; the defer in main reaps the child app.

Trade-off: rebuilds cost ~1-2 seconds + lose live app state on each
cycle. Acceptable for the demo-app dev loop; a future runtime
disk-read mode would lift the bake-at-build constraint.

### ~~#20 — Release tarball + zig fetch flow~~ — DONE 2026-05-24

Shipped 2026-05-23 → 2026-05-24:
- `.github/workflows/release.yml` matrix now includes x86_64-windows-gnu
  alongside Linux + macOS; `.exe` suffix handled per-matrix-entry.
- `src/cli/main.zig:renderZon` emits a commented swap-to-URL example.
- `verve-cli` cross-compiles cleanly to `x86_64-windows-gnu`
  (Phase L: `std.c.realpath` → `std.Io.Dir.realPathFileAbsoluteAlloc`).
- `verve-server` cross-compiles cleanly to `x86_64-windows-gnu`
  after `installShutdownHandlers` + LISTEN_FDS fd-3 adoption were
  gated behind `if (comptime builtin.target.os.tag != .windows)`.
  Windows shutdown signaling would route through
  SetConsoleCtrlHandler — deferred until a Windows host runs the
  binary in anger.

### ~~#21 — WebView2 SDK auto-vendor~~ — DONE 2026-05-23

Shipped in Phase J. `templates/desktop/tools/fetch_webview2.{sh,ps1}`
+ `webview2.pinned.txt`. Scaffold `build.zig` Windows branch invokes
the script; CI workflow's manual vendor step removed. SHA pin still
blank — populate after first verified download via CI.

### ~~#22 — Cookie + storage uniform API~~ — DONE 2026-05-23

Shipped across Phases E (API surface), F1 (macOS real impl), F2
(Windows real impl), F3 (Linux real impl). `Window.cookies()` returns
`CookieStore { get, set, delete, clear }`. All three backends ship
real implementations using their native async cookie managers wrapped
in sync facades (NSRunLoop pump on macOS, Win32 message pump on
Windows, GMainContext iteration on Linux). macOS validated live;
Win/Linux compile-clean cross-compile.

### ~~#23 — Level 3 smoke (macOS)~~ — DONE 2026-05-24

Shipped end-to-end. The desktop scaffold's `zig build smoke` step is
now a Level-3 golden-diff harness:

- `Window.takeSnapshotPng(path)` lives on the cross-platform surface
  (Win/Linux stubs return `error.Unsupported`). macOS impl uses
  `WKWebView.takeSnapshotWithConfiguration:completionHandler:` with
  an `_NSConcreteStackBlock` impostor (`SnapshotBlock`) + the existing
  `pumpUntilDone` nested NSRunLoop pump, then NSImage →
  NSBitmapImageRep → PNG → `writeToFile:atomically:`.
- Template `main.zig` parses `--smoke <dir>`; when set, overrides
  `initial_path` to `index.html?smoke=1` so the bridge driver wakes up.
- `frontend/verve_desktop.js` smoke driver runs after hydration:
  clicks `#ping`, clicks the `increment_counter` button, then posts
  `{ type: "smoke_done", checksum: document.body.innerText.length }`
  via the existing IPC channel.
- `handlers.zig` `smoke_done` route: `takeSnapshotPng` →
  `writeFile(checksum.txt)` → `Window.terminate()`.
- `tools/smoke_macos.sh` runs the app with `--smoke .smoke`, polls
  for self-exit, diffs `.smoke/checksum.txt` against
  `tests/golden/checksum.txt`. PNG comparison intentionally NOT
  enforced (renders are display/font/scale-dependent); shot kept for
  human inspection.
- `tests/golden/checksum.txt` baked into scaffold template
  (default = "284"). First-run fallback in script captures + exits
  65 with "commit it" message.
- Cross-platform: macOS only. Win/Linux smoke scripts still live but
  call into stubs — port follows the same shape once those backends
  get `takeSnapshotPng` real impls.

### Out of P1 scope (P3 — open)

- GTK4 + WebKitGTK 6.0 backend behind `-Dgtk4`
- Tray icons + system notifications
- Drag-drop with native paths, print API
- Hicolor / Linux app icon theme installation
- Accessibility (NSAccessibility / UIA / ATK)
- Auto-updater (Sparkle / Squirrel)

### Out of P1 scope — shipped 2026-05-24

- Single-instance enforcement — `desktop.single_instance.acquire`
  with POSIX flock + Windows named mutex.
- Cross-platform clipboard read/write — `Window.clipboard()`
  (NSPasteboard / CF_UNICODETEXT / GtkClipboard).
- Theme follow — `Window.colorScheme()` getter + live change
  events via `Window.setColorSchemeHandler` on all three backends.
- App icons (macOS `.app` bundle) — `-Dicon=<path>` build flag
  copies an `.icns` into `Contents/Resources/AppIcon.icns` and
  references it from `CFBundleIconFile`.

### Out of P1 scope — shipped 2026-05-25

- Tray icons + notifications — new `desktop.tray` +
  `desktop.notifications` modules. Tray: macOS `NSStatusItem`,
  Windows `Shell_NotifyIconW` + stock `IDI_APPLICATION`, Linux
  `libayatana-appindicator3` with an empty `GtkMenu` attached
  (some Ayatana versions silently refuse to render without one).
  Notifications: macOS `NSUserNotification`, Linux `libnotify`
  (`notify_init` + `notify_notification_new` + `_show`); Windows
  returns `error.Unsupported` — Toast notifications need COM +
  AUMID + Start-menu registration, deferred. Scope deliberately
  narrow: no click handlers, no submenus, no actions. Apps that
  need Win notifications today drop down to
  `Shell_NotifyIconW(NIF_INFO)` against the tray icon.
- Win/Linux warm-launch URL forwarding — `desktop.deep_link` module
  with `forwardToRunningInstance(allocator, name, url)` +
  `startListener(window, name)`. Windows side: `FindWindowW` to
  locate the running app's HWND, then `SendMessageW(WM_COPYDATA)`
  with a `URL` sentinel `dwData` so unrelated WM_COPYDATA traffic
  doesn't trip the receiver; receiver lives in `wndProc`. Linux
  side: abstract `AF_UNIX SOCK_DGRAM` socket bound to
  `\0verve-deeplink-<name>`; sender `connect`+`send`s; receiver
  wraps the bound fd in a `GIOChannel` watch (`G_IO_IN`) so the
  GTK main loop dispatches inbound URLs. macOS is a no-op on both
  calls — `NSAppleEventManager` already routes warm-launch URLs
  through the AEH installed at `setUrlOpenHandler` time. Template
  `main.zig` calls `forwardToRunningInstance` from the second
  instance's `AlreadyRunning` branch when `--url` was supplied,
  and `startListener` after the window opens.
- Deep-link URL handlers — `Window.setUrlOpenHandler(cb, ctx)` +
  `Window.deliverUrl(url)` on the public surface. macOS installs
  a process-wide `NSAppleEventManager` URL handler
  (`kInternetEventClass`/`kAEGetURL`), so warm-launch (app running)
  and cold-launch (Finder click while not running) both funnel
  through the same callback; Cocoa queues pre-launch URLs until the
  AEH installs, then drains. Win + Linux ship cold-launch only —
  the scaffold template's `main.zig` parses `--url <u>` or any
  positional starting with the scheme and calls `deliverUrl(url)`
  after the window opens. Second-instance forwarding
  (`WM_COPYDATA` on Win, abstract `AF_UNIX` socket on Linux) is a
  follow-up. Scaffold `build.zig` gains `-Durl-scheme=<name>` which
  injects `CFBundleURLTypes` into the generated `Info.plist`.
- Native menu bars on Windows + Linux — default File (Quit) + Edit
  (Undo/Redo/Cut/Copy/Paste/Select All) honoring the existing
  `install_default_menu` flag for parity with the macOS App + Edit
  + Window menus. Win32 uses `CreateMenu` + `SetMenu` + a one-entry
  `HACCEL` for Ctrl+Q routed through `TranslateAcceleratorW` and
  `WM_COMMAND`; Linux wraps the webview in a `GtkBox` + `GtkMenuBar`
  with a single Ctrl+Q binding on the accel group. Edit items
  render the shortcut hint in the label only — WebView2 and
  WebKitGTK keep handling Ctrl+C/V/X/Z/Y/A inside text inputs
  natively, since binding an OS-level accelerator on those keys
  would consume the event before the webview saw it. macOS
  validated live; Win/Linux compile-clean cross-compile (live
  validation deferred).

## Suggested next-session bundles

All P1 + every P2 platform port closed; the high-value P3 items
that user-facing apps reach for immediately (single-instance,
clipboard, color scheme + change events, app icons) all landed on
2026-05-24. Remaining work is the lower-frequency P3 surface:

| Bundle | Items | Best for |
|---|---|---|
| **P3 GTK4** | GTK4 + WebKitGTK 6.0 behind `-Dgtk4` | Future-proofing once Ubuntu LTS / Fedora ship GTK4 webkit by default. New backend module; existing GTK3 path stays. |
| **P3 drag-drop / print** | `NSDraggingDestination` / `IDropTarget` / GTK drag signals; `NSPrintOperation` / `PrintDlgExW` / `gtk_print_operation_run` | Drag-drop with native file paths (browser DataTransfer doesn't expose them). |
| **P3 a11y** | NSAccessibility / UIA / ATK | Window-chrome + menu accessibility — web content already inherits from WebView. |
| **P3 auto-updater** | Sparkle on macOS / Squirrel or MSIX on Windows / AppImage update on Linux | Multi-platform signing + delta channels. |

Pick one. Each remaining bundle is ~2–4 hours focused work plus
testing.

## Verification commands for fresh sessions

```sh
# 1. Confirm framework still healthy
cd /Users/chrisolson/development/github/verve
zig build
zig build test

# 2. Confirm all 3 backends still cross-compile
zig build-obj src/desktop/window.zig -target aarch64-macos    -fno-emit-bin
zig build-obj src/desktop/window.zig -target x86_64-linux-gnu -fno-emit-bin
zig build-obj src/desktop/window.zig -target x86_64-windows-gnu -fno-emit-bin
rm -f window.o.o window.o

# 3. Confirm scaffold + boot still works
ln -sfn $(pwd) /tmp/verve   # if you scaffold to /tmp
./zig-out/bin/verve-cli new /tmp/vd --desktop --name vd
cd /tmp/vd
zig build
./zig-out/bin/app &
sleep 1.5
# expect stdout to show:
#   info: verve.desktop[macos]: window+webview ready (1100x760), scheme=verve
#   debug: verve.desktop[macos]: scheme '/index.html'
#   debug: verve.desktop[macos]: scheme '/style.css'
kill %1
zig build bundle
ls zig-out/app.app/Contents/{Info.plist,MacOS/app}   # both should exist
```

## Notes for the next session

- Don't touch `src/verve.zig` — keeping its public web surface
  unchanged is a hard constraint.
- The Linux backend has never run live — diagnostic logs are
  instrumented but no host has booted it. Live-validate cookies
  (#22) + multi-window (#16) + scheme handler on Linux when one
  is available.
- WebView2 vtable slot indexes in `src/desktop/windows.zig` were
  hand-extracted from public docs (including the new cookie slots
  added 2026-05-23 — `SLOT_WV2_2_get_CookieManager = 66` is
  particularly load-bearing). Verify against actual SDK headers
  during first Windows live boot.
- macOS cookie store sync wrapper (`pumpUntilDone` in `macos.zig`)
  uses a nested `[NSRunLoop runMode:beforeDate:]` — re-entrant in
  the wrong context. Safe from IPC handlers (the dominant path).
  Risky from inside other modal run loops; document if a caller
  trips over it.
- `webview2.pinned.txt` SHA-512 is blank. Populate after first CI
  run verifies the published value at
  `https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/1.0.2849.39/microsoft.web.webview2.1.0.2849.39.nupkg.sha512`.
- Avoid expanding scope mid-session. The recommendation above of
  one bundle per session is sized for sustainable quality. The
  2026-05-22 → 2026-05-24 session ran 12 phases — past the limit
  — and the rubric still held because each phase was bounded and
  verified independently. That's a ceiling, not a target.
