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

# 2. Scaffold a desktop project (demo-rich default)
./zig-out/bin/verve-cli new ~/code/my-app --desktop --name=my_app

# 3. Build + run the new project
cd ~/code/my-app
zig build run
```

The first window opens with a demo page that exercises every wired
feature: typed IPC (`ping`), cookies, multi-window, WASM-hydrated
counter, notifications, deep links (with a self-test Test button),
tray menu, print, HTTP fetch, system info readout, disk space,
file dialog, and window controls.

### Minimal scaffold

If you'd rather start from a single-window app with one IPC route
and a static HTML page, pass `--template minimal`:

```sh
./zig-out/bin/verve-cli new ~/code/my-app --desktop --template minimal
```

The minimal tree has no SSR, no WASM, no smoke harness, no tray /
notifications / multi-window wiring — just a window, a `greet`
route, and a responsive HTML form. Add features back from the full
scaffold one at a time as you need them.

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
│   └── smoke_{macos,linux,windows}.{sh,ps1}
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
  wasm32-freestanding, served at `verve://app/client.wasm`, imports
  the `verve_client` module for the full reactive surface.
  Scaffold uses typed bindings (`.bindI32` / `.bindStr` / etc.) so
  the Phase-14 JS auto-walker handles registration — no
  `verve_init_*` boilerplate needed; the scaffold's `main.zig` ships
  only the click handlers. Both `[z-on-click="<name>"]` (string
  dispatch) and `[z-on-click-id="<id>"]` (closure dispatch via
  `verve.registerEvent(&fn)`) are wired in the bridge JS delegate
- **Typed IPC** — `desktop.Router(Ctx, Routes)` with `Args`/`Reply`
  types per route; JS callers `await window.verve.request({type, ...})`
- **Cookies** — per-window `CookieStore` with `set`/`get`/`delete`/`clear`,
  real implementations on all three backends (sync wrappers around
  platform-native async cookie managers)
- **Multi-window** — `Window.openChildWindow(opts)`; last-window-quit
  semantics on all three platforms
