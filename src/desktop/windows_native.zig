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

// Bundle 2: window geometry & state.
extern fn wv2_set_title(host: *Host, title: [*]const u8, len: usize) void;
extern fn wv2_set_always_on_top(host: *Host, on: c_int) void;
extern fn wv2_set_opacity(host: *Host, v: f64) void;
extern fn wv2_set_size(host: *Host, w: u32, h: u32) void;
extern fn wv2_set_position(host: *Host, x: i32, y: i32) void;
extern fn wv2_center(host: *Host) void;
extern fn wv2_minimize(host: *Host) void;
extern fn wv2_maximize(host: *Host) void;
extern fn wv2_restore(host: *Host) void;
extern fn wv2_show(host: *Host) void;
extern fn wv2_hide(host: *Host) void;
extern fn wv2_focus(host: *Host) void;
extern fn wv2_set_min_size(host: *Host, w: u32, h: u32) void;
extern fn wv2_set_max_size(host: *Host, w: u32, h: u32) void;
extern fn wv2_scale_factor(host: *Host) f32;
extern fn wv2_is_minimized(host: *Host) c_int;
extern fn wv2_is_maximized(host: *Host) c_int;
extern fn wv2_is_fullscreen(host: *Host) c_int;
extern fn wv2_request_attention(host: *Host, critical: c_int) void;
extern fn wv2_set_resizable(host: *Host, on: c_int) void;
extern fn wv2_set_fullscreen(host: *Host, on: c_int) void;

// Bundle 3: navigation & webview state.
const ColorSchemeFn = *const fn (ctx: ?*anyopaque, scheme: c_int) callconv(.c) void;
extern fn wv2_reload(host: *Host) void;
extern fn wv2_go_back(host: *Host) void;
extern fn wv2_go_forward(host: *Host) void;
extern fn wv2_can_go_back(host: *Host) c_int;
extern fn wv2_can_go_forward(host: *Host) c_int;
extern fn wv2_current_url(host: *Host, buf: [*]u8, cap: usize) usize;
extern fn wv2_current_title(host: *Host, buf: [*]u8, cap: usize) usize;
extern fn wv2_set_zoom(host: *Host, level: f64) void;
extern fn wv2_get_zoom(host: *Host) f64;
extern fn wv2_color_scheme(host: *Host) c_int;
extern fn wv2_set_color_scheme_cb(host: *Host, cb: ?ColorSchemeFn, ctx: ?*anyopaque) void;

/// Toast error set — mirrors the legacy `windows.zig` surface so the
/// module-level `showToast` is signature-compatible.
pub const ToastError = error{ Unsupported, Backend, OutOfMemory };

/// Re-export so downstream drivers (the win-native smoke harness) can name the
/// color-scheme types without a separate `options.zig` import.
pub const ColorScheme = opts_mod.ColorScheme;
pub const ColorSchemeHandler = opts_mod.ColorSchemeHandler;

// ---- Heap-pinned window context ---------------------------------------------

