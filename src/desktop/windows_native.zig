//! windows_native.zig — Windows desktop backend backed by a native C++
//! WebView2 host behind a flat C ABI (src/desktop/win_native/host.h).
//!
//! This is the eventual replacement for the 4129-line pure-Zig hand-rolled
//! COM backend in `windows.zig`. It mirrors the same `Window` surface so the
//! `window.zig` conformance check is satisfied and the backend is a drop-in.
//!
//! Bundle 1 (this file): the migration scaffold. CORE methods (init, run,
//! load*, evalJs, setMessageHandler, deinit) delegate to the native host for
//! real; every other conformance method is a typed stub that compiles and
//! returns a sane default, each tagged with the later bundle that fills it in
//! (geometry=2, nav=3, events=4, dialogs=5, cookies=6, clipboard=7,
//! print/a11y/snapshot/toast/terminate=8).

const std = @import("std");

const opts_mod = @import("options.zig");
const cookies_mod = @import("cookies.zig");
const clipboard_mod = @import("clipboard.zig");

// ---- Flat C ABI to the native WebView2 host ---------------------------------

const Host = opaque {};
const BridgeFn = *const fn (ctx: ?*anyopaque, msg: [*]const u8, len: usize) callconv(.c) void;

extern fn wv2_create(title: [*:0]const u8, width: c_int, height: c_int) ?*Host;
extern fn wv2_load_html(host: *Host, html: [*]const u8, len: usize) void;
extern fn wv2_load_url(host: *Host, url: [*]const u8, len: usize) void;
extern fn wv2_eval_js(host: *Host, js: [*]const u8, len: usize) void;
extern fn wv2_set_bridge(host: *Host, cb: BridgeFn, ctx: ?*anyopaque) void;
extern fn wv2_run(host: *Host) void;
extern fn wv2_destroy(host: *Host) void;

/// Toast error set — mirrors the legacy `windows.zig` surface so the
/// module-level `showToast` is signature-compatible.
pub const ToastError = error{ Unsupported, Backend, OutOfMemory };

// ---- Heap-pinned window context ---------------------------------------------

const WindowCtx = struct {
    allocator: std.mem.Allocator,
    host: *Host,
    on_message: ?opts_mod.MessageHandler = null,
    on_message_ctx: ?*anyopaque = null,
};

