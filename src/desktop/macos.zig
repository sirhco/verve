//! macOS backend — AppKit `NSWindow` + WebKit `WKWebView`.
//!
//! The implementation talks to the Objective-C runtime directly through
//! `objc_msgSend` (see `msg.zig` for the cast plumbing). We avoid
//! `@cImport`-ing Objective-C headers because Zig's translator does not
//! handle them; instead every class is looked up by name and every
//! selector by `sel_registerName`.
//!
//! The lifecycle is:
//!   1. `init` creates the shared `NSApplication`, builds a borderless-
//!      capable `NSWindow`, and configures a `WKWebView` whose user-
//!      content controller (a) injects the document-start IPC shim and
//!      (b) registers a script-message handler named `verve`.
//!   2. The `verve` custom URL scheme is registered through a dynamic
//!      `WKURLSchemeHandler` class. Resource requests are answered from
//!      `WindowOptions.assets` via `asset_router.resolve`.
//!   3. `run` activates the app and starts the main event loop.

const std = @import("std");
const m = @import("msg.zig");
const opts_mod = @import("options.zig");
const ipc = @import("ipc.zig");
const router = @import("asset_router.zig");
const cookies_mod = @import("cookies.zig");
const clipboard_mod = @import("clipboard.zig");

const id = m.id;
const SEL = m.SEL;
const nil: ?id = null;

/// Per-window context. Heap-allocated by `Window.init`, registered in
/// the module-level `registry` keyed by the WKWebView pointer so that
/// the dynamic Objective-C method bodies can resolve which window a
/// callback belongs to. We cannot add storage to runtime-allocated
/// classes without `class_addIvar` (restricted on modern macOS outside
/// `+load`), so the registry replaces ivars.
const WindowCtx = struct {
    allocator: std.mem.Allocator,
    assets: []const opts_mod.AssetEntry,
    dev_assets: ?opts_mod.DevAssetsConfig,
    on_message: ?opts_mod.MessageHandler,
    on_message_ctx: ?*anyopaque,
    on_color_scheme: ?opts_mod.ColorSchemeHandler = null,
    on_color_scheme_ctx: ?*anyopaque = null,
    color_scheme_observer: ?id = null,
    on_url_open: ?opts_mod.UrlOpenHandler = null,
    on_url_open_ctx: ?*anyopaque = null,
    on_drag_drop: ?opts_mod.DragDropHandler = null,
    on_drag_drop_ctx: ?*anyopaque = null,
    drop_view: ?id = null,
    webview: id,
};

// WK callbacks (scheme handler, script message handler) all fire on
// the AppKit main thread, so the registry needs no locking. Keyed by
// `*anyopaque` cast of the WKWebView pointer. Map storage uses the
// page allocator — entries are tiny and live for the window's lifetime.
var registry: std.AutoHashMapUnmanaged(*anyopaque, *WindowCtx) = .{};

// App-level setup (NSApplication delegate, menu bar) must happen
// exactly once per process. Window.init is idempotent through this
// flag so openChildWindow can call it for additional windows without
// re-installing the delegate or clobbering the menu bar.
var app_initialized: bool = false;

// The Objective-C runtime rejects a second `objc_allocateClassPair`
// with the same name in the same process, so the per-window dynamic
// classes (`VerveSchemeHandler`, `VerveMessageHandler`,
// `VerveThemeObserver`) are registered at the first Window.init and
// reused for every subsequent window. Without this, `openChildWindow`
// crashes with "objc_allocateClassPair failed".
var scheme_class_cached: ?m.Class = null;
var message_class_cached: ?m.Class = null;
var theme_class_cached: ?m.Class = null;
var url_opener_class_cached: ?m.Class = null;
var drag_window_class_cached: ?m.Class = null;

// Maps the `VerveDragWindow`'d NSWindow instance to the owning
// WindowCtx. The drag trampolines receive the window as self and
// look up the ctx — separate from the webview→ctx registry because
// drag events arrive at the window, not the webview.
var window_registry: std.AutoHashMapUnmanaged(*anyopaque, *WindowCtx) = .{};

// `NSAppleEventManager` accepts only one handler per (event class,
// event id) pair per process — multi-window apps converge on a
// single global URL handler instance that fans out to whichever
// WindowCtx most-recently called `setUrlOpenHandler`. Apps that
// want per-window routing keep ctx state in their own callback.
var url_opener_singleton: ?id = null;
var last_url_handler_ctx: ?*WindowCtx = null;

// Maps NSDistributedNotificationCenter observer instance → owning
// WindowCtx. Theme-change callbacks fire on the AppKit main thread
// so the map needs no locking.
var theme_registry: std.AutoHashMapUnmanaged(*anyopaque, *WindowCtx) = .{};

fn registerCtx(webview: id, ctx_ptr: *WindowCtx) !void {
    try registry.put(std.heap.page_allocator, @ptrCast(webview), ctx_ptr);
}

fn lookupCtx(webview: id) ?*WindowCtx {
    return registry.get(@ptrCast(webview));
}

fn unregisterCtx(webview: id) void {
    _ = registry.remove(@ptrCast(webview));
}

