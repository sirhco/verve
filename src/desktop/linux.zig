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
const clipboard_mod = @import("clipboard.zig");

// ---- Opaque GTK/GLib/WebKit pointer types -----------------------------------

const GtkWidget = opaque {};
const GtkWindow = opaque {};
const GtkContainer = opaque {};
const GtkDialog = opaque {};
const GtkFileChooser = opaque {};
const GtkFileChooserNative = opaque {};
const GtkNativeDialog = opaque {};
const GtkMessageDialog = opaque {};
const GtkFileFilter = opaque {};
const CairoSurface = opaque {};
const GCancellable = opaque {};
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

// ---- GTK menu bar + accel group externs ------------------------------------
//
// Default menu bar (File + Edit) for parity with the macOS App + Edit
// menu. Only File→Quit binds an accelerator; Edit items render their
// shortcut hint in the label text via `gtk_menu_item_new_with_mnemonic`
// markup but do not attach a `gtk_widget_add_accelerator` binding —
// otherwise GTK would consume Ctrl+C/V/X before WebKit sees them and
// silently break clipboard inside HTML inputs.
const GtkBox = opaque {};
const GtkMenuShell = opaque {};
const GtkMenuItem = opaque {};
const GtkAccelGroup = opaque {};
const GtkOrientation = c_uint;
const GdkModifierType = c_uint;
const GtkAccelFlags = c_uint;

const GTK_ORIENTATION_VERTICAL: GtkOrientation = 1;
const GTK_ACCEL_VISIBLE: GtkAccelFlags = 1;

extern fn gtk_box_new(orientation: GtkOrientation, spacing: c_int) *GtkWidget;
extern fn gtk_box_pack_start(box: *GtkBox, child: *GtkWidget, expand: gboolean, fill: gboolean, padding: c_uint) void;
extern fn gtk_menu_bar_new() *GtkWidget;
extern fn gtk_menu_new() *GtkWidget;
extern fn gtk_menu_item_new_with_mnemonic(label: [*:0]const u8) *GtkWidget;
extern fn gtk_separator_menu_item_new() *GtkWidget;
extern fn gtk_menu_item_set_submenu(item: *GtkMenuItem, submenu: *GtkWidget) void;
extern fn gtk_menu_shell_append(shell: *GtkMenuShell, child: *GtkWidget) void;
extern fn gtk_accel_group_new() *GtkAccelGroup;
extern fn gtk_window_add_accel_group(win: *GtkWindow, ag: *GtkAccelGroup) void;
extern fn gtk_widget_add_accelerator(
    widget: *GtkWidget,
    signal: [*:0]const u8,
    ag: *GtkAccelGroup,
    key: c_uint,
    mods: GdkModifierType,
    flags: GtkAccelFlags,
) void;
extern fn gtk_accelerator_parse(s: [*:0]const u8, key_out: *c_uint, mods_out: *GdkModifierType) void;

// ---- GTK drag-and-drop externs ---------------------------------------------
//
// `gtk_drag_dest_set` marks a widget as a drop destination; `add_uri_targets`
// is the convenience helper that enrolls all the URI-list target atoms (so
// file drops from Nautilus / Dolphin / etc all arrive on one signal).
// `drag-data-received` then fires once per drop with the pasteboard data.
const GtkDestDefaults = c_uint;
const GdkDragAction = c_uint;
const GtkTargetList = opaque {};
const GdkDragContext = opaque {};
const GtkSelectionData = opaque {};

const GTK_DEST_DEFAULT_MOTION: GtkDestDefaults = 1;
const GTK_DEST_DEFAULT_HIGHLIGHT: GtkDestDefaults = 2;
const GTK_DEST_DEFAULT_DROP: GtkDestDefaults = 4;
const GTK_DEST_DEFAULT_ALL: GtkDestDefaults = 7;
const GDK_ACTION_COPY: GdkDragAction = 4;

extern fn gtk_drag_dest_set(
    widget: *GtkWidget,
    flags: GtkDestDefaults,
    targets: ?*GtkTargetList,
    n_targets: c_int,
    actions: GdkDragAction,
) void;
extern fn gtk_drag_dest_add_uri_targets(widget: *GtkWidget) void;
extern fn gtk_drag_dest_unset(widget: *GtkWidget) void;
extern fn gtk_drag_finish(ctx: *GdkDragContext, success: gboolean, delete: gboolean, time: c_uint) void;
extern fn gtk_selection_data_get_uris(data: *GtkSelectionData) ?[*]const ?[*:0]const u8;
extern fn g_strfreev(strv: ?[*]const ?[*:0]const u8) void;
extern fn g_signal_handler_disconnect(instance: *anyopaque, handler_id: c_ulong) void;

// ---- ATK accessibility -----------------------------------------------------
const AtkObject = opaque {};
extern fn gtk_widget_get_accessible(w: *GtkWidget) *AtkObject;
extern fn atk_object_set_name(obj: *AtkObject, name: [*:0]const u8) void;
extern fn gtk_window_set_keep_above(w: *GtkWindow, on: gboolean) void;
extern fn gtk_widget_set_opacity(w: *GtkWidget, value: f64) void;
extern fn gtk_window_resize(w: *GtkWindow, width: c_int, height: c_int) void;
extern fn gtk_window_move(w: *GtkWindow, x: c_int, y: c_int) void;
extern fn gtk_window_set_position(w: *GtkWindow, position: c_uint) void;
extern fn gtk_window_iconify(w: *GtkWindow) void;
extern fn gtk_window_deiconify(w: *GtkWindow) void;
extern fn gtk_window_maximize(w: *GtkWindow) void;
extern fn gtk_window_unmaximize(w: *GtkWindow) void;
extern fn gtk_window_fullscreen(w: *GtkWindow) void;
extern fn gtk_window_unfullscreen(w: *GtkWindow) void;
extern fn gtk_window_present(w: *GtkWindow) void;
extern fn gtk_widget_hide(w: *GtkWidget) void;
extern fn gtk_window_set_resizable(w: *GtkWindow, on: gboolean) void;

