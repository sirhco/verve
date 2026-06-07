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
   shipped 2026-05-24/25/26/27/28/29 are listed under "Out of P1
   scope — shipped" below. **macOS is feature-complete for
   self-built apps as of v0.1.9** — the 2026-05-29 close-out added
   pure-Zig `applyUpdate` (download + SHA-256 verify + same-volume
   rename swap + `open -n` relaunch) and the opt-in `-Dhardened=true`
   build path (entitlements + `--options=runtime`). The 2026-05-28
   sweep added IOKit battery, SF Symbol tray, four new modules
   (`desktop.network` / `desktop.fswatch` / `desktop.hotkeys` /
   `desktop.process`), clipboard HTML, runtime URL-scheme
   registration, and print page-range / copies / printer settings,
   plus pumpUntilDone re-entrancy doc + LSMinimumSystemVersion bump
   to 11.0. Remaining P3 backlog is Windows + Linux backfill
   (file-watch, hotkeys, clipboard HTML, URL-scheme registration,
   print extras, update-apply), GTK4 backend, full a11y provider,
   WinRT Toast, notarization automation (documented manual
   sequence today), and `UNUserNotificationCenter` migration on
   macOS (deferred — needs entitlements).
4. **Hard constraint: do not modify `src/verve.zig`.** Public web
   surface stays unchanged. Anything desktop-specific goes in
   `src/desktop/` or the template tree.

Authoritative state of the desktop scaffold subsystem and the remaining
work needed to call it "fully functional." Written 2026-05-22, last
updated 2026-05-28. Fresh sessions should be able to pick up without
prior context.

## Done in the 2026-06-07 session — Windows native host: first REAL-HARDWARE boot

The Bundle 9 native WebView2 host (2026-06-04) had only ever been
**cross-compiled** (`x86_64-windows-gnu`) — never run on a real Windows host.
This session scaffolded and ran both `--desktop` templates on real Windows 11
(Zig 0.16.0, WebView2 Evergreen 149). Five Windows-only defects surfaced — none
caught by the macOS/Linux CI, which never compiles these paths, nor by the
template's `zig build smoke` (it only screenshots + checks PNG size, so it
**false-passed** over a `CreateCoreWebView2Environment failed` dialog on a blank
webview). All fixed; shipped in v0.1.42:

- [x] **`SetAllowedOrigins` COM signature** — vendored `WebView2.h` declares the
  2nd param `LPCWSTR *`; the `LPWSTR *` override left `CustomSchemeRegistration`
  abstract (compile error).
- [x] **`notifications.zig` non-exhaustive switch** — Windows balloon fallback
  over `tray.Error` missed the macOS-only `ObjcClassMissing` variant (compile
  error).
- [x] **Blank webview / `E_INVALIDARG`** — `VerveEnvironmentOptions.
  get_TargetCompatibleBrowserVersion` returned `""`;
  `CreateCoreWebView2EnvironmentWithOptions` rejects an options object with no
  parseable version. Now returns `CORE_WEBVIEW_TARGET_PRODUCT_VERSION`
  (`148.0.3967.48`).
- [x] **`?query` navigation → `ERR_INVALID_RESPONSE`** — the `verve://app/`
  scheme handler did not strip the query/fragment before the asset lookup
  (macOS gets this free via `NSURL.path`). Broke `index.html?smoke=1`.
- [x] **IPC fully broken** — Windows injected only `window.verve = { post }`,
  never `ipc.zig`'s `shim_js`, so `send` / `request` / `onMessage` were
  undefined. Added the `wv2_add_user_script` host ABI;
  `windows_native.zig` injects the shim at document-start like macOS, and
  `bridgeTrampoline` now intercepts the `__verve_title:` marker.
- [x] **`desktop.updates` test compile** — `applyUpdateWindows` used the removed
  `std.process.getEnvVarOwned`; switched to `GetEnvironmentVariableW`.

Verified end-to-end on real hardware: both templates build, render, hydrate
WASM, and complete an IPC round-trip; the full template's `app.exe --smoke`
self-driving harness now writes `checksum.txt` + `shot.png` and self-terminates.
Regression guard added: **`tools/validate_scaffold_windows.ps1`** (rigorous
`--smoke` gate, not the false-passing screen capture). Desktop + core + client
tests: 336/336. (Pre-existing, unrelated: `tests/integration.zig`'s `floodWorker`
crashes under concurrent HTTP on Windows — a std.Io socket-concurrency issue in
the server test, not desktop.)

Follow-up the same day — **Bundle 9 (WinRT Toast) and Bundle 12 (Windows live
validation) closed** (see the deferred-bundles list below):

- **Bundle 9 — WinRT Action Center toast**: live-validated. A startup
  `notifications.show` logged `showToast OK (WinRT Action Center path)` (no
  balloon fallback), proving the hand-rolled WinRT/COM vtable-slot chain
  (`RoInitialize` → `XmlDocument.LoadXml` → `ToastNotificationManager.
  CreateToastNotifierWithId` → `CreateToastNotification` → `IToastNotifier::Show`)
  works, and the AUMID Start-menu `.lnk` was created (IShellLink / IPropertyStore
  / IPersistFile chain). No code change required — the deferral was a
  live-validation gate only.
- **Bundle 12 — Windows live validation**: the remaining WebView2 vtable surface
  is verified — the core path (env/controller/nav/custom-scheme/
  `WebMessageReceived`/`CapturePreview`) via the `--smoke` round-trip, plus the
  async `ICoreWebView2CookieManager::GetCookies` nested-pump path via a set→get
  cookie roundtrip (`cookie roundtrip OK: verve_diag=bundle12`). The only
  Windows item still open is **silent print**, which is an unimplemented feature
  (advisory-only today), not a validation gap.

Also the same day — **Linux GTK4 drag-drop fixes** (commits `2cf8afd` →
`48a20d5` → `5f322c9` → `d2247c3`):

- [x] **Scaffold drag-drop handler added** (`2cf8afd`) — `templates/desktop/src/main.zig`
  gained `on_drag_drop` wiring to log dropped file paths via IPC.
- [x] **`onDragDrop` signature corrected** (`48a20d5`) — parameter was
  `[*:0]const u8` (single C-string); corrected to `[]const []const u8` (slice
  of UTF-8 path slices) matching the `DragDropHandler` typedef in `options.zig`.
- [x] **WebKit file:// navigation blocked on drag-drop** (`5f322c9`) — GTK4
  `drag-data-received` trampoline returned without calling `gtk_drag_finish`,
  letting WebKit interpret the dropped `file://` URI as a navigation request and
  blank the webview. Fixed: call `gtk_drag_finish(ctx, TRUE, FALSE, time)` after
  the user callback returns.
- [x] **`decide-policy` narrowed to file:// URLs** (`d2247c3`) — the
  `decide_policy` signal handler blocked all navigation; changed to only block
  `file://` scheme navigations so non-file navigations still work correctly.

## Done in the 2026-06-04 session — Windows native-host CUTOVER (Bundle 9)

- [x] **The Windows desktop backend is now the native C++ WebView2 host.**
  `src/desktop/windows_native.zig` (a thin Zig shim over the flat C ABI in
  `src/desktop/win_native/host.h`, implemented by
  `src/desktop/win_native/webview2_host.cpp`) is the **sole** Windows backend.
  `backend.zig` selects it **unconditionally** on Windows — the
  `verve_win_backend_native` root-decl / `@hasDecl` opt-in gate is gone, and
  with it the legacy-vs-native fallback. `window.zig`, `cookies.zig`,
  `clipboard.zig`, `tray.zig`, and `notifications.zig` all resolve the Windows
  backend through `backend.zig`'s `impl`; none import a backend file directly
  anymore.
