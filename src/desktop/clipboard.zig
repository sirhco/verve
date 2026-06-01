//! Uniform system-clipboard API surfaced via `Window.clipboard()`.
//!
//! Reading is asynchronous on some backends (Linux's GtkClipboard
//! goes through the X11/Wayland selection round-trip; macOS and
//! Windows are synchronous) — the functions presented here are all
//! blocking so consumer code never sees callbacks. The backends pump
//! the platform event loop while they wait, same shape as the cookie
//! getters and the snapshot path.
//!
//! Backends that have not implemented clipboard support return
//! `error.Unsupported`; callers can probe by attempting a write of
//! an empty string.

const std = @import("std");
const builtin = @import("builtin");
const opts_mod = @import("options.zig");

pub const ClipboardError = opts_mod.ClipboardError;

const backend = switch (builtin.target.os.tag) {
    .macos => @import("macos.zig"),
    .windows => @import("windows.zig"),
    .linux => @import("linux.zig"),
    else => @compileError("desktop backend unimplemented for this OS"),
};

/// Per-window clipboard handle. The underlying clipboard is process-
/// global on every host backend; the per-window scoping just gives
/// API parity with `Window.cookies()` and threads the window pointer
/// through to backends that need it (Linux for GtkClipboard's
/// display lookup, the others ignore it).
pub const Clipboard = struct {
    window: *anyopaque,

    /// Replace the system clipboard's text content with `text`. UTF-8
    /// is the on-the-wire encoding; the backend transcodes to the
    /// native clipboard format (NSPasteboardTypeString on macOS,
    /// CF_UNICODETEXT on Windows, gtk_clipboard_set_text on Linux).
    pub fn writeText(self: Clipboard, text: []const u8) ClipboardError!void {
        return backend.clipboardWriteText(self.window, text);
    }

    /// Read the system clipboard's current text payload. Returns
    /// `null` when the clipboard holds no text (e.g. only an image
    /// or files). The returned slice is owned by `allocator`.
    pub fn readText(self: Clipboard, allocator: std.mem.Allocator) ClipboardError!?[]u8 {
        return backend.clipboardReadText(self.window, allocator);
    }

    /// Replace the system clipboard with an HTML fragment.
    /// macOS uses `NSPasteboardTypeHTML` (writes as
    /// `public.html`). Windows + Linux currently return
    /// `error.Unsupported` — Win needs the gnarly `CF_HTML`
    /// header format and Linux GtkClipboard `text/html` target
    /// needs custom serialization; both follow-up bundles.
    pub fn writeHtml(self: Clipboard, html: []const u8) ClipboardError!void {
        return backend.clipboardWriteHtml(self.window, html);
    }

    /// Read the system clipboard's HTML payload. Returns `null`
    /// when no HTML is on the pasteboard. macOS only on this
    /// surface today; Win + Linux return `error.Unsupported`.
    pub fn readHtml(self: Clipboard, allocator: std.mem.Allocator) ClipboardError!?[]u8 {
        return backend.clipboardReadHtml(self.window, allocator);
    }

    /// Replace the system clipboard with a PNG image (`png` = raw PNG bytes).
    /// macOS writes `public.png` (NSPasteboardTypePNG); Windows + Linux return
    /// `error.Unsupported` (CF_DIB / `image/png` GtkClipboard target are
    /// follow-up bundles).
    pub fn writeImage(self: Clipboard, png: []const u8) ClipboardError!void {
        return backend.clipboardWriteImage(self.window, png);
    }

    /// Read a PNG image off the clipboard, or `null` when none is present.
    /// Returned bytes are owned by `allocator`. macOS only today.
    pub fn readImage(self: Clipboard, allocator: std.mem.Allocator) ClipboardError!?[]u8 {
        return backend.clipboardReadImage(self.window, allocator);
    }
};
