//! Window construction options shared by every platform backend.
//!
//! The platform modules (`macos.zig`, `windows.zig`, `linux.zig`) all
//! consume the same `WindowOptions` value so a desktop app written
//! against `desktop.window` compiles unchanged across hosts. Only the
//! field set is platform-neutral; each backend is free to apply or
//! ignore individual fields (e.g. `devtools` is a no-op on Windows when
//! the WebView2 runtime has the developer-tools UI gated by group
//! policy).

const std = @import("std");

/// Embedded asset entry. Identical shape to `public_assets.Entry`
/// emitted by `build.zig:buildPublicAssets`, so a desktop app can pipe
/// its compile-time asset table straight into the router without an
/// intermediate adapter type.
pub const AssetEntry = struct {
    path: []const u8,
    bytes: []const u8,
    content_type: []const u8,
};

/// Callback invoked when the frontend posts a message via
/// `window.verve.send(...)`. `ctx` is the opaque pointer registered
/// alongside the callback. `payload` is the raw JSON string the JS
/// runtime delivered — the framework does not parse it.
pub const MessageHandler = *const fn (ctx: ?*anyopaque, payload: []const u8) void;

/// Parameters for `Window.openFileDialog` / `Window.saveFileDialog`.
pub const FileDialogOptions = struct {
    title: []const u8 = "",
    message: []const u8 = "",
    /// Initial directory. Empty string defers to the platform default.
    default_path: []const u8 = "",
    /// File-name suggestion shown in save dialogs. Ignored on open.
    default_name: []const u8 = "",
    /// Extensions like "txt", "json". Empty slice = allow any.
    allowed_extensions: []const []const u8 = &.{},
    /// Open dialogs only. Always false for save.
    allow_multiple: bool = false,
    /// Open dialogs only. When true, the dialog selects directories
    /// instead of files.
    pick_directory: bool = false,
};

/// Parameters for `Window.showAlert`.
pub const AlertOptions = struct {
    title: []const u8 = "",
    message: []const u8 = "",
    /// Button labels rendered right-to-left. The first label is the
    /// default action. Empty slice falls back to `["OK"]`.
    buttons: []const []const u8 = &.{},
    style: AlertStyle = .informational,
};

pub const AlertStyle = enum { informational, warning, critical };

pub const DialogError = error{
    Cancelled,
    Unsupported,
    OutOfMemory,
    PathTooLong,
};

/// Subset of `SameSite` cookie attribute values. Maps onto the
/// platform-native enums at the backend boundary.
pub const SameSite = enum { default, none, lax, strict };

/// Single cookie record. Values are caller-owned strings; backends
/// dupe into platform-native storage and never retain the slice.
/// Mirrors WKHTTPCookieStore / ICoreWebView2CookieManager /
/// SoupCookie field surfaces closely enough to round-trip without
/// information loss on the common path.
pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    /// Defaults to the request origin when empty.
    domain: []const u8 = "",
    path: []const u8 = "/",
    /// Unix epoch seconds. 0 = session cookie (no Expires attribute).
    expires_unix: i64 = 0,
    secure: bool = false,
    http_only: bool = false,
    same_site: SameSite = .default,
};

pub const CookieError = error{
    Unsupported,
    NotReady,
    OutOfMemory,
    Backend,
};

pub const ClipboardError = error{
    Unsupported,
    OutOfMemory,
    Backend,
};

/// Current system color preference. Apps that style their UI to
/// match the OS appearance should call `Window.colorScheme()` at
/// startup and either re-check on window restore or register a
/// `ColorSchemeHandler` via `Window.setColorSchemeHandler` to be
/// notified when the user toggles the OS setting at runtime.
pub const ColorScheme = enum { light, dark, unknown };