- [x] **Deleted the 4129-line pure-Zig hand-rolled COM backend**
  (`src/desktop/windows.zig`). The native host owns the Win32 window, the
  WebView2 controller, the message loop, cookies/clipboard, dialogs, the UIA
  a11y provider, WinRT toasts, and now **tray dispatch**: the host `WndProc`
  forwards `WM_COMMAND` (0xC000 tray-id block) and `WM_VERVE_TRAY` to Zig
  trampolines registered via the new `wv2_set_tray_dispatch`, and exposes the
  window handle via `wv2_hwnd` (consumed by `tray.zig`'s `hwndOf`). The Zig
  identity holds: the **framework core stays pure-Zig**; the desktop native
  hosts (macOS objc, Windows C++, Linux GTK) are thin platform glue behind a
  uniform `Window` surface.
- [x] **Scaffold templates compile the C++ host.** `templates/desktop/build.zig`
  and `templates/desktop-minimal/build.zig` now `addCSourceFile` the vendored
  `webview2_host.cpp` (c++17, `-fms-extensions -fno-exceptions -fno-rtti`,
  `UNICODE`), add the `win_native/include` header path, link `Comdlg32`/`Gdi32`
  alongside the existing Win libs, and install the vendored
  `WebView2Loader.dll` next to `app.exe` (the host `LoadLibraryW`s it at
  startup — no import lib or NuGet SDK fetch). The scaffold embed pipeline
  already vendors `src/desktop/win_native/**` (cpp + headers + DLL) verbatim,
  so a `--desktop` app is self-contained.
- [x] **Cross-compile verified** at cutover: `zig build`, `zig build test`
  (336/336), `zig build win-native`, and a scaffolded `--desktop` app (both
  `full` and `minimal`) cross-compiling clean for `x86_64-windows-gnu`,
  producing `app.exe` + `WebView2Loader.dll`. **NB:** this was cross-compile
  only — the native host was *not* run on real Windows until the 2026-06-07
  session above, which found five blocking defects. Treat "compiles" and "boots"
  as separate gates for the native backends.

## Done in the 2026-06-02 session

- [x] **Window-chrome a11y provider.** Three new `Window` methods on all
  three backends: `setAccessibilityHelp`, `setAccessibilityRoleDescription`,
  `setAccessibilitySubrole(AccessibilitySubrole)`. macOS: real
  `setAccessibilityHelp:` / `setAccessibilityRoleDescription:` /
  `setAccessibilitySubrole:` (subrole tags map to AXStandardWindow /
  AXDialog / AXSystemDialog / AXFloatingWindow). **Windows: a server-side
  UIA provider** — an `IRawElementProviderSimple` embedded per `WindowCtx`,
  returned from `WM_GETOBJECT`/`UiaRootObjectId` via
  `UiaReturnRawElementProvider`. `GetPropertyValue` maps role-desc →
  `UIA_LocalizedControlTypePropertyId`, help → `UIA_HelpTextPropertyId`,
  and dialog subroles → `UIA_IsDialogPropertyId`; `UiaHostProviderFromHwnd`
  supplies Name/bounds and the WebView2 subtree. Links `Uiautomationcore`.
  Linux: help → `atk_object_set_description`; role-desc + subrole no-op
  (logged) pending an AtkObject provider. New `AccessibilitySubrole`
  enum in `options.zig`; ABI-guarded in `surface_test.zig`. No
  `src/verve.zig` change. Conformance enforced by the comptime list in
  `window.zig`; macOS verified via `zig build-obj -target aarch64-macos`,
  Win/Linux cross-compile clean. Live a11y-tree verification on
  Win/Linux deferred — host-gated.
- [x] **macOS notifications → UNUserNotificationCenter.**
  `notifications.show` macOS branch rewritten off the deprecated
  `NSUserNotification`. Guards on `[[NSBundle mainBundle]
  bundleIdentifier]` (unbundled → `error.Unsupported`); first call
  requests authorization (`requestAuthorizationWithOptions:` alert|sound)
  and pumps a nested `NSRunLoop` until the grant resolves, caching it
  process-wide; denied → `error.Unsupported`. Delivers via
  `UNMutableNotificationContent` + `UNNotificationRequest` (nil trigger).
  Scaffold `build.zig` links `UserNotifications.framework`. Cross-platform
  `show(allocator, opts)` surface unchanged; Linux/Windows untouched. No
  `src/verve.zig` change. macOS semantic compile verified via
  `zig build-obj -target aarch64-macos`; live delivery needs a signed
  bundle (deferred to a signing-capable host).
- [x] **Fixed dead binding-walker in island-free desktop apps.** The
  scaffold demo's counter never updated: the JS walker that registers
  `bindI32` signals requires `verve_island_scratch_ptr`/`_capacity`
  exports, but those lived in the framework's `src/client/main.zig`, so
  the desktop template's own minimal `main.zig` (no islands) didn't
  export them → walker skipped → `signalI32("count")` null → clicks
  no-op. Moved the scratch buffer + accessors into the shared
  `src/client/runtime_exports.zig` (force-included via `verve_client`)
  so every client entry exports them. Added a same-file regression-guard
  test + a "walker skipped" `console.warn` in both bridges. Pre-existing
  bug, unrelated to the notification migration.
- [x] **Scaffold `zig build notarize` step.** `templates/desktop/build.zig`
  gained a `notarize` step (gated on `-Dnotarize-profile` + `-Dcodesign`):
  ditto-zips the signed bundle, `xcrun notarytool submit --wait` against a
  keychain profile, `xcrun stapler staple`s the ticket, then re-zips the
  stapled `.app` as `zig-out/<name>.zip`. Requesting notarize implies the
  hardened runtime. The framework notarizes nothing itself — downstream
  apps run it under their own Developer ID Application cert; structural
  verification only here (no Developer ID cert on the dev box).

## v0.1.0 — first tagged release (2026-05-26)

Pushed to `sirhco/verve` as `v0.1.0`. Release workflow built and
published binaries for x86_64-linux-gnu, aarch64-linux-gnu,
x86_64-macos, aarch64-macos, x86_64-windows-gnu. Each platform
ships a `verve-<version>-<arch>-<os>.tar.gz` with the verve-cli +
verve-server binaries, LICENSE, README, CHANGELOG and a `.sha256`
sibling. `verve-cli` gained `--release <tag>` + `--release-hash
<h>` flags so scaffolded `build.zig.zon` can pin a URL+hash dep
against the published tag.

## Done in the 2026-05-26 session

Five P3 bundles shipped to `main`. First three tagged as `v0.1.0`:
- Tray click handlers + submenus (all 3 backends).
- Release prep — `verve-cli new --release` flag + CHANGELOG bump to
  0.1.0 + working release.yml run.
- Custom tray icons via `Tray.setIcon(path)` + `TrayOptions.icon_path`
  (all 3 backends).

Shipped post-tag (will roll into a v0.1.1 / v0.2.0):
- Windows balloon-tip notifications via existing tray. Replaces the
  `error.Unsupported` Win branch in `notifications.show`.
- Hicolor / Linux desktop integration — `zig build install-icons`
  stages a freedesktop icon-theme + `.desktop` file tree under
  `zig-out/share/` for user / system install.
- Drag-drop with native file paths — `Window.setDragDropHandler` +
  `WindowOptions.on_drag_drop`. macOS via `VerveDragWindow` NSWindow
  subclass + `registerForDraggedTypes:`; Windows via `IDropTarget`
  COM + `RegisterDragDrop` + `DragQueryFileW`; Linux via
  `gtk_drag_dest_set` + `drag-data-received` signal.
- Print API — `Window.print()` dispatches via `window.print()` on
  all 3 engines (WKWebView / WebView2 / WebKitGTK). Native APIs
  (`NSPrintOperation` / `ICoreWebView2_16::ShowPrintUI` /
  `webkit_print_operation_run_dialog`) deferred as polish for
  silent print + advanced controls.
- Window accessibility label — `Window.setAccessibilityLabel(text)`
  on all 3 backends. macOS: NSAccessibilityLabel. Linux:
  `atk_object_set_name` on the window's AtkObject. Windows: routes
  through `setTitle` since Win32 has no separate a11y-label
  channel without a custom UIA provider.
- Auto-updater check — new `desktop.updates` module:
  `checkForUpdate(allocator, feed_url, current_version) Error!?UpdateInfo`.
  Pure stdlib (`std.http.Client` + `std.json`); identical on all 3
  platforms; no native frameworks linked. Returns `null` when the
  caller is already up to date. Applying the update (download,
  signature verify, swap binary, restart) stays out of scope —
  Sparkle / Squirrel / AppImageUpdate handle that per platform.
- Window state — `Window.setAlwaysOnTop(bool)` +
  `Window.setOpacity(f64)` on all 3 backends. macOS:
  `setLevel:NSFloatingWindowLevel` + `setAlphaValue:` / `setOpaque:`.
  Windows: `SetWindowPos(HWND_TOPMOST)` +
  `SetLayeredWindowAttributes(LWA_ALPHA)` with `WS_EX_LAYERED`
  stamped via `SetWindowLongPtrW`. Linux:
  `gtk_window_set_keep_above` + `gtk_widget_set_opacity`.
- Auto-launch on login — new `desktop.autostart` module:
  `enable(allocator, io, environ, opts)` / `disable(...)` /
  `isEnabled(...)`. User-scoped, no admin prompt. macOS writes
  `~/Library/LaunchAgents/<name>.plist` (launchd picks up on
  next session). Windows writes
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` registry
  value via advapi32 RegSetValueExW / RegDeleteValueW. Linux
  writes `~/.config/autostart/<name>.desktop` (every
  freedesktop session). Options struct carries
  `name`/`exe_path`/`display_name`/`args`.
- Power / battery — new `desktop.power` module:
  `batteryPercent() ?u32` + `isCharging() bool`. Windows:
  `GetSystemPowerStatus` (kernel32). Linux: reads
  `/sys/class/power_supply/BAT[0-9]/capacity` + `status` via
  posix open + bounded read (iterates BAT0..BAT9). macOS
  currently returns null / false — IOKit
  (`IOPSCopyPowerSourcesInfo`) deferred until scaffold links
  the IOKit framework.
- Disk space — new `desktop.disk` module:
  `spaceAt(allocator, path) Error!Space`. `Space { total,
  available, free }` in bytes. POSIX: `statvfs` with
  `f_blocks * f_frsize`, `f_bavail * f_frsize`, `f_bfree *
  f_frsize`. Windows: `GetDiskFreeSpaceExW(path, free_for_caller,
  total, total_free)`. Useful for capacity dashboards, pre-flight
  checks before large writes.
- System uptime — `desktop.system.uptime() u64` returns seconds
  since boot. macOS: `sysctlbyname("kern.boottime")` + `time(2)`
  delta. Windows: `GetTickCount64() / 1000`. Linux: parses the
  first float in `/proc/uptime`.
- System resource info — `desktop.system.cpuCount() usize` (incl.
  hyperthreads, falls back to 1 on failure) +
  `desktop.system.totalMemory() u64` (physical RAM in bytes,
  falls back to 0). Thin wrappers over `std.Thread.getCpuCount`
  and `std.process.totalSystemMemory`.
- System bell + process ID — `desktop.system.beep()` triggers
  the OS audible alert (NSBeep / MessageBeep / stdout BEL).
  `desktop.system.processId()` returns the current PID for log
  correlation / IPC keying. Pure stdlib + per-platform externs.
- Window state queries — `Window.isMinimized()` / `isMaximized()`
  / `isFullscreen()` on all 3 backends. macOS:
  `isMiniaturized` / `isZoomed` / `styleMask &
  NSWindowStyleMaskFullScreen`. Windows: `IsIconic` /
  `IsZoomed` from user32 + cached `fullscreen` flag from
  `setFullscreen`. Linux: `gdk_window_get_state` mask checks +
  `gtk_window_is_maximized`.
- Window attention request — `Window.requestAttention(critical)`
  pulses dock icon / flashes taskbar / sets WM urgency hint.
  macOS: `[NSApp requestUserAttention:NSCriticalRequest|NSInformationalRequest]`.
  Windows: `FlashWindowEx(FLASHW_ALL | FLASHW_TIMERNOFG)` for
  critical (flash until user clicks), `FLASHW_ALL` with count=5
  for informational. Linux: `gtk_window_set_urgency_hint(true)`.
- Window scale factor — `Window.scaleFactor()` returns the
  HiDPI multiplier of the window's current screen. macOS:
  `[window backingScaleFactor]` (tracks the monitor the window
  sits on). Windows: `GetDpiForWindow(hwnd) / 96.0`. Linux:
  `gtk_widget_get_scale_factor`.
- Window zoom — `Window.setZoom(level)` / `getZoom()` on all 3
  backends. `1.0` = 100%; engines clamp to their supported range.
  macOS: `WKWebView setPageZoom:` / `pageZoom`. Windows:
  `ICoreWebView2Controller::get_ZoomFactor` / `put_ZoomFactor`
  (vtSlots 11 / 12). Linux: `webkit_web_view_set_zoom_level` /
  `_get_zoom_level`.
- System info — new `desktop.system` module:
  `locale(allocator, environ) ![]u8` + `osVersion(allocator) ![]u8`.
  macOS: `[NSLocale currentLocale].localeIdentifier` +
  `[NSProcessInfo processInfo].operatingSystemVersionString`.
  Windows: `GetUserDefaultLocaleName` + `RtlGetVersion`
  (OSVERSIONINFOEXW from ntdll.dll). Linux: `LC_ALL` / `LANG`
  env vars (with `.UTF-8` / `@modifier` stripped) +
  `/etc/os-release` `PRETTY_NAME` parse. Three headless tests
  fire on `zig build test` (os-release with quotes, unquoted,
  locale codeset strip).
- Standard directories — new `desktop.paths` module:
  `dataDir` / `cacheDir` / `configDir` / `homeDir` / `tempDir`.
  Takes `std.process.Environ` (typically `init.minimal.environ`)
  + allocator + app name; returns owned UTF-8 absolute path.
  macOS: `~/Library/Application Support/<app>` +
  `~/Library/Caches/<app>`. Windows: `%APPDATA%\<app>` +
  `%LOCALAPPDATA%\<app>`. Linux: XDG ($XDG_DATA_HOME /
  $XDG_CACHE_HOME / $XDG_CONFIG_HOME) with `$HOME/.local/share`
  / `$HOME/.cache` / `$HOME/.config` fallbacks. Pure stdlib, no
  native APIs.
- Page title auto-sync — the IPC shim_js polls `document.title`
  every 500ms and posts a `__verve_title:<title>` marker via the
  native bridge whenever it changes. Each backend's script-message
  trampoline (`handleScriptMessage` on macOS, `onScriptMessage`
  on Linux, `onMessageReceived` on Windows) peeks for the prefix
  before forwarding to the user's `MessageHandler` — when matched,
  it calls the native title setter (`setTitle:` / `gtk_window_set_title`
  / `SetWindowTextW`) and returns without propagating. Pages that
  change `<title>` (or call `document.title = ...`) now propagate
  to the OS title bar / taskbar / window-list with no app code.
- Navigation queries — `Window.canGoBack()` / `canGoForward()` /
  `currentUrl(allocator) ![]u8` / `currentTitle(allocator) ![]u8`
  on all 3 backends. Pairs with `goBack` / `goForward` for back
  / forward UI that grays out at history endpoints; `currentUrl`
  + `currentTitle` enable bookmark / share / address-bar
  features. macOS: `WKWebView` selectors `canGoBack` /
  `canGoForward` / `URL` / `title` with a new
  `nsStringToOwnedUtf8` helper. Windows: vtSlots 38 / 39 /
  4 / 48 on ICoreWebView2; `CoTaskMemFree` releases the
  WinRT-allocated LPWSTRs after UTF-16→UTF-8 conversion. Linux:
  `webkit_web_view_can_go_back` / `_can_go_forward` /
  `_get_uri` / `_get_title`.
- Navigation helpers — `Window.reload()` / `goBack()` /
  `goForward()` on all 3 backends. macOS: `WKWebView reload` /
  `goBack` / `goForward`. Windows: vtSlots 31 / 40 / 41 on
  `ICoreWebView2`. Linux: `webkit_web_view_reload` /
  `_go_back` / `_go_forward`. macOS uses `reloadFromOrigin` for
  cache-bypass behavior matching Cmd+Shift+R.
- Shell helpers — new `desktop.shell` module:
  - `openUrl(allocator, url)` hands a URL to the OS shell so it
    opens externally (system browser / registered handler app).
    macOS: `[NSWorkspace openURL:]`. Windows:
    `ShellExecuteW(NULL, "open", url, NULL, NULL,
    SW_SHOWNORMAL)`. Linux: `posix.fork` + `execvp("xdg-open",
    ...)`.
  - `showInFolder(allocator, path)` reveals a file in the OS
    file manager. macOS:
    `[NSWorkspace selectFile:inFileViewerRootedAtPath:]` (Finder
    pre-selects). Windows: `ShellExecuteW(NULL, "open",
    "explorer.exe", "/select,<path>", ...)` (Explorer
    pre-selects). Linux: `xdg-open <parent_dir>` — freedesktop
    has no portable "select this file" verb, so the file's row
    won't be pre-highlighted.
- Multi-display enumeration — new `desktop.displays` module:
  `list(allocator) Error![]Display`. `Display { x, y, width,
  height, scale, primary }`. macOS: `[NSScreen screens]` +
  `backingScaleFactor`, with Y-flip to convert AppKit's bottom-
  left origin into top-left for cross-platform parity. Windows:
  `EnumDisplayMonitors` callback + `GetMonitorInfoW` +
  `GetDpiForMonitor` (Shcore.dll). Linux: `gdk_display_get_default`
  → `gdk_display_get_n_monitors` / `_get_monitor` /
  `_get_geometry` / `_get_scale_factor`. New `Shcore`
  link-line entry in `templates/desktop/build.zig` for Windows.
- Window min/max size — `Window.setMinSize(w, h)` /
  `setMaxSize(w, h)` on all 3 backends. `(0, 0)` clears the
  constraint. macOS: `setContentMinSize:` / `setContentMaxSize:`
  on NSWindow. Windows: new `WM_GETMINMAXINFO` case in wndProc
  patches `ptMinTrackSize` / `ptMaxTrackSize` from cached
  WindowCtx fields. Linux: shared `applyGeometryHints` helper
  composes `GdkGeometry` + flag mask, calls
  `gtk_window_set_geometry_hints` with `GDK_HINT_MIN_SIZE` /
  `GDK_HINT_MAX_SIZE` flags.
- Window event callbacks — `Window.setResizeHandler` /
  `setFocusHandler` / `setCloseHandler` (+ matching
  `WindowOptions.on_resize` / `on_focus` / `on_close` init-time
  fields) on all 3 backends. `ResizeHandler` fires with the new
  content size; `FocusHandler` with focused/blurred state;
  `CloseHandler` returns `true` to allow close, `false` to keep
  the window open (for "Unsaved changes?" prompts). macOS:
  `VerveWindowDelegate` NSObject subclass; `windowDidResize:` +
  `windowDidBecomeKey:` + `windowDidResignKey:` +
  `windowShouldClose:`. Windows: `WM_SIZE` + `WM_ACTIVATE` +
  `WM_CLOSE` cases in wndProc; `WM_CLOSE` falls through to
  `DefWindowProcW` when the handler returns `true` or no handler
  is set. Linux: `g_signal_connect_data` on `configure-event`,
  `focus-in-event` / `focus-out-event`, `delete-event` — the
  delete handler returning 1 ("don't propagate") maps to "block
  close."
- Window visibility + focus — `Window.show()` / `hide()` /
  `focus()` / `setResizable(bool)` on all 3 backends. macOS:
  `makeKeyAndOrderFront:` + `activateIgnoringOtherApps:` /
  `orderOut:` / styleMask toggle for resizable. Windows:
  `ShowWindow(SW_SHOW/SW_HIDE/SW_RESTORE)` +
  `SetForegroundWindow`; resizable via `WS_THICKFRAME` |
  `WS_MAXIMIZEBOX` style toggle with `SWP_FRAMECHANGED`. Linux:
  `gtk_widget_show_all` / `gtk_widget_hide` / `gtk_window_present` /
  `gtk_window_set_resizable`. Template demo's tray "Show window"
  menu item now actually calls `window.show()` + `window.focus()`
  instead of faking it with evalJs.
- Window geometry + lifecycle — `Window.setSize`, `setPosition`,
  `center`, `minimize`, `maximize`, `restore`, `setFullscreen` on
  all 3 backends. macOS: `setContentSize:` / `setFrameTopLeftPoint:`
  / `center` / `miniaturize:` / `zoom:` / `deminiaturize:` /
  `toggleFullScreen:`. Windows: `SetWindowPos` (size + move) /
  `ShowWindow` (SW_MINIMIZE/MAXIMIZE/RESTORE) / fullscreen via
  strip-WS_OVERLAPPEDWINDOW + monitor-size SetWindowPos (saved
  style + rect on `WindowCtx` so `setFullscreen(false)` round-
  trips). Linux: `gtk_window_resize` / `gtk_window_move` /
  `gtk_window_iconify` / `maximize` / `unmaximize` /
  `fullscreen` / `unfullscreen` / `gtk_window_set_position` (for
  `center`).

### Tray click handlers + submenus

Builds directly on the 2026-05-25 tray work (commit `68af576`).

- [x] **Tray click handlers + submenus** (all 3 backends). Cross-
  platform additions to `src/desktop/tray.zig`:
  - New `TrayMenuItem { label, id, enabled, children }` value type
    (null label = separator; non-empty `children` = submenu parent).
  - `TrayOptions` grew `menu`, `on_click` + `on_click_ctx`,
    `on_menu_item` + `on_menu_item_ctx`. ABI matches
    `MessageHandler` / `UrlOpenHandler` / `ColorSchemeHandler` —
    `fn(ctx: ?*anyopaque, ...) void`.
  - New methods on `Tray`: `setMenu(items)` (deep-copies),
    `setClickHandler`, `setMenuItemHandler`.
  - `Tray.impl` heap-allocates per-platform impl so the singleton
    pointers used by Cocoa target/action and the Win wndProc
    forwarder see a stable address after `init` returns by value.
  - **macOS**: NSMenu built via `objc_msgSend`; menu items target
    a process-wide `VerveTrayTarget` NSObject (registered lazily
    via `objc_allocateClassPair`) with `verveTrayItem:` /
    `verveTrayClick:` selectors. Each `NSMenuItem.setTag:` carries
    the user-defined id; the trampoline reads `[sender tag]` and
    dispatches to the singleton tray's `on_menu_item`. Cocoa
    attaches the menu via `setMenu:` and shows it on any click of
    the status item — `on_click` only fires when no menu is set.
  - **Windows**: `NOTIFYICONDATAW.uCallbackMessage =
    WM_VERVE_TRAY` (= `WM_USER + 100`, declared pub in
    `windows.zig` so `tray.zig` references one canonical value).
    `windows.zig` wndProc gained two cases: `WM_VERVE_TRAY`
    forwards mouse events to `tray_dispatch_message`, and
    `WM_COMMAND` checks for the tray's `0xC000` ID block before
    falling through. `tray.zig` registers both dispatchers on
    first `Tray.init`. Menu items use IDs `0xC000 | (user_id &
    0x0FFF)` — collisions with the default `0x8000` File/Edit
    range are impossible. Right-click + WM_CONTEXTMENU show the
    menu via `TrackPopupMenu` (with the MSDN-mandated
    `SetForegroundWindow` + `PostMessage(WM_NULL)` dance); left
    click fires `on_click` or shows the menu as a fallback.
  - **Linux**: GtkMenu built from items via
    `gtk_menu_item_new_with_label` + `gtk_menu_shell_append`.
    Submenus via `gtk_menu_item_set_submenu`; separators via
    `gtk_separator_menu_item_new`; disabled rows via
    `gtk_widget_set_sensitive(item, 0)`. Each leaf gets a
    `g_signal_connect_data("activate", trampoline, ItemBox)`
    where `ItemBox = { *LinuxTray, id }` lives on the tray's
    allocator and is freed in `deinit`. AppIndicator doesn't
    expose icon-click signals, so `on_click` is a no-op on Linux
    when a menu is set (the indicator only shows the menu).
  - Template demo: `templates/desktop/src/main.zig` now passes a
    4-item menu (Show window, Notify, separator, Quit) with id
    routing in the new `handlers.onTrayItem`. Components grew a
    "Tray menu" card explaining the click behavior. Golden
    checksum bumped from `284` → `605`.
  - **v1 single-tray-per-process assumption** documented in
    module header. Multi-tray would need per-target ivars on
    macOS + HWND-keyed registry on Windows instead of the current
    `g_macos_tray` / `g_windows_tray` singletons — deferred until
    a use case shows up.

### Verification

- Framework `zig build` + `zig build test` PASS.
- 3-backend cross-compile (`aarch64-macos`, `x86_64-linux-gnu`,
  `x86_64-windows-gnu`) clean for `window.zig`, `tray.zig`, and
  `windows.zig`.
- macOS scaffold live boot: app boots, tray icon appears in the
  menu bar, no log warnings. Smoke harness PASS (`checksum=605`).
- Live Win/Linux validation deferred — no hosts. Same convention
  as cookies / clipboard / color-scheme / menus / tray init.

## Done in the 2026-05-25 session

Four P3 bundles shipped to `ui-ki`. All committed; tree clean at
session end. Commit chain (newest first):

```
68af576 desktop: tray icons + native notifications
c0aeef5 desktop: warm-launch URL forwarding on Win + Linux
e96d190 desktop: deep-link URL handlers (macOS AEH + Win/Linux cold-launch)
a31ac6c desktop: native menu bars on Windows + Linux
```

- [x] **Win/Linux native menu bars** (`a31ac6c`). Default File (Quit,
  Ctrl+Q) + Edit (Undo/Redo/Cut/Copy/Paste/Select All) honoring the
  existing `install_default_menu` flag. Win uses
  `CreateMenu`/`SetMenu` + one-entry `HACCEL` for Ctrl+Q routed
  through `TranslateAcceleratorW` + `WM_COMMAND`. Linux wraps the
  webview in a `GtkBox` + `GtkMenuBar` with a single Ctrl+Q binding
  on the accel group. Edit items render the shortcut hint in the
  label only — WebView2 / WebKitGTK handle the actual keystrokes
  natively. Opt-out (`install_default_menu = false`) keeps the
  pre-existing tree unchanged on every backend.
- [x] **Deep-link URL handlers** (`e96d190`).
  `Window.setUrlOpenHandler(cb, ctx)` + `Window.deliverUrl(url)` on
  the public surface; new `UrlOpenHandler` type and
  `on_url_open`/`on_url_open_ctx` on `WindowOptions`. macOS installs
  an `NSAppleEventManager` handler for `kInternetEventClass` /
  `kAEGetURL` (FourCharCode `'GURL'`, `0x4755524C`) lazily on the
  first non-null call; Cocoa queues pre-launch URLs and drains them
  on the next run-loop spin. Win + Linux: cold-launch via argv —
  template `main.zig` parses `--url <u>` (or any positional
  starting with `verve://`) and feeds the URL through `deliverUrl`
  after the window opens. Scaffold `build.zig` gains
  `-Durl-scheme=<name>` which injects `CFBundleURLTypes` into the
  generated `Info.plist`. New `window.verve.handleDeepLink` JS
  bridge hook + "Deep link" card in the demo page.
- [x] **Win/Linux warm-launch URL forwarding** (`c0aeef5`). New
  `desktop.deep_link` module:
  - `forwardToRunningInstance(allocator, name, url)` — second-instance
    call. Win: `FindWindowW("VerveWindow", null)` + `SendMessageW(WM_COPYDATA)`
    with a `0x55524C00` (`"URL\0"`) `dwData` sentinel so unrelated
    WM_COPYDATA traffic doesn't trip the receiver. Linux: abstract
    `AF_UNIX SOCK_DGRAM` socket bound to
    `\0verve-deeplink-<single_instance_name>`; `connect` + `send`
    a single datagram. macOS returns `error.Unsupported` —
    `NSAppleEventManager` already routes warm-launch URLs through
    the AEH so no second process is spawned.
  - `startListener(window, name)` — running-instance call. Win is a
    no-op (wndProc handles `WM_COPYDATA` directly). Linux wraps the
    bound fd in a `GIOChannel` with a `G_IO_IN` watch so the GTK
    main loop dispatches inbound URLs; `close_on_unref(true)` cleans
    up at window destruction.
  - Template `main.zig`: second-instance `AlreadyRunning` branch
    calls `forwardToRunningInstance` when `--url <u>` was provided
    and exits. Primary instance calls `startListener` after window
    open. macOS `Unsupported` suppressed silently.
- [x] **Tray icons + native notifications** (`68af576`). Two new
  modules:
  - `desktop.tray` — `init(allocator, &window, .{ .label, .tooltip })`
    + `setTooltip(text)` + `deinit`. macOS: `NSStatusItem` from
    `[NSStatusBar systemStatusBar]`. Win: `Shell_NotifyIconW(NIM_ADD)`
    with stock `IDI_APPLICATION` + `NIF_TIP`. Linux: `app_indicator_new`
    (libayatana-appindicator3) with an empty `GtkMenu` attached
    because some Ayatana versions silently refuse to render without
    one. No click handlers, no submenus — those are a future bundle.
  - `desktop.notifications` — `show(allocator, .{ .title, .body })`.
    macOS: `NSUserNotification` + `NSUserNotificationCenter`
    (deprecated but works without a permission grant). Linux:
    `notify_init` + `notify_notification_new` + `notify_notification_show`
    (libnotify). Win: returns `error.Unsupported` — Toast
    notifications need COM + AUMID + Start-menu registration,
    deferred. Apps that need Win notifications today layer a
    manual `Shell_NotifyIconW(NIF_INFO)` on top of the tray icon.
  - `src/desktop/windows.zig` exposes `hwndOf(window)` so sibling
    modules can reach the HWND without going through the
    cross-platform `Window` facade.
  - Template demo: scaffold opens a tray on startup; new `notify`
    IPC route fires a native notification; "Notify" button card in
    the demo page.

### Custom tray icons (`setIcon` API)

Closes the deferred `setIcon` follow-up from the 2026-05-25 notes.
Added 2026-05-26 to `src/desktop/tray.zig`:

- `TrayOptions.icon_path: ?[]const u8` — null falls back to the
  stock per-platform icon. macOS reads anything `NSImage` parses
  (PNG / JPEG / ICNS / TIFF); Windows expects a `.ico` file; Linux
  accepts a PNG path or a theme icon name (both go through
  `app_indicator_set_icon_full`).
- `Tray.setIcon(path)` on the public surface — same accepted-format
  rules. Returns `error.Backend` when the OS rejects the file.
- macOS: `[[NSImage alloc] initWithContentsOfFile:]` + `setImage:`
  on the status item's button. Loaded image marked
  `setTemplate:true` so the menu bar applies its standard
  light/dark tint (best with monochrome PNGs); colored icons still
  show but don't tint. Old image released after the button takes
  its own ref; the existing label is cleared on icon set so the
  status bar doesn't render both.
- Windows: `LoadImageW(NULL, path, IMAGE_ICON, 0, 0,
  LR_LOADFROMFILE | LR_DEFAULTSIZE)` then `Shell_NotifyIconW(NIM_
  MODIFY, NIF_ICON)`. The previous HICON is `DestroyIcon`'d ONLY
  when we loaded it ourselves — the stock `IDI_APPLICATION` HICON
  from `LoadIconW(NULL, ...)` is process-shared and must never be
  destroyed. `owns_icon` tracks that distinction.
- Linux: `app_indicator_set_icon_full(ind, path_or_name, desc)`.
  Description string is a fixed "verve tray" for accessibility
  tooling — apps can layer their own atop later.

No template demo wiring — would need a real icon file embedded in
the scaffold, which isn't worth the bytes for a v1 feature. Apps
add their own icon path in `TrayOptions` or call `setIcon` after
init.

### Hicolor / Linux desktop integration

`templates/desktop/build.zig` gains an `install-icons` step
(gated on `target.result.os.tag == .linux`) that lays out a
Hicolor icon-theme tree + freedesktop `.desktop` file under
`zig-out/share/`:

- `zig-out/share/icons/hicolor/scalable/apps/<name>.png` — written
  when `-Dlinux-icon=<path>` is set.
- `zig-out/share/icons/hicolor/<N>x<N>/apps/<name>.png` — written
  for each `-Dlinux-icon-<N>=<path>` (N ∈ {16,22,24,32,48,64,96,
  128,256,512}). No resizing — Zig stdlib has no image library
  and pulling ImageMagick / libpng as a build dep is heavier than
  the value. Apps either pre-resize per size or rely on the
  scalable/ catch-all.
- `zig-out/share/applications/<name>.desktop` — always written.
  Fields configurable via `-Dlinux-categories`, `-Dlinux-comment`,
  `-Dlinux-generic-name`, `-Dlinux-exec`. Default `Exec=<name> %U`
  relies on `$PATH` lookup; users wanting a prefix install override
  with the absolute path.

Install with:
```sh
cp -r zig-out/share ~/.local/share           # user install
sudo cp -r zig-out/share /usr/share          # system install
```
Followed optionally by `gtk-update-icon-cache ~/.local/share/icons/hicolor`
and `update-desktop-database ~/.local/share/applications`.

Step is invisible on non-Linux targets — the gate uses the
resolved `target` so a `-Dtarget=x86_64-linux-gnu install-icons`
cross-stage on macOS / Windows hosts still works.

### Drag-drop with native file paths

Closes the deferred drag-drop bundle. Adds a single cross-platform
callback that surfaces dropped file paths the browser
`DataTransfer` hides by design.

- New `DragDropHandler` typedef in `options.zig`:
  `fn(ctx, paths: []const []const u8) void`. Paths are UTF-8
  absolute filesystem paths. Slice + strings only live for the
  duration of the callback; apps copy if they want to outlive it.
- `WindowOptions.on_drag_drop` + `on_drag_drop_ctx` for
  init-time registration. `Window.setDragDropHandler(cb, ctx)`
  for runtime install/replace/clear.
- Cross-platform conformance enforced by the comptime check in
  `window.zig` (the required-method list gained
  `setDragDropHandler`).

macOS: `objc_allocateClassPair(NSWindow, "VerveDragWindow")`
registers a subclass with `draggingEntered:` +
`performDragOperation:` methods. `object_setClass` swaps an
existing NSWindow instance to it; `registerForDraggedTypes:` is
then called with `@[NSPasteboardTypeFileURL]` (a.k.a.
`public.file-url`). `draggingEntered:` returns
`NSDragOperationCopy` when the pasteboard advertises a file URL;
`performDragOperation:` reads `[NSPasteboard
readObjectsForClasses:@[NSURL.class] options:nil]`, copies each
URL's `path` UTF-8 into a temporary slice, fires the callback,
then frees. A new `window_registry` keyed on the NSWindow ptr
routes the trampoline back to the owning `WindowCtx`.

Windows: minimal `IDropTarget` COM impl embedded in `WindowCtx`
(`drop_target` field, like the existing
`env_handler`/`ctrl_handler`/`msg_handler`/`res_handler`). The
vtable reuses `comQI`/`comAddRef`/`comRelease` from the rest of
the COM scaffolding. `OleInitialize(NULL)` runs once before
`RegisterDragDrop(hwnd, &heap.drop_target)`. `Drop`:
`IDataObject::GetData(CF_HDROP)` → `DragQueryFileW` to count and
extract each path as UTF-16, converted to UTF-8 for the
callback. `RevokeDragDrop` fires on `WM_DESTROY`.

Linux: `gtk_drag_dest_set(window, GTK_DEST_DEFAULT_ALL, NULL, 0,
GDK_ACTION_COPY)` + `gtk_drag_dest_add_uri_targets(window)` +
`g_signal_connect_data(window, "drag-data-received", ...)`. The
trampoline reads `gtk_selection_data_get_uris` (NUL-terminated
`gchar**`), strips the `file://` scheme prefix from each URI,
fires the callback, then `gtk_drag_finish(ctx, TRUE, FALSE,
time)`. The connection id is stashed on `WindowCtx.drag_signal`
so `setDragDropHandler(null, null)` can disconnect.

In-app drag sources (drags originating inside the WebView) are
out of scope — those continue to flow through standard HTML5
drag-drop events on the JS side.

### Win balloon notifications

Replaces the `error.Unsupported` Win branch in
`notifications.show`. Strategy: piggy-back on the existing tray
icon's `NOTIFYICONDATAW` via `Shell_NotifyIconW(NIM_MODIFY,
NIF_INFO)`. Renders as a Win10/11 balloon tip (older shell) or
Action Center entry (modern shell).

- New `pub fn tray.showWindowsBalloon(title, body)` reaches the
  active `g_windows_tray` singleton, fills `szInfoTitle` (UTF-16,
  cap 64 chars) + `szInfo` (UTF-16, cap 256 chars) + `dwInfoFlags
  = NIIF_INFO`, and ships via `NIM_MODIFY`.
- `notifications.show` on Windows delegates to it. Errors map 1:1
  between the tray + notifications `Error` domains.
- **Hard requirement**: `desktop.tray.init` must have run before
  `notifications.show` on Windows — without an active tray, the
  call returns `error.Backend`. macOS + Linux remain
  tray-independent.

Modern WinRT Toast (`Windows.UI.Notifications.ToastNotificationManager`)
**shipped** (`windows.showToast`): RoInitialize + AUMID via
`SetCurrentProcessExplicitAppUserModelID` + a lazily-created Start-menu
`.lnk` carrying `System.AppUserModel.ID` (IShellLink + IPropertyStore +
IPersistFile) + an `XmlDocument` `ToastGeneric` template → notifier
`Show`. `notifications.show` prefers it and falls back to the balloon
when WinRT init fails. Links `combase`. Pure `buildToastXml`/`xmlEscape`
unit-tested; live banner + Action Center delivery is host-gated (🔒).

### Verification across all four bundles

- Framework `zig build` + `zig build test` PASS each commit.
- 3-backend cross-compile (`aarch64-macos`, `x86_64-linux-gnu`,
  `x86_64-windows-gnu`) clean each commit.
- macOS scaffold boot: window + AEH install + cold-launch URL
  routing all live (`info: [url-open] verve://app/test-cold-launch`).
