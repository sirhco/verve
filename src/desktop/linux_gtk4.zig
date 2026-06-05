//! Linux backend — GTK4 + WebKitGTK 6.0.
//!
//! Symbols are declared as hand-rolled `extern` decls rather than
//! `@cImport`ing the GTK/WebKit headers. That keeps the file
//! syntactically compilable on any host (the framework's own
//! `zig build` runs on macOS CI), while still linking correctly when
//! a real Linux target builds against `gtk4` and `webkitgtk-6.0`
//! via pkg-config.
//!
//! This file is the GTK4 counterpart to `linux.zig` (GTK3/WebKitGTK 4.1).
//! The public `Window` struct surface is identical; all implementations
//! are stubs that return `error.TODO` — task D through I fill them in.

const std = @import("std");
const opts_mod = @import("options.zig");
const ipc = @import("ipc.zig");
const router = @import("asset_router.zig");
const cookies_mod = @import("cookies.zig");
const clipboard_mod = @import("clipboard.zig");

// ---- Opaque GTK/GLib/WebKit pointer types -----------------------------------

// GLib / GObject (unchanged between GTK3 and GTK4)
const GAsyncResult = opaque {};
const GCancellable = opaque {};
const GError = opaque {};
const GInputStream = opaque {};
const GList = opaque {};
const GObject = opaque {};
const GClosureNotify = ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;
const GAsyncReadyCallback = ?*const fn (?*anyopaque, ?*GAsyncResult, ?*anyopaque) callconv(.c) void;
const GDestroyNotify = ?*const fn (?*anyopaque) callconv(.c) void;

// libsoup 3.x (WebKitGTK 6.0 dependency — same struct names as soup2)
const SoupCookie = opaque {};
const SoupDate = opaque {};

// JavaScriptCore (present in WK6)
const JSCValue = opaque {};
const WebKitJavascriptResult = opaque {};

// WebKitGTK 6.0 types
const WebKitWebView = opaque {};
const WebKitWebContext = opaque {};
const WebKitUserContentManager = opaque {};
const WebKitUserScript = opaque {};
const WebKitURISchemeRequest = opaque {};
const WebKitSettings = opaque {};
const WebKitCookieManager = opaque {};
const WebKitNetworkSession = opaque {};

// Cairo (for snapshot)
const CairoSurface = opaque {};

// GTK4 widget types (present in GTK4 — GtkContainer removed)
const GtkWidget = opaque {};
const GtkWindow = opaque {};

// GTK4 new types (replace GTK3 clipboard / dialog / dnd types)
const GdkClipboard = opaque {};
const GdkDisplay = opaque {};
const GdkTexture = opaque {};
const GdkContentProvider = opaque {};
const GBytes = opaque {};
const GtkDropTarget = opaque {};
const GtkEventControllerFocus = opaque {};
const GtkAlertDialog = opaque {};
const GtkFileDialog = opaque {};
const GFile = opaque {};
const GListModel = opaque {};
const GMainLoop = opaque {};
const GdkPixbuf = opaque {};
const GdkPixbufLoader = opaque {};

// GDK4 surface/toplevel for window-state queries
const GdkSurface = opaque {};
const GdkToplevel = opaque {};

// GLib IO channel (for deep_link.attachUrlSocket)
const GIOChannel = opaque {};

// Print types (carry over — unchanged in GTK4)
const WebKitPrintOperation = opaque {};
const GtkPrintSettings = opaque {};
const GtkPageRange = extern struct {
    start: c_int,
    end: c_int,
};

// GtkSettings (color-scheme query)
const GtkSettings = opaque {};

// ---- Scalar typedefs --------------------------------------------------------

const gboolean = c_int;
const GQuark = u32;
const GConnectFlags = c_uint;
const WebKitUserContentInjectedFrames = c_uint;
const WebKitUserScriptInjectionTime = c_uint;
const GCallback = *const fn () callconv(.c) void;
const GType = usize;
const GIOCondition = c_uint;

// GTK4: GdkDragAction
const GdkDragAction = c_uint;

// GTK4: toplevel state flags
const GdkToplevelState = c_uint;

// GTK4: accessibility property enum
const GtkAccessibleProperty = c_uint;

// ---- Constants --------------------------------------------------------------

const WEBKIT_USER_CONTENT_INJECT_TOP_FRAME: WebKitUserContentInjectedFrames = 0;
const WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START: WebKitUserScriptInjectionTime = 0;

// GTK4 drag action
const GDK_ACTION_COPY: GdkDragAction = 1 << 1;

