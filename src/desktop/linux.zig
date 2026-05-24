//! Linux backend — GTK3 + WebKitGTK 4.1.
//!
//! Symbols are declared as hand-rolled `extern` decls rather than
//! `@cImport`ing the GTK/WebKit headers. That keeps the file
//! syntactically compilable on any host (the framework's own
//! `zig build` runs on macOS CI), while still linking correctly when
//! a real Linux target builds against `gtk+-3.0` and `webkit2gtk-4.1`
//! via pkg-config.
//!
//! GTK4 + WebKitGTK 6.0 are a follow-up; the platform-neutral surface
//! in `window.zig` does not change, so a second backend can be added
//! later behind a `-Dgtk4` flag without touching call sites.

const std = @import("std");
const opts_mod = @import("options.zig");
const ipc = @import("ipc.zig");
const router = @import("asset_router.zig");
const cookies_mod = @import("cookies.zig");

// ---- Opaque GTK/GLib/WebKit pointer types -----------------------------------

const GtkWidget = opaque {};
const GtkWindow = opaque {};
const GtkContainer = opaque {};
const WebKitWebView = opaque {};
const WebKitWebContext = opaque {};
const WebKitUserContentManager = opaque {};
const WebKitUserScript = opaque {};
const WebKitURISchemeRequest = opaque {};
const WebKitJavascriptResult = opaque {};
const WebKitSettings = opaque {};
const WebKitCookieManager = opaque {};
const GInputStream = opaque {};
const GError = opaque {};
const GAsyncResult = opaque {};
const GList = opaque {};
const JSCValue = opaque {};
const GObject = opaque {};
const SoupCookie = opaque {};
const SoupDate = opaque {};
const GClosureNotify = ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;
const GAsyncReadyCallback = ?*const fn (?*anyopaque, ?*GAsyncResult, ?*anyopaque) callconv(.c) void;
const GDestroyNotify = ?*const fn (?*anyopaque) callconv(.c) void;

const gboolean = c_int;
const GQuark = u32;
const GConnectFlags = c_uint;
const GtkWindowType = c_uint;
const WebKitUserContentInjectedFrames = c_uint;
const WebKitUserScriptInjectionTime = c_uint;
const GCallback = *const fn () callconv(.c) void;
const GType = usize;

const GTK_WINDOW_TOPLEVEL: GtkWindowType = 0;
const WEBKIT_USER_CONTENT_INJECT_TOP_FRAME: WebKitUserContentInjectedFrames = 0;
const WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START: WebKitUserScriptInjectionTime = 0;

// ---- GTK / GLib externs -----------------------------------------------------

extern fn gtk_init_check(argc: ?*c_int, argv: ?*?[*][*:0]u8) gboolean;
extern fn gtk_window_new(t: GtkWindowType) *GtkWidget;
extern fn gtk_window_set_title(w: *GtkWindow, title: [*:0]const u8) void;
extern fn gtk_window_set_default_size(w: *GtkWindow, width: c_int, height: c_int) void;
extern fn gtk_container_add(c: *GtkContainer, w: *GtkWidget) void;
extern fn gtk_widget_show_all(w: *GtkWidget) void;
extern fn gtk_widget_destroy(w: *GtkWidget) void;
extern fn gtk_main() void;
extern fn gtk_main_quit() void;

extern fn g_signal_connect_data(
    instance: ?*anyopaque,
    detailed_signal: [*:0]const u8,
    handler: GCallback,
    data: ?*anyopaque,
    destroy_data: GClosureNotify,
    connect_flags: GConnectFlags,
) c_ulong;
extern fn g_object_unref(o: ?*anyopaque) void;
extern fn g_free(p: ?*anyopaque) void;
extern fn g_memdup2(mem: ?*const anyopaque, byte_size: usize) ?*anyopaque;
extern fn g_quark_from_static_string(s: [*:0]const u8) GQuark;
extern fn g_error_new_literal(domain: GQuark, code: c_int, message: [*:0]const u8) *GError;
extern fn g_error_free(err: *GError) void;
extern fn g_memory_input_stream_new_from_data(
    data: [*]const u8,
    len: c_long,
    destroy: ?*const fn (?*anyopaque) callconv(.c) void,
) *GInputStream;