- macOS `-Durl-scheme=verve` bundle step writes
  `CFBundleURLTypes` into `Info.plist`.
- Second-instance with `--url`: detects `AlreadyRunning`, attempts
  forward, gracefully exits.

Live Win/Linux validation deferred — no hosts. Same convention as
cookies / clipboard / color-scheme / menus on those backends.

### New runtime deps

- **Linux** picks up two new shared libraries:
  - `libayatana-appindicator3` (tray icon)
  - `libnotify` (notifications)
  Both are present by default on Ubuntu / Fedora / Debian / Arch
  GNOME + KDE installs. Distros without them get a link-time
  failure when the scaffold app is built. Apps that don't call the
  new modules still link them today — moving externs behind weak
  symbols / `dlopen` is a future polish.

### Remaining P3 follow-ups after this session

- GTK4 + WebKitGTK 6.0 backend behind `-Dgtk4`
- Drag-drop with native paths, print API
- Hicolor / Linux app-icon theme installation
- Win Toast notifications (`Windows.UI.Notifications.ToastNotificationManager`)
- Accessibility (NSAccessibility / UIA / ATK)
- Auto-updater (Sparkle / Squirrel / AppImage update)

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
- Print page-range / printer-selection — native dialog path
  shipped 2026-05-27 (`NSPrintOperation` /
  `ICoreWebView2_16::ShowPrintUI` /
  `webkit_print_operation_run_dialog`). Programmatic per-platform
  settings (NSPrintInfo dict / `ICoreWebView2PrintSettings` /
  `GtkPrintSettings`) remain future polish.
