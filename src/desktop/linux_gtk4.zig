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

// libsoup 3.x (WebKitGTK 6.0 dependency)
const SoupCookie = opaque {};
const GDateTime = opaque {};

// JavaScriptCore (present in WK6)
const JSCValue = opaque {};

// WebKitGTK 6.0 types
const WebKitWebView = opaque {};
const WebKitWebContext = opaque {};
const WebKitUserContentManager = opaque {};
const WebKitUserScript = opaque {};
const WebKitURISchemeRequest = opaque {};
const WebKitSettings = opaque {};
const WebKitCookieManager = opaque {};
const WebKitNetworkSession = opaque {};

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
// GTK4: gtk_window_set_geometry_hints removed. Use gtk_widget_set_size_request
// for minimum size. Maximum size has no GTK4 equivalent (Wayland compositor handles it).
extern fn gtk_widget_set_size_request(widget: *GtkWidget, width: c_int, height: c_int) void;

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

// ---- GValue / GSList (drag-drop file list) ----------------------------------

/// Minimal GValue layout: type tag + two 64-bit data slots.
/// Matches the GLib ABI on LP64 (all supported Linux targets).
const GValue = extern struct {
    g_type: GType,
    data: [2]u64,
};

/// Singly-linked list node (GLib GSList).
const GSList = extern struct {
    data: ?*anyopaque,
    next: ?*GSList,
};

extern fn g_value_get_boxed(value: *const GValue) ?*anyopaque;
extern fn gdk_file_list_get_files(file_list: *anyopaque) ?*GSList;

// ---- GTK4 accessibility (replaces ATK) -------------------------------------
//
// GTK4 removes ATK. Accessibility is now exposed via gtk_accessible_update_property
// (variadic in C — Zig 0.16.0 uses `...`).

extern fn gtk_accessible_update_property(accessible: *GtkWidget, first_property: GtkAccessibleProperty, ...) void;
extern fn g_value_init(value: *GValue, g_type: GType) *GValue;
extern fn g_value_set_string(value: *GValue, v_string: [*:0]const u8) void;
extern fn g_value_unset(value: *GValue) void;
extern fn gtk_accessible_update_property_value(
    accessible: *GtkWidget,
    n_properties: c_int,
    properties: [*]const GtkAccessibleProperty,
    values: [*]const GValue,
) void;

const G_TYPE_STRING: GType = 64; // 16 << 2 — GLib fundamental type

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
extern fn gdk_pixbuf_savev(
    pixbuf: *GdkPixbuf,
    filename: [*:0]const u8,
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
extern fn gdk_texture_new_for_pixbuf(pixbuf: *GdkPixbuf) *GdkTexture;

// ---- GInputStream externs (GTK4 async clipboard HTML read) -----------------

extern fn g_input_stream_read(
    stream: *GInputStream,
    buffer: [*]u8,
    count: usize,
    cancellable: ?*anyopaque,
    err: ?*?*GError,
) isize;
extern fn g_input_stream_close(
    stream: *GInputStream,
    cancellable: ?*anyopaque,
    err: ?*?*GError,
) gboolean;

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
const ScriptMessageCallback = *const fn (ucm: *WebKitUserContentManager, jsval: *JSCValue, user_data: ?*anyopaque) callconv(.c) void;

extern fn webkit_web_context_new() *WebKitWebContext;
extern fn webkit_web_context_register_uri_scheme(
    ctx: *WebKitWebContext,
    scheme: [*:0]const u8,
    cb: WebKitURISchemeRequestCallback,
    user_data: ?*anyopaque,
    destroy: ?*const fn (?*anyopaque) callconv(.c) void,
) void;
extern fn webkit_web_context_set_sandbox_enabled(ctx: *WebKitWebContext, enabled: gboolean) void;

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
    callback: GAsyncReadyCallback,
    user_data: ?*anyopaque,
) void;

// WK6: network session replaces per-context cookie manager
extern fn webkit_web_view_get_network_session(wv: *WebKitWebView) *WebKitNetworkSession;
extern fn webkit_network_session_get_cookie_manager(session: *WebKitNetworkSession) *WebKitCookieManager;

