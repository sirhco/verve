//! windows_native.zig — Windows desktop backend backed by a native C++
//! WebView2 host behind a flat C ABI (src/desktop/win_native/host.h).
//!
//! This is the sole Windows desktop backend (the 4129-line pure-Zig
//! hand-rolled COM backend in `windows.zig` was deleted in the Bundle 9
//! cutover). It mirrors the `Window` surface so the `window.zig` conformance
//! check is satisfied; `backend.zig` selects it unconditionally on Windows.

const std = @import("std");
const builtin = @import("builtin");

const opts_mod = @import("options.zig");
const router = @import("asset_router.zig");
const ipc = @import("ipc.zig");
const cookies_mod = @import("cookies.zig");
const clipboard_mod = @import("clipboard.zig");
const cookie_codec = @import("win_native/cookie_codec.zig");
const clipboard_codec = @import("win_native/clipboard_codec.zig");
const toast_codec = @import("win_native/toast_codec.zig");

// ---- Flat C ABI to the native WebView2 host ---------------------------------

const Host = opaque {};
const BridgeFn = *const fn (ctx: ?*anyopaque, msg: [*]const u8, len: usize) callconv(.c) void;

extern fn wv2_create(title: [*:0]const u8, width: c_int, height: c_int) ?*Host;
extern fn wv2_load_html(host: *Host, html: [*]const u8, len: usize) void;
extern fn wv2_load_url(host: *Host, url: [*]const u8, len: usize) void;
extern fn wv2_eval_js(host: *Host, js: [*]const u8, len: usize) void;
extern fn wv2_set_bridge(host: *Host, cb: BridgeFn, ctx: ?*anyopaque) void;
extern fn wv2_add_user_script(host: *Host, utf8: [*]const u8, len: usize) void;
extern fn wv2_run(host: *Host) void;
extern fn wv2_destroy(host: *Host) void;

const SchemeCb = *const fn (
    ctx: ?*anyopaque,
    path: [*]const u8,
    path_len: usize,
    out_bytes: *[*]const u8,
    out_len: *usize,
    out_ct: *[*:0]const u8,
) callconv(.c) c_int;
extern fn wv2_set_scheme_handler(
    host: *Host,
    scheme: [*]const u8,
    scheme_len: usize,
    cb: SchemeCb,
    ctx: ?*anyopaque,
) void;

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

// Tray dispatch (desktop.tray). The host WndProc forwards WM_COMMAND tray-block
// ids and WM_VERVE_TRAY to these callbacks; wv2_hwnd exposes the window handle
// the tray layer anchors its icon/menu to.
const TrayCommandFn = *const fn (hwnd: ?*anyopaque, cmd_id: u16) callconv(.c) c_int;
const TrayMessageFn = *const fn (hwnd: ?*anyopaque, wparam: usize, lparam: isize) callconv(.c) void;
extern fn wv2_set_tray_dispatch(cmd: ?TrayCommandFn, msg: ?TrayMessageFn) void;
extern fn wv2_hwnd(host: *Host) ?*anyopaque;

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

// Bundle 7: clipboard. Text is CF_UNICODETEXT (host widens UTF-8). HTML crosses
// as the finished CF_HTML blob built by clipboard_codec (host SetClipboardData's
// the registered "HTML Format"); read returns raw CF_HTML bytes for the codec to
// extract. Images cross as PNG bytes; the host WIC-transcodes PNG<->CF_DIBV5.
// write fns return 0 on success, nonzero on error; read fns return the FULL byte
// length (buffer-grow contract), 0 = no matching format on the clipboard.
extern fn wv2_clip_write_text(host: *Host, utf8: [*]const u8, len: usize) c_int;
extern fn wv2_clip_read_text(host: *Host, buf: [*]u8, cap: usize) usize;
extern fn wv2_clip_write_html(host: *Host, cf_html: [*]const u8, len: usize) c_int;
extern fn wv2_clip_read_html(host: *Host, buf: [*]u8, cap: usize) usize;
extern fn wv2_clip_write_image(host: *Host, png: [*]const u8, len: usize) c_int;
extern fn wv2_clip_read_image(host: *Host, buf: [*]u8, cap: usize) usize;