- Win Toast (WinRT) notifications — balloon path shipped 2026-05-26;
  Toast remains future polish for richer styling + Action Center
  grouping.
- Accessibility — `setAccessibilityLabel` shipped 2026-05-26;
  richer NSAccessibility / UIA provider / full ATK roles + states
  remain future polish. Web content + default menu items already
  publish their own labels through the WebView engines + native
  menu APIs.
- Auto-updater apply phase — `desktop.updates.checkForUpdate`
  shipped 2026-05-26; macOS `applyUpdate` shipped 2026-05-29 (pure
  stdlib: SHA-256 verify + `/usr/bin/tar` extract + same-volume
  rename swap + `open -n` relaunch; requires running inside an
  `.app` bundle, returns `error.NotBundled` for bare binaries).
  **Windows `applyUpdate` shipped** (pure stdlib: SHA-256 verify +
  `tar.exe` extract to `%TEMP%` + a detached `swap.cmd` that waits for
  the PID, robocopy-/MOVEs the new tree over the locked install dir,
  relaunches, and self-deletes — `applyUpdateWindows` / `buildSwapScript`,
  the latter unit-tested; `error.NotBundled` in the `\zig-out\` dev
  layout). This is unsigned side-by-side replacement, not Squirrel/MSIX.
  Linux apply remains platform-updater territory (AppImageUpdate).

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

### Out of P1 scope — shipped 2026-05-27

- Native print APIs — closes the deferred `Window.print()` polish on
  all three backends. New `desktop.PrintOptions { kind: PrintDialogKind }`
  + `PrintError = error{ Unsupported, Backend, Cancelled, OutOfMemory }`
  in `options.zig`. `Window.printWithOptions(opts) PrintError!void` on
  the public surface; legacy `Window.print() void` becomes a thin
  wrapper (`printWithOptions(.{}) catch {}`) so existing callers
  compile unchanged.
  - macOS: `[NSPrintInfo sharedPrintInfo]` +
    `[WKWebView printOperationWithPrintInfo:]` +
    `[NSPrintOperation runOperation]`. `opts.kind` ignored —
    NSPrintOperation always shows the system dialog. Cancel returns
    `error.Cancelled`; nil op returns `error.Backend`.
  - Windows: `ICoreWebView2_16::ShowPrintUI`. QI from base `Wv2` to
    new `Wv2_16` interface via fresh `IID_ICoreWebView2_16` GUID;
    `releaseRef` on the temporary after the call. `opts.kind`
    `default` / `browser` → `COREWEBVIEW2_PRINT_DIALOG_KIND_BROWSER`,
    `system` → `..._SYSTEM`. Edge WebView2 runtimes older than
    version 111 (March 2023) answer `E_NOINTERFACE` to the QI and
    surface `error.Unsupported`. New `SLOT_WV2_16_ShowPrintUI = 104`
    is hand-extracted from `WebView2.h`; logs `hr` on both QI and
    ShowPrintUI to disambiguate wrong-IID vs wrong-slot during the
    first live Windows boot (same convention as
    `SLOT_WV2_2_get_CookieManager`).
  - Linux: `webkit_print_operation_new` +
    `webkit_print_operation_run_dialog(op, parent)` + `g_object_unref`.
    `opts.kind` ignored — WebKitGTK has one dialog path.
    `WEBKIT_PRINT_OPERATION_RESPONSE_CANCEL` returns
    `error.Cancelled`.
  - `window.zig` conformance `required` array gained
    `"printWithOptions"` between `"print"` and `"setAccessibilityLabel"`.
  - Template demo: new `print_page` IPC route in `handlers.zig` maps
    `default` / `browser` / `system` strings to the enum + maps
    `Cancelled` / `Unsupported` / else to `{ ok: bool, status:
    string }` reply. New "Print" feature card in `components.zig`
    with default + system buttons. Smoke golden checksum bumped
    605 → 857.
  - macOS validated live (system print sheet opens, Cancel returns
    expected reply); Win/Linux compile-clean cross-compile (live
    validation deferred per project convention).

- `--template minimal` scaffold variant —
  `verve-cli new <dir> --desktop --template minimal` emits a
  single-window app with one IPC route (`greet` → `Hello, <name>!`)
  and a static HTML page. Intended as a clean starting point.
  `templates/desktop-minimal/` carries a stripped `build.zig` (no
  SSR / WASM / dev / smoke / bundle steps), simple `main.zig`,
  responsive `style.css` (clamp + max-width 28rem + dark-mode),
  and the `tools/fetch_webview2.*` scripts (Win build prereq).
  `verve-cli` gained `DesktopTemplate { full, minimal }` + the
  `--template <name>` flag; `--template` with `--web` warns. Plumbed
  via new `buildCliSkeletonDesktopMinimal()` in root `build.zig`
  mirroring the existing full version.

- Demo scaffold beefed up — `templates/desktop/` grew six new IPC
  routes + matching feature cards (`fetch_url` via
  `std.http.Client`, `system_info`, `disk_space`, `open_file`,
  `window_action`, `deep_link_test`) and a responsive CSS rewrite
  (CSS grid `repeat(auto-fit, minmax(320px, 1fr))`, fluid
  `clamp()` typography + padding, mobile breakpoint at 600px,
  themed `.result-panel` + `dl.kv` markup, log card spans full
  row). `RouterCtx` gained `environ: std.process.Environ`
  threaded from `init.minimal.environ` so the system + paths
  handlers can read XDG / HOME / LANG. Smoke golden checksum
  bumped 605 → 1474 → 1789 across the print + demo + deep-link
  Test button additions.

- Pre-existing framework bugs caught + fixed (latent before the
  demo scaffold exercised these paths live):
  - `desktop.disk` integer overflow on macOS — `StatvfsPosix`
    extern struct used `c_ulong` for `f_blocks` / `f_bfree` /
    `f_bavail`, but macOS `fsblkcnt_t` is `unsigned int` (32-bit);
    `f_blocks` read picked up the high half of `f_bfree` as
    garbage, multiplying by `f_frsize` panicked. Fix: alias
    `fsblkcnt_t = if (macos) c_uint else c_ulong`.
  - `desktop.system` `uptimeMacos` called `std.time.timestamp()`
    which doesn't exist in Zig 0.16. Replaced with libc
    `time(null)` extern. `localeMacos` + `osVersionMacos`
    returned `error.Backend` not in the declared `Error` set;
    swapped to `error.Unsupported`.

### Out of P1 scope — shipped 2026-05-30 (Bundle 8 — print extras Linux full / Win advisory)

Eighth and final entry in the Win/Linux backfill plan.

- **Linux** (`linux.zig` `printWithOptions`):
  - `gtk_print_settings_new` returns a fresh GtkPrintSettings.
  - `gtk_print_settings_set_n_copies(settings, opts.copies)` —
    when copies > 1.
  - When `opts.pages` is set: translate the 1-indexed `PageRange`
    to GTK's 0-indexed `GtkPageRange { start, end }`. The
    `to == 0` "all remaining" sentinel becomes `maxInt(c_int)` —
    we don't have the page count at this layer to expand it.
    Set `gtk_print_settings_set_print_pages(settings,
    GTK_PRINT_PAGES_RANGES = 2)` so the dialog respects the
    range instead of defaulting to "print all".
  - `gtk_print_settings_set_printer(settings, name_z)` —
    pre-selects the printer by user-visible name.
  - `webkit_print_operation_set_print_settings(op, settings)`
    before `webkit_print_operation_run_dialog`. Settings
    pre-fill the dialog; user can override before clicking
    Print.
- **Windows** (`windows.zig` `printWithOptions`):
  - `ShowPrintUI(kind)` doesn't accept a PrintSettings struct.
    The framework logs a warning when caller sets `copies > 1`
    / `pages != null` / `printer_name != null` so the behavior
    gap is visible. Otherwise proceeds with the existing
    ShowPrintUI call.
  - Full silent-print integration via
    `ICoreWebView2_16::Print(printSettings, completionHandler)`
    + `ICoreWebView2Environment6::CreatePrintSettings` + a
    `ICoreWebView2PrintCompletedHandler` COM impostor is a
    future bundle. Defer until a Windows host can verify the
    vtable slot indexes against actual SDK headers — every Win
    slot in the framework today is hand-extracted and
    unvalidated live.
- **PrintOptions docstring** (`options.zig`) updated to spell
  out the per-platform contract: macOS + Linux honor every
  field; Windows extras are advisory.

New Linux externs in `linux.zig`: `webkit_print_operation_set_print_settings`,
`gtk_print_settings_new`, `gtk_print_settings_set_n_copies`,
`gtk_print_settings_set_page_ranges`,
`gtk_print_settings_set_print_pages`,
`gtk_print_settings_set_printer`. All gtk+-3.0 / webkit2gtk-4.1
symbols — already in the link line.

Verified: framework `zig build test` (205 pass); 3-backend
cross-compile clean for `windows.zig` + `linux.zig`;
fresh-scaffold `zig build smoke` PASS (checksum 1789 unchanged).

### Out of P1 scope — shipped 2026-05-30 (Bundles 6 + 7 — global hotkeys Win + Linux)

Bundles 6 + 7 closed together in a single commit (same module +
finish-the-feature shape). Manager is now real on all three
backends.

- `Manager` gained `windows_impl` + `linux_impl` slots alongside
  `macos_impl`; init switches on `builtin.os.tag`.
- **Windows** (`WindowsManager`):
  - Registers a private window class (`VerveHotkeyMessageWnd`)
    on first manager init and creates a `HWND_MESSAGE` parent
    window. Message-only windows live off-screen and are
    excluded from the foreground stack but still receive
    `WM_HOTKEY` posted by the system, which the custom wndProc
    dispatches to `g_win_singleton.cb`.
  - `RegisterHotKey(msg_hwnd, id, MOD_NOREPEAT | mods, vk)`.
    Modifier mapping: cmd→MOD_WIN, ctrl→MOD_CONTROL,
    option→MOD_ALT, shift→MOD_SHIFT. `MOD_NOREPEAT` suppresses
    auto-fire on a held key.
  - Self-contained — no changes to `windows.zig`. The existing
    main message loop's GetMessage/DispatchMessage flow already
    routes messages to the right wndProc by HWND.
- **Linux** (`LinuxManager`):
  - libX11 loaded at runtime via `std.c.dlopen("libX11.so.6")`
    + memoized fn-pointer struct (`LibX11`). Falls back to
    unversioned `libX11.so`; returns null on miss. Detects
    Wayland via `XDG_SESSION_TYPE=wayland` and returns null
    upfront — XGrabKey on the XWayland root only fires when an
    X11 client has focus, which breaks the "global" promise.
    Apps on Wayland get `error.Unsupported` from init.
  - `XOpenDisplay(null)` → `XDefaultRootWindow` → `XKeysymToKeycode`
    → `XGrabKey` × 4 (one per (NumLock × CapsLock) toggle combo)
    so the binding fires regardless of toggle state. Modifier
    mapping: cmd→Mod4Mask (Super), ctrl→ControlMask,
    option→Mod1Mask (Alt), shift→ShiftMask. Public `keycode`
    parameter is interpreted as an X11 keysym (XK_*) on this
    backend — caller looks up the right value per OS.
  - `XSetErrorHandler` installs a no-op handler globally so a
    BadAccess from grabbing a combo another client already owns
    doesn't abort the process (default Xlib handler calls
    exit()). Standard idiom for hotkey libraries that coexist
    with other X11 code.
  - Dedicated `std.Thread.spawn` worker runs `XNextEvent` and
    dispatches matching KeyPress events to the callback **from
    the worker thread**. Matches the Win fswatch threading
    convention; apps that need main-thread delivery marshal
    themselves. Shutdown: `stop_flag` atomic + ungrab every
    binding + `XCloseDisplay` (unblocks XNextEvent) + join.

Verified: framework `zig build test` (205 pass); 3-backend
cross-compile clean for `hotkeys.zig`; fresh-scaffold
`zig build smoke` PASS (checksum 1789 unchanged).

### Out of P1 scope — shipped 2026-05-30 (Bundle 5 — Linux file-watch)

Fifth entry in the Win/Linux backfill plan. Closes the Linux half
of `desktop.fswatch`. Now the module is complete on all three
backends.

- `Watcher` gained a third per-platform slot (`linux_impl`); init
  switch now covers macos / windows / linux.
- Linux impl (`LinuxWatcher`):
  - `inotify_init1(IN_NONBLOCK | IN_CLOEXEC)` — non-blocking so
    the trampoline can drain in a loop without parking.
  - `inotify_add_watch(fd, path, IN_MASK_ALL)` — single inode.
    v1 is non-recursive; callers needing subtree coverage walk
    + add their own watches. Mask covers MODIFY + ATTRIB +
    MOVED_FROM/TO + CREATE + DELETE.
  - `g_io_channel_unix_new(fd)` + `g_io_add_watch(G_IO_IN,
    trampoline, self)` so events dispatch on the GTK main loop.
    Callback fires on the **main thread**, matching macOS
    FSEvents. (Win remains the only worker-thread backend.)
  - Trampoline drains the kernel buffer in a `read()` loop until
    EAGAIN — one g_io_add_watch dispatch can correspond to many
    queued events. Parses fixed 16-byte `inotify_event` header
    + NUL-padded name. Composes `<watch_root>/<name>` UTF-8;
    name-less events (operations on the watched inode itself,
    `len=0`) emit the bare watch root.
  - Shutdown: `g_source_remove(watch_tag)` first (prevents
    re-entry), `inotify_rm_watch(fd, wd)`, `g_io_channel_unref`
    (close_on_unref=1 closes the fd transitively).
- Glib externs (`g_io_channel_unix_new` / `g_io_add_watch` /
  `g_io_channel_unref` / `g_source_remove`) duplicated in
  `fswatch.zig` — same shapes as `linux.zig`'s deep-link
  implementation. The linker dedupes by name; no extra link line.

Verified: framework `zig build test` (205 pass); 3-backend
cross-compile clean for `fswatch.zig`; fresh-scaffold
`zig build smoke` PASS (checksum 1789 unchanged).

### Out of P1 scope — shipped 2026-05-30 (Bundle 4 — Win file-watch)

Fourth entry in the Win/Linux backfill plan. Closes the Win half
of the macOS-only `desktop.fswatch` from 2026-05-28. Linux half
remains pending (Bundle 5).

- `Watcher` struct gained per-platform `macos_impl` /
  `windows_impl` slots; `init` switches on `builtin.os.tag` and
  populates the right one. `deinit` cleans up whichever was set.
- Windows impl (`WindowsWatcher`):
  - Opens the directory with `CreateFileW` +
    `FILE_LIST_DIRECTORY | GENERIC_READ` + share-everything +
    `FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED`. Backup
    semantics is what lets you open a directory as a handle.
  - Allocates a 16 KiB u32-aligned buffer for
    `FILE_NOTIFY_INFORMATION` entries (enough for ~150-500
    coalesced events per read; larger reduces the chance of
    kernel-side buffer overflow on bursty FS activity).
  - Creates a manual-reset event for the OVERLAPPED structure.
  - Spawns a worker thread via `std.Thread.spawn` that loops:
    `ReadDirectoryChangesW(...)` →
    `GetOverlappedResult(..., bWait=TRUE)` (blocks until
    completion or cancellation) → parse FILE_NOTIFY_INFORMATION
    chain → compose `<watch_root>\<relative_path>` UTF-8 →
    fire callback. Recursive (`bWatchSubtree=TRUE`) to match
    FSEvents shape on macOS. Filter mask covers FILE_NAME +
    DIR_NAME + ATTRIBUTES + SIZE + LAST_WRITE + CREATION.
  - Shutdown: set `stop_flag` atomic + `CancelIoEx(dir, null)`
    so the blocking `GetOverlappedResult` returns; worker
    sees the flag and exits; `Thread.join` from `deinit`;
    handles + buffer freed.
  - **v1 callback threading**: fires from the worker thread,
    not the UI thread. macOS FSEvents schedules onto the main
    run loop; Win has no equivalent built-in. Apps that need
    main-thread delivery should marshal across themselves
    (PostMessage to the window + drain from wndProc, or a
    thread-safe queue drained from the GTK/Cocoa main loop).
    Documented in the module header.

Externs added to `fswatch.zig`: `CreateFileW`, `CreateEventW`,
`ReadDirectoryChangesW`, `GetOverlappedResult`, `CancelIoEx`,
`CloseHandle` — all kernel32, auto-linked via `extern "kernel32"`.

Verified: framework `zig build test` (205 pass); 3-backend
cross-compile clean for `fswatch.zig`; fresh-scaffold
`zig build smoke` PASS (checksum 1789 unchanged).

### Out of P1 scope — shipped 2026-05-30 (Bundle 3 — clipboard HTML Win + Linux)

Third entry in the Win/Linux backfill plan. Closes the macOS-only
`Clipboard.writeHtml` / `readHtml` from 2026-05-28.

- **Windows** — CF_HTML format ID assigned dynamically via
  `RegisterClipboardFormatW(L"HTML Format")` (cached by user32;
  repeated calls cheap). `writeHtml` builds the Microsoft-spec
  payload directly: header with `Version:0.9` + four 10-digit
  zero-padded offsets (StartHTML / EndHTML / StartFragment /
  EndFragment), then `<html>\r\n<body>\r\n<!--StartFragment-->`,
  the user's fragment, then `<!--EndFragment-->\r\n</body>\r\n</html>`.
  Offsets are byte counts from the start of the buffer.
  `readHtml` parses StartFragment/EndFragment out of whatever
  producer wrote the data (Chrome / Word / Edge all agree on the
  header layout; only the fragment shape varies) and returns
  just the fragment bytes — caller doesn't see the wrapper.
- **Linux** — GtkClipboard offers a `text/html` MIME target via
  `gtk_clipboard_set_with_data` + a `GtkTargetEntry` advertising
  the target + a get_func callback that copies bytes into a
  `GtkSelectionData` when something pastes. `writeHtml` caches
  the most-recent payload in a process-global `g_clip_html` /
  `g_clip_html_allocator` pair (single-window assumption matches
  the rest of the framework — tray / notifications / single-
  instance scope). `clipHtmlClear` callback runs when ownership
  transfers to another app, freeing the cache. `readHtml` is
  synchronous via `gtk_clipboard_wait_for_contents` +
  `gtk_selection_data_get_data` (X11 / Wayland round-trip
  blocks; no nested GMainContext pump needed).
- New externs in `src/desktop/linux.zig`: `GtkTargetEntry`,
  `gtk_clipboard_set_with_data`, `gtk_clipboard_wait_for_contents`,
  `gtk_selection_data_set/_get_data/_get_length/_free`. All resolve
  through gtk+-3.0 + libgtk-3 — already in the link line.
- New extern in `src/desktop/windows.zig`:
  `RegisterClipboardFormatW` from user32 (auto-linked).
- Image clipboard (PNG): **macOS done (2026-06-01)** —
  `Clipboard.writeImage(png)` / `readImage(alloc)` via `NSData` +
  `setData:forType:` / `dataForType:` with the `public.png` UTI
  (verified by a host round-trip: write a 1×1 PNG → read back
  identical; the system pasteboard reports `«class PNGf»`). The API
  format is raw PNG bytes. **Windows ships** (`CF_DIBV5`): WIC transcodes
  the PNG to a 32bpp-BGRA DIB on write and re-encodes `CF_DIBV5`/`CF_DIB`
  back to PNG on read (`Windowscodecs`; pure `buildDibV5`/`dibToBgra`
  helpers unit-tested, COM path host-gated). **Linux (`image/png`
  GtkClipboard target) still pending** — returns `error.Unsupported`.
  (TIFF on macOS is a possible later add; PNG pastes into modern apps.)

Verified: framework `zig build test` (205 pass); 3-backend
cross-compile clean for `windows.zig` + `linux.zig`;
fresh-scaffold `zig build smoke` PASS (checksum 1789 unchanged).

### Out of P1 scope — shipped 2026-05-30 (Bundle 2 — registerScheme Win + Linux)

Second entry in the Win/Linux backfill plan. Closes the macOS-only
stub from 2026-05-28's `desktop.deep_link.registerScheme`.

- **Signature change**: `registerScheme(scheme, bundle_id)` →
  `registerScheme(allocator, scheme, bundle_id)`. macOS impl
  ignores the allocator; Win + Linux need it for string
  composition. No external callers beyond the README example.
- **Windows** — Writes the `HKCU\Software\Classes\<scheme>`
  registry tree:
  - `(Default) = "URL:<bundle_id>"` — the per-spec display label.
  - `URL Protocol = ""` — the marker Windows uses to identify
    a key as a URL-protocol handler.
  - `<scheme>\shell\open\command (Default) = "<exe>" "%1"` — the
    actual handler invocation. `<exe>` resolved at runtime via
    `GetModuleFileNameW(null, ...)`. UTF-16 composed directly to
    skip a round-trip.
  - Uses `RegCreateKeyExW` (auto-create-or-open) so the call is
    idempotent. advapi32 + kernel32 auto-linked via the existing
    `extern "<lib>"` pattern; no template build.zig changes.
- **Linux** — Writes
  `~/.local/share/applications/<bundle_id>.desktop` with
  `[Desktop Entry] Type=Application Name=<bundle_id>
  Exec="<exe>" %u NoDisplay=true MimeType=x-scheme-handler/<scheme>;
  StartupWMClass=<bundle_id>`. `$HOME` from `getenv`; exe path
  from `readlink("/proc/self/exe", ...)`. Parent dirs created
  via a posix `mkdir -p` walk (EEXIST tolerated). Atomic file
  write via raw `open/write/close` so the .desktop appears whole
  or not at all (no half-written entries on disk).
- **`xdg-mime default` not invoked** — that would force an
  `io: std.Io` parameter for a best-effort side-effect. Callers
  who need explicit default-handler activation run
  `xdg-mime default <bundle_id>.desktop x-scheme-handler/<scheme>`
  themselves after the call returns. The .desktop file alone is
  enough for nautilus/dolphin/etc. to register the app as *a*
  handler on next desktop-database refresh.

Verified: framework `zig build` + `zig build test`; 3-backend
cross-compile clean for `deep_link.zig`; fresh-scaffold
`zig build smoke` PASS (checksum 1789 unchanged).

### Out of P1 scope — shipped 2026-05-30 (Bundle 1 — Linux dlopen)

First entry in the Win/Linux backfill plan (post-v0.1.9). Closes
the "libayatana + libnotify linked unconditionally" sharp edge
that blocked distros without those libs from building any Verve
desktop scaffold — including scaffolds that never call `Tray.init`
or `notifications.show`.

- `src/desktop/tray.zig` Linux backend — six `app_indicator_*`
  externs replaced by a `LibAyatana` fn-pointer struct loaded via
  `std.c.dlopen` + `dlsym` on first call. Lazy + memoized — single
  `dlopen` attempt per process lifetime, cached null result on
  failure. Tries `libayatana-appindicator3.so.1` first (modern
  soname), falls back to unversioned `libayatana-appindicator3.so`.
  Returns `error.Unsupported` when neither resolves. All call
  sites (bareInit / setTooltip / setIcon / setMenu) thread through
  the loader; bareInit fails fast with `Unsupported`, downstream
  setters skip silently.
- `src/desktop/notifications.zig` Linux backend — same shape with
  four `notify_*` externs (`init` / `is_initted` /
  `notification_new` / `notification_show`) behind a `LibNotify`
  fn-pointer struct + `loadLibnotify` loader. Tries
  `libnotify.so.4` then `libnotify.so`.
- `g_object_unref` (glib, linked transitively via gtk+-3.0) stays
  as a direct extern — already in the link line, not part of the
  optional surface.
- Module headers updated to document the runtime-load contract +
  the `error.Unsupported` failure mode.

Verified: framework `zig build` + `zig build test` (205 pass);
3-backend cross-compile clean for both modules; fresh-scaffold
`zig build smoke` PASS (checksum 1789 unchanged — Bundle 1 is
behavior-preserving for distros that already have the libs).

### Out of P1 scope — shipped 2026-05-29 (macOS updater + signing)

Closes the last two macOS-touching roadmap items for self-built
apps. Pure-stdlib apply phase + opt-in hardened-runtime signing
path. Notarization remains a documented manual sequence.

- `desktop.updates.applyUpdate(allocator, io, info)` — macOS-only
  apply phase. Algorithm: locate enclosing `.app` via
  `_NSGetExecutablePath` walking up to the first `.app` ancestor;
  download `info.download_url` into memory; SHA-256 over the bytes
  and compare to `info.sha256` (case-insensitive lowercase hex);
  stage `.{name}.app.verve-update/` next to the target so the
  rename stays on a single volume; extract via `/usr/bin/tar -xzf`;
  two-step rename swap (current → `.old`, new → current, restore
  on failure); `open -n <bundle>` then `std.process.exit(0)`.
  Win + Linux return `error.Unsupported`. Bare-binary callers
  (running `./zig-out/bin/app`) get `error.NotBundled`. New
  `ApplyError` set: `Unsupported, Network, BadChecksum, NotBundled,
  ExtractFailed, SwapFailed, RelaunchFailed, MissingChecksum,
  OutOfMemory`.
- `UpdateInfo.sha256` — new required field on the feed schema.
  `checkForUpdate` tolerates absence (defaults to ""); `applyUpdate`
  returns `MissingChecksum` when the digest isn't 64 hex chars.
- `-Dhardened=true` build option — opt-in hardened runtime +
  entitlements path on `templates/desktop/build.zig`. Generates a
  scaffold-local `.entitlements` plist with the three keys WKWebView
  needs (allow-jit, allow-unsigned-executable-memory,
  disable-library-validation) and threads
  `--options=runtime --entitlements <generated>` into the existing
  codesign step. Default (`hardened=false`) is byte-for-byte
  identical to today's signing path.
- Template README — new "Auto-update" + "Distributing to other
  Macs" sections. Distribution sequence (Developer ID cert →
  hardened build → notarytool submit → stapler staple) documented
  as manual commands; framework deliberately does not automate
  notarization because credential handling belongs in CI, not in
  `build.zig`.

macOS is now feature-complete for self-built personal-use apps.
All P3 roadmap items that remain are either Windows/Linux backfill
or entitlement-gated polish (WinRT Toast, GTK4, full a11y,
UNUserNotificationCenter migration, Win/Linux update apply via
platform updaters).

### Out of P1 scope — shipped 2026-05-28 (macOS sweep)

Eleven items closing every macOS-only gap from the post-v0.1.6
"Open P3" + "Uncovered gaps" tables. Cross-platform stubs
(`error.Unsupported`) on Win + Linux per project convention.

- `desktop.power` macOS battery — IOKit `IOPSCopyPowerSourcesInfo`
  + `IOPSCopyPowerSourcesList`; reads `kIOPSCurrentCapacityKey` /
  `kIOPSMaxCapacityKey` / `kIOPSIsChargingKey`. CFString keys
  built at runtime via `CFStringCreateWithCString` (the IOKit
  header `#define`s the keys as C string literals, not extern
  CFStrings). Closes the only known per-platform null in
  `desktop.power`.