// GTK4 toplevel state
const GDK_TOPLEVEL_STATE_MINIMIZED: GdkToplevelState = 1 << 0;
const GDK_TOPLEVEL_STATE_FULLSCREEN: GdkToplevelState = 1 << 2;

// GLib IO priority
const G_PRIORITY_DEFAULT: c_int = 0;

// GLib IO condition
const G_IO_IN: GIOCondition = 1;

// GTK4 accessibility properties
const GTK_ACCESSIBLE_PROPERTY_LABEL: GtkAccessibleProperty = 8;
const GTK_ACCESSIBLE_PROPERTY_DESCRIPTION: GtkAccessibleProperty = 3;

// WebKitGTK snapshot
const WebKitSnapshotRegion = c_uint;
const WebKitSnapshotOptions = c_uint;
const CairoStatus = c_int;

const WEBKIT_SNAPSHOT_REGION_VISIBLE: WebKitSnapshotRegion = 0;
const WEBKIT_SNAPSHOT_OPTIONS_NONE: WebKitSnapshotOptions = 0;
const CAIRO_STATUS_SUCCESS: CairoStatus = 0;

// Print
const GTK_PRINT_PAGES_RANGES: c_int = 2;
const WEBKIT_PRINT_OPERATION_RESPONSE_PRINT: c_uint = 0;
const WEBKIT_PRINT_OPERATION_RESPONSE_CANCEL: c_uint = 1;

// Soup SameSite
const SOUP_SAME_SITE_NONE: c_int = 0;
const SOUP_SAME_SITE_LAX: c_int = 1;
const SOUP_SAME_SITE_STRICT: c_int = 2;

// ---- GTK4 window / widget externs -------------------------------------------
//
// GTK4 removes: gtk_init_check (use gtk_init), gtk_window_new(type),
// gtk_container_add, gtk_widget_show_all, gtk_widget_destroy,
// gtk_main / gtk_main_quit (use GMainLoop), GtkContainer, GtkDialog,
// GtkFileChooserNative, GtkMessageDialog, GtkBox-based menu bar,
// GtkAccelGroup, and GTK3 DnD API.

extern fn gtk_init() void;
extern fn gtk_window_new() *GtkWidget;
extern fn gtk_window_set_title(w: *GtkWindow, title: [*:0]const u8) void;
extern fn gtk_window_set_default_size(w: *GtkWindow, width: c_int, height: c_int) void;
extern fn gtk_window_get_default_size(w: *GtkWindow, width: ?*c_int, height: ?*c_int) void;
extern fn gtk_window_set_child(w: *GtkWindow, child: ?*GtkWidget) void;
extern fn gtk_window_destroy(w: *GtkWindow) void;
extern fn gtk_window_is_maximized(w: *GtkWindow) gboolean;
extern fn gtk_window_minimize(w: *GtkWindow) void;
extern fn gtk_window_maximize(w: *GtkWindow) void;
extern fn gtk_window_unmaximize(w: *GtkWindow) void;
extern fn gtk_window_fullscreen(w: *GtkWindow) void;
extern fn gtk_window_unfullscreen(w: *GtkWindow) void;
extern fn gtk_window_set_resizable(w: *GtkWindow, resizable: gboolean) void;
extern fn gtk_window_set_decorated(w: *GtkWindow, setting: gboolean) void;
extern fn gtk_window_present(w: *GtkWindow) void;
extern fn gtk_widget_show(w: *GtkWidget) void;
extern fn gtk_widget_hide(w: *GtkWidget) void;
extern fn gtk_widget_grab_focus(w: *GtkWidget) gboolean;
extern fn gtk_widget_set_opacity(w: *GtkWidget, opacity: f64) void;
extern fn gtk_widget_get_scale_factor(w: *GtkWidget) c_int;
extern fn gtk_widget_add_controller(widget: *GtkWidget, controller: *anyopaque) void;
extern fn gtk_window_set_geometry_hints(
    w: *GtkWindow,
    geometry_widget: ?*GtkWidget,
    geometry: ?*anyopaque,
    geom_mask: c_int,
) void;

// GTK4 event controllers (replace GTK3 signal-based event handling)
extern fn gtk_event_controller_focus_new() *GtkEventControllerFocus;
extern fn gtk_drop_target_new(g_type: GType, actions: GdkDragAction) *GtkDropTarget;
extern fn g_type_from_name(name: [*:0]const u8) GType;