extern fn webkit_uri_scheme_request_get_uri(req: *WebKitURISchemeRequest) [*:0]const u8;
extern fn webkit_uri_scheme_request_finish(
    req: *WebKitURISchemeRequest,
    stream: *GInputStream,
    stream_length: c_long,
    content_type: [*:0]const u8,
) void;
extern fn webkit_uri_scheme_request_finish_error(req: *WebKitURISchemeRequest, err: *GError) void;

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
extern fn soup_cookie_get_expires(c: *SoupCookie) ?*GDateTime;
extern fn soup_cookie_get_same_site_policy(c: *SoupCookie) c_int;
extern fn soup_cookie_set_secure(c: *SoupCookie, v: gboolean) void;
extern fn soup_cookie_set_http_only(c: *SoupCookie, v: gboolean) void;
extern fn soup_cookie_set_same_site_policy(c: *SoupCookie, p: c_int) void;
extern fn soup_cookie_set_expires(c: *SoupCookie, date: ?*GDateTime) void;
extern fn g_date_time_new_from_unix_utc(t: i64) ?*GDateTime;
extern fn g_date_time_to_unix(dt: *GDateTime) i64;
extern fn g_date_time_unref(dt: *GDateTime) void;

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
    resize_signal_h: c_ulong = 0,
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
        std.log.debug("verve.desktop[linux-gtk4]: gtk_init", .{});
        gtk_init();

        const heap = try allocator.create(WindowCtx);
        errdefer allocator.destroy(heap);
        heap.* = .{
            .allocator = allocator,
            .opts = opts,
            .on_message = opts.on_message,
            .on_message_ctx = opts.on_message_ctx,
            .on_url_open = opts.on_url_open,
            .on_url_open_ctx = opts.on_url_open_ctx,
            .on_drag_drop = opts.on_drag_drop,
            .on_drag_drop_ctx = opts.on_drag_drop_ctx,
            .on_resize = opts.on_resize,
            .on_resize_ctx = opts.on_resize_ctx,
            .on_focus = opts.on_focus,
            .on_focus_ctx = opts.on_focus_ctx,
            .on_close = opts.on_close,
            .on_close_ctx = opts.on_close_ctx,
        };

        // GTK4: gtk_window_new() takes no type argument.
        const window_widget = gtk_window_new();
        heap.window = window_widget;

        const title_z = try allocator.dupeZ(u8, opts.title);
        defer allocator.free(title_z);
        gtk_window_set_title(@ptrCast(window_widget), title_z.ptr);
        gtk_window_set_default_size(@ptrCast(window_widget), @intCast(opts.width), @intCast(opts.height));

        // "destroy" fires after the window has been torn down.
        _ = g_signal_connect_data(window_widget, "destroy", @as(GCallback, @ptrCast(&onDestroy)), @ptrCast(heap), null, 0);

        // GTK4: "close-request" replaces "delete-event". Returns gboolean:
        // 1 = block close, 0 = allow close.
        _ = g_signal_connect_data(window_widget, "close-request", @as(GCallback, @ptrCast(&onCloseRequest)), @ptrCast(heap), null, 0);

        // Per-window WebContext. Scheme handlers must be registered
        // BEFORE the WebView is constructed; the WebView resolves its
        // context-bound handlers at first navigation.
        const web_ctx = webkit_web_context_new();
        heap.web_context = web_ctx;
        // bubblewrap sandbox requires unprivileged user namespaces; disable
        // if the kernel doesn't support them (sysctl kernel.unprivileged_userns_clone=0).
        webkit_web_context_set_sandbox_enabled(web_ctx, 0);
        const scheme_z = try allocator.dupeZ(u8, opts.scheme);
        defer allocator.free(scheme_z);
        std.log.debug("verve.desktop[linux-gtk4]: register scheme '{s}://' (per-window context)", .{opts.scheme});
        webkit_web_context_register_uri_scheme(web_ctx, scheme_z.ptr, &onSchemeRequest, @ptrCast(heap), null);

        const ucm = webkit_user_content_manager_new();
        heap.ucm = ucm;
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

        // WK6: extra null world_name parameter for default world.
        _ = webkit_user_content_manager_register_script_message_handler(ucm, "verve", null);
        _ = g_signal_connect_data(ucm, "script-message-received::verve", @as(GCallback, @ptrCast(&onScriptMessage)), @ptrCast(heap), null, 0);

        // Construct WebView with BOTH our custom WebContext and our
        // UserContentManager. No WK6 single-call helper takes both,
        // so go through g_object_new with explicit properties.
        const wv_obj = g_object_new(
            webkit_web_view_get_type(),
            "web-context",
            web_ctx,
            @as(?[*:0]const u8, "user-content-manager"),
            ucm,
            @as(?[*:0]const u8, null),
        ) orelse return error.WebViewCreateFailed;
        const wv: *WebKitWebView = @ptrCast(wv_obj);
        heap.webview = wv;

        if (opts.devtools) {
            const settings = webkit_web_view_get_settings(wv);
            webkit_settings_set_enable_developer_extras(settings, 1);
        }

        // GTK4: gtk_window_set_child replaces gtk_container_add.
        // Menu bar has no GtkApplication-free GTK4 equivalent — skip.
        if (opts.install_default_menu) {
            std.log.debug("verve.desktop[linux-gtk4]: install_default_menu skipped (no GtkApplication-free menu bar in GTK4)", .{});
        }
        gtk_window_set_child(@ptrCast(window_widget), @ptrCast(wv));

        // GTK4: gtk_widget_show replaces gtk_widget_show_all.
        gtk_widget_show(window_widget);
        live_windows += 1;
        std.log.info("verve.desktop[linux-gtk4]: window shown ({d}x{d})", .{ opts.width, opts.height });

        heap.main_loop = g_main_loop_new(null, 0);

        // Initial navigation.
        if (opts.initial_path.len > 0) {
            var url_buf: [1024]u8 = undefined;
            const url = try std.fmt.bufPrintZ(&url_buf, "{s}://app/{s}", .{ opts.scheme, opts.initial_path });
            std.log.debug("verve.desktop[linux-gtk4]: navigate {s}", .{url});
            webkit_web_view_load_uri(wv, url.ptr);
        }

        return Window{ .ctx = heap };
    }

    pub fn run(self: *Window) void {
        g_main_loop_run(self.ctx.main_loop.?);
    }

    pub fn deinit(self: *Window) void {
        const alloc = self.ctx.allocator;
        if (self.ctx.main_loop) |loop| g_main_loop_unref(loop);
        if (self.ctx.web_context) |wc| g_object_unref(wc);
        alloc.destroy(self.ctx);
        // Window is returned by value from init — caller owns it; do NOT destroy self here.
    }

    pub fn terminate(self: *Window) void {
        if (self.ctx.main_loop) |loop| g_main_loop_quit(loop);
    }

    pub fn close(self: *Window) void {
        if (self.ctx.window) |w| gtk_window_destroy(@ptrCast(w));
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
        webkit_web_view_evaluate_javascript(wv, z.ptr, -1, null, null, null, null, null);
    }

    pub fn setMessageHandler(self: *Window, handler: opts_mod.MessageHandler, handler_ctx: ?*anyopaque) void {
        self.ctx.on_message = handler;
        self.ctx.on_message_ctx = handler_ctx;
    }

    /// Open a second window in the same GTK main loop. Returned
    /// Window owns its own GtkWindow + WebKitWebContext + WebView;
    /// the GMainLoop quits only when the last live window closes.
    pub fn openChildWindow(self: *Window, opts: opts_mod.WindowOptions) !Window {
        return Window.init(self.ctx.allocator, opts);
    }

    pub fn cookies(self: *Window) cookies_mod.CookieStore {
        return .{ .window = @ptrCast(self) };
    }

    pub fn clipboard(self: *Window) clipboard_mod.Clipboard {
        return .{ .window = @ptrCast(self) };
    }

    pub fn setColorSchemeHandler(self: *Window, cb: ?opts_mod.ColorSchemeHandler, ctx_ptr: ?*anyopaque) void {
        self.ctx.on_color_scheme = cb;
        self.ctx.on_color_scheme_ctx = ctx_ptr;
        if (self.ctx.color_scheme_signal == 0 and cb != null) {
            const settings = gtk_settings_get_default() orelse return;
            const sig = g_signal_connect_data(
                @ptrCast(settings),
                "notify::gtk-application-prefer-dark-theme",
                @as(GCallback, @ptrCast(&onColorSchemeChanged)),
                @ptrCast(self.ctx),
                null,
                0,
            );
            self.ctx.color_scheme_signal = sig;
        } else if (cb == null and self.ctx.color_scheme_signal != 0) {
            const settings = gtk_settings_get_default() orelse return;
            g_signal_handler_disconnect(@ptrCast(settings), self.ctx.color_scheme_signal);
            self.ctx.color_scheme_signal = 0;
        }
    }

    pub fn setUrlOpenHandler(self: *Window, cb: ?opts_mod.UrlOpenHandler, ctx_ptr: ?*anyopaque) void {
        self.ctx.on_url_open = cb;
        self.ctx.on_url_open_ctx = ctx_ptr;
    }

    pub fn print(self: *Window) void {
        self.printWithOptions(.{}) catch {};
    }

    pub fn printWithOptions(self: *Window, opts: opts_mod.PrintOptions) opts_mod.PrintError!void {
        const wv = self.ctx.webview orelse return opts_mod.PrintError.Backend;
        const op = webkit_print_operation_new(wv) orelse return opts_mod.PrintError.Backend;
        defer g_object_unref(@ptrCast(op));

        if (opts.copies > 1 or opts.pages != null or opts.printer_name != null) {
            const settings = gtk_print_settings_new();
            defer g_object_unref(@ptrCast(settings));

            if (opts.copies > 1) gtk_print_settings_set_n_copies(settings, @intCast(opts.copies));

            if (opts.pages) |range| {
                const start: c_int = @intCast(@max(range.from, 1) - 1);
                const end: c_int = if (range.to == 0) std.math.maxInt(c_int) else @intCast(range.to - 1);
                const gtk_ranges = [_]GtkPageRange{.{ .start = start, .end = end }};
                gtk_print_settings_set_page_ranges(settings, &gtk_ranges, 1);
                gtk_print_settings_set_print_pages(settings, GTK_PRINT_PAGES_RANGES);
            }

            if (opts.printer_name) |pname| {
                const z = self.ctx.allocator.dupeZ(u8, pname) catch return opts_mod.PrintError.OutOfMemory;
                defer self.ctx.allocator.free(z);
                gtk_print_settings_set_printer(settings, z.ptr);
            }

            webkit_print_operation_set_print_settings(op, settings);
        }

        const parent: ?*GtkWindow = if (self.ctx.window) |w| @ptrCast(w) else null;
        const response = webkit_print_operation_run_dialog(op, parent);
        if (response == WEBKIT_PRINT_OPERATION_RESPONSE_CANCEL) return opts_mod.PrintError.Cancelled;
        std.log.info("verve.desktop[linux-gtk4]: print dialog response={d} (copies={d})", .{ response, opts.copies });
    }

    pub fn setAccessibilityLabel(self: *Window, label: []const u8) void {
        const window = self.ctx.window orelse return;
        var buf: [1024]u8 = undefined;
        if (label.len >= buf.len) return;
        @memcpy(buf[0..label.len], label);
        buf[label.len] = 0;
        var value: GValue = std.mem.zeroes(GValue);
        _ = g_value_init(&value, G_TYPE_STRING);
        g_value_set_string(&value, @ptrCast(&buf));
        defer g_value_unset(&value);
        const props = [1]GtkAccessibleProperty{GTK_ACCESSIBLE_PROPERTY_LABEL};
        gtk_accessible_update_property_value(window, 1, &props, &value);
    }

    pub fn setAccessibilityHelp(self: *Window, text: []const u8) void {
        const window = self.ctx.window orelse return;
        var buf: [1024]u8 = undefined;
        if (text.len >= buf.len) return;
        @memcpy(buf[0..text.len], text);
        buf[text.len] = 0;
        var value: GValue = std.mem.zeroes(GValue);
        _ = g_value_init(&value, G_TYPE_STRING);
        g_value_set_string(&value, @ptrCast(&buf));
        defer g_value_unset(&value);
        const props = [1]GtkAccessibleProperty{GTK_ACCESSIBLE_PROPERTY_DESCRIPTION};
        gtk_accessible_update_property_value(window, 1, &props, &value);
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

    /// GTK4 removed `gtk_window_set_keep_above` (Wayland does not
    /// expose this as a reliable client-side hint). Log and return.
    pub fn setAlwaysOnTop(self: *Window, on: bool) void {
        _ = self;
        _ = on;
        std.log.debug("verve.desktop[linux-gtk4]: setAlwaysOnTop not reliably supported in GTK4", .{});
    }

    /// Window-wide opacity in `[0.0, 1.0]`. `gtk_widget_set_opacity`
    /// composites through the active compositor; opaque-only Wayland
    /// sessions silently clamp to 1.0.
    pub fn setOpacity(self: *Window, value: f64) void {
        const w = self.ctx.window orelse return;
        gtk_widget_set_opacity(w, std.math.clamp(value, 0.0, 1.0));
    }

    pub fn setSize(self: *Window, width: u32, height: u32) void {
        const w = self.ctx.window orelse return;
        gtk_window_set_default_size(@ptrCast(w), @intCast(width), @intCast(height));
    }

    /// GTK4/Wayland does not permit arbitrary window positioning.
    pub fn setPosition(self: *Window, x: i32, y: i32) void {
        _ = self;
        _ = x;
        _ = y;
        std.log.debug("verve.desktop[linux-gtk4]: setPosition not supported in GTK4 (Wayland)", .{});
    }

    /// GTK4 removed `gtk_window_set_position`; centering is compositor-managed.
    pub fn center(self: *Window) void {
        _ = self;
        std.log.debug("verve.desktop[linux-gtk4]: center not supported in GTK4 (Wayland)", .{});
    }

    pub fn minimize(self: *Window) void {
        const w = self.ctx.window orelse return;
        gtk_window_minimize(@ptrCast(w));
    }

    pub fn maximize(self: *Window) void {
        const w = self.ctx.window orelse return;
        gtk_window_maximize(@ptrCast(w));
    }

    pub fn restore(self: *Window) void {
        const w = self.ctx.window orelse return;
        gtk_window_unmaximize(@ptrCast(w));
        gtk_window_present(@ptrCast(w));
    }

    pub fn setFullscreen(self: *Window, on: bool) void {
        const w = self.ctx.window orelse return;
        if (on) gtk_window_fullscreen(@ptrCast(w)) else gtk_window_unfullscreen(@ptrCast(w));
    }

    pub fn show(self: *Window) void {
        const w = self.ctx.window orelse return;
        gtk_widget_show(w);
        gtk_window_present(@ptrCast(w));
    }

    pub fn hide(self: *Window) void {
        const w = self.ctx.window orelse return;
        gtk_widget_hide(w);
    }

    pub fn focus(self: *Window) void {
        const w = self.ctx.window orelse return;
        gtk_window_present(@ptrCast(w));
    }

    pub fn setResizable(self: *Window, on: bool) void {
        const w = self.ctx.window orelse return;
        gtk_window_set_resizable(@ptrCast(w), if (on) 1 else 0);
    }

    pub fn setResizeHandler(self: *Window, cb: ?opts_mod.ResizeHandler, ctx_ptr: ?*anyopaque) void {
        self.ctx.on_resize = cb;
        self.ctx.on_resize_ctx = ctx_ptr;
        const win = self.ctx.window orelse return;
        if (cb != null and self.ctx.resize_signal == 0) {
            const sig = g_signal_connect_data(
                win,
                "notify::default-width",
                @as(GCallback, @ptrCast(&onWindowSizeChanged)),
                @ptrCast(self.ctx),
                null,
                0,
            );
            self.ctx.resize_signal = sig;
            self.ctx.resize_signal_h = g_signal_connect_data(
                win,
                "notify::default-height",
                @as(GCallback, @ptrCast(&onWindowSizeChanged)),
                @ptrCast(self.ctx),
                null,
                0,
            );
        } else if (cb == null and self.ctx.resize_signal != 0) {
            g_signal_handler_disconnect(win, self.ctx.resize_signal);
            self.ctx.resize_signal = 0;
            if (self.ctx.resize_signal_h != 0) {
                g_signal_handler_disconnect(win, self.ctx.resize_signal_h);
                self.ctx.resize_signal_h = 0;
            }
        }
    }

    pub fn setFocusHandler(self: *Window, cb: ?opts_mod.FocusHandler, ctx_ptr: ?*anyopaque) void {
        self.ctx.on_focus = cb;
        self.ctx.on_focus_ctx = ctx_ptr;
        const win = self.ctx.window orelse return;
        if (cb != null and self.ctx.focus_in_signal == 0) {
            const focus_ctrl = gtk_event_controller_focus_new();
            gtk_widget_add_controller(win, @ptrCast(focus_ctrl));
            const sig_in = g_signal_connect_data(
                focus_ctrl,
                "enter",
                @as(GCallback, @ptrCast(&onFocusIn)),
                @ptrCast(self.ctx),
                null,
                0,
            );
            self.ctx.focus_in_signal = sig_in;
            const sig_out = g_signal_connect_data(
                focus_ctrl,
                "leave",
                @as(GCallback, @ptrCast(&onFocusOut)),
                @ptrCast(self.ctx),
                null,
                0,
            );
            self.ctx.focus_out_signal = sig_out;
        }
    }

    pub fn setCloseHandler(self: *Window, cb: ?opts_mod.CloseHandler, ctx: ?*anyopaque) void {
        self.ctx.on_close = cb;
        self.ctx.on_close_ctx = ctx;
    }

    /// Set minimum window size via gtk_widget_set_size_request.
    /// `(0, 0)` clears the minimum.
    pub fn setMinSize(self: *Window, width: u32, height: u32) void {
        self.ctx.min_width = @intCast(width);
        self.ctx.min_height = @intCast(height);
        applyGeometryHints(self.ctx);
    }

    pub fn setMaxSize(self: *Window, width: u32, height: u32) void {
        self.ctx.max_width = @intCast(width);
        self.ctx.max_height = @intCast(height);
        applyGeometryHints(self.ctx);
    }

    pub fn reload(self: *Window) void {
        const wv = self.ctx.webview orelse return;
        webkit_web_view_reload(wv);
    }

    pub fn goBack(self: *Window) void {
        const wv = self.ctx.webview orelse return;
        webkit_web_view_go_back(wv);
    }

    pub fn goForward(self: *Window) void {
        const wv = self.ctx.webview orelse return;
        webkit_web_view_go_forward(wv);
    }

    pub fn canGoBack(self: *Window) bool {
        const wv = self.ctx.webview orelse return false;
        return webkit_web_view_can_go_back(wv) != 0;
    }

    pub fn canGoForward(self: *Window) bool {
        const wv = self.ctx.webview orelse return false;
        return webkit_web_view_can_go_forward(wv) != 0;
    }

    pub fn currentUrl(self: *Window, allocator: std.mem.Allocator) ![]u8 {
        const wv = self.ctx.webview orelse return allocator.dupe(u8, "");
        const uri = webkit_web_view_get_uri(wv) orelse return allocator.dupe(u8, "");
        return allocator.dupe(u8, std.mem.span(uri));
    }

    pub fn currentTitle(self: *Window, allocator: std.mem.Allocator) ![]u8 {
        const wv = self.ctx.webview orelse return allocator.dupe(u8, "");
        const title = webkit_web_view_get_title(wv) orelse return allocator.dupe(u8, "");
        return allocator.dupe(u8, std.mem.span(title));
    }

    pub fn setZoom(self: *Window, level: f64) void {
        const wv = self.ctx.webview orelse return;
        webkit_web_view_set_zoom_level(wv, level);
    }

    pub fn getZoom(self: *Window) f64 {
        const wv = self.ctx.webview orelse return 1.0;
        return webkit_web_view_get_zoom_level(wv);
    }

    pub fn scaleFactor(self: *Window) f32 {
        const w = self.ctx.window orelse return 1.0;
        return @floatFromInt(gtk_widget_get_scale_factor(w));
    }

    pub fn isMinimized(self: *Window) bool {
        const w = self.ctx.window orelse return false;
        const surface = gtk_native_get_surface(@ptrCast(w)) orelse return false;
        const state = gdk_toplevel_get_state(@ptrCast(surface));
        return (state & GDK_TOPLEVEL_STATE_MINIMIZED) != 0;
    }

    pub fn isMaximized(self: *Window) bool {
        const w = self.ctx.window orelse return false;
        return gtk_window_is_maximized(@ptrCast(w)) != 0;
    }

    pub fn isFullscreen(self: *Window) bool {
        const w = self.ctx.window orelse return false;
        const surface = gtk_native_get_surface(@ptrCast(w)) orelse return false;
        const state = gdk_toplevel_get_state(@ptrCast(surface));
        return (state & GDK_TOPLEVEL_STATE_FULLSCREEN) != 0;
    }

    /// GTK4 removed `gtk_window_set_urgency_hint`. Best-effort: present
    /// the window to bring it to the user's attention.
    pub fn requestAttention(self: *Window, critical: bool) void {
        _ = critical;
        const w = self.ctx.window orelse return;
        gtk_window_present(@ptrCast(w));
    }

    pub fn setDragDropHandler(self: *Window, cb: ?opts_mod.DragDropHandler, ctx_ptr: ?*anyopaque) void {
        self.ctx.on_drag_drop = cb;
        self.ctx.on_drag_drop_ctx = ctx_ptr;
        const win = self.ctx.window orelse return;
        if (cb != null and self.ctx.drag_signal == 0) {
            // GdkFileList type — lazy-load via g_type_from_name.
            const file_list_type = g_type_from_name("GdkFileList");
            if (file_list_type == 0) {
                std.log.warn("verve.desktop[linux-gtk4]: GdkFileList type not registered — DnD unavailable", .{});
                return;
            }
            const drop_target = gtk_drop_target_new(file_list_type, GDK_ACTION_COPY);
            gtk_widget_add_controller(win, @ptrCast(drop_target));
            const sig = g_signal_connect_data(
                drop_target,
                "drop",
                @as(GCallback, @ptrCast(&onDrop)),
                @ptrCast(self.ctx),
                null,
                0,
            );
            self.ctx.drag_signal = sig;
        }
    }

    pub fn deliverUrl(self: *Window, url: []const u8) void {
        if (self.ctx.on_url_open) |cb| cb(self.ctx.on_url_open_ctx, url);
    }

    pub fn colorScheme(self: *Window) opts_mod.ColorScheme {
        _ = self;
        const settings = gtk_settings_get_default() orelse return .unknown;
        var prefer_dark: gboolean = 0;
        g_object_get(settings, "gtk-application-prefer-dark-theme", &prefer_dark, @as(?*anyopaque, null));
        return if (prefer_dark != 0) .dark else .light;
    }

    pub fn openFileDialog(self: *Window, allocator: std.mem.Allocator, opts: opts_mod.FileDialogOptions) opts_mod.DialogError![]u8 {
        const dialog = gtk_file_dialog_new();
        defer g_object_unref(dialog);

        if (opts.title.len > 0) {
            const t = allocator.dupeZ(u8, opts.title) catch return error.OutOfMemory;
            defer allocator.free(t);
            gtk_file_dialog_set_title(dialog, t.ptr);
        }

        const parent: ?*GtkWindow = if (self.ctx.window) |w| @ptrCast(w) else null;
        var cell: OpenFileCell = .{ .dialog = dialog };
        gtk_file_dialog_open(dialog, parent, null, &openFileCb, @ptrCast(&cell));
        pumpMainContextUntilDone(&cell.done);

        const gfile = cell.file orelse return error.Cancelled;
        defer g_object_unref(gfile);
        const raw = g_file_get_path(gfile) orelse return error.Unsupported;
        defer g_free(@ptrCast(raw));
        return allocator.dupe(u8, std.mem.span(raw)) catch error.OutOfMemory;
    }

    pub fn saveFileDialog(self: *Window, allocator: std.mem.Allocator, opts: opts_mod.FileDialogOptions) opts_mod.DialogError![]u8 {
        const dialog = gtk_file_dialog_new();
        defer g_object_unref(dialog);

        if (opts.title.len > 0) {
            const t = allocator.dupeZ(u8, opts.title) catch return error.OutOfMemory;
            defer allocator.free(t);
            gtk_file_dialog_set_title(dialog, t.ptr);
        }
        if (opts.default_name.len > 0) {
            const n = allocator.dupeZ(u8, opts.default_name) catch return error.OutOfMemory;
            defer allocator.free(n);
            gtk_file_dialog_set_initial_name(dialog, n.ptr);
        }

        const parent: ?*GtkWindow = if (self.ctx.window) |w| @ptrCast(w) else null;
        var cell: SaveFileCell = .{ .dialog = dialog };
        gtk_file_dialog_save(dialog, parent, null, &saveFileCb, @ptrCast(&cell));
        pumpMainContextUntilDone(&cell.done);

        const gfile = cell.file orelse return error.Cancelled;
        defer g_object_unref(gfile);
        const raw = g_file_get_path(gfile) orelse return error.Unsupported;
        defer g_free(@ptrCast(raw));
        return allocator.dupe(u8, std.mem.span(raw)) catch error.OutOfMemory;
    }

    pub fn showAlert(self: *Window, opts: opts_mod.AlertOptions) usize {
        const dialog = gtk_alert_dialog_new("%s", "");
        defer g_object_unref(dialog);

        // Message
        const msg_src = if (opts.message.len > 0) opts.message else " ";
        const msg_z = self.ctx.allocator.dupeZ(u8, msg_src) catch return 0;
        defer self.ctx.allocator.free(msg_z);
        gtk_alert_dialog_set_message(dialog, msg_z.ptr);

        // Buttons — build a null-terminated array of ?[*:0]const u8
        const btn_src = if (opts.buttons.len == 0) &[_][]const u8{"OK"} else opts.buttons;
        // stack-allocate up to 64 button pointers + null terminator
        var btn_ptrs: [65]?[*:0]const u8 = undefined;
        var btn_strs: [64][:0]u8 = undefined;
        const btn_count = @min(btn_src.len, 64);
        var allocated: usize = 0;
        for (btn_src[0..btn_count], 0..) |label, i| {
            const z = self.ctx.allocator.dupeZ(u8, label) catch break;
            btn_strs[i] = z;
            btn_ptrs[i] = z.ptr;
            allocated = i + 1;
        }
        btn_ptrs[allocated] = null;
        defer {
            for (0..allocated) |i| self.ctx.allocator.free(btn_strs[i]);
        }
        gtk_alert_dialog_set_buttons(dialog, &btn_ptrs);
        gtk_alert_dialog_set_default_button(dialog, 0);

        const parent: ?*GtkWindow = if (self.ctx.window) |w| @ptrCast(w) else null;
        var cell: AlertCell = .{ .dialog = dialog };
        gtk_alert_dialog_choose(dialog, parent, null, &alertCb, @ptrCast(&cell));
        pumpMainContextUntilDone(&cell.done);

        return if (cell.result < 0) 0 else @intCast(cell.result);
    }

    pub fn takeSnapshotPng(self: *Window, path: []const u8) opts_mod.SnapshotError!void {
        _ = self;
        _ = path;
        // webkit_web_view_snapshot not yet available in installed webkitgtk-6.0
        return error.Unsupported;
    }
};

