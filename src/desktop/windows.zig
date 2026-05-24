//! Windows backend — Win32 HWND + Microsoft Edge WebView2.
//!
//! Symbols are declared as hand-rolled `extern` decls rather than
//! `@cImport`ing `<windows.h>` and `<WebView2.h>`. That keeps the file
//! syntactically compilable on any host (the framework's own
//! `zig build` runs on macOS CI) and avoids depending on the Windows
//! SDK being present at framework-build time. The generated desktop
//! project links the actual `WebView2Loader.dll.lib` import library at
//! its own link step, so the symbols still resolve.
//!
//! WebView2 is delivered as the "Evergreen" runtime on modern Windows;
//! Win11 ships it preinstalled, Win10 may not. We do not bundle a
//! fixed-version runtime — instead, when
//! `CreateCoreWebView2EnvironmentWithOptions` returns a failing HRESULT
//! we print the install URL and exit with code 78 (config error).
//!
//! COM call strategy. WebView2 interfaces we *consume* (Environment,
//! Controller, WebView2, EventArgs) are called through the
//! offset-based pattern: `lpVtbl` is treated as `[*]const *const anyopaque`
//! and the desired method is loaded by its documented slot index, cast
//! to the right function-pointer type, and invoked. This avoids having
//! to redeclare every one of the ~60 vtable entries from WebView2.h.
//! Interfaces we *implement* (the three completion-handler interfaces)
//! get hand-rolled extern-struct vtables — they only have four slots
//! each so the redundancy is trivial.

const std = @import("std");
const builtin = @import("builtin");
const opts_mod = @import("options.zig");
const ipc = @import("ipc.zig");
const router = @import("asset_router.zig");
const cookies_mod = @import("cookies.zig");

const WV2_INSTALL_URL = "https://developer.microsoft.com/microsoft-edge/webview2/";

// ---- Minimal Win32 surface --------------------------------------------------

const HWND = ?*opaque {};
const HINSTANCE = ?*opaque {};
const HMENU = ?*opaque {};
const HMODULE = ?*opaque {};
const HRESULT = c_long;
const LRESULT = isize;
const WPARAM = usize;
const LPARAM = isize;
const ULONG = c_ulong;
const DWORD = c_ulong;
const BOOL = c_int;
const UINT = c_uint;

const LPCWSTR = ?[*:0]const u16;
const LPWSTR = ?[*:0]u16;
const LPVOID = ?*anyopaque;

const RECT = extern struct { left: c_long, top: c_long, right: c_long, bottom: c_long };

const POINT = extern struct { x: c_long, y: c_long };

const MSG = extern struct {
    hwnd: HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
    lPrivate: DWORD,
};

const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

const IID = GUID;

const WNDCLASSW = extern struct {
    style: UINT,
    lpfnWndProc: ?*const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT,
    cbClsExtra: c_int,
    cbWndExtra: c_int,
    hInstance: HINSTANCE,
    hIcon: ?*anyopaque,
    hCursor: ?*anyopaque,
    hbrBackground: ?*anyopaque,
    lpszMenuName: LPCWSTR,
    lpszClassName: LPCWSTR,
};

const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
const CW_USEDEFAULT: c_int = @bitCast(@as(u32, 0x80000000));
const SW_SHOW: c_int = 5;
const WM_SIZE: UINT = 0x0005;
const WM_DESTROY: UINT = 0x0002;
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));