// ---- GTK4 main loop (replaces gtk_main / gtk_main_quit) --------------------

extern fn g_main_loop_new(ctx: ?*anyopaque, is_running: gboolean) *GMainLoop;
extern fn g_main_loop_run(loop: *GMainLoop) void;
extern fn g_main_loop_quit(loop: *GMainLoop) void;
extern fn g_main_loop_unref(loop: *GMainLoop) void;
extern fn g_main_context_iteration(ctx: ?*anyopaque, may_block: gboolean) gboolean;
extern fn g_main_context_default() ?*anyopaque;

// ---- GdkSurface / GdkToplevel for window-state queries ---------------------

extern fn gtk_native_get_surface(native: *GtkWidget) ?*GdkSurface;
extern fn gdk_toplevel_get_state(toplevel: *GdkToplevel) GdkToplevelState;

// ---- GLib / GObject externs (unchanged between GTK3 and GTK4) --------------

extern fn g_signal_connect_data(
    instance: ?*anyopaque,
    detailed_signal: [*:0]const u8,
    handler: GCallback,
    data: ?*anyopaque,
    destroy_data: GClosureNotify,
    connect_flags: GConnectFlags,
) c_ulong;
extern fn g_signal_handler_disconnect(instance: *anyopaque, handler_id: c_ulong) void;
extern fn g_object_new(g_type: GType, first_prop: ?[*:0]const u8, ...) ?*anyopaque;
extern fn g_object_get(
    object: *GtkSettings,
    first_property_name: [*:0]const u8,
    out: *gboolean,
    sentinel: ?*anyopaque,
) void;
extern fn g_object_ref(o: ?*anyopaque) ?*anyopaque;
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
extern fn g_list_length(list: ?*GList) c_uint;
extern fn g_list_nth_data(list: ?*GList, n: c_uint) ?*anyopaque;
extern fn g_list_free_full(list: ?*GList, destroy: GDestroyNotify) void;
extern fn g_strfreev(strv: ?[*]const ?[*:0]const u8) void;

// ---- GLib IO channel externs (for deep_link.attachUrlSocket) ---------------

const GIOFunc = *const fn (source: *GIOChannel, cond: GIOCondition, data: ?*anyopaque) callconv(.c) gboolean;

extern fn g_io_channel_unix_new(fd: c_int) *GIOChannel;
extern fn g_io_channel_set_close_on_unref(channel: *GIOChannel, do_close: gboolean) void;
extern fn g_io_add_watch(channel: *GIOChannel, cond: GIOCondition, func: GIOFunc, data: ?*anyopaque) c_uint;
extern fn g_io_channel_unref(channel: *GIOChannel) void;

extern "c" fn recv(fd: c_int, buf: *anyopaque, len: usize, flags: c_int) isize;

// ---- GBytes externs (GTK4 clipboard content provider) ----------------------

extern fn g_bytes_new(data: [*]const u8, size: usize) *GBytes;
extern fn g_bytes_unref(bytes: *GBytes) void;

// ---- GtkSettings (color-scheme query) --------------------------------------

extern fn gtk_settings_get_default() ?*GtkSettings;

// ---- GTK4 accessibility (replaces ATK) -------------------------------------
//
// GTK4 removes ATK. Accessibility is now exposed via gtk_accessible_update_property
// (variadic in C — Zig 0.16.0 uses `...`).

extern fn gtk_accessible_update_property(accessible: *GtkWidget, first_property: GtkAccessibleProperty, ...) void;

// ---- GdkClipboard externs (replaces GtkClipboard in GTK4) -----------------