- `desktop.network` (new module) — `isOnline() bool`. macOS:
  `SCNetworkReachabilityCreateWithName("apple.com")` +
  `SCNetworkReachabilityGetFlags`. Windows:
  `InternetGetConnectedState` from wininet. Linux: `getifaddrs`
  + scan for non-loopback iface with `IFF_UP | IFF_RUNNING`.
- `desktop.fswatch` (new module, macOS only) — `Watcher.init`
  with `FSEventStreamCreate` (file-events flag, 1s coalescing)
  scheduled on the main run loop. C trampoline fires the Zig
  callback per changed path. Win + Linux return
  `error.Unsupported`.
- `desktop.hotkeys` (new module, macOS only) — global hotkey
  `Manager` via Carbon `RegisterEventHotKey` +
  `InstallEventHandler` on `GetApplicationEventTarget`.
  `Modifiers { cmd, ctrl, option, shift }` packed struct +
  `register(id, mods, keycode)` + `unregister(id)`. Single-
  manager-per-process v1 (`g_singleton` routes the trampoline).
- `desktop.process` (new module) — `runCapture` + `spawnDetached`
  wrappers over `std.process.Child` with desktop-friendly
  defaults. Cross-platform stdlib reshape.
- `desktop.deep_link.registerScheme(scheme, bundle_id)` — runtime
  URL-scheme registration via LaunchServices
  `LSSetDefaultHandlerForURLScheme`. Requires a bundled `.app`
  with `CFBundleURLTypes` already declaring the scheme. Win +
  Linux stubs (HKCU registry + xdg-mime are follow-ups).