pub const Window = struct {
    app: id,
    window: id,
    webview: id,
    scheme_handler: id,
    message_handler: id,
    user_content: id,
    config: id,
    scheme_class: m.Class,
    message_class: m.Class,
    allocator: std.mem.Allocator,
    ctx: *WindowCtx,

    pub fn init(allocator: std.mem.Allocator, opts: opts_mod.WindowOptions) !Window {
        const NSApplication = m.getClass("NSApplication");
        const sharedApp = m.cast(*const fn (id, SEL) callconv(.c) id);
        const app = sharedApp(@as(id, @ptrCast(NSApplication)), m.sel("sharedApplication"));
        if (!app_initialized) {
            const setActivationPolicy = m.cast(*const fn (id, SEL, isize) callconv(.c) void);
            setActivationPolicy(app, m.sel("setActivationPolicy:"), 0); // NSApplicationActivationPolicyRegular
        }

        // Build a content rect and create the window. Style mask =
        // titled | closable | miniaturizable | resizable.
        const rect = NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = @floatFromInt(opts.width), .height = @floatFromInt(opts.height) } };
        const NSWindow = m.getClass("NSWindow");
        const nsAlloc = m.cast(*const fn (id, SEL) callconv(.c) id);
        const window_raw = nsAlloc(@as(id, @ptrCast(NSWindow)), m.sel("alloc"));
        const initWindow = m.cast(*const fn (id, SEL, NSRect, usize, usize, bool) callconv(.c) id);
        const style_mask: usize = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3);
        const window = initWindow(window_raw, m.sel("initWithContentRect:styleMask:backing:defer:"), rect, style_mask, 2, false);

        const setTitleSel = m.cast(*const fn (id, SEL, id) callconv(.c) void);
        setTitleSel(window, m.sel("setTitle:"), nsString(opts.title));

        const center = m.cast(*const fn (id, SEL) callconv(.c) void);
        center(window, m.sel("center"));

        // Register (or reuse) the dynamic classes for the custom-
        // scheme handler and the script-message handler. Both subclass
        // NSObject. The Objective-C runtime won't accept a second
        // `objc_allocateClassPair` with the same name, so cache after
        // the first window and hand the existing class to every
        // subsequent `openChildWindow` call.
        const NSObject = m.getClass("NSObject");
        const scheme_class = scheme_class_cached orelse blk: {
            const c = m.allocateClass(NSObject, "VerveSchemeHandler");
            m.addMethod(c, m.sel("webView:startURLSchemeTask:"), @ptrCast(&schemeStartTrampoline), "v@:@@");
            m.addMethod(c, m.sel("webView:stopURLSchemeTask:"), @ptrCast(&schemeStopTrampoline), "v@:@@");
            m.addProtocol(c, "WKURLSchemeHandler");
            m.registerClass(c);
            scheme_class_cached = c;
            break :blk c;
        };

        const message_class = message_class_cached orelse blk: {
            const c = m.allocateClass(NSObject, "VerveMessageHandler");
            m.addMethod(c, m.sel("userContentController:didReceiveScriptMessage:"), @ptrCast(&didReceiveTrampoline), "v@:@@");
            m.addProtocol(c, "WKScriptMessageHandler");
            m.registerClass(c);
            message_class_cached = c;
            break :blk c;
        };

        if (!app_initialized) {
            // NSApplicationDelegate. Without one, closing the last window
            // leaves the app running with no UI and no menu — the run
            // loop keeps spinning forever. The standard Cocoa convention
            // for single-window apps is to terminate when the last window
            // closes; the delegate's `applicationShouldTerminateAfterLastWindowClosed:`
            // returns YES to opt in. For multi-window apps NSApp tracks
            // all open windows automatically, so the same delegate
            // handles single AND multi-window quit semantics.
            const app_delegate_class = m.allocateClass(NSObject, "VerveAppDelegate");
            m.addMethod(app_delegate_class, m.sel("applicationShouldTerminateAfterLastWindowClosed:"), @ptrCast(&appShouldTerminateOnLastWindowClosed), "B@:@");
            m.addProtocol(app_delegate_class, "NSApplicationDelegate");
            m.registerClass(app_delegate_class);

            const delegate_alloc = m.cast(*const fn (id, SEL) callconv(.c) id);
            const delegate_init = m.cast(*const fn (id, SEL) callconv(.c) id);
            const app_delegate = delegate_init(
                delegate_alloc(@as(id, @ptrCast(app_delegate_class)), m.sel("alloc")),
                m.sel("init"),
            );
            const setDelegate = m.cast(*const fn (id, SEL, id) callconv(.c) void);
            setDelegate(app, m.sel("setDelegate:"), app_delegate);

            if (opts.install_default_menu) installDefaultMenuBar(app);
            app_initialized = true;
        }

        // Configure the WKWebView with a user-content controller that
        // owns the message handler and the document-start shim.
        const WKWebViewConfiguration = m.getClass("WKWebViewConfiguration");
        const cfg_alloc = m.cast(*const fn (id, SEL) callconv(.c) id);
        const cfg = m.cast(*const fn (id, SEL) callconv(.c) id)(cfg_alloc(@as(id, @ptrCast(WKWebViewConfiguration)), m.sel("alloc")), m.sel("init"));

        const userContentControllerSelector = m.sel("userContentController");
        const user_content = m.cast(*const fn (id, SEL) callconv(.c) id)(cfg, userContentControllerSelector);

        // Document-start script injection.
        const WKUserScript = m.getClass("WKUserScript");
        const us_alloc = m.cast(*const fn (id, SEL) callconv(.c) id);
        const us_raw = us_alloc(@as(id, @ptrCast(WKUserScript)), m.sel("alloc"));
        const initUserScript = m.cast(*const fn (id, SEL, id, isize, bool) callconv(.c) id);
        const shim_str = nsString(ipc.shim_js);
        const user_script = initUserScript(us_raw, m.sel("initWithSource:injectionTime:forMainFrameOnly:"), shim_str, 0, false);

        const addUserScript = m.cast(*const fn (id, SEL, id) callconv(.c) void);
        addUserScript(user_content, m.sel("addUserScript:"), user_script);

        // Script message handler.
        const mh_alloc = m.cast(*const fn (id, SEL) callconv(.c) id);
        const message_handler = m.cast(*const fn (id, SEL) callconv(.c) id)(mh_alloc(@as(id, @ptrCast(message_class)), m.sel("alloc")), m.sel("init"));
        const addScriptMessageHandler = m.cast(*const fn (id, SEL, id, id) callconv(.c) void);
        addScriptMessageHandler(user_content, m.sel("addScriptMessageHandler:name:"), message_handler, nsString("verve"));

        // Custom URL scheme handler.
        const sh_alloc = m.cast(*const fn (id, SEL) callconv(.c) id);
        const scheme_handler = m.cast(*const fn (id, SEL) callconv(.c) id)(sh_alloc(@as(id, @ptrCast(scheme_class)), m.sel("alloc")), m.sel("init"));
        const setURLSchemeHandler = m.cast(*const fn (id, SEL, id, id) callconv(.c) void);
        const scheme_str = nsString(opts.scheme);
        setURLSchemeHandler(cfg, m.sel("setURLSchemeHandler:forURLScheme:"), scheme_handler, scheme_str);

        if (opts.devtools) {
            const preferences = m.cast(*const fn (id, SEL) callconv(.c) id)(cfg, m.sel("preferences"));
            const setValueForKey = m.cast(*const fn (id, SEL, id, id) callconv(.c) void);
            // `developerExtrasEnabled` is a private preferences key but
            // it has been stable since WebKit2. Failing here is non-
            // fatal — devtools just stay hidden.
            setValueForKey(preferences, m.sel("setValue:forKey:"), nsNumberBool(true), nsString("developerExtrasEnabled"));
        }

        // Build the WKWebView and pin it as the window's content view.
        const WKWebView = m.getClass("WKWebView");
        const wv_alloc = m.cast(*const fn (id, SEL) callconv(.c) id);
        const wv_raw = wv_alloc(@as(id, @ptrCast(WKWebView)), m.sel("alloc"));
        const initWebView = m.cast(*const fn (id, SEL, NSRect, id) callconv(.c) id);
        const webview = initWebView(wv_raw, m.sel("initWithFrame:configuration:"), rect, cfg);

        const setContentView = m.cast(*const fn (id, SEL, id) callconv(.c) void);
        setContentView(window, m.sel("setContentView:"), webview);

        const ctx_ptr = try allocator.create(WindowCtx);
        errdefer allocator.destroy(ctx_ptr);
        ctx_ptr.* = .{
            .allocator = allocator,
            .assets = opts.assets,
            .dev_assets = opts.dev_assets,
            .on_message = opts.on_message,
            .on_message_ctx = opts.on_message_ctx,
            .on_url_open = opts.on_url_open,
            .on_url_open_ctx = opts.on_url_open_ctx,
            .on_drag_drop = opts.on_drag_drop,
            .on_drag_drop_ctx = opts.on_drag_drop_ctx,
            .webview = webview,
        };
        if (opts.on_url_open != null) {
            installUrlOpenerIfNeeded(ctx_ptr);
        }
        if (opts.on_drag_drop != null) {
            installDragDestination(window, ctx_ptr) catch |err| {
                std.log.warn("verve.desktop[macos]: drag-drop install failed: {s}", .{@errorName(err)});
            };
        }
        if (opts.dev_assets) |dev| {
            std.log.info("verve.desktop[macos]: dev-mode asset fallback enabled, dir='{s}'", .{dev.dir});
        }
        try registerCtx(webview, ctx_ptr);
        errdefer unregisterCtx(webview);

        std.log.info("verve.desktop[macos]: window+webview ready ({d}x{d}), scheme={s}", .{ opts.width, opts.height, opts.scheme });

        var self = Window{
            .app = app,
            .window = window,
            .webview = webview,
            .scheme_handler = scheme_handler,
            .message_handler = message_handler,
            .user_content = user_content,
            .config = cfg,
            .scheme_class = scheme_class,
            .message_class = message_class,
            .allocator = allocator,
            .ctx = ctx_ptr,
        };

        if (opts.initial_path.len > 0) {
            const url = std.fmt.allocPrint(allocator, "{s}://app/{s}", .{ opts.scheme, opts.initial_path }) catch return error.OutOfMemory;
            defer allocator.free(url);
            try self.loadUrl(url);
        }

        const makeKeyAndOrderFront = m.cast(*const fn (id, SEL, ?id) callconv(.c) void);
        makeKeyAndOrderFront(window, m.sel("makeKeyAndOrderFront:"), nil);

        return self;
    }

    pub fn setTitle(self: *Window, title: []const u8) void {
        const setTitleSel = m.cast(*const fn (id, SEL, id) callconv(.c) void);
        setTitleSel(self.window, m.sel("setTitle:"), nsString(title));
    }

    pub fn loadUrl(self: *Window, url: []const u8) !void {
        const NSURL = m.getClass("NSURL");
        const urlWithString = m.cast(*const fn (id, SEL, id) callconv(.c) id);
        const ns_url = urlWithString(@as(id, @ptrCast(NSURL)), m.sel("URLWithString:"), nsString(url));
        if (@intFromPtr(ns_url) == 0) return error.InvalidUrl;

        const NSURLRequest = m.getClass("NSURLRequest");
        const requestWithURL = m.cast(*const fn (id, SEL, id) callconv(.c) id);
        const req = requestWithURL(@as(id, @ptrCast(NSURLRequest)), m.sel("requestWithURL:"), ns_url);

        const loadRequest = m.cast(*const fn (id, SEL, id) callconv(.c) id);
        _ = loadRequest(self.webview, m.sel("loadRequest:"), req);
    }

    pub fn loadHtml(self: *Window, html: []const u8, base_url: ?[]const u8) !void {
        const loadHTMLString = m.cast(*const fn (id, SEL, id, ?id) callconv(.c) id);
        const base = if (base_url) |b| nsString(b) else null;
        _ = loadHTMLString(self.webview, m.sel("loadHTMLString:baseURL:"), nsString(html), base);
    }

    pub fn evalJs(self: *Window, script: []const u8) void {
        const evaluate = m.cast(*const fn (id, SEL, id, ?id) callconv(.c) void);
        evaluate(self.webview, m.sel("evaluateJavaScript:completionHandler:"), nsString(script), null);
    }

    pub fn setMessageHandler(self: *Window, handler: opts_mod.MessageHandler, handler_ctx: ?*anyopaque) void {
        self.ctx.on_message = handler;
        self.ctx.on_message_ctx = handler_ctx;
    }

    /// Open a second window in the same app session. Returned Window
    /// shares NSApplication state (delegate, menu bar) with the
    /// caller; it gets its own WKWebView, scheme handler, and
    /// WindowCtx in the registry. Uses the parent's allocator.
    pub fn openChildWindow(self: *Window, opts: opts_mod.WindowOptions) !Window {
        return Window.init(self.allocator, opts);
    }

    /// Per-window cookie store. WKHTTPCookieStore wiring is a
    /// follow-up — see module-level cookieGet/Set/Delete/Clear stubs.
    pub fn cookies(self: *Window) cookies_mod.CookieStore {
        return .{ .window = @ptrCast(self) };
    }

    /// System pasteboard handle. NSPasteboard is process-global; the
    /// per-window wrapper is only there for API parity with cookies().
    pub fn clipboard(self: *Window) clipboard_mod.Clipboard {
        return .{ .window = @ptrCast(self) };
    }

    /// Register a callback fired on AppleInterfaceThemeChangedNotification.
    /// The observer subscribes to `NSDistributedNotificationCenter`
    /// with a lazily-allocated `VerveThemeObserver` class. Passing a
    /// `null` handler removes any prior observer for this window.
    pub fn setColorSchemeHandler(self: *Window, cb: ?opts_mod.ColorSchemeHandler, ctx: ?*anyopaque) void {
        self.ctx.on_color_scheme = cb;
        self.ctx.on_color_scheme_ctx = ctx;

        if (self.ctx.color_scheme_observer == null and cb != null) {
            const NSObject = m.getClass("NSObject");
            const theme_class = theme_class_cached orelse blk: {
                const c = m.allocateClass(NSObject, "VerveThemeObserver");
                m.addMethod(c, m.sel("themeChanged:"), @ptrCast(&themeChangedTrampoline), "v@:@");
                m.registerClass(c);
                theme_class_cached = c;
                break :blk c;
            };
            const alloc_id = m.cast(*const fn (id, SEL) callconv(.c) id);
            const init_id = m.cast(*const fn (id, SEL) callconv(.c) id);
            const observer = init_id(alloc_id(@as(id, @ptrCast(theme_class)), m.sel("alloc")), m.sel("init"));

            theme_registry.put(std.heap.page_allocator, @ptrCast(observer), self.ctx) catch return;

            const NSDistributedNotificationCenter = m.getClass("NSDistributedNotificationCenter");
            const defaultCenter = m.cast(*const fn (id, SEL) callconv(.c) id);
            const center = defaultCenter(@as(id, @ptrCast(NSDistributedNotificationCenter)), m.sel("defaultCenter"));

            const addObserver = m.cast(*const fn (id, SEL, id, SEL, id, ?id) callconv(.c) void);
            addObserver(
                center,
                m.sel("addObserver:selector:name:object:"),
                observer,
                m.sel("themeChanged:"),
                nsString("AppleInterfaceThemeChangedNotification"),
                null,
            );
            self.ctx.color_scheme_observer = observer;
        }
    }

    /// Register / replace the deep-link URL handler. macOS routes
    /// every `verve://...` URL the OS hands to the app through
    /// `NSAppleEventManager` (`kInternetEventClass`/`kAEGetURL`),
    /// regardless of whether the URL arrived at cold launch or while
    /// the app was already running — Cocoa queues pre-launch URLs
    /// until the AEH installs, then drains them. The framework
    /// installs the AEH lazily on the first non-null call and keeps
    /// it process-wide. Passing `null` clears the handler — the AEH
    /// stays installed but fires nothing.
    pub fn setUrlOpenHandler(self: *Window, cb: ?opts_mod.UrlOpenHandler, ctx: ?*anyopaque) void {
        self.ctx.on_url_open = cb;
        self.ctx.on_url_open_ctx = ctx;
        if (cb != null) installUrlOpenerIfNeeded(self.ctx);
    }

    /// Synthesize a URL delivery — call the registered handler with
    /// `url` as if the OS had just delivered it. Templates use this
    /// to feed cold-launch URLs that arrived through argv (the
    /// AppleEvent path supersedes argv on macOS, so this code path
    /// is mostly used by Windows + Linux templates for parity).
    pub fn deliverUrl(self: *Window, url: []const u8) void {
        if (self.ctx.on_url_open) |cb| cb(self.ctx.on_url_open_ctx, url);
    }

    /// Install / replace the drag-drop handler. Setting a non-null
    /// callback registers the window as a drag destination for
    /// `NSPasteboardTypeFileURL`; the trampolines on the
    /// `VerveDragWindow` subclass extract file URLs from the
    /// pasteboard on drop and fire the callback. Passing `null`
    /// unregisters the destination.
    /// Trigger the platform print dialog for the WebView's current
    /// document. v1 dispatches via the page's `window.print()` —
    /// each native engine (WKWebView / WebView2 / WebKitGTK) renders
    /// its own print UI off that call. Native print APIs
    /// (`NSPrintOperation` / `ICoreWebView2_16::ShowPrintUI` /
    /// `webkit_print_operation_run_dialog`) are deferred polish for
    /// silent print + page-range / printer-selection controls.
    pub fn print(self: *Window) void {
        self.evalJs("window.print();");
    }

    /// Set the window's `NSAccessibilityLabel` — the string
    /// VoiceOver reads when the window receives focus. Distinct from
    /// `setTitle:`; the latter sets the visible title-bar text while
    /// this targets the accessibility tree only. Web content +
    /// default menu items already publish their own accessibility
    /// labels via WKWebView + NSMenuItem, no extra wiring needed.
    pub fn setAccessibilityLabel(self: *Window, label: []const u8) void {
        const setLabel = m.cast(*const fn (id, SEL, id) callconv(.c) void);
        setLabel(self.window, m.sel("setAccessibilityLabel:"), nsString(label));
    }

    /// Toggle whether this window floats above normal-level windows.
    /// `true` switches to `NSFloatingWindowLevel` (3); `false` back
    /// to `NSNormalWindowLevel` (0).
    pub fn setAlwaysOnTop(self: *Window, on: bool) void {
        const NSNormalWindowLevel: isize = 0;
        const NSFloatingWindowLevel: isize = 3;
        const setLevel = m.cast(*const fn (id, SEL, isize) callconv(.c) void);
        setLevel(self.window, m.sel("setLevel:"), if (on) NSFloatingWindowLevel else NSNormalWindowLevel);
    }

    /// Window-wide opacity in `[0.0, 1.0]`. `1.0` is opaque; `0.0`
    /// fully transparent. Forces `setOpaque:NO` so the alpha
    /// channel actually composites — without it AppKit may rely on
    /// an opaque shortcut and ignore alpha.
    pub fn setOpacity(self: *Window, value: f64) void {
        const setOpaque = m.cast(*const fn (id, SEL, bool) callconv(.c) void);
        setOpaque(self.window, m.sel("setOpaque:"), value >= 1.0);
        const setAlpha = m.cast(*const fn (id, SEL, f64) callconv(.c) void);
        setAlpha(self.window, m.sel("setAlphaValue:"), std.math.clamp(value, 0.0, 1.0));
    }

    pub fn setDragDropHandler(self: *Window, cb: ?opts_mod.DragDropHandler, ctx: ?*anyopaque) void {
        self.ctx.on_drag_drop = cb;
        self.ctx.on_drag_drop_ctx = ctx;
        if (cb != null) {
            installDragDestination(self.window, self.ctx) catch |err| {
                std.log.warn("verve.desktop[macos]: drag-drop install failed: {s}", .{@errorName(err)});
            };
        } else {
            // Unregister types but leave the class swap in place —
            // future setDragDropHandler(non-null) calls are cheap.
            const unregister = m.cast(*const fn (id, SEL) callconv(.c) void);
            unregister(self.window, m.sel("unregisterDraggedTypes"));
        }
    }

    /// Current macOS appearance: dark vs light, derived from
    /// `[NSApp.effectiveAppearance].name`. The string is one of
    /// `NSAppearanceNameAqua`, `NSAppearanceNameDarkAqua`,
    /// `NSAppearanceNameAccessibilityHighContrastAqua`, etc — any
    /// name containing the substring "Dark" maps to .dark.
    pub fn colorScheme(self: *Window) opts_mod.ColorScheme {
        const appearanceSel = m.cast(*const fn (id, SEL) callconv(.c) ?id);
        const appearance = appearanceSel(self.app, m.sel("effectiveAppearance")) orelse return .unknown;
        const nameSel = m.cast(*const fn (id, SEL) callconv(.c) ?id);
        const name_str = nameSel(appearance, m.sel("name")) orelse return .unknown;
        const utf8 = m.cast(*const fn (id, SEL) callconv(.c) ?[*:0]const u8);
        const cstr = utf8(name_str, m.sel("UTF8String")) orelse return .unknown;
        const slice = std.mem.span(cstr);
        if (std.mem.indexOf(u8, slice, "Dark") != null) return .dark;
        return .light;
    }

    /// Render a PNG snapshot of the current WKWebView contents to
    /// `path` on disk. Sync-blocks on a nested NSRunLoop pump until the
    /// completion handler fires, then encodes the NSImage via
    /// NSBitmapImageRep and writes via `[NSData writeToFile:atomically:]`.
    /// Used by the Level-3 smoke harness for golden-diff CI.
    pub fn takeSnapshotPng(self: *Window, path: []const u8) opts_mod.SnapshotError!void {
        var image: ?id = null;
        var done = false;
        var block: SnapshotBlock = .{
            .isa = &_NSConcreteStackBlock,
            .flags = 0,
            .reserved = 0,
            .invoke = &snapshotBlockInvoke,
            .descriptor = &snapshot_block_desc,
            .out_image = &image,
            .done = &done,
        };
        // Pass nil config — defaults to the whole web view bounds at
        // the device's native pixel scale.
        const takeSnapshot = m.cast(*const fn (id, SEL, ?id, *SnapshotBlock) callconv(.c) void);
        takeSnapshot(self.webview, m.sel("takeSnapshotWithConfiguration:completionHandler:"), null, &block);
        pumpUntilDone(&done);

        const ns_image = image orelse return opts_mod.SnapshotError.CaptureFailed;
        const release = m.cast(*const fn (id, SEL) callconv(.c) void);
        defer release(ns_image, m.sel("release"));

        // NSImage → TIFF → NSBitmapImageRep → PNG NSData.
        const tiffSel = m.cast(*const fn (id, SEL) callconv(.c) id);
        const tiff = tiffSel(ns_image, m.sel("TIFFRepresentation"));
        if (@intFromPtr(tiff) == 0) return opts_mod.SnapshotError.EncodeFailed;

        const NSBitmapImageRep = m.getClass("NSBitmapImageRep");
        const imageRepWithData = m.cast(*const fn (id, SEL, id) callconv(.c) id);
        const rep = imageRepWithData(@as(id, @ptrCast(NSBitmapImageRep)), m.sel("imageRepWithData:"), tiff);
        if (@intFromPtr(rep) == 0) return opts_mod.SnapshotError.EncodeFailed;

        // Empty NSDictionary singleton for properties.
        const NSDictionary = m.getClass("NSDictionary");
        const dictionarySel = m.cast(*const fn (id, SEL) callconv(.c) id);
        const empty_dict = dictionarySel(@as(id, @ptrCast(NSDictionary)), m.sel("dictionary"));

        // NSBitmapImageFileTypePNG = 4 (NSPNGFileType enum value).
        const NS_BITMAP_FILE_TYPE_PNG: u64 = 4;
        const representationUsingType = m.cast(*const fn (id, SEL, u64, id) callconv(.c) id);
        const png_data = representationUsingType(rep, m.sel("representationUsingType:properties:"), NS_BITMAP_FILE_TYPE_PNG, empty_dict);
        if (@intFromPtr(png_data) == 0) return opts_mod.SnapshotError.EncodeFailed;

        const writeToFile = m.cast(*const fn (id, SEL, id, bool) callconv(.c) bool);
        const ok = writeToFile(png_data, m.sel("writeToFile:atomically:"), nsString(path), true);
        if (!ok) return opts_mod.SnapshotError.WriteFailed;
    }

    pub fn run(self: *Window) void {
        const activate = m.cast(*const fn (id, SEL, bool) callconv(.c) void);
        activate(self.app, m.sel("activateIgnoringOtherApps:"), true);
        const runLoop = m.cast(*const fn (id, SEL) callconv(.c) void);
        runLoop(self.app, m.sel("run"));
    }

    pub fn deinit(self: *Window) void {
        unregisterCtx(self.webview);
        self.allocator.destroy(self.ctx);
        const release = m.cast(*const fn (id, SEL) callconv(.c) void);
        release(self.window, m.sel("close"));
    }

    /// Programmatically quit the app. Stops `run()` immediately.
    pub fn terminate(self: *Window) void {
        const term = m.cast(*const fn (id, SEL, ?id) callconv(.c) void);
        term(self.app, m.sel("terminate:"), null);
    }

    /// Close just this window. The app keeps running. The app-level
    /// delegate will call `terminate` automatically if no other
    /// windows remain (the standard macOS single-window convention).
    pub fn close(self: *Window) void {
        const closeSel = m.cast(*const fn (id, SEL) callconv(.c) void);
        closeSel(self.window, m.sel("close"));
    }

    /// Modal file picker. Returns the chosen path (caller frees) or
    /// `error.Cancelled` if the user dismissed the panel.
    pub fn openFileDialog(self: *Window, allocator: std.mem.Allocator, opts: opts_mod.FileDialogOptions) opts_mod.DialogError![]u8 {
        const NSOpenPanel = m.getClass("NSOpenPanel");
        const panel = m.cast(*const fn (id, SEL) callconv(.c) id)(@as(id, @ptrCast(NSOpenPanel)), m.sel("openPanel"));

        const setBool = m.cast(*const fn (id, SEL, bool) callconv(.c) void);
        setBool(panel, m.sel("setCanChooseFiles:"), !opts.pick_directory);
        setBool(panel, m.sel("setCanChooseDirectories:"), opts.pick_directory);
        setBool(panel, m.sel("setAllowsMultipleSelection:"), opts.allow_multiple);

        const setStr = m.cast(*const fn (id, SEL, id) callconv(.c) void);
        if (opts.title.len > 0) setStr(panel, m.sel("setTitle:"), nsString(opts.title));
        if (opts.message.len > 0) setStr(panel, m.sel("setMessage:"), nsString(opts.message));
        if (opts.default_path.len > 0) {
            const NSURL = m.getClass("NSURL");
            const fileURL = m.cast(*const fn (id, SEL, id) callconv(.c) id);
            const ns_url = fileURL(@as(id, @ptrCast(NSURL)), m.sel("fileURLWithPath:"), nsString(opts.default_path));
            setStr(panel, m.sel("setDirectoryURL:"), ns_url);
        }

        applyAllowedExtensions(panel, opts.allowed_extensions);

        _ = self;
        const runModal = m.cast(*const fn (id, SEL) callconv(.c) isize);
        const response = runModal(panel, m.sel("runModal"));
        const NSModalResponseOK: isize = 1;
        if (response != NSModalResponseOK) return opts_mod.DialogError.Cancelled;

        const urlSel = m.cast(*const fn (id, SEL) callconv(.c) id);
        const url = urlSel(panel, m.sel("URL"));
        return copyFilePath(allocator, url);
    }

    /// Modal save panel. Returns the chosen path or `error.Cancelled`.
    pub fn saveFileDialog(self: *Window, allocator: std.mem.Allocator, opts: opts_mod.FileDialogOptions) opts_mod.DialogError![]u8 {
        const NSSavePanel = m.getClass("NSSavePanel");
        const panel = m.cast(*const fn (id, SEL) callconv(.c) id)(@as(id, @ptrCast(NSSavePanel)), m.sel("savePanel"));

        const setStr = m.cast(*const fn (id, SEL, id) callconv(.c) void);
        if (opts.title.len > 0) setStr(panel, m.sel("setTitle:"), nsString(opts.title));
        if (opts.message.len > 0) setStr(panel, m.sel("setMessage:"), nsString(opts.message));
        if (opts.default_name.len > 0) setStr(panel, m.sel("setNameFieldStringValue:"), nsString(opts.default_name));
        if (opts.default_path.len > 0) {
            const NSURL = m.getClass("NSURL");
            const fileURL = m.cast(*const fn (id, SEL, id) callconv(.c) id);
            const ns_url = fileURL(@as(id, @ptrCast(NSURL)), m.sel("fileURLWithPath:"), nsString(opts.default_path));
            setStr(panel, m.sel("setDirectoryURL:"), ns_url);
        }

        applyAllowedExtensions(panel, opts.allowed_extensions);

        _ = self;
        const runModal = m.cast(*const fn (id, SEL) callconv(.c) isize);
        const response = runModal(panel, m.sel("runModal"));
        const NSModalResponseOK: isize = 1;
        if (response != NSModalResponseOK) return opts_mod.DialogError.Cancelled;

        const urlSel = m.cast(*const fn (id, SEL) callconv(.c) id);
        const url = urlSel(panel, m.sel("URL"));
        return copyFilePath(allocator, url);
    }

    /// Modal alert. Returns the index of the button the user clicked
    /// (0 = first, default). Never throws — alerts always resolve.
    pub fn showAlert(self: *Window, opts: opts_mod.AlertOptions) usize {
        _ = self;
        const NSAlert = m.getClass("NSAlert");
        const alloc_id = m.cast(*const fn (id, SEL) callconv(.c) id);
        const init_id = m.cast(*const fn (id, SEL) callconv(.c) id);
        const alert = init_id(alloc_id(@as(id, @ptrCast(NSAlert)), m.sel("alloc")), m.sel("init"));

        const setStr = m.cast(*const fn (id, SEL, id) callconv(.c) void);
        if (opts.title.len > 0) setStr(alert, m.sel("setMessageText:"), nsString(opts.title));
        if (opts.message.len > 0) setStr(alert, m.sel("setInformativeText:"), nsString(opts.message));

        const setStyle = m.cast(*const fn (id, SEL, isize) callconv(.c) void);
        const style_val: isize = switch (opts.style) {
            .informational => 1,
            .warning => 0,
            .critical => 2,
        };
        setStyle(alert, m.sel("setAlertStyle:"), style_val);

        const addBtn = m.cast(*const fn (id, SEL, id) callconv(.c) id);
        if (opts.buttons.len == 0) {
            _ = addBtn(alert, m.sel("addButtonWithTitle:"), nsString("OK"));
        } else {
            for (opts.buttons) |label| _ = addBtn(alert, m.sel("addButtonWithTitle:"), nsString(label));
        }

        const runModal = m.cast(*const fn (id, SEL) callconv(.c) isize);
        const response = runModal(alert, m.sel("runModal"));
        // NSAlertFirstButtonReturn = 1000 + button index
        const NSAlertFirstButtonReturn: isize = 1000;
        if (response < NSAlertFirstButtonReturn) return 0;
        return @intCast(response - NSAlertFirstButtonReturn);
    }
};