// ---- Geometry hints (min/max size) ------------------------------------------
// `gtk_window_set_geometry_hints` reads bitfields from `GdkGeometry`
// based on which `GdkWindowHints` flags are set. We only ever set
// `GDK_HINT_MIN_SIZE = 4` and `GDK_HINT_MAX_SIZE = 8`; the other
// hint slots stay zero. Layout matches the GTK3 ABI verbatim.
const GdkGeometry = extern struct {
    min_width: c_int = 0,
    min_height: c_int = 0,
    max_width: c_int = 0,
    max_height: c_int = 0,
    base_width: c_int = 0,
    base_height: c_int = 0,
    width_inc: c_int = 0,
    height_inc: c_int = 0,
    min_aspect: f64 = 0,
    max_aspect: f64 = 0,
    win_gravity: c_int = 0,
};
const GdkWindowHints = c_uint;
const GDK_HINT_MIN_SIZE: GdkWindowHints = 4;
const GDK_HINT_MAX_SIZE: GdkWindowHints = 8;
extern fn gtk_window_set_geometry_hints(
    w: *GtkWindow,
    geometry_widget: ?*GtkWidget,
    geometry: ?*const GdkGeometry,
    flags: GdkWindowHints,
) void;

// ---- GTK dialog externs (used by openFileDialog / saveFileDialog / showAlert)
//
// File chooser uses the native variant: portal-aware on modern hosts,
// graceful GtkFileChooserDialog fallback elsewhere. NativeDialog and
// MessageDialog implement the GtkFileChooser / GtkDialog interfaces
// respectively, so the getter/setter helpers below operate on the
// returned widget via interface casts (`@ptrCast` in callers).
const GtkFileChooserAction = c_uint;
const GtkResponseType = c_int;
const GtkDialogFlags = c_uint;
const GtkMessageType = c_uint;
const GtkButtonsType = c_uint;

const GTK_FILE_CHOOSER_ACTION_OPEN: GtkFileChooserAction = 0;
const GTK_FILE_CHOOSER_ACTION_SAVE: GtkFileChooserAction = 1;
const GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER: GtkFileChooserAction = 2;

const GTK_RESPONSE_ACCEPT: GtkResponseType = -3;
const GTK_RESPONSE_CANCEL: GtkResponseType = -6;
const GTK_RESPONSE_DELETE_EVENT: GtkResponseType = -4;

const GTK_DIALOG_MODAL: GtkDialogFlags = 1;

const GTK_MESSAGE_INFO: GtkMessageType = 0;
const GTK_MESSAGE_WARNING: GtkMessageType = 1;
const GTK_MESSAGE_ERROR: GtkMessageType = 3;

const GTK_BUTTONS_NONE: GtkButtonsType = 0;

extern fn gtk_file_chooser_native_new(
    title: [*:0]const u8,
    parent: ?*GtkWindow,
    action: GtkFileChooserAction,
    accept_label: ?[*:0]const u8,
    cancel_label: ?[*:0]const u8,
) *GtkFileChooserNative;
extern fn gtk_native_dialog_run(dialog: *GtkNativeDialog) c_int;
extern fn gtk_native_dialog_destroy(dialog: *GtkNativeDialog) void;
extern fn gtk_file_chooser_set_select_multiple(chooser: *GtkFileChooser, select: gboolean) void;
extern fn gtk_file_chooser_set_current_name(chooser: *GtkFileChooser, name: [*:0]const u8) void;
extern fn gtk_file_chooser_set_current_folder(chooser: *GtkFileChooser, path: [*:0]const u8) c_int;
extern fn gtk_file_chooser_get_filename(chooser: *GtkFileChooser) ?[*:0]u8;
extern fn gtk_file_chooser_add_filter(chooser: *GtkFileChooser, filter: *GtkFileFilter) void;

extern fn gtk_file_filter_new() *GtkFileFilter;
extern fn gtk_file_filter_set_name(filter: *GtkFileFilter, name: [*:0]const u8) void;
extern fn gtk_file_filter_add_pattern(filter: *GtkFileFilter, pattern: [*:0]const u8) void;

// `gtk_message_dialog_new` is varargs in C (`format, ...`). The
// trailing format pointer is declared optional + nullable here so
// passing `null` matches the no-format call shape; the message text
// is then set via `gtk_message_dialog_set_markup` to avoid passing
// any actual format spec.
extern fn gtk_message_dialog_new(
    parent: ?*GtkWindow,
    flags: GtkDialogFlags,
    msg_type: GtkMessageType,
    buttons: GtkButtonsType,
    format: ?[*:0]const u8,
) *GtkWidget;
extern fn gtk_message_dialog_set_markup(dialog: *GtkMessageDialog, str: [*:0]const u8) void;
extern fn gtk_dialog_add_button(dialog: *GtkDialog, text: [*:0]const u8, response_id: c_int) *GtkWidget;
extern fn gtk_dialog_run(dialog: *GtkDialog) c_int;

// ---- Snapshot externs (used by takeSnapshotPng) ----------------------------
//
// `webkit_web_view_get_snapshot` is async — the standard
// `g_main_context_iteration` pump wraps it sync (same shape as the
// cookie-store getters). `cairo_surface_write_to_png` handles the
// PNG encoding inline so no third-party encoder dependency lands in
// the linker line.

const WebKitSnapshotRegion = c_uint;
const WebKitSnapshotOptions = c_uint;
const CairoStatus = c_int;

const WEBKIT_SNAPSHOT_REGION_VISIBLE: WebKitSnapshotRegion = 0;
const WEBKIT_SNAPSHOT_OPTIONS_NONE: WebKitSnapshotOptions = 0;
const CAIRO_STATUS_SUCCESS: CairoStatus = 0;

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

// ---- GtkClipboard externs --------------------------------------------------
const GtkClipboard = opaque {};
const GdkAtom = ?*anyopaque;
extern fn gtk_clipboard_get(selection: GdkAtom) *GtkClipboard;
extern fn gtk_clipboard_set_text(clipboard: *GtkClipboard, text: [*:0]const u8, len: c_int) void;
extern fn gtk_clipboard_store(clipboard: *GtkClipboard) void;
extern fn gtk_clipboard_wait_for_text(clipboard: *GtkClipboard) ?[*:0]u8;
// `GDK_SELECTION_CLIPBOARD` is the X11 atom for the CLIPBOARD
// selection (system clipboard, as opposed to PRIMARY which is the
// X11 middle-click buffer). It's a GdkAtom which on x86_64-linux is
// a pointer-sized opaque. The internal `gdk_atom_intern_static_string`
// path resolves the well-known string.
extern fn gdk_atom_intern_static_string(name: [*:0]const u8) GdkAtom;

