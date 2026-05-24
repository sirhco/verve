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
        "takeSnapshotPng",
    };
    for (required) |name| {
        if (!@hasDecl(Window, name)) {
            @compileError("desktop backend (" ++ @tagName(builtin.os.tag) ++ ") missing required method: " ++ name);
        }
    }
}