extern fn g_main_context_iteration(ctx: ?*anyopaque, may_block: gboolean) gboolean;
extern fn g_list_length(list: ?*GList) c_uint;
extern fn g_list_nth_data(list: ?*GList, n: c_uint) ?*anyopaque;
extern fn g_list_free_full(list: ?*GList, destroy: GDestroyNotify) void;

// ---- WebKitGTK externs ------------------------------------------------------

const WebKitURISchemeRequestCallback = *const fn (req: *WebKitURISchemeRequest, user_data: ?*anyopaque) callconv(.c) void;
const ScriptMessageCallback = *const fn (ucm: *WebKitUserContentManager, msg: *WebKitJavascriptResult, user_data: ?*anyopaque) callconv(.c) void;

extern fn webkit_web_context_get_default() *WebKitWebContext;
extern fn webkit_web_context_new() *WebKitWebContext;
extern fn webkit_web_context_register_uri_scheme(
    ctx: *WebKitWebContext,
    scheme: [*:0]const u8,
    cb: WebKitURISchemeRequestCallback,
    user_data: ?*anyopaque,
    destroy: ?*const fn (?*anyopaque) callconv(.c) void,
) void;

extern fn webkit_user_content_manager_new() *WebKitUserContentManager;
extern fn webkit_user_content_manager_add_script(ucm: *WebKitUserContentManager, script: *WebKitUserScript) void;
extern fn webkit_user_content_manager_register_script_message_handler(
    ucm: *WebKitUserContentManager,
    name: [*:0]const u8,
) gboolean;

extern fn webkit_user_script_new(
    source: [*:0]const u8,
    frames: WebKitUserContentInjectedFrames,
    time: WebKitUserScriptInjectionTime,
    whitelist: ?[*]const [*:0]const u8,
    blacklist: ?[*]const [*:0]const u8,
) *WebKitUserScript;
extern fn webkit_user_script_unref(s: *WebKitUserScript) void;

extern fn webkit_web_view_new_with_user_content_manager(ucm: *WebKitUserContentManager) *GtkWidget;
extern fn webkit_web_view_get_type() GType;
// GObject's universal constructor — variadic property list, NULL-terminated.
// Needed because no WebKitGTK 4.1 helper takes BOTH a custom WebContext and a
// custom UserContentManager; we set them both via properties at construction.
extern fn g_object_new(g_type: GType, first_prop: ?[*:0]const u8, ...) ?*anyopaque;
extern fn webkit_web_view_load_uri(wv: *WebKitWebView, uri: [*:0]const u8) void;
extern fn webkit_web_view_load_html(wv: *WebKitWebView, html: [*:0]const u8, base_uri: ?[*:0]const u8) void;
extern fn webkit_web_view_run_javascript(
    wv: *WebKitWebView,
    script: [*:0]const u8,
    cancellable: ?*anyopaque,
    cb: ?*anyopaque,
    user_data: ?*anyopaque,
) void;
extern fn webkit_web_view_get_settings(wv: *WebKitWebView) *WebKitSettings;
extern fn webkit_settings_set_enable_developer_extras(s: *WebKitSettings, enabled: gboolean) void;

extern fn webkit_uri_scheme_request_get_uri(req: *WebKitURISchemeRequest) [*:0]const u8;
extern fn webkit_uri_scheme_request_finish(
    req: *WebKitURISchemeRequest,
    stream: *GInputStream,
    stream_length: c_long,
    content_type: [*:0]const u8,
) void;
extern fn webkit_uri_scheme_request_finish_error(req: *WebKitURISchemeRequest, err: *GError) void;

extern fn webkit_javascript_result_get_js_value(result: *WebKitJavascriptResult) *JSCValue;
extern fn jsc_value_is_string(v: *JSCValue) gboolean;
extern fn jsc_value_to_string(v: *JSCValue) [*:0]u8;

// ---- WebKit cookie manager + SoupCookie externs -----------------------------