// ----- Trampolines -----------------------------------------------------------

fn schemeStartTrampoline(self: id, _cmd: SEL, webview: id, task: id) callconv(.c) void {
    _ = self;
    _ = _cmd;
    const ctx_ptr = lookupCtx(webview) orelse {
        std.log.warn("verve.desktop[macos]: scheme handler fired with no registered ctx", .{});
        sendError(task, error.NotFound);
        return;
    };
    handleSchemeStart(ctx_ptr, task) catch |err| {
        std.log.warn("verve scheme handler failed: {s}", .{@errorName(err)});
    };
}

fn schemeStopTrampoline(self: id, _cmd: SEL, webview: id, task: id) callconv(.c) void {
    _ = self;
    _ = _cmd;
    _ = webview;
    _ = task;
}

fn didReceiveTrampoline(self: id, _cmd: SEL, controller: id, message: id) callconv(.c) void {
    _ = self;
    _ = _cmd;
    _ = controller;
    const wv = m.cast(*const fn (id, SEL) callconv(.c) id)(message, m.sel("webView"));
    const ctx_ptr = lookupCtx(wv) orelse return;
    handleScriptMessage(ctx_ptr, message);
}

/// Trampoline for the NSDistributedNotificationCenter observer that
/// watches `AppleInterfaceThemeChangedNotification`. Looks up the
/// owning WindowCtx via the per-observer registry, re-reads the
/// current appearance through the same path `Window.colorScheme()`
/// uses, and dispatches to the caller-registered handler.
fn themeChangedTrampoline(self: id, _cmd: SEL, _notification: id) callconv(.c) void {
    _ = _cmd;
    _ = _notification;
    const ctx_ptr = theme_registry.get(@ptrCast(self)) orelse return;
    if (ctx_ptr.on_color_scheme) |cb| {
        // Re-derive scheme via the same path the public getter uses
        // so the value the caller sees is the new one, not whatever
        // was current when the observer registered.
        const app_class = m.getClass("NSApplication");
        const sharedApp = m.cast(*const fn (id, SEL) callconv(.c) id);
        const app = sharedApp(@as(id, @ptrCast(app_class)), m.sel("sharedApplication"));
        const appearanceSel = m.cast(*const fn (id, SEL) callconv(.c) ?id);
        const appearance = appearanceSel(app, m.sel("effectiveAppearance"));
        const scheme: opts_mod.ColorScheme = blk: {
            const ap = appearance orelse break :blk .unknown;
            const nameSel = m.cast(*const fn (id, SEL) callconv(.c) ?id);
            const name_str = nameSel(ap, m.sel("name")) orelse break :blk .unknown;
            const utf8 = m.cast(*const fn (id, SEL) callconv(.c) ?[*:0]const u8);
            const cstr = utf8(name_str, m.sel("UTF8String")) orelse break :blk .unknown;
            const slice = std.mem.span(cstr);
            if (std.mem.indexOf(u8, slice, "Dark") != null) break :blk .dark;
            break :blk .light;
        };
        cb(ctx_ptr.on_color_scheme_ctx, scheme);
    }
}