extern fn gdk_display_get_default() ?*GdkDisplay;
extern fn gdk_display_get_clipboard(display: *GdkDisplay) *GdkClipboard;
extern fn gdk_clipboard_set_text(clipboard: *GdkClipboard, text: [*:0]const u8) void;
extern fn gdk_clipboard_read_text_async(
    clipboard: *GdkClipboard,
    cancellable: ?*GCancellable,
    callback: GAsyncReadyCallback,
    user_data: ?*anyopaque,
) void;
extern fn gdk_clipboard_read_text_finish(
    clipboard: *GdkClipboard,
    result: *GAsyncResult,
    err: ?*?*GError,
) ?[*:0]u8;
extern fn gdk_clipboard_set_texture(clipboard: *GdkClipboard, texture: *GdkTexture) void;
extern fn gdk_clipboard_read_texture_async(
    clipboard: *GdkClipboard,
    cancellable: ?*GCancellable,
    callback: GAsyncReadyCallback,
    user_data: ?*anyopaque,
) void;
extern fn gdk_clipboard_read_texture_finish(
    clipboard: *GdkClipboard,
    result: *GAsyncResult,
    err: ?*?*GError,
) ?*GdkTexture;
extern fn gdk_texture_download(texture: *GdkTexture, data: [*]u8, stride: usize) void;
extern fn gdk_texture_get_width(texture: *GdkTexture) c_int;
extern fn gdk_texture_get_height(texture: *GdkTexture) c_int;
extern fn gdk_content_provider_new_for_bytes(mime_type: [*:0]const u8, bytes: *GBytes) *GdkContentProvider;
extern fn gdk_clipboard_set_content(clipboard: *GdkClipboard, provider: ?*GdkContentProvider) gboolean;
extern fn gdk_clipboard_read_async(
    clipboard: *GdkClipboard,
    mime_types: [*]const ?[*:0]const u8,
    io_priority: c_int,
    cancellable: ?*GCancellable,
    callback: GAsyncReadyCallback,
    user_data: ?*anyopaque,
) void;
extern fn gdk_clipboard_read_finish(
    clipboard: *GdkClipboard,
    result: *GAsyncResult,
    out_mime_type: ?*?[*:0]const u8,
    err: ?*?*GError,
) ?*GInputStream;

// ---- GdkPixbuf externs (image clipboard, same API in GTK4) -----------------

extern fn gdk_pixbuf_loader_new() *GdkPixbufLoader;
extern fn gdk_pixbuf_loader_write(l: *GdkPixbufLoader, buf: [*]const u8, count: usize, err: ?*?*GError) gboolean;
extern fn gdk_pixbuf_loader_close(l: *GdkPixbufLoader, err: ?*?*GError) gboolean;
extern fn gdk_pixbuf_loader_get_pixbuf(l: *GdkPixbufLoader) ?*GdkPixbuf;
extern fn gdk_pixbuf_save_to_bufferv(
    pixbuf: *GdkPixbuf,
    buffer: *?[*]u8,
    buffer_size: *usize,
    type_str: [*:0]const u8,
    option_keys: ?[*:null]const ?[*:0]const u8,
    option_values: ?[*:null]const ?[*:0]const u8,
    err: ?*?*GError,
) gboolean;
extern fn gdk_pixbuf_new_from_data(
    data: [*]const u8,
    colorspace: c_int,
    has_alpha: gboolean,
    bits_per_sample: c_int,
    width: c_int,
    height: c_int,
    rowstride: c_int,
    destroy_fn: ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void,
    destroy_fn_data: ?*anyopaque,
) ?*GdkPixbuf;

// ---- GTK4 dialog externs (GTK 4.10+) ---------------------------------------
//
// GtkAlertDialog replaces GtkMessageDialog + gtk_dialog_run.
// GtkFileDialog replaces GtkFileChooserNative + gtk_native_dialog_run.
// Both use async APIs; the sync-wrap pattern matches the cookie store.

extern fn gtk_alert_dialog_new(format: [*:0]const u8, ...) *GtkAlertDialog;
extern fn gtk_alert_dialog_set_message(d: *GtkAlertDialog, msg: [*:0]const u8) void;
extern fn gtk_alert_dialog_set_detail(d: *GtkAlertDialog, detail: [*:0]const u8) void;
extern fn gtk_alert_dialog_set_buttons(d: *GtkAlertDialog, labels: [*]const ?[*:0]const u8) void;
extern fn gtk_alert_dialog_set_default_button(d: *GtkAlertDialog, button: c_int) void;
extern fn gtk_alert_dialog_choose(
    d: *GtkAlertDialog,
    parent: ?*GtkWindow,
    cancellable: ?*GCancellable,
    callback: GAsyncReadyCallback,
    user_data: ?*anyopaque,
) void;
extern fn gtk_alert_dialog_choose_finish(
    d: *GtkAlertDialog,
    result: *GAsyncResult,
    err: ?*?*GError,
) c_int;