extern fn webkit_web_context_get_cookie_manager(ctx: *WebKitWebContext) *WebKitCookieManager;
extern fn webkit_cookie_manager_get_all_cookies(
    mgr: *WebKitCookieManager,
    cancellable: ?*anyopaque,
    callback: GAsyncReadyCallback,
    user_data: ?*anyopaque,
) void;
extern fn webkit_cookie_manager_get_all_cookies_finish(
    mgr: *WebKitCookieManager,
    result: *GAsyncResult,
    err: ?*?*GError,
) ?*GList;
extern fn webkit_cookie_manager_add_cookie(
    mgr: *WebKitCookieManager,
    cookie: *SoupCookie,
    cancellable: ?*anyopaque,
    callback: GAsyncReadyCallback,
    user_data: ?*anyopaque,
) void;
extern fn webkit_cookie_manager_delete_cookie(
    mgr: *WebKitCookieManager,
    cookie: *SoupCookie,
    cancellable: ?*anyopaque,
    callback: GAsyncReadyCallback,
    user_data: ?*anyopaque,
) void;

extern fn soup_cookie_new(
    name: [*:0]const u8,
    value: [*:0]const u8,
    domain: [*:0]const u8,
    path: [*:0]const u8,
    max_age: c_int,
) ?*SoupCookie;
extern fn soup_cookie_free(c: *SoupCookie) void;
extern fn soup_cookie_get_name(c: *SoupCookie) [*:0]const u8;
extern fn soup_cookie_get_value(c: *SoupCookie) [*:0]const u8;
extern fn soup_cookie_get_domain(c: *SoupCookie) [*:0]const u8;
extern fn soup_cookie_get_path(c: *SoupCookie) [*:0]const u8;
extern fn soup_cookie_get_secure(c: *SoupCookie) gboolean;
extern fn soup_cookie_get_http_only(c: *SoupCookie) gboolean;
extern fn soup_cookie_get_expires(c: *SoupCookie) ?*SoupDate;
extern fn soup_cookie_get_same_site_policy(c: *SoupCookie) c_int;
extern fn soup_cookie_set_secure(c: *SoupCookie, v: gboolean) void;
extern fn soup_cookie_set_http_only(c: *SoupCookie, v: gboolean) void;
extern fn soup_cookie_set_same_site_policy(c: *SoupCookie, p: c_int) void;
extern fn soup_cookie_set_expires(c: *SoupCookie, date: ?*SoupDate) void;
extern fn soup_date_new_from_time_t(t: c_long) *SoupDate;
extern fn soup_date_to_time_t(d: *SoupDate) c_long;
extern fn soup_date_free(d: *SoupDate) void;

const SOUP_SAME_SITE_NONE: c_int = 0;
const SOUP_SAME_SITE_LAX: c_int = 1;
const SOUP_SAME_SITE_STRICT: c_int = 2;

// ---- Implementation ---------------------------------------------------------

/// Per-window state. Each window owns its own WebKitWebContext so that
/// the URI scheme handler can be registered per-context (a WebKitGTK
/// constraint — scheme registration sticks to the WebContext, not the
/// view). The global `webkit_web_context_get_default()` of the prior
/// implementation made multi-window impossible. user_data threading
/// via g_signal_connect_data + webkit_web_context_register_uri_scheme
/// carries the WindowCtx pointer directly into trampolines, so this
/// backend needs no module-level registry.
const WindowCtx = struct {
    allocator: std.mem.Allocator,
    opts: opts_mod.WindowOptions,
    on_message: ?opts_mod.MessageHandler,
    on_message_ctx: ?*anyopaque,
    window: ?*GtkWidget = null,
    webview: ?*WebKitWebView = null,
    web_context: ?*WebKitWebContext = null,
};

// GTK's main loop has no automatic last-window tracking, so we count
// live windows ourselves. Incremented after gtk_window_new succeeds;
// decremented in onDestroy. gtk_main_quit only fires when the counter
// hits zero — matches Cocoa applicationShouldTerminateAfterLastWindowClosed.
var live_windows: u32 = 0;

