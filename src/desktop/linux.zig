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
const GInputStream = opaque {};
const GError = opaque {};
const JSCValue = opaque {};
const GObject = opaque {};
const GClosureNotify = ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;

const gboolean = c_int;
const GQuark = u32;
const GConnectFlags = c_uint;
const GtkWindowType = c_uint;
const WebKitUserContentInjectedFrames = c_uint;
const WebKitUserScriptInjectionTime = c_uint;
const GCallback = *const fn () callconv(.c) void;

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
extern fn g_quark_from_static_string(s: [*:0]const u8) GQuark;
extern fn g_error_new_literal(domain: GQuark, code: c_int, message: [*:0]const u8) *GError;
extern fn g_error_free(err: *GError) void;
extern fn g_memory_input_stream_new_from_data(
    data: [*]const u8,
    len: c_long,
    destroy: ?*const fn (?*anyopaque) callconv(.c) void,
) *GInputStream;

// ---- WebKitGTK externs ------------------------------------------------------

const WebKitURISchemeRequestCallback = *const fn (req: *WebKitURISchemeRequest, user_data: ?*anyopaque) callconv(.c) void;
const ScriptMessageCallback = *const fn (ucm: *WebKitUserContentManager, msg: *WebKitJavascriptResult, user_data: ?*anyopaque) callconv(.c) void;

extern fn webkit_web_context_get_default() *WebKitWebContext;
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

// ---- Implementation ---------------------------------------------------------

const Ctx = struct {
    allocator: std.mem.Allocator,
    opts: opts_mod.WindowOptions,
    on_message: ?opts_mod.MessageHandler,
    on_message_ctx: ?*anyopaque,
    window: ?*GtkWidget = null,
    webview: ?*WebKitWebView = null,
};

var ctx_storage: ?*Ctx = null;

pub const Window = struct {
    ctx: *Ctx,

    pub fn init(allocator: std.mem.Allocator, opts: opts_mod.WindowOptions) !Window {
        std.log.debug("verve.desktop[linux]: gtk_init_check", .{});
        if (gtk_init_check(null, null) == 0) return error.GtkInitFailed;

        const heap = try allocator.create(Ctx);
        heap.* = .{
            .allocator = allocator,
            .opts = opts,
            .on_message = opts.on_message,
            .on_message_ctx = opts.on_message_ctx,
        };
        ctx_storage = heap;

        const window_widget = gtk_window_new(GTK_WINDOW_TOPLEVEL);
        heap.window = window_widget;

        const title_z = try allocator.dupeZ(u8, opts.title);
        defer allocator.free(title_z);
        gtk_window_set_title(@ptrCast(window_widget), title_z.ptr);
        gtk_window_set_default_size(@ptrCast(window_widget), @intCast(opts.width), @intCast(opts.height));

        _ = g_signal_connect_data(window_widget, "destroy", @as(GCallback, @ptrCast(&onDestroy)), null, null, 0);

        // Register the custom scheme on the default context BEFORE any
        // WebView is created — WebKitGTK refuses scheme registration
        // once a WebView is live.
        const default_ctx = webkit_web_context_get_default();
        const scheme_z = try allocator.dupeZ(u8, opts.scheme);
        defer allocator.free(scheme_z);
        std.log.debug("verve.desktop[linux]: register scheme '{s}://'", .{opts.scheme});
        webkit_web_context_register_uri_scheme(default_ctx, scheme_z.ptr, &onSchemeRequest, null, null);

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
        _ = g_signal_connect_data(ucm, "script-message-received::verve", @as(GCallback, @ptrCast(&onScriptMessage)), null, null, 0);

        const wv_widget = webkit_web_view_new_with_user_content_manager(ucm);
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
};

// ---- GTK signal trampolines -------------------------------------------------

fn onDestroy(_: ?*GtkWidget, _: ?*anyopaque) callconv(.c) void {
    gtk_main_quit();
}

fn onSchemeRequest(req: *WebKitURISchemeRequest, _: ?*anyopaque) callconv(.c) void {
    const cx = ctx_storage orelse return;

    const uri = webkit_uri_scheme_request_get_uri(req);
    const uri_slice = std.mem.span(uri);

    const auth = "://app/";
    const path: []const u8 = if (std.mem.indexOf(u8, uri_slice, auth)) |i| uri_slice[i + auth.len ..] else uri_slice;
    std.log.debug("verve.desktop[linux]: scheme '{s}' → '{s}'", .{ uri_slice, path });

    const resolved = router.resolve(cx.opts.assets, path) catch {
        std.log.warn("verve.desktop[linux]: 404 {s}", .{path});
        const err = g_error_new_literal(g_quark_from_static_string("verve"), 404, "not found");
        webkit_uri_scheme_request_finish_error(req, err);
        g_error_free(err);
        return;
    };

    const stream = g_memory_input_stream_new_from_data(resolved.bytes.ptr, @intCast(resolved.bytes.len), null);
    var ct_buf: [128]u8 = undefined;
    const ct_z = std.fmt.bufPrintZ(&ct_buf, "{s}", .{resolved.content_type}) catch {
        webkit_uri_scheme_request_finish(req, stream, @intCast(resolved.bytes.len), "application/octet-stream");
        g_object_unref(stream);
        return;
    };
    webkit_uri_scheme_request_finish(req, stream, @intCast(resolved.bytes.len), ct_z.ptr);
    g_object_unref(stream);
}

fn onScriptMessage(_: *WebKitUserContentManager, message: *WebKitJavascriptResult, _: ?*anyopaque) callconv(.c) void {
    const cx = ctx_storage orelse return;
    const value = webkit_javascript_result_get_js_value(message);
    if (jsc_value_is_string(value) == 0) return;
    const raw = jsc_value_to_string(value);
    defer g_free(raw);
    const slice = std.mem.span(raw);
    if (cx.on_message) |h| h(cx.on_message_ctx, slice);
}