extern "kernel32" fn GetModuleHandleW(name: LPCWSTR) callconv(.winapi) HINSTANCE;
extern "user32" fn RegisterClassW(cls: *const WNDCLASSW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(
    ex_style: DWORD,
    class_name: LPCWSTR,
    window_name: LPCWSTR,
    style: DWORD,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    parent: HWND,
    menu: HMENU,
    instance: HINSTANCE,
    param: LPVOID,
) callconv(.winapi) HWND;
extern "user32" fn DefWindowProcW(hwnd: HWND, msg: UINT, w: WPARAM, l: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn ShowWindow(hwnd: HWND, cmd: c_int) callconv(.winapi) BOOL;
extern "user32" fn UpdateWindow(hwnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn GetClientRect(hwnd: HWND, rect: *RECT) callconv(.winapi) BOOL;
extern "user32" fn SetWindowTextW(hwnd: HWND, text: LPCWSTR) callconv(.winapi) BOOL;
extern "user32" fn GetMessageW(msg: *MSG, hwnd: HWND, min: UINT, max: UINT) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(msg: *const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(msg: *const MSG) callconv(.winapi) LRESULT;
extern "user32" fn PostQuitMessage(code: c_int) callconv(.winapi) void;
extern "user32" fn SendMessageW(hwnd: HWND, msg: UINT, w: WPARAM, l: LPARAM) callconv(.winapi) LRESULT;

const WM_CLOSE: UINT = 0x0010;

extern "ole32" fn CoTaskMemFree(p: LPVOID) callconv(.winapi) void;
extern "shlwapi" fn SHCreateMemStream(bytes: ?[*]const u8, size: UINT) callconv(.winapi) ?*IStream;

// IStream is opaque to us — we only hand the pointer to WebView2.
const IStream = opaque {};

// ---- WebView2 loader entry --------------------------------------------------

extern "WebView2Loader.dll" fn CreateCoreWebView2EnvironmentWithOptions(
    browser_folder: LPCWSTR,
    user_folder: LPCWSTR,
    env_options: ?*anyopaque,
    handler: *const IEnvCreatedHandler,
) callconv(.winapi) HRESULT;

// ---- COM interfaces we consume (offset-based vtable calls) ------------------

const IUnknown = extern struct {
    lpVtbl: *const anyopaque,
};

const Env = extern struct { lpVtbl: *const anyopaque };
const Ctrl = extern struct { lpVtbl: *const anyopaque };
const Wv2 = extern struct { lpVtbl: *const anyopaque };
const Wv2_2 = extern struct { lpVtbl: *const anyopaque };
const CookieMgr = extern struct { lpVtbl: *const anyopaque };
const CookieT = extern struct { lpVtbl: *const anyopaque };
const CookieList = extern struct { lpVtbl: *const anyopaque };
const ResponseT = extern struct { lpVtbl: *const anyopaque };
const RequestT = extern struct { lpVtbl: *const anyopaque };
const RequestedArgs = extern struct { lpVtbl: *const anyopaque };
const MessageArgs = extern struct { lpVtbl: *const anyopaque };

// Vtable slot indexes — must match WebView2.h. Comments cite the C++
// method name; first three slots in every COM interface are
// QueryInterface/AddRef/Release.
const SLOT_ENV_CreateController: usize = 3;
const SLOT_ENV_CreateWebResourceResponse: usize = 4;

const SLOT_CTRL_putBounds: usize = 6;
const SLOT_CTRL_getCoreWebView2: usize = 25;

const SLOT_WV2_Navigate: usize = 5;
const SLOT_WV2_NavigateToString: usize = 6;
const SLOT_WV2_AddScriptToExecuteOnDocumentCreated: usize = 27;
const SLOT_WV2_ExecuteScript: usize = 29;
const SLOT_WV2_add_WebMessageReceived: usize = 34;
const SLOT_WV2_add_WebResourceRequested: usize = 52;
const SLOT_WV2_AddWebResourceRequestedFilter: usize = 54;

const SLOT_RequestedArgs_get_Request: usize = 3;
const SLOT_RequestedArgs_put_Response: usize = 5;

const SLOT_Request_get_Uri: usize = 3;

const SLOT_MessageArgs_TryGetWebMessageAsString: usize = 5;

// ICoreWebView2_2 inherits all 58 ICoreWebView2 methods (slots 3-60),
// then adds 7 more (slots 61-67). Only get_CookieManager is consumed
// here.
const SLOT_WV2_2_get_CookieManager: usize = 66;

// ICoreWebView2CookieManager.
const SLOT_CM_CreateCookie: usize = 3;
const SLOT_CM_GetCookies: usize = 5;
const SLOT_CM_AddOrUpdateCookie: usize = 6;
const SLOT_CM_DeleteCookie: usize = 7;
const SLOT_CM_DeleteAllCookies: usize = 10;

// ICoreWebView2Cookie property accessors.
const SLOT_CK_get_Name: usize = 3;
const SLOT_CK_get_Value: usize = 4;
const SLOT_CK_get_Domain: usize = 6;
const SLOT_CK_get_Path: usize = 7;
const SLOT_CK_get_Expires: usize = 8;
const SLOT_CK_put_Expires: usize = 9;
const SLOT_CK_get_IsHttpOnly: usize = 10;
const SLOT_CK_put_IsHttpOnly: usize = 11;
const SLOT_CK_get_SameSite: usize = 12;
const SLOT_CK_put_SameSite: usize = 13;
const SLOT_CK_get_IsSecure: usize = 14;
const SLOT_CK_put_IsSecure: usize = 15;

// ICoreWebView2CookieList.
const SLOT_CL_get_Count: usize = 3;
const SLOT_CL_GetValueAtIndex: usize = 4;

// COREWEBVIEW2_COOKIE_SAME_SITE_KIND.
const COOKIE_SAME_SITE_NONE: c_int = 0;
const COOKIE_SAME_SITE_LAX: c_int = 1;
const COOKIE_SAME_SITE_STRICT: c_int = 2;

// IIDs (from WebView2 SDK).
const IID_ICoreWebView2_2: IID = .{
    .Data1 = 0x9E8F0CF8,
    .Data2 = 0xE670,
    .Data3 = 0x4B5E,
    .Data4 = .{ 0xB2, 0xBC, 0x73, 0xE0, 0x61, 0xE3, 0x18, 0x4C },
};

fn vtSlot(comptime Fn: type, lpVtbl: *const anyopaque, slot: usize) Fn {
    const arr: [*]const *const anyopaque = @ptrCast(@alignCast(lpVtbl));
    return @ptrCast(arr[slot]);
}

// ---- COM interfaces we implement (full vtable) ------------------------------

const IEnvCreatedHandlerVtbl = extern struct {
    QueryInterface: *const fn (?*const IEnvCreatedHandler, *const IID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (?*const IEnvCreatedHandler) callconv(.winapi) ULONG,
    Release: *const fn (?*const IEnvCreatedHandler) callconv(.winapi) ULONG,
    Invoke: *const fn (?*const IEnvCreatedHandler, HRESULT, ?*Env) callconv(.winapi) HRESULT,
};
const IEnvCreatedHandler = extern struct {
    lpVtbl: *const IEnvCreatedHandlerVtbl,
    ctx: *WindowCtx,
};

const ICtrlCreatedHandlerVtbl = extern struct {
    QueryInterface: *const fn (?*const ICtrlCreatedHandler, *const IID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (?*const ICtrlCreatedHandler) callconv(.winapi) ULONG,
    Release: *const fn (?*const ICtrlCreatedHandler) callconv(.winapi) ULONG,
    Invoke: *const fn (?*const ICtrlCreatedHandler, HRESULT, ?*Ctrl) callconv(.winapi) HRESULT,
};
const ICtrlCreatedHandler = extern struct {
    lpVtbl: *const ICtrlCreatedHandlerVtbl,
    ctx: *WindowCtx,
};

const IMessageReceivedHandlerVtbl = extern struct {
    QueryInterface: *const fn (?*const IMessageReceivedHandler, *const IID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (?*const IMessageReceivedHandler) callconv(.winapi) ULONG,
    Release: *const fn (?*const IMessageReceivedHandler) callconv(.winapi) ULONG,
    Invoke: *const fn (?*const IMessageReceivedHandler, ?*Wv2, ?*MessageArgs) callconv(.winapi) HRESULT,
};
const IMessageReceivedHandler = extern struct {
    lpVtbl: *const IMessageReceivedHandlerVtbl,
    ctx: *WindowCtx,
};

const IResourceRequestedHandlerVtbl = extern struct {
    QueryInterface: *const fn (?*const IResourceRequestedHandler, *const IID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (?*const IResourceRequestedHandler) callconv(.winapi) ULONG,
    Release: *const fn (?*const IResourceRequestedHandler) callconv(.winapi) ULONG,
    Invoke: *const fn (?*const IResourceRequestedHandler, ?*Wv2, ?*RequestedArgs) callconv(.winapi) HRESULT,
};
const IResourceRequestedHandler = extern struct {
    lpVtbl: *const IResourceRequestedHandlerVtbl,
    ctx: *WindowCtx,
};

fn comQI(_: ?*const IUnknown, _: *const IID, ppv: *?*anyopaque) callconv(.winapi) HRESULT {
    ppv.* = null;
    return E_NOINTERFACE;
}
fn comAddRef(_: ?*const IUnknown) callconv(.winapi) ULONG {
    return 1;
}
fn comRelease(_: ?*const IUnknown) callconv(.winapi) ULONG {
    return 1;
}

// ---- Filter for AddWebResourceRequestedFilter -------------------------------

const COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL: c_int = 0;

// ---- Per-window context + registry ------------------------------------------

/// Per-window state. Heap-allocated by `Window.init`. Each WebView2
/// COM event handler embeds a back-pointer to the WindowCtx that owns
/// it (see the four `*Handler` types below) so callbacks resolve which
/// window fired them without consulting a process-global. wndProc
/// finds the WindowCtx via the HWND registry below.
const WindowCtx = struct {
    allocator: std.mem.Allocator,
    opts: opts_mod.WindowOptions,
    on_message: ?opts_mod.MessageHandler,
    on_message_ctx: ?*anyopaque,
    hwnd: HWND = null,
    controller: ?*Ctrl = null,
    webview: ?*Wv2 = null,
    environment: ?*Env = null,
    env_handler: IEnvCreatedHandler,
    ctrl_handler: ICtrlCreatedHandler,
    msg_handler: IMessageReceivedHandler,
    res_handler: IResourceRequestedHandler,
};

/// Win32 messages dispatch through wndProc which receives the HWND
/// directly, so we key the registry by HWND. WebView2 COM callbacks
/// resolve their own ctx through the embedded back-pointer in each
/// handler struct, no registry lookup needed.
var registry: std.AutoHashMapUnmanaged(HWND, *WindowCtx) = .{};

fn registerCtx(hwnd: HWND, ctx_ptr: *WindowCtx) !void {
    try registry.put(std.heap.page_allocator, hwnd, ctx_ptr);
}

fn lookupCtx(hwnd: HWND) ?*WindowCtx {
    return registry.get(hwnd);
}

fn unregisterCtx(hwnd: HWND) void {
    _ = registry.remove(hwnd);
}

// ---- Window facade ----------------------------------------------------------

pub const Window = struct {
    ctx: *WindowCtx,

    pub fn init(allocator: std.mem.Allocator, opts: opts_mod.WindowOptions) !Window {
        const heap = try allocator.create(WindowCtx);
        errdefer allocator.destroy(heap);
        heap.* = .{
            .allocator = allocator,
            .opts = opts,
            .on_message = opts.on_message,
            .on_message_ctx = opts.on_message_ctx,
            .env_handler = .{ .lpVtbl = &env_created_handler_vtbl, .ctx = heap },
            .ctrl_handler = .{ .lpVtbl = &ctrl_created_handler_vtbl, .ctx = heap },
            .msg_handler = .{ .lpVtbl = &message_handler_vtbl, .ctx = heap },
            .res_handler = .{ .lpVtbl = &resource_handler_vtbl, .ctx = heap },
        };

        const class_name = std.unicode.utf8ToUtf16LeStringLiteral("VerveWindow");
        const hinstance = GetModuleHandleW(null);

        var wc = std.mem.zeroes(WNDCLASSW);
        wc.lpfnWndProc = &wndProc;
        wc.hInstance = hinstance;
        wc.lpszClassName = class_name;
        _ = RegisterClassW(&wc);

        var title_buf: [512]u16 = undefined;
        const title_len = try std.unicode.utf8ToUtf16Le(&title_buf, opts.title);
        title_buf[@min(title_buf.len - 1, title_len)] = 0;

        const hwnd = CreateWindowExW(
            0,
            class_name,
            @ptrCast(&title_buf),
            WS_OVERLAPPEDWINDOW,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            @intCast(opts.width),
            @intCast(opts.height),
            null,
            null,
            hinstance,
            null,
        ) orelse return error.WindowCreateFailed;
        heap.hwnd = hwnd;
        try registerCtx(hwnd, heap);
        errdefer unregisterCtx(hwnd);

        _ = ShowWindow(hwnd, SW_SHOW);
        _ = UpdateWindow(hwnd);

        std.log.info("verve.desktop[windows]: HWND created ({d}x{d})", .{ opts.width, opts.height });

        // Async — actual webview creation runs in the env/controller
        // completion handlers below.
        std.log.debug("verve.desktop[windows]: CreateCoreWebView2EnvironmentWithOptions", .{});
        const hr = CreateCoreWebView2EnvironmentWithOptions(null, null, null, &heap.env_handler);
        if (hr < 0) {
            std.log.err(
                "WebView2 runtime missing or failed (hr=0x{x:0>8}). Install Evergreen runtime: {s}",
                .{ @as(u32, @bitCast(hr)), WV2_INSTALL_URL },
            );
            return error.WebView2Missing;
        }

        return .{ .ctx = heap };
    }

    pub fn setTitle(self: *Window, title: []const u8) void {
        var buf: [512]u16 = undefined;
        const len = std.unicode.utf8ToUtf16Le(&buf, title) catch return;
        buf[@min(buf.len - 1, len)] = 0;
        _ = SetWindowTextW(self.ctx.hwnd, @ptrCast(&buf));
    }

    pub fn loadUrl(self: *Window, url: []const u8) !void {
        const wv = self.ctx.webview orelse return error.NotReady;
        var buf: [1024]u16 = undefined;
        const len = try std.unicode.utf8ToUtf16Le(&buf, url);
        buf[@min(buf.len - 1, len)] = 0;
        const Navigate = vtSlot(*const fn (*Wv2, LPCWSTR) callconv(.winapi) HRESULT, wv.lpVtbl, SLOT_WV2_Navigate);
        const hr = Navigate(wv, @ptrCast(&buf));
        if (hr < 0) return error.NavigateFailed;
    }

    pub fn loadHtml(self: *Window, html: []const u8, _: ?[]const u8) !void {
        const wv = self.ctx.webview orelse return error.NotReady;
        const w_text = try std.unicode.utf8ToUtf16LeAllocZ(self.ctx.allocator, html);
        defer self.ctx.allocator.free(w_text);
        const NavStr = vtSlot(*const fn (*Wv2, LPCWSTR) callconv(.winapi) HRESULT, wv.lpVtbl, SLOT_WV2_NavigateToString);
        const hr = NavStr(wv, w_text.ptr);
        if (hr < 0) return error.NavigateFailed;
    }

    pub fn evalJs(self: *Window, script: []const u8) void {
        const wv = self.ctx.webview orelse return;
        const w_text = std.unicode.utf8ToUtf16LeAllocZ(self.ctx.allocator, script) catch return;
        defer self.ctx.allocator.free(w_text);
        const ExecScript = vtSlot(*const fn (*Wv2, LPCWSTR, ?*anyopaque) callconv(.winapi) HRESULT, wv.lpVtbl, SLOT_WV2_ExecuteScript);
        _ = ExecScript(wv, w_text.ptr, null);
    }

    pub fn setMessageHandler(self: *Window, handler: opts_mod.MessageHandler, handler_ctx: ?*anyopaque) void {
        self.ctx.on_message = handler;
        self.ctx.on_message_ctx = handler_ctx;
    }

    /// Open a second window in the same app session. Each call mints
    /// a fresh HWND + WebView2 environment/controller; the registry
    /// keeps both windows resolvable from wndProc.
    pub fn openChildWindow(self: *Window, opts: opts_mod.WindowOptions) !Window {
        return Window.init(self.ctx.allocator, opts);
    }

    /// Per-window cookie store. ICoreWebView2CookieManager wiring is
    /// a follow-up — see module-level stubs.
    pub fn cookies(self: *Window) cookies_mod.CookieStore {
        return .{ .window = @ptrCast(self) };
    }

    pub fn run(self: *Window) void {
        _ = self;
        var msg: MSG = undefined;
        while (GetMessageW(&msg, null, 0, 0) > 0) {
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
    }

    pub fn terminate(self: *Window) void {
        _ = self;
        PostQuitMessage(0);
    }

    pub fn close(self: *Window) void {
        // Posting WM_CLOSE triggers the standard close path; the
        // default DefWindowProcW will destroy the window which fires
        // WM_DESTROY → PostQuitMessage(0). For multi-window apps the
        // wndProc will need to suppress that PostQuitMessage so only
        // the last close terminates.
        _ = SendMessageW(self.ctx.hwnd, WM_CLOSE, 0, 0);
    }

    pub fn deinit(self: *Window) void {
        unregisterCtx(self.ctx.hwnd);
        self.ctx.allocator.destroy(self.ctx);
    }

    // ---- Dialogs ------------------------------------------------------------
    // Real GetOpenFileNameW / GetSaveFileNameW / MessageBoxW wiring is
    // a follow-up; the cross-platform Window surface still exposes
    // these methods so callers can compile, then degrade gracefully at
    // runtime.

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

fn wndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    switch (msg) {
        WM_SIZE => {
            if (lookupCtx(hwnd)) |cx| if (cx.controller) |ctrl| {
                var rect: RECT = undefined;
                _ = GetClientRect(hwnd, &rect);
                const putBounds = vtSlot(*const fn (*Ctrl, RECT) callconv(.winapi) HRESULT, ctrl.lpVtbl, SLOT_CTRL_putBounds);
                _ = putBounds(ctrl, rect);
            };
            return 0;
        },
        WM_DESTROY => {
            // Multi-window quit: unregister this HWND, only post
            // WM_QUIT when the last live window destroys. Win32 has
            // no equivalent of NSApp's automatic last-window tracking
            // so the registry size IS the live-window count.
            unregisterCtx(hwnd);
            if (registry.count() == 0) PostQuitMessage(0);
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

// ---- Completion handler vtables ---------------------------------------------

// Handler vtables stay module-level (the function pointer table is
// identical across all windows). Each WindowCtx embeds an instance of
// the matching handler struct so the COM "this" pointer carries a
// back-ref to the owning ctx.

const env_created_handler_vtbl: IEnvCreatedHandlerVtbl = .{
    .QueryInterface = @ptrCast(&comQI),
    .AddRef = @ptrCast(&comAddRef),
    .Release = @ptrCast(&comRelease),
    .Invoke = &onEnvironmentReady,
};

const ctrl_created_handler_vtbl: ICtrlCreatedHandlerVtbl = .{
    .QueryInterface = @ptrCast(&comQI),
    .AddRef = @ptrCast(&comAddRef),
    .Release = @ptrCast(&comRelease),
    .Invoke = &onControllerReady,
};

const message_handler_vtbl: IMessageReceivedHandlerVtbl = .{
    .QueryInterface = @ptrCast(&comQI),
    .AddRef = @ptrCast(&comAddRef),
    .Release = @ptrCast(&comRelease),
    .Invoke = &onMessageReceived,
};

const resource_handler_vtbl: IResourceRequestedHandlerVtbl = .{
    .QueryInterface = @ptrCast(&comQI),
    .AddRef = @ptrCast(&comAddRef),
    .Release = @ptrCast(&comRelease),
    .Invoke = &onResourceRequested,
};

// ---- Async creation flow ----------------------------------------------------

fn onEnvironmentReady(this: ?*const IEnvCreatedHandler, hr: HRESULT, env: ?*Env) callconv(.winapi) HRESULT {
    if (hr < 0 or env == null) return hr;
    const self = this orelse return 0;
    const cx = self.ctx;
    cx.environment = env;
    const CreateController = vtSlot(
        *const fn (*Env, HWND, *const ICtrlCreatedHandler) callconv(.winapi) HRESULT,
        env.?.lpVtbl,
        SLOT_ENV_CreateController,
    );
    _ = CreateController(env.?, cx.hwnd, &cx.ctrl_handler);
    return 0;
}

fn onControllerReady(this: ?*const ICtrlCreatedHandler, hr: HRESULT, ctrl: ?*Ctrl) callconv(.winapi) HRESULT {
    std.log.debug("verve.desktop[windows]: controller ready (hr=0x{x:0>8})", .{@as(u32, @bitCast(hr))});
    if (hr < 0 or ctrl == null) return hr;
    const self = this orelse return 0;
    const cx = self.ctx;
    cx.controller = ctrl;

    var rect: RECT = undefined;
    _ = GetClientRect(cx.hwnd, &rect);
    const putBounds = vtSlot(*const fn (*Ctrl, RECT) callconv(.winapi) HRESULT, ctrl.?.lpVtbl, SLOT_CTRL_putBounds);
    _ = putBounds(ctrl.?, rect);

    const getCoreWebView2 = vtSlot(*const fn (*Ctrl, *?*Wv2) callconv(.winapi) HRESULT, ctrl.?.lpVtbl, SLOT_CTRL_getCoreWebView2);
    var wv: ?*Wv2 = null;
    _ = getCoreWebView2(ctrl.?, &wv);
    cx.webview = wv;
    if (wv == null) return 0;

    // Document-start shim.
    var shim_buf: [16384]u16 = undefined;
    const shim_len = std.unicode.utf8ToUtf16Le(&shim_buf, ipc.shim_js) catch return 0;
    shim_buf[@min(shim_buf.len - 1, shim_len)] = 0;
    const addScript = vtSlot(*const fn (*Wv2, LPCWSTR, ?*anyopaque) callconv(.winapi) HRESULT, wv.?.lpVtbl, SLOT_WV2_AddScriptToExecuteOnDocumentCreated);
    _ = addScript(wv.?, @ptrCast(&shim_buf), null);

    // Hook message channel.
    const addMessage = vtSlot(*const fn (*Wv2, *const IMessageReceivedHandler, *anyopaque) callconv(.winapi) HRESULT, wv.?.lpVtbl, SLOT_WV2_add_WebMessageReceived);
    var token: i64 = 0;
    _ = addMessage(wv.?, &cx.msg_handler, @ptrCast(&token));

    // Filter `<scheme>://app/*` requests.
    var filter_utf8_buf: [256]u8 = undefined;
    const filter_utf8 = std.fmt.bufPrint(&filter_utf8_buf, "{s}://app/*", .{cx.opts.scheme}) catch "verve://app/*";
    var filter_buf: [256]u16 = undefined;
    const filter_len = std.unicode.utf8ToUtf16Le(&filter_buf, filter_utf8) catch 0;
    filter_buf[@min(filter_buf.len - 1, filter_len)] = 0;
    const addFilter = vtSlot(*const fn (*Wv2, LPCWSTR, c_int) callconv(.winapi) HRESULT, wv.?.lpVtbl, SLOT_WV2_AddWebResourceRequestedFilter);
    _ = addFilter(wv.?, @ptrCast(&filter_buf), COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);

    const addResource = vtSlot(*const fn (*Wv2, *const IResourceRequestedHandler, *anyopaque) callconv(.winapi) HRESULT, wv.?.lpVtbl, SLOT_WV2_add_WebResourceRequested);
    var token2: i64 = 0;
    _ = addResource(wv.?, &cx.res_handler, @ptrCast(&token2));

    // Initial navigation.
    if (cx.opts.initial_path.len > 0) {
        const gpa = std.heap.page_allocator;
        const utf8 = std.fmt.allocPrint(gpa, "{s}://app/{s}", .{ cx.opts.scheme, cx.opts.initial_path }) catch return 0;
        defer gpa.free(utf8);
        const w_url = std.unicode.utf8ToUtf16LeAllocZ(gpa, utf8) catch return 0;
        defer gpa.free(w_url);
        const Navigate = vtSlot(*const fn (*Wv2, LPCWSTR) callconv(.winapi) HRESULT, wv.?.lpVtbl, SLOT_WV2_Navigate);
        _ = Navigate(wv.?, w_url.ptr);
    }
    return 0;
}

fn onMessageReceived(this: ?*const IMessageReceivedHandler, _: ?*Wv2, args: ?*MessageArgs) callconv(.winapi) HRESULT {
    const self = this orelse return 0;
    const cx = self.ctx;
    if (args == null) return 0;

    const tryGet = vtSlot(*const fn (*MessageArgs, *LPWSTR) callconv(.winapi) HRESULT, args.?.lpVtbl, SLOT_MessageArgs_TryGetWebMessageAsString);
    var raw: LPWSTR = null;
    _ = tryGet(args.?, &raw);
    if (raw == null) return 0;
    defer CoTaskMemFree(raw);

    var buf: [16 * 1024]u8 = undefined;
    const w_slice = std.mem.span(@as([*:0]const u16, @ptrCast(raw.?)));
    const utf8_len = std.unicode.utf16LeToUtf8(&buf, w_slice) catch return 0;
    if (cx.on_message) |handler| handler(cx.on_message_ctx, buf[0..utf8_len]);
    return 0;
}

fn onResourceRequested(this: ?*const IResourceRequestedHandler, _: ?*Wv2, args: ?*RequestedArgs) callconv(.winapi) HRESULT {
    const self = this orelse return 0;
    const cx = self.ctx;
    if (args == null) return 0;

    const getReq = vtSlot(*const fn (*RequestedArgs, *?*RequestT) callconv(.winapi) HRESULT, args.?.lpVtbl, SLOT_RequestedArgs_get_Request);
    var req: ?*RequestT = null;
    _ = getReq(args.?, &req);
    if (req == null) return 0;

    const getUri = vtSlot(*const fn (*RequestT, *LPWSTR) callconv(.winapi) HRESULT, req.?.lpVtbl, SLOT_Request_get_Uri);
    var uri: LPWSTR = null;
    _ = getUri(req.?, &uri);
    if (uri == null) return 0;
    defer CoTaskMemFree(uri);

    var uri_utf8: [2048]u8 = undefined;
    const uri_slice = std.mem.span(@as([*:0]const u16, @ptrCast(uri.?)));
    const uri_len = std.unicode.utf16LeToUtf8(&uri_utf8, uri_slice) catch return 0;
    const uri_str = uri_utf8[0..uri_len];

    const auth = "://app/";
    const start = std.mem.indexOf(u8, uri_str, auth) orelse return 0;
    const path = uri_str[start + auth.len ..];
    std.log.debug("verve.desktop[windows]: resource '{s}' → '{s}'", .{ uri_str, path });

    const env = cx.environment orelse return 0;
    const createResp = vtSlot(
        *const fn (*Env, ?*IStream, c_int, LPCWSTR, LPCWSTR, *?*ResponseT) callconv(.winapi) HRESULT,
        env.lpVtbl,
        SLOT_ENV_CreateWebResourceResponse,
    );

    var response: ?*ResponseT = null;

    const resolved = router.resolve(cx.opts.assets, path) catch {
        _ = createResp(
            env,
            null,
            404,
            std.unicode.utf8ToUtf16LeStringLiteral("Not Found"),
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            &response,
        );
        const putResp = vtSlot(*const fn (*RequestedArgs, ?*ResponseT) callconv(.winapi) HRESULT, args.?.lpVtbl, SLOT_RequestedArgs_put_Response);
        _ = putResp(args.?, response);
        return 0;
    };

    var headers_buf: [512]u8 = undefined;
    const headers_utf8 = std.fmt.bufPrint(
        &headers_buf,
        "Content-Type: {s}\r\nContent-Length: {d}\r\nCross-Origin-Resource-Policy: same-origin\r\nCache-Control: no-store",
        .{ resolved.content_type, resolved.bytes.len },
    ) catch return 0;
    var headers_w: [512]u16 = undefined;
    const h_len = std.unicode.utf8ToUtf16Le(&headers_w, headers_utf8) catch return 0;
    headers_w[@min(headers_w.len - 1, h_len)] = 0;

    const stream = SHCreateMemStream(resolved.bytes.ptr, @intCast(resolved.bytes.len));

    _ = createResp(
        env,
        stream,
        200,
        std.unicode.utf8ToUtf16LeStringLiteral("OK"),
        @ptrCast(&headers_w),
        &response,
    );
    const putResp = vtSlot(*const fn (*RequestedArgs, ?*ResponseT) callconv(.winapi) HRESULT, args.?.lpVtbl, SLOT_RequestedArgs_put_Response);
    _ = putResp(args.?, response);
    return 0;
}

// ---- Cookie store -----------------------------------------------------------
//
// ICoreWebView2CookieManager hangs off ICoreWebView2_2; obtained via
// QueryInterface from the base webview pointer. GetCookies is the only
// async call — its completion handler delivers a CookieList on the UI
// thread. We sync-wrap by spinning a nested Win32 message pump until
// the handler's `done` flag flips.
//
// Lifetime: GetCookies returns a +1 refcount on the CookieList in the
// completion handler, and each Cookie returned by GetValueAtIndex
// carries its own +1 — we Release each Cookie after marshaling and
// the list after iteration. CookieManager + Wv2_2 returned by
// QueryInterface / get_CookieManager are also +1 refs; release at end.

const IGetCookiesHandlerVtbl = extern struct {
    QueryInterface: *const fn (?*const IGetCookiesHandler, *const IID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (?*const IGetCookiesHandler) callconv(.winapi) ULONG,
    Release: *const fn (?*const IGetCookiesHandler) callconv(.winapi) ULONG,
    Invoke: *const fn (?*const IGetCookiesHandler, HRESULT, ?*CookieList) callconv(.winapi) HRESULT,
};

const IGetCookiesHandler = extern struct {
    lpVtbl: *const IGetCookiesHandlerVtbl,
    out_list: *?*CookieList,
    done: *bool,
};

fn onGetCookies(this: ?*const IGetCookiesHandler, hr: HRESULT, list: ?*CookieList) callconv(.winapi) HRESULT {
    const self = this orelse return 0;
    if (hr >= 0 and list != null) {
        // AddRef so the list outlives the callback frame.
        const AddRef = vtSlot(*const fn (*CookieList) callconv(.winapi) ULONG, list.?.lpVtbl, 1);
        _ = AddRef(list.?);
        self.out_list.* = list;
    }
    self.done.* = true;
    return 0;
}

const get_cookies_handler_vtbl: IGetCookiesHandlerVtbl = .{
    .QueryInterface = @ptrCast(&comQI),
    .AddRef = @ptrCast(&comAddRef),
    .Release = @ptrCast(&comRelease),
    .Invoke = &onGetCookies,
};

fn pumpMsgUntilDone(done: *const bool) void {
    var msg: MSG = undefined;
    while (!done.*) {
        const got = GetMessageW(&msg, null, 0, 0);
        if (got <= 0) break;
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }
}

fn releaseRef(any: *anyopaque) void {
    const ptr: *Wv2 = @ptrCast(@alignCast(any));
    const Release = vtSlot(*const fn (*Wv2) callconv(.winapi) ULONG, ptr.lpVtbl, 2);
    _ = Release(ptr);
}

fn cookieMgrFromWindow(window: *anyopaque) opts_mod.CookieError!struct { mgr: *CookieMgr, wv2_2: *Wv2_2 } {
    const win: *Window = @ptrCast(@alignCast(window));
    const wv = win.ctx.webview orelse return opts_mod.CookieError.NotReady;
    var wv2_raw: ?*anyopaque = null;
    const QI = vtSlot(*const fn (*Wv2, *const IID, *?*anyopaque) callconv(.winapi) HRESULT, wv.lpVtbl, 0);
    const hr = QI(wv, &IID_ICoreWebView2_2, &wv2_raw);
    if (hr < 0 or wv2_raw == null) return opts_mod.CookieError.Backend;
    const wv2_2: *Wv2_2 = @ptrCast(@alignCast(wv2_raw.?));
    const getCM = vtSlot(*const fn (*Wv2_2, *?*CookieMgr) callconv(.winapi) HRESULT, wv2_2.lpVtbl, SLOT_WV2_2_get_CookieManager);
    var cm: ?*CookieMgr = null;
    const hr2 = getCM(wv2_2, &cm);
    if (hr2 < 0 or cm == null) {
        releaseRef(@ptrCast(wv2_2));
        return opts_mod.CookieError.Backend;
    }
    return .{ .mgr = cm.?, .wv2_2 = wv2_2 };
}

fn fetchAllCookies(mgr: *CookieMgr) ?*CookieList {
    var out: ?*CookieList = null;
    var done = false;
    var handler: IGetCookiesHandler = .{
        .lpVtbl = &get_cookies_handler_vtbl,
        .out_list = &out,
        .done = &done,
    };
    const GetCookies = vtSlot(*const fn (*CookieMgr, LPCWSTR, *const IGetCookiesHandler) callconv(.winapi) HRESULT, mgr.lpVtbl, SLOT_CM_GetCookies);
    _ = GetCookies(mgr, null, &handler);
    pumpMsgUntilDone(&done);
    return out;
}

fn lpwstrToOwned(allocator: std.mem.Allocator, w: LPWSTR) opts_mod.CookieError![]u8 {
    if (w == null) return allocator.dupe(u8, "") catch return opts_mod.CookieError.OutOfMemory;
    const slice = std.mem.span(@as([*:0]const u16, @ptrCast(w.?)));
    return std.unicode.utf16LeToUtf8Alloc(allocator, slice) catch return opts_mod.CookieError.OutOfMemory;
}

fn cookieNameMatches(ck: *CookieT, want: []const u8) bool {
    const getName = vtSlot(*const fn (*CookieT, *LPWSTR) callconv(.winapi) HRESULT, ck.lpVtbl, SLOT_CK_get_Name);
    var raw: LPWSTR = null;
    _ = getName(ck, &raw);
    if (raw == null) return false;
    defer CoTaskMemFree(raw);
    const slice = std.mem.span(@as([*:0]const u16, @ptrCast(raw.?)));
    var buf: [512]u8 = undefined;
    const len = std.unicode.utf16LeToUtf8(&buf, slice) catch return false;
    return std.mem.eql(u8, buf[0..len], want);
}

fn marshalCookie(allocator: std.mem.Allocator, ck: *CookieT) opts_mod.CookieError!opts_mod.Cookie {
    const getStr = struct {
        fn call(c: *CookieT, slot: usize) LPWSTR {
            const f = vtSlot(*const fn (*CookieT, *LPWSTR) callconv(.winapi) HRESULT, c.lpVtbl, slot);
            var raw: LPWSTR = null;
            _ = f(c, &raw);
            return raw;
        }
    }.call;

    const name_raw = getStr(ck, SLOT_CK_get_Name);
    defer if (name_raw != null) CoTaskMemFree(name_raw);
    const value_raw = getStr(ck, SLOT_CK_get_Value);
    defer if (value_raw != null) CoTaskMemFree(value_raw);
    const domain_raw = getStr(ck, SLOT_CK_get_Domain);
    defer if (domain_raw != null) CoTaskMemFree(domain_raw);
    const path_raw = getStr(ck, SLOT_CK_get_Path);
    defer if (path_raw != null) CoTaskMemFree(path_raw);

    var out: opts_mod.Cookie = .{
        .name = try lpwstrToOwned(allocator, name_raw),
        .value = try lpwstrToOwned(allocator, value_raw),
        .domain = try lpwstrToOwned(allocator, domain_raw),
        .path = try lpwstrToOwned(allocator, path_raw),
    };

    const getBool = struct {
        fn call(c: *CookieT, slot: usize) bool {
            const f = vtSlot(*const fn (*CookieT, *BOOL) callconv(.winapi) HRESULT, c.lpVtbl, slot);
            var v: BOOL = 0;
            _ = f(c, &v);
            return v != 0;
        }
    }.call;
    out.secure = getBool(ck, SLOT_CK_get_IsSecure);
    out.http_only = getBool(ck, SLOT_CK_get_IsHttpOnly);

    const getExpires = vtSlot(*const fn (*CookieT, *f64) callconv(.winapi) HRESULT, ck.lpVtbl, SLOT_CK_get_Expires);
    var expires: f64 = -1;
    _ = getExpires(ck, &expires);
    out.expires_unix = if (expires > 0) @intFromFloat(expires) else 0;

    const getSS = vtSlot(*const fn (*CookieT, *c_int) callconv(.winapi) HRESULT, ck.lpVtbl, SLOT_CK_get_SameSite);
    var ss: c_int = 0;
    _ = getSS(ck, &ss);
    out.same_site = switch (ss) {
        COOKIE_SAME_SITE_NONE => .none,
        COOKIE_SAME_SITE_LAX => .lax,
        COOKIE_SAME_SITE_STRICT => .strict,
        else => .default,
    };

    return out;
}

fn buildNsCookie(mgr: *CookieMgr, cookie: opts_mod.Cookie, allocator: std.mem.Allocator) opts_mod.CookieError!*CookieT {
    const name_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, cookie.name) catch return opts_mod.CookieError.OutOfMemory;
    defer allocator.free(name_w);
    const value_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, cookie.value) catch return opts_mod.CookieError.OutOfMemory;
    defer allocator.free(value_w);
    const domain_src = if (cookie.domain.len > 0) cookie.domain else "";
    const domain_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, domain_src) catch return opts_mod.CookieError.OutOfMemory;
    defer allocator.free(domain_w);
    const path_src = if (cookie.path.len > 0) cookie.path else "/";
    const path_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, path_src) catch return opts_mod.CookieError.OutOfMemory;
    defer allocator.free(path_w);

    const CreateCookie = vtSlot(*const fn (*CookieMgr, LPCWSTR, LPCWSTR, LPCWSTR, LPCWSTR, *?*CookieT) callconv(.winapi) HRESULT, mgr.lpVtbl, SLOT_CM_CreateCookie);
    var out: ?*CookieT = null;
    const hr = CreateCookie(mgr, name_w.ptr, value_w.ptr, domain_w.ptr, path_w.ptr, &out);
    if (hr < 0 or out == null) return opts_mod.CookieError.Backend;
    const ck = out.?;

    if (cookie.secure) {
        const putSecure = vtSlot(*const fn (*CookieT, BOOL) callconv(.winapi) HRESULT, ck.lpVtbl, SLOT_CK_put_IsSecure);
        _ = putSecure(ck, 1);
    }
    if (cookie.http_only) {
        const putHttpOnly = vtSlot(*const fn (*CookieT, BOOL) callconv(.winapi) HRESULT, ck.lpVtbl, SLOT_CK_put_IsHttpOnly);
        _ = putHttpOnly(ck, 1);
    }
    if (cookie.expires_unix > 0) {
        const putExpires = vtSlot(*const fn (*CookieT, f64) callconv(.winapi) HRESULT, ck.lpVtbl, SLOT_CK_put_Expires);
        _ = putExpires(ck, @floatFromInt(cookie.expires_unix));
    }
    switch (cookie.same_site) {
        .default, .lax => {
            const putSS = vtSlot(*const fn (*CookieT, c_int) callconv(.winapi) HRESULT, ck.lpVtbl, SLOT_CK_put_SameSite);
            _ = putSS(ck, COOKIE_SAME_SITE_LAX);
        },
        .none => {
            const putSS = vtSlot(*const fn (*CookieT, c_int) callconv(.winapi) HRESULT, ck.lpVtbl, SLOT_CK_put_SameSite);
            _ = putSS(ck, COOKIE_SAME_SITE_NONE);
        },
        .strict => {
            const putSS = vtSlot(*const fn (*CookieT, c_int) callconv(.winapi) HRESULT, ck.lpVtbl, SLOT_CK_put_SameSite);
            _ = putSS(ck, COOKIE_SAME_SITE_STRICT);
        },
    }

    return ck;
}

pub fn cookieGet(window: *anyopaque, allocator: std.mem.Allocator, name: []const u8) opts_mod.CookieError!?opts_mod.Cookie {
    const handles = try cookieMgrFromWindow(window);
    defer releaseRef(@ptrCast(handles.mgr));
    defer releaseRef(@ptrCast(handles.wv2_2));

    const list = fetchAllCookies(handles.mgr) orelse return null;
    defer releaseRef(@ptrCast(list));

    const getCount = vtSlot(*const fn (*CookieList, *u32) callconv(.winapi) HRESULT, list.lpVtbl, SLOT_CL_get_Count);
    var count: u32 = 0;
    _ = getCount(list, &count);

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const getAt = vtSlot(*const fn (*CookieList, u32, *?*CookieT) callconv(.winapi) HRESULT, list.lpVtbl, SLOT_CL_GetValueAtIndex);
        var ck: ?*CookieT = null;
        _ = getAt(list, i, &ck);
        if (ck == null) continue;
        defer releaseRef(@ptrCast(ck.?));
        if (cookieNameMatches(ck.?, name)) {
            return try marshalCookie(allocator, ck.?);
        }
    }
    return null;
}

pub fn cookieSet(window: *anyopaque, cookie: opts_mod.Cookie) opts_mod.CookieError!void {
    const handles = try cookieMgrFromWindow(window);
    defer releaseRef(@ptrCast(handles.mgr));
    defer releaseRef(@ptrCast(handles.wv2_2));

    const win: *Window = @ptrCast(@alignCast(window));
    const ck = try buildNsCookie(handles.mgr, cookie, win.ctx.allocator);
    defer releaseRef(@ptrCast(ck));

    const AddOrUpdate = vtSlot(*const fn (*CookieMgr, *CookieT) callconv(.winapi) HRESULT, handles.mgr.lpVtbl, SLOT_CM_AddOrUpdateCookie);
    const hr = AddOrUpdate(handles.mgr, ck);
    if (hr < 0) return opts_mod.CookieError.Backend;
}

pub fn cookieDelete(window: *anyopaque, name: []const u8) opts_mod.CookieError!void {
    const handles = try cookieMgrFromWindow(window);
    defer releaseRef(@ptrCast(handles.mgr));
    defer releaseRef(@ptrCast(handles.wv2_2));

    const list = fetchAllCookies(handles.mgr) orelse return;
    defer releaseRef(@ptrCast(list));

    const getCount = vtSlot(*const fn (*CookieList, *u32) callconv(.winapi) HRESULT, list.lpVtbl, SLOT_CL_get_Count);
    var count: u32 = 0;
    _ = getCount(list, &count);

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const getAt = vtSlot(*const fn (*CookieList, u32, *?*CookieT) callconv(.winapi) HRESULT, list.lpVtbl, SLOT_CL_GetValueAtIndex);
        var ck: ?*CookieT = null;
        _ = getAt(list, i, &ck);
        if (ck == null) continue;
        defer releaseRef(@ptrCast(ck.?));
        if (cookieNameMatches(ck.?, name)) {
            const Delete = vtSlot(*const fn (*CookieMgr, *CookieT) callconv(.winapi) HRESULT, handles.mgr.lpVtbl, SLOT_CM_DeleteCookie);
            _ = Delete(handles.mgr, ck.?);
            return;
        }
    }
}

pub fn cookieClear(window: *anyopaque) opts_mod.CookieError!void {
    const handles = try cookieMgrFromWindow(window);
    defer releaseRef(@ptrCast(handles.mgr));
    defer releaseRef(@ptrCast(handles.wv2_2));

    const DeleteAll = vtSlot(*const fn (*CookieMgr) callconv(.winapi) HRESULT, handles.mgr.lpVtbl, SLOT_CM_DeleteAllCookies);
    const hr = DeleteAll(handles.mgr);
    if (hr < 0) return opts_mod.CookieError.Backend;
}

comptime {
    // Keep std + builtin alive in case future trimming inadvertently
    // drops references.
    _ = builtin;
}