pub const Window = struct {
    ctx: *WindowCtx,

    pub fn init(allocator: std.mem.Allocator, opts: opts_mod.WindowOptions) !Window {
        std.log.debug("verve.desktop[linux]: gtk_init_check", .{});
        if (gtk_init_check(null, null) == 0) return error.GtkInitFailed;

        const heap = try allocator.create(WindowCtx);
        errdefer allocator.destroy(heap);
        heap.* = .{
            .allocator = allocator,
            .opts = opts,
            .on_message = opts.on_message,
            .on_message_ctx = opts.on_message_ctx,
        };

        const window_widget = gtk_window_new(GTK_WINDOW_TOPLEVEL);
        heap.window = window_widget;
        live_windows += 1;

        const title_z = try allocator.dupeZ(u8, opts.title);
        defer allocator.free(title_z);
        gtk_window_set_title(@ptrCast(window_widget), title_z.ptr);
        gtk_window_set_default_size(@ptrCast(window_widget), @intCast(opts.width), @intCast(opts.height));

        _ = g_signal_connect_data(window_widget, "destroy", @as(GCallback, @ptrCast(&onDestroy)), @ptrCast(heap), null, 0);

        // Per-window WebContext. Scheme handlers must be registered
        // BEFORE the WebView is constructed; the WebView resolves its
        // context-bound handlers at first navigation.
        const web_ctx = webkit_web_context_new();
        heap.web_context = web_ctx;
        const scheme_z = try allocator.dupeZ(u8, opts.scheme);
        defer allocator.free(scheme_z);
        std.log.debug("verve.desktop[linux]: register scheme '{s}://' (per-window context)", .{opts.scheme});
        webkit_web_context_register_uri_scheme(web_ctx, scheme_z.ptr, &onSchemeRequest, @ptrCast(heap), null);

        const ucm = webkit_user_content_manager_new();
        const shim_z = try allocator.dupeZ(u8, ipc.shim_js);
        defer allocator.free(shim_z);
        const script = webkit_user_script_new(
            shim_z.ptr,
            WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
            WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,
            null,
            null,
        );
        webkit_user_content_manager_add_script(ucm, script);
        webkit_user_script_unref(script);

        _ = webkit_user_content_manager_register_script_message_handler(ucm, "verve");
        _ = g_signal_connect_data(ucm, "script-message-received::verve", @as(GCallback, @ptrCast(&onScriptMessage)), @ptrCast(heap), null, 0);

        // Construct WebView with BOTH our custom WebContext and our
        // UserContentManager. No WebKitGTK 4.1 single-call helper takes
        // both, so go through g_object_new with explicit properties.
        const wv_obj = g_object_new(
            webkit_web_view_get_type(),
            "web-context",
            web_ctx,
            @as(?[*:0]const u8, "user-content-manager"),
            ucm,
            @as(?[*:0]const u8, null),
        ) orelse return error.WebViewCreateFailed;
        const wv_widget: *GtkWidget = @ptrCast(wv_obj);
        const wv: *WebKitWebView = @ptrCast(wv_widget);
        heap.webview = wv;

        if (opts.devtools) {
            const settings = webkit_web_view_get_settings(wv);
            webkit_settings_set_enable_developer_extras(settings, 1);
        }

        gtk_container_add(@ptrCast(window_widget), wv_widget);

        if (opts.initial_path.len > 0) {
            var url_buf: [1024]u8 = undefined;
            const url = try std.fmt.bufPrintZ(&url_buf, "{s}://app/{s}", .{ opts.scheme, opts.initial_path });
            std.log.debug("verve.desktop[linux]: navigate {s}", .{url});
            webkit_web_view_load_uri(wv, url.ptr);
        }

        gtk_widget_show_all(window_widget);
        std.log.info("verve.desktop[linux]: window shown ({d}x{d})", .{ opts.width, opts.height });
        return .{ .ctx = heap };
    }

    pub fn setTitle(self: *Window, title: []const u8) void {
        const z = self.ctx.allocator.dupeZ(u8, title) catch return;
        defer self.ctx.allocator.free(z);
        if (self.ctx.window) |w| gtk_window_set_title(@ptrCast(w), z.ptr);
    }

    pub fn loadUrl(self: *Window, url: []const u8) !void {
        const wv = self.ctx.webview orelse return error.NotReady;
        const z = try self.ctx.allocator.dupeZ(u8, url);
        defer self.ctx.allocator.free(z);
        webkit_web_view_load_uri(wv, z.ptr);
    }

    pub fn loadHtml(self: *Window, html: []const u8, base_url: ?[]const u8) !void {
        const wv = self.ctx.webview orelse return error.NotReady;
        const z = try self.ctx.allocator.dupeZ(u8, html);
        defer self.ctx.allocator.free(z);
        const base_z: ?[:0]u8 = if (base_url) |b| (self.ctx.allocator.dupeZ(u8, b) catch null) else null;
        defer if (base_z) |bz| self.ctx.allocator.free(bz);
        const base_ptr: ?[*:0]const u8 = if (base_z) |bz| bz.ptr else null;
        webkit_web_view_load_html(wv, z.ptr, base_ptr);
    }

    pub fn evalJs(self: *Window, script: []const u8) void {
        const wv = self.ctx.webview orelse return;
        const z = self.ctx.allocator.dupeZ(u8, script) catch return;
        defer self.ctx.allocator.free(z);
        webkit_web_view_run_javascript(wv, z.ptr, null, null, null);
    }

    pub fn setMessageHandler(self: *Window, handler: opts_mod.MessageHandler, handler_ctx: ?*anyopaque) void {
        self.ctx.on_message = handler;
        self.ctx.on_message_ctx = handler_ctx;
    }

    /// Open a second window in the same GTK main loop. Returned
    /// Window owns its own GtkWindow + WebKitWebContext + WebView;
    /// gtk_main_quit only fires when the last live window destroys.
    pub fn openChildWindow(self: *Window, opts: opts_mod.WindowOptions) !Window {
        return Window.init(self.ctx.allocator, opts);
    }

    /// Per-window cookie store. WebKitCookieManager wiring is a
    /// follow-up — see module-level stubs.
    pub fn cookies(self: *Window) cookies_mod.CookieStore {
        return .{ .window = @ptrCast(self) };
    }

    pub fn run(self: *Window) void {
        _ = self;
        gtk_main();
    }

    pub fn terminate(self: *Window) void {
        _ = self;
        gtk_main_quit();
    }

    pub fn close(self: *Window) void {
        if (self.ctx.window) |w| gtk_widget_destroy(w);
    }

    pub fn deinit(self: *Window) void {
        if (self.ctx.web_context) |wc| g_object_unref(wc);
        self.ctx.allocator.destroy(self.ctx);
    }

    // ---- Dialogs ------------------------------------------------------------
    // Real GtkFileChooserDialog + GtkMessageDialog wiring is a follow-up;
    // returning Unsupported lets cross-platform call sites compile and
    // makes the missing surface visible at runtime.

    pub fn openFileDialog(self: *Window, allocator: std.mem.Allocator, opts: opts_mod.FileDialogOptions) opts_mod.DialogError![]u8 {
        _ = self;
        _ = allocator;
        _ = opts;
        return opts_mod.DialogError.Unsupported;
    }

    pub fn saveFileDialog(self: *Window, allocator: std.mem.Allocator, opts: opts_mod.FileDialogOptions) opts_mod.DialogError![]u8 {
        _ = self;
        _ = allocator;
        _ = opts;
        return opts_mod.DialogError.Unsupported;
    }

    pub fn showAlert(self: *Window, opts: opts_mod.AlertOptions) usize {
        _ = self;
        _ = opts;
        return 0;
    }

    pub fn takeSnapshotPng(self: *Window, path: []const u8) opts_mod.SnapshotError!void {
        _ = self;
        _ = path;
        return opts_mod.SnapshotError.Unsupported;
    }
};