pub const Window = struct {
    ctx: *WindowCtx,

    // ---- core (wired for real) ----------------------------------------------

    pub fn init(allocator: std.mem.Allocator, opts: opts_mod.WindowOptions) !Window {
        const heap = try allocator.create(WindowCtx);
        errdefer allocator.destroy(heap);

        // Truncate (not drop) titles longer than the buffer: keep a valid
        // NUL-terminated prefix of the real title rather than falling back.
        var tbuf: [512]u8 = undefined;
        const src = opts.title[0..@min(opts.title.len, tbuf.len - 1)];
        @memcpy(tbuf[0..src.len], src);
        tbuf[src.len] = 0;
        const tz: [*:0]const u8 = @ptrCast(&tbuf);
        const host = wv2_create(tz, @intCast(opts.width), @intCast(opts.height)) orelse
            return error.BackendInit;

        heap.* = .{
            .allocator = allocator,
            .host = host,
            .on_message = opts.on_message,
            .on_message_ctx = opts.on_message_ctx,
        };
        wv2_set_bridge(host, bridgeTrampoline, heap);
        return .{ .ctx = heap };
    }

    pub fn run(self: *Window) void {
        wv2_run(self.ctx.host);
    }

    pub fn loadUrl(self: *Window, url: []const u8) !void {
        wv2_load_url(self.ctx.host, url.ptr, url.len);
    }

    pub fn loadHtml(self: *Window, html: []const u8, _: ?[]const u8) !void {
        wv2_load_html(self.ctx.host, html.ptr, html.len);
    }

    pub fn evalJs(self: *Window, script: []const u8) void {
        wv2_eval_js(self.ctx.host, script.ptr, script.len);
    }

    pub fn setMessageHandler(self: *Window, handler: opts_mod.MessageHandler, handler_ctx: ?*anyopaque) void {
        self.ctx.on_message = handler;
        self.ctx.on_message_ctx = handler_ctx;
    }

    pub fn deinit(self: *Window) void {
        wv2_destroy(self.ctx.host);
        self.ctx.allocator.destroy(self.ctx);
    }

    // ---- cookies / clipboard handles ----------------------------------------

    pub fn cookies(self: *Window) cookies_mod.CookieStore {
        // TODO bundle 6: thread the real cookie store through the native host.
        return .{ .window = @ptrCast(self.ctx.host) };
    }

    pub fn clipboard(self: *Window) clipboard_mod.Clipboard {
        // TODO bundle 7: thread the real clipboard through the native host.
        return .{ .window = @ptrCast(self.ctx.host) };
    }

    // ---- geometry / chrome (bundle 2) ---------------------------------------

    pub fn setTitle(self: *Window, title: []const u8) void {
        _ = self;
        _ = title;
        // TODO bundle 2
    }

    pub fn setAlwaysOnTop(self: *Window, on: bool) void {
        _ = self;
        _ = on;
        // TODO bundle 2
    }

    pub fn setOpacity(self: *Window, value: f64) void {
        _ = self;
        _ = value;
        // TODO bundle 2
    }

    pub fn setSize(self: *Window, width: u32, height: u32) void {
        _ = self;
        _ = width;
        _ = height;
        // TODO bundle 2
    }

    pub fn setPosition(self: *Window, x: i32, y: i32) void {
        _ = self;
        _ = x;
        _ = y;
        // TODO bundle 2
    }

    pub fn center(self: *Window) void {
        _ = self;
        // TODO bundle 2
    }

    pub fn minimize(self: *Window) void {
        _ = self;
        // TODO bundle 2
    }

    pub fn maximize(self: *Window) void {
        _ = self;
        // TODO bundle 2
    }

    pub fn restore(self: *Window) void {
        _ = self;
        // TODO bundle 2
    }

    pub fn setFullscreen(self: *Window, on: bool) void {
        _ = self;
        _ = on;
        // TODO bundle 2
    }

    pub fn show(self: *Window) void {
        _ = self;
        // TODO bundle 2
    }

    pub fn hide(self: *Window) void {
        _ = self;
        // TODO bundle 2
    }

    pub fn focus(self: *Window) void {
        _ = self;
        // TODO bundle 2
    }

    pub fn setResizable(self: *Window, on: bool) void {
        _ = self;
        _ = on;
        // TODO bundle 2
    }

    pub fn setMinSize(self: *Window, width: u32, height: u32) void {
        _ = self;
        _ = width;
        _ = height;
        // TODO bundle 2
    }

    pub fn setMaxSize(self: *Window, width: u32, height: u32) void {
        _ = self;
        _ = width;
        _ = height;
        // TODO bundle 2
    }

    pub fn setZoom(self: *Window, level: f64) void {
        _ = self;
        _ = level;
        // TODO bundle 2
    }

    pub fn getZoom(self: *Window) f64 {
        _ = self;
        // TODO bundle 2
        return 1.0;
    }

    pub fn scaleFactor(self: *Window) f32 {
        _ = self;
        // TODO bundle 2
        return 1.0;
    }

    pub fn requestAttention(self: *Window, critical: bool) void {
        _ = self;
        _ = critical;
        // TODO bundle 2
    }

    pub fn isMinimized(self: *Window) bool {
        _ = self;
        // TODO bundle 2
        return false;
    }

    pub fn isMaximized(self: *Window) bool {
        _ = self;
        // TODO bundle 2
        return false;
    }

    pub fn isFullscreen(self: *Window) bool {
        _ = self;
        // TODO bundle 2
        return false;
    }

    // ---- navigation (bundle 3) ----------------------------------------------

    pub fn reload(self: *Window) void {
        _ = self;
        // TODO bundle 3
    }

    pub fn goBack(self: *Window) void {
        _ = self;
        // TODO bundle 3
    }

    pub fn goForward(self: *Window) void {
        _ = self;
        // TODO bundle 3
    }

    pub fn canGoBack(self: *Window) bool {
        _ = self;
        // TODO bundle 3
        return false;
    }

    pub fn canGoForward(self: *Window) bool {
        _ = self;
        // TODO bundle 3
        return false;
    }

    pub fn currentUrl(self: *Window, allocator: std.mem.Allocator) ![]u8 {
        _ = self;
        // TODO bundle 3
        return allocator.dupe(u8, "");
    }

    pub fn currentTitle(self: *Window, allocator: std.mem.Allocator) ![]u8 {
        _ = self;
        // TODO bundle 3
        return allocator.dupe(u8, "");
    }

    // ---- events / handlers (bundle 4) ---------------------------------------

    pub fn setColorSchemeHandler(self: *Window, cb: ?opts_mod.ColorSchemeHandler, ctx: ?*anyopaque) void {
        _ = self;
        _ = cb;
        _ = ctx;
        // TODO bundle 4
    }

    pub fn setUrlOpenHandler(self: *Window, cb: ?opts_mod.UrlOpenHandler, ctx: ?*anyopaque) void {
        _ = self;
        _ = cb;
        _ = ctx;
        // TODO bundle 4
    }

    pub fn deliverUrl(self: *Window, url: []const u8) void {
        _ = self;
        _ = url;
        // TODO bundle 4
    }

    pub fn setDragDropHandler(self: *Window, cb: ?opts_mod.DragDropHandler, ctx: ?*anyopaque) void {
        _ = self;
        _ = cb;
        _ = ctx;
        // TODO bundle 4
    }

    pub fn setResizeHandler(self: *Window, cb: ?opts_mod.ResizeHandler, ctx: ?*anyopaque) void {
        _ = self;
        _ = cb;
        _ = ctx;
        // TODO bundle 4
    }

    pub fn setFocusHandler(self: *Window, cb: ?opts_mod.FocusHandler, ctx: ?*anyopaque) void {
        _ = self;
        _ = cb;
        _ = ctx;
        // TODO bundle 4
    }

    pub fn setCloseHandler(self: *Window, cb: ?opts_mod.CloseHandler, ctx: ?*anyopaque) void {
        _ = self;
        _ = cb;
        _ = ctx;
        // TODO bundle 4
    }

    pub fn colorScheme(self: *Window) opts_mod.ColorScheme {
        _ = self;
        // TODO bundle 4
        return .unknown;
    }

    // ---- dialogs (bundle 5) -------------------------------------------------

    pub fn openFileDialog(self: *Window, allocator: std.mem.Allocator, opts: opts_mod.FileDialogOptions) opts_mod.DialogError![]u8 {
        _ = self;
        _ = allocator;
        _ = opts;
        // TODO bundle 5
        return error.Unsupported;
    }

    pub fn saveFileDialog(self: *Window, allocator: std.mem.Allocator, opts: opts_mod.FileDialogOptions) opts_mod.DialogError![]u8 {
        _ = self;
        _ = allocator;
        _ = opts;
        // TODO bundle 5
        return error.Unsupported;
    }

    pub fn showAlert(self: *Window, opts: opts_mod.AlertOptions) usize {
        _ = self;
        _ = opts;
        // TODO bundle 5
        return 0;
    }

    pub fn openChildWindow(self: *Window, opts: opts_mod.WindowOptions) !Window {
        // TODO bundle 5: spawn a distinct top-level window. For now just
        // construct another native host with the same options.
        return Window.init(self.ctx.allocator, opts);
    }

    // ---- print / a11y / snapshot / lifecycle (bundle 8) ---------------------

    pub fn print(self: *Window) void {
        _ = self;
        // TODO bundle 8
    }

    pub fn printWithOptions(self: *Window, opts: opts_mod.PrintOptions) opts_mod.PrintError!void {
        _ = self;
        _ = opts;
        // TODO bundle 8
        return error.Unsupported;
    }

    pub fn takeSnapshotPng(self: *Window, path: []const u8) opts_mod.SnapshotError!void {
        _ = self;
        _ = path;
        // TODO bundle 8
        return error.Unsupported;
    }

    pub fn setAccessibilityLabel(self: *Window, label: []const u8) void {
        _ = self;
        _ = label;
        // TODO bundle 8
    }

    pub fn setAccessibilityHelp(self: *Window, text: []const u8) void {
        _ = self;
        _ = text;
        // TODO bundle 8
    }

    pub fn setAccessibilityRoleDescription(self: *Window, text: []const u8) void {
        _ = self;
        _ = text;
        // TODO bundle 8
    }

    pub fn setAccessibilitySubrole(self: *Window, subrole: opts_mod.AccessibilitySubrole) void {
        _ = self;
        _ = subrole;
        // TODO bundle 8
    }

    pub fn terminate(self: *Window) void {
        _ = self;
        // TODO bundle 8
    }

    pub fn close(self: *Window) void {
        _ = self;
        // TODO bundle 8
    }
};