/// Swap an existing NSWindow's class to `VerveDragWindow` and
/// register the window for `NSPasteboardTypeFileURL`. The subclass
/// only adds `draggingEntered:` + `performDragOperation:` methods —
/// passing through to NSWindow for everything else. Idempotent:
/// repeated calls just refresh the registry entry.
fn installDragDestination(window: id, ctx_ptr: *WindowCtx) !void {
    const NSWindow = m.getClass("NSWindow");
    const klass = drag_window_class_cached orelse blk: {
        const c = m.allocateClass(NSWindow, "VerveDragWindow");
        m.addMethod(c, m.sel("draggingEntered:"), @ptrCast(&dragEnteredTrampoline), "L@:@");
        m.addMethod(c, m.sel("performDragOperation:"), @ptrCast(&dragPerformTrampoline), "B@:@");
        m.registerClass(c);
        drag_window_class_cached = c;
        break :blk c;
    };
    // `object_setClass` retains the existing instance state while
    // swapping the isa pointer. Safe on documented NSObject
    // subclasses since Snow Leopard.
    const objc_setClass = @extern(*const fn (id, m.Class) callconv(.c) m.Class, .{ .name = "object_setClass" });
    _ = objc_setClass(window, klass);

    try window_registry.put(std.heap.page_allocator, @as(*anyopaque, @ptrCast(window)), ctx_ptr);

    // `NSPasteboardTypeFileURL` is the modern (post-10.13) constant
    // for file-URL pasteboard items. Older `NSFilenamesPboardType`
    // is deprecated. The pasteboard type is a normal NSString;
    // dlsyming the exported constant from AppKit is the canonical
    // path but `[NSPasteboard nameFromUTI:]` works too — simplest
    // is hard-coding the well-known string value
    // ("public.file-url") since UTType maps it 1:1.
    const NSArray = m.getClass("NSArray");
    const arrayWithObject = m.cast(*const fn (id, SEL, id) callconv(.c) id);
    const types_array = arrayWithObject(
        @as(id, @ptrCast(NSArray)),
        m.sel("arrayWithObject:"),
        nsString("public.file-url"),
    );

    const registerForTypes = m.cast(*const fn (id, SEL, id) callconv(.c) void);
    registerForTypes(window, m.sel("registerForDraggedTypes:"), types_array);
}