// ---- Private signal handlers and helpers -----------------------------------

/// Apply size constraints to the window.
/// GTK4 dropped gtk_window_set_geometry_hints; min size uses
/// gtk_widget_set_size_request, max size is unsupported on Wayland.
fn applyGeometryHints(ctx: *WindowCtx) void {
    const win = ctx.window orelse return;
    // GTK4: gtk_window_set_geometry_hints removed. Use gtk_widget_set_size_request for min.
    // Max size has no GTK4 equivalent (Wayland compositor-enforced).
    if (ctx.min_width > 0 or ctx.min_height > 0) {
        gtk_widget_set_size_request(@ptrCast(win), ctx.min_width, ctx.min_height);
    }
    if (ctx.max_width > 0 or ctx.max_height > 0) {
        std.log.debug("verve.desktop[linux-gtk4]: setMaxSize not supported in GTK4/Wayland", .{});
    }
}

/// "destroy" fires after the GTK window has been torn down.
/// Decrements live_windows; quits the per-window GMainLoop when
/// the last window closes.
fn onDestroy(widget: *GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = widget;
    const ctx: *WindowCtx = @ptrCast(@alignCast(user_data));
    if (live_windows > 0) live_windows -= 1;
    if (live_windows == 0) {
        if (ctx.main_loop) |loop| g_main_loop_quit(loop);
    }
}