// ---- GTK signal trampolines -------------------------------------------------

fn onDestroy(_: ?*GtkWidget, _: ?*anyopaque) callconv(.c) void {
    if (live_windows > 0) live_windows -= 1;
    if (live_windows == 0) gtk_main_quit();
}

fn onSchemeRequest(req: *WebKitURISchemeRequest, user_data: ?*anyopaque) callconv(.c) void {
    const cx: *WindowCtx = @ptrCast(@alignCast(user_data orelse return));

    const uri = webkit_uri_scheme_request_get_uri(req);
    const uri_slice = std.mem.span(uri);

    const auth = "://app/";
    const path: []const u8 = if (std.mem.indexOf(u8, uri_slice, auth)) |i| uri_slice[i + auth.len ..] else uri_slice;
    std.log.debug("verve.desktop[linux]: scheme '{s}' → '{s}'", .{ uri_slice, path });

    const resolved = blk: {
        if (cx.opts.dev_assets) |dev| {
            break :blk router.resolveWithFallback(cx.allocator, dev.io, cx.opts.assets, path, dev.dir) catch {
                std.log.warn("verve.desktop[linux]: 404 {s}", .{path});
                const err = g_error_new_literal(g_quark_from_static_string("verve"), 404, "not found");
                webkit_uri_scheme_request_finish_error(req, err);
                g_error_free(err);
                return;
            };
        }
        break :blk router.resolve(cx.opts.assets, path) catch {
            std.log.warn("verve.desktop[linux]: 404 {s}", .{path});
            const err = g_error_new_literal(g_quark_from_static_string("verve"), 404, "not found");
            webkit_uri_scheme_request_finish_error(req, err);
            g_error_free(err);
            return;
        };
    };
    defer resolved.deinit(cx.allocator);

    // WebKitGTK's `from_data` does NOT copy the input buffer — the
    // bytes must outlive the stream. Embedded entries are static, so
    // passing the slice directly with a null destroy notify is fine.
    // Dev-mode owned bytes are about to be freed by the defer above,
    // so we hand a glib-allocated copy to the stream with `g_free` as
    // the destroy notify.
    const len_c: c_long = @intCast(resolved.bytes.len);
    var stream: *GInputStream = undefined;
    if (resolved.owned) {
        const copy = g_memdup2(resolved.bytes.ptr, resolved.bytes.len) orelse {
            std.log.warn("verve.desktop[linux]: g_memdup2 OOM", .{});
            const err = g_error_new_literal(g_quark_from_static_string("verve"), 500, "out of memory");
            webkit_uri_scheme_request_finish_error(req, err);
            g_error_free(err);
            return;
        };
        stream = g_memory_input_stream_new_from_data(@ptrCast(copy), len_c, g_free);
    } else {
        stream = g_memory_input_stream_new_from_data(resolved.bytes.ptr, len_c, null);
    }

    var ct_buf: [128]u8 = undefined;
    const ct_z = std.fmt.bufPrintZ(&ct_buf, "{s}", .{resolved.content_type}) catch {
        webkit_uri_scheme_request_finish(req, stream, len_c, "application/octet-stream");
        g_object_unref(stream);
        return;
    };
    webkit_uri_scheme_request_finish(req, stream, len_c, ct_z.ptr);
    g_object_unref(stream);
}