// NSDragOperationCopy from `<AppKit/NSDragging.h>`.
const NSDragOperationNone: usize = 0;
const NSDragOperationCopy: usize = 1;

fn dragEnteredTrampoline(self_window: id, _cmd: SEL, sender: id) callconv(.c) usize {
    _ = _cmd;
    const ctx = window_registry.get(@as(*anyopaque, @ptrCast(self_window))) orelse return NSDragOperationNone;
    if (ctx.on_drag_drop == null) return NSDragOperationNone;
    // `sender` is `id<NSDraggingInfo>`. Read its pasteboard and
    // confirm a file-URL type is present.
    const pasteboard_sel = m.cast(*const fn (id, SEL) callconv(.c) id);
    const pb = pasteboard_sel(sender, m.sel("draggingPasteboard"));
    if (@intFromPtr(pb) == 0) return NSDragOperationNone;
    // `[NSPasteboard.types containsObject:@"public.file-url"]`
    const types_method = m.cast(*const fn (id, SEL) callconv(.c) id);
    const types = types_method(pb, m.sel("types"));
    if (@intFromPtr(types) == 0) return NSDragOperationNone;
    const containsObject = m.cast(*const fn (id, SEL, id) callconv(.c) bool);
    if (!containsObject(types, m.sel("containsObject:"), nsString("public.file-url"))) return NSDragOperationNone;
    return NSDragOperationCopy;
}

fn dragPerformTrampoline(self_window: id, _cmd: SEL, sender: id) callconv(.c) bool {
    _ = _cmd;
    const ctx = window_registry.get(@as(*anyopaque, @ptrCast(self_window))) orelse return false;
    const cb = ctx.on_drag_drop orelse return false;

    const pasteboard_sel = m.cast(*const fn (id, SEL) callconv(.c) id);
    const pb = pasteboard_sel(sender, m.sel("draggingPasteboard"));
    if (@intFromPtr(pb) == 0) return false;

    // `[NSPasteboard readObjectsForClasses:@[NSURL.class] options:nil]`
    // returns an NSArray<NSURL*>. Walk it, extract UTF-8 paths.
    const NSURL = m.getClass("NSURL");
    const NSArray = m.getClass("NSArray");
    const arrayWithObject = m.cast(*const fn (id, SEL, id) callconv(.c) id);
    const classes = arrayWithObject(@as(id, @ptrCast(NSArray)), m.sel("arrayWithObject:"), @as(id, @ptrCast(NSURL)));

    const readObjects = m.cast(*const fn (id, SEL, id, ?id) callconv(.c) id);
    const urls = readObjects(pb, m.sel("readObjectsForClasses:options:"), classes, null);
    if (@intFromPtr(urls) == 0) return false;

    const count_sel = m.cast(*const fn (id, SEL) callconv(.c) usize);
    const n = count_sel(urls, m.sel("count"));
    if (n == 0) return false;

    // Build a temporary slice of UTF-8 paths. We use the page
    // allocator for the throw-away storage — the slice only lives
    // until `cb` returns.
    var gpa = std.heap.page_allocator;
    var paths_buf = gpa.alloc([]const u8, n) catch return false;
    defer gpa.free(paths_buf);

    const objectAtIndex = m.cast(*const fn (id, SEL, usize) callconv(.c) id);
    const path_sel = m.cast(*const fn (id, SEL) callconv(.c) id);
    const utf8 = m.cast(*const fn (id, SEL) callconv(.c) ?[*:0]const u8);

    var owned: usize = 0;
    defer {
        var i: usize = 0;
        while (i < owned) : (i += 1) gpa.free(paths_buf[i]);
    }

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const url = objectAtIndex(urls, m.sel("objectAtIndex:"), i);
        const path_ns = path_sel(url, m.sel("path"));
        if (@intFromPtr(path_ns) == 0) {
            paths_buf[i] = "";
            continue;
        }
        const cstr = utf8(path_ns, m.sel("UTF8String")) orelse {
            paths_buf[i] = "";
            continue;
        };
        const slice = std.mem.span(cstr);
        const owned_copy = gpa.dupe(u8, slice) catch {
            paths_buf[i] = "";
            continue;
        };
        paths_buf[i] = owned_copy;
        owned += 1;
    }

    cb(ctx.on_drag_drop_ctx, paths_buf);
    return true;
}

/// Lazily install the `NSAppleEventManager` URL handler for
/// `kInternetEventClass`/`kAEGetURL` (both 'GURL' FourCharCodes
/// historically — see Apple's URL Schemes / Launch Services docs).
/// Subsequent calls are no-ops; only `last_url_handler_ctx` rotates so
/// the trampoline knows which window's callback to fire. Cocoa queues
/// any URL events that arrived before the AEH installed, then drains
/// them on the next run-loop spin — so a cold-launch URL clicked from
/// the Finder before `Window.init` even ran still reaches the handler.
fn installUrlOpenerIfNeeded(ctx: *WindowCtx) void {
    last_url_handler_ctx = ctx;
    if (url_opener_singleton != null) return;

    const NSObject = m.getClass("NSObject");
    const klass = url_opener_class_cached orelse blk: {
        const c = m.allocateClass(NSObject, "VerveUrlOpener");
        m.addMethod(c, m.sel("getUrl:withReplyEvent:"), @ptrCast(&urlOpenTrampoline), "v@:@@");
        m.registerClass(c);
        url_opener_class_cached = c;
        break :blk c;
    };
    const alloc_id = m.cast(*const fn (id, SEL) callconv(.c) id);
    const init_id = m.cast(*const fn (id, SEL) callconv(.c) id);
    const opener = init_id(alloc_id(@as(id, @ptrCast(klass)), m.sel("alloc")), m.sel("init"));

    const NSAppleEventManager = m.getClass("NSAppleEventManager");
    const sharedManager = m.cast(*const fn (id, SEL) callconv(.c) id);
    const manager = sharedManager(@as(id, @ptrCast(NSAppleEventManager)), m.sel("sharedAppleEventManager"));

    // FourCharCode 'GURL' = 0x4755524C. Apple's `kInternetEventClass`
    // and `kAEGetURL` constants both expand to this same code.
    const four_cc: u32 = 0x4755524C;
    const setEventHandler = m.cast(*const fn (id, SEL, id, SEL, u32, u32) callconv(.c) void);
    setEventHandler(
        manager,
        m.sel("setEventHandler:andSelector:forEventClass:andEventID:"),
        opener,
        m.sel("getUrl:withReplyEvent:"),
        four_cc,
        four_cc,
    );
    url_opener_singleton = opener;
    std.log.debug("verve.desktop[macos]: AppleEventManager URL handler installed", .{});
}

/// AEH trampoline. The event's direct-object parameter (keyword
/// `'----'` = `keyDirectObject` = 0x2D2D2D2D) holds the URL as an
/// NSAppleEventDescriptor; `stringValue` yields the NSString form.
fn urlOpenTrampoline(self: id, _cmd: SEL, event: id, reply: id) callconv(.c) void {
    _ = self;
    _ = _cmd;
    _ = reply;

    const key_direct_object: u32 = 0x2D2D2D2D; // '----'
    const paramSel = m.cast(*const fn (id, SEL, u32) callconv(.c) ?id);
    const descriptor = paramSel(event, m.sel("paramDescriptorForKeyword:"), key_direct_object) orelse return;
    const stringValue = m.cast(*const fn (id, SEL) callconv(.c) ?id);
    const ns_str = stringValue(descriptor, m.sel("stringValue")) orelse return;
    const utf8 = m.cast(*const fn (id, SEL) callconv(.c) ?[*:0]const u8);
    const cstr = utf8(ns_str, m.sel("UTF8String")) orelse return;
    const url = std.mem.span(cstr);

    const ctx = last_url_handler_ctx orelse return;
    if (ctx.on_url_open) |cb| cb(ctx.on_url_open_ctx, url);
}