/// GTK4 "close-request" replaces GTK3 "delete-event".
/// Returns gboolean: 1 = block close, 0 = allow close.
/// on_close callback returns true to allow close, false to block.
fn onCloseRequest(widget: *GtkWidget, user_data: ?*anyopaque) callconv(.c) gboolean {
    _ = widget;
    const ctx: *WindowCtx = @ptrCast(@alignCast(user_data));
    if (ctx.on_close) |cb| {
        if (!cb(ctx.on_close_ctx)) return 1; // cb returns false = block close
    }
    return 0; // allow close
}

fn onScriptMessage(ucm: *WebKitUserContentManager, jsval: *JSCValue, user_data: ?*anyopaque) callconv(.c) void {
    _ = ucm;
    const ctx: *WindowCtx = @ptrCast(@alignCast(user_data));
    if (jsc_value_is_string(jsval) == 0) return;
    const str = jsc_value_to_string(jsval);
    defer g_free(@ptrCast(str));
    const slice = std.mem.span(str);
    // Intercept the title-sync marker before forwarding.
    const title_prefix = "__verve_title:";
    if (std.mem.startsWith(u8, slice, title_prefix)) {
        const title = slice[title_prefix.len..];
        const z = ctx.allocator.dupeZ(u8, title) catch return;
        defer ctx.allocator.free(z);
        if (ctx.window) |w| gtk_window_set_title(@ptrCast(w), z.ptr);
        return;
    }
    if (ctx.on_message) |cb| {
        cb(ctx.on_message_ctx, slice);
    }
}