/// Callback fired when the OS delivers a deep-link URL to the app —
/// the user clicked a `verve://...` link or opened a `.desktop`-handled
/// MIME. `url` is the full URL string the OS received. Caller does not
/// retain the slice; copy if you need to outlive the callback.
///
/// Cold-launch (app starts up because of the URL) and warm-launch (app
/// already running, OS delivers via a process IPC) both funnel through
/// the same callback. macOS handles both via `AppleEventManager`'s
/// `kInternetEventClass`/`kAEGetURL` so the handler fires from inside
/// the Cocoa run loop. Windows + Linux ship cold-launch via the
/// process argv only in this pass — second-instance URL forwarding
/// (WM_COPYDATA / AF_UNIX socket) is a follow-up.
pub const UrlOpenHandler = *const fn (ctx: ?*anyopaque, url: []const u8) void;

/// Callback fired when the OS color-scheme preference changes.
/// `ctx` is the opaque pointer registered alongside the callback.
/// Fires on the main / UI thread of the host platform — same thread
/// that drives the event loop — so consumers can call any other
/// `Window` method without crossing threads.
pub const ColorSchemeHandler = *const fn (ctx: ?*anyopaque, scheme: ColorScheme) void;

/// Callback fired when the user drops one or more files onto the
/// window from outside the app (Finder / Explorer / file manager).
/// `paths` is a slice of UTF-8 absolute filesystem paths — the
/// browser's drag-drop DataTransfer hides these by design, so this
/// callback is the only way to learn them from native code. The
/// slice (and the strings it points at) live only for the duration
/// of the callback; copy if you need to outlive it.
///
/// In-app drag sources (drags originating inside the webview) are
/// out of scope — those still flow through standard HTML5 drag-drop
/// events on the JS side.
pub const DragDropHandler = *const fn (ctx: ?*anyopaque, paths: []const []const u8) void;

/// Fired when the window is resized by the user (window-chrome drag,
/// maximize, fullscreen, restore). `width` and `height` are the new
/// content-area dimensions in OS-logical pixels. The callback fires
/// on the main / UI thread.
pub const ResizeHandler = *const fn (ctx: ?*anyopaque, width: u32, height: u32) void;

/// Fired when the window gains (`focused = true`) or loses
/// (`focused = false`) keyboard focus.
pub const FocusHandler = *const fn (ctx: ?*anyopaque, focused: bool) void;

/// Fired when the user requests close (title-bar X, OS shortcut).
/// Return `true` to allow the close; return `false` to keep the
/// window open (apps prompting "Unsaved changes?" return false
/// until the user confirms). Without a handler, close proceeds.
pub const CloseHandler = *const fn (ctx: ?*anyopaque) bool;

pub const SnapshotError = error{
    Unsupported,
    /// Snapshot capture returned without an image (timeout / view not ready / GPU issue).
    CaptureFailed,
    /// PNG encoding via platform image API failed.
    EncodeFailed,
    /// Write to disk failed (permissions / disk full / invalid path).
    WriteFailed,
};

/// Configuration for `WindowOptions.dev_assets`. Pairs the source
/// directory with the `Io` the backend needs to perform the
/// fallback file read.
pub const DevAssetsConfig = struct {
    /// Directory served as the disk fallback. May be relative to the
    /// working directory the app was launched from. Caller owns the
    /// slice; the backend captures by reference and never frees it.
    dir: []const u8,
    /// `Io` used for `openFile` / `stat` / `readPositionalAll`. Typically
    /// `init.io` from the app's `main` entry point.
    io: std.Io,
};