- **Color scheme** — `Window.colorScheme()` returns
  `.light` / `.dark` / `.unknown`. macOS reads
  `[NSApp.effectiveAppearance].name` and matches "Dark"; Windows
  reads
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize\AppsUseLightTheme`
  (0 = dark, 1 = light, absent → unknown); Linux reads
  `gtk-application-prefer-dark-theme` via `gtk_settings_get_default`.
  Pair with `Window.setColorSchemeHandler(cb, ctx)` to react
  live: macOS observes
  `AppleInterfaceThemeChangedNotification` on
  `NSDistributedNotificationCenter`; Windows hooks
  `WM_SETTINGCHANGE` with `lParam == "ImmersiveColorSet"`; Linux
  connects to `GtkSettings notify::gtk-application-prefer-dark-theme`.
- **Clipboard** — `Window.clipboard()` returns a handle with
  `writeText(text)` / `readText(alloc) -> ?[]u8`,
  `writeHtml(html)` / `readHtml(alloc) -> ?[]u8` (macOS only on
  the HTML pair — Win + Linux return `error.Unsupported`), and
  `writeImage(png)` / `readImage(alloc) -> ?[]u8` for raw PNG
  bytes (macOS writes `NSPasteboardTypePNG` / `public.png`; Windows
  + Linux return `error.Unsupported`).
  Text: macOS `NSPasteboard.generalPasteboard` +
  `public.utf8-plain-text`; Windows `OpenClipboard` +
  `CF_UNICODETEXT` + an HGLOBAL payload that ownership transfers
  to the system; Linux `gtk_clipboard_get(CLIPBOARD)` +
  `gtk_clipboard_set_text` / `wait_for_text`. HTML on macOS:
  `NSPasteboardTypeHTML` (`public.html`). All sync from the
  caller's view.
- **Single-instance lock** — `desktop.single_instance.acquire(allocator, name)`
  returns an opaque `Lock` held for process lifetime. macOS + Linux use
  `flock(LOCK_EX | LOCK_NB)` on `<TMPDIR>/verve.<name>.lock`; Windows
  uses `CreateMutexW` under `Local\Verve.<name>`. Second call from a
  live sibling process returns `error.AlreadyRunning`. The kernel
  reclaims the lock on process exit so crashes don't leave it stuck.
  Activating the existing instance (raise window / forward argv) is
  out of scope — apps that want it build on top of the lock primitive.
- **Native dialogs** — `Window.openFileDialog`, `saveFileDialog`,
  `showAlert`. macOS uses NSOpenPanel/NSSavePanel/NSAlert; Linux uses
  `GtkFileChooserNative` + `GtkMessageDialog`; Windows uses
  `GetOpenFileNameW` / `GetSaveFileNameW` (`comdlg32`) + `MessageBoxW`.
  Per-platform caveats: Win32 alerts honor the button *count* (1/2/3
  → MB_OK / MB_YESNO / MB_YESNOCANCEL) but not arbitrary labels;
  directory-picking via `pick_directory` is macOS + Linux only on this
  surface (Win32 splits dir-picking into `IFileOpenDialog` — port TBD).
- **Tray icon** — `desktop.tray.init(allocator, &window, .{ .label,
  .tooltip, .icon_path, .icon_symbol, .menu, .on_click,
  .on_menu_item })`. Click handlers + submenus on all 3 backends
  (`TrayMenuItem { label, id, enabled, children }`). Icons via
  bytes-on-disk (`icon_path`: macOS NSImage formats; Win `.ico`;
  Linux PNG or theme name) or — macOS 11+ only — `icon_symbol`
  with an SF Symbol name (e.g. `"bolt.fill"`) rendered via
  `+[NSImage imageWithSystemSymbolName:...]`. macOS:
  `NSStatusItem` from `[NSStatusBar systemStatusBar]`. Windows:
  `Shell_NotifyIconW` + `WM_VERVE_TRAY` (= `WM_USER + 100`)
  callback message + `TrackPopupMenu` on right-click. Linux:
  `app_indicator_new` (libayatana-appindicator3) with a GtkMenu
  built from `TrayMenuItem`s.
- **Notifications** — `desktop.notifications.show(allocator, .{ .title,
  .body })`. macOS uses `NSUserNotification` +
  `[NSUserNotificationCenter deliverNotification:]`; Linux uses
  `notify_init` + `notify_notification_new` +
  `notify_notification_show` (libnotify). Windows returns
  `error.Unsupported` — Toast notifications need COM + AUMID + a
  Start-menu registration, deferred to a future bundle. Apps that
  need Win notifications today layer on `tray.zig` plus a manual
  `Shell_NotifyIconW(NIF_INFO)` call.
- **Deep-link URL handlers** — register a custom scheme at install
  time (`-Durl-scheme=verve` injects `CFBundleURLTypes` into the
  macOS `Info.plist`; Win/Linux registration is app-controlled),
  then receive URLs through `Window.setUrlOpenHandler(cb, ctx)`.
  macOS uses `NSAppleEventManager` (`kInternetEventClass` /
  `kAEGetURL`) so warm-launch (app already running) and cold-launch
  (Finder click while not running) both funnel through the same
  callback. Windows + Linux deliver cold-launch URLs via the
  process argv — the scaffold template parses `--url <u>` and any
  positional starting with `verve://` and calls
  `Window.deliverUrl(url)` after the window opens. Warm-launch
  forwarding on Win/Linux uses `desktop.deep_link`: the second
  instance calls `forwardToRunningInstance(allocator, name, url)`
  which `FindWindowW` + `SendMessageW(WM_COPYDATA)` on Win, or
  opens an abstract `AF_UNIX SOCK_DGRAM` socket
  (`\0verve-deeplink-<name>`) and `send`s on Linux. The running
  instance receives via the wndProc `WM_COPYDATA` case (Win) or a
  GIOChannel watch on the bound socket (Linux), routed back through
  the same `setUrlOpenHandler` callback. Runtime scheme
  registration via `desktop.deep_link.registerScheme(scheme,
  bundle_id)` on macOS uses LaunchServices
  `LSSetDefaultHandlerForURLScheme` (requires a bundled `.app` with
  the scheme already in `CFBundleURLTypes`); Win + Linux runtime
  registration are follow-ups.
- **Native menu bar** — `install_default_menu = true` (the default)
  stamps a default menu bar on all three platforms. macOS gets App +
  Edit + Window menus; the Edit menu is what makes Cmd+C / Cmd+V
  actually fire inside WKWebView text inputs. Windows and Linux get
  File (Quit) + Edit (Undo/Redo/Cut/Copy/Paste/Select All); only
  Quit binds a real shortcut (Ctrl+Q). The Edit items render their
  shortcut hint in the label but do **not** attach an OS accelerator
  — WebView2 and WebKitGTK handle Ctrl+C/V/X/Z/Y/A inside text
  inputs natively, and an OS-level accelerator would consume the key
  before the webview saw it.