fn onScriptMessage(_: *WebKitUserContentManager, message: *WebKitJavascriptResult, user_data: ?*anyopaque) callconv(.c) void {
    const cx: *WindowCtx = @ptrCast(@alignCast(user_data orelse return));
    const value = webkit_javascript_result_get_js_value(message);
    if (jsc_value_is_string(value) == 0) return;
    const raw = jsc_value_to_string(value);
    defer g_free(raw);
    const slice = std.mem.span(raw);
    if (cx.on_message) |h| h(cx.on_message_ctx, slice);
}

// ---- Cookie store -----------------------------------------------------------
//
// WebKitCookieManager is per-WebContext (we already create one per
// window). All cookie APIs are async via GAsyncResult — we sync-wrap by
// spinning `g_main_context_iteration` until the GAsyncReadyCallback
// flips a `done` bool. Standard GLib pattern; processes other GTK
// events during the wait. Requires WebKitGTK ≥ 2.40 for
// get_all_cookies (introduced 2023-03). add_cookie / delete_cookie are
// available since 2.20.

/// Continuation cell passed as `user_data` to async cookie ops. The
/// callback writes its result into the cell and signals via `done`.
const GetAllCookiesCell = extern struct {
    result: ?*GAsyncResult = null,
    done: bool = false,
};