// ---- Bundle 8: print / a11y / snapshot / lifecycle --------------------------
// print: 0 ok, 1 not-ready, 2 unsupported-runtime, 3 backend-fail.
// snapshot: 0 ok, 1 unsupported, 2 capture-fail, 3 encode-fail, 4 write-fail.
extern fn wv2_print(host: *Host, dialog_kind: c_int) c_int;
extern fn wv2_set_a11y_label(host: *Host, text: [*]const u8, len: usize) void;
extern fn wv2_set_a11y_help(host: *Host, text: [*]const u8, len: usize) void;
extern fn wv2_set_a11y_role_desc(host: *Host, text: [*]const u8, len: usize) void;
extern fn wv2_set_a11y_subrole(host: *Host, subrole: c_int) void;
extern fn wv2_snapshot_png(host: *Host, path: [*]const u8, len: usize) c_int;
extern fn wv2_terminate(host: *Host) void;

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
    opts: opts_mod.WindowOptions = .{},
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
    /// Holds the last dev-mode Resolved from schemeCallback so its allocated
    /// bytes stay alive until the C++ host copies them into the IStream.
    /// Freed on the next scheme request or on deinit.
    last_scheme_resolved: ?router.Resolved = null,
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
            .opts = opts,
            .on_message = opts.on_message,
            .on_message_ctx = opts.on_message_ctx,
        };
        wv2_set_bridge(host, bridgeTrampoline, heap);
        // Document-start IPC shim (window.verve.{send,request,onMessage,_dispatch}).
        // Without this, the page has no IPC surface on Windows — matches macOS's
        // WKUserScript injection of the same source.
        wv2_add_user_script(host, ipc.shim_js.ptr, ipc.shim_js.len);
        wv2_set_scheme_handler(host, opts.scheme.ptr, opts.scheme.len, schemeCallback, heap);

        var url_buf: [512]u8 = undefined;
        const initial_url = std.fmt.bufPrint(&url_buf, "{s}://app/{s}", .{ opts.scheme, opts.initial_path }) catch
            return error.OutOfMemory;
        wv2_load_url(host, initial_url.ptr, initial_url.len);

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

    /// Per-window system-clipboard handle backed by the Win32 clipboard behind
    /// the native host. The handle's `window` pointer is the native `*Host`; the
    /// module-level clipboard free fns cast it back and call the C ABI.
    pub fn clipboard(self: *Window) clipboard_mod.Clipboard {
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
            .opts = opts,
            .on_message = opts.on_message,
            .on_message_ctx = opts.on_message_ctx,
        };
        wv2_set_bridge(host, bridgeTrampoline, heap);
        // Document-start IPC shim (window.verve.{send,request,onMessage,_dispatch}).
        // Without this, the page has no IPC surface on Windows — matches macOS's
        // WKUserScript injection of the same source.
        wv2_add_user_script(host, ipc.shim_js.ptr, ipc.shim_js.len);
        wv2_set_scheme_handler(host, opts.scheme.ptr, opts.scheme.len, schemeCallback, heap);

        var url_buf: [512]u8 = undefined;
        const initial_url = std.fmt.bufPrint(&url_buf, "{s}://app/{s}", .{ opts.scheme, opts.initial_path }) catch
            return error.OutOfMemory;
        wv2_load_url(host, initial_url.ptr, initial_url.len);

        return .{ .ctx = heap };
    }

    // ---- print / a11y / snapshot / lifecycle (bundle 8) ---------------------

    /// Trigger the platform print dialog. Thin wrapper over
    /// `printWithOptions(.{})`; swallows the error to match the legacy
    /// `windows.zig` surface.
    pub fn print(self: *Window) void {
        self.printWithOptions(.{}) catch {};
    }

    /// Native print dialog via `ICoreWebView2_16::ShowPrintUI` (in the C++
    /// host). Returns `error.Unsupported` when the Edge WebView2 runtime is
    /// older than ~v111 (the QI for `ICoreWebView2_16` fails).
    ///
    /// `opts.copies`, `opts.pages`, and `opts.printer_name` are advisory on
    /// Windows — `ShowPrintUI` takes no PrintSettings struct, so the user picks
    /// values in the dialog. A warning is logged when those fields are
    /// non-default, matching the legacy backend.
    pub fn printWithOptions(self: *Window, opts: opts_mod.PrintOptions) opts_mod.PrintError!void {
        if (opts.copies > 1 or opts.pages != null or opts.printer_name != null) {
            std.log.warn("verve.desktop[windows]: opts.copies/pages/printer_name are advisory — ShowPrintUI doesn't accept PrintSettings. User picks in the dialog.", .{});
        }
        const kind: c_int = switch (opts.kind) {
            .default, .browser => 0,
            .system => 1,
        };
        return switch (wv2_print(self.ctx.host, kind)) {
            0 => {},
            2 => opts_mod.PrintError.Unsupported,
            else => opts_mod.PrintError.Backend, // 1 not-ready, 3 ShowPrintUI fail
        };
    }

    /// Capture the WebView2 contents as PNG via `ICoreWebView2::CapturePreview`
    /// (in the C++ host), then write the PNG bytes to `path`. The host pumps the
    /// async completion with a nested message loop — safe because bridge
    /// handlers run from WndProc, off the WebView2 event stack.
    pub fn takeSnapshotPng(self: *Window, path: []const u8) opts_mod.SnapshotError!void {
        return switch (wv2_snapshot_png(self.ctx.host, path.ptr, path.len)) {
            0 => {},
            1 => opts_mod.SnapshotError.Unsupported,
            2 => opts_mod.SnapshotError.CaptureFailed,
            3 => opts_mod.SnapshotError.EncodeFailed,
            else => opts_mod.SnapshotError.WriteFailed, // 4
        };
    }

    /// The window's accessible Name is its window text, so the label channel
    /// delegates to `SetWindowTextW` in the host — same contract as legacy
    /// `windows.zig` (which routes the label through `setTitle`).
    pub fn setAccessibilityLabel(self: *Window, label: []const u8) void {
        wv2_set_a11y_label(self.ctx.host, label.ptr, label.len);
    }

    /// Publish UIA help text (`UIA_HelpTextPropertyId`) for the window root.
    /// The native host stores the string on its server-side
    /// `IRawElementProviderSimple` and Narrator/NVDA read it on the next UIA
    /// query — ports the legacy `windows.zig` provider, not advisory.
    pub fn setAccessibilityHelp(self: *Window, text: []const u8) void {
        wv2_set_a11y_help(self.ctx.host, text.ptr, text.len);
    }

    /// Override the spoken role name (`UIA_LocalizedControlTypePropertyId`)
    /// through the native host's server-side UIA provider. Ports legacy
    /// `windows.zig` `setAccessibilityRoleDescription`.
    pub fn setAccessibilityRoleDescription(self: *Window, text: []const u8) void {
        wv2_set_a11y_role_desc(self.ctx.host, text.ptr, text.len);
    }

    /// Set the window's accessibility subrole. `dialog` / `system_dialog`
    /// surface as `UIA_IsDialogPropertyId == true` through the native host's
    /// UIA provider so assistive tech announces the window as a dialog. Ports
    /// legacy `windows.zig` `setAccessibilitySubrole`.
    pub fn setAccessibilitySubrole(self: *Window, subrole: opts_mod.AccessibilitySubrole) void {
        wv2_set_a11y_subrole(self.ctx.host, @intFromEnum(subrole));
    }

    /// Quit the app: posts `WM_QUIT` (via `PostQuitMessage(0)` in the host),
    /// unwinding the `run()` message loop. Matches legacy `windows.zig`.
    pub fn terminate(self: *Window) void {
        wv2_terminate(self.ctx.host);
    }

    pub fn close(self: *Window) void {
        // Post WM_CLOSE so the standard close path (and any veto handler) runs,
        // matching legacy windows.zig close().
        wv2_close(self.ctx.host);
    }
};