// ---- GtkSettings (color-scheme query) --------------------------------------
const GtkSettings = opaque {};
extern fn gtk_settings_get_default() ?*GtkSettings;
// g_object_get is varargs in C — declare with the exact arity we need.
// Final NULL terminator is the sentinel; passing null pointer suffices.
extern fn g_object_get(
    object: *GtkSettings,
    first_property_name: [*:0]const u8,
    out: *gboolean,
    sentinel: ?*anyopaque,
) void;

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

// ---- GIOChannel externs (used by deep_link.attachUrlSocket) ----------------
//
// `g_io_channel_unix_new` wraps a raw POSIX fd in a GIOChannel so it
// plugs into the GTK main loop's source dispatch. `g_io_add_watch`
// installs a callback fired when the socket has bytes to read; we
// pass `G_IO_IN` (= 1) plus the per-window WindowCtx pointer as
// user_data so the trampoline can route inbound URLs through the
// stored handler.
const GIOChannel = opaque {};
const GIOCondition = c_uint;
const G_IO_IN: GIOCondition = 1;
const GIOFunc = *const fn (source: *GIOChannel, cond: GIOCondition, data: ?*anyopaque) callconv(.c) gboolean;

extern fn g_io_channel_unix_new(fd: c_int) *GIOChannel;
extern fn g_io_channel_set_close_on_unref(channel: *GIOChannel, do_close: gboolean) void;
extern fn g_io_add_watch(channel: *GIOChannel, cond: GIOCondition, func: GIOFunc, data: ?*anyopaque) c_uint;
extern fn g_io_channel_unref(channel: *GIOChannel) void;