/// GtkSettings property-notify trampoline. Fires on every change to
/// `gtk-application-prefer-dark-theme`; re-reads the property and
/// forwards the resulting ColorScheme to the user callback.
fn onColorSchemeChanged(settings: *GtkSettings, _: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const ctx: *WindowCtx = @ptrCast(@alignCast(user_data));
    var dark: gboolean = 0;
    g_object_get(settings, "gtk-application-prefer-dark-theme", &dark, @as(?*anyopaque, null));
    if (ctx.on_color_scheme) |cb| {
        cb(ctx.on_color_scheme_ctx, if (dark != 0) .dark else .light);
    }
}

/// `notify::default-width` / `notify::default-height` on GtkWindow.
/// GTK4 removed `configure-event`; property-notify is the replacement.
fn onWindowSizeChanged(win: *GtkWidget, _: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const ctx: *WindowCtx = @ptrCast(@alignCast(user_data));
    var w: c_int = 0;
    var h: c_int = 0;
    gtk_window_get_default_size(@ptrCast(win), &w, &h);
    if (ctx.on_resize) |cb| {
        cb(ctx.on_resize_ctx, @intCast(w), @intCast(h));
    }
}

/// GtkEventControllerFocus "enter" — window gained focus.
fn onFocusIn(_: *anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const ctx: *WindowCtx = @ptrCast(@alignCast(user_data));
    if (ctx.on_focus) |cb| cb(ctx.on_focus_ctx, true);
}