// ---- Tray dispatch surface (consumed by desktop/tray.zig) -------------------
//
// `tray.zig` resolves the Windows backend through `backend.zig`'s `impl` and
// expects these three names (the legacy `windows.zig` exposed the same surface):
//   - `WM_VERVE_TRAY`        : the NOTIFYICONDATAW callback message constant.
//   - `tray_dispatch_command`/`tray_dispatch_message`: forwarders it installs on
//     `Tray.init`; the native host's WndProc invokes them via C trampolines.
//   - `hwndOf`               : the host window's HWND for icon/menu anchoring.

/// Tray-icon callback message — must equal the C++ host's `WM_VERVE_TRAY`
/// (WM_USER + 100). `tray.zig` writes it into `NOTIFYICONDATAW.uCallbackMessage`.
pub const WM_VERVE_TRAY: u32 = 0x0400 + 100; // WM_USER + 100

/// Forwarders installed by `tray.zig` once `Tray.init` runs. The C++ host's
/// WndProc calls the C trampolines below, which fan out to these. Null until a
/// tray exists in this process (v1 single-tray-per-process).
pub var tray_dispatch_command: ?*const fn (hwnd: ?*anyopaque, cmd_id: u16) bool = null;
pub var tray_dispatch_message: ?*const fn (hwnd: ?*anyopaque, wparam: usize, lparam: isize) void = null;

fn trayCommandTrampoline(hwnd: ?*anyopaque, cmd_id: u16) callconv(.c) c_int {
    if (tray_dispatch_command) |dispatch| return if (dispatch(hwnd, cmd_id)) 1 else 0;
    return 0;
}

fn trayMessageTrampoline(hwnd: ?*anyopaque, wparam: usize, lparam: isize) callconv(.c) void {
    if (tray_dispatch_message) |dispatch| dispatch(hwnd, wparam, lparam);
}

var tray_dispatch_registered: bool = false;

/// Register the C trampolines with the native host (idempotent). Called from
/// `hwndOf`, which `tray.zig` invokes during `Tray.init` before any tray message
/// can arrive, so the forwarders are live by the time Shell32 fires WM_VERVE_TRAY.
fn ensureTrayDispatchRegistered() void {
    if (tray_dispatch_registered) return;
    wv2_set_tray_dispatch(&trayCommandTrampoline, &trayMessageTrampoline);
    tray_dispatch_registered = true;
}

/// The host window's HWND, for `tray.zig` to anchor its NOTIFYICONDATAW icon and
/// TrackPopupMenu. Registering the dispatch trampolines here piggybacks on the
/// fact that `tray.zig` calls this during `Tray.init`.
pub fn hwndOf(window: *Window) ?*anyopaque {
    ensureTrayDispatchRegistered();
    return wv2_hwnd(window.ctx.host);
}

// ---- JS -> host -> Zig trampoline -------------------------------------------

fn bridgeTrampoline(ctx: ?*anyopaque, msg: [*]const u8, len: usize) callconv(.c) void {
    const wc: *WindowCtx = @ptrCast(@alignCast(ctx.?));
    const payload = msg[0..len];
    // Intercept the IPC shim's title-sync marker before forwarding to the user's
    // MessageHandler — the shim polls document.title and posts this prefix on
    // change. Mirrors the macOS trampoline.
    const title_prefix = "__verve_title:";
    if (std.mem.startsWith(u8, payload, title_prefix)) {
        const title = payload[title_prefix.len..];
        wv2_set_title(wc.host, title.ptr, title.len);
        return;
    }
    if (wc.on_message) |h| h(wc.on_message_ctx, payload);
}