// ---- JS -> host -> Zig trampoline -------------------------------------------

fn bridgeTrampoline(ctx: ?*anyopaque, msg: [*]const u8, len: usize) callconv(.c) void {
    const wc: *WindowCtx = @ptrCast(@alignCast(ctx.?));
    if (wc.on_message) |h| h(wc.on_message_ctx, msg[0..len]);
}

// ---- module-level cookie free fns (bundle 6) --------------------------------

pub fn cookieGet(window: *anyopaque, allocator: std.mem.Allocator, name: []const u8) opts_mod.CookieError!?opts_mod.Cookie {
    _ = window;
    _ = allocator;
    _ = name;
    // TODO bundle 6
    return error.Unsupported;
}

pub fn cookieSet(window: *anyopaque, cookie: opts_mod.Cookie) opts_mod.CookieError!void {
    _ = window;
    _ = cookie;
    // TODO bundle 6
    return error.Unsupported;
}

pub fn cookieDelete(window: *anyopaque, name: []const u8) opts_mod.CookieError!void {
    _ = window;
    _ = name;
    // TODO bundle 6
    return error.Unsupported;
}

pub fn cookieClear(window: *anyopaque) opts_mod.CookieError!void {
    _ = window;
    // TODO bundle 6
    return error.Unsupported;
}