extern fn gtk_file_dialog_new() *GtkFileDialog;
extern fn gtk_file_dialog_set_title(d: *GtkFileDialog, title: [*:0]const u8) void;
extern fn gtk_file_dialog_set_initial_name(d: *GtkFileDialog, name: [*:0]const u8) void;
extern fn gtk_file_dialog_open(
    d: *GtkFileDialog,
    parent: ?*GtkWindow,
    cancellable: ?*GCancellable,
    callback: GAsyncReadyCallback,
    user_data: ?*anyopaque,
) void;
extern fn gtk_file_dialog_open_finish(
    d: *GtkFileDialog,
    result: *GAsyncResult,
    err: ?*?*GError,
) ?*GFile;
extern fn gtk_file_dialog_save(
    d: *GtkFileDialog,
    parent: ?*GtkWindow,
    cancellable: ?*GCancellable,
    callback: GAsyncReadyCallback,
    user_data: ?*anyopaque,
) void;
extern fn gtk_file_dialog_save_finish(
    d: *GtkFileDialog,
    result: *GAsyncResult,
    err: ?*?*GError,
) ?*GFile;
extern fn gtk_file_dialog_select_multiple_files(
    d: *GtkFileDialog,
    parent: ?*GtkWindow,
    cancellable: ?*GCancellable,
    callback: GAsyncReadyCallback,
    user_data: ?*anyopaque,
) void;
extern fn gtk_file_dialog_select_multiple_files_finish(
    d: *GtkFileDialog,
    result: *GAsyncResult,
    err: ?*?*GError,
) ?*GListModel;
extern fn g_file_get_path(file: *GFile) ?[*:0]u8;

// ---- GTK4 print externs (carry over from linux.zig) ------------------------

extern fn webkit_print_operation_new(wv: *WebKitWebView) ?*WebKitPrintOperation;
extern fn webkit_print_operation_run_dialog(op: *WebKitPrintOperation, parent: ?*GtkWindow) c_uint;
extern fn webkit_print_operation_set_print_settings(op: *WebKitPrintOperation, settings: *GtkPrintSettings) void;
extern fn gtk_print_settings_new() *GtkPrintSettings;
extern fn gtk_print_settings_set_n_copies(settings: *GtkPrintSettings, n: c_int) void;
extern fn gtk_print_settings_set_page_ranges(settings: *GtkPrintSettings, ranges: [*]const GtkPageRange, num_ranges: c_int) void;
extern fn gtk_print_settings_set_print_pages(settings: *GtkPrintSettings, pages: c_int) void;
extern fn gtk_print_settings_set_printer(settings: *GtkPrintSettings, printer: [*:0]const u8) void;

// ---- WebKitGTK 6.0 externs --------------------------------------------------
//
// Mostly the same as WebKitGTK 4.1. Key changes:
//   - webkit_user_content_manager_register_script_message_handler takes
//     an extra world_name parameter (pass null for default world).
//   - webkit_web_view_run_javascript replaced by webkit_web_view_evaluate_javascript.
//   - Cookie manager accessed via webkit_web_view_get_network_session +
//     webkit_network_session_get_cookie_manager (no per-context cookie manager).

const WebKitURISchemeRequestCallback = *const fn (req: *WebKitURISchemeRequest, user_data: ?*anyopaque) callconv(.c) void;
const ScriptMessageCallback = *const fn (ucm: *WebKitUserContentManager, msg: *WebKitJavascriptResult, user_data: ?*anyopaque) callconv(.c) void;

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
// WK6: extra world_name parameter (pass null for default world)
extern fn webkit_user_content_manager_register_script_message_handler(
    ucm: *WebKitUserContentManager,
    name: [*:0]const u8,
    world_name: ?[*:0]const u8,
) gboolean;

extern fn webkit_user_script_new(
    source: [*:0]const u8,
    frames: WebKitUserContentInjectedFrames,
    time: WebKitUserScriptInjectionTime,
    whitelist: ?[*]const [*:0]const u8,
    blacklist: ?[*]const [*:0]const u8,
) *WebKitUserScript;
extern fn webkit_user_script_unref(s: *WebKitUserScript) void;

extern fn webkit_web_view_get_type() GType;
extern fn webkit_web_view_load_uri(wv: *WebKitWebView, uri: [*:0]const u8) void;
extern fn webkit_web_view_load_html(wv: *WebKitWebView, html: [*:0]const u8, base_uri: ?[*:0]const u8) void;
extern fn webkit_web_view_reload(wv: *WebKitWebView) void;
extern fn webkit_web_view_go_back(wv: *WebKitWebView) void;
extern fn webkit_web_view_go_forward(wv: *WebKitWebView) void;
extern fn webkit_web_view_can_go_back(wv: *WebKitWebView) gboolean;
extern fn webkit_web_view_can_go_forward(wv: *WebKitWebView) gboolean;
extern fn webkit_web_view_get_uri(wv: *WebKitWebView) ?[*:0]const u8;
extern fn webkit_web_view_get_title(wv: *WebKitWebView) ?[*:0]const u8;
extern fn webkit_web_view_set_zoom_level(wv: *WebKitWebView, level: f64) void;
extern fn webkit_web_view_get_zoom_level(wv: *WebKitWebView) f64;
extern fn webkit_web_view_get_settings(wv: *WebKitWebView) *WebKitSettings;
extern fn webkit_settings_set_enable_developer_extras(s: *WebKitSettings, enabled: gboolean) void;