/// GtkEventControllerFocus "leave" — window lost focus.
fn onFocusOut(_: *anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const ctx: *WindowCtx = @ptrCast(@alignCast(user_data));
    if (ctx.on_focus) |cb| cb(ctx.on_focus_ctx, false);
}

/// GtkDropTarget "drop" signal. `value` holds a GdkFileList boxed type.
/// Extracts paths via `GSList`, builds a stack-allocated slice of up to
/// 64 entries (as `[]const u8` slices), then invokes the user callback.
fn onDrop(_: *GtkDropTarget, value: *const GValue, _: f64, _: f64, user_data: ?*anyopaque) callconv(.c) gboolean {
    const ctx: *WindowCtx = @ptrCast(@alignCast(user_data));
    const file_list_ptr = g_value_get_boxed(value) orelse return 0;
    const files = gdk_file_list_get_files(file_list_ptr) orelse return 0;

    // Stack buffer for up to 64 dropped file paths.
    // g_file_get_path returns a glib-allocated [*:0]u8; must be freed with g_free.
    var path_ptrs: [64][*:0]u8 = undefined;
    var paths_buf: [64][]const u8 = undefined;
    var count: usize = 0;
    var node: ?*GSList = files;
    while (node) |n| : (node = n.next) {
        if (count >= paths_buf.len) break;
        const gfile: *GFile = @ptrCast(@alignCast(n.data orelse continue));
        const path = g_file_get_path(gfile) orelse continue;
        path_ptrs[count] = path;
        paths_buf[count] = std.mem.span(path);
        count += 1;
    }

    if (ctx.on_drag_drop) |cb| {
        cb(ctx.on_drag_drop_ctx, paths_buf[0..count]);
    }
    for (path_ptrs[0..count]) |p| g_free(@ptrCast(p));
    return 1; // handled
}