/// Construction parameters for `Window.init`. The platform layer
/// captures these by value during init; later changes need explicit
/// setter calls (`setTitle`, `loadUrl`, …).
pub const WindowOptions = struct {
    /// UTF-8 window title shown in the OS title bar. Length is bounded
    /// by the platform — the macOS backend silently truncates beyond
    /// roughly 256 chars; Windows allows up to ~32K via `SetWindowTextW`.
    title: []const u8 = "Verve",

    /// Initial outer dimensions in OS-logical pixels. The backend may
    /// clamp these to the primary display's working area.
    width: u32 = 1024,
    height: u32 = 768,

    /// Whether the embedded webview should expose its native developer
    /// tools UI. Honored on macOS (WKWebView `developerExtrasEnabled`)
    /// and Windows (WebView2 `AreDevToolsEnabled`). On WebKitGTK the
    /// `WEBKIT_DEBUG=...` environment variable still applies.
    devtools: bool = false,

    /// URL scheme name used for the custom-scheme asset bridge. Defaults
    /// to `verve`, producing URLs of the form `verve://app/<path>`. The
    /// authority (`app`) is fixed by `asset_router.resolve`.
    scheme: []const u8 = "verve",

    /// Path that the backend should navigate to after the window is
    /// shown. Resolved through the custom scheme so the asset router
    /// answers it from the embedded table. Pass an empty string to skip
    /// the initial navigation entirely.
    initial_path: []const u8 = "index.html",

    /// Embedded asset table the custom-scheme handler resolves against.
    /// May be empty — in that case all in-flight resource requests fail
    /// with a clear error, which is useful while iterating on a project
    /// that has not produced its production bundle yet.
    assets: []const AssetEntry = &.{},

    /// Opt-in dev-mode fallback: when set, scheme-handler requests that
    /// miss `assets` fall through to a sandboxed disk read against
    /// `dev_assets.dir`. The `io` field is required for the file ops;
    /// scaffolded apps pass `init.io` straight through. Leave `null`
    /// for production builds — the asset table is the source of truth.
    /// Path traversal (`..`) and post-strip absolute paths are rejected.
    dev_assets: ?DevAssetsConfig = null,

    /// Optional message-handler callback + context registered before
    /// any page load. The same pointer pair can be set later via
    /// `Window.setMessageHandler`; supplying it here just saves the
    /// follow-up call.
    on_message: ?MessageHandler = null,
    on_message_ctx: ?*anyopaque = null,

    /// Optional deep-link handler + context registered before any URL
    /// the OS delivers can fire. macOS installs the AppleEventManager
    /// handler eagerly during `Window.init` when this is non-null, so
    /// cold-launch URLs that arrive during the early Cocoa run-loop
    /// pump are queued through the same callback. Set via
    /// `Window.setUrlOpenHandler` if you need to install it later.
    on_url_open: ?UrlOpenHandler = null,
    on_url_open_ctx: ?*anyopaque = null,

    /// Optional drag-drop handler + context for file drops from outside
    /// the app. When non-null, the backend registers the platform-
    /// native drag-destination and routes incoming file drops through
    /// this callback. `Window.setDragDropHandler` swaps it at runtime.
    on_drag_drop: ?DragDropHandler = null,
    on_drag_drop_ctx: ?*anyopaque = null,

    /// Optional resize / focus / close handlers. All fire on the
    /// main / UI thread. Setters on `Window` (`setResizeHandler`,
    /// `setFocusHandler`, `setCloseHandler`) swap at runtime.
    on_resize: ?ResizeHandler = null,
    on_resize_ctx: ?*anyopaque = null,
    on_focus: ?FocusHandler = null,
    on_focus_ctx: ?*anyopaque = null,
    on_close: ?CloseHandler = null,
    on_close_ctx: ?*anyopaque = null,

    /// Install a default OS menu bar. Honored on all three backends:
    /// macOS gets App + Edit + Window menus; Windows and Linux get
    /// File (Quit) + Edit (Undo/Redo/Cut/Copy/Paste/Select All). On
    /// Win/Linux the Edit shortcuts are rendered as hints — the
    /// embedded webview handles the actual clipboard keystrokes
    /// natively, and attaching a real OS-level accelerator would
    /// consume the key event before the webview saw it. Set to
    /// `false` to suppress the bar (apps building their own).
    install_default_menu: bool = true,
};