fn schemeCallback(
    ctx: ?*anyopaque,
    path_ptr: [*]const u8,
    path_len: usize,
    out_bytes: *[*]const u8,
    out_len: *usize,
    out_ct: *[*:0]const u8,
) callconv(.c) c_int {
    const wc: *WindowCtx = @ptrCast(@alignCast(ctx orelse return 0));
    const path = path_ptr[0..path_len];

    // Free any previously allocated dev-mode response. The C++ host calls
    // SHCreateMemStream (copies bytes) before returning from the event
    // handler, so the prior response is safe to release on the next call.
    if (wc.last_scheme_resolved) |prev| {
        prev.deinit(wc.allocator);
        wc.last_scheme_resolved = null;
    }

    const resolved = blk: {
        if (wc.opts.dev_assets) |dev| {
            break :blk router.resolveWithFallback(
                wc.allocator,
                dev.io,
                wc.opts.assets,
                path,
                dev.dir,
            ) catch return 0;
        }
        break :blk router.resolve(wc.opts.assets, path) catch return 0;
    };

    if (resolved.owned) wc.last_scheme_resolved = resolved;

    out_bytes.* = resolved.bytes.ptr;
    out_len.* = resolved.bytes.len;
    // content_type is always a Zig string literal from guessContentType —
    // NUL-terminated in the binary even though the slice length excludes the NUL.
    out_ct.* = @ptrCast(resolved.content_type.ptr);
    return 1;
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
//
// `window` is the native `*Host` pointer handed out by `clipboard()`. The Win32
// clipboard work (Open/Empty/Set/Get/Close, CF_UNICODETEXT, the registered "HTML
// Format", CF_DIBV5 via WIC) all runs inside the native host; here we just widen
// to / narrow from the C ABI. The CF_HTML wrap/extract is pure Zig in
// clipboard_codec — windows_native ships the codec's bytes across the seam.
//
// Read fns use the buffer-grow contract: a stack buffer first, re-alloc + re-read
// only if the host reports a full length beyond the stack capacity. The host
// returns 0 when the clipboard holds no matching format -> we surface `null`
// (matching the legacy backend: null vs error.Unsupported).

/// Run a native read-into-buffer getter with the buffer-grow contract. Returns an
/// owned slice (caller frees), or `null` when the getter reports length 0. The
/// first attempt uses a `stack_cap`-byte stack buffer; if the host's full length
/// exceeds it, one heap re-read sizes to the full length.
fn clipReadOwned(
    comptime stack_cap: usize,
    host: *Host,
    getter: *const fn (*Host, [*]u8, usize) callconv(.c) usize,
    allocator: std.mem.Allocator,
) opts_mod.ClipboardError!?[]u8 {
    var stack: [stack_cap]u8 = undefined;
    const full = getter(host, &stack, stack.len);
    if (full == 0) return null;
    if (full <= stack.len) {
        return allocator.dupe(u8, stack[0..full]) catch return error.OutOfMemory;
    }
    const heap = allocator.alloc(u8, full) catch return error.OutOfMemory;
    errdefer allocator.free(heap);
    const got = getter(host, heap.ptr, heap.len);
    if (got == 0) {
        allocator.free(heap);
        return null;
    }
    if (got < heap.len) return allocator.realloc(heap, got) catch return error.OutOfMemory;
    return heap;
}

pub fn clipboardWriteText(window: *anyopaque, text: []const u8) opts_mod.ClipboardError!void {
    const host: *Host = @ptrCast(@alignCast(window));
    if (wv2_clip_write_text(host, text.ptr, text.len) != 0) return error.Backend;
}

pub fn clipboardReadText(window: *anyopaque, allocator: std.mem.Allocator) opts_mod.ClipboardError!?[]u8 {
    const host: *Host = @ptrCast(@alignCast(window));
    return clipReadOwned(4096, host, wv2_clip_read_text, allocator);
}

pub fn clipboardWriteHtml(window: *anyopaque, html: []const u8) opts_mod.ClipboardError!void {
    const host: *Host = @ptrCast(@alignCast(window));
    // Build the CF_HTML envelope (header offsets back-patched) in pure Zig, then
    // hand the finished bytes to the host to SetClipboardData under "HTML Format".
    const cf_html = try clipboard_codec.wrapCfHtml(allocatorForHtml(), html);
    defer allocatorForHtml().free(cf_html);
    if (wv2_clip_write_html(host, cf_html.ptr, cf_html.len) != 0) return error.Backend;
}

pub fn clipboardReadHtml(window: *anyopaque, allocator: std.mem.Allocator) opts_mod.ClipboardError!?[]u8 {
    const host: *Host = @ptrCast(@alignCast(window));
    // Pull the raw CF_HTML bytes off the clipboard, then extract the inner
    // fragment via the codec. `null` propagates both for "no HTML on clipboard"
    // and "bytes weren't valid CF_HTML".
    const raw = (try clipReadOwned(8192, host, wv2_clip_read_html, allocator)) orelse return null;
    defer allocator.free(raw);
    return clipboard_codec.extractCfHtmlFragment(allocator, raw);
}

pub fn clipboardWriteImage(window: *anyopaque, png: []const u8) opts_mod.ClipboardError!void {
    const host: *Host = @ptrCast(@alignCast(window));
    if (png.len == 0) return error.Backend;
    if (wv2_clip_write_image(host, png.ptr, png.len) != 0) return error.Backend;
}

pub fn clipboardReadImage(window: *anyopaque, allocator: std.mem.Allocator) opts_mod.ClipboardError!?[]u8 {
    const host: *Host = @ptrCast(@alignCast(window));
    // Images are large — start with a generous 64 KB stack buffer, grow once if
    // the encoded PNG is bigger.
    return clipReadOwned(64 * 1024, host, wv2_clip_read_image, allocator);
}

/// CF_HTML wrap allocates a transient buffer that never escapes the write call.
/// The clipboard ABI exposes no allocator, so use the process page allocator for
/// this scratch (freed immediately after the host copies it).
fn allocatorForHtml() std.mem.Allocator {
    return std.heap.page_allocator;
}

// ---- module-level toast (bundle 8) ------------------------------------------
//
// Modern Action Center toast (vs. the legacy Shell_NotifyIconW balloon). This
// is window-independent, so it lives outside the C++ host: it is a hand-rolled
// WinRT/COM path identical to the legacy `windows.zig` toast, driven through
// `vtSlot` over the vendored WinRT vtables. Three prerequisites the balloon
// path lacks:
//   1. An AUMID (`SetCurrentProcessExplicitAppUserModelID`).
//   2. A Start-menu `.lnk` carrying that AUMID (`System.AppUserModel.ID`) — the
//      shell drops toasts from unpackaged apps without it. Created once.
//   3. WinRT activation: XmlDocument -> ToastGeneric -> ToastNotificationManager
//      -> IToastNotifier::Show.
//
// WinRT activation + HSTRING live in combase.dll, but zig's bundled mingw ships
// no x86_64 combase import lib — only the split API-set stubs. linkWinNative
// links the two carrying our symbols (api-ms-win-core-winrt-l1-1-0 / -string).
// Proven to cross-compile from macOS by the legacy backend (commit 76a7374).

// --- Win32 / WinRT FFI types (local; mirror windows.zig) ---
const HRESULT = c_long;
const DWORD = c_ulong;
const BOOL = c_int;
const HMODULE = ?*opaque {};
const GUID = extern struct { Data1: u32, Data2: u16, Data3: u16, Data4: [8]u8 };
const IID = GUID;
/// A bare COM/WinRT object: a pointer to its vtable. We index it via `vtSlot`.
const ComObj = extern struct { lpVtbl: *const anyopaque };

extern "api-ms-win-core-winrt-l1-1-0" fn RoInitialize(init_type: c_int) callconv(.winapi) HRESULT;
extern "api-ms-win-core-winrt-string-l1-1-0" fn WindowsCreateString(src: [*]const u16, len: u32, out: *?*anyopaque) callconv(.winapi) HRESULT;
extern "api-ms-win-core-winrt-string-l1-1-0" fn WindowsDeleteString(str: ?*anyopaque) callconv(.winapi) HRESULT;
extern "api-ms-win-core-winrt-l1-1-0" fn RoGetActivationFactory(class_id: ?*anyopaque, iid: *const IID, factory: *?*anyopaque) callconv(.winapi) HRESULT;
extern "api-ms-win-core-winrt-l1-1-0" fn RoActivateInstance(class_id: ?*anyopaque, instance: *?*anyopaque) callconv(.winapi) HRESULT;
extern "shell32" fn SetCurrentProcessExplicitAppUserModelID(id: [*:0]const u16) callconv(.winapi) HRESULT;
extern "kernel32" fn GetModuleFileNameW(module: HMODULE, buf: [*]u16, size: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: [*]u16, size: DWORD) callconv(.winapi) DWORD;
extern "shlwapi" fn PathFileExistsW(path: [*:0]const u16) callconv(.winapi) BOOL;
extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, coinit: DWORD) callconv(.winapi) HRESULT;
extern "ole32" fn CoCreateInstance(
    rclsid: *const GUID,
    unk_outer: ?*anyopaque,
    cls_context: DWORD,
    riid: *const GUID,
    ppv: *?*anyopaque,
) callconv(.winapi) HRESULT;