- **Native print dialog** — `Window.print()` (legacy void wrapper)
  and `Window.printWithOptions(opts)` with `PrintOptions { kind,
  copies, pages: ?{from,to}, printer_name }`. macOS:
  `NSPrintOperation` + NSPrintInfo dict patching (`NSCopies` /
  `NSFirstPage` / `NSLastPage` / `[NSPrinter printerWithName:]`).
  Windows: `ICoreWebView2_16::ShowPrintUI` with
  `COREWEBVIEW2_PRINT_DIALOG_KIND_BROWSER` or `_SYSTEM` via
  `opts.kind`. Linux: `webkit_print_operation_run_dialog`.
  Win + Linux ignore `copies` / `pages` / `printer_name` today.
- **System info** — `desktop.system.osVersion(a)`,
  `locale(a, environ)`, `cpuCount()`, `totalMemory()`,
  `uptime()`, `beep()`, `processId()`. macOS uses NSLocale /
  NSProcessInfo / sysctlbyname + libc `time(NULL)`. Windows:
  `GetUserDefaultLocaleName` / `RtlGetVersion` /
  `GetTickCount64`. Linux: `/etc/os-release` parse + `LC_ALL` /
  `LANG` env + `/proc/uptime`.
- **Standard paths** — `desktop.paths.{dataDir, cacheDir,
  configDir, homeDir, tempDir}(allocator, environ[, app_name])`.
  Per-platform conventions: macOS `~/Library/Application
  Support/<app>` / `~/Library/Caches/<app>`; Win `%APPDATA%\<app>`
  / `%LOCALAPPDATA%\<app>`; Linux XDG with `$HOME/.local/share`
  / `$HOME/.cache` / `$HOME/.config` fallbacks.
- **Disk space** — `desktop.disk.spaceAt(allocator, path) Space`
  with `{ total, available, free }` bytes. POSIX: `statvfs`
  (macOS uses 32-bit `fsblkcnt_t` — handled). Windows:
  `GetDiskFreeSpaceExW`.
- **Power / battery** — `desktop.power.batteryPercent() ?u32` +
  `isCharging() bool`. macOS: IOKit `IOPSCopyPowerSourcesInfo`
  + `IOPSGetPowerSourceDescription` reading
  `kIOPSCurrentCapacityKey` / `kIOPSMaxCapacityKey` /
  `kIOPSIsChargingKey`. Windows: `GetSystemPowerStatus`. Linux:
  `/sys/class/power_supply/BAT[0-9]/capacity` + `/status`.
- **Network reachability** — `desktop.network.isOnline() bool`.
  macOS: `SCNetworkReachabilityCreateWithName("apple.com")`.
  Windows: `InternetGetConnectedState`. Linux: `getifaddrs` +
  scan for non-loopback iface in `IFF_UP | IFF_RUNNING`.
- **File watcher** — `desktop.fswatch.Watcher.init(allocator,
  path, cb, ctx)`. macOS: `FSEventStreamCreate` with file-events
  flag, scheduled on the main run loop, 1s coalescing. Win +
  Linux return `error.Unsupported` (ReadDirectoryChangesW +
  inotify follow-ups).
- **Global hotkeys** — `desktop.hotkeys.Manager` with
  `register(id, mods, keycode)`. macOS: Carbon
  `RegisterEventHotKey` + `InstallEventHandler`. Win + Linux
  return `error.Unsupported`.
- **Process spawn** — `desktop.process.runCapture(a, io, argv)`
  → `{ code, stdout, stderr }` and
  `desktop.process.spawnDetached(a, io, argv)` for fire-and-
  forget. Cross-platform via `std.process.Child`.
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
  `-Dbundle-version` / `-Dicon=<path-to-icns>` / `-Dcodesign`. The
  icon path can be absolute or build-root-relative; the bundle step
  copies it into `Contents/Resources/AppIcon.icns` and adds the
  matching `CFBundleIconFile` key to `Info.plist`. Without it Finder
  falls back to the generic app glyph.
