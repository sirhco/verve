# Changelog

All notable changes to Verve are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.3] - 2026-05-26

Seven post-`v0.1.2` polish bundles. Closes the navigation + shell
+ display ergonomics gap.

### Added — Window event callbacks (2026-05-26)

- `WindowOptions.on_resize` / `on_focus` / `on_close` + matching
  `Window.setResizeHandler` / `setFocusHandler` / `setCloseHandler`
  on all 3 backends. `ResizeHandler` fires with new content size;
  `FocusHandler` with focused/blurred state; `CloseHandler` returns
  `true` to allow close, `false` to keep window open (for "Unsaved
  changes?" prompts).
- macOS: `VerveWindowDelegate` NSObject subclass with
  `windowDidResize:` + `windowDidBecomeKey:` + `windowDidResignKey:`
  + `windowShouldClose:`. Windows: `WM_SIZE` + `WM_ACTIVATE` +
  `WM_CLOSE` wndProc cases. Linux: `g_signal_connect_data` on
  `configure-event`, `focus-in-event`, `focus-out-event`,
  `delete-event`.

### Added — Window min/max size (2026-05-26)

- `Window.setMinSize(w, h)` / `setMaxSize(w, h)` on all 3 backends;
  `(0, 0)` clears the bound. macOS: `setContentMinSize:` /
  `setContentMaxSize:`. Windows: new `WM_GETMINMAXINFO` wndProc
  case patches `ptMinTrackSize` / `ptMaxTrackSize`. Linux:
  `gtk_window_set_geometry_hints` with `GDK_HINT_MIN_SIZE` /
  `GDK_HINT_MAX_SIZE` flags.

### Added — Multi-display enumeration (2026-05-26)

- New `desktop.displays` module: `list(allocator) Error![]Display`.
  `Display { x, y, width, height, scale, primary }`. macOS:
  `[NSScreen screens]` + `backingScaleFactor` with Y-flip into
  top-left coords for cross-platform parity. Windows:
  `EnumDisplayMonitors` + `GetMonitorInfoW` + `GetDpiForMonitor`
  (Shcore.dll). Linux: `gdk_display_get_default` +
  `gdk_display_get_n_monitors` / `_get_monitor` / `_get_geometry` /
  `_get_scale_factor`. Scaffold `build.zig` gains `Shcore` link
  on the Windows branch.

### Added — Shell helpers (2026-05-26)

- New `desktop.shell` module: `openUrl(allocator, url) Error!void`.
  Hands a URL to the OS shell so it opens externally (default
  browser for http/https, registered handler for mailto/custom
  schemes). macOS: `[NSWorkspace openURL:]`. Windows:
  `ShellExecuteW(NULL, "open", url, NULL, NULL, SW_SHOWNORMAL)`.
  Linux: `posix.fork` + `execvp("xdg-open", ...)`.

### Added — Navigation helpers (2026-05-26)

- `Window.reload()` / `goBack()` / `goForward()` on all 3 backends.
  macOS: `WKWebView reloadFromOrigin` / `goBack` / `goForward`.
  Windows: vtSlots 31 / 40 / 41 on ICoreWebView2. Linux:
  `webkit_web_view_reload` / `_go_back` / `_go_forward`.

### Added — Navigation queries (2026-05-26)

- `Window.canGoBack()` / `canGoForward()` / `currentUrl(allocator)
  ![]u8` / `currentTitle(allocator) ![]u8` on all 3 backends.
  Pairs with `goBack` / `goForward` for history-aware UI; URL +
  title getters enable bookmark / share / address-bar features.
  macOS: WKWebView selectors + new `nsStringToOwnedUtf8` helper.
  Windows: vtSlots 38 / 39 / 4 / 48 + shared `wv2StringGetter`
  for LPWSTR-out + UTF-16→UTF-8 + `CoTaskMemFree`. Linux:
  `webkit_web_view_can_go_back` / `_can_go_forward` /
  `_get_uri` / `_get_title`.

### Added — Page title auto-sync (2026-05-26)

- IPC `shim_js` now polls `document.title` every 500ms + posts a
  `__verve_title:<title>` marker through the native bridge.
  Each backend's script-message trampoline intercepts the prefix
  before forwarding to the user's MessageHandler, calling the
  native title setter (`setTitle:` / `gtk_window_set_title` /
  `SetWindowTextW`). Pages mutating `<title>` propagate to the
  OS title bar / taskbar / window list with no app-side code.

## [0.1.2] - 2026-05-26

Four post-`v0.1.1` bundles. Window state + lifecycle + checked
auto-updater.

### Added — Auto-updater check (2026-05-26)

- New `desktop.updates` module:
  `checkForUpdate(allocator, feed_url, current_version) Error!?UpdateInfo`.
  Pure stdlib (`std.http.Client` + `std.json`); identical on all
  3 platforms; no native frameworks linked. Returns `null` when
  the caller is already up to date; otherwise `{ version,
  download_url, notes }` — caller owns each string. Lower-level
  `parseUpdateFeed(body, current)` lets apps drive their own HTTP
  fetch. SemVer compare via `compareSemver` (numeric-prefix
  ordering, tolerates leading `v` + `-rc1`-style suffixes).
- Applying the update — download, signature verify, swap binary,
  restart — stays out of scope. That's Sparkle / Squirrel /
  AppImageUpdate per-platform polish, deferred.

### Added — Window always-on-top + opacity (2026-05-26)

- `Window.setAlwaysOnTop(bool)` toggles whether the window floats
  above normal-stack peers. `Window.setOpacity(f64)` in `[0.0,
  1.0]`. macOS: `setLevel:NSFloatingWindowLevel` + `setAlphaValue:`
  / `setOpaque:`. Windows: `SetWindowPos(HWND_TOPMOST)` +
  `SetLayeredWindowAttributes(LWA_ALPHA)` with `WS_EX_LAYERED`
  stamped via `SetWindowLongPtrW`. Linux:
  `gtk_window_set_keep_above` + `gtk_widget_set_opacity`.

### Added — Window geometry + lifecycle (2026-05-26)

- Seven new methods: `setSize`, `setPosition`, `center`,
  `minimize`, `maximize`, `restore`, `setFullscreen`. macOS:
  `setContentSize:` / `setFrameTopLeftPoint:` / `center` /
  `miniaturize:` / `zoom:` / `deminiaturize:` /
  `toggleFullScreen:`. Windows: `SetWindowPos` + `ShowWindow(SW_*)`;
  fullscreen via strip-WS_OVERLAPPEDWINDOW + monitor-size
  SetWindowPos (saved style/rect cache on `WindowCtx`). Linux:
  `gtk_window_resize` / `_move` / `_iconify` / `_maximize` /
  `_unmaximize` / `_fullscreen` / `_unfullscreen` /
  `_set_position(CENTER)` / `_present`.

### Added — Window visibility + focus (2026-05-26)

- `Window.show()` / `hide()` / `focus()` / `setResizable(bool)`
  on all 3 backends. macOS: `makeKeyAndOrderFront:` +
  `activateIgnoringOtherApps:` / `orderOut:` / styleMask toggle.
  Windows: `ShowWindow(SW_SHOW/HIDE/RESTORE)` +
  `SetForegroundWindow`; resizable via `WS_THICKFRAME` |
  `WS_MAXIMIZEBOX` + `SetWindowPos(SWP_FRAMECHANGED)`. Linux:
  `gtk_widget_show_all` / `_hide` / `gtk_window_present` /
  `_set_resizable`. Template demo's tray "Show window" item now
  actually calls `window.show()` + `window.focus()` (was faked
  with evalJs before).

## [0.1.1] - 2026-05-26

Six P3 bundles shipped post-`v0.1.0`. Mostly closes the desktop
backlog — only GTK4, WinRT Toast (polish), full UIA / NSAccessibility
providers, and the auto-updater remain.

### Added — Custom tray icons (2026-05-26)

- `Tray.setIcon(path)` + `TrayOptions.icon_path` on all 3 backends.
  Replaces the stock `IDI_APPLICATION` glyph on Windows; macOS uses
  any `NSImage`-readable format with `setTemplate:true` for menu-bar
  tinting; Linux routes through `app_indicator_set_icon_full`
  (accepts absolute PNG path or theme icon name). `owns_icon` on
  Windows tracks LoadImageW-loaded HICONs vs the shared stock icon
  so `DestroyIcon` only fires on the owned variant.

### Added — Win balloon notifications (2026-05-26)

- Replaces `error.Unsupported` in `notifications.show` on Windows
  with `Shell_NotifyIconW(NIM_MODIFY, NIF_INFO)` against the active
  `desktop.tray` icon. Renders as a Win10/11 balloon tip (older
  shell) / Action Center entry (modern). Requires `desktop.tray.init`
  to have run first — without an active tray, the call returns
  `error.Backend`. WinRT Toast (`ToastNotificationManager`) deferred
  as polish.

### Added — Hicolor / Linux desktop integration (2026-05-26)

- New `zig build install-icons` step in `templates/desktop/build.zig`
  stages a freedesktop icon-theme tree + `.desktop` launcher entry
  under `zig-out/share/` for user (`~/.local/share`) or system
  (`/usr/share`) install. Build options:
  - `-Dlinux-icon=<path>` (single PNG → `scalable/apps/<name>.png`)
  - `-Dlinux-icon-<N>=<path>` for N in
    `{16,22,24,32,48,64,96,128,256,512}` (per-size variants)
  - `-Dlinux-categories=<x;y;>`, `-Dlinux-comment=<text>`,
    `-Dlinux-generic-name=<text>`, `-Dlinux-exec=<text>` for the
    `.desktop` file fields.
  Step is gated on `target.result.os.tag == .linux`.

### Added — Drag-drop with native file paths (2026-05-26)

- `Window.setDragDropHandler(cb, ctx)` + `WindowOptions.on_drag_drop`
  on all 3 backends. Single callback `fn(ctx, paths: []const []const u8)`
  fires with UTF-8 absolute filesystem paths — the browser
  `DataTransfer` API hides these by design.
- macOS: `VerveDragWindow` NSWindow subclass via
  `objc_allocateClassPair` + `object_setClass`;
  `registerForDraggedTypes:` with `public.file-url`;
  `performDragOperation:` reads
  `[NSPasteboard readObjectsForClasses:@[NSURL.class]]`.
- Windows: minimal `IDropTarget` COM impl embedded in `WindowCtx`
  (`drop_target` field, mirrors the env/ctrl/msg/res handler embed
  pattern). `OleInitialize` + `RegisterDragDrop`; `Drop` reads
  `IDataObject::GetData(CF_HDROP)` → `DragQueryFileW`. `RevokeDragDrop`
  on `WM_DESTROY`.
- Linux: `gtk_drag_dest_set(window, GTK_DEST_DEFAULT_ALL, NULL, 0,
  GDK_ACTION_COPY)` + `gtk_drag_dest_add_uri_targets` +
  `drag-data-received` signal. Strips `file://` URI prefix.

In-app drag sources (drags originating inside the WebView) remain
out of scope — those flow through standard HTML5 drag-drop events.

### Added — Print API (2026-05-26)

- `Window.print()` on all 3 backends. v1 dispatches via the page's
  `window.print()` — each native engine (WKWebView / WebView2 /
  WebKitGTK) renders its built-in print UI off that call. Native
  print APIs (`NSPrintOperation` / `ICoreWebView2_16::ShowPrintUI` /
  `webkit_print_operation_run_dialog`) deferred as polish for
  silent print + advanced controls.

### Added — Accessibility label API (2026-05-26)

- `Window.setAccessibilityLabel(text)` on all 3 backends. macOS:
  `[NSWindow setAccessibilityLabel:]`. Linux:
  `gtk_widget_get_accessible(window)` + `atk_object_set_name`.
  Windows: routes through `setTitle` (no separate Win32 a11y-label
  channel without a custom UIA provider; deferred).

### CLI

- No `verve-cli` changes vs `v0.1.0`. The `--release` / `--release-hash`
  flags shipped with `v0.1.0` continue to work — point at any
  released tag (`--release v0.1.1`).

## [0.1.0] - 2026-05-26

First tagged release. Closes P1 (#16–#23), every P2 platform port,
and the high-frequency P3 surface (clipboard, single-instance,
color-scheme follow, app icons, native menu bars on all 3,
deep-link URL handlers, tray icons + notifications, tray click
handlers + submenus).

### Added — Tray click handlers + submenus (2026-05-26)

- **Expanded `desktop.tray` API.** `TrayMenuItem { label, id,
  enabled, children }` value type — null label = separator,
  non-empty children = submenu parent. `TrayOptions` grew `menu`,
  `on_click` + `on_click_ctx`, `on_menu_item` + `on_menu_item_ctx`.
  ABI matches `MessageHandler` / `UrlOpenHandler` /
  `ColorSchemeHandler`. New `Tray.setMenu(items)` (deep-copies),
  `setClickHandler`, `setMenuItemHandler`. `Tray.impl` is now
  heap-allocated so callback singletons see a stable address after
  `init` returns by value.
- **macOS.** NSMenu via `objc_msgSend`; items target a process-wide
  `VerveTrayTarget` NSObject (registered lazily via
  `objc_allocateClassPair`) with `verveTrayItem:` /
  `verveTrayClick:` selectors. Each `NSMenuItem.setTag:` carries
  the user id; the trampoline reads `[sender tag]` and dispatches.
- **Windows.** `NOTIFYICONDATAW.uCallbackMessage = WM_VERVE_TRAY`
  (= `WM_USER + 100`, declared pub in `windows.zig`). wndProc
  forwards mouse events to `tray_dispatch_message` and `WM_COMMAND`
  IDs in the `0xC000` block to `tray_dispatch_command`. Right
  click / WM_CONTEXTMENU show the menu via `TrackPopupMenu` with
  the MSDN `SetForegroundWindow` + `PostMessage(WM_NULL)` dance.
  Tray IDs use `0xC000 | (user_id & 0x0FFF)` — no collisions with
  the default `0x8000` File/Edit range.
- **Linux.** GtkMenu via `gtk_menu_item_new_with_label` +
  `gtk_menu_shell_append`; submenus via
  `gtk_menu_item_set_submenu`; disabled rows via
  `gtk_widget_set_sensitive`. Each leaf gets `g_signal_connect_data`
  with an allocator-owned `ItemBox { *LinuxTray, id }` as
  user_data; boxes freed in `deinit`. AppIndicator has no
  icon-click signal so `on_click` is a no-op when a menu is set.
- **Template demo.** 4-item tray menu (Show window / Notify / sep /
  Quit) wired to a new `handlers.onTrayItem`; new "Tray menu" card
  in components; golden smoke checksum 284 → 605.
- **v1 limitation.** Single-tray-per-process — `g_macos_tray` /
  `g_windows_tray` are unguarded singletons. Multi-tray would need
  per-target ivars + an HWND-keyed registry. Deferred.

### Added — Tray icons + native notifications (2026-05-25)

- **New `desktop.tray` module.** `tray.init(allocator, &window,
  .{ .label, .tooltip })` creates a system-tray / status-bar icon;
  `setTooltip(text)` updates the hover text; `deinit` removes it.
  macOS: `NSStatusItem` from `[NSStatusBar systemStatusBar]`.
  Windows: `Shell_NotifyIconW(NIM_ADD)` with stock
  `IDI_APPLICATION` icon (`NIF_ICON | NIF_TIP`). Linux:
  `app_indicator_new` (libayatana-appindicator3) with an empty
  `GtkMenu` attached because some Ayatana versions silently refuse
  to render the icon without one. Click handlers + submenus are
  deferred to a future bundle.
- **New `desktop.notifications` module.** `notifications.show(allocator,
  .{ .title, .body })`. macOS: `NSUserNotification` +
  `NSUserNotificationCenter.deliverNotification:`. Linux: `notify_init`
  + `notify_notification_new` + `notify_notification_show` (libnotify).
  Windows returns `error.Unsupported` — Toast notifications need
  COM + AUMID + Start-menu registration, deferred to a future
  bundle. Apps that need Win notifications today combine
  `desktop.tray` with a manual `Shell_NotifyIconW(NIF_INFO)` call
  against the tray icon.
- **Backend exposure.** `src/desktop/windows.zig` gains `hwndOf(window)`
  so sibling modules can reach the underlying HWND without going
  through the cross-platform `Window` facade.
- **Template demo wiring.** Scaffold `main.zig` opens a tray icon
  on startup; `handlers.zig` ships a `notify` IPC route that fires
  a native notification; `components.zig` adds a "Notify" button
  card.

### Added — Win/Linux warm-launch URL forwarding (2026-05-25)

- **New `desktop.deep_link` module** with two halves:
  `forwardToRunningInstance(allocator, name, url)` (second-instance
  side) and `startListener(window, name)` (running-instance side).
  macOS makes both calls no-ops because `NSAppleEventManager`
  already routes URLs to the running process; Win + Linux now
  implement real cross-process delivery.
- **Windows** — `FindWindowW("VerveWindow", null)` locates the
  running app's HWND; `SendMessageW(WM_COPYDATA)` ships the URL
  with a `0x55524C00` ("URL\0") `dwData` sentinel so unrelated
  WM_COPYDATA traffic doesn't trip the receiver. The wndProc
  WM_COPYDATA case validates the sentinel, bounds-checks the
  payload (≤4 KB), and fires `on_url_open` on the matched
  `WindowCtx`.
- **Linux** — abstract `AF_UNIX SOCK_DGRAM` socket bound to
  `\0verve-deeplink-<single_instance_name>`. Sender `connect`s +
  `send`s a single datagram with the URL bytes. Receiver wraps the
  bound fd in a `GIOChannel` with a `G_IO_IN` watch so the GTK
  main loop dispatches inbound URLs; `close_on_unref(true)` cleans
  the fd up when the window is destroyed.
- **Template `main.zig`** — second-instance `AlreadyRunning`
  branch now calls `forwardToRunningInstance(allocator, name, u)`
  when `--url <u>` was provided, then exits. After the primary
  instance opens its window it calls
  `deep_link.startListener(&window, instance_name)` to bind the
  receive side.

### Added — Desktop deep-link URL handlers (2026-05-25)

- **`Window.setUrlOpenHandler(cb, ctx)` + `Window.deliverUrl(url)`**
  on the public surface; new `UrlOpenHandler` type and
  `on_url_open` / `on_url_open_ctx` fields on `WindowOptions`.
- **macOS — `NSAppleEventManager` handler** for
  `kInternetEventClass`/`kAEGetURL` (FourCharCode `'GURL'`,
  0x4755524C). Installs lazily on the first non-null
  `setUrlOpenHandler` call. Cocoa queues URL events that arrived
  before the AEH installed, then drains them on the next run-loop
  spin — so a `verve://...` URL clicked from Finder before
  `Window.init` even ran still reaches the callback.
- **Windows + Linux — cold-launch only.** Backend stores the
  callback on `WindowCtx`; the scaffold template's `main.zig`
  parses `--url <u>` or any positional starting with `verve://`
  and feeds it through `Window.deliverUrl(url)` after the window
  opens. Warm-launch second-instance forwarding (`WM_COPYDATA` on
  Win, abstract `AF_UNIX` socket on Linux) is a follow-up.
- **Scaffold `build.zig` — `-Durl-scheme=<name>`.** Injects
  `CFBundleURLTypes` into the macOS `Info.plist` so Launch
  Services routes `<scheme>://...` URLs to the .app.
- **Template demo wiring.** `handlers.zig` ships an `onUrlOpen`
  example that logs + dispatches the URL into the page via a new
  `window.verve.handleDeepLink` bridge hook; `components.zig`
  gains a "Deep link" card that mirrors the most-recent URL.

### Added — Desktop native menu bars on Windows + Linux (2026-05-25)

- **Default menu bar on every backend.** `install_default_menu = true`
  (the existing flag, previously honored only on macOS) now stamps a
  File + Edit bar on Windows and Linux for parity with the macOS
  App + Edit + Window default. Only File→Quit (Ctrl+Q) binds a real
  OS accelerator; Edit items render the shortcut hint in the label
  but do not attach an accelerator, because WebView2 and WebKitGTK
  handle Ctrl+C/V/X/Z/Y/A natively inside text inputs and a real
  OS-level binding would consume the key event before the webview
  saw it.
- **Win32 wiring.** `CreateMenu` + `CreatePopupMenu` + `AppendMenuW`
  + `SetMenu`; one-entry `HACCEL` driven through
  `TranslateAcceleratorW` in the main `GetMessageW` loop. Quit posts
  `WM_CLOSE` so multi-window last-window-quit semantics keep firing
  through the existing HWND registry. Accelerator table freed in
  `WM_DESTROY`.
- **GTK wiring.** `GtkBox(GTK_ORIENTATION_VERTICAL)` wrap stacks
  `gtk_menu_bar_new` above the webview; `gtk_accel_group_new` carries
  Ctrl+Q; Quit routes through `gtk_widget_destroy(window)` so the
  `live_windows` counter triggers `gtk_main_quit` only on the last
  close. Layout switch is conditional on the flag — opt-out apps keep
  the unchanged `gtk_container_add(window, webview)` tree.

### Added — Desktop framework polish (2026-05-24)

- **`--dev <dir>` runtime asset fallback.** Desktop scheme handler
  checks `<dir>/<path>` before the embedded `public_assets` table
  on every request, so hand-written frontend assets (`style.css`,
  `verve_desktop.js`, …) reload with Cmd+R instead of triggering a
  full process-restart rebuild. Rejects `..` and post-strip
  absolute paths; 16 MB per-file ceiling. Wired through
  `WindowOptions.dev_assets: ?DevAssetsConfig`.
- **Win + Linux ports of `openFileDialog` / `saveFileDialog` /
  `showAlert`.** Linux uses `GtkFileChooserNative` + `GtkMessageDialog`;
  Windows uses `GetOpenFileNameW` / `GetSaveFileNameW` + `MessageBoxW`.
  Win folder-picking returns `Unsupported` (needs `IFileOpenDialog`);
  custom alert labels honored on mac + Linux, mapped to standard
  buttons on Windows.
- **Win + Linux `takeSnapshotPng` ports.** Linux uses
  `webkit_web_view_get_snapshot` → cairo PNG; Windows uses
  `ICoreWebView2::CapturePreview` → `IStream` → `WriteFile`. Same
  byte-deterministic PNG output as the macOS reference.
- **Single-instance enforcement.**
  `desktop.single_instance.acquire(allocator, name)` returns an
  opaque `Lock` held for process lifetime. macOS + Linux use POSIX
  `flock(LOCK_EX | LOCK_NB)` on `<TMPDIR>/verve.<name>.lock`;
  Windows uses `CreateMutexW` under `Local\Verve.<name>`. Scaffold
  template wires it at startup automatically.
- **Cross-platform clipboard read/write.** `Window.clipboard()`
  returns a handle with `writeText` / `readText`. macOS:
  `NSPasteboard.generalPasteboard`; Windows: `OpenClipboard` +
  `CF_UNICODETEXT` + HGLOBAL ownership transfer; Linux:
  `gtk_clipboard_get(CLIPBOARD)` + `set_text` / `wait_for_text` +
  `gtk_clipboard_store`.
- **`Window.colorScheme()`** returns `.light` / `.dark` /
  `.unknown`. macOS: `[NSApp.effectiveAppearance].name`; Windows:
  `RegGetValueW(HKCU\…\Personalize\AppsUseLightTheme)`; Linux:
  GtkSettings' `gtk-application-prefer-dark-theme`. Pair with
  `Window.setColorSchemeHandler(cb, ctx)` for live change events
  via NSDistributedNotificationCenter (mac), WM_SETTINGCHANGE
  (win), GtkSettings notify signal (linux).
- **App icons (macOS `.app` bundle).** Scaffold `build.zig` gains
  a `-Dicon=<path>` option. Bundle step copies the supplied
  `.icns` into `Contents/Resources/AppIcon.icns` and injects
  `CFBundleIconFile = "AppIcon"` into the generated Info.plist.
  Absolute and build-root-relative paths both work.

### Fixed — Desktop framework

- **`openChildWindow` crash on multi-window apps.** The macOS
  backend re-registered `VerveSchemeHandler` and
  `VerveMessageHandler` Obj-C classes for every `Window.init`,
  but the Objective-C runtime rejects duplicate class names with
  `objc_allocateClassPair failed`. Classes are now cached at
  module scope and reused for every window.
- **`webview2.pinned.txt` SHA-512 populated.** Previously blank
  with TODO; reproducible Windows builds now actually verify the
  downloaded SDK. Also fixed `fetch_webview2.sh` `cut -d= -f2`
  truncating the trailing `==` base64 padding.
- **CI smoke server CSRF.** `--csrf=disable` added to the
  workflow's smoke-test invocation; form-encoded `/api/<fn>` POSTs
  no longer fail with `403`.
- **`verve-cli new <hyphenated-dir>`.** Basename-derived package
  names previously errored with `InvalidName` on hyphens. Hyphens
  / dots in basename now sanitize to `_`; explicit `--name=<n>`
  keeps the strict validation.

### Fixed — Docs

- **`docs/11-desktop-roadmap.md` #18 status.** Item was marked open
  even though commits 49b053d (J1 build-time SSR) and 3338d45
  (J2+J3 WASM + bridge) had landed. Doc now reflects shipped state.

## [0.1.0] — 2026-05-21

First public release. Server-side rendering with fine-grained
reactivity, a wasm32-freestanding client runtime that hosts the
real Signal/Effect graph, per-island WASM code-splitting, and a
single-binary distribution — all in pure Zig 0.16, zero external
runtime dependencies.

### Added — Routing + rendering

- Comptime route parser with path parameters (`/work/:slug`),
  wildcards (`/files/*rest`), and nested layouts via
  `ctx.outlet()`.
- `Route.layout` for grouping child routes under a shared shell.
- `ProtectedRoute` guards + `Redirect` sentinel
  (`ctx.redirect("/login")`).
- `ctx.location` (`useLocation`) with lazy query parsing +
  `isActive`.
- `RequestMeta` exposing cookies, Accept-Language, User-Agent,
  Origin, Host.
- Streaming HTML output via `std.http.Server`, chunked transfer
  encoding, no full-body buffering.

### Added — Reactivity (server + WASM client)

- Full SolidJS/Leptos-style reactive runtime: `Signal`,
  `Effect`, `Owner`, `Store`, `Resource`.
- Reactive `ErrorBoundary` — `Signal(?anyerror)` with
  `captureError` / `reset`.
- `untrack` / `batch` escape hatches.
- Per-request Owner with LIFO `on_cleanup` disposal.
- WASM client hosts the real reactive graph — `registerI32` /
  `registerStr` / `registerBool` / `registerF32` allocate
  Signals whose `on_set` hook drives DOM updates.
- 256 KB per-frame scratch allocator separate from the
  long-lived bump heap so reactive memory usage stays bounded by
  the largest single-frame render.

### Added — Keyed-list reconciler

- LIS-based planner emits the minimum (insert | move | remove)
  op sequence to turn the live DOM into a new key order.
- `ForEachHandle` caches the parent's current key order;
  `update(arena, new_keys, new_html)` diffs against the cache
  and dispatches DOM ops.
- `bindForEach(handle, ctx, render_fn)` ties a list-valued
  computation into the reactive graph — closure re-runs when any
  tracked Signal changes, automatically reconciles.

### Added — Components + head slots

- Arena-backed `*Node` tree with fluent chain methods.
- Head slot accumulator — `setTitle` / `metaTag` / `linkTag` /
  `jsonLd` with explicit priority + replace-not-append semantics.
- `provide` / `use` DI through the owner chain.
- `Slot` / `SlotMap` named-children API.
- `show` / `forEach` / `portal` control-flow helpers (server +
  reactive client-side via the reconciler).
- `NodeRef` typed handles + `data-ref` markers.

### Added — Actions / server functions

- Comptime dispatcher walks `app.Actions` to expose every
  `pub fn` as `POST /api/<name>`.
- Form-encoded bodies URL-decoded; JSON bodies parsed via
  `std.json`. Return types may be `void`, `!void`, `T`, or `!T`.
- `ctx.serverFn(f, args)` — server-side direct call.
- **Build-time codegen** (`tools/server_fn_codegen.zig`) emits
  `app_client.zig` with one typed wrapper per Action: native
  `<name>(arena, args) → Ret` plus WASM-callable
  `<name>_post(arena, args) → void` (JSON-serialize + JS-bridge
  fetch).
- Auto-303 redirect to `Referer` on form POSTs — works without
  any client-side JS.

### Added — Islands (per-island WASM chunks)

- `verve.island(ctx, opts, inner)` emits `<verve-island
  data-name=… data-props=…>` markers.
- **Build-time manifest codegen**
  (`tools/island_manifest_gen.zig`) walks `app.islands` and
  emits `client_manifest.zig` listing each island's name, props
  schema, and chunk URL.
- **Per-island WASM chunks** — `build.zig` parses
  `src/app/islands.zig` at configure time and builds one chunk
  per declared island. Custom logic via
  `src/client/islands/<Name>.zig`; everything else picks up a
  shared `_default.zig` stub.
- **Shared linear memory** — chunks import their memory from
  the main `client.wasm` via `env.memory`. Per-chunk size drops
  to ~73 bytes (vs. ~180 B standalone).
- JS bridge fetches chunks lazily, caches per name, copies props
  through shared scratch, calls `hydrate(ptr, len, root_id)`.
- In-process `verve_island_dispatch` for islands registered via
  `island.register(name, hydrate_fn)` in the main bundle.

### Added — Streaming SSR (out-of-order Suspense)

- `Suspense` boundary parks a continuation on the active
  `StreamRegistry` when `markSuspended()` fires and a registry
  is in scope.
- `verve.withStreamRegistry(reg, ctx, build_fn)` activates the
  thread-local for the lifetime of `build_fn`.
- `Renderer.streamRender(w, node, reg)` flushes the shell first,
  then drains every parked slot as
  `<template id="verve-vs-{id}">{real}</template>` +
  `verveSwap({id})` chunks.
- `window.verveSwap(id)` JS helper unwraps the matching template
  into the placeholder `<div data-vs="{id}">`. Reactive state
  on surrounding nodes survives.

### Added — SPA navigation

- `verve.link(ctx, href, label, opts)` emits anchors with
  `data-vlink`.
- Bridge intercepts same-origin clicks, fetches the page, merges
  `<head>` (title / meta by name|property / link by rel), swaps
  `<body>` innerHTML, pushes history.
- Optional prefetch-on-hover via `data-vprefetch="hover"`.
- `popstate` handler restores prior navigations.

### Added — Auth + security

- CSRF — HMAC-SHA256 token, auto-issued cookie + `__csrf` form
  field. `ctx.actionForm` injects the field automatically.
  `VERVE_CSRF_KEY` env var pins the secret across restarts.
- CSP nonce — per-request 12-byte hex nonce in
  `Content-Security-Policy: script-src 'nonce-…'
  'strict-dynamic'`.
- Origin pinning on form POSTs.
- `SameSite=Strict` on the CSRF cookie.
- `--csrf=enforce|disable` flag (default enforce).

### Added — Static assets

- `/public/*` routing — runtime via `--public-dir DIR`, or
  comptime-embedded via `-Dpublic-dir=DIR`.
- Hashed URLs (`/public/style-d5a73163.css`) with
  `Cache-Control: public, max-age=31536000, immutable`.
  `ctx.assetHref("style.css")` resolves the hashed form.
- mtime-aware LRU for `--public-dir` reads.
- Precompressed `.br` / `.gz` siblings served when present.

### Added — i18n

- `verve.I18nCatalog` + `resolveLocale` — cookie → query →
  Accept-Language → default with language-prefix fallback.

### Added — Dev + ops

- `--dev` auto-reload via injected WS-disconnect-reconnect
  script; `/__verve/dev_ws` upgrade endpoint.
- `/events` Server-Sent Events.
- `/ws` bidirectional WebSocket.
- `/health` — JSON: `{status, uptime_sec, requests}`.
- `/metrics` — per-route latency JSON.
- Bounded-admission worker pool (`--workers N`, default
  `CPU * 2`); excess returns 503.
- `LISTEN_FDS` env var for systemd socket activation.
- Graceful shutdown on `SIGINT` / `SIGTERM`.

### Added — Scaffolder

- `verve-cli new <dir>` writes the entire Verve source tree
  (sources + build wiring + test fixtures) into a target
  directory, emitting a fresh `build.zig.zon` with the chosen
  package name. Generated apps are self-contained — no Zig
  package-manager dependency, no git clone.

### Added — Build + tooling

- `zig build` produces a single-binary `verve-server` with the
  WASM client, per-island chunks, JS bridge, public assets, and
  manifest baked in. Plus `verve-cli` for scaffolding.
- `zig build test` runs 155+ tests spanning core / server /
  client / integration suites.
- `zig build docs` emits Zig autodoc HTML/JS to
  `zig-out/docs/api/`.
- 18 handwritten topic guides under `docs/`.
- 8 runnable example apps under `examples/`, including a full
  hybrid-product `showcase`.
- CI matrix (ubuntu-latest + macos-latest) runs `zig fmt`,
  `zig build`, `zig build test`, plus curl smoke tests against
  the live binary.

### Deferred (tracked for the 0.x line)

- **Phase 13F** — export the main runtime's Signal-registration
  + DOM-primitive symbols to per-island chunk imports so chunks
  can wire reactive state from inside their own `hydrate` body.
- **Phase 14C** — async `ctx.fetch` over `std.Io.async`
  (gated on Zig 0.16 ecosystem) so parked Suspense boundaries
  can genuinely wait on an upstream rather than re-running
  synchronously.
- **Typed WASM-side value returns** from server-fn calls
  (depends on Phase 14C's continuation shape).
- **Native TLS server** — production path today is to terminate
  TLS at a reverse proxy; revisit when `std.crypto.tls.Server`
  ships.
- **Brotli encoder** — gzip on the fly + precomputed `.br`
  siblings cover production today; revisit when a vetted
  pure-Zig brotli encoder lands.

[Unreleased]: https://github.com/sirhco/verve/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/sirhco/verve/releases/tag/v0.1.0