const SimpleAsyncCell = extern struct {
    done: bool = false,
};

fn onGetAllCookiesDone(_: ?*anyopaque, res: ?*GAsyncResult, user_data: ?*anyopaque) callconv(.c) void {
    const cell: *GetAllCookiesCell = @ptrCast(@alignCast(user_data orelse return));
    cell.result = res;
    cell.done = true;
}

fn onSimpleAsyncDone(_: ?*anyopaque, _: ?*GAsyncResult, user_data: ?*anyopaque) callconv(.c) void {
    const cell: *SimpleAsyncCell = @ptrCast(@alignCast(user_data orelse return));
    cell.done = true;
}

fn pumpMainContextUntilDone(done: *const bool) void {
    while (!done.*) {
        _ = g_main_context_iteration(null, 1); // 1 = may_block
    }
}

fn cookieManagerFor(window: *anyopaque) opts_mod.CookieError!*WebKitCookieManager {
    const win: *Window = @ptrCast(@alignCast(window));
    const wc = win.ctx.web_context orelse return opts_mod.CookieError.NotReady;
    return webkit_web_context_get_cookie_manager(wc);
}

fn fetchAllCookies(mgr: *WebKitCookieManager) ?*GList {
    var cell: GetAllCookiesCell = .{};
    webkit_cookie_manager_get_all_cookies(mgr, null, &onGetAllCookiesDone, @ptrCast(&cell));
    pumpMainContextUntilDone(&cell.done);
    const res = cell.result orelse return null;
    var err: ?*GError = null;
    const list = webkit_cookie_manager_get_all_cookies_finish(mgr, res, &err);
    if (err) |e| {
        std.log.warn("verve.desktop[linux]: get_all_cookies_finish failed", .{});
        g_error_free(e);
        return null;
    }
    return list;
}

fn marshalCookie(allocator: std.mem.Allocator, c: *SoupCookie) opts_mod.CookieError!opts_mod.Cookie {
    const name = std.mem.span(soup_cookie_get_name(c));
    const value = std.mem.span(soup_cookie_get_value(c));
    const domain = std.mem.span(soup_cookie_get_domain(c));
    const path = std.mem.span(soup_cookie_get_path(c));

    var out: opts_mod.Cookie = .{
        .name = allocator.dupe(u8, name) catch return opts_mod.CookieError.OutOfMemory,
        .value = allocator.dupe(u8, value) catch return opts_mod.CookieError.OutOfMemory,
        .domain = allocator.dupe(u8, domain) catch return opts_mod.CookieError.OutOfMemory,
        .path = allocator.dupe(u8, path) catch return opts_mod.CookieError.OutOfMemory,
        .secure = soup_cookie_get_secure(c) != 0,
        .http_only = soup_cookie_get_http_only(c) != 0,
    };

    if (soup_cookie_get_expires(c)) |date| {
        out.expires_unix = @intCast(soup_date_to_time_t(date));
    }

    out.same_site = switch (soup_cookie_get_same_site_policy(c)) {
        SOUP_SAME_SITE_NONE => .none,
        SOUP_SAME_SITE_LAX => .lax,
        SOUP_SAME_SITE_STRICT => .strict,
        else => .default,
    };

    return out;
}

