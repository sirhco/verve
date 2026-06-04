//! Cross-platform window facade. Comptime-dispatches to the backend
//! that matches the host OS. The selected backend implements a `Window`
//! struct with the same public surface; this file re-exports it so app
//! code writes `const w = try desktop.Window.init(alloc, opts);`
//! regardless of platform.
//!
//! Unsupported hosts fail at compile time rather than at runtime — a
//! missing backend is a build-graph mistake, not a recoverable error.

const std = @import("std");
const builtin = @import("builtin");

pub const options = @import("options.zig");
pub const ipc = @import("ipc.zig");
pub const ipc_router = @import("ipc_router.zig");
pub const asset_router = @import("asset_router.zig");
pub const cookies = @import("cookies.zig");
pub const clipboard = @import("clipboard.zig");
pub const single_instance = @import("single_instance.zig");
pub const deep_link = @import("deep_link.zig");
pub const tray = @import("tray.zig");
pub const notifications = @import("notifications.zig");
pub const updates = @import("updates.zig");
pub const displays = @import("displays.zig");
pub const shell = @import("shell.zig");
pub const paths = @import("paths.zig");
pub const system = @import("system.zig");
pub const autostart = @import("autostart.zig");
pub const disk = @import("disk.zig");
pub const power = @import("power.zig");
pub const network = @import("network.zig");
pub const fswatch = @import("fswatch.zig");
pub const hotkeys = @import("hotkeys.zig");
pub const process = @import("process.zig");

pub const Router = ipc_router.Router;

pub const WindowOptions = options.WindowOptions;
pub const AssetEntry = options.AssetEntry;
pub const MessageHandler = options.MessageHandler;
pub const FileDialogOptions = options.FileDialogOptions;
pub const AlertOptions = options.AlertOptions;
pub const AlertStyle = options.AlertStyle;
pub const DialogError = options.DialogError;
pub const Cookie = options.Cookie;
pub const CookieError = options.CookieError;
pub const SnapshotError = options.SnapshotError;
pub const SameSite = options.SameSite;
pub const ClipboardError = options.ClipboardError;
pub const PrintDialogKind = options.PrintDialogKind;
pub const PrintOptions = options.PrintOptions;
pub const PrintError = options.PrintError;
pub const PageRange = options.PageRange;
pub const ColorScheme = options.ColorScheme;
pub const ColorSchemeHandler = options.ColorSchemeHandler;
pub const UrlOpenHandler = options.UrlOpenHandler;
pub const DragDropHandler = options.DragDropHandler;
pub const ResizeHandler = options.ResizeHandler;
pub const FocusHandler = options.FocusHandler;
pub const CloseHandler = options.CloseHandler;
pub const DevAssetsConfig = options.DevAssetsConfig;
pub const CookieStore = cookies.CookieStore;

const root = @import("root");

// Native-host backend opt-in. `@hasDecl` guards the field access, so this
// compiles whether or not root declares it (test runners, bare modules).
const win_backend_native = @hasDecl(root, "verve_win_backend_native") and root.verve_win_backend_native;

const backend = switch (builtin.os.tag) {
    .macos => @import("macos.zig"),
    // Windows backend selection. Default: the legacy pure-Zig COM backend.
    // A desktop/template build opts into the native C++ WebView2 host
    // backend by declaring `pub const verve_win_backend_native = true;` in
    // its ROOT source file; this is wired into the framework + scaffold
    // builds at the Bundle 9 cutover. Until then `windows_native.zig` is
    // exercised only via `zig build win-native`.
    .windows => if (win_backend_native) @import("windows_native.zig") else @import("windows.zig"),
    .linux => @import("linux.zig"),
    else => @compileError("verve.desktop: unsupported OS — only macOS, Windows, and Linux are wired today"),
};

pub const Window = backend.Window;

// Backend-conformance check. Every host backend MUST expose this
// surface or downstream call sites blow up at instantiation time
// with confusing decl-missing errors. Fail fast at framework-build
// instead. Adding a new public method? Append it here too.
comptime {
    const required = [_][]const u8{
        "init",
        "setTitle",
        "loadUrl",
        "loadHtml",
        "evalJs",
        "setMessageHandler",
        "run",
        "deinit",
        "terminate",
        "close",
        "openFileDialog",
        "saveFileDialog",
        "showAlert",
        "openChildWindow",
        "cookies",
        "clipboard",
        "colorScheme",
        "setColorSchemeHandler",
        "setUrlOpenHandler",
        "deliverUrl",
        "takeSnapshotPng",
        "setDragDropHandler",
        "print",
        "printWithOptions",
        "setAccessibilityLabel",
        "setAccessibilityHelp",
        "setAccessibilityRoleDescription",
        "setAccessibilitySubrole",
        "setAlwaysOnTop",
        "setOpacity",
        "setSize",
        "setPosition",
        "center",
        "minimize",
        "maximize",
        "restore",
        "setFullscreen",
        "show",
        "hide",
        "focus",
        "setResizable",
        "setResizeHandler",
        "setFocusHandler",
        "setCloseHandler",
        "setMinSize",
        "setMaxSize",
        "reload",
        "goBack",
        "goForward",
        "canGoBack",
        "canGoForward",
        "currentUrl",
        "currentTitle",
        "setZoom",
        "getZoom",
        "scaleFactor",
        "requestAttention",
        "isMinimized",
        "isMaximized",
        "isFullscreen",
    };
    for (required) |name| {
        if (!@hasDecl(Window, name)) {
            @compileError("desktop backend (" ++ @tagName(builtin.os.tag) ++ ") missing required method: " ++ name);
        }
    }
}