const WindowCtx = struct {
    allocator: std.mem.Allocator,
    host: *Host,
    on_message: ?opts_mod.MessageHandler = null,
    on_message_ctx: ?*anyopaque = null,
    on_color_scheme: ?opts_mod.ColorSchemeHandler = null,
    on_color_scheme_ctx: ?*anyopaque = null,
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
        wv2_set_title(self.ctx.host, title.ptr, title.len);
    }

    pub fn setAlwaysOnTop(self: *Window, on: bool) void {
        wv2_set_always_on_top(self.ctx.host, @intFromBool(on));
    }

    pub fn setOpacity(self: *Window, value: f64) void {
        wv2_set_opacity(self.ctx.host, value);
    }

    pub fn setSize(self: *Window, width: u32, height: u32) void {
        wv2_set_size(self.ctx.host, width, height);
    }

    pub fn setPosition(self: *Window, x: i32, y: i32) void {
        wv2_set_position(self.ctx.host, x, y);
    }

    pub fn center(self: *Window) void {
        wv2_center(self.ctx.host);
    }

    pub fn minimize(self: *Window) void {
        wv2_minimize(self.ctx.host);
    }

    pub fn maximize(self: *Window) void {
        wv2_maximize(self.ctx.host);
    }

    pub fn restore(self: *Window) void {
        wv2_restore(self.ctx.host);
    }

    pub fn setFullscreen(self: *Window, on: bool) void {
        wv2_set_fullscreen(self.ctx.host, @intFromBool(on));
    }

    pub fn show(self: *Window) void {
        wv2_show(self.ctx.host);
    }

    pub fn hide(self: *Window) void {
        wv2_hide(self.ctx.host);
    }

    pub fn focus(self: *Window) void {
        wv2_focus(self.ctx.host);
    }

    pub fn setResizable(self: *Window, on: bool) void {
        wv2_set_resizable(self.ctx.host, @intFromBool(on));
    }

    pub fn setMinSize(self: *Window, width: u32, height: u32) void {
        wv2_set_min_size(self.ctx.host, width, height);
    }

    pub fn setMaxSize(self: *Window, width: u32, height: u32) void {
        wv2_set_max_size(self.ctx.host, width, height);
    }

    pub fn setZoom(self: *Window, level: f64) void {
        wv2_set_zoom(self.ctx.host, level);
    }

    pub fn getZoom(self: *Window) f64 {
        return wv2_get_zoom(self.ctx.host);
    }

    pub fn scaleFactor(self: *Window) f32 {
        return wv2_scale_factor(self.ctx.host);
    }

    pub fn requestAttention(self: *Window, critical: bool) void {
        wv2_request_attention(self.ctx.host, @intFromBool(critical));
    }

    pub fn isMinimized(self: *Window) bool {
        return wv2_is_minimized(self.ctx.host) != 0;
    }

    pub fn isMaximized(self: *Window) bool {
        return wv2_is_maximized(self.ctx.host) != 0;
    }

    pub fn isFullscreen(self: *Window) bool {
        return wv2_is_fullscreen(self.ctx.host) != 0;
    }

    // ---- navigation (bundle 3) ----------------------------------------------

    pub fn reload(self: *Window) void {
        wv2_reload(self.ctx.host);
    }

    pub fn goBack(self: *Window) void {
        wv2_go_back(self.ctx.host);
    }

    pub fn goForward(self: *Window) void {
        wv2_go_forward(self.ctx.host);
    }

    pub fn canGoBack(self: *Window) bool {
        return wv2_can_go_back(self.ctx.host) != 0;
    }

    pub fn canGoForward(self: *Window) bool {
        return wv2_can_go_forward(self.ctx.host) != 0;
    }

    pub fn currentUrl(self: *Window, allocator: std.mem.Allocator) ![]u8 {
        return wv2GetString(self.ctx.host, wv2_current_url, allocator);
    }

    pub fn currentTitle(self: *Window, allocator: std.mem.Allocator) ![]u8 {
        return wv2GetString(self.ctx.host, wv2_current_title, allocator);
    }

    // ---- events / handlers (bundle 4) ---------------------------------------

    pub fn setColorSchemeHandler(self: *Window, cb: ?opts_mod.ColorSchemeHandler, ctx: ?*anyopaque) void {
        self.ctx.on_color_scheme = cb;
        self.ctx.on_color_scheme_ctx = ctx;
        // The native host fires its callback for every registered window; we
        // route through one trampoline that re-reads the per-window ctx.
        wv2_set_color_scheme_cb(
            self.ctx.host,
            if (cb == null) null else colorSchemeTrampoline,
            self.ctx,
        );
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
        return intToColorScheme(wv2_color_scheme(self.ctx.host));
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

/// Map the host's int scheme (0 light, 1 dark, 2 unknown) to the enum.
fn intToColorScheme(v: c_int) opts_mod.ColorScheme {
    return switch (v) {
        0 => .light,
        1 => .dark,
        else => .unknown,
    };
}

/// Fired by the native host on the UI thread when the OS theme toggles. Maps
/// the int and dispatches to the per-window handler stored in `ctx`.
fn colorSchemeTrampoline(ctx: ?*anyopaque, scheme: c_int) callconv(.c) void {
    const wc: *WindowCtx = @ptrCast(@alignCast(ctx.?));
    if (wc.on_color_scheme) |h| h(wc.on_color_scheme_ctx, intToColorScheme(scheme));
}

/// Shared body for currentUrl / currentTitle. The C fn fills a caller buffer
/// and returns the FULL byte length; if it overflows the stack buffer we
/// allocate exactly and call again. Empty (0) on an unavailable webview —
/// matching the legacy "" return.
fn wv2GetString(
    host: *Host,
    getter: *const fn (*Host, [*]u8, usize) callconv(.c) usize,
    allocator: std.mem.Allocator,
) ![]u8 {
    var stack: [2048]u8 = undefined;
    const len = getter(host, &stack, stack.len);
    if (len <= stack.len) return allocator.dupe(u8, stack[0..len]);
    const heap = try allocator.alloc(u8, len);
    errdefer allocator.free(heap);
    const got = getter(host, heap.ptr, heap.len);
    return heap[0..@min(got, heap.len)];
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