// WK6: replaces webkit_web_view_run_javascript
extern fn webkit_web_view_evaluate_javascript(
    wv: *WebKitWebView,
    script: [*:0]const u8,
    length: isize,
    world_name: ?[*:0]const u8,
    source_uri: ?[*:0]const u8,
    cancellable: ?*GCancellable,
    callback: ?GAsyncReadyCallback,
    user_data: ?*anyopaque,
) void;

// WK6: network session replaces per-context cookie manager
extern fn webkit_web_view_get_network_session(wv: *WebKitWebView) *WebKitNetworkSession;
extern fn webkit_network_session_get_cookie_manager(session: *WebKitNetworkSession) *WebKitCookieManager;

// Snapshot
extern fn webkit_web_view_get_snapshot(
    web_view: *WebKitWebView,
    region: WebKitSnapshotRegion,
    options: WebKitSnapshotOptions,
    cancellable: ?*GCancellable,
    callback: GAsyncReadyCallback,
    user_data: ?*anyopaque,
) void;
extern fn webkit_web_view_get_snapshot_finish(
    web_view: *WebKitWebView,
    result: *GAsyncResult,
    err: ?*?*GError,
) ?*CairoSurface;

extern fn cairo_surface_write_to_png(surface: *CairoSurface, filename: [*:0]const u8) CairoStatus;
extern fn cairo_surface_destroy(surface: *CairoSurface) void;

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

// ---- Cookie manager / SoupCookie externs ------------------------------------

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

// ---- Implementation ---------------------------------------------------------

/// Per-window state. Each window owns its own WebKitWebContext so that
/// the URI scheme handler can be registered per-context. GTK4 adds
/// a GMainLoop per window for event loop control (replaces gtk_main /
/// gtk_main_quit).
const WindowCtx = struct {
    allocator: std.mem.Allocator,
    opts: opts_mod.WindowOptions,
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
    main_loop: ?*GMainLoop = null,
    window: ?*GtkWidget = null,
    webview: ?*WebKitWebView = null,
    web_context: ?*WebKitWebContext = null,
    ucm: ?*WebKitUserContentManager = null,
    min_width: c_int = 0,
    min_height: c_int = 0,
    max_width: c_int = 0,
    max_height: c_int = 0,
    url_socket_fd: c_int = -1,
    url_socket_watch: c_uint = 0,
    color_scheme_signal: c_ulong = 0,
    close_signal: c_ulong = 0,
    resize_signal: c_ulong = 0,
    focus_in_signal: c_ulong = 0,
    focus_out_signal: c_ulong = 0,
    drag_signal: c_ulong = 0,
};

// GTK4 has no automatic last-window tracking. Count live windows and
// quit the GMainLoop when the last one closes — same semantics as the
// GTK3 backend.
var live_windows: u32 = 0;