fn buildSoupCookie(allocator: std.mem.Allocator, cookie: opts_mod.Cookie) opts_mod.CookieError!*SoupCookie {
    const name_z = allocator.dupeZ(u8, cookie.name) catch return opts_mod.CookieError.OutOfMemory;
    defer allocator.free(name_z);
    const value_z = allocator.dupeZ(u8, cookie.value) catch return opts_mod.CookieError.OutOfMemory;
    defer allocator.free(value_z);
    const domain_src = if (cookie.domain.len > 0) cookie.domain else "";
    const domain_z = allocator.dupeZ(u8, domain_src) catch return opts_mod.CookieError.OutOfMemory;
    defer allocator.free(domain_z);
    const path_src = if (cookie.path.len > 0) cookie.path else "/";
    const path_z = allocator.dupeZ(u8, path_src) catch return opts_mod.CookieError.OutOfMemory;
    defer allocator.free(path_z);

    // max_age == -1 → session cookie. soup_cookie_new ignores expires;
    // we override below via soup_cookie_set_expires if requested.
    const c = soup_cookie_new(name_z.ptr, value_z.ptr, domain_z.ptr, path_z.ptr, -1) orelse return opts_mod.CookieError.Backend;

    if (cookie.secure) soup_cookie_set_secure(c, 1);
    if (cookie.http_only) soup_cookie_set_http_only(c, 1);
    if (cookie.expires_unix > 0) {
        const date = soup_date_new_from_time_t(@intCast(cookie.expires_unix));
        soup_cookie_set_expires(c, date);
        soup_date_free(date);
    }
    soup_cookie_set_same_site_policy(c, switch (cookie.same_site) {
        .default, .lax => SOUP_SAME_SITE_LAX,
        .none => SOUP_SAME_SITE_NONE,
        .strict => SOUP_SAME_SITE_STRICT,
    });

    return c;
}

pub fn cookieGet(window: *anyopaque, allocator: std.mem.Allocator, name: []const u8) opts_mod.CookieError!?opts_mod.Cookie {
    const mgr = try cookieManagerFor(window);
    const list = fetchAllCookies(mgr) orelse return null;
    defer g_list_free_full(list, @ptrCast(&soup_cookie_free));

    const count = g_list_length(list);
    var i: c_uint = 0;
    while (i < count) : (i += 1) {
        const raw = g_list_nth_data(list, i) orelse continue;
        const c: *SoupCookie = @ptrCast(@alignCast(raw));
        const c_name = std.mem.span(soup_cookie_get_name(c));
        if (std.mem.eql(u8, c_name, name)) {
            return try marshalCookie(allocator, c);
        }
    }
    return null;
}

pub fn cookieSet(window: *anyopaque, cookie: opts_mod.Cookie) opts_mod.CookieError!void {
    const mgr = try cookieManagerFor(window);
    const win: *Window = @ptrCast(@alignCast(window));
    const c = try buildSoupCookie(win.ctx.allocator, cookie);
    defer soup_cookie_free(c);

    var cell: SimpleAsyncCell = .{};
    webkit_cookie_manager_add_cookie(mgr, c, null, &onSimpleAsyncDone, @ptrCast(&cell));
    pumpMainContextUntilDone(&cell.done);
}

pub fn cookieDelete(window: *anyopaque, name: []const u8) opts_mod.CookieError!void {
    const mgr = try cookieManagerFor(window);
    const list = fetchAllCookies(mgr) orelse return;
    defer g_list_free_full(list, @ptrCast(&soup_cookie_free));

    const count = g_list_length(list);
    var i: c_uint = 0;
    while (i < count) : (i += 1) {
        const raw = g_list_nth_data(list, i) orelse continue;
        const c: *SoupCookie = @ptrCast(@alignCast(raw));
        const c_name = std.mem.span(soup_cookie_get_name(c));
        if (std.mem.eql(u8, c_name, name)) {
            var cell: SimpleAsyncCell = .{};
            webkit_cookie_manager_delete_cookie(mgr, c, null, &onSimpleAsyncDone, @ptrCast(&cell));
            pumpMainContextUntilDone(&cell.done);
            return;
        }
    }
}

pub fn cookieClear(window: *anyopaque) opts_mod.CookieError!void {
    const mgr = try cookieManagerFor(window);
    const list = fetchAllCookies(mgr) orelse return;
    defer g_list_free_full(list, @ptrCast(&soup_cookie_free));

    const count = g_list_length(list);
    var i: c_uint = 0;
    while (i < count) : (i += 1) {
        const raw = g_list_nth_data(list, i) orelse continue;
        const c: *SoupCookie = @ptrCast(@alignCast(raw));
        var cell: SimpleAsyncCell = .{};
        webkit_cookie_manager_delete_cookie(mgr, c, null, &onSimpleAsyncDone, @ptrCast(&cell));
        pumpMainContextUntilDone(&cell.done);
    }
}