const RO_INIT_SINGLETHREADED: c_int = 0;
const CLSCTX_INPROC_SERVER: DWORD = 1;
const COINIT_APARTMENTTHREADED: DWORD = 2;

// WinRT runtime-method slots (IInspectable methods occupy slots 3-5).
const SLOT_XmlDocumentIO_LoadXml: usize = 6;
const SLOT_ToastMgr_CreateToastNotifierWithId: usize = 7;
const SLOT_ToastFactory_CreateToastNotification: usize = 6;
const SLOT_ToastNotifier_Show: usize = 6;
// Shortcut COM slots (classic IUnknown-rooted interfaces).
const SLOT_ShellLink_SetPath: usize = 20;
const SLOT_PropertyStore_SetValue: usize = 6;
const SLOT_PropertyStore_Commit: usize = 7;
const SLOT_PersistFile_Save: usize = 6;

const IID_IXmlDocument: GUID = .{ .Data1 = 0xf7f3a506, .Data2 = 0x1e87, .Data3 = 0x42d6, .Data4 = .{ 0xbc, 0xfb, 0xb8, 0xc8, 0x09, 0xfa, 0x54, 0x94 } };
const IID_IXmlDocumentIO: GUID = .{ .Data1 = 0x6cd0e74e, .Data2 = 0xee65, .Data3 = 0x4489, .Data4 = .{ 0x9e, 0xbf, 0xca, 0x43, 0xe8, 0x7b, 0xa6, 0x37 } };
const IID_IToastNotificationManagerStatics: GUID = .{ .Data1 = 0x50ac103f, .Data2 = 0xd235, .Data3 = 0x4598, .Data4 = .{ 0xbb, 0xef, 0x98, 0xfe, 0x4d, 0x1a, 0x3a, 0xd4 } };
const IID_IToastNotificationFactory: GUID = .{ .Data1 = 0x04124b20, .Data2 = 0x82c6, .Data3 = 0x4229, .Data4 = .{ 0xb1, 0x09, 0xfd, 0x9e, 0xd4, 0x66, 0x2b, 0x53 } };
const IID_IToastNotifier: GUID = .{ .Data1 = 0x75927b93, .Data2 = 0x03f3, .Data3 = 0x41ec, .Data4 = .{ 0x91, 0xd3, 0x6e, 0x5b, 0xac, 0x1b, 0x38, 0xe7 } };