fn onSchemeRequest(req: *WebKitURISchemeRequest, user_data: ?*anyopaque) callconv(.c) void {
    const cx: *WindowCtx = @ptrCast(@alignCast(user_data orelse return));

    const uri = webkit_uri_scheme_request_get_uri(req);
    const uri_slice = std.mem.span(uri);

    const auth = "://app/";
    const path: []const u8 = if (std.mem.indexOf(u8, uri_slice, auth)) |i| uri_slice[i + auth.len ..] else uri_slice;
    std.log.debug("verve.desktop[linux-gtk4]: scheme '{s}' → '{s}'", .{ uri_slice, path });

    const resolved = blk: {
        if (cx.opts.dev_assets) |dev| {
            break :blk router.resolveWithFallback(cx.allocator, dev.io, cx.opts.assets, path, dev.dir) catch {
                std.log.warn("verve.desktop[linux-gtk4]: 404 {s}", .{path});
                const err = g_error_new_literal(g_quark_from_static_string("verve"), 404, "not found");
                webkit_uri_scheme_request_finish_error(req, err);
                g_error_free(err);
                return;
            };
        }
        break :blk router.resolve(cx.opts.assets, path) catch {
            std.log.warn("verve.desktop[linux-gtk4]: 404 {s}", .{path});
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
            std.log.warn("verve.desktop[linux-gtk4]: g_memdup2 OOM", .{});
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

// ---- Dialog async-to-sync cells + callbacks ---------------------------------

const OpenFileCell = extern struct {
    dialog: *GtkFileDialog,
    done: bool = false,
    file: ?*GFile = null,
};

fn openFileCb(_: ?*anyopaque, result: ?*GAsyncResult, user_data: ?*anyopaque) callconv(.c) void {
    const cell: *OpenFileCell = @ptrCast(@alignCast(user_data orelse return));
    if (result) |r| {
        var gerr: ?*GError = null;
        cell.file = gtk_file_dialog_open_finish(cell.dialog, r, &gerr);
        if (gerr) |e| g_error_free(e);
    }
    @atomicStore(bool, &cell.done, true, .release);
}

const SaveFileCell = extern struct {
    dialog: *GtkFileDialog,
    done: bool = false,
    file: ?*GFile = null,
};

fn saveFileCb(_: ?*anyopaque, result: ?*GAsyncResult, user_data: ?*anyopaque) callconv(.c) void {
    const cell: *SaveFileCell = @ptrCast(@alignCast(user_data orelse return));
    if (result) |r| {
        var gerr: ?*GError = null;
        cell.file = gtk_file_dialog_save_finish(cell.dialog, r, &gerr);
        if (gerr) |e| g_error_free(e);
    }
    @atomicStore(bool, &cell.done, true, .release);
}

const AlertCell = extern struct {
    dialog: *GtkAlertDialog,
    done: bool = false,
    result: c_int = 0,
};

fn alertCb(_: ?*anyopaque, result: ?*GAsyncResult, user_data: ?*anyopaque) callconv(.c) void {
    const cell: *AlertCell = @ptrCast(@alignCast(user_data orelse return));
    if (result) |r| {
        var gerr: ?*GError = null;
        cell.result = gtk_alert_dialog_choose_finish(cell.dialog, r, &gerr);
        if (gerr) |e| g_error_free(e);
    }
    @atomicStore(bool, &cell.done, true, .release);
}


/// Spin the GLib main context until `done` flips true.
/// Used by async-to-sync wrappers (cookies, clipboard, dialogs).
fn pumpMainContextUntilDone(done: *const bool) void {
    while (!@atomicLoad(bool, done, .acquire)) {
        _ = g_main_context_iteration(null, 1); // 1 = may_block
    }
}

// ---- Module-level functions (cookie + clipboard + socket) ------------------
//
// All stubs — implementations follow in tasks D through I.

/// Wrap an already-bound `AF_UNIX` SOCK_DGRAM fd in a GIOChannel
/// watch keyed on `G_IO_IN`. Called by `deep_link.startListener` on
/// the Linux backend; the fd ownership transfers — we set
/// `close_on_unref(true)` so the channel cleans the fd up at
/// window destruction.
pub fn attachUrlSocket(window: *Window, fd: c_int) !void {
    const ch = g_io_channel_unix_new(fd);
    g_io_channel_set_close_on_unref(ch, 1);
    const watch = g_io_add_watch(ch, G_IO_IN, &onUrlSocketReadable, @ptrCast(window.ctx));
    g_io_channel_unref(ch);
    window.ctx.url_socket_fd = fd;
    window.ctx.url_socket_watch = watch;
}

/// `G_IO_IN` callback. One datagram per `recv`; URL bytes are UTF-8
/// with no terminator. Returns `1` (TRUE) to keep the watch active.
fn onUrlSocketReadable(source: *GIOChannel, _cond: GIOCondition, data: ?*anyopaque) callconv(.c) gboolean {
    _ = source;
    _ = _cond;
    const cx: *WindowCtx = @ptrCast(@alignCast(data orelse return 1));
    var buf: [4096]u8 = undefined;
    const n = recv(cx.url_socket_fd, &buf, buf.len, 0);
    if (n <= 0) return 1;
    const url = buf[0..@intCast(n)];
    if (cx.on_url_open) |cb| cb(cx.on_url_open_ctx, url);
    return 1;
}

// ---- Cookie helpers ---------------------------------------------------------
//
// WK6 replaces the per-WebContext cookie manager with a per-NetworkSession one.
// We retrieve the session from the WebView and ask it for the cookie manager.

/// Continuation cell for webkit_cookie_manager_get_all_cookies async callback.
const GetAllCookiesCell = extern struct {
    list: ?*GList = null,
    done: bool = false,
};

/// Continuation cell for single-step async cookie ops (add / delete).
const SimpleAsyncCell = extern struct {
    done: bool = false,
};

fn onGetAllCookiesDone(src: ?*anyopaque, res: ?*GAsyncResult, user_data: ?*anyopaque) callconv(.c) void {
    const cell: *GetAllCookiesCell = @ptrCast(@alignCast(user_data orelse return));
    defer @atomicStore(bool, &cell.done, true, .release);
    const mgr: *WebKitCookieManager = @ptrCast(@alignCast(src orelse return));
    const r = res orelse return;
    var gerr: ?*GError = null;
    cell.list = webkit_cookie_manager_get_all_cookies_finish(mgr, r, &gerr);
    if (gerr) |e| {
        std.log.warn("verve.desktop[linux-gtk4]: get_all_cookies_finish failed", .{});
        g_error_free(e);
    }
}

fn onSimpleAsyncDone(_: ?*anyopaque, _: ?*GAsyncResult, user_data: ?*anyopaque) callconv(.c) void {
    const cell: *SimpleAsyncCell = @ptrCast(@alignCast(user_data orelse return));
    @atomicStore(bool, &cell.done, true, .release);
}

fn cookieManagerFor(window: *anyopaque) opts_mod.CookieError!*WebKitCookieManager {
    const win: *Window = @ptrCast(@alignCast(window));
    const wv = win.ctx.webview orelse return opts_mod.CookieError.NotReady;
    const session = webkit_web_view_get_network_session(wv);
    return webkit_network_session_get_cookie_manager(session);
}

fn fetchAllCookies(mgr: *WebKitCookieManager) ?*GList {
    var cell: GetAllCookiesCell = .{};
    webkit_cookie_manager_get_all_cookies(mgr, null, &onGetAllCookiesDone, @ptrCast(&cell));
    pumpMainContextUntilDone(&cell.done);
    return cell.list;
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
        out.expires_unix = @intCast(g_date_time_to_unix(date));
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
        const date = g_date_time_new_from_unix_utc(@intCast(cookie.expires_unix));
        soup_cookie_set_expires(c, date);
        if (date) |d| g_date_time_unref(d);
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

// ---- Clipboard (GTK4 / GdkClipboard) ---------------------------------------
//
// GTK4 removed GtkClipboard. All reads are async; writes are synchronous
// (text) or via a GdkContentProvider (HTML/image).

fn getClipboard() ?*GdkClipboard {
    const display = gdk_display_get_default() orelse return null;
    return gdk_display_get_clipboard(display);
}

// ---- clipboardWriteText ----------------------------------------------------

pub fn clipboardWriteText(window: *anyopaque, text: []const u8) opts_mod.ClipboardError!void {
    _ = window;
    const clip = getClipboard() orelse return opts_mod.ClipboardError.Backend;
    var sfb = std.heap.stackFallback(4096, std.heap.c_allocator);
    const alloc = sfb.get();
    const z = alloc.dupeZ(u8, text) catch return opts_mod.ClipboardError.OutOfMemory;
    defer alloc.free(z);
    gdk_clipboard_set_text(clip, z.ptr);
}

// ---- clipboardReadText -----------------------------------------------------

const ReadTextCell = extern struct {
    clip: *GdkClipboard,
    done: bool = false,
    text: ?[*:0]u8 = null,
};

fn readTextCb(src: ?*anyopaque, result: ?*GAsyncResult, user_data: ?*anyopaque) callconv(.c) void {
    _ = src;
    const cell: *ReadTextCell = @ptrCast(@alignCast(user_data));
    defer @atomicStore(bool, &cell.done, true, .release);
    const res = result orelse return;
    var gerr: ?*GError = null;
    cell.text = gdk_clipboard_read_text_finish(cell.clip, res, &gerr);
    if (gerr) |e| g_error_free(e);
}

pub fn clipboardReadText(window: *anyopaque, allocator: std.mem.Allocator) opts_mod.ClipboardError!?[]u8 {
    _ = window;
    const clip = getClipboard() orelse return null;
    var cell = ReadTextCell{ .clip = clip };
    gdk_clipboard_read_text_async(clip, null, @ptrCast(&readTextCb), @ptrCast(&cell));
    pumpMainContextUntilDone(&cell.done);
    const raw = cell.text orelse return null;
    defer g_free(@ptrCast(raw));
    return allocator.dupe(u8, std.mem.span(raw)) catch return opts_mod.ClipboardError.OutOfMemory;
}

// ---- clipboardWriteHtml ----------------------------------------------------

pub fn clipboardWriteHtml(window: *anyopaque, html: []const u8) opts_mod.ClipboardError!void {
    _ = window;
    const clip = getClipboard() orelse return opts_mod.ClipboardError.Backend;
    const bytes = g_bytes_new(html.ptr, html.len);
    defer g_bytes_unref(bytes);
    const provider = gdk_content_provider_new_for_bytes("text/html", bytes);
    defer g_object_unref(provider);
    _ = gdk_clipboard_set_content(clip, provider);
}

// ---- clipboardReadHtml -----------------------------------------------------

const ReadHtmlCell = extern struct {
    clip: *GdkClipboard,
    done: bool = false,
    stream: ?*GInputStream = null,
};

fn readHtmlCb(src: ?*anyopaque, result: ?*GAsyncResult, user_data: ?*anyopaque) callconv(.c) void {
    _ = src;
    const cell: *ReadHtmlCell = @ptrCast(@alignCast(user_data));
    defer @atomicStore(bool, &cell.done, true, .release);
    const res = result orelse return;
    var gerr: ?*GError = null;
    var out_mime: ?[*:0]const u8 = null;
    cell.stream = gdk_clipboard_read_finish(cell.clip, res, &out_mime, &gerr);
    if (gerr) |e| g_error_free(e);
}

// mime_types sentinel-terminated array for gdk_clipboard_read_async
const html_mime_types = [_:null]?[*:0]const u8{"text/html"};

pub fn clipboardReadHtml(window: *anyopaque, allocator: std.mem.Allocator) opts_mod.ClipboardError!?[]u8 {
    _ = window;
    const clip = getClipboard() orelse return null;
    var cell = ReadHtmlCell{ .clip = clip };
    gdk_clipboard_read_async(clip, &html_mime_types, 0, null, @ptrCast(&readHtmlCb), @ptrCast(&cell));
    pumpMainContextUntilDone(&cell.done);
    const stream = cell.stream orelse return null;
    defer _ = g_input_stream_close(stream, null, null);
    defer g_object_unref(stream);

    // Read chunks into a growable list.
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    var chunk: [1024]u8 = undefined;
    while (true) {
        var rd_err: ?*GError = null;
        const n = g_input_stream_read(stream, &chunk, chunk.len, null, &rd_err);
        if (rd_err) |e| {
            g_error_free(e);
            break;
        }
        if (n <= 0) break;
        buf.appendSlice(chunk[0..@intCast(n)]) catch return opts_mod.ClipboardError.OutOfMemory;
    }
    if (buf.items.len == 0) return null;
    return buf.toOwnedSlice() catch return opts_mod.ClipboardError.OutOfMemory;
}

// ---- clipboardWriteImage ---------------------------------------------------

pub fn clipboardWriteImage(window: *anyopaque, png: []const u8) opts_mod.ClipboardError!void {
    _ = window;
    const clip = getClipboard() orelse return opts_mod.ClipboardError.Backend;

    // Decode PNG → GdkPixbuf via loader.
    const loader = gdk_pixbuf_loader_new();
    defer g_object_unref(loader);
    var gerr: ?*GError = null;
    if (gdk_pixbuf_loader_write(loader, png.ptr, png.len, &gerr) == 0) {
        if (gerr) |e| g_error_free(e);
        _ = gdk_pixbuf_loader_close(loader, null);
        return opts_mod.ClipboardError.Backend;
    }
    gerr = null;
    if (gdk_pixbuf_loader_close(loader, &gerr) == 0) {
        if (gerr) |e| g_error_free(e);
        return opts_mod.ClipboardError.Backend;
    }
    const pixbuf = gdk_pixbuf_loader_get_pixbuf(loader) orelse return opts_mod.ClipboardError.Backend;

    // Wrap in a GdkTexture (GTK4 clipboard expects a texture, not a pixbuf).
    const texture = gdk_texture_new_for_pixbuf(pixbuf);
    defer g_object_unref(texture);
    gdk_clipboard_set_texture(clip, texture);
}

// ---- clipboardReadImage ----------------------------------------------------

const ReadTexCell = extern struct {
    clip: *GdkClipboard,
    done: bool = false,
    texture: ?*GdkTexture = null,
};

fn readTexCb(src: ?*anyopaque, result: ?*GAsyncResult, user_data: ?*anyopaque) callconv(.c) void {
    _ = src;
    const cell: *ReadTexCell = @ptrCast(@alignCast(user_data));
    defer @atomicStore(bool, &cell.done, true, .release);
    const res = result orelse return;
    var gerr: ?*GError = null;
    cell.texture = gdk_clipboard_read_texture_finish(cell.clip, res, &gerr);
    if (gerr) |e| g_error_free(e);
}

pub fn clipboardReadImage(window: *anyopaque, allocator: std.mem.Allocator) opts_mod.ClipboardError!?[]u8 {
    _ = window;
    const clip = getClipboard() orelse return null;
    var cell = ReadTexCell{ .clip = clip };
    gdk_clipboard_read_texture_async(clip, null, @ptrCast(&readTexCb), @ptrCast(&cell));
    pumpMainContextUntilDone(&cell.done);
    const texture = cell.texture orelse return null;
    defer g_object_unref(texture);

    const w: c_int = gdk_texture_get_width(texture);
    const h: c_int = gdk_texture_get_height(texture);
    const stride: usize = @as(usize, @intCast(w)) * 4;
    const rgba_size: usize = @as(usize, @intCast(h)) * stride;

    // Download raw RGBA bytes from texture.
    const rgba_buf = allocator.alloc(u8, rgba_size) catch return opts_mod.ClipboardError.OutOfMemory;
    defer allocator.free(rgba_buf);
    gdk_texture_download(texture, rgba_buf.ptr, stride);

    // Re-encode as PNG via GdkPixbuf.
    // GDK_COLORSPACE_RGB = 0, has_alpha = 1, bits_per_sample = 8
    const pixbuf = gdk_pixbuf_new_from_data(
        rgba_buf.ptr,
        0, // GDK_COLORSPACE_RGB
        1, // has_alpha
        8,
        w,
        h,
        @intCast(stride),
        null,
        null,
    ) orelse return opts_mod.ClipboardError.Backend;
    defer g_object_unref(pixbuf);

    var buf_ptr: ?[*]u8 = null;
    var buf_size: usize = 0;
    var gerr: ?*GError = null;
    if (gdk_pixbuf_save_to_bufferv(pixbuf, &buf_ptr, &buf_size, "png", null, null, &gerr) == 0) {
        if (gerr) |e| g_error_free(e);
        return opts_mod.ClipboardError.Backend;
    }
    const raw = buf_ptr orelse return opts_mod.ClipboardError.Backend;
    defer g_free(@ptrCast(raw));
    return allocator.dupe(u8, raw[0..buf_size]) catch return opts_mod.ClipboardError.OutOfMemory;
}
