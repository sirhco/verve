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
    on_message: ?opts_mod.MessageHandler,
    on_message_ctx: ?*anyopaque,
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

        // Register dynamic classes for the custom-scheme handler and
        // the script-message handler. Both subclass NSObject. Methods
        // are added before `objc_registerClassPair`.
        const NSObject = m.getClass("NSObject");
        const scheme_class = m.allocateClass(NSObject, "VerveSchemeHandler");
        m.addMethod(scheme_class, m.sel("webView:startURLSchemeTask:"), @ptrCast(&schemeStartTrampoline), "v@:@@");
        m.addMethod(scheme_class, m.sel("webView:stopURLSchemeTask:"), @ptrCast(&schemeStopTrampoline), "v@:@@");
        m.addProtocol(scheme_class, "WKURLSchemeHandler");
        m.registerClass(scheme_class);

        const message_class = m.allocateClass(NSObject, "VerveMessageHandler");
        m.addMethod(message_class, m.sel("userContentController:didReceiveScriptMessage:"), @ptrCast(&didReceiveTrampoline), "v@:@@");
        m.addProtocol(message_class, "WKScriptMessageHandler");
        m.registerClass(message_class);

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
            .on_message = opts.on_message,
            .on_message_ctx = opts.on_message_ctx,
            .webview = webview,
        };
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

    const resolved = router.resolve(ctx_ptr.assets, path_slice) catch |err| {
        std.log.warn("verve.desktop[macos]: scheme miss '{s}' ({s})", .{ path_slice, @errorName(err) });
        sendError(task, err);
        return;
    };

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