pub const Window = struct {
    ctx: *WindowCtx,

    pub fn init(allocator: std.mem.Allocator, opts: opts_mod.WindowOptions) !Window {
        _ = allocator;
        _ = opts;
        return error.TODO;
    }

    pub fn run(self: *Window) void {
        _ = self;
    }

    pub fn deinit(self: *Window) void {
        _ = self;
    }

    pub fn terminate(self: *Window) void {
        _ = self;
    }

    pub fn close(self: *Window) void {
        _ = self;
    }

    pub fn setTitle(self: *Window, title: []const u8) void {
        _ = self;
        _ = title;
    }

    pub fn loadUrl(self: *Window, url: []const u8) !void {
        _ = self;
        _ = url;
        return error.TODO;
    }

    pub fn loadHtml(self: *Window, html: []const u8, base_url: ?[]const u8) !void {
        _ = self;
        _ = html;
        _ = base_url;
        return error.TODO;
    }

    pub fn evalJs(self: *Window, script: []const u8) void {
        _ = self;
        _ = script;
    }

    pub fn setMessageHandler(self: *Window, handler: opts_mod.MessageHandler, handler_ctx: ?*anyopaque) void {
        _ = self;
        _ = handler;
        _ = handler_ctx;
    }

    pub fn openChildWindow(self: *Window, opts: opts_mod.WindowOptions) !Window {
        _ = self;
        _ = opts;
        return error.TODO;
    }

    pub fn cookies(self: *Window) cookies_mod.CookieStore {
        return .{ .window = @ptrCast(self) };
    }

    pub fn clipboard(self: *Window) clipboard_mod.Clipboard {
        return .{ .window = @ptrCast(self) };
    }

    pub fn setColorSchemeHandler(self: *Window, cb: ?opts_mod.ColorSchemeHandler, ctx: ?*anyopaque) void {
        _ = self;
        _ = cb;
        _ = ctx;
    }

    pub fn setUrlOpenHandler(self: *Window, cb: ?opts_mod.UrlOpenHandler, ctx: ?*anyopaque) void {
        _ = self;
        _ = cb;
        _ = ctx;
    }

    pub fn print(self: *Window) void {
        self.printWithOptions(.{}) catch {};
    }

    pub fn printWithOptions(self: *Window, opts: opts_mod.PrintOptions) opts_mod.PrintError!void {
        _ = self;
        _ = opts;
        return error.TODO;
    }

    pub fn setAccessibilityLabel(self: *Window, label: []const u8) void {
        _ = self;
        _ = label;
    }

    pub fn setAccessibilityHelp(self: *Window, text: []const u8) void {
        _ = self;
        _ = text;
    }

    pub fn setAccessibilityRoleDescription(self: *Window, text: []const u8) void {
        _ = self;
        _ = text;
        std.log.info("verve.desktop[linux-gtk4]: setAccessibilityRoleDescription no-op (GTK4 accessible API uses enum properties)", .{});
    }

    pub fn setAccessibilitySubrole(self: *Window, subrole: opts_mod.AccessibilitySubrole) void {
        _ = self;
        _ = subrole;
        std.log.info("verve.desktop[linux-gtk4]: setAccessibilitySubrole no-op (no GTK4 subrole)", .{});
    }

    pub fn setAlwaysOnTop(self: *Window, on: bool) void {
        _ = self;
        _ = on;
    }

    pub fn setOpacity(self: *Window, value: f64) void {
        _ = self;
        _ = value;
    }

    pub fn setSize(self: *Window, width: u32, height: u32) void {
        _ = self;
        _ = width;
        _ = height;
    }

    pub fn setPosition(self: *Window, x: i32, y: i32) void {
        _ = self;
        _ = x;
        _ = y;
    }

    pub fn center(self: *Window) void {
        _ = self;
    }

    pub fn minimize(self: *Window) void {
        _ = self;
    }

    pub fn maximize(self: *Window) void {
        _ = self;
    }

    pub fn restore(self: *Window) void {
        _ = self;
    }

    pub fn setFullscreen(self: *Window, on: bool) void {
        _ = self;
        _ = on;
    }

    pub fn show(self: *Window) void {
        _ = self;
    }

    pub fn hide(self: *Window) void {
        _ = self;
    }

    pub fn focus(self: *Window) void {
        _ = self;
    }

    pub fn setResizable(self: *Window, on: bool) void {
        _ = self;
        _ = on;
    }

    pub fn setResizeHandler(self: *Window, cb: ?opts_mod.ResizeHandler, ctx: ?*anyopaque) void {
        _ = self;
        _ = cb;
        _ = ctx;
    }

    pub fn setFocusHandler(self: *Window, cb: ?opts_mod.FocusHandler, ctx: ?*anyopaque) void {
        _ = self;
        _ = cb;
        _ = ctx;
    }

    pub fn setCloseHandler(self: *Window, cb: ?opts_mod.CloseHandler, ctx: ?*anyopaque) void {
        _ = self;
        _ = cb;
        _ = ctx;
    }

    pub fn setMinSize(self: *Window, width: u32, height: u32) void {
        _ = self;
        _ = width;
        _ = height;
    }

    pub fn setMaxSize(self: *Window, width: u32, height: u32) void {
        _ = self;
        _ = width;
        _ = height;
    }

    pub fn reload(self: *Window) void {
        _ = self;
    }

    pub fn goBack(self: *Window) void {
        _ = self;
    }

    pub fn goForward(self: *Window) void {
        _ = self;
    }

    pub fn canGoBack(self: *Window) bool {
        _ = self;
        return false;
    }

    pub fn canGoForward(self: *Window) bool {
        _ = self;
        return false;
    }

    pub fn currentUrl(self: *Window, allocator: std.mem.Allocator) ![]u8 {
        _ = self;
        return allocator.dupe(u8, "");
    }

    pub fn currentTitle(self: *Window, allocator: std.mem.Allocator) ![]u8 {
        _ = self;
        return allocator.dupe(u8, "");
    }

    pub fn setZoom(self: *Window, level: f64) void {
        _ = self;
        _ = level;
    }

    pub fn getZoom(self: *Window) f64 {
        _ = self;
        return 1.0;
    }

    pub fn scaleFactor(self: *Window) f32 {
        _ = self;
        return 1.0;
    }

    pub fn isMinimized(self: *Window) bool {
        _ = self;
        return false;
    }

    pub fn isMaximized(self: *Window) bool {
        _ = self;
        return false;
    }

    pub fn isFullscreen(self: *Window) bool {
        _ = self;
        return false;
    }

    pub fn requestAttention(self: *Window, critical: bool) void {
        _ = self;
        _ = critical;
    }

    pub fn setDragDropHandler(self: *Window, cb: ?opts_mod.DragDropHandler, ctx: ?*anyopaque) void {
        _ = self;
        _ = cb;
        _ = ctx;
    }

    pub fn deliverUrl(self: *Window, url: []const u8) void {
        _ = self;
        _ = url;
    }

    pub fn colorScheme(self: *Window) opts_mod.ColorScheme {
        _ = self;
        return .unknown;
    }

    pub fn openFileDialog(self: *Window, allocator: std.mem.Allocator, opts: opts_mod.FileDialogOptions) opts_mod.DialogError![]u8 {
        _ = self;
        _ = allocator;
        _ = opts;
        return error.TODO;
    }

    pub fn saveFileDialog(self: *Window, allocator: std.mem.Allocator, opts: opts_mod.FileDialogOptions) opts_mod.DialogError![]u8 {
        _ = self;
        _ = allocator;
        _ = opts;
        return error.TODO;
    }

    pub fn showAlert(self: *Window, opts: opts_mod.AlertOptions) usize {
        _ = self;
        _ = opts;
        return 0;
    }

    pub fn takeSnapshotPng(self: *Window, path: []const u8) opts_mod.SnapshotError!void {
        _ = self;
        _ = path;
        return error.TODO;
    }
};