const CLSID_ShellLink: GUID = .{ .Data1 = 0x00021401, .Data2 = 0x0000, .Data3 = 0x0000, .Data4 = .{ 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } };
const IID_IShellLinkW: GUID = .{ .Data1 = 0x000214f9, .Data2 = 0x0000, .Data3 = 0x0000, .Data4 = .{ 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } };
const IID_IPersistFile: GUID = .{ .Data1 = 0x0000010b, .Data2 = 0x0000, .Data3 = 0x0000, .Data4 = .{ 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } };
const IID_IPropertyStore: GUID = .{ .Data1 = 0x886d8eeb, .Data2 = 0x8cf2, .Data3 = 0x4446, .Data4 = .{ 0x8d, 0x02, 0xcd, 0xba, 0x1d, 0xbd, 0xcf, 0x99 } };

const VT_LPWSTR: u16 = 31;
const PROPERTYKEY = extern struct { fmtid: GUID, pid: u32 };
const PROPVARIANT = extern struct {
    vt: u16,
    r1: u16 = 0,
    r2: u16 = 0,
    r3: u16 = 0,
    val: usize = 0,
    pad: u64 = 0,
};
// System.AppUserModel.ID
const PKEY_AppUserModel_ID: PROPERTYKEY = .{
    .fmtid = .{ .Data1 = 0x9f4c2855, .Data2 = 0x9f79, .Data3 = 0x4b39, .Data4 = .{ 0xa8, 0xd0, 0xe1, 0xd4, 0x2d, 0xe1, 0xd5, 0xf3 } },
    .pid = 5,
};

/// Fetch vtable slot `slot` from `lpVtbl` as a typed fn pointer.
fn vtSlot(comptime Fn: type, lpVtbl: *const anyopaque, slot: usize) Fn {
    const arr: [*]const *const anyopaque = @ptrCast(@alignCast(lpVtbl));
    return @ptrCast(arr[slot]);
}

/// IUnknown::Release at slot 2.
fn releaseRef(obj: *ComObj) void {
    const Release = vtSlot(*const fn (*ComObj) callconv(.winapi) c_ulong, obj.lpVtbl, 2);
    _ = Release(obj);
}

/// IUnknown::QueryInterface at slot 0.
fn comQueryInterface(obj: *ComObj, iid: *const IID, out: *?*anyopaque) HRESULT {
    const QI = vtSlot(*const fn (*ComObj, *const IID, *?*anyopaque) callconv(.winapi) HRESULT, obj.lpVtbl, 0);
    return QI(obj, iid, out);
}

/// Create an HSTRING from a comptime ASCII class id. Caller deletes.
fn hstr(comptime s: []const u8) ?*anyopaque {
    const w = std.unicode.utf8ToUtf16LeStringLiteral(s);
    var h: ?*anyopaque = null;
    if (WindowsCreateString(w, w.len, &h) < 0) return null;
    return h;
}

fn winrtString(w: []const u16) ?*anyopaque {
    var h: ?*anyopaque = null;
    if (WindowsCreateString(w.ptr, @intCast(w.len), &h) < 0) return null;
    return h;
}

/// `RoActivateInstance` a runtime class by comptime id. Caller Releases.
fn roActivate(comptime class: []const u8) ?*ComObj {
    const id = hstr(class) orelse return null;
    defer _ = WindowsDeleteString(id);
    var p: ?*anyopaque = null;
    if (RoActivateInstance(id, &p) < 0 or p == null) return null;
    return @ptrCast(@alignCast(p));
}