// ---- module-level clipboard free fns (bundle 7) -----------------------------

pub fn clipboardWriteText(window: *anyopaque, text: []const u8) opts_mod.ClipboardError!void {
    _ = window;
    _ = text;
    // TODO bundle 7
    return error.Unsupported;
}

pub fn clipboardReadText(window: *anyopaque, allocator: std.mem.Allocator) opts_mod.ClipboardError!?[]u8 {
    _ = window;
    _ = allocator;
    // TODO bundle 7
    return error.Unsupported;
}

pub fn clipboardWriteHtml(window: *anyopaque, html: []const u8) opts_mod.ClipboardError!void {
    _ = window;
    _ = html;
    // TODO bundle 7
    return error.Unsupported;
}

pub fn clipboardReadHtml(window: *anyopaque, allocator: std.mem.Allocator) opts_mod.ClipboardError!?[]u8 {
    _ = window;
    _ = allocator;
    // TODO bundle 7
    return error.Unsupported;
}

pub fn clipboardWriteImage(window: *anyopaque, png: []const u8) opts_mod.ClipboardError!void {
    _ = window;
    _ = png;
    // TODO bundle 7
    return error.Unsupported;
}

pub fn clipboardReadImage(window: *anyopaque, allocator: std.mem.Allocator) opts_mod.ClipboardError!?[]u8 {
    _ = window;
    _ = allocator;
    // TODO bundle 7
    return error.Unsupported;
}

// ---- module-level toast (bundle 8) ------------------------------------------

pub fn showToast(allocator: std.mem.Allocator, title: []const u8, body: []const u8) ToastError!void {
    _ = allocator;
    _ = title;
    _ = body;
    // TODO bundle 8
    return error.Unsupported;
}