- `Clipboard.writeHtml` / `readHtml` — macOS
  `NSPasteboardTypeHTML` (`public.html`). Win + Linux stubs
  (`CF_HTML` header format + GtkClipboard `text/html` target are
  follow-ups).
- `TrayOptions.icon_symbol` — macOS-only SF Symbol fallback
  for the tray icon (uses `+[NSImage
  imageWithSystemSymbolName:accessibilityDescription:]`, macOS
  11+). Demo uses `"bolt.fill"`. Lets demos ship a real icon
  without bundling a PNG.
- `PrintOptions` extended — new `copies` / `pages: ?PageRange` /
  `printer_name` fields. macOS patches NSPrintInfo via dict keys
  (`NSCopies` / `NSFirstPage` / `NSLastPage` /
  `NSPrintAllPages = false` / `[NSPrinter printerWithName:]` →
  `setPrinter:`). NSPrintInfo is copied off the shared singleton
  before mutation so settings don't bleed into later operations.
  Win + Linux ignore the extras for now.
- `pumpUntilDone` re-entrancy hazard documented at
  `src/desktop/macos.zig`. Safe from IPC handlers (default mode);
  unsafe inside another modal run loop.
- macOS `LSMinimumSystemVersion` bumped 10.15 → 11.0 in
  `templates/desktop/build.zig` to cover the 11+ selectors
  shipped this cycle (NSPrintOperation, snapshot, IOKit / SF
  Symbols / LaunchServices added now).