fn handleSchemeStart(ctx_ptr: *WindowCtx, task: id) !void {
    const requestSel = m.cast(*const fn (id, SEL) callconv(.c) id);
    const req = requestSel(task, m.sel("request"));
    const URL = m.cast(*const fn (id, SEL) callconv(.c) id);
    const url = URL(req, m.sel("URL"));
    const pathSel = m.cast(*const fn (id, SEL) callconv(.c) id);
    const ns_path = pathSel(url, m.sel("path"));
    const utf8 = m.cast(*const fn (id, SEL) callconv(.c) [*:0]const u8);
    const path_cstr = utf8(ns_path, m.sel("UTF8String"));
    const path_len = std.mem.len(path_cstr);
    const path_slice = path_cstr[0..path_len];
    std.log.debug("verve.desktop[macos]: scheme '{s}'", .{path_slice});

    const resolved = if (ctx_ptr.dev_assets) |dev|
        router.resolveWithFallback(ctx_ptr.allocator, dev.io, ctx_ptr.assets, path_slice, dev.dir) catch |err| {
            std.log.warn("verve.desktop[macos]: scheme miss '{s}' ({s})", .{ path_slice, @errorName(err) });
            sendError(task, err);
            return;
        }
    else
        router.resolve(ctx_ptr.assets, path_slice) catch |err| {
            std.log.warn("verve.desktop[macos]: scheme miss '{s}' ({s})", .{ path_slice, @errorName(err) });
            sendError(task, err);
            return;
        };
    defer resolved.deinit(ctx_ptr.allocator);
    if (resolved.owned) {
        std.log.debug("verve.desktop[macos]: scheme '{s}' served from dev fallback ({d} B)", .{ path_slice, resolved.bytes.len });
    }

    const NSURLResponse = m.getClass("NSHTTPURLResponse");
    const ns_alloc = m.cast(*const fn (id, SEL) callconv(.c) id);
    const headers = makeHeaderDict(resolved.content_type, resolved.bytes.len);
    const initResp = m.cast(*const fn (id, SEL, id, isize, id, id) callconv(.c) id);
    const resp_raw = ns_alloc(@as(id, @ptrCast(NSURLResponse)), m.sel("alloc"));
    const resp = initResp(resp_raw, m.sel("initWithURL:statusCode:HTTPVersion:headerFields:"), url, 200, nsString("HTTP/1.1"), headers);

    const didReceiveResponse = m.cast(*const fn (id, SEL, id) callconv(.c) void);
    didReceiveResponse(task, m.sel("didReceiveResponse:"), resp);

    const NSData = m.getClass("NSData");
    const dataWithBytes = m.cast(*const fn (id, SEL, [*]const u8, usize) callconv(.c) id);
    const data = dataWithBytes(@as(id, @ptrCast(NSData)), m.sel("dataWithBytes:length:"), resolved.bytes.ptr, resolved.bytes.len);

    const didReceiveData = m.cast(*const fn (id, SEL, id) callconv(.c) void);
    didReceiveData(task, m.sel("didReceiveData:"), data);

    const didFinish = m.cast(*const fn (id, SEL) callconv(.c) void);
    didFinish(task, m.sel("didFinish"));
}

fn sendError(task: id, _: anyerror) void {
    const NSError = m.getClass("NSError");
    const errorWithDomain = m.cast(*const fn (id, SEL, id, isize, ?id) callconv(.c) id);
    const ns_err = errorWithDomain(@as(id, @ptrCast(NSError)), m.sel("errorWithDomain:code:userInfo:"), nsString("VerveScheme"), 404, null);
    const didFail = m.cast(*const fn (id, SEL, id) callconv(.c) void);
    didFail(task, m.sel("didFailWithError:"), ns_err);
}

fn appShouldTerminateOnLastWindowClosed(_: id, _: SEL, _: id) callconv(.c) bool {
    return true;
}

/// Install the standard Cocoa menu bar so Cmd+Q quits the app, Cmd+W
/// closes the active window, and the WebView's clipboard shortcuts
/// (Cmd+X/C/V, Cmd+Z, Cmd+A) reach `NSResponder`. Without a main menu,
/// none of these key equivalents are honored — Cocoa specifically gates
/// them on the menu item existing.
fn installDefaultMenuBar(app: id) void {
    const NSMenu = m.getClass("NSMenu");
    const NSMenuItem = m.getClass("NSMenuItem");
    const alloc_id = m.cast(*const fn (id, SEL) callconv(.c) id);
    const init_id = m.cast(*const fn (id, SEL) callconv(.c) id);
    const init_title = m.cast(*const fn (id, SEL, id) callconv(.c) id);
    const init_action = m.cast(*const fn (id, SEL, id, SEL, id) callconv(.c) id);
    const add_item = m.cast(*const fn (id, SEL, id) callconv(.c) void);
    const set_submenu = m.cast(*const fn (id, SEL, id) callconv(.c) void);
    const set_main = m.cast(*const fn (id, SEL, id) callconv(.c) void);
    const separator_item = m.cast(*const fn (id, SEL) callconv(.c) id);

    const main_menu = init_id(alloc_id(@as(id, @ptrCast(NSMenu)), m.sel("alloc")), m.sel("init"));

    // ---- App menu (Quit) ---------------------------------------------------
    const app_menu_item = init_id(alloc_id(@as(id, @ptrCast(NSMenuItem)), m.sel("alloc")), m.sel("init"));
    add_item(main_menu, m.sel("addItem:"), app_menu_item);
    const app_menu = init_title(alloc_id(@as(id, @ptrCast(NSMenu)), m.sel("alloc")), m.sel("initWithTitle:"), nsString("Verve"));
    set_submenu(app_menu_item, m.sel("setSubmenu:"), app_menu);

    const quit_item = init_action(
        alloc_id(@as(id, @ptrCast(NSMenuItem)), m.sel("alloc")),
        m.sel("initWithTitle:action:keyEquivalent:"),
        nsString("Quit"),
        m.sel("terminate:"),
        nsString("q"),
    );
    add_item(app_menu, m.sel("addItem:"), quit_item);

    // ---- Edit menu (clipboard + undo) --------------------------------------
    const edit_item = init_id(alloc_id(@as(id, @ptrCast(NSMenuItem)), m.sel("alloc")), m.sel("init"));
    add_item(main_menu, m.sel("addItem:"), edit_item);
    const edit_menu = init_title(alloc_id(@as(id, @ptrCast(NSMenu)), m.sel("alloc")), m.sel("initWithTitle:"), nsString("Edit"));
    set_submenu(edit_item, m.sel("setSubmenu:"), edit_menu);

    addEditItem(edit_menu, "Undo", "undo:", "z");
    addEditItem(edit_menu, "Redo", "redo:", "Z");
    add_item(edit_menu, m.sel("addItem:"), separator_item(@as(id, @ptrCast(NSMenuItem)), m.sel("separatorItem")));
    addEditItem(edit_menu, "Cut", "cut:", "x");
    addEditItem(edit_menu, "Copy", "copy:", "c");
    addEditItem(edit_menu, "Paste", "paste:", "v");
    addEditItem(edit_menu, "Select All", "selectAll:", "a");

    // ---- Window menu (Close + Minimize, auto-populates app windows) -------
    const window_item = init_id(alloc_id(@as(id, @ptrCast(NSMenuItem)), m.sel("alloc")), m.sel("init"));
    add_item(main_menu, m.sel("addItem:"), window_item);
    const window_menu = init_title(alloc_id(@as(id, @ptrCast(NSMenu)), m.sel("alloc")), m.sel("initWithTitle:"), nsString("Window"));
    set_submenu(window_item, m.sel("setSubmenu:"), window_menu);
    addEditItem(window_menu, "Minimize", "performMiniaturize:", "m");
    addEditItem(window_menu, "Close", "performClose:", "w");
    const set_windows_menu = m.cast(*const fn (id, SEL, id) callconv(.c) void);
    set_windows_menu(app, m.sel("setWindowsMenu:"), window_menu);

    set_main(app, m.sel("setMainMenu:"), main_menu);
}

fn addEditItem(menu: id, title: []const u8, selector: [*:0]const u8, key: []const u8) void {
    const NSMenuItem = m.getClass("NSMenuItem");
    const init_action = m.cast(*const fn (id, SEL, id, SEL, id) callconv(.c) id);
    const alloc_id = m.cast(*const fn (id, SEL) callconv(.c) id);
    const add_item = m.cast(*const fn (id, SEL, id) callconv(.c) void);
    const item = init_action(
        alloc_id(@as(id, @ptrCast(NSMenuItem)), m.sel("alloc")),
        m.sel("initWithTitle:action:keyEquivalent:"),
        nsString(title),
        m.sel(selector),
        nsString(key),
    );
    add_item(menu, m.sel("addItem:"), item);
}

fn handleScriptMessage(ctx_ptr: *WindowCtx, message: id) void {
    const body = m.cast(*const fn (id, SEL) callconv(.c) id)(message, m.sel("body"));
    if (@intFromPtr(body) == 0) return;

    // Body may be an NSString or NSDictionary. We only forward strings;
    // dictionaries are JSON-encoded first.
    const NSString = m.getClass("NSString");
    const isKind = m.cast(*const fn (id, SEL, id) callconv(.c) bool);
    if (isKind(body, m.sel("isKindOfClass:"), @as(id, @ptrCast(NSString)))) {
        const utf8 = m.cast(*const fn (id, SEL) callconv(.c) [*:0]const u8);
        const cstr = utf8(body, m.sel("UTF8String"));
        const len = std.mem.len(cstr);
        if (ctx_ptr.on_message) |handler| handler(ctx_ptr.on_message_ctx, cstr[0..len]);
    }
}

// ----- NS helpers ------------------------------------------------------------

const NSPoint = extern struct { x: f64, y: f64 };
const NSSize = extern struct { width: f64, height: f64 };
const NSRect = extern struct { origin: NSPoint, size: NSSize };