fn appendW(dst: []u16, i: *usize, src: []const u16) bool {
    if (i.* + src.len >= dst.len) return false;
    @memcpy(dst[i.*..][0..src.len], src);
    i.* += src.len;
    return true;
}

/// The running exe's basename (no dir, `.exe` stripped) as UTF-16 into `out`.
/// Returns the length or null on failure. Drives the per-app AUMID + shortcut.
fn exeBaseNameW(out: []u16) ?usize {
    var exe: [512]u16 = undefined;
    const n = GetModuleFileNameW(null, &exe, exe.len);
    if (n == 0 or n >= exe.len) return null;
    var start: usize = 0;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        if (exe[k] == '\\' or exe[k] == '/') start = k + 1;
    }
    var end: usize = n;
    if (end >= start + 4) {
        const tail = exe[end - 4 .. end];
        if (tail[0] == '.' and (tail[1] | 0x20) == 'e' and (tail[2] | 0x20) == 'x' and (tail[3] | 0x20) == 'e') {
            end -= 4;
        }
    }
    const len = end - start;
    if (len == 0 or len >= out.len) return null;
    @memcpy(out[0..len], exe[start..end]);
    return len;
}

/// Re-resolve the full exe path as a NUL-terminated UTF-16 buffer for the
/// shortcut target. Returns a process-static buffer; falls back to empty.
var g_exe_path_buf: [512]u16 = undefined;
fn exeFullPathZ() [*:0]const u16 {
    const n = GetModuleFileNameW(null, &g_exe_path_buf, g_exe_path_buf.len);
    if (n == 0 or n >= g_exe_path_buf.len) {
        g_exe_path_buf[0] = 0;
    } else {
        g_exe_path_buf[n] = 0;
    }
    return @ptrCast(&g_exe_path_buf);
}

/// Create the AUMID Start-menu shortcut once (idempotent — skips if the `.lnk`
/// already exists). Best-effort. `*_z` are NUL-terminated UTF-16.
fn ensureAumidShortcut(exe_z: [*:0]const u16, aumid_z: [*:0]const u16, lnk_z: [*:0]const u16) void {
    if (PathFileExistsW(lnk_z) != 0) return;
    _ = CoInitializeEx(null, COINIT_APARTMENTTHREADED);

    var sl_p: ?*anyopaque = null;
    if (CoCreateInstance(&CLSID_ShellLink, null, CLSCTX_INPROC_SERVER, &IID_IShellLinkW, &sl_p) < 0 or sl_p == null) return;
    const sl: *ComObj = @ptrCast(@alignCast(sl_p));
    defer releaseRef(sl);

    const SetPath = vtSlot(*const fn (*ComObj, [*:0]const u16) callconv(.winapi) HRESULT, sl.lpVtbl, SLOT_ShellLink_SetPath);
    if (SetPath(sl, exe_z) < 0) return;

    var ps_p: ?*anyopaque = null;
    if (comQueryInterface(sl, &IID_IPropertyStore, &ps_p) < 0 or ps_p == null) return;
    const ps: *ComObj = @ptrCast(@alignCast(ps_p));
    defer releaseRef(ps);

    var pv: PROPVARIANT = .{ .vt = VT_LPWSTR, .val = @intFromPtr(aumid_z) };
    const SetValue = vtSlot(*const fn (*ComObj, *const PROPERTYKEY, *const PROPVARIANT) callconv(.winapi) HRESULT, ps.lpVtbl, SLOT_PropertyStore_SetValue);
    if (SetValue(ps, &PKEY_AppUserModel_ID, &pv) < 0) return;
    const Commit = vtSlot(*const fn (*ComObj) callconv(.winapi) HRESULT, ps.lpVtbl, SLOT_PropertyStore_Commit);
    _ = Commit(ps);

    var pf_p: ?*anyopaque = null;
    if (comQueryInterface(sl, &IID_IPersistFile, &pf_p) < 0 or pf_p == null) return;
    const pf: *ComObj = @ptrCast(@alignCast(pf_p));
    defer releaseRef(pf);
    const Save = vtSlot(*const fn (*ComObj, [*:0]const u16, BOOL) callconv(.winapi) HRESULT, pf.lpVtbl, SLOT_PersistFile_Save);
    _ = Save(pf, lnk_z, 1);
}