- **Vendored WebView2** — the WebView2 SDK header + x64
  `WebView2Loader.dll` are vendored in-tree under
  `src/desktop/win_native/include/`; the build compiles the native C++
  host (`win_native/webview2_host.cpp`) and ships the loader next to the
  `.exe`. No NuGet / network fetch. Needs the WebView2 Evergreen Runtime
  at runtime (preinstalled on Win11; Win10 needs Microsoft's bootstrapper)
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
| Single-instance lock | ✓ | ✓ | ✓ |
| Clipboard read / write | ✓ | ✓ | ✓ |
| Color scheme (light/dark) | ✓ | ✓ | ✓ |
| File / save dialogs | ✓ | ✓ (file only) | ✓ |
| Alerts | ✓ | ✓ (standard buttons) | ✓ |
| Native menu bar | ✓ | ✓ | ✓ |
| Tray icon | ✓ | ✓ | ✓ |
| Tray SF Symbol fallback | ✓ | — | — |
| Notifications | ✓ | balloon | ✓ |
| Window snapshot (PNG) | ✓ | ✓ | ✓ |
| Native print dialog | ✓ | ✓ | ✓ |
| Print copies / pages / printer | ✓ | stub | stub |
| Clipboard (text) | ✓ | ✓ | ✓ |
| Clipboard (HTML) | ✓ | ✓ | stub |
| Clipboard (image/PNG) | ✓ | ✓ | pending |
| Battery / charging (`desktop.power`) | ✓ | ✓ | ✓ |
| Disk space (`desktop.disk`) | ✓ | ✓ | ✓ |
| System info (`desktop.system`) | ✓ | ✓ | ✓ |
| Standard paths (`desktop.paths`) | ✓ | ✓ | ✓ |
| Network reachability (`desktop.network`) | ✓ | ✓ | ✓ |
| File watcher (`desktop.fswatch`) | ✓ | stub | stub |
| Global hotkeys (`desktop.hotkeys`) | ✓ | stub | stub |
| Process spawn (`desktop.process`) | ✓ | ✓ | ✓ |
| Deep-link URL handler | ✓ | ✓ | ✓ |
| Deep-link runtime scheme registration | ✓ | stub | stub |
| `.app` bundle | ✓ | — | — |
| Level-3 smoke | ✓ | — | — |
| Dev-loop watcher | ✓ | ✓ | ✓ |
| `--dev` runtime fallback | ✓ | ✓ | ✓ |

✓ = real implementation. `stub` = the API exists and returns
`error.Unsupported` so cross-platform call sites compile.
— = not on the cross-platform surface yet.

## Roadmap status

All P1 and all P2 desktop items per `docs/11-desktop-roadmap.md`
are closed; clipboard, single-instance enforcement, color-scheme
follow (getter + live change events), runtime asset-disk fallback,
and macOS app-icon bundling shipped 2026-05-24. Native menu bars
on Windows + Linux, deep-link URL handlers, Win/Linux warm-launch
URL forwarding (`WM_COPYDATA` + abstract `AF_UNIX` socket), and
tray icons + notifications (macOS + Linux real, Win tray real and
notifications stubbed) all landed 2026-05-25. Tray click handlers +
submenus, drag-drop with native paths, hicolor / Linux icon-theme
install, basic accessibility labels, Win balloon notifications,
print via `window.print()`, and `desktop.updates.checkForUpdate`
shipped 2026-05-26. Native print dialog
(`NSPrintOperation` / `ICoreWebView2_16::ShowPrintUI` /
`webkit_print_operation_run_dialog`) + `--template minimal`
scaffold variant shipped 2026-05-27 (v0.1.7). Complete macOS
sweep shipped 2026-05-28 (v0.1.8): IOKit battery, SF Symbol
tray, four new modules (`desktop.network`, `desktop.fswatch`,
`desktop.hotkeys`, `desktop.process`), clipboard HTML, runtime
URL-scheme registration, print page-range / copies / printer
settings, plus `LSMinimumSystemVersion` bump to 11.0 and
`pumpUntilDone` re-entrancy doc. Remaining P3 follow-ups: GTK4
+ WebKitGTK 6.0 backend, Win + Linux backfill for file-watch /
hotkeys / clipboard-HTML / URL-scheme-registration / print
extras, full a11y provider (NSAccessibility / UIA / ATK roles +
states), Win Toast notifications (`ToastNotificationManager`),
auto-updater apply phase (Sparkle / Squirrel / AppImageUpdate),
and macOS `UNUserNotificationCenter` migration (needs
entitlements).

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

## Notarization (macOS)

To distribute a Verve desktop app outside the App Store without the
Gatekeeper "unidentified developer" block, notarize the signed bundle.
This requires a paid Apple Developer account and a **Developer ID
Application** certificate in your keychain.

One-time: store notary credentials as a keychain profile (so secrets never
appear on the build command line):

```sh
xcrun notarytool store-credentials verve-notary \
  --apple-id "you@example.com" \
  --team-id "ABCDE12345" \
  --password "<app-specific-password>"   # appleid.apple.com → App-Specific Passwords
```

Then build, sign, and notarize in one step:

```sh
zig build notarize \
  -Dcodesign="Developer ID Application: Your Name (ABCDE12345)" \
  -Dnotarize-profile=verve-notary \
  -Dbundle-id=com.example.myapp
```

`-Dnotarize-profile` implies the hardened runtime, so you do not need
`-Dhardened=true` as well. The step produces:

- `zig-out/<name>.app` — signed, hardened, **stapled** (runs offline).
- `zig-out/<name>.zip` — the stapled `.app`, ready to distribute.

(`zig-out/<name>-submission.zip` is an intermediate pre-ticket container —
do not distribute it.)