fn nsString(s: []const u8) id {
    const NSString = m.getClass("NSString");
    const stringWithUTF8 = m.cast(*const fn (id, SEL, [*]const u8) callconv(.c) id);
    // NSString expects a NUL-terminated buffer; copy into a stack buf
    // up to a safe size, else heap-allocate. Path strings from the
    // framework rarely exceed 4 KB.
    if (s.len < 4096) {
        var buf: [4097]u8 = undefined;
        @memcpy(buf[0..s.len], s);
        buf[s.len] = 0;
        return stringWithUTF8(@as(id, @ptrCast(NSString)), m.sel("stringWithUTF8String:"), &buf);
    }
    const gpa = std.heap.page_allocator;
    const z = gpa.allocSentinel(u8, s.len, 0) catch @panic("nsString OOM");
    defer gpa.free(z);
    @memcpy(z[0..s.len], s);
    return stringWithUTF8(@as(id, @ptrCast(NSString)), m.sel("stringWithUTF8String:"), z.ptr);
}

fn nsNumberBool(value: bool) id {
    const NSNumber = m.getClass("NSNumber");
    const numberWithBool = m.cast(*const fn (id, SEL, bool) callconv(.c) id);
    return numberWithBool(@as(id, @ptrCast(NSNumber)), m.sel("numberWithBool:"), value);
}

fn copyFilePath(allocator: std.mem.Allocator, url: id) opts_mod.DialogError![]u8 {
    if (@intFromPtr(url) == 0) return opts_mod.DialogError.Cancelled;
    const pathSel = m.cast(*const fn (id, SEL) callconv(.c) id);
    const ns_path = pathSel(url, m.sel("path"));
    if (@intFromPtr(ns_path) == 0) return opts_mod.DialogError.Cancelled;
    const utf8 = m.cast(*const fn (id, SEL) callconv(.c) [*:0]const u8);
    const c_path = utf8(ns_path, m.sel("UTF8String"));
    const len = std.mem.len(c_path);
    return allocator.dupe(u8, c_path[0..len]) catch opts_mod.DialogError.OutOfMemory;
}

fn applyAllowedExtensions(panel: id, exts: []const []const u8) void {
    if (exts.len == 0) return;
    // NSOpenPanel's `allowedFileTypes` was deprecated in macOS 12 in
    // favor of `allowedContentTypes` (UTType). The legacy property
    // still works through macOS 14; using it keeps the surface tiny
    // and avoids the UniformTypeIdentifiers framework dependency.
    const NSMutableArray = m.getClass("NSMutableArray");
    const arr_alloc = m.cast(*const fn (id, SEL) callconv(.c) id);
    const arr_init = m.cast(*const fn (id, SEL) callconv(.c) id);
    const arr = arr_init(arr_alloc(@as(id, @ptrCast(NSMutableArray)), m.sel("alloc")), m.sel("init"));
    const add = m.cast(*const fn (id, SEL, id) callconv(.c) void);
    for (exts) |e| add(arr, m.sel("addObject:"), nsString(e));
    const setExts = m.cast(*const fn (id, SEL, id) callconv(.c) void);
    setExts(panel, m.sel("setAllowedFileTypes:"), arr);
}

fn makeHeaderDict(content_type: []const u8, length: usize) id {
    const NSDictionary = m.getClass("NSDictionary");
    var len_buf: [32]u8 = undefined;
    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{length}) catch "0";

    var keys = [_]id{
        nsString("Content-Type"),
        nsString("Content-Length"),
        nsString("Cross-Origin-Resource-Policy"),
        nsString("Cache-Control"),
    };
    var vals = [_]id{
        nsString(content_type),
        nsString(len_str),
        nsString("same-origin"),
        nsString("no-store"),
    };

    const dictWithObjects = m.cast(*const fn (id, SEL, [*]const id, [*]const id, usize) callconv(.c) id);
    return dictWithObjects(@as(id, @ptrCast(NSDictionary)), m.sel("dictionaryWithObjects:forKeys:count:"), &vals, &keys, 4);
}

// ----- Cookie store ----------------------------------------------------------
//
// WKHTTPCookieStore lives on `webview.configuration.websiteDataStore`.
// Its APIs (getAllCookies:, setCookie:completionHandler:,
// deleteCookie:completionHandler:) are all async — completion handlers
// are Objective-C blocks delivered on the main thread. To present a
// blocking Zig API we use two pieces of plumbing:
//
//   1. NSBlock impostor — a Zig extern struct laid out identically to
//      the Objective-C block ABI so we can construct blocks without
//      `__block` syntax. Captured fields follow the standard
//      isa/flags/reserved/invoke/descriptor header.
//   2. Nested run-loop pump — we spin `[NSRunLoop currentRunLoop]
//      runMode:beforeDate:` until the completion block toggles a
//      `done` bool. This is the documented pattern for sync-wrapping
//      main-thread-async APIs. Trade-off: the nested loop processes
//      other input sources, so the calling context must be re-entrant
//      safe. Cookie calls from IPC handlers are fine; from inside
//      another modal run loop, less so.

extern const _NSConcreteStackBlock: anyopaque;

const BlockDescriptor = extern struct {
    reserved: c_ulong = 0,
    size: c_ulong,
};

const get_all_block_desc: BlockDescriptor = .{ .size = @sizeOf(GetAllBlock) };
const void_block_desc: BlockDescriptor = .{ .size = @sizeOf(VoidBlock) };
const snapshot_block_desc: BlockDescriptor = .{ .size = @sizeOf(SnapshotBlock) };

const GetAllBlock = extern struct {
    isa: *const anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const fn (*GetAllBlock, id) callconv(.c) void,
    descriptor: *const BlockDescriptor,
    // captured:
    out_array: *?id,
    done: *bool,
};

const VoidBlock = extern struct {
    isa: *const anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const fn (*VoidBlock) callconv(.c) void,
    descriptor: *const BlockDescriptor,
    // captured:
    done: *bool,
};

fn getAllBlockInvoke(block: *GetAllBlock, cookies_arr: id) callconv(.c) void {
    // Retain the array so it outlives the block's stack frame.
    const retain = m.cast(*const fn (id, SEL) callconv(.c) id);
    block.out_array.* = retain(cookies_arr, m.sel("retain"));
    block.done.* = true;
}

fn voidBlockInvoke(block: *VoidBlock) callconv(.c) void {
    block.done.* = true;
}

/// Completion block for `WKWebView.takeSnapshotWithConfiguration:completionHandler:`.
/// Two-arg signature: (NSImage*, NSError*). We retain the NSImage so
/// it outlives the block frame; error is ignored — the caller infers
/// failure from `out_image == null`.
const SnapshotBlock = extern struct {
    isa: *const anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const fn (*SnapshotBlock, id, ?id) callconv(.c) void,
    descriptor: *const BlockDescriptor,
    out_image: *?id,
    done: *bool,
};

fn snapshotBlockInvoke(block: *SnapshotBlock, image: id, err: ?id) callconv(.c) void {
    _ = err;
    const retain = m.cast(*const fn (id, SEL) callconv(.c) id);
    if (@intFromPtr(image) != 0) {
        block.out_image.* = retain(image, m.sel("retain"));
    }
    block.done.* = true;
}

fn pumpUntilDone(done: *const bool) void {
    const NSRunLoop = m.getClass("NSRunLoop");
    const NSDate = m.getClass("NSDate");
    const currentRunLoop = m.cast(*const fn (id, SEL) callconv(.c) id);
    const distantFuture = m.cast(*const fn (id, SEL) callconv(.c) id);
    const runMode = m.cast(*const fn (id, SEL, id, id) callconv(.c) bool);

    const mode_str = nsString("kCFRunLoopDefaultMode");
    while (!done.*) {
        const rl = currentRunLoop(@as(id, @ptrCast(NSRunLoop)), m.sel("currentRunLoop"));
        const date = distantFuture(@as(id, @ptrCast(NSDate)), m.sel("distantFuture"));
        _ = runMode(rl, m.sel("runMode:beforeDate:"), mode_str, date);
    }
}

fn cookieStoreFromWindow(window: *anyopaque) id {
    const win: *Window = @ptrCast(@alignCast(window));
    const dataStore = m.cast(*const fn (id, SEL) callconv(.c) id)(win.config, m.sel("websiteDataStore"));
    return m.cast(*const fn (id, SEL) callconv(.c) id)(dataStore, m.sel("httpCookieStore"));
}

/// Block-on-completion wrapper around `[cookieStore getAllCookies:^...]`.
/// Returns a retained NSArray<NSHTTPCookie*>; caller must `release`.
fn fetchAllCookies(cookieStore: id) ?id {
    var result: ?id = null;
    var done = false;
    var block: GetAllBlock = .{
        .isa = &_NSConcreteStackBlock,
        .flags = 0,
        .reserved = 0,
        .invoke = &getAllBlockInvoke,
        .descriptor = &get_all_block_desc,
        .out_array = &result,
        .done = &done,
    };
    const getAll = m.cast(*const fn (id, SEL, *GetAllBlock) callconv(.c) void);
    getAll(cookieStore, m.sel("getAllCookies:"), &block);
    pumpUntilDone(&done);
    return result;
}

/// Run `[cookieStore <selector>:cookie completionHandler:^()]` to
/// completion. `selector` is "setCookie:completionHandler:" or
/// "deleteCookie:completionHandler:".
fn cookieMutate(cookieStore: id, selector: [*:0]const u8, cookie: id) void {
    var done = false;
    var block: VoidBlock = .{
        .isa = &_NSConcreteStackBlock,
        .flags = 0,
        .reserved = 0,
        .invoke = &voidBlockInvoke,
        .descriptor = &void_block_desc,
        .done = &done,
    };
    const call = m.cast(*const fn (id, SEL, id, *VoidBlock) callconv(.c) void);
    call(cookieStore, m.sel(selector), cookie, &block);
    pumpUntilDone(&done);
}

fn nsStringToOwned(allocator: std.mem.Allocator, ns_str: id) opts_mod.CookieError![]u8 {
    const utf8 = m.cast(*const fn (id, SEL) callconv(.c) [*:0]const u8);
    const cstr = utf8(ns_str, m.sel("UTF8String"));
    const len = std.mem.len(cstr);
    return allocator.dupe(u8, cstr[0..len]) catch return opts_mod.CookieError.OutOfMemory;
}