/// Show a modern Action Center toast (title + body). WinRT path identical to
/// the legacy `windows.zig` `showToast`. Returns `error.Unsupported` off
/// Windows, `error.Backend` on any WinRT failure.
pub fn showToast(allocator: std.mem.Allocator, title: []const u8, body: []const u8) ToastError!void {
    if (builtin.os.tag != .windows) return error.Unsupported;

    // ---- identity: AUMID + shortcut path from the exe basename ----
    var base: [256]u16 = undefined;
    const base_len = exeBaseNameW(&base) orelse return error.Backend;

    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("Verve.");
    var aumid: [320]u16 = undefined;
    var ai: usize = 0;
    if (!appendW(&aumid, &ai, prefix[0..])) return error.Backend;
    if (!appendW(&aumid, &ai, base[0..base_len])) return error.Backend;
    aumid[ai] = 0;

    var appdata: [320]u16 = undefined;
    const ad_name = std.unicode.utf8ToUtf16LeStringLiteral("APPDATA");
    const ad_len = GetEnvironmentVariableW(ad_name, &appdata, appdata.len);
    if (ad_len == 0 or ad_len >= appdata.len) return error.Backend;

    var lnk: [768]u16 = undefined;
    var li: usize = 0;
    if (!appendW(&lnk, &li, appdata[0..ad_len])) return error.Backend;
    if (!appendW(&lnk, &li, std.unicode.utf8ToUtf16LeStringLiteral("\\Microsoft\\Windows\\Start Menu\\Programs\\")[0..])) return error.Backend;
    if (!appendW(&lnk, &li, base[0..base_len])) return error.Backend;
    if (!appendW(&lnk, &li, std.unicode.utf8ToUtf16LeStringLiteral(".lnk")[0..])) return error.Backend;
    lnk[li] = 0;

    _ = SetCurrentProcessExplicitAppUserModelID(@ptrCast(&aumid));
    ensureAumidShortcut(exeFullPathZ(), @ptrCast(&aumid), @ptrCast(&lnk));

    _ = RoInitialize(RO_INIT_SINGLETHREADED); // S_FALSE / changed-mode tolerated

    // ---- XmlDocument + ToastGeneric template ----
    const xml_doc = roActivate("Windows.Data.Xml.Dom.XmlDocument") orelse return error.Backend;
    defer releaseRef(xml_doc);

    var docio_p: ?*anyopaque = null;
    if (comQueryInterface(xml_doc, &IID_IXmlDocumentIO, &docio_p) < 0 or docio_p == null) return error.Backend;
    const docio: *ComObj = @ptrCast(@alignCast(docio_p));
    defer releaseRef(docio);

    const xml = toast_codec.buildToastXml(allocator, title, body) catch return error.OutOfMemory;
    defer allocator.free(xml);
    const xml_w = std.unicode.utf8ToUtf16LeAlloc(allocator, xml) catch return error.OutOfMemory;
    defer allocator.free(xml_w);
    const xml_h = winrtString(xml_w) orelse return error.Backend;
    defer _ = WindowsDeleteString(xml_h);

    const LoadXml = vtSlot(*const fn (*ComObj, ?*anyopaque) callconv(.winapi) HRESULT, docio.lpVtbl, SLOT_XmlDocumentIO_LoadXml);
    if (LoadXml(docio, xml_h) < 0) return error.Backend;

    // The XmlDocument as IXmlDocument (what CreateToastNotification wants).
    var doc_p: ?*anyopaque = null;
    if (comQueryInterface(xml_doc, &IID_IXmlDocument, &doc_p) < 0 or doc_p == null) return error.Backend;
    const doc: *ComObj = @ptrCast(@alignCast(doc_p));
    defer releaseRef(doc);

    // ---- notifier (AUMID) ----
    const mgr_id = hstr("Windows.UI.Notifications.ToastNotificationManager") orelse return error.Backend;
    defer _ = WindowsDeleteString(mgr_id);
    var statics_p: ?*anyopaque = null;
    if (RoGetActivationFactory(mgr_id, &IID_IToastNotificationManagerStatics, &statics_p) < 0 or statics_p == null) return error.Backend;
    const statics: *ComObj = @ptrCast(@alignCast(statics_p));
    defer releaseRef(statics);

    const aumid_h = winrtString(aumid[0..ai]) orelse return error.Backend;
    defer _ = WindowsDeleteString(aumid_h);
    const CreateNotifier = vtSlot(*const fn (*ComObj, ?*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT, statics.lpVtbl, SLOT_ToastMgr_CreateToastNotifierWithId);
    var notifier_p: ?*anyopaque = null;
    if (CreateNotifier(statics, aumid_h, &notifier_p) < 0 or notifier_p == null) return error.Backend;
    const notifier: *ComObj = @ptrCast(@alignCast(notifier_p));
    defer releaseRef(notifier);

    // ---- toast from the xml ----
    const toast_id = hstr("Windows.UI.Notifications.ToastNotification") orelse return error.Backend;
    defer _ = WindowsDeleteString(toast_id);
    var tfac_p: ?*anyopaque = null;
    if (RoGetActivationFactory(toast_id, &IID_IToastNotificationFactory, &tfac_p) < 0 or tfac_p == null) return error.Backend;
    const tfac: *ComObj = @ptrCast(@alignCast(tfac_p));
    defer releaseRef(tfac);

    const CreateToast = vtSlot(*const fn (*ComObj, *ComObj, *?*anyopaque) callconv(.winapi) HRESULT, tfac.lpVtbl, SLOT_ToastFactory_CreateToastNotification);
    var toast_p: ?*anyopaque = null;
    if (CreateToast(tfac, doc, &toast_p) < 0 or toast_p == null) return error.Backend;
    const toast: *ComObj = @ptrCast(@alignCast(toast_p));
    defer releaseRef(toast);

    const Show = vtSlot(*const fn (*ComObj, *ComObj) callconv(.winapi) HRESULT, notifier.lpVtbl, SLOT_ToastNotifier_Show);
    if (Show(notifier, toast) < 0) return error.Backend;
}
