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
const builtin = @import("builtin");

const opts_mod = @import("options.zig");
const cookies_mod = @import("cookies.zig");
const clipboard_mod = @import("clipboard.zig");
const cookie_codec = @import("win_native/cookie_codec.zig");

// Guard against the backend-mismatch segfault: if this native backend is
// compiled in on Windows, the shared selector in backend.zig MUST have resolved
// to native. Otherwise cookies.zig/clipboard.zig dispatch this exe's native
// WV2Host* into the legacy windows.zig backend, which derefs it and crashes.
// This turns that runtime segfault into a compile error caught on the build host.
comptime {
    if (builtin.os.tag == .windows and !@import("backend.zig").win_backend_native) {
        @compileError("windows_native.zig compiled but backend.win_backend_native is false: " ++
            "cookies/clipboard would dispatch a native WV2Host* into the legacy windows.zig " ++
            "backend and segfault. Declare `pub const verve_win_backend_native = true;` in the root.");
    }
}

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

// Bundle 4: event handlers & lifecycle.
const ResizeFn = *const fn (ctx: ?*anyopaque, w: u32, h: u32) callconv(.c) void;
const FocusFn = *const fn (ctx: ?*anyopaque, focused: c_int) callconv(.c) void;
const CloseFn = *const fn (ctx: ?*anyopaque) callconv(.c) c_int;
const DragDropFn = *const fn (ctx: ?*anyopaque, paths: [*]const u8, len: usize) callconv(.c) void;
extern fn wv2_set_resize_cb(host: *Host, cb: ?ResizeFn, ctx: ?*anyopaque) void;
extern fn wv2_set_focus_cb(host: *Host, cb: ?FocusFn, ctx: ?*anyopaque) void;
extern fn wv2_set_close_cb(host: *Host, cb: ?CloseFn, ctx: ?*anyopaque) void;
extern fn wv2_set_drag_drop_cb(host: *Host, cb: ?DragDropFn, ctx: ?*anyopaque) void;
extern fn wv2_close(host: *Host) void;

// Bundle 5: dialogs & child windows.
extern fn wv2_open_file_dialog(
    host: *Host,
    title: [*]const u8,
    title_len: usize,
    default_path: [*]const u8,
    default_path_len: usize,
    filters: [*]const u8,
    filters_len: usize,
    allow_multiple: c_int,
    buf: [*]u8,
    cap: usize,
) usize;
extern fn wv2_save_file_dialog(
    host: *Host,
    title: [*]const u8,
    title_len: usize,
    default_path: [*]const u8,
    default_path_len: usize,
    default_name: [*]const u8,
    default_name_len: usize,
    filters: [*]const u8,
    filters_len: usize,
    buf: [*]u8,
    cap: usize,
) usize;
extern fn wv2_show_alert(
    host: *Host,
    title: [*]const u8,
    title_len: usize,
    message: [*]const u8,
    message_len: usize,
    style: c_int,
    button_count: usize,
) usize;
extern fn wv2_open_child(
    parent: *Host,
    title: [*]const u8,
    title_len: usize,
    width: c_int,
    height: c_int,
) ?*Host;