fn marshalCookie(allocator: std.mem.Allocator, ns_cookie: id) opts_mod.CookieError!opts_mod.Cookie {
    const getStr = m.cast(*const fn (id, SEL) callconv(.c) id);
    const getBool = m.cast(*const fn (id, SEL) callconv(.c) bool);
    const getDate = m.cast(*const fn (id, SEL) callconv(.c) ?id);

    const ns_name = getStr(ns_cookie, m.sel("name"));
    const ns_value = getStr(ns_cookie, m.sel("value"));
    const ns_domain = getStr(ns_cookie, m.sel("domain"));
    const ns_path = getStr(ns_cookie, m.sel("path"));

    var out: opts_mod.Cookie = .{
        .name = try nsStringToOwned(allocator, ns_name),
        .value = try nsStringToOwned(allocator, ns_value),
        .domain = try nsStringToOwned(allocator, ns_domain),
        .path = try nsStringToOwned(allocator, ns_path),
        .secure = getBool(ns_cookie, m.sel("isSecure")),
        .http_only = getBool(ns_cookie, m.sel("isHTTPOnly")),
    };

    if (getDate(ns_cookie, m.sel("expiresDate"))) |date| {
        const tiSince1970 = m.cast(*const fn (id, SEL) callconv(.c) f64);
        out.expires_unix = @intFromFloat(tiSince1970(date, m.sel("timeIntervalSince1970")));
    }

    // sameSitePolicy is macOS 10.15+. Returns NSString or nil.
    const same_site_ns = getStr(ns_cookie, m.sel("sameSitePolicy"));
    if (@intFromPtr(same_site_ns) != 0) {
        const ns_to_cstr = m.cast(*const fn (id, SEL) callconv(.c) [*:0]const u8);
        const policy_cstr = ns_to_cstr(same_site_ns, m.sel("UTF8String"));
        const policy = std.mem.span(policy_cstr);
        // Apple normalises to lowercase ("lax"/"strict"/"none").
        if (std.ascii.eqlIgnoreCase(policy, "lax")) out.same_site = .lax;
        if (std.ascii.eqlIgnoreCase(policy, "strict")) out.same_site = .strict;
        if (std.ascii.eqlIgnoreCase(policy, "none")) out.same_site = .none;
    }

    return out;
}

/// Build a transient NSHTTPCookie from a Cookie record via
/// `+cookieWithProperties:`. Returned cookie is autoreleased.
fn buildNsCookie(cookie: opts_mod.Cookie) ?id {
    const NSMutableDictionary = m.getClass("NSMutableDictionary");
    const dictAlloc = m.cast(*const fn (id, SEL) callconv(.c) id);
    const dictInit = m.cast(*const fn (id, SEL) callconv(.c) id);
    const dict = dictInit(dictAlloc(@as(id, @ptrCast(NSMutableDictionary)), m.sel("alloc")), m.sel("init"));

    const setObj = m.cast(*const fn (id, SEL, id, id) callconv(.c) void);
    setObj(dict, m.sel("setObject:forKey:"), nsString(cookie.name), nsString("Name"));
    setObj(dict, m.sel("setObject:forKey:"), nsString(cookie.value), nsString("Value"));
    const domain = if (cookie.domain.len > 0) cookie.domain else "";
    setObj(dict, m.sel("setObject:forKey:"), nsString(domain), nsString("Domain"));
    const path = if (cookie.path.len > 0) cookie.path else "/";
    setObj(dict, m.sel("setObject:forKey:"), nsString(path), nsString("Path"));

    if (cookie.secure) {
        setObj(dict, m.sel("setObject:forKey:"), nsString("TRUE"), nsString("Secure"));
    }
    if (cookie.http_only) {
        setObj(dict, m.sel("setObject:forKey:"), nsString("TRUE"), nsString("HTTPOnly"));
    }
    if (cookie.expires_unix > 0) {
        const NSDate = m.getClass("NSDate");
        const dateAt = m.cast(*const fn (id, SEL, f64) callconv(.c) id);
        const date = dateAt(@as(id, @ptrCast(NSDate)), m.sel("dateWithTimeIntervalSince1970:"), @floatFromInt(cookie.expires_unix));
        setObj(dict, m.sel("setObject:forKey:"), date, nsString("Expires"));
    }
    switch (cookie.same_site) {
        .default => {},
        .lax => setObj(dict, m.sel("setObject:forKey:"), nsString("lax"), nsString("SameSitePolicy")),
        .strict => setObj(dict, m.sel("setObject:forKey:"), nsString("strict"), nsString("SameSitePolicy")),
        .none => setObj(dict, m.sel("setObject:forKey:"), nsString("none"), nsString("SameSitePolicy")),
    }

    const NSHTTPCookie = m.getClass("NSHTTPCookie");
    const cookieWith = m.cast(*const fn (id, SEL, id) callconv(.c) ?id);
    return cookieWith(@as(id, @ptrCast(NSHTTPCookie)), m.sel("cookieWithProperties:"), dict);
}

fn nsStringEquals(ns: id, want: []const u8) bool {
    const utf8 = m.cast(*const fn (id, SEL) callconv(.c) [*:0]const u8);
    const cstr = utf8(ns, m.sel("UTF8String"));
    const len = std.mem.len(cstr);
    return std.mem.eql(u8, cstr[0..len], want);
}

pub fn cookieGet(window: *anyopaque, allocator: std.mem.Allocator, name: []const u8) opts_mod.CookieError!?opts_mod.Cookie {
    const cookieStore = cookieStoreFromWindow(window);
    const arr = fetchAllCookies(cookieStore) orelse return null;
    defer {
        const release = m.cast(*const fn (id, SEL) callconv(.c) void);
        release(arr, m.sel("release"));
    }

    const countSel = m.cast(*const fn (id, SEL) callconv(.c) usize);
    const objAt = m.cast(*const fn (id, SEL, usize) callconv(.c) id);
    const getName = m.cast(*const fn (id, SEL) callconv(.c) id);
    const count = countSel(arr, m.sel("count"));

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const c = objAt(arr, m.sel("objectAtIndex:"), i);
        if (nsStringEquals(getName(c, m.sel("name")), name)) {
            return try marshalCookie(allocator, c);
        }
    }
    return null;
}

pub fn cookieSet(window: *anyopaque, cookie: opts_mod.Cookie) opts_mod.CookieError!void {
    const cookieStore = cookieStoreFromWindow(window);
    const ns_cookie = buildNsCookie(cookie) orelse return opts_mod.CookieError.Backend;
    cookieMutate(cookieStore, "setCookie:completionHandler:", ns_cookie);
}

pub fn cookieDelete(window: *anyopaque, name: []const u8) opts_mod.CookieError!void {
    const cookieStore = cookieStoreFromWindow(window);
    const arr = fetchAllCookies(cookieStore) orelse return;
    defer {
        const release = m.cast(*const fn (id, SEL) callconv(.c) void);
        release(arr, m.sel("release"));
    }

    const countSel = m.cast(*const fn (id, SEL) callconv(.c) usize);
    const objAt = m.cast(*const fn (id, SEL, usize) callconv(.c) id);
    const getName = m.cast(*const fn (id, SEL) callconv(.c) id);
    const count = countSel(arr, m.sel("count"));

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const c = objAt(arr, m.sel("objectAtIndex:"), i);
        if (nsStringEquals(getName(c, m.sel("name")), name)) {
            cookieMutate(cookieStore, "deleteCookie:completionHandler:", c);
            return;
        }
    }
}

pub fn cookieClear(window: *anyopaque) opts_mod.CookieError!void {
    const cookieStore = cookieStoreFromWindow(window);
    const arr = fetchAllCookies(cookieStore) orelse return;
    defer {
        const release = m.cast(*const fn (id, SEL) callconv(.c) void);
        release(arr, m.sel("release"));
    }

    const countSel = m.cast(*const fn (id, SEL) callconv(.c) usize);
    const objAt = m.cast(*const fn (id, SEL, usize) callconv(.c) id);
    const count = countSel(arr, m.sel("count"));

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const c = objAt(arr, m.sel("objectAtIndex:"), i);
        cookieMutate(cookieStore, "deleteCookie:completionHandler:", c);
    }
}

// ---- Clipboard --------------------------------------------------------------
//
// NSPasteboard `generalPasteboard` is the system clipboard; both
// reads and writes are synchronous on AppKit so no run-loop pump is
// needed. UTF-8 in / UTF-8 out via `NSPasteboardTypeString`.

pub fn clipboardWriteText(window: *anyopaque, text: []const u8) opts_mod.ClipboardError!void {
    _ = window;
    const NSPasteboard = m.getClass("NSPasteboard");
    const generalPasteboard = m.cast(*const fn (id, SEL) callconv(.c) id);
    const pb = generalPasteboard(@as(id, @ptrCast(NSPasteboard)), m.sel("generalPasteboard"));

    const clearContents = m.cast(*const fn (id, SEL) callconv(.c) isize);
    _ = clearContents(pb, m.sel("clearContents"));

    const setString = m.cast(*const fn (id, SEL, id, id) callconv(.c) bool);
    const ok = setString(pb, m.sel("setString:forType:"), nsString(text), nsString("public.utf8-plain-text"));
    if (!ok) return opts_mod.ClipboardError.Backend;
}

pub fn clipboardReadText(window: *anyopaque, allocator: std.mem.Allocator) opts_mod.ClipboardError!?[]u8 {
    _ = window;
    const NSPasteboard = m.getClass("NSPasteboard");
    const generalPasteboard = m.cast(*const fn (id, SEL) callconv(.c) id);
    const pb = generalPasteboard(@as(id, @ptrCast(NSPasteboard)), m.sel("generalPasteboard"));

    const stringForType = m.cast(*const fn (id, SEL, id) callconv(.c) ?id);
    const ns_str = stringForType(pb, m.sel("stringForType:"), nsString("public.utf8-plain-text")) orelse return null;

    const utf8 = m.cast(*const fn (id, SEL) callconv(.c) ?[*:0]const u8);
    const cstr = utf8(ns_str, m.sel("UTF8String")) orelse return null;
    const slice = std.mem.span(cstr);
    return allocator.dupe(u8, slice) catch return opts_mod.ClipboardError.OutOfMemory;
}