// ---- Module-level functions (cookie + clipboard + socket) ------------------
//
// All stubs — implementations follow in tasks D through I.

pub fn attachUrlSocket(window: *Window, fd: c_int) !void {
    _ = window;
    _ = fd;
    return error.TODO;
}

pub fn cookieGet(window: *anyopaque, allocator: std.mem.Allocator, name: []const u8) opts_mod.CookieError!?opts_mod.Cookie {
    _ = window;
    _ = allocator;
    _ = name;
    return error.TODO;
}

pub fn cookieSet(window: *anyopaque, cookie: opts_mod.Cookie) opts_mod.CookieError!void {
    _ = window;
    _ = cookie;
    return error.TODO;
}

pub fn cookieDelete(window: *anyopaque, name: []const u8) opts_mod.CookieError!void {
    _ = window;
    _ = name;
    return error.TODO;
}

pub fn cookieClear(window: *anyopaque) opts_mod.CookieError!void {
    _ = window;
    return error.TODO;
}

pub fn clipboardWriteText(window: *anyopaque, text: []const u8) opts_mod.ClipboardError!void {
    _ = window;
    _ = text;
    return error.TODO;
}

pub fn clipboardReadText(window: *anyopaque, allocator: std.mem.Allocator) opts_mod.ClipboardError!?[]u8 {
    _ = window;
    _ = allocator;
    return error.TODO;
}

pub fn clipboardWriteHtml(window: *anyopaque, html: []const u8) opts_mod.ClipboardError!void {
    _ = window;
    _ = html;
    return error.TODO;
}

pub fn clipboardReadHtml(window: *anyopaque, allocator: std.mem.Allocator) opts_mod.ClipboardError!?[]u8 {
    _ = window;
    _ = allocator;
    return error.TODO;
}

pub fn clipboardWriteImage(window: *anyopaque, png: []const u8) opts_mod.ClipboardError!void {
    _ = window;
    _ = png;
    return error.TODO;
}

pub fn clipboardReadImage(window: *anyopaque, allocator: std.mem.Allocator) opts_mod.ClipboardError!?[]u8 {
    _ = window;
    _ = allocator;
    return error.TODO;
}