// Bundle 6: cookies (ICoreWebView2CookieManager behind the host). Fields cross
// as explicit args; `same_site` is the COREWEBVIEW2_COOKIE_SAME_SITE_KIND int
// produced by cookie_codec. set/delete/clear return 0 on success; get returns
// 1 found / 0 not-found / <0 error and fills the out buffers/scalars.
extern fn wv2_cookie_set(
    host: *Host,
    name: [*]const u8,
    nlen: usize,
    value: [*]const u8,
    vlen: usize,
    domain: [*]const u8,
    dlen: usize,
    path: [*]const u8,
    plen: usize,
    has_expiry: c_int,
    expiry: f64,
    secure: c_int,
    http_only: c_int,
    same_site: c_int,
) c_int;
extern fn wv2_cookie_delete(
    host: *Host,
    name: [*]const u8,
    nlen: usize,
    domain: [*]const u8,
    dlen: usize,
    path: [*]const u8,
    plen: usize,
) c_int;
extern fn wv2_cookie_clear(host: *Host) c_int;
extern fn wv2_cookie_get(
    host: *Host,
    name: [*]const u8,
    nlen: usize,
    value_buf: [*]u8,
    value_cap: usize,
    value_len: *usize,
    domain_buf: [*]u8,
    domain_cap: usize,
    domain_len: *usize,
    path_buf: [*]u8,
    path_cap: usize,
    path_len: *usize,
    has_expiry: *c_int,
    expiry: *f64,
    secure: *c_int,
    http_only: *c_int,
    same_site: *c_int,
) c_int;

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
    on_url_open: ?opts_mod.UrlOpenHandler = null,
    on_url_open_ctx: ?*anyopaque = null,
    on_drag_drop: ?opts_mod.DragDropHandler = null,
    on_drag_drop_ctx: ?*anyopaque = null,
    on_resize: ?opts_mod.ResizeHandler = null,
    on_resize_ctx: ?*anyopaque = null,
    on_focus: ?opts_mod.FocusHandler = null,
    on_focus_ctx: ?*anyopaque = null,
    on_close: ?opts_mod.CloseHandler = null,
    on_close_ctx: ?*anyopaque = null,
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

    /// Per-window cookie store backed by ICoreWebView2CookieManager. The
    /// store's `window` handle is the native host pointer; the module-level
    /// cookie free fns cast it back to `*Host` and call the C ABI.
    pub fn cookies(self: *Window) cookies_mod.CookieStore {
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

    /// Register a deep-link URL handler. As in the legacy backend, the URL is
    /// not routed from in-page navigations (WebView2 NavigationStarting is only
    /// a debug probe there); delivery is via `deliverUrl` (cold-launch argv) —
    /// the handler+ctx are stored Zig-side and invoked directly. `null` clears.
    pub fn setUrlOpenHandler(self: *Window, cb: ?opts_mod.UrlOpenHandler, ctx: ?*anyopaque) void {
        self.ctx.on_url_open = cb;
        self.ctx.on_url_open_ctx = ctx;
    }

    /// Synthesize a URL delivery — call the registered url-open handler with
    /// `url`. Used by templates to feed argv-derived cold-launch URLs through
    /// the same callback a future WM_COPYDATA receiver will drive. Pure Zig: no
    /// C-ABI round trip needed since the handler lives in WindowCtx.
    pub fn deliverUrl(self: *Window, url: []const u8) void {
        if (self.ctx.on_url_open) |cb| cb(self.ctx.on_url_open_ctx, url);
    }

    pub fn setDragDropHandler(self: *Window, cb: ?opts_mod.DragDropHandler, ctx: ?*anyopaque) void {
        self.ctx.on_drag_drop = cb;
        self.ctx.on_drag_drop_ctx = ctx;
        wv2_set_drag_drop_cb(
            self.ctx.host,
            if (cb == null) null else dragDropTrampoline,
            self.ctx,
        );
    }

    pub fn setResizeHandler(self: *Window, cb: ?opts_mod.ResizeHandler, ctx: ?*anyopaque) void {
        self.ctx.on_resize = cb;
        self.ctx.on_resize_ctx = ctx;
        wv2_set_resize_cb(
            self.ctx.host,
            if (cb == null) null else resizeTrampoline,
            self.ctx,
        );
    }

    pub fn setFocusHandler(self: *Window, cb: ?opts_mod.FocusHandler, ctx: ?*anyopaque) void {
        self.ctx.on_focus = cb;
        self.ctx.on_focus_ctx = ctx;
        wv2_set_focus_cb(
            self.ctx.host,
            if (cb == null) null else focusTrampoline,
            self.ctx,
        );
    }

    pub fn setCloseHandler(self: *Window, cb: ?opts_mod.CloseHandler, ctx: ?*anyopaque) void {
        self.ctx.on_close = cb;
        self.ctx.on_close_ctx = ctx;
        // No handler => leave the native close-cb unregistered so WM_CLOSE
        // takes the normal (allow) default; legacy has no veto without a cb.
        wv2_set_close_cb(
            self.ctx.host,
            if (cb == null) null else closeTrampoline,
            self.ctx,
        );
    }

    pub fn colorScheme(self: *Window) opts_mod.ColorScheme {
        return intToColorScheme(wv2_color_scheme(self.ctx.host));
    }

    // ---- dialogs (bundle 5) -------------------------------------------------

    /// Modal open-file dialog via `GetOpenFileNameW` behind the native host.
    /// `pick_directory` is rejected with `error.Unsupported` (the Win32 common
    /// file dialog can't pick directories — legacy returns the same error). On
    /// cancel returns `error.Cancelled`, matching legacy.
    ///
    /// `allow_multiple` currently returns only the leading path (the directory),
    /// matching the legacy `windows.zig` limitation; full `dir\0file1\0...`
    /// unpacking is a follow-up.
    pub fn openFileDialog(self: *Window, allocator: std.mem.Allocator, opts: opts_mod.FileDialogOptions) opts_mod.DialogError![]u8 {
        if (opts.pick_directory) return opts_mod.DialogError.Unsupported;
        return runFileDialog(self, allocator, opts, .open);
    }

    /// Modal save-file dialog via `GetSaveFileNameW` behind the native host.
    /// On cancel returns `error.Cancelled`.
    pub fn saveFileDialog(self: *Window, allocator: std.mem.Allocator, opts: opts_mod.FileDialogOptions) opts_mod.DialogError![]u8 {
        return runFileDialog(self, allocator, opts, .save);
    }

    /// Modal alert via `MessageBoxW`. Win32 doesn't honor arbitrary button
    /// labels — the surface accepts up to three buttons and maps the COUNT onto
    /// MB_OK / MB_YESNO / MB_YESNOCANCEL, then translates the return code back
    /// to the caller's button index (0 = first button). The custom label
    /// strings in `opts.buttons` are ignored on Windows (macOS honors them).
    /// Mapping is identical to the legacy `windows.zig` backend.
    pub fn showAlert(self: *Window, opts: opts_mod.AlertOptions) usize {
        const style: c_int = switch (opts.style) {
            .informational => 0,
            .warning => 1,
            .critical => 2,
        };
        const button_count: usize = if (opts.buttons.len == 0) 1 else opts.buttons.len;
        return wv2_show_alert(
            self.ctx.host,
            opts.title.ptr,
            opts.title.len,
            opts.message.ptr,
            opts.message.len,
            style,
            button_count,
        );
    }

    /// Open a second top-level window in the same app session. Mints a fresh
    /// native host (HWND + WebView2 environment/controller) and wraps it in a
    /// new `WindowCtx`/`Window` exactly like `init` does, wiring the message
    /// handler from `opts`. The caller owns the returned window and must
    /// `deinit` it. Independent window, matching legacy semantics.
    pub fn openChildWindow(self: *Window, opts: opts_mod.WindowOptions) !Window {
        const allocator = self.ctx.allocator;
        const heap = try allocator.create(WindowCtx);
        errdefer allocator.destroy(heap);

        var tbuf: [512]u8 = undefined;
        const src = opts.title[0..@min(opts.title.len, tbuf.len - 1)];
        @memcpy(tbuf[0..src.len], src);
        tbuf[src.len] = 0;

        const host = wv2_open_child(
            self.ctx.host,
            &tbuf,
            src.len,
            @intCast(opts.width),
            @intCast(opts.height),
        ) orelse return error.BackendInit;

        heap.* = .{
            .allocator = allocator,
            .host = host,
            .on_message = opts.on_message,
            .on_message_ctx = opts.on_message_ctx,
        };
        wv2_set_bridge(host, bridgeTrampoline, heap);
        return .{ .ctx = heap };
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
        // Post WM_CLOSE so the standard close path (and any veto handler) runs,
        // matching legacy windows.zig close().
        wv2_close(self.ctx.host);
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

/// WM_SIZE -> app resize handler (client-area width/height).
fn resizeTrampoline(ctx: ?*anyopaque, w: u32, h: u32) callconv(.c) void {
    const wc: *WindowCtx = @ptrCast(@alignCast(ctx.?));
    if (wc.on_resize) |h_fn| h_fn(wc.on_resize_ctx, w, h);
}

/// WM_ACTIVATE -> app focus handler (focused = activated).
fn focusTrampoline(ctx: ?*anyopaque, focused: c_int) callconv(.c) void {
    const wc: *WindowCtx = @ptrCast(@alignCast(ctx.?));
    if (wc.on_focus) |h| h(wc.on_focus_ctx, focused != 0);
}

/// WM_CLOSE veto gate. Returns 1 to allow the close, 0 to veto. With no handler
/// stored, default to allow (1) — though the native side won't register us then.
fn closeTrampoline(ctx: ?*anyopaque) callconv(.c) c_int {
    const wc: *WindowCtx = @ptrCast(@alignCast(ctx.?));
    if (wc.on_close) |h| return if (h(wc.on_close_ctx)) 1 else 0;
    return 1;
}

/// OLE Drop -> app drag-drop handler. `paths` is a UTF-8 buffer of dropped file
/// paths separated by '\0' (no trailing separator). Split into a slice-of-slices
/// pointing into the buffer (valid for the synchronous handler call) and invoke.
fn dragDropTrampoline(ctx: ?*anyopaque, paths: [*]const u8, len: usize) callconv(.c) void {
    const wc: *WindowCtx = @ptrCast(@alignCast(ctx.?));
    const cb = wc.on_drag_drop orelse return;
    const buf = paths[0..len];

    // Count records (NUL-separated, no trailing NUL) and split. Cap at a fixed
    // stack array to avoid an allocation on the synchronous drop path; extra
    // paths beyond the cap are dropped (a multi-thousand-file drop is absurd).
    var slices: [256][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, buf, 0);
    while (it.next()) |seg| {
        if (n >= slices.len) break;
        slices[n] = seg;
        n += 1;
    }
    cb(wc.on_drag_drop_ctx, slices[0..n]);
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
    // NOTE: the heap-retry path can TOCTOU-truncate if the url/title grows
    // between the two getter calls (we size to the first call's length, then
    // min() the second). Spike-acceptable for a synchronous UI-thread getter.
    const heap = try allocator.alloc(u8, len);
    errdefer allocator.free(heap);
    const got = getter(host, heap.ptr, heap.len);
    return heap[0..@min(got, heap.len)];
}

// ---- file-dialog driver (bundle 5) ------------------------------------------

const FileDialogKind = enum { open, save };

/// Shared open/save dialog driver. Builds the `*.ext;*.ext` filter pattern from
/// `opts.allowed_extensions` (empty = allow any), then calls the native host
/// EXACTLY ONCE. A modal dialog must not use the url/title buffer-grow re-call
/// pattern: a second call would pop the dialog again, forcing the user to pick
/// twice. The host caps the path at a 4096-wchar `lpstrFile`; the UTF-8
/// encoding of <=4096 UTF-16 code units is at most ~3 bytes/unit (~12 KB), so a
/// single 16 KB buffer ALWAYS holds the full result in one call. The host
/// copies min(full, cap) and returns the full UTF-8 length (0 on cancel).
fn runFileDialog(
    self: *Window,
    allocator: std.mem.Allocator,
    opts: opts_mod.FileDialogOptions,
    kind: FileDialogKind,
) opts_mod.DialogError![]u8 {
    // Build the ';'-joined pattern string the host wraps under "Allowed types".
    var pattern_buf: std.ArrayList(u8) = .empty;
    defer pattern_buf.deinit(allocator);
    for (opts.allowed_extensions, 0..) |ext, i| {
        if (i > 0) pattern_buf.append(allocator, ';') catch return opts_mod.DialogError.OutOfMemory;
        pattern_buf.appendSlice(allocator, "*.") catch return opts_mod.DialogError.OutOfMemory;
        pattern_buf.appendSlice(allocator, ext) catch return opts_mod.DialogError.OutOfMemory;
    }
    const filters = pattern_buf.items;

    // Single fixed buffer, sized to always hold the host's max output in one
    // call (16 KB > the ~12 KB worst case for the 4096-wchar host cap). The
    // `@min` clamp is belt-and-suspenders; it never actually clamps here.
    var buf: [16384]u8 = undefined;
    const len = callFileDialog(self.ctx.host, opts, filters, kind, &buf, buf.len);
    if (len == 0) return opts_mod.DialogError.Cancelled;
    return allocator.dupe(u8, buf[0..@min(len, buf.len)]) catch opts_mod.DialogError.OutOfMemory;
}

/// Dispatch one open/save call to the matching native host fn.
fn callFileDialog(
    host: *Host,
    opts: opts_mod.FileDialogOptions,
    filters: []const u8,
    kind: FileDialogKind,
    buf: [*]u8,
    cap: usize,
) usize {
    return switch (kind) {
        .open => wv2_open_file_dialog(
            host,
            opts.title.ptr,
            opts.title.len,
            opts.default_path.ptr,
            opts.default_path.len,
            filters.ptr,
            filters.len,
            @intFromBool(opts.allow_multiple),
            buf,
            cap,
        ),
        .save => wv2_save_file_dialog(
            host,
            opts.title.ptr,
            opts.title.len,
            opts.default_path.ptr,
            opts.default_path.len,
            opts.default_name.ptr,
            opts.default_name.len,
            filters.ptr,
            filters.len,
            buf,
            cap,
        ),
    };
}

// ---- module-level cookie free fns (bundle 6) --------------------------------

/// Read the first cookie matching `name`. `window` is the native `*Host`
/// pointer handed out by `cookies()`. The async GetCookies pump runs entirely
/// inside the host (`wv2_cookie_get`); here we just hand it fixed out-buffers
/// and decode the flat result into an owned `Cookie` via `cookie_codec`. The
/// returned slices are owned by `allocator` (CookieStore contract). Returns
/// null when no cookie matches.
pub fn cookieGet(window: *anyopaque, allocator: std.mem.Allocator, name: []const u8) opts_mod.CookieError!?opts_mod.Cookie {
    const host: *Host = @ptrCast(@alignCast(window));

    // Generous fixed buffers — cookie values can be large, but a single 4 KB
    // buffer per field comfortably covers real cookies; the host clamps writes
    // to the cap (no dialog-style grow needed here).
    var value_buf: [4096]u8 = undefined;
    var domain_buf: [4096]u8 = undefined;
    var path_buf: [4096]u8 = undefined;
    var value_len: usize = 0;
    var domain_len: usize = 0;
    var path_len: usize = 0;
    var has_expiry: c_int = 0;
    var expiry: f64 = 0;
    var secure: c_int = 0;
    var http_only: c_int = 0;
    var same_site: c_int = cookie_codec.SAME_SITE_LAX;

    const rc = wv2_cookie_get(
        host,
        name.ptr,
        name.len,
        &value_buf,
        value_buf.len,
        &value_len,
        &domain_buf,
        domain_buf.len,
        &domain_len,
        &path_buf,
        path_buf.len,
        &path_len,
        &has_expiry,
        &expiry,
        &secure,
        &http_only,
        &same_site,
    );
    if (rc < 0) return opts_mod.CookieError.Backend;
    if (rc == 0) return null;

    return try cookie_codec.decodeCookie(
        allocator,
        name,
        value_buf[0..@min(value_len, value_buf.len)],
        domain_buf[0..@min(domain_len, domain_buf.len)],
        path_buf[0..@min(path_len, path_buf.len)],
        has_expiry != 0,
        expiry,
        secure != 0,
        http_only != 0,
        same_site,
    );
}

/// Create-or-update a cookie. `window` is the native `*Host`. SameSite is
/// mapped to the WebView2 kind int by `cookie_codec.sameSiteToInt`; expiry is
/// passed as epoch-seconds with a has_expiry flag (0 = session cookie).
pub fn cookieSet(window: *anyopaque, cookie: opts_mod.Cookie) opts_mod.CookieError!void {
    const host: *Host = @ptrCast(@alignCast(window));
    const rc = wv2_cookie_set(
        host,
        cookie.name.ptr,
        cookie.name.len,
        cookie.value.ptr,
        cookie.value.len,
        cookie.domain.ptr,
        cookie.domain.len,
        cookie.path.ptr,
        cookie.path.len,
        @intFromBool(cookie.expires_unix > 0),
        @floatFromInt(cookie.expires_unix),
        @intFromBool(cookie.secure),
        @intFromBool(cookie.http_only),
        cookie_codec.sameSiteToInt(cookie.same_site),
    );
    if (rc != 0) return opts_mod.CookieError.Backend;
}

/// Delete the first cookie matching `name`. No-op if no match. Domain/path are
/// not narrowed here (matches legacy delete-by-name), so they're passed empty.
pub fn cookieDelete(window: *anyopaque, name: []const u8) opts_mod.CookieError!void {
    const host: *Host = @ptrCast(@alignCast(window));
    const empty: [*]const u8 = name.ptr; // any valid ptr; len 0 => host ignores
    const rc = wv2_cookie_delete(host, name.ptr, name.len, empty, 0, empty, 0);
    if (rc != 0) return opts_mod.CookieError.Backend;
}

/// Remove every cookie in the per-profile store.
pub fn cookieClear(window: *anyopaque) opts_mod.CookieError!void {
    const host: *Host = @ptrCast(@alignCast(window));
    const rc = wv2_cookie_clear(host);
    if (rc != 0) return opts_mod.CookieError.Backend;
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