extern "c" fn recv(fd: c_int, buf: *anyopaque, len: usize, flags: c_int) isize;
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
extern fn webkit_web_view_reload(wv: *WebKitWebView) void;
extern fn webkit_web_view_go_back(wv: *WebKitWebView) void;
extern fn webkit_web_view_go_forward(wv: *WebKitWebView) void;
extern fn webkit_web_view_can_go_back(wv: *WebKitWebView) gboolean;
extern fn webkit_web_view_can_go_forward(wv: *WebKitWebView) gboolean;
extern fn webkit_web_view_get_uri(wv: *WebKitWebView) ?[*:0]const u8;
extern fn webkit_web_view_get_title(wv: *WebKitWebView) ?[*:0]const u8;
extern fn webkit_web_view_set_zoom_level(wv: *WebKitWebView, level: f64) void;
extern fn webkit_web_view_get_zoom_level(wv: *WebKitWebView) f64;
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
    on_color_scheme: ?opts_mod.ColorSchemeHandler = null,
    on_color_scheme_ctx: ?*anyopaque = null,
    on_url_open: ?opts_mod.UrlOpenHandler = null,
    on_url_open_ctx: ?*anyopaque = null,
    on_drag_drop: ?opts_mod.DragDropHandler = null,
    on_drag_drop_ctx: ?*anyopaque = null,
    drag_signal: c_ulong = 0,
    on_resize: ?opts_mod.ResizeHandler = null,
    on_resize_ctx: ?*anyopaque = null,
    on_focus: ?opts_mod.FocusHandler = null,
    on_focus_ctx: ?*anyopaque = null,
    on_close: ?opts_mod.CloseHandler = null,
    on_close_ctx: ?*anyopaque = null,
    resize_signal: c_ulong = 0,
    focus_in_signal: c_ulong = 0,
    focus_out_signal: c_ulong = 0,
    close_signal: c_ulong = 0,
    min_width: u32 = 0,
    min_height: u32 = 0,
    max_width: u32 = 0,
    max_height: u32 = 0,
    url_socket_fd: c_int = -1,
    url_socket_watch: c_uint = 0,
    color_scheme_signal: c_ulong = 0,
    window: ?*GtkWidget = null,
    webview: ?*WebKitWebView = null,
    web_context: ?*WebKitWebContext = null,
    accel_group: ?*GtkAccelGroup = null,
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

        if (opts.install_default_menu) {
            // GtkBox wraps the menu bar + webview vertically. Failure
            // to allocate any menu piece falls back to the opt-out
            // shape (webview as the sole window child) — apps still
            // boot, just menu-less.
            installDefaultMenuBar(heap, window_widget, wv_widget) catch {
                gtk_container_add(@ptrCast(window_widget), wv_widget);
            };
        } else {
            gtk_container_add(@ptrCast(window_widget), wv_widget);
        }

        if (opts.initial_path.len > 0) {
            var url_buf: [1024]u8 = undefined;
            const url = try std.fmt.bufPrintZ(&url_buf, "{s}://app/{s}", .{ opts.scheme, opts.initial_path });
            std.log.debug("verve.desktop[linux]: navigate {s}", .{url});
            webkit_web_view_load_uri(wv, url.ptr);
        }

        if (opts.on_drag_drop != null) {
            installDragDestination(heap, window_widget);
        }

        if (opts.on_resize != null) {
            heap.resize_signal = g_signal_connect_data(
                window_widget,
                "configure-event",
                @as(GCallback, @ptrCast(&onConfigureEvent)),
                @ptrCast(heap),
                null,
                0,
            );
        }
        if (opts.on_focus != null) {
            heap.focus_in_signal = g_signal_connect_data(
                window_widget,
                "focus-in-event",
                @as(GCallback, @ptrCast(&onFocusIn)),
                @ptrCast(heap),
                null,
                0,
            );
            heap.focus_out_signal = g_signal_connect_data(
                window_widget,
                "focus-out-event",
                @as(GCallback, @ptrCast(&onFocusOut)),
                @ptrCast(heap),
                null,
                0,
            );
        }
        if (opts.on_close != null) {
            heap.close_signal = g_signal_connect_data(
                window_widget,
                "delete-event",
                @as(GCallback, @ptrCast(&onDeleteEvent)),
                @ptrCast(heap),
                null,
                0,
            );
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

    /// System clipboard handle. GtkClipboard is keyed on a display +
    /// selection (CLIPBOARD here, not PRIMARY); the per-window
    /// scoping just gives API parity with `cookies()`.
    pub fn clipboard(self: *Window) clipboard_mod.Clipboard {
        return .{ .window = @ptrCast(self) };
    }

    /// Register a callback fired on GtkSettings'
    /// `notify::gtk-application-prefer-dark-theme` signal — emitted
    /// when GTK reapplies its theme (e.g. user toggles dark mode in
    /// the desktop's appearance settings). `g_signal_connect_data`
    /// returns the connection id; we stash it on the ctx so a
    /// follow-up `setColorSchemeHandler(null, null)` can disconnect.
    pub fn setColorSchemeHandler(self: *Window, cb: ?opts_mod.ColorSchemeHandler, ctx: ?*anyopaque) void {
        self.ctx.on_color_scheme = cb;
        self.ctx.on_color_scheme_ctx = ctx;
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
        }
    }

    /// Register a deep-link URL handler. Linux ships only the
    /// receive-side wiring in this pass — cold-launch (OS spawns the
    /// app with the URL in argv) is the supported delivery path,
    /// driven by the template's argv parser feeding through
    /// `deliverUrl`. Warm-launch URL forwarding via abstract Unix
    /// socket from a second instance to the running window is a
    /// follow-up.
    pub fn setUrlOpenHandler(self: *Window, cb: ?opts_mod.UrlOpenHandler, ctx: ?*anyopaque) void {
        self.ctx.on_url_open = cb;
        self.ctx.on_url_open_ctx = ctx;
    }

    /// Install / replace the drag-drop handler. Wires
    /// `gtk_drag_dest_set` + URI-list targets + a `drag-data-received`
    /// signal on the window widget. Passing `null` disconnects the
    /// signal and clears the destination.
    /// Trigger the platform print dialog. v1 dispatches via the
    /// page's `window.print()` — WebKitGTK shows its built-in print
    /// dialog off that call. Native `webkit_print_operation_run_dialog`
    /// is deferred polish for richer programmatic print control.
    pub fn print(self: *Window) void {
        self.evalJs("window.print();");
    }

    /// Set the window's ATK accessible name. `gtk_widget_get_accessible`
    /// returns the AtkObject lazily attached to every GtkWidget;
    /// `atk_object_set_name` then sets the string Orca + other AT
    /// tools announce on focus. Distinct from `gtk_window_set_title`
    /// (the visible title-bar text). Web content + GTK menu items
    /// already publish their own ATK names through WebKitGTK and the
    /// default menu bar.
    pub fn setAccessibilityLabel(self: *Window, label: []const u8) void {
        const w = self.ctx.window orelse return;
        const z = self.ctx.allocator.dupeZ(u8, label) catch return;
        defer self.ctx.allocator.free(z);
        const atk_obj = gtk_widget_get_accessible(w);
        atk_object_set_name(atk_obj, z.ptr);
    }

    /// Toggle whether the window stays above normal-stack peers.
    /// `gtk_window_set_keep_above` is the WM-coordinated hint —
    /// effective on every freedesktop-compliant compositor.
    pub fn setAlwaysOnTop(self: *Window, on: bool) void {
        const w = self.ctx.window orelse return;
        gtk_window_set_keep_above(@ptrCast(w), if (on) 1 else 0);
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
        gtk_window_resize(@ptrCast(w), @intCast(width), @intCast(height));
    }

    pub fn setPosition(self: *Window, x: i32, y: i32) void {
        const w = self.ctx.window orelse return;
        gtk_window_move(@ptrCast(w), @intCast(x), @intCast(y));
    }

    /// GTK_WIN_POS_CENTER = 1 — the WM positions the window at the
    /// screen center on next show. For already-visible windows the
    /// hint plus a no-op move re-applies.
    pub fn center(self: *Window) void {
        const w = self.ctx.window orelse return;
        gtk_window_set_position(@ptrCast(w), 1);
    }

    pub fn minimize(self: *Window) void {
        const w = self.ctx.window orelse return;
        gtk_window_iconify(@ptrCast(w));
    }

    pub fn maximize(self: *Window) void {
        const w = self.ctx.window orelse return;
        gtk_window_maximize(@ptrCast(w));
    }

    pub fn restore(self: *Window) void {
        const w = self.ctx.window orelse return;
        gtk_window_unmaximize(@ptrCast(w));
        gtk_window_deiconify(@ptrCast(w));
        gtk_window_present(@ptrCast(w));
    }

    pub fn setFullscreen(self: *Window, on: bool) void {
        const w = self.ctx.window orelse return;
        if (on) gtk_window_fullscreen(@ptrCast(w)) else gtk_window_unfullscreen(@ptrCast(w));
    }

    pub fn show(self: *Window) void {
        const w = self.ctx.window orelse return;
        gtk_widget_show_all(w);
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

    pub fn setResizeHandler(self: *Window, cb: ?opts_mod.ResizeHandler, ctx: ?*anyopaque) void {
        self.ctx.on_resize = cb;
        self.ctx.on_resize_ctx = ctx;
        const w = self.ctx.window orelse return;
        if (cb != null and self.ctx.resize_signal == 0) {
            self.ctx.resize_signal = g_signal_connect_data(
                w,
                "configure-event",
                @as(GCallback, @ptrCast(&onConfigureEvent)),
                @ptrCast(self.ctx),
                null,
                0,
            );
        }
    }

    pub fn setFocusHandler(self: *Window, cb: ?opts_mod.FocusHandler, ctx: ?*anyopaque) void {
        self.ctx.on_focus = cb;
        self.ctx.on_focus_ctx = ctx;
        const w = self.ctx.window orelse return;
        if (cb != null and self.ctx.focus_in_signal == 0) {
            self.ctx.focus_in_signal = g_signal_connect_data(
                w,
                "focus-in-event",
                @as(GCallback, @ptrCast(&onFocusIn)),
                @ptrCast(self.ctx),
                null,
                0,
            );
            self.ctx.focus_out_signal = g_signal_connect_data(
                w,
                "focus-out-event",
                @as(GCallback, @ptrCast(&onFocusOut)),
                @ptrCast(self.ctx),
                null,
                0,
            );
        }
    }

    pub fn setCloseHandler(self: *Window, cb: ?opts_mod.CloseHandler, ctx: ?*anyopaque) void {
        self.ctx.on_close = cb;
        self.ctx.on_close_ctx = ctx;
        const w = self.ctx.window orelse return;
        if (cb != null and self.ctx.close_signal == 0) {
            self.ctx.close_signal = g_signal_connect_data(
                w,
                "delete-event",
                @as(GCallback, @ptrCast(&onDeleteEvent)),
                @ptrCast(self.ctx),
                null,
                0,
            );
        }
    }

    /// Constraints honored by GTK + the WM. `(0, 0)` clears the
    /// minimum. Pairs with `setMaxSize` — both must be re-applied
    /// together because `gtk_window_set_geometry_hints` takes a
    /// single struct that covers both bounds.
    pub fn setMinSize(self: *Window, width: u32, height: u32) void {
        self.ctx.min_width = width;
        self.ctx.min_height = height;
        applyGeometryHints(self.ctx);
    }

    pub fn setMaxSize(self: *Window, width: u32, height: u32) void {
        self.ctx.max_width = width;
        self.ctx.max_height = height;
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

    pub fn setDragDropHandler(self: *Window, cb: ?opts_mod.DragDropHandler, ctx: ?*anyopaque) void {
        self.ctx.on_drag_drop = cb;
        self.ctx.on_drag_drop_ctx = ctx;
        const window_widget = self.ctx.window orelse return;
        if (cb == null) {
            if (self.ctx.drag_signal != 0) {
                g_signal_handler_disconnect(@ptrCast(window_widget), self.ctx.drag_signal);
                self.ctx.drag_signal = 0;
            }
            gtk_drag_dest_unset(window_widget);
            return;
        }
        if (self.ctx.drag_signal == 0) installDragDestination(self.ctx, window_widget);
    }

    /// Synthesize a URL delivery — call the registered handler with
    /// `url`. Used by templates to feed argv-derived cold-launch URLs
    /// through the same callback the future warm-launch socket
    /// receiver will eventually drive.
    pub fn deliverUrl(self: *Window, url: []const u8) void {
        if (self.ctx.on_url_open) |cb| cb(self.ctx.on_url_open_ctx, url);
    }

    /// Read GTK's `gtk-application-prefer-dark-theme` boolean. This
    /// reflects the user's theme choice on most GNOME / KDE desktops
    /// and matches what GTK uses internally to flip widget colors.
    /// On hosts without a GtkSettings backend (uncommon — `gtk_init`
    /// already failed earlier in that case), collapses to .unknown.
    pub fn colorScheme(self: *Window) opts_mod.ColorScheme {
        _ = self;
        const settings = gtk_settings_get_default() orelse return .unknown;
        var prefer_dark: gboolean = 0;
        g_object_get(settings, "gtk-application-prefer-dark-theme", &prefer_dark, null);
        return if (prefer_dark != 0) .dark else .light;
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
    //
    // File / save dialogs use `GtkFileChooserNative` so the system file
    // picker (portal on modern hosts, GtkFileChooserDialog fallback
    // elsewhere) shows up rather than a custom-rendered window. Alerts
    // use `GtkMessageDialog` with `gtk_dialog_run` for sync modal
    // behavior — same shape as the macOS NSAlert wrapper.

    pub fn openFileDialog(self: *Window, allocator: std.mem.Allocator, opts: opts_mod.FileDialogOptions) opts_mod.DialogError![]u8 {
        return runFileChooserNative(self, allocator, opts, .open);
    }

    pub fn saveFileDialog(self: *Window, allocator: std.mem.Allocator, opts: opts_mod.FileDialogOptions) opts_mod.DialogError![]u8 {
        return runFileChooserNative(self, allocator, opts, .save);
    }

    pub fn showAlert(self: *Window, opts: opts_mod.AlertOptions) usize {
        const msg_type: GtkMessageType = switch (opts.style) {
            .informational => GTK_MESSAGE_INFO,
            .warning => GTK_MESSAGE_WARNING,
            .critical => GTK_MESSAGE_ERROR,
        };
        const parent: ?*GtkWindow = if (self.ctx.window) |w| @ptrCast(w) else null;
        const dialog_widget = gtk_message_dialog_new(parent, GTK_DIALOG_MODAL, msg_type, GTK_BUTTONS_NONE, null);
        const dialog: *GtkDialog = @ptrCast(dialog_widget);

        // Set title bar + body. `gtk_window_set_title` is safe on
        // GtkMessageDialog (it inherits GtkWindow).
        if (opts.title.len > 0) {
            const title_z = self.ctx.allocator.dupeZ(u8, opts.title) catch return 0;
            defer self.ctx.allocator.free(title_z);
            gtk_window_set_title(@ptrCast(dialog_widget), title_z.ptr);
        }
        if (opts.message.len > 0) {
            const msg_z = self.ctx.allocator.dupeZ(u8, opts.message) catch return 0;
            defer self.ctx.allocator.free(msg_z);
            gtk_message_dialog_set_markup(@ptrCast(dialog_widget), msg_z.ptr);
        }

        const buttons = if (opts.buttons.len == 0)
            &[_][]const u8{"OK"}
        else
            opts.buttons;
        for (buttons, 0..) |label, i| {
            const z = self.ctx.allocator.dupeZ(u8, label) catch continue;
            defer self.ctx.allocator.free(z);
            // Response IDs 0..N map directly to button index in
            // `opts.buttons` order. Cocoa returns the same convention
            // (first button = 0, default action) so the surface stays
            // consistent across platforms.
            _ = gtk_dialog_add_button(dialog, z.ptr, @intCast(i));
        }

        const response = gtk_dialog_run(dialog);
        gtk_widget_destroy(dialog_widget);
        if (response < 0) return 0; // delete / escape — fall back to default action
        return @intCast(response);
    }

    /// Capture the visible WebView region as PNG via
    /// `webkit_web_view_get_snapshot` (async, sync-wrapped through a
    /// GMainContext pump) + `cairo_surface_write_to_png`. Same shape
    /// as the macOS NSImage path; output is byte-for-byte deterministic
    /// for a given DOM render at a given device pixel ratio, so it
    /// plugs into the existing Level-3 golden-diff harness once the
    /// Linux smoke runner exists.
    pub fn takeSnapshotPng(self: *Window, path: []const u8) opts_mod.SnapshotError!void {
        const wv = self.ctx.webview orelse return opts_mod.SnapshotError.Unsupported;

        var cell: SnapshotCell = .{};
        webkit_web_view_get_snapshot(
            wv,
            WEBKIT_SNAPSHOT_REGION_VISIBLE,
            WEBKIT_SNAPSHOT_OPTIONS_NONE,
            null,
            onSnapshotDone,
            @ptrCast(&cell),
        );
        pumpMainContextUntilDone(&cell.done);

        const result = cell.result orelse return opts_mod.SnapshotError.CaptureFailed;
        const surface = webkit_web_view_get_snapshot_finish(wv, result, null) orelse return opts_mod.SnapshotError.CaptureFailed;
        defer cairo_surface_destroy(surface);

        const path_z = self.ctx.allocator.dupeZ(u8, path) catch return opts_mod.SnapshotError.WriteFailed;
        defer self.ctx.allocator.free(path_z);
        if (cairo_surface_write_to_png(surface, path_z.ptr) != CAIRO_STATUS_SUCCESS) {
            return opts_mod.SnapshotError.WriteFailed;
        }
    }
};

// ---- GTK signal trampolines -------------------------------------------------

fn onDestroy(_: ?*GtkWidget, _: ?*anyopaque) callconv(.c) void {
    if (live_windows > 0) live_windows -= 1;
    if (live_windows == 0) gtk_main_quit();
}

/// Build the default File + Edit menu bar and pack it above the
/// webview in a vertical GtkBox. Stores the accel group on `ctx`
/// (transitively freed when the window is destroyed — GTK ref-counts
/// the whole widget tree). Returns an error so the caller can fall
/// back to the menu-less layout on allocation failure.
fn installDefaultMenuBar(ctx: *WindowCtx, window_widget: *GtkWidget, wv_widget: *GtkWidget) !void {
    const box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_container_add(@ptrCast(window_widget), box);

    const menu_bar = gtk_menu_bar_new();
    const accel_group = gtk_accel_group_new();
    gtk_window_add_accel_group(@ptrCast(window_widget), accel_group);
    ctx.accel_group = accel_group;

    // File → Quit (Ctrl+Q is the only real shortcut binding).
    const file_item_widget = gtk_menu_item_new_with_mnemonic("_File");
    const file_menu = gtk_menu_new();
    gtk_menu_item_set_submenu(@ptrCast(file_item_widget), file_menu);
    gtk_menu_shell_append(@ptrCast(menu_bar), file_item_widget);

    const quit_item = gtk_menu_item_new_with_mnemonic("_Quit");
    _ = g_signal_connect_data(
        quit_item,
        "activate",
        @as(GCallback, @ptrCast(&onQuitActivate)),
        @ptrCast(ctx),
        null,
        0,
    );
    var quit_key: c_uint = 0;
    var quit_mods: GdkModifierType = 0;
    gtk_accelerator_parse("<Control>q", &quit_key, &quit_mods);
    gtk_widget_add_accelerator(quit_item, "activate", accel_group, quit_key, quit_mods, GTK_ACCEL_VISIBLE);
    gtk_menu_shell_append(@ptrCast(file_menu), quit_item);

    // Edit → standard items. NO `gtk_widget_add_accelerator` call —
    // WebKitGTK handles Ctrl+C/V/X/Z/Y/A inside text inputs natively,
    // and adding a GTK accelerator would consume the key event before
    // WebKit sees it. The mnemonic-with-tab labels render the shortcut
    // hint without binding a real accelerator.
    const edit_item_widget = gtk_menu_item_new_with_mnemonic("_Edit");
    const edit_menu = gtk_menu_new();
    gtk_menu_item_set_submenu(@ptrCast(edit_item_widget), edit_menu);
    gtk_menu_shell_append(@ptrCast(menu_bar), edit_item_widget);

    gtk_menu_shell_append(@ptrCast(edit_menu), gtk_menu_item_new_with_mnemonic("_Undo    Ctrl+Z"));
    gtk_menu_shell_append(@ptrCast(edit_menu), gtk_menu_item_new_with_mnemonic("_Redo    Ctrl+Y"));
    gtk_menu_shell_append(@ptrCast(edit_menu), gtk_separator_menu_item_new());
    gtk_menu_shell_append(@ptrCast(edit_menu), gtk_menu_item_new_with_mnemonic("Cu_t    Ctrl+X"));
    gtk_menu_shell_append(@ptrCast(edit_menu), gtk_menu_item_new_with_mnemonic("_Copy    Ctrl+C"));
    gtk_menu_shell_append(@ptrCast(edit_menu), gtk_menu_item_new_with_mnemonic("_Paste    Ctrl+V"));
    gtk_menu_shell_append(@ptrCast(edit_menu), gtk_menu_item_new_with_mnemonic("Select _All    Ctrl+A"));

    gtk_box_pack_start(@ptrCast(box), menu_bar, 0, 0, 0);
    gtk_box_pack_start(@ptrCast(box), wv_widget, 1, 1, 0);
}

/// Wrap an already-bound `AF_UNIX` SOCK_DGRAM fd in a GIOChannel
/// watch keyed on `G_IO_IN`. Called by `deep_link.startListener` on
/// the Linux backend; the fd ownership transfers — we set
/// `close_on_unref(true)` so the channel cleans the fd up at
/// window destruction.
pub fn attachUrlSocket(window: *Window, fd: c_int) !void {
    const ch = g_io_channel_unix_new(fd);
    g_io_channel_set_close_on_unref(ch, 1);
    const watch = g_io_add_watch(ch, G_IO_IN, &onUrlSocketReadable, @ptrCast(window.ctx));
    window.ctx.url_socket_fd = fd;
    window.ctx.url_socket_watch = watch;
}

/// `G_IO_IN` callback. One datagram per `recv`; URL bytes are UTF-8
/// with no terminator. Returns `1` (TRUE) to keep the watch active —
/// returning `0` would unregister the source after the first URL.
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

/// `activate` handler for File → Quit. Routes through the per-window
/// close path so the existing `live_windows` counter fires
/// `gtk_main_quit` only when the last window closes — matches the
/// multi-window semantics on the macOS + Windows backends.
fn onQuitActivate(_: ?*GtkMenuItem, user_data: ?*anyopaque) callconv(.c) void {
    const cx: *WindowCtx = @ptrCast(@alignCast(user_data orelse return));
    if (cx.window) |w| gtk_widget_destroy(w);
}

/// GTK `configure-event` fires on resize + reposition. Event struct
/// is `GdkEventConfigure { type, window, send_event, x, y, width,
/// height }`. We only read width + height — the layout matches the
/// stable GDK3 ABI.
const GdkEventConfigure = extern struct {
    type: c_int,
    window: ?*anyopaque,
    send_event: i8,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
};

fn onConfigureEvent(_widget: *GtkWidget, event: *GdkEventConfigure, user_data: ?*anyopaque) callconv(.c) gboolean {
    _ = _widget;
    const cx: *WindowCtx = @ptrCast(@alignCast(user_data orelse return 0));
    if (cx.on_resize) |cb| {
        const w: u32 = @intCast(@max(event.width, 0));
        const h: u32 = @intCast(@max(event.height, 0));
        cb(cx.on_resize_ctx, w, h);
    }
    // Returning 0 = don't stop propagation; GTK continues its
    // standard configure handling (layout invalidation etc.).
    return 0;
}

fn onFocusIn(_widget: *GtkWidget, _event: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) gboolean {
    _ = _widget;
    _ = _event;
    const cx: *WindowCtx = @ptrCast(@alignCast(user_data orelse return 0));
    if (cx.on_focus) |cb| cb(cx.on_focus_ctx, true);
    return 0;
}

fn onFocusOut(_widget: *GtkWidget, _event: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) gboolean {
    _ = _widget;
    _ = _event;
    const cx: *WindowCtx = @ptrCast(@alignCast(user_data orelse return 0));
    if (cx.on_focus) |cb| cb(cx.on_focus_ctx, false);
    return 0;
}

/// Compose the current min/max constraints into one GdkGeometry
/// struct + flag mask, then push through gtk_window_set_geometry_hints.
/// Called from both `setMinSize` and `setMaxSize` so the two bounds
/// stay coherent on the WM side.
fn applyGeometryHints(ctx: *WindowCtx) void {
    const w = ctx.window orelse return;
    var hints: GdkGeometry = .{};
    var flags: GdkWindowHints = 0;
    if (ctx.min_width != 0 or ctx.min_height != 0) {
        hints.min_width = @intCast(ctx.min_width);
        hints.min_height = @intCast(ctx.min_height);
        flags |= GDK_HINT_MIN_SIZE;
    }
    if (ctx.max_width != 0 or ctx.max_height != 0) {
        hints.max_width = if (ctx.max_width != 0) @intCast(ctx.max_width) else std.math.maxInt(c_int);
        hints.max_height = if (ctx.max_height != 0) @intCast(ctx.max_height) else std.math.maxInt(c_int);
        flags |= GDK_HINT_MAX_SIZE;
    }
    gtk_window_set_geometry_hints(@ptrCast(w), null, &hints, flags);
}

/// `delete-event` fires when the WM requests window close. Returning
/// `TRUE` (1) blocks the standard destroy; `FALSE` (0) lets GTK
/// proceed to emit `destroy`. We map our `on_close` callback's
/// return value: caller returns `true` to allow close, so we
/// return 0 to GTK ("don't block").
fn onDeleteEvent(_widget: *GtkWidget, _event: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) gboolean {
    _ = _widget;
    _ = _event;
    const cx: *WindowCtx = @ptrCast(@alignCast(user_data orelse return 0));
    const cb = cx.on_close orelse return 0;
    return if (cb(cx.on_close_ctx)) 0 else 1;
}

/// Mark the window as a URI-list drop destination + connect the
/// `drag-data-received` signal. Idempotent through the
/// `drag_signal` guard.
fn installDragDestination(ctx: *WindowCtx, window_widget: *GtkWidget) void {
    gtk_drag_dest_set(window_widget, GTK_DEST_DEFAULT_ALL, null, 0, GDK_ACTION_COPY);
    gtk_drag_dest_add_uri_targets(window_widget);
    ctx.drag_signal = g_signal_connect_data(
        window_widget,
        "drag-data-received",
        @as(GCallback, @ptrCast(&onDragDataReceived)),
        @ptrCast(ctx),
        null,
        0,
    );
}

/// GTK `drag-data-received` signal handler. Parses the URI list,
/// converts `file://...` URIs to filesystem paths, and invokes the
/// app callback. We always call `gtk_drag_finish(success=TRUE)`
/// — even on empty drops — so the drag source UI clears properly.
fn onDragDataReceived(
    widget: *GtkWidget,
    drag_context: *GdkDragContext,
    _x: c_int,
    _y: c_int,
    data: *GtkSelectionData,
    _info: c_uint,
    time: c_uint,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = widget;
    _ = _x;
    _ = _y;
    _ = _info;
    const ctx: *WindowCtx = @ptrCast(@alignCast(user_data orelse return));
    const cb = ctx.on_drag_drop orelse {
        gtk_drag_finish(drag_context, 1, 0, time);
        return;
    };

    const uri_array = gtk_selection_data_get_uris(data) orelse {
        gtk_drag_finish(drag_context, 1, 0, time);
        return;
    };
    defer g_strfreev(uri_array);

    // Count entries (NUL-terminated array).
    var n: usize = 0;
    while (uri_array[n] != null) : (n += 1) {}
    if (n == 0) {
        gtk_drag_finish(drag_context, 1, 0, time);
        return;
    }

    var paths_buf = ctx.allocator.alloc([]const u8, n) catch {
        gtk_drag_finish(drag_context, 0, 0, time);
        return;
    };
    defer ctx.allocator.free(paths_buf);

    var owned: usize = 0;
    defer {
        var i: usize = 0;
        while (i < owned) : (i += 1) ctx.allocator.free(paths_buf[i]);
    }

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const uri_ptr = uri_array[i] orelse {
            paths_buf[i] = "";
            continue;
        };
        const uri = std.mem.span(uri_ptr);
        // `file://path` — strip the scheme. Skip non-file URIs.
        const file_prefix = "file://";
        const path: []const u8 = if (std.mem.startsWith(u8, uri, file_prefix))
            uri[file_prefix.len..]
        else
            uri;
        const copy = ctx.allocator.dupe(u8, path) catch {
            paths_buf[i] = "";
            continue;
        };
        paths_buf[i] = copy;
        owned += 1;
    }

    cb(ctx.on_drag_drop_ctx, paths_buf);
    gtk_drag_finish(drag_context, 1, 0, time);
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
    // Intercept the title-sync marker before forwarding.
    const title_prefix = "__verve_title:";
    if (std.mem.startsWith(u8, slice, title_prefix)) {
        const title = slice[title_prefix.len..];
        const z = cx.allocator.dupeZ(u8, title) catch return;
        defer cx.allocator.free(z);
        if (cx.window) |w| gtk_window_set_title(@ptrCast(w), z.ptr);
        return;
    }
    if (cx.on_message) |h| h(cx.on_message_ctx, slice);
}

// ---- File chooser ----------------------------------------------------------

const FileChooserKind = enum { open, save };

fn runFileChooserNative(
    self: *Window,
    allocator: std.mem.Allocator,
    opts: opts_mod.FileDialogOptions,
    kind: FileChooserKind,
) opts_mod.DialogError![]u8 {
    const action: GtkFileChooserAction = switch (kind) {
        .open => if (opts.pick_directory) GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER else GTK_FILE_CHOOSER_ACTION_OPEN,
        .save => GTK_FILE_CHOOSER_ACTION_SAVE,
    };

    const title_default: []const u8 = switch (kind) {
        .open => "Open",
        .save => "Save",
    };
    const title_src = if (opts.title.len > 0) opts.title else title_default;
    const title_z = allocator.dupeZ(u8, title_src) catch return opts_mod.DialogError.OutOfMemory;
    defer allocator.free(title_z);

    const accept_label_default: []const u8 = switch (kind) {
        .open => "_Open",
        .save => "_Save",
    };
    const accept_z = allocator.dupeZ(u8, accept_label_default) catch return opts_mod.DialogError.OutOfMemory;
    defer allocator.free(accept_z);
    const cancel_z = allocator.dupeZ(u8, "_Cancel") catch return opts_mod.DialogError.OutOfMemory;
    defer allocator.free(cancel_z);

    const parent: ?*GtkWindow = if (self.ctx.window) |w| @ptrCast(w) else null;
    const dialog = gtk_file_chooser_native_new(title_z.ptr, parent, action, accept_z.ptr, cancel_z.ptr);
    defer g_object_unref(@ptrCast(dialog));
    const chooser: *GtkFileChooser = @ptrCast(dialog);

    // Open: optionally allow multi-select. Save: cannot multi-select
    // (Gtk enforces this), so only honor for open.
    if (kind == .open and opts.allow_multiple) {
        gtk_file_chooser_set_select_multiple(chooser, 1);
    }

    if (opts.default_path.len > 0) {
        const path_z = allocator.dupeZ(u8, opts.default_path) catch return opts_mod.DialogError.OutOfMemory;
        defer allocator.free(path_z);
        _ = gtk_file_chooser_set_current_folder(chooser, path_z.ptr);
    }

    if (kind == .save and opts.default_name.len > 0) {
        const name_z = allocator.dupeZ(u8, opts.default_name) catch return opts_mod.DialogError.OutOfMemory;
        defer allocator.free(name_z);
        gtk_file_chooser_set_current_name(chooser, name_z.ptr);
    }

    if (opts.allowed_extensions.len > 0) {
        const filter = gtk_file_filter_new();
        var name_buf: [256]u8 = undefined;
        if (std.fmt.bufPrintZ(&name_buf, "Allowed types", .{})) |z| {
            gtk_file_filter_set_name(filter, z.ptr);
        } else |_| {}
        for (opts.allowed_extensions) |ext| {
            var pat_buf: [128]u8 = undefined;
            const pat = std.fmt.bufPrintZ(&pat_buf, "*.{s}", .{ext}) catch continue;
            gtk_file_filter_add_pattern(filter, pat.ptr);
        }
        gtk_file_chooser_add_filter(chooser, filter);
    }

    const response = gtk_native_dialog_run(@ptrCast(dialog));
    if (response != GTK_RESPONSE_ACCEPT) return opts_mod.DialogError.Cancelled;

    const raw = gtk_file_chooser_get_filename(chooser) orelse return opts_mod.DialogError.Cancelled;
    defer g_free(@ptrCast(raw));
    const slice = std.mem.span(raw);
    return allocator.dupe(u8, slice) catch return opts_mod.DialogError.OutOfMemory;
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

const SnapshotCell = extern struct {
    result: ?*GAsyncResult = null,
    done: bool = false,
};

fn onSnapshotDone(_: ?*anyopaque, res: ?*GAsyncResult, user_data: ?*anyopaque) callconv(.c) void {
    const cell: *SnapshotCell = @ptrCast(@alignCast(user_data orelse return));
    cell.result = res;
    cell.done = true;
}

/// GtkSettings property-notify trampoline. The signal fires every
/// time the `gtk-application-prefer-dark-theme` property changes;
/// we re-read it and pass the resulting ColorScheme to the user
/// handler. Signature matches `GCallback` (variadic at the C ABI;
/// the GObject framework prepends the instance pointer and any
/// signal-specific args, so we accept them by `?*anyopaque`).
fn onColorSchemeChanged(_: ?*anyopaque, _: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const cx: *WindowCtx = @ptrCast(@alignCast(user_data orelse return));
    const cb = cx.on_color_scheme orelse return;
    const settings = gtk_settings_get_default() orelse {
        cb(cx.on_color_scheme_ctx, .unknown);
        return;
    };
    var prefer_dark: gboolean = 0;
    g_object_get(settings, "gtk-application-prefer-dark-theme", &prefer_dark, null);
    cb(cx.on_color_scheme_ctx, if (prefer_dark != 0) .dark else .light);
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

// ---- Clipboard --------------------------------------------------------------
//
// `gtk_clipboard_get(CLIPBOARD)` returns a process-global GtkClipboard
// keyed on the display's CLIPBOARD selection (the system clipboard;
// not PRIMARY, which is the middle-click selection). `set_text` is
// synchronous; `wait_for_text` blocks the main loop until the owning
// client responds — on X11/Wayland that's a single round-trip, so no
// nested GMainContext pump is needed.

fn clipboardHandle() *GtkClipboard {
    return gtk_clipboard_get(gdk_atom_intern_static_string("CLIPBOARD"));
}

pub fn clipboardWriteText(window: *anyopaque, text: []const u8) opts_mod.ClipboardError!void {
    const self: *Window = @ptrCast(@alignCast(window));

    const text_z = self.ctx.allocator.dupeZ(u8, text) catch return opts_mod.ClipboardError.OutOfMemory;
    defer self.ctx.allocator.free(text_z);

    const clip = clipboardHandle();
    gtk_clipboard_set_text(clip, text_z.ptr, @intCast(text.len));
    // Persist past the app's exit so a paste in another window after
    // we quit still sees the bytes (the X11 selection owner is the
    // application by default).
    gtk_clipboard_store(clip);
}

pub fn clipboardReadText(window: *anyopaque, allocator: std.mem.Allocator) opts_mod.ClipboardError!?[]u8 {
    _ = window;
    const clip = clipboardHandle();
    const raw = gtk_clipboard_wait_for_text(clip) orelse return null;
    defer g_free(@ptrCast(raw));
    const slice = std.mem.span(raw);
    if (slice.len == 0) return null;
    return allocator.dupe(u8, slice) catch return opts_mod.ClipboardError.OutOfMemory;
}