Framework linkage on macOS now includes IOKit, CoreFoundation,
SystemConfiguration, CoreServices, Carbon (templates +
host-target test artifact in root `build.zig`).

### Out of P1 scope — shipped 2026-05-26

- Tray click handlers + submenus — `TrayMenuItem { label, id,
  enabled, children }` + `TrayOptions.menu` + `on_click` +
  `on_menu_item` on all three backends. `Tray.impl` is now heap-
  allocated so callback singletons see a stable address after the
  by-value `init` return. macOS dispatches via a process-wide
  `VerveTrayTarget` NSObject with `verveTrayItem:` /
  `verveTrayClick:` selectors and per-item `setTag:`. Windows
  registers `NOTIFYICONDATAW.uCallbackMessage = WM_VERVE_TRAY`
  (= `WM_USER + 100`, declared pub in `windows.zig`); wndProc
  forwards via `tray_dispatch_message` (mouse events) +
  `tray_dispatch_command` (`WM_COMMAND` in the `0xC000` ID
  block). Right-click / WM_CONTEXTMENU shows the menu via
  `TrackPopupMenu` with the MSDN-required `SetForegroundWindow` +
  `PostMessage(WM_NULL)` dance. Linux builds a GtkMenu via
  `gtk_menu_item_new_with_label` + `gtk_menu_shell_append`;
  submenus via `gtk_menu_item_set_submenu`; per-item
  `g_signal_connect_data("activate")` trampoline with an
  allocator-owned `ItemBox { *LinuxTray, id }` as user_data.
  Single-tray-per-process v1 assumption documented (singletons
  unguarded). macOS validated live; Win/Linux compile-clean
  cross-compile (live validation deferred). Template demo
  ships a 4-item tray menu (Show window / Notify / Quit) routed
  through `handlers.onTrayItem`.

## Remaining work + gaps (post-v0.1.6)

All P1 + every P2 platform port closed. Core desktop framework
essentially done — what's left below is polish for niche
features, large refactors (GTK4), or fixes for known sharp
edges in shipped code.

### Open P3 — polish for existing features

macOS sweep on 2026-05-28 closed every macOS-only entry below.
Remaining items are Linux- or Windows-only or need entitlement /
signing infra.

| Bundle | What | Status / scope |
|---|---|---|
| **GTK4 backend** | Parallel GTK4 + WebKitGTK 6.0 module behind `-Dgtk4`; existing GTK3 path stays | Largest remaining item (~5h). New backend module. Future-proofs Linux once Ubuntu LTS / Fedora ship GTK4 webkit by default. |
| **Print page-range / printer-selection (Win + Linux)** | **Linux closed 2026-05-30 (Bundle 8).** macOS landed 2026-05-28 via NSPrintInfo dict; Linux now honors `copies` / `pages` / `printer_name` via `GtkPrintSettings` attached to the operation before the dialog opens. Win remains **advisory** — `ShowPrintUI` doesn't accept a settings struct; the user picks values in the dialog. Full silent-print via `ICoreWebView2_16::Print` + `ICoreWebView2PrintSettings` + a completion-handler COM impostor is a future bundle (needs Windows host for vtable slot validation). | Win full path future |
| **WinRT Toast** | `Windows.UI.Notifications.ToastNotificationManager` via COM + AUMID + Start-menu shortcut | Polish vs current `Shell_NotifyIconW(NIF_INFO)` balloon. Richer styling + Action Center grouping. ~4h, needs Windows host. |
| **Full a11y provider** | NSAccessibility / UIA / ATK roles + states beyond labels | Polish vs current `setAccessibilityLabel`. Web content + menus already self-publish; remaining gap is window-chrome semantics. ~3h. |
| **Auto-updater apply (Win + Linux)** | Squirrel or MSIX (Win) / AppImageUpdate (Linux) | macOS apply shipped 2026-05-29 (pure-Zig download + SHA-256 verify + rename swap + `open -n` relaunch). Win + Linux apply still platform-updater territory. ~5h+ + signing infra. |
| **`UNUserNotificationCenter` migration (macOS)** | Current `notifications.show` uses deprecated NSUserNotification. UN center needs entitlements + permission prompt + bundled app. | ~2-3h + entitlement setup. Apple still ships NSUserNotification; not urgent. |

### Uncovered gaps (not in roadmap before)

| Gap | What | Estimated scope |
|---|---|---|
| ~~**Clipboard HTML (Win + Linux)**~~ | **Closed 2026-05-30 (Bundle 3).** Win CF_HTML format with the Microsoft-spec Version / Start/End HTML / Start/End Fragment header offsets. Linux GtkClipboard `text/html` target via `gtk_clipboard_set_with_data` + a get-callback that reads a process-global cached payload. Image clipboard (PNG): macOS done 2026-06-01 (`public.png` via NSData; `Clipboard.writeImage`/`readImage`); `CF_DIB` (Win) + `image/png` GtkClipboard target (Linux) still pending. | — |
| ~~**File-watch (Win + Linux)**~~ | **Closed 2026-05-30 (Bundles 4 + 5).** Win: `ReadDirectoryChangesW` + overlapped IO on a dedicated worker thread + `GetOverlappedResult` pump + `CancelIoEx`-driven shutdown (callback fires from worker thread). Linux: `inotify_init1 + inotify_add_watch` + `GIOChannel` wrap + `g_io_add_watch(G_IO_IN)` so events dispatch on the GTK main loop (callback fires on main thread, matching macOS). v1 Linux is **non-recursive** — single-inode watch only; callers walk subtrees themselves. | — |
| ~~**Global hotkeys (Win + Linux)**~~ | **Closed 2026-05-30 (Bundles 6 + 7).** macOS Carbon `RegisterEventHotKey` shipped 2026-05-28. Win: `RegisterHotKey` against a hidden HWND_MESSAGE message-only window owned by the manager; existing app message loop delivers `WM_HOTKEY` to a small custom wndProc. Linux X11: libX11 loaded via `dlopen("libX11.so.6")` + `XGrabKey` on the root window for all 4 NumLock/CapsLock modifier variants; dedicated worker thread does `XNextEvent`. Wayland deferred (needs GlobalShortcuts xdg portal). | — |
| ~~**Custom URL scheme runtime registration (Win + Linux)**~~ | **Closed 2026-05-30 (Bundle 2).** Win writes `HKCU\Software\Classes\<scheme>` registry tree (default value + `URL Protocol` marker + `shell\open\command`); Linux writes `~/.local/share/applications/<bundle_id>.desktop` with `MimeType=x-scheme-handler/<scheme>`. macOS `LSSetDefaultHandlerForURLScheme` shipped 2026-05-28. | — |

### Known sharp edges in shipped code

