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
   shipped 2026-05-24/25/26 are listed under "Out of P1 scope —
   shipped" below. Remaining P3 backlog: GTK4 backend, drag-drop with
   native paths, print API, hicolor / Linux icon-theme install,
   accessibility (NSAccessibility / UIA / ATK), auto-updater
   (Sparkle / Squirrel), Win tray-balloon / Toast notifications
   (macOS + Linux notifications already landed). Tray click handlers
   + submenus on all 3 platforms shipped 2026-05-26.
4. **Hard constraint: do not modify `src/verve.zig`.** Public web
   surface stays unchanged. Anything desktop-specific goes in
   `src/desktop/` or the template tree.

Authoritative state of the desktop scaffold subsystem and the remaining
work needed to call it "fully functional." Written 2026-05-22, last
updated 2026-05-26. Fresh sessions should be able to pick up without
prior context.

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
  `openUrl(allocator, url) Error!void`. Hands a URL to the OS
  shell so it opens in the system default browser (HTTP) or the
  registered handler app (mailto:, custom schemes). macOS:
  `[NSWorkspace.sharedWorkspace openURL:]`. Windows:
  `ShellExecuteW(NULL, "open", url, NULL, NULL, SW_SHOWNORMAL)`.
  Linux: `posix.fork` + `execvp("xdg-open", ...)`. Apps that
  want web links to open externally (instead of navigating the
  embedded WebView) call this from their IPC handler.
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
is deferred — it needs COM init + AUMID +
`SetCurrentProcessExplicitAppUserModelID` + Start-menu shortcut
registration + XML toast templates, ~500 LOC of WinRT plumbing.
The balloon path covers the basic title/body case for v1.

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
- Native print APIs (`NSPrintOperation` /
  `ICoreWebView2_16::ShowPrintUI` /
  `webkit_print_operation_run_dialog`) — `window.print()` path
  shipped 2026-05-26; native APIs remain future polish for silent
  print + page-range / printer-selection controls.
- Win Toast (WinRT) notifications — balloon path shipped 2026-05-26;
  Toast remains future polish for richer styling + Action Center
  grouping.
- Accessibility — `setAccessibilityLabel` shipped 2026-05-26;
  richer NSAccessibility / UIA provider / full ATK roles + states
  remain future polish. Web content + default menu items already
  publish their own labels through the WebView engines + native
  menu APIs.
- Auto-updater apply phase — `desktop.updates.checkForUpdate`
  shipped 2026-05-26. Actually downloading + verifying signatures +
  swapping the running executable remains per-platform polish
  (Sparkle on macOS, Squirrel or MSIX on Windows, AppImageUpdate
  on Linux).

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

## Suggested next-session bundles

All P1 + every P2 platform port closed. The high-value P3 items
landed across 2026-05-24/25/26: clipboard, single-instance, color
scheme + change events, app icons, native menu bars (all 3),
deep-link URL handlers (warm + cold, all 3), tray icons (all 3),
notifications (macOS + Linux), tray click handlers + submenus (all
3). Remaining work is the lower-frequency P3 surface:

| Bundle | Items | Best for |
|---|---|---|
| **P3 GTK4** | GTK4 + WebKitGTK 6.0 behind `-Dgtk4` | Future-proofing once Ubuntu LTS / Fedora ship GTK4 webkit by default. New backend module; existing GTK3 path stays. |
| **P3 drag-drop / print** | `NSDraggingDestination` / `IDropTarget` / GTK drag signals; `NSPrintOperation` / `PrintDlgExW` / `gtk_print_operation_run` | Drag-drop with native file paths (browser DataTransfer doesn't expose them). |
| **P3 Win Toast** | `Windows.UI.Notifications.ToastNotificationManager` via COM + AUMID + Start-menu shortcut | Closes the Windows side of the notifications API. |
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
- The 2026-05-25 session shipped four P3 bundles (menus, deep-link
  cold-launch + warm-launch, tray + notifications). Same rubric
  applied: each bundle had its own commit + cross-compile + scaffold
  smoke. Tree clean at session end.
- New Linux runtime deps as of 2026-05-25:
  `libayatana-appindicator3` (tray) + `libnotify` (notifications).
  Both are present by default on most Ubuntu / Fedora / Debian /
  Arch GNOME + KDE installs. Distros without them will fail at
  link time for any scaffolded app — including apps that don't use
  the new modules. Moving the externs behind weak symbols /
  `dlopen` is a polish item.
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
