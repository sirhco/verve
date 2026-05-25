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
pub const ColorScheme = options.ColorScheme;
pub const ColorSchemeHandler = options.ColorSchemeHandler;
pub const UrlOpenHandler = options.UrlOpenHandler;
pub const DragDropHandler = options.DragDropHandler;
pub const ResizeHandler = options.ResizeHandler;
pub const FocusHandler = options.FocusHandler;
pub const CloseHandler = options.CloseHandler;
pub const DevAssetsConfig = options.DevAssetsConfig;
pub const CookieStore = cookies.CookieStore;

const backend = switch (builtin.os.tag) {
    .macos => @import("macos.zig"),
    .windows => @import("windows.zig"),
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
        "setAccessibilityLabel",
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
    };
    for (required) |name| {
        if (!@hasDecl(Window, name)) {
            @compileError("desktop backend (" ++ @tagName(builtin.os.tag) ++ ") missing required method: " ++ name);
        }
    }
}