| File / area | Issue | Severity |
|---|---|---|
| `templates/desktop/tools/webview2.pinned.txt` | SHA-512 still blank — first CI run needs to populate after verifying the published value | Low (auto-vendor still works; integrity check skipped). |
| Linux backend overall | ~~Never run live on a real Linux host~~ **First-boot validated 2026-06-06 on aarch64 (WebKitGTK 6.0 / libsoup 3, v0.1.41).** Cookies, scheme handler, IPC, tray guard, sandbox all exercised. ~~Drag-drop code fixed 2026-06-07 (signature + WebKit file:// navigation guard).~~ Multi-window / tray menu unverified live. | Substantially addressed; drag-drop correct in code. |
| ~~`src/desktop/windows_native.zig` vtable slot indexes~~ | ~~Hand-extracted from public MS docs (not generated from SDK headers)~~ | ~~Medium.~~ **Closed 2026-06-07 (Bundle 12).** Core path + async cookie manager verified on real Windows 11. |
| `src/desktop/macos.zig` `pumpUntilDone` | Nested `[NSRunLoop runMode:beforeDate:]` re-entrant in modal contexts | Low. Safe from IPC handlers (the dominant call site); risky if a caller is already inside another modal run loop. |
| ~~Linux `libayatana-appindicator3` + `libnotify` linked unconditionally~~ | **Closed 2026-05-30 (Bundle 1).** Both libs now loaded via `std.c.dlopen` + `dlsym` with a memoized fn-pointer struct; missing-lib paths return `error.Unsupported` at runtime. Distros without ayatana / libnotify build cleanly. | — |
| `desktop.tray` single-tray-per-process v1 | `g_macos_tray` + `g_windows_tray` are unguarded singletons | Low. Multi-tray apps would need per-target ivars on macOS + HWND-keyed registry on Windows. No current use case. |
| `notifications.show` on Windows | ~~Requires `desktop.tray.init` first; without an active tray, returns `error.Backend`.~~ WinRT Toast path (Bundle 9, validated 2026-06-07) is now the primary path and does not require a tray. Balloon fallback still requires tray. | Addressed for the primary path. |

### Suggested next-session bundle picks

All three backends (macOS, Windows, Linux GTK4) have been live-validated
on real hardware as of v0.2.0. The remaining open work is:

| Priority | Bundle | What |
|---|---|---|
| High | **Bundle 13 — full a11y** | UIA Win + ATK Linux provider beyond current `setAccessibilityLabel`; cross-compile feasible, live validation is the value |
| High | **Bundle 11 — auto-updater (Win/Linux)** | Win: Squirrel or MSIX; Linux: AppImageUpdate. Needs signing-infra decision first. |
| Medium | **Silent print (Windows)** | `ICoreWebView2_16::Print` + `ICoreWebView2PrintSettings` + COM completion-handler; currently advisory-only |
| Medium | **Linux image clipboard** | `image/png` GtkClipboard target; macOS + Windows ship `writeImage`/`readImage` |
| Low | **`UNUserNotificationCenter` migration (macOS)** | Off deprecated `NSUserNotification`; needs entitlements + bundled app |
| Low | **`webview2.pinned.txt` SHA-512** | Populate after first CI run |

### Win + Linux backfill plan (post-v0.1.9) — completed

All 8 backfill bundles shipped (2026-05-30). GTK4 live-validated
2026-06-06 (Bundle 10). Windows live-validated 2026-06-07 (Bundle 12).
WinRT Toast validated 2026-06-07 (Bundle 9). The table below is a
historical record of what was done and how. Each bundle ships under the existing convention:
cross-compile clean on all three backends + macOS smoke PASS +
single commit + roadmap update.

Ordering rationale: mechanical / format-conversion / filesystem-
write bundles first (lowest implementation novelty → smallest
chance of latent bugs without a live host). Bundles that exercise
event-loop / async / callback plumbing land later, once patterns
from earlier bundles are established.

| # | Bundle | What | Win impl | Linux impl | Risk |
|---|--------|------|----------|------------|------|
| 1 | ~~**Linux libayatana / libnotify dlopen**~~ — **shipped 2026-05-30** | Closed. `std.c.dlopen("libayatana-appindicator3.so.1")` + memoized fn-pointer struct in `tray.zig`; same shape for `libnotify.so.4` in `notifications.zig`. Both fall back to unversioned `.so` filename then return `error.Unsupported` when neither resolves. macOS smoke PASS (1789); 3-backend cross-compile clean | — | done | — |
| 2 | ~~**URL-scheme runtime registration**~~ — **shipped 2026-05-30** | Closed. Win: `HKCU\Software\Classes\<scheme>` tree (default + `URL Protocol` marker + `shell\open\command`) via advapi32 `RegCreateKeyExW` + `RegSetValueExW`. Linux: `~/.local/share/applications/<bundle_id>.desktop` write with `MimeType=x-scheme-handler/<scheme>;` + `NoDisplay=true`. `xdg-mime default` left to caller (avoids forcing an `io: std.Io` param). Signature gained `allocator` (now `(allocator, scheme, bundle_id)`) | done | done | — |
| 3 | ~~**Clipboard HTML**~~ — **shipped 2026-05-30** | Closed. Win: CF_HTML via `RegisterClipboardFormatW("HTML Format")` + zero-padded 10-digit header offsets (StartHTML / EndHTML / StartFragment / EndFragment); read parses the StartFragment/EndFragment offsets to slice out the original fragment. Linux: `gtk_clipboard_set_with_data` with a `text/html` GtkTargetEntry + a get_func reading a process-global cached payload (single-window assumption matches the rest of tray / notifications); read via `gtk_clipboard_wait_for_contents` + `gtk_selection_data_get_data` | done | done | — |
| 4 | ~~**File-watch (Win)**~~ — **shipped 2026-05-30** | Closed. `ReadDirectoryChangesW` against a `FILE_FLAG_BACKUP_SEMANTICS \| FILE_FLAG_OVERLAPPED` directory handle; dedicated worker thread blocks on `GetOverlappedResult(hDir, &ovl, &n, TRUE)`. v1 fires the callback **from the worker thread** (not the UI thread) — docstring instructs apps that need main-thread delivery to marshal. Shutdown via `CancelIoEx(hDir, null)` from `deinit` so the blocking `GetOverlappedResult` returns; stop_flag atomic checked between iterations. 16 KiB buffer carries ~150-500 events per read | done | — | — |
| 5 | ~~**File-watch (Linux)**~~ — **shipped 2026-05-30** | Closed. `inotify_init1(IN_NONBLOCK \| IN_CLOEXEC)` → `inotify_add_watch(IN_MODIFY \| IN_ATTRIB \| IN_MOVED_FROM \| IN_MOVED_TO \| IN_CREATE \| IN_DELETE)` → wrap fd in `g_io_channel_unix_new` + `g_io_add_watch(G_IO_IN, trampoline)`. Trampoline drains the kernel buffer in a loop (one g_io_add_watch dispatch handles many queued events), parses `inotify_event` headers (16-byte fixed + NUL-padded name), composes `<watch_root>/<name>`. v1 non-recursive (single inode). Shutdown via `g_source_remove` + `inotify_rm_watch` + `g_io_channel_unref` (close_on_unref handles fd) | done | done | — |
| 6 | ~~**Global hotkeys (Win)**~~ — **shipped 2026-05-30** | Closed. `RegisterHotKey(hwnd, id, fsModifiers, vk)` against a hidden message-only window (`HWND_MESSAGE` parent) owned by the manager, with a custom wndProc that handles `WM_HOTKEY`. Self-contained — no changes to windows.zig main loop; existing GetMessage/DispatchMessage flow delivers events. Modifier mapping: cmd→MOD_WIN, ctrl→MOD_CONTROL, option→MOD_ALT, shift→MOD_SHIFT. `MOD_NOREPEAT` added to suppress auto-repeat on held keys | done | — | — |
| 7 | ~~**Global hotkeys (Linux X11)**~~ — **shipped 2026-05-30** | Closed. libX11 loaded at runtime via `std.c.dlopen("libX11.so.6")` so apps build cleanly on Wayland-only / headless installs (returns `error.Unsupported` when libX11 absent OR when `XDG_SESSION_TYPE=wayland`). Per binding, `XGrabKey` is called 4× to cover the (NumLock × CapsLock) toggle combos. Dedicated `std.Thread.spawn` worker runs `XNextEvent` and fires the callback from the worker thread; deinit closes the display to unblock the loop. `XSetErrorHandler` swallows BadAccess so other X11 clients holding the same combo don't crash the process | done | done | — |
| 8 | ~~**Print extras (Linux full / Win advisory)**~~ — **shipped 2026-05-30** | Linux: `gtk_print_settings_new` → `_set_n_copies` / `_set_page_ranges` (1-indexed PageRange translated to GTK's 0-indexed GtkPageRange) / `_set_print_pages(RANGES)` / `_set_printer` → `webkit_print_operation_set_print_settings` before `_run_dialog`. Settings pre-fill the dialog; user can override. Win: `ShowPrintUI` doesn't accept settings — extras are advisory + the framework logs a warning when caller sets them. Full silent-print via `ICoreWebView2_16::Print` + `ICoreWebView2PrintSettings` + completion-handler COM impostor deferred (needs Windows host to validate vtable slot indexes) | advisory | done | — |

Bundles **deferred** (host-required or scope-too-large):
- ~~**Bundle 9**~~ — **validated 2026-06-07** — WinRT Action Center toast.
  Live-validated on real Windows 11 (see the 2026-06-07 session entry above):
  `showToast` returns success (the full hand-rolled WinRT/COM vtable-slot chain
  — `RoInitialize` → `XmlDocument.LoadXml` → `ToastNotificationManager`
  `CreateToastNotifierWithId` → `CreateToastNotification` → `IToastNotifier::Show`
  — all succeed) and the AUMID Start-menu `.lnk` is created via the
  IShellLink / IPropertyStore / IPersistFile COM chain. No code change was
  needed; the deferral was purely a live-validation gate, now cleared.
- ~~**Bundle 10**~~ — **shipped 2026-06-06** — GTK4 + WebKitGTK 6.0
  live-validated on aarch64 Linux. libsoup 3 API migration, JSC callback
  update, tray GTK3/GTK4 conflict resolved, cookie async lifetime fix,
  WebKit sandbox programmatic disable. Snapshot returns `error.Unsupported`
  (webkit_web_view_snapshot absent in installed webkitgtk-6.0).
- **Bundle 11** — Win/Linux auto-updater apply. Squirrel or MSIX
  on Win, AppImageUpdate on Linux. Each is a full framework
  integration with its own signing model. Defer until update
  signing infra is picked.
- **Bundle 12** — live validation. Linux complete (2026-06-06, aarch64,
  v0.1.41); **Windows complete 2026-06-07** (v0.1.42 + the 2026-06-07 session).
  Of the three Windows items it tracked: **WebView2 vtable slot verification** —
  done (env/controller/navigation/custom-scheme/`WebMessageReceived`/
  `CapturePreview` exercised by the `--smoke` round-trip, and the async
  `ICoreWebView2CookieManager::GetCookies` nested-pump path verified by a
  set→get cookie roundtrip); **WinRT Toast** — done (Bundle 9 above);
  **silent print** — still open, but that is an *unimplemented feature*
  (Windows print is advisory-only per Bundle 8; full silent print via
  `ICoreWebView2_16::Print` + `ICoreWebView2PrintSettings` remains its own
  future bundle), not a live-validation gap. Net: Windows live validation is
  effectively complete; the only Windows backlog left is the silent-print
  feature itself.
- **Bundle 13** — Full a11y provider (UIA on Win + ATK on
  Linux). Polish vs. shipped `setAccessibilityLabel`. Web content
  + menus already self-publish; remaining gap is window-chrome
  semantics. Cross-compile clean is feasible but live validation
  is the entire value, so this is host-gated too.

Per-bundle session checklist (lifted from 2026-05-22 →
2026-05-29 conventions, applies to every bundle 1-8):

1. New module / impl behind feature flag if breaking, or extend
   existing module if additive (most of these are additive
   per-platform impls of macOS-shipped surfaces).
2. `zig build` + `zig build test` PASS in the framework.
3. 3-backend cross-compile of the touched files
   (`window.zig` + any new module).
4. Fresh-scaffold `zig build smoke` PASS on macOS (golden
   checksum unchanged unless the bundle is additive to the demo
   page — bump golden in same commit when it is).
5. Update `docs/11-desktop-roadmap.md` "Open P3" / "Uncovered
   gaps" tables — strike the closed line.
6. Update `CHANGELOG.md` `[Unreleased]` section.
7. Single commit, message follows `desktop: <bundle name>` shape.

Estimated cumulative effort: bundles 1-3 (~4-6h) close the
quick-wins band; bundles 4-7 (~10-12h) close the medium-novelty
band; bundle 8 (~3h) closes the print polish. After all eight,
non-host-gated Win/Linux work is exhausted — every remaining
roadmap item needs either a live host or a distribution-signing
decision.

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
- ~~The Linux backend has never run live~~ **First-boot validated
  2026-06-06 on aarch64** (GTK4 + WebKitGTK 6.0; cookies, scheme
  handler, IPC, tray guard, sandbox confirmed). Drag-drop code fixed
  2026-06-07 (signature + WebKit file:// navigation guard). Multi-window
  and tray menu not yet live-validated.
- ~~WebView2 vtable slot indexes in `src/desktop/windows_native.zig`
  were hand-extracted and unverified~~ **Verified 2026-06-07 (Bundle 12)**
  on real Windows 11 (v0.1.42): core path + async cookie manager
  confirmed. No further vtable verification needed.
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
- The 2026-05-25 session shipped four P3 bundles (menus, deep-link
  cold-launch + warm-launch, tray + notifications). Same rubric
  applied: each bundle had its own commit + cross-compile + scaffold
  smoke. Tree clean at session end.
- Linux runtime deps for the tray + notifications modules
  (`libayatana-appindicator3` + `libnotify`) are loaded via
  `std.c.dlopen` since Bundle 1 (2026-05-30). Distros without them
  build cleanly; calls to `Tray.init` / `notifications.show` return
  `error.Unsupported` at runtime instead of failing at link time.
- macOS `NSUserNotification` is deprecated by Apple but still works
  without a permission grant. Migrating to
  `UNUserNotificationCenter` requires entitlements + a permission
  prompt + a bundled app (LSUIElement / NSPrincipalClass).
  Deferred.
- Windows tray defaults to the stock `IDI_APPLICATION` icon.
  Custom icons via `Tray.setIcon(path)` / `TrayOptions.icon_path`
  shipped 2026-05-26.
- Tray click handlers + submenus shipped 2026-05-26. v1 assumes a
  single tray per process — multi-tray would need per-target ivars
  on macOS + the Windows registry keyed beyond HWND. No use case
  yet.
