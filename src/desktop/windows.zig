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
const clipboard_mod = @import("clipboard.zig");

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
const WM_GETOBJECT: UINT = 0x003D;
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
extern "user32" fn MessageBoxW(hwnd: HWND, text: LPCWSTR, caption: LPCWSTR, ty: UINT) callconv(.winapi) c_int;
extern "user32" fn SetWindowPos(
    hwnd: HWND,
    insert_after: HWND,
    x: c_int,
    y: c_int,
    cx: c_int,
    cy: c_int,
    flags: UINT,
) callconv(.winapi) BOOL;
extern "user32" fn SetLayeredWindowAttributes(hwnd: HWND, color: DWORD, alpha: u8, flags: DWORD) callconv(.winapi) BOOL;
extern "user32" fn GetWindowLongPtrW(hwnd: HWND, idx: c_int) callconv(.winapi) c_long;
extern "user32" fn SetWindowLongPtrW(hwnd: HWND, idx: c_int, value: c_long) callconv(.winapi) c_long;
extern "user32" fn GetWindowRect(hwnd: HWND, rect: *RECT) callconv(.winapi) BOOL;
extern "user32" fn GetSystemMetrics(idx: c_int) callconv(.winapi) c_int;
extern "user32" fn SetForegroundWindow(hwnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn GetDpiForWindow(hwnd: HWND) callconv(.winapi) c_uint;
const FLASHWINFO = extern struct {
    cbSize: u32 = 0,
    hwnd: HWND = null,
    dwFlags: u32 = 0,
    uCount: u32 = 0,
    dwTimeout: u32 = 0,
};
extern "user32" fn FlashWindowEx(info: *FLASHWINFO) callconv(.winapi) BOOL;
extern "user32" fn IsIconic(hwnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn IsZoomed(hwnd: HWND) callconv(.winapi) BOOL;

// ---- Menu + accelerator externs ---------------------------------------------
//
// Default menu bar (File + Edit) for parity with the macOS App + Edit
// menu. Only File→Quit has a real handler; Edit items are decorative
// (label hints) — WebView2 handles Ctrl+C/V/X/Z/Y/A natively when it
// has focus, and `WM_COPY`-style messages don't reach the OOP HTML
// input on the parent HWND.
const HACCEL = ?*opaque {};
const ACCEL = extern struct { fVirt: u8, key: u16, cmd: u16 };

const MF_STRING: UINT = 0x0000;
const MF_POPUP: UINT = 0x0010;
const MF_SEPARATOR: UINT = 0x0800;
const WM_COMMAND: UINT = 0x0111;
const FVIRTKEY: u8 = 0x01;
const FCONTROL: u8 = 0x08;

extern "user32" fn CreateMenu() callconv(.winapi) HMENU;
extern "user32" fn CreatePopupMenu() callconv(.winapi) HMENU;
extern "user32" fn AppendMenuW(menu: HMENU, flags: UINT, id: usize, name: LPCWSTR) callconv(.winapi) BOOL;
extern "user32" fn SetMenu(hwnd: HWND, menu: HMENU) callconv(.winapi) BOOL;
extern "user32" fn DestroyMenu(menu: HMENU) callconv(.winapi) BOOL;
extern "user32" fn CreateAcceleratorTableW(accel: [*]const ACCEL, count: c_int) callconv(.winapi) HACCEL;
extern "user32" fn TranslateAcceleratorW(hwnd: HWND, accel: HACCEL, msg: *MSG) callconv(.winapi) c_int;
extern "user32" fn DestroyAcceleratorTable(accel: HACCEL) callconv(.winapi) BOOL;

// Command IDs for the default menu. 0x8000+ is the private app range
// (0x0000–0x7FFF is reserved by Microsoft for predefined commands).
// Edit IDs exist so `AppendMenuW` has a valid `id` parameter and so
// future hooks can intercept them; the accelerator table omits them
// because the WebView2 OOP host handles those keystrokes itself.
const ID_FILE_QUIT: u16 = 0x8001;
const ID_EDIT_UNDO: u16 = 0x8010;
const ID_EDIT_REDO: u16 = 0x8011;
const ID_EDIT_CUT: u16 = 0x8013;
const ID_EDIT_COPY: u16 = 0x8014;
const ID_EDIT_PASTE: u16 = 0x8015;
const ID_EDIT_SELECT_ALL: u16 = 0x8016;

// ---- Clipboard externs ------------------------------------------------------
extern "user32" fn OpenClipboard(hwnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
extern "user32" fn SetClipboardData(format: UINT, mem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "user32" fn GetClipboardData(format: UINT) callconv(.winapi) ?*anyopaque;
extern "user32" fn IsClipboardFormatAvailable(format: UINT) callconv(.winapi) BOOL;
extern "user32" fn RegisterClipboardFormatW(name: [*:0]const u16) callconv(.winapi) UINT;
extern "kernel32" fn GlobalAlloc(flags: UINT, bytes: usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalLock(mem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(mem: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn GlobalFree(mem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalSize(mem: ?*anyopaque) callconv(.winapi) usize;

// ---- Registry (color-scheme query) -----------------------------------------
//
// `RegGetValueW` reads a single value with one call and handles the
// open + close internally. We only care about
// `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize\AppsUseLightTheme`
// which is 0 for dark and 1 for light on Windows 10/11. Missing key
// (older Windows) collapses to .unknown.
const HKEY = ?*opaque {};
const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
const ERROR_SUCCESS: c_long = 0;
const RRF_RT_REG_DWORD: DWORD = 0x10;
extern "advapi32" fn RegGetValueW(
    hkey: HKEY,
    sub_key: LPCWSTR,
    value: LPCWSTR,
    flags: DWORD,
    type_out: ?*DWORD,
    data: ?*anyopaque,
    data_size: ?*DWORD,
) callconv(.winapi) c_long;

const CF_UNICODETEXT: UINT = 13;
const GMEM_MOVEABLE: UINT = 0x0002;

// ---- Common-dialog struct (OPENFILENAMEW) -----------------------------------
//
// Canonical Win32 layout from <commdlg.h>. The trailing `FlagsEx`
// field is present even on legacy Windows because Microsoft has kept
// the struct ABI-stable since XP. Caller fills `lStructSize` with
// `@sizeOf(OPENFILENAMEW)`; the rest defaults to zeros via the
// `OPENFILENAMEW{}` literal.

const OPENFILENAMEW = extern struct {
    lStructSize: DWORD = 0,
    hwndOwner: HWND = null,
    hInstance: HINSTANCE = null,
    lpstrFilter: LPCWSTR = null,
    lpstrCustomFilter: LPWSTR = null,
    nMaxCustFilter: DWORD = 0,
    nFilterIndex: DWORD = 0,
    lpstrFile: LPWSTR = null,
    nMaxFile: DWORD = 0,
    lpstrFileTitle: LPWSTR = null,
    nMaxFileTitle: DWORD = 0,
    lpstrInitialDir: LPCWSTR = null,
    lpstrTitle: LPCWSTR = null,
    Flags: DWORD = 0,
    nFileOffset: u16 = 0,
    nFileExtension: u16 = 0,
    lpstrDefExt: LPCWSTR = null,
    lCustData: LPARAM = 0,
    lpfnHook: ?*const anyopaque = null,
    lpTemplateName: LPCWSTR = null,
    pvReserved: ?*anyopaque = null,
    dwReserved: DWORD = 0,
    FlagsEx: DWORD = 0,
};

const OFN_OVERWRITEPROMPT: DWORD = 0x00000002;
const OFN_PATHMUSTEXIST: DWORD = 0x00000800;
const OFN_FILEMUSTEXIST: DWORD = 0x00001000;
const OFN_ALLOWMULTISELECT: DWORD = 0x00000200;
const OFN_EXPLORER: DWORD = 0x00080000;

extern "comdlg32" fn GetOpenFileNameW(ofn: *OPENFILENAMEW) callconv(.winapi) BOOL;
extern "comdlg32" fn GetSaveFileNameW(ofn: *OPENFILENAMEW) callconv(.winapi) BOOL;

const MB_OK: UINT = 0x00000000;
const MB_OKCANCEL: UINT = 0x00000001;
const MB_YESNO: UINT = 0x00000004;
const MB_YESNOCANCEL: UINT = 0x00000003;
const MB_ICONINFORMATION: UINT = 0x00000040;
const MB_ICONWARNING: UINT = 0x00000030;
const MB_ICONERROR: UINT = 0x00000010;

const IDOK: c_int = 1;
const IDCANCEL: c_int = 2;
const IDYES: c_int = 6;
const IDNO: c_int = 7;

const WM_CLOSE: UINT = 0x0010;
const WM_ACTIVATE: UINT = 0x0006;
const WM_SETTINGCHANGE: UINT = 0x001A;
const WM_COPYDATA: UINT = 0x004A;
const WM_GETMINMAXINFO: UINT = 0x0024;

/// `<winuser.h>` — Win32 hands wndProc a pointer to this struct in
/// lParam on WM_GETMINMAXINFO. We patch the `ptMinTrackSize` /
/// `ptMaxTrackSize` fields when the WindowCtx has constraints set.
const MINMAXINFO = extern struct {
    ptReserved: POINT,
    ptMaxSize: POINT,
    ptMaxPosition: POINT,
    ptMinTrackSize: POINT,
    ptMaxTrackSize: POINT,
};
const WM_USER: UINT = 0x0400;
/// Tray-icon callback message. Set as `NOTIFYICONDATAW.uCallbackMessage`
/// by `tray.zig` so Shell32 routes mouse events on the tray icon back
/// through this window's `wndProc`. Exposed pub so `tray.zig` can read
/// the canonical value without redefining a parallel constant.
pub const WM_VERVE_TRAY: UINT = WM_USER + 100;

/// Optional forwarders registered by `tray.zig` once `Tray.init` runs
/// on Windows. wndProc invokes them on `WM_VERVE_TRAY` and on
/// `WM_COMMAND` IDs in the tray-reserved `0xC000` block. Left null in
/// builds that never create a tray — the cost is one nullable load per
/// matching message, which is noise next to `DefWindowProcW`.
pub var tray_dispatch_command: ?*const fn (hwnd: ?*anyopaque, cmd_id: u16) bool = null;
pub var tray_dispatch_message: ?*const fn (hwnd: ?*anyopaque, wparam: usize, lparam: isize) void = null;

/// `COPYDATASTRUCT` from `<winuser.h>`. WM_COPYDATA carries a pointer
/// to one of these in `lParam`. The receiver must not retain `lpData`
/// past message return — the sender's buffer goes out of scope as
/// soon as `SendMessageW` returns.
const COPYDATASTRUCT = extern struct {
    dwData: usize,
    cbData: DWORD,
    lpData: ?*const anyopaque,
};

/// Sentinel `dwData` value the deep-link forwarder uses. Mirrors the
/// constant in `deep_link.zig` so the receiver can ignore unrelated
/// WM_COPYDATA traffic (other apps using the same wndProc, etc).
const URL_COPYDATA_SENTINEL: usize = 0x55524C00; // "URL\0"

extern "ole32" fn CoTaskMemFree(p: LPVOID) callconv(.winapi) void;
extern "ole32" fn OleInitialize(reserved: ?*anyopaque) callconv(.winapi) HRESULT;
extern "ole32" fn OleUninitialize() callconv(.winapi) void;
extern "ole32" fn RegisterDragDrop(hwnd: HWND, dropTarget: *IDropTarget) callconv(.winapi) HRESULT;
extern "ole32" fn RevokeDragDrop(hwnd: HWND) callconv(.winapi) HRESULT;
extern "ole32" fn ReleaseStgMedium(stgmedium: *STGMEDIUM) callconv(.winapi) void;
extern "shell32" fn DragQueryFileW(hdrop: ?*anyopaque, idx: UINT, buf: ?[*]u16, size: UINT) callconv(.winapi) UINT;

// ---- IDropTarget COM machinery ----------------------------------------------
// Minimal viable IDropTarget implementation — file drops only, copy-effect
// always. Wired to the window's HWND via `RegisterDragDrop` during init;
// torn down via `RevokeDragDrop` on `WM_DESTROY`.

const POINTL = extern struct { x: c_long, y: c_long };
const FORMATETC = extern struct {
    cfFormat: u16,
    ptd: ?*anyopaque,
    dwAspect: DWORD,
    lindex: c_long,
    tymed: DWORD,
};
const STGMEDIUM = extern struct {
    tymed: DWORD,
    handle: ?*anyopaque,
    pUnkForRelease: ?*anyopaque,
};
const DROPEFFECT_NONE: DWORD = 0;
const DROPEFFECT_COPY: DWORD = 1;
const CF_HDROP: u16 = 15;
const DVASPECT_CONTENT: DWORD = 1;
const TYMED_HGLOBAL: DWORD = 1;

/// `IDataObject` is opaque to us — we only call `GetData` (slot 3) on
/// it. The remaining vtable slots stay unbound.
const IDataObject = extern struct { lpVtbl: *const anyopaque };
const SLOT_IDataObject_GetData: usize = 3;

const IDropTargetVtbl = extern struct {
    QueryInterface: *const fn (this: ?*const IUnknown, iid: *const IID, ppv: *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (this: ?*const IUnknown) callconv(.winapi) ULONG,
    Release: *const fn (this: ?*const IUnknown) callconv(.winapi) ULONG,
    DragEnter: *const fn (this: ?*const IDropTarget, dataObj: *IDataObject, key_state: DWORD, pt: POINTL, effect: *DWORD) callconv(.winapi) HRESULT,
    DragOver: *const fn (this: ?*const IDropTarget, key_state: DWORD, pt: POINTL, effect: *DWORD) callconv(.winapi) HRESULT,
    DragLeave: *const fn (this: ?*const IDropTarget) callconv(.winapi) HRESULT,
    Drop: *const fn (this: ?*const IDropTarget, dataObj: *IDataObject, key_state: DWORD, pt: POINTL, effect: *DWORD) callconv(.winapi) HRESULT,
};
const IDropTarget = extern struct {
    lpVtbl: *const IDropTargetVtbl,
    ctx: *WindowCtx,
};
extern "shlwapi" fn SHCreateMemStream(bytes: ?[*]const u8, size: UINT) callconv(.winapi) ?*IStream;

// `CapturePreview` writes through a writable IStream. ole32's
// `CreateStreamOnHGlobal(NULL, TRUE, &stream)` allocates a growable
// HGLOBAL-backed stream that releases its memory when the stream's
// refcount hits zero. Caller reads back via IStream::Stat + Seek +
// Read. (Identical contract to shlwapi's SHCreateStreamOnHGlobal, but
// ole32 — already linked — exports it reliably under the MinGW import
// libs, where shlwapi's copy is absent.)
extern "ole32" fn CreateStreamOnHGlobal(
    hGlobal: ?*anyopaque,
    fDeleteOnRelease: BOOL,
    ppstm: *?*IStreamW,
) callconv(.winapi) HRESULT;

// IStream we DO consume directly (Stat / Seek / Read) — needs a real
// vtable layout. `IStream` (consumer-named `IStreamW` to avoid colliding
// with the opaque WebView2-only alias above) extends ISequentialStream
// which extends IUnknown.
const IStreamW = extern struct { lpVtbl: *const anyopaque };

const SLOT_IStream_Read: usize = 3;
const SLOT_IStream_Seek: usize = 5;
const SLOT_IStream_Stat: usize = 11;

const STREAM_SEEK_SET: DWORD = 0;
const STATFLAG_NONAME: DWORD = 1;

const STATSTG = extern struct {
    pwcsName: LPWSTR = null,
    type: DWORD = 0,
    cbSize: u64 = 0,
    mtime: extern struct { lo: DWORD = 0, hi: DWORD = 0 } = .{},
    ctime: extern struct { lo: DWORD = 0, hi: DWORD = 0 } = .{},
    atime: extern struct { lo: DWORD = 0, hi: DWORD = 0 } = .{},
    grfMode: DWORD = 0,
    grfLocksSupported: DWORD = 0,
    clsid: GUID = .{ .Data1 = 0, .Data2 = 0, .Data3 = 0, .Data4 = .{ 0, 0, 0, 0, 0, 0, 0, 0 } },
    grfStateBits: DWORD = 0,
    reserved: DWORD = 0,
};

// IStream is opaque to us when handed to WebView2's CapturePreview —
// we only need the pointer round-tripped. The IStreamW alias above is
// for the cases where we DO call into the vtable.
const IStream = IStreamW;

const HANDLE = ?*opaque {};
const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

const GENERIC_WRITE: DWORD = 0x40000000;
const CREATE_ALWAYS: DWORD = 2;
const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;
const FILE_SHARE_READ: DWORD = 0x01;

extern "kernel32" fn CreateFileW(
    name: LPCWSTR,
    access: DWORD,
    share: DWORD,
    sec: ?*anyopaque,
    creation: DWORD,
    flags: DWORD,
    template: HANDLE,
) callconv(.winapi) HANDLE;
extern "kernel32" fn WriteFile(
    handle: HANDLE,
    buffer: ?[*]const u8,
    bytes_to_write: DWORD,
    bytes_written: *DWORD,
    overlapped: ?*anyopaque,
) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;

// ---- WebView2 CapturePreview completion handler -----------------------------
//
// IID for `ICoreWebView2CapturePreviewCompletedHandler` from the SDK
// idl. Required for `QueryInterface`. We hardcode it the same way the
// cookie/env handlers do.
const IID_CapturePreviewCompleted: GUID = .{
    .Data1 = 0x697E05E9,
    .Data2 = 0x3D8F,
    .Data3 = 0x45FA,
    .Data4 = .{ 0x96, 0x04, 0x28, 0x21, 0x47, 0xE4, 0xCE, 0x05 },
};

const ICapturePreviewCompletedHandlerVtbl = extern struct {
    QueryInterface: *const fn (?*const ICapturePreviewCompletedHandler, *const IID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (?*const ICapturePreviewCompletedHandler) callconv(.winapi) ULONG,
    Release: *const fn (?*const ICapturePreviewCompletedHandler) callconv(.winapi) ULONG,
    Invoke: *const fn (?*const ICapturePreviewCompletedHandler, HRESULT) callconv(.winapi) HRESULT,
};

const ICapturePreviewCompletedHandler = extern struct {
    lpVtbl: *const ICapturePreviewCompletedHandlerVtbl,
    done: *bool,
    error_code: *HRESULT,
};

const COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT_PNG: c_int = 0;

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
const Wv2_16 = extern struct { lpVtbl: *const anyopaque };
const Wv2_22 = extern struct { lpVtbl: *const anyopaque };
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
const SLOT_WV2_Reload: usize = 31;
const SLOT_WV2_GoBack: usize = 40;
const SLOT_WV2_GoForward: usize = 41;
const SLOT_WV2_get_CanGoBack: usize = 38;
const SLOT_WV2_get_CanGoForward: usize = 39;
const SLOT_WV2_get_Source: usize = 4;
const SLOT_WV2_get_DocumentTitle: usize = 48;
// `ICoreWebView2Controller` (not ICoreWebView2) holds the zoom
// factor — slot 12 in vtable order: QI/AddRef/Release (3) +
// get_IsVisible/put_IsVisible/get_Bounds/put_Bounds/get_ZoomFactor/
// put_ZoomFactor + ... So ZoomFactor lives at slot 11/12.
const SLOT_CTRL_get_ZoomFactor: usize = 11;
const SLOT_CTRL_put_ZoomFactor: usize = 12;
const SLOT_WV2_NavigateToString: usize = 6;
const SLOT_WV2_AddScriptToExecuteOnDocumentCreated: usize = 27;
const SLOT_WV2_ExecuteScript: usize = 29;
/// `CapturePreview(format, IStream*, completionHandler)` —
/// ICoreWebView2 slot 30 per WebView2.h. PNG encoder is built into
/// the runtime; output goes into the supplied stream.
const SLOT_WV2_CapturePreview: usize = 30;
const SLOT_WV2_add_WebMessageReceived: usize = 34;
// ICoreWebView2 vtable slots (verified against the SDK header): the
// WebResourceRequested pair sits at 55/57, not 52/54 — the off-by-three
// here silently registered the asset handler against the wrong methods
// (they returned S_OK but never fired), leaving every page blank on Windows.
const SLOT_WV2_add_WebResourceRequested: usize = 55;
const SLOT_WV2_AddWebResourceRequestedFilter: usize = 57;

// ICoreWebView2_22.AddWebResourceRequestedFilterWithRequestSourceKinds — the
// only way to intercept the *top-level document* request of a custom scheme.
// The legacy AddWebResourceRequestedFilter only covers sub-resources, so a
// page navigated via `<scheme>://app/index.html` never fires the handler and
// renders blank. SOURCE_KINDS_ALL includes the document navigation itself.
const IID_ICoreWebView2_22: GUID = .{ .Data1 = 0xdb75dfc7, .Data2 = 0xa857, .Data3 = 0x4632, .Data4 = .{ 0xa3, 0x98, 0x69, 0x69, 0xdd, 0xe2, 0x6c, 0x0a } };
const SLOT_WV2_22_AddWebResourceRequestedFilterWithRequestSourceKinds: usize = 123;
const COREWEBVIEW2_WEB_RESOURCE_REQUEST_SOURCE_KINDS_ALL: u32 = 0xffffffff;

const SLOT_RequestedArgs_get_Request: usize = 3;
const SLOT_RequestedArgs_put_Response: usize = 5;

const SLOT_Request_get_Uri: usize = 3;

const SLOT_MessageArgs_TryGetWebMessageAsString: usize = 5;

// ICoreWebView2_2 inherits all 58 ICoreWebView2 methods (slots 3-60),
// then adds 7 more (slots 61-67). Only get_CookieManager is consumed
// here.
const SLOT_WV2_2_get_CookieManager: usize = 66;

// ICoreWebView2_16 inherits every method of ICoreWebView2 through
// ICoreWebView2_15, then adds Print / PrintToPdfStream / ShowPrintUI.
// Slot 104 is the hand-extracted ShowPrintUI position counted from
// WebView2.h:
//   58 (Wv2) + 7 (_2) + 5 (_3) + 6 (_4) + 2 (_5) + 2 (_6) + 2 (_7) +
//    5 (_8) + 2 (_9) + 2 (_10) + 2 (_11) + 2 (_12) + 2 (_13) +
//    2 (_14) + 2 (_15) = 101 inherited, +3 in slots 102–104.
// LOOK UP: verify against actual WebView2.h on first live Windows
// boot; if QI returns S_OK but ShowPrintUI calls crash, this index
// is wrong. Same convention as SLOT_WV2_2_get_CookieManager above.
const SLOT_WV2_16_ShowPrintUI: usize = 104;

// COREWEBVIEW2_PRINT_DIALOG_KIND.
const PRINT_DIALOG_KIND_BROWSER: c_int = 0;
const PRINT_DIALOG_KIND_SYSTEM: c_int = 1;

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

// {0EB34DC9-9F91-41E1-BBBB-E7F04446A6C1}
const IID_ICoreWebView2_16: IID = .{
    .Data1 = 0x0EB34DC9,
    .Data2 = 0x9F91,
    .Data3 = 0x41E1,
    .Data4 = .{ 0xBB, 0xBB, 0xE7, 0xF0, 0x44, 0x46, 0xA6, 0xC1 },
};

fn vtSlot(comptime Fn: type, lpVtbl: *const anyopaque, slot: usize) Fn {
    const arr: [*]const *const anyopaque = @ptrCast(@alignCast(lpVtbl));
    return @ptrCast(arr[slot]);
}

/// Shared body for WebView2 string-getter calls. `get_Source` and
/// `get_DocumentTitle` share the same shape: `(WV, LPWSTR*) →
/// HRESULT`, caller frees via `CoTaskMemFree`. We allocate the
/// UTF-8 copy via the caller's allocator and free the WinRT
/// allocation immediately.
fn wv2StringGetter(wv: *Wv2, slot: usize, allocator: std.mem.Allocator) ![]u8 {
    const Getter = vtSlot(*const fn (*Wv2, *?[*:0]const u16) callconv(.winapi) HRESULT, wv.lpVtbl, slot);
    var ptr: ?[*:0]const u16 = null;
    if (Getter(wv, &ptr) < 0 or ptr == null) return allocator.dupe(u8, "");
    defer CoTaskMemFree(@constCast(@as(?*anyopaque, @ptrCast(ptr.?))));
    var len: usize = 0;
    while (ptr.?[len] != 0) : (len += 1) {}
    var buf = allocator.alloc(u8, len * 3 + 1) catch return error.OutOfMemory;
    const written = std.unicode.utf16LeToUtf8(buf, ptr.?[0..len]) catch {
        allocator.free(buf);
        return allocator.dupe(u8, "");
    };
    return allocator.realloc(buf, written) catch buf[0..written];
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

// ---- Custom URL-scheme registration -----------------------------------------
//
// WebView2 is Chromium: it refuses to *navigate* to an unregistered URL
// scheme, so `<scheme>://app/index.html` renders a blank page and the
// WebResourceRequested filter below never even fires. WKWebView (macOS) has
// no such restriction, which is why this only bites on Windows. The fix is to
// declare the scheme at environment-creation time via
// ICoreWebView2EnvironmentOptions4.CustomSchemeRegistrations. We hand
// CreateCoreWebView2EnvironmentWithOptions a minimal options object exposing
// exactly one registration. All three COM objects are process-global
// singletons with no per-call state, so AddRef/Release are no-ops and
// QueryInterface dispatches purely by IID. The scheme name is captured into
// `g_scheme_name_w` immediately before env creation (see Window.init).

extern "ole32" fn CoTaskMemAlloc(cb: usize) callconv(.winapi) ?*anyopaque;

const S_OK: HRESULT = 0;
const E_OUTOFMEMORY: HRESULT = @bitCast(@as(u32, 0x8007000E));

const IID_IUnknown: GUID = .{ .Data1 = 0, .Data2 = 0, .Data3 = 0, .Data4 = .{ 0, 0, 0, 0xC0, 0, 0, 0, 0x46 } };
const IID_EnvOptions: GUID = .{ .Data1 = 0x2fde08a8, .Data2 = 0x1e9a, .Data3 = 0x4766, .Data4 = .{ 0x8c, 0x05, 0x95, 0xa9, 0xce, 0xb9, 0xd1, 0xc5 } };
const IID_EnvOptions4: GUID = .{ .Data1 = 0xac52d13f, .Data2 = 0x0d38, .Data3 = 0x475a, .Data4 = .{ 0x9d, 0xca, 0x87, 0x65, 0x80, 0xd6, 0x79, 0x3e } };
const IID_CustomScheme: GUID = .{ .Data1 = 0xd60ac92c, .Data2 = 0x37a6, .Data3 = 0x4b26, .Data4 = .{ 0xa3, 0x9e, 0x95, 0xcf, 0xe5, 0x90, 0x47, 0xbb } };

fn guidEq(a: *const IID, b: *const IID) bool {
    return a.Data1 == b.Data1 and a.Data2 == b.Data2 and a.Data3 == b.Data3 and std.mem.eql(u8, &a.Data4, &b.Data4);
}

fn comAddRef1(_: ?*anyopaque) callconv(.winapi) ULONG {
    return 1;
}
fn comRelease1(_: ?*anyopaque) callconv(.winapi) ULONG {
    return 1;
}

// Scheme name as a NUL-terminated UTF-16 string, set before env creation.
var g_scheme_name_w: [64]u16 = [_]u16{0} ** 64;

// --- ICoreWebView2CustomSchemeRegistration (IID d60ac92c-…) ---
const ICustomSchemeRegVtbl = extern struct {
    QueryInterface: *const fn (?*anyopaque, *const IID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (?*anyopaque) callconv(.winapi) ULONG,
    Release: *const fn (?*anyopaque) callconv(.winapi) ULONG,
    get_SchemeName: *const fn (?*anyopaque, *LPWSTR) callconv(.winapi) HRESULT,
    get_TreatAsSecure: *const fn (?*anyopaque, *BOOL) callconv(.winapi) HRESULT,
    put_TreatAsSecure: *const fn (?*anyopaque, BOOL) callconv(.winapi) HRESULT,
    GetAllowedOrigins: *const fn (?*anyopaque, *u32, *?*anyopaque) callconv(.winapi) HRESULT,
    SetAllowedOrigins: *const fn (?*anyopaque, u32, ?*anyopaque) callconv(.winapi) HRESULT,
    get_HasAuthorityComponent: *const fn (?*anyopaque, *BOOL) callconv(.winapi) HRESULT,
    put_HasAuthorityComponent: *const fn (?*anyopaque, BOOL) callconv(.winapi) HRESULT,
};
fn schemeQI(this: ?*anyopaque, riid: *const IID, ppv: *?*anyopaque) callconv(.winapi) HRESULT {
    if (guidEq(riid, &IID_IUnknown) or guidEq(riid, &IID_CustomScheme)) {
        ppv.* = this;
        return S_OK;
    }
    ppv.* = null;
    return E_NOINTERFACE;
}
fn schemeGetName(_: ?*anyopaque, out: *LPWSTR) callconv(.winapi) HRESULT {
    var n: usize = 0;
    while (g_scheme_name_w[n] != 0) : (n += 1) {}
    const count = n + 1; // include the NUL terminator
    const mem = CoTaskMemAlloc(count * 2) orelse return E_OUTOFMEMORY;
    const dst: [*]u16 = @ptrCast(@alignCast(mem));
    @memcpy(dst[0..count], g_scheme_name_w[0..count]);
    out.* = @ptrCast(dst);
    return S_OK;
}
fn schemeGetSecure(_: ?*anyopaque, out: *BOOL) callconv(.winapi) HRESULT {
    out.* = 1; // secure context (https-equivalent origin)
    return S_OK;
}
fn schemeGetOrigins(_: ?*anyopaque, count: *u32, origins: *?*anyopaque) callconv(.winapi) HRESULT {
    // Allow-list "*": permit any origin (including the programmatic top-level
    // Navigate to `<scheme>://app/...`) to access the scheme. An EMPTY list
    // makes WebView2 treat the scheme as access-restricted and silently blocks
    // the initial navigation, so it hangs with no WebResourceRequested event.
    const arr = CoTaskMemAlloc(@sizeOf(?*anyopaque)) orelse return E_OUTOFMEMORY;
    const star = CoTaskMemAlloc(2 * 2) orelse return E_OUTOFMEMORY; // "*\0"
    const s: [*]u16 = @ptrCast(@alignCast(star));
    s[0] = '*';
    s[1] = 0;
    const slot: *?*anyopaque = @ptrCast(@alignCast(arr));
    slot.* = @ptrCast(s);
    count.* = 1;
    origins.* = arr;
    return S_OK;
}
fn schemeGetAuthority(_: ?*anyopaque, out: *BOOL) callconv(.winapi) HRESULT {
    out.* = 1; // `<scheme>://app/...` parses `app` as the host
    return S_OK;
}
fn schemePutBool(_: ?*anyopaque, _: BOOL) callconv(.winapi) HRESULT {
    return S_OK;
}
fn schemeSetOrigins(_: ?*anyopaque, _: u32, _: ?*anyopaque) callconv(.winapi) HRESULT {
    return S_OK;
}
const scheme_reg_vtbl: ICustomSchemeRegVtbl = .{
    .QueryInterface = schemeQI,
    .AddRef = comAddRef1,
    .Release = comRelease1,
    .get_SchemeName = schemeGetName,
    .get_TreatAsSecure = schemeGetSecure,
    .put_TreatAsSecure = schemePutBool,
    .GetAllowedOrigins = schemeGetOrigins,
    .SetAllowedOrigins = schemeSetOrigins,
    .get_HasAuthorityComponent = schemeGetAuthority,
    .put_HasAuthorityComponent = schemePutBool,
};
const SchemeRegObj = extern struct { lpVtbl: *const ICustomSchemeRegVtbl };
var g_scheme_reg: SchemeRegObj = .{ .lpVtbl = &scheme_reg_vtbl };

// --- ICoreWebView2EnvironmentOptions (IID 2fde08a8-…) + …Options4 (ac52d13f-…) ---
const IEnvOptionsVtbl = extern struct {
    QueryInterface: *const fn (?*anyopaque, *const IID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (?*anyopaque) callconv(.winapi) ULONG,
    Release: *const fn (?*anyopaque) callconv(.winapi) ULONG,
    get_AdditionalBrowserArguments: *const fn (?*anyopaque, *LPWSTR) callconv(.winapi) HRESULT,
    put_AdditionalBrowserArguments: *const fn (?*anyopaque, LPCWSTR) callconv(.winapi) HRESULT,
    get_Language: *const fn (?*anyopaque, *LPWSTR) callconv(.winapi) HRESULT,
    put_Language: *const fn (?*anyopaque, LPCWSTR) callconv(.winapi) HRESULT,
    get_TargetCompatibleBrowserVersion: *const fn (?*anyopaque, *LPWSTR) callconv(.winapi) HRESULT,
    put_TargetCompatibleBrowserVersion: *const fn (?*anyopaque, LPCWSTR) callconv(.winapi) HRESULT,
    get_AllowSingleSignOnUsingOSPrimaryAccount: *const fn (?*anyopaque, *BOOL) callconv(.winapi) HRESULT,
    put_AllowSingleSignOnUsingOSPrimaryAccount: *const fn (?*anyopaque, BOOL) callconv(.winapi) HRESULT,
};
const IEnvOptions4Vtbl = extern struct {
    QueryInterface: *const fn (?*anyopaque, *const IID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (?*anyopaque) callconv(.winapi) ULONG,
    Release: *const fn (?*anyopaque) callconv(.winapi) ULONG,
    GetCustomSchemeRegistrations: *const fn (?*anyopaque, *u32, *?*anyopaque) callconv(.winapi) HRESULT,
    SetCustomSchemeRegistrations: *const fn (?*anyopaque, u32, ?*anyopaque) callconv(.winapi) HRESULT,
};
const EnvOptionsObj = extern struct {
    lpVtbl: *const IEnvOptionsVtbl,
    lpVtbl4: *const IEnvOptions4Vtbl,
};
fn envOptForIID(riid: *const IID, ppv: *?*anyopaque) HRESULT {
    // IUnknown identity is the primary object regardless of which interface
    // the QI started from (COM requires a stable IUnknown).
    if (guidEq(riid, &IID_IUnknown) or guidEq(riid, &IID_EnvOptions)) {
        ppv.* = @ptrCast(&g_env_options);
        return S_OK;
    }
    if (guidEq(riid, &IID_EnvOptions4)) {
        ppv.* = @ptrCast(&g_env_options.lpVtbl4);
        return S_OK;
    }
    ppv.* = null;
    return E_NOINTERFACE;
}
fn envQI(_: ?*anyopaque, riid: *const IID, ppv: *?*anyopaque) callconv(.winapi) HRESULT {
    return envOptForIID(riid, ppv);
}
fn envGetNull(_: ?*anyopaque, out: *LPWSTR) callconv(.winapi) HRESULT {
    // NULL means "no value — use the runtime default". An empty string is
    // NOT equivalent: WebView2 rejects an empty TargetCompatibleBrowserVersion
    // with E_INVALIDARG, which aborts the whole environment creation before
    // it ever reads our custom-scheme registration.
    out.* = null;
    return S_OK;
}
fn envPutStr(_: ?*anyopaque, _: LPCWSTR) callconv(.winapi) HRESULT {
    return S_OK;
}
fn envGetTargetVersion(_: ?*anyopaque, out: *LPWSTR) callconv(.winapi) HRESULT {
    // Unlike the other option strings, this one cannot be null/empty:
    // WebView2 validates the installed runtime against it and rejects a
    // missing value with E_INVALIDARG (aborting env creation). "86.0.616.0"
    // is the original GA baseline — every Evergreen runtime satisfies it,
    // and the actual (newer) runtime still provides Options4/custom schemes.
    const ver = std.unicode.utf8ToUtf16LeStringLiteral("86.0.616.0");
    const count = ver.len + 1; // include NUL
    const mem = CoTaskMemAlloc(count * 2) orelse return E_OUTOFMEMORY;
    const dst: [*]u16 = @ptrCast(@alignCast(mem));
    @memcpy(dst[0..ver.len], ver[0..ver.len]);
    dst[ver.len] = 0;
    out.* = @ptrCast(dst);
    return S_OK;
}
fn envGetBoolFalse(_: ?*anyopaque, out: *BOOL) callconv(.winapi) HRESULT {
    out.* = 0;
    return S_OK;
}
fn envPutBool(_: ?*anyopaque, _: BOOL) callconv(.winapi) HRESULT {
    return S_OK;
}
const env_options_vtbl: IEnvOptionsVtbl = .{
    .QueryInterface = envQI,
    .AddRef = comAddRef1,
    .Release = comRelease1,
    .get_AdditionalBrowserArguments = envGetNull,
    .put_AdditionalBrowserArguments = envPutStr,
    .get_Language = envGetNull,
    .put_Language = envPutStr,
    .get_TargetCompatibleBrowserVersion = envGetTargetVersion,
    .put_TargetCompatibleBrowserVersion = envPutStr,
    .get_AllowSingleSignOnUsingOSPrimaryAccount = envGetBoolFalse,
    .put_AllowSingleSignOnUsingOSPrimaryAccount = envPutBool,
};
fn env4QI(_: ?*anyopaque, riid: *const IID, ppv: *?*anyopaque) callconv(.winapi) HRESULT {
    return envOptForIID(riid, ppv);
}
fn env4GetSchemes(_: ?*anyopaque, count: *u32, regs: *?*anyopaque) callconv(.winapi) HRESULT {
    // Hand back a 1-element array of interface pointers. WebView2 takes
    // ownership of the array (frees it via CoTaskMemFree) and Releases each
    // entry, so AddRef the registration to balance.
    const arr = CoTaskMemAlloc(@sizeOf(?*anyopaque)) orelse return E_OUTOFMEMORY;
    const slot: *?*anyopaque = @ptrCast(@alignCast(arr));
    slot.* = @ptrCast(&g_scheme_reg);
    _ = g_scheme_reg.lpVtbl.AddRef(@ptrCast(&g_scheme_reg));
    count.* = 1;
    regs.* = arr;
    return S_OK;
}
fn env4SetSchemes(_: ?*anyopaque, _: u32, _: ?*anyopaque) callconv(.winapi) HRESULT {
    return S_OK;
}
const env_options4_vtbl: IEnvOptions4Vtbl = .{
    .QueryInterface = env4QI,
    .AddRef = comAddRef1,
    .Release = comRelease1,
    .GetCustomSchemeRegistrations = env4GetSchemes,
    .SetCustomSchemeRegistrations = env4SetSchemes,
};
var g_env_options: EnvOptionsObj = .{ .lpVtbl = &env_options_vtbl, .lpVtbl4 = &env_options4_vtbl };

/// Capture `scheme` as UTF-16 and return the singleton environment-options
/// object to pass to CreateCoreWebView2EnvironmentWithOptions. Returns null
/// (→ caller passes null options) if the scheme name doesn't fit the buffer.
fn customSchemeOptions(scheme: []const u8) ?*anyopaque {
    const n = std.unicode.utf8ToUtf16Le(g_scheme_name_w[0 .. g_scheme_name_w.len - 1], scheme) catch return null;
    g_scheme_name_w[n] = 0;
    return @ptrCast(&g_env_options);
}

// ---- UI Automation provider (role description + subrole + help) -------------
//
// Window chrome on Windows has no NSAccessibility-equivalent setter; the
// way to publish role-description / dialog-subrole / help-text semantics to
// screen readers (Narrator, NVDA, JAWS) is a server-side UIA provider that
// answers `WM_GETOBJECT` for `UiaRootObjectId`. We expose a minimal
// `IRawElementProviderSimple` whose `GetPropertyValue` returns the strings
// stashed on the `WindowCtx`, and delegate everything else (Name from the
// window title, bounding rects, the WebView2 subtree) to the default host
// provider via `UiaHostProviderFromHwnd`. One provider is embedded per
// `WindowCtx`; AddRef/Release are no-ops because its lifetime is the
// window's. Values are read live, so the setters just swap the stored
// string and assistive tech picks them up on the next query/focus.

extern "Uiautomationcore" fn UiaReturnRawElementProvider(hwnd: HWND, wparam: WPARAM, lparam: LPARAM, el: ?*anyopaque) callconv(.winapi) LRESULT;
extern "Uiautomationcore" fn UiaHostProviderFromHwnd(hwnd: HWND, provider: *?*anyopaque) callconv(.winapi) HRESULT;
extern "OleAut32" fn SysAllocString(psz: ?[*:0]const u16) callconv(.winapi) ?*anyopaque; // BSTR; UIA frees it

const UiaRootObjectId: LPARAM = -25;
const ProviderOptions_ServerSideProvider: c_int = 1;

// UIA property IDs (uiautomationclient.h).
const UIA_ControlTypePropertyId: c_int = 30003;
const UIA_LocalizedControlTypePropertyId: c_int = 30004;
const UIA_HelpTextPropertyId: c_int = 30013;
const UIA_IsDialogPropertyId: c_int = 30174;
const UIA_WindowControlTypeId: usize = 50032;

const VT_EMPTY: u16 = 0;
const VT_I4: u16 = 3;
const VT_BSTR: u16 = 8;
const VT_BOOL: u16 = 11;
const VARIANT_TRUE: usize = 0xFFFF;

// 24-byte x64 VARIANT: 8-byte header (vt + 3 reserved WORDs), 8-byte value
// union at offset 8 (BSTR pointer / LONG / VARIANT_BOOL), 8-byte tail pad.
const VARIANT = extern struct {
    vt: u16,
    r1: u16 = 0,
    r2: u16 = 0,
    r3: u16 = 0,
    val: usize = 0,
    pad: u64 = 0,
};

const IID_IRawElementProviderSimple: GUID = .{ .Data1 = 0xd6dd68d1, .Data2 = 0x86fd, .Data3 = 0x4332, .Data4 = .{ 0x86, 0x66, 0x9a, 0xbe, 0xde, 0xa2, 0xd2, 0x4c } };

const RawElementProviderVtbl = extern struct {
    QueryInterface: *const fn (?*anyopaque, *const IID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (?*anyopaque) callconv(.winapi) ULONG,
    Release: *const fn (?*anyopaque) callconv(.winapi) ULONG,
    get_ProviderOptions: *const fn (?*anyopaque, *c_int) callconv(.winapi) HRESULT,
    GetPatternProvider: *const fn (?*anyopaque, c_int, *?*anyopaque) callconv(.winapi) HRESULT,
    GetPropertyValue: *const fn (?*anyopaque, c_int, *VARIANT) callconv(.winapi) HRESULT,
    get_HostRawElementProvider: *const fn (?*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
};

const RawElementProvider = extern struct {
    lpVtbl: *const RawElementProviderVtbl,
    ctx: *WindowCtx,
};

fn uiaQueryInterface(this: ?*anyopaque, riid: *const IID, ppv: *?*anyopaque) callconv(.winapi) HRESULT {
    if (guidEq(riid, &IID_IUnknown) or guidEq(riid, &IID_IRawElementProviderSimple)) {
        ppv.* = this;
        return S_OK;
    }
    ppv.* = null;
    return E_NOINTERFACE;
}

fn uiaGetProviderOptions(_: ?*anyopaque, out: *c_int) callconv(.winapi) HRESULT {
    out.* = ProviderOptions_ServerSideProvider;
    return S_OK;
}

fn uiaGetPatternProvider(_: ?*anyopaque, _: c_int, out: *?*anyopaque) callconv(.winapi) HRESULT {
    out.* = null; // no control patterns; window chrome only
    return S_OK;
}

/// Map the cross-platform subrole onto a UIA control type. All window
/// chrome reports as a Window control type; dialog vs. plain window is
/// differentiated through `UIA_IsDialogPropertyId` (see below), matching
/// how modern UIA surfaces dialogs.
fn controlTypeForSubrole(_: opts_mod.AccessibilitySubrole) usize {
    return UIA_WindowControlTypeId;
}

fn isDialogSubrole(sub: opts_mod.AccessibilitySubrole) bool {
    return sub == .dialog or sub == .system_dialog;
}

fn uiaToBstr(allocator: std.mem.Allocator, s: []const u8) ?*anyopaque {
    const w = std.unicode.utf8ToUtf16LeAllocZ(allocator, s) catch return null;
    defer allocator.free(w);
    return SysAllocString(w.ptr);
}

fn uiaGetPropertyValue(this: ?*anyopaque, pid: c_int, out: *VARIANT) callconv(.winapi) HRESULT {
    out.* = .{ .vt = VT_EMPTY };
    const self: *RawElementProvider = @ptrCast(@alignCast(this orelse return S_OK));
    const cx = self.ctx;
    switch (pid) {
        UIA_LocalizedControlTypePropertyId => {
            if (cx.a11y_role_desc) |s| {
                if (uiaToBstr(cx.allocator, s)) |b| out.* = .{ .vt = VT_BSTR, .val = @intFromPtr(b) };
            }
        },
        UIA_HelpTextPropertyId => {
            if (cx.a11y_help) |s| {
                if (uiaToBstr(cx.allocator, s)) |b| out.* = .{ .vt = VT_BSTR, .val = @intFromPtr(b) };
            }
        },
        UIA_ControlTypePropertyId => {
            out.* = .{ .vt = VT_I4, .val = controlTypeForSubrole(cx.a11y_subrole) };
        },
        UIA_IsDialogPropertyId => {
            out.* = .{ .vt = VT_BOOL, .val = if (isDialogSubrole(cx.a11y_subrole)) VARIANT_TRUE else 0 };
        },
        else => {},
    }
    return S_OK;
}

fn uiaGetHostProvider(this: ?*anyopaque, out: *?*anyopaque) callconv(.winapi) HRESULT {
    out.* = null;
    const self: *RawElementProvider = @ptrCast(@alignCast(this orelse return S_OK));
    _ = UiaHostProviderFromHwnd(self.ctx.hwnd, out);
    return S_OK;
}

const raw_element_provider_vtbl: RawElementProviderVtbl = .{
    .QueryInterface = uiaQueryInterface,
    .AddRef = comAddRef1,
    .Release = comRelease1,
    .get_ProviderOptions = uiaGetProviderOptions,
    .GetPatternProvider = uiaGetPatternProvider,
    .GetPropertyValue = uiaGetPropertyValue,
    .get_HostRawElementProvider = uiaGetHostProvider,
};

/// Replace an owned a11y string on the ctx, freeing any prior value. A
/// failed dupe leaves the slot null (property reverts to default) rather
/// than aborting — accessibility metadata is best-effort.
fn setCtxA11yString(cx: *WindowCtx, slot: *?[]u8, text: []const u8) void {
    if (slot.*) |old| cx.allocator.free(old);
    slot.* = cx.allocator.dupe(u8, text) catch null;
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
    on_color_scheme: ?opts_mod.ColorSchemeHandler = null,
    on_color_scheme_ctx: ?*anyopaque = null,
    on_url_open: ?opts_mod.UrlOpenHandler = null,
    on_url_open_ctx: ?*anyopaque = null,
    on_drag_drop: ?opts_mod.DragDropHandler = null,
    on_drag_drop_ctx: ?*anyopaque = null,
    drop_registered: bool = false,
    on_resize: ?opts_mod.ResizeHandler = null,
    on_resize_ctx: ?*anyopaque = null,
    on_focus: ?opts_mod.FocusHandler = null,
    on_focus_ctx: ?*anyopaque = null,
    on_close: ?opts_mod.CloseHandler = null,
    on_close_ctx: ?*anyopaque = null,
    hwnd: HWND = null,
    menu: HMENU = null,
    accel: HACCEL = null,
    controller: ?*Ctrl = null,
    webview: ?*Wv2 = null,
    environment: ?*Env = null,
    env_handler: IEnvCreatedHandler,
    ctrl_handler: ICtrlCreatedHandler,
    msg_handler: IMessageReceivedHandler,
    res_handler: IResourceRequestedHandler,
    drop_target: IDropTarget,
    /// Server-side UIA provider answering `WM_GETOBJECT`; back-pointer to
    /// this ctx so `GetPropertyValue` reads the live a11y strings below.
    a11y_provider: RawElementProvider,
    /// Accessibility metadata published through the UIA provider. Owned by
    /// `allocator`; freed on `WM_DESTROY`.
    a11y_role_desc: ?[]u8 = null,
    a11y_help: ?[]u8 = null,
    a11y_subrole: opts_mod.AccessibilitySubrole = .standard,
    /// Fullscreen state cache. `fullscreen` flag + saved style/rect
    /// let `setFullscreen(false)` restore the pre-fullscreen window
    /// without the caller threading state back.
    fullscreen: bool = false,
    saved_style: c_long = 0,
    saved_rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    /// Min/max size constraints applied via `WM_GETMINMAXINFO` in
    /// wndProc. `0` means "no constraint" (unbounded). Defaults
    /// leave the OS at its defaults (no per-window constraint).
    min_width: u32 = 0,
    min_height: u32 = 0,
    max_width: u32 = 0,
    max_height: u32 = 0,
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

/// Expose the underlying HWND of a `Window`. Used by sibling modules
/// (`tray.zig`) that need the raw HWND to plug into Win32 APIs which
/// route through `Shell_NotifyIconW` / `SendMessageW` etc. Lives on
/// the backend so the cross-platform `Window` struct stays opaque.
pub fn hwndOf(window: *Window) ?*anyopaque {
    return @ptrCast(window.ctx.hwnd);
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
            .env_handler = .{ .lpVtbl = &env_created_handler_vtbl, .ctx = heap },
            .ctrl_handler = .{ .lpVtbl = &ctrl_created_handler_vtbl, .ctx = heap },
            .msg_handler = .{ .lpVtbl = &message_handler_vtbl, .ctx = heap },
            .res_handler = .{ .lpVtbl = &resource_handler_vtbl, .ctx = heap },
            .drop_target = .{ .lpVtbl = &drop_target_vtbl, .ctx = heap },
            .a11y_provider = .{ .lpVtbl = &raw_element_provider_vtbl, .ctx = heap },
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

        if (opts.install_default_menu) {
            installDefaultMenuBar(heap);
        }

        if (opts.on_drag_drop != null) {
            // `RegisterDragDrop` requires OleInitialize on the calling
            // thread. Idempotent — repeat calls return RPC_E_CHANGED_MODE
            // / S_FALSE, both of which are non-fatal here.
            _ = OleInitialize(null);
            const dd_hr = RegisterDragDrop(hwnd, &heap.drop_target);
            if (dd_hr >= 0) {
                heap.drop_registered = true;
            } else {
                std.log.warn("verve.desktop[windows]: RegisterDragDrop failed (hr=0x{x:0>8})", .{@as(u32, @bitCast(dd_hr))});
            }
        }

        _ = ShowWindow(hwnd, SW_SHOW);
        _ = UpdateWindow(hwnd);

        std.log.info("verve.desktop[windows]: HWND created ({d}x{d})", .{ opts.width, opts.height });

        // Async — actual webview creation runs in the env/controller
        // completion handlers below.
        std.log.debug("verve.desktop[windows]: CreateCoreWebView2EnvironmentWithOptions", .{});
        // Register the app's custom URL scheme so WebView2 (Chromium) will
        // navigate to `<scheme>://app/...` — without this the page is blank.
        const env_options = customSchemeOptions(opts.scheme);
        const hr = CreateCoreWebView2EnvironmentWithOptions(null, null, env_options, &heap.env_handler);
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

    /// System clipboard handle. Win32 clipboard is process-global; the
    /// per-window scoping just gives API parity with `cookies()`.
    pub fn clipboard(self: *Window) clipboard_mod.Clipboard {
        return .{ .window = @ptrCast(self) };
    }

    /// Register a callback fired when Windows broadcasts
    /// `WM_SETTINGCHANGE` with `lParam == "ImmersiveColorSet"` — the
    /// standard signal a light/dark theme toggle was applied. wndProc
    /// hooks the message and dispatches to the registered handler
    /// after re-reading the registry. Passing `null` clears the
    /// handler.
    pub fn setColorSchemeHandler(self: *Window, cb: ?opts_mod.ColorSchemeHandler, ctx: ?*anyopaque) void {
        self.ctx.on_color_scheme = cb;
        self.ctx.on_color_scheme_ctx = ctx;
    }

    /// Register a deep-link URL handler. Windows ships only the
    /// receive-side wiring in this pass — cold-launch (OS spawns the
    /// app with the URL in argv) is the supported delivery path,
    /// driven by the template's argv parser feeding through
    /// `deliverUrl`. Warm-launch URL forwarding via WM_COPYDATA from
    /// a second instance to the running window is a follow-up.
    pub fn setUrlOpenHandler(self: *Window, cb: ?opts_mod.UrlOpenHandler, ctx: ?*anyopaque) void {
        self.ctx.on_url_open = cb;
        self.ctx.on_url_open_ctx = ctx;
    }

    /// Install / replace the drag-drop handler. Registers the HWND as
    /// a drop target via `RegisterDragDrop` on first non-null call;
    /// later calls just swap the callback fields. Setting `null`
    /// revokes the registration.
    /// Trigger the platform print dialog. Thin wrapper over
    /// `printWithOptions(.{})`; preserved for backward compat.
    /// Swallows the underlying error.
    pub fn print(self: *Window) void {
        self.printWithOptions(.{}) catch {};
    }

    /// Native print dialog via `ICoreWebView2_16::ShowPrintUI`.
    /// Returns `error.Unsupported` when the Edge WebView2 runtime is
    /// older than version 111 (March 2023) — the older runtime
    /// answers `E_NOINTERFACE` to the QI for `ICoreWebView2_16`.
    ///
    /// `opts.copies`, `opts.pages`, and `opts.printer_name` are
    /// **advisory** on Windows today — `ShowPrintUI` doesn't accept
    /// a PrintSettings struct; the user picks values from the
    /// dialog. The framework logs a warning when those fields are
    /// non-default so apps can see the behavior gap. Full silent
    /// print with PrintSettings would route through
    /// `ICoreWebView2_16::Print` + `ICoreWebView2Environment6::CreatePrintSettings`
    /// + a `ICoreWebView2PrintCompletedHandler` COM impostor — a
    /// future bundle that needs a Windows host to validate the
    /// vtable slot indexes against the actual SDK headers.
    pub fn printWithOptions(self: *Window, opts: opts_mod.PrintOptions) opts_mod.PrintError!void {
        const wv = self.ctx.webview orelse return opts_mod.PrintError.Backend;

        if (opts.copies > 1 or opts.pages != null or opts.printer_name != null) {
            std.log.warn("verve.desktop[windows]: opts.copies/pages/printer_name are advisory — ShowPrintUI doesn't accept PrintSettings. User picks in the dialog.", .{});
        }

        var wv16_raw: ?*anyopaque = null;
        const QI = vtSlot(*const fn (*Wv2, *const IID, *?*anyopaque) callconv(.winapi) HRESULT, wv.lpVtbl, 0);
        const qhr = QI(wv, &IID_ICoreWebView2_16, &wv16_raw);
        if (qhr < 0 or wv16_raw == null) {
            std.log.warn("verve.desktop[windows]: QI ICoreWebView2_16 failed (hr=0x{x}); runtime too old", .{qhr});
            return opts_mod.PrintError.Unsupported;
        }
        const wv16: *Wv2_16 = @ptrCast(@alignCast(wv16_raw.?));
        defer releaseRef(@ptrCast(wv16));

        const kind: c_int = switch (opts.kind) {
            .default, .browser => PRINT_DIALOG_KIND_BROWSER,
            .system => PRINT_DIALOG_KIND_SYSTEM,
        };
        const Show = vtSlot(*const fn (*Wv2_16, c_int) callconv(.winapi) HRESULT, wv16.lpVtbl, SLOT_WV2_16_ShowPrintUI);
        const hr = Show(wv16, kind);
        if (hr < 0) {
            std.log.warn("verve.desktop[windows]: ShowPrintUI(kind={d}) hr=0x{x}", .{ kind, hr });
            return opts_mod.PrintError.Backend;
        }
        std.log.info("verve.desktop[windows]: ShowPrintUI(kind={d}) ok", .{kind});
    }

    /// The window's accessible Name (what screen readers read on focus)
    /// comes from the window text, so the label channel delegates to
    /// `setTitle`; the default host provider re-publishes it as the UIA
    /// Name. Role-description / subrole / help ride the dedicated UIA
    /// provider below.
    pub fn setAccessibilityLabel(self: *Window, label: []const u8) void {
        self.setTitle(label);
    }

    /// Publish UIA help text (`UIA_HelpTextPropertyId`) for the window
    /// root. Read live by the provider; assistive tech picks it up on the
    /// next query.
    pub fn setAccessibilityHelp(self: *Window, text: []const u8) void {
        setCtxA11yString(self.ctx, &self.ctx.a11y_help, text);
    }

    /// Override the spoken role name (`UIA_LocalizedControlTypePropertyId`)
    /// via the UIA provider.
    pub fn setAccessibilityRoleDescription(self: *Window, text: []const u8) void {
        setCtxA11yString(self.ctx, &self.ctx.a11y_role_desc, text);
    }

    /// Set the window's accessibility subrole. `dialog` / `system_dialog`
    /// surface as `UIA_IsDialogPropertyId == true` through the provider so
    /// assistive tech announces the window as a dialog.
    pub fn setAccessibilitySubrole(self: *Window, subrole: opts_mod.AccessibilitySubrole) void {
        self.ctx.a11y_subrole = subrole;
    }

    /// Toggle topmost via `SetWindowPos(HWND_TOPMOST | HWND_NOTOPMOST)`.
    pub fn setAlwaysOnTop(self: *Window, on: bool) void {
        const HWND_TOPMOST: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
        const HWND_NOTOPMOST: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));
        const SWP_NOMOVE: UINT = 0x0002;
        const SWP_NOSIZE: UINT = 0x0001;
        _ = SetWindowPos(
            self.ctx.hwnd,
            if (on) HWND_TOPMOST else HWND_NOTOPMOST,
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE,
        );
    }

    /// Window opacity in `[0.0, 1.0]`. Stamps `WS_EX_LAYERED` into
    /// the extended style (idempotent — `GetWindowLongPtrW` then OR)
    /// and applies the alpha via `SetLayeredWindowAttributes(LWA_ALPHA)`.
    pub fn setOpacity(self: *Window, value: f64) void {
        const GWL_EXSTYLE: c_int = -20;
        const WS_EX_LAYERED: c_long = 0x00080000;
        const LWA_ALPHA: DWORD = 0x2;
        const cur = GetWindowLongPtrW(self.ctx.hwnd, GWL_EXSTYLE);
        if ((cur & WS_EX_LAYERED) == 0) {
            _ = SetWindowLongPtrW(self.ctx.hwnd, GWL_EXSTYLE, cur | WS_EX_LAYERED);
        }
        const clamped = std.math.clamp(value, 0.0, 1.0);
        const alpha_byte: u8 = @intFromFloat(clamped * 255.0);
        _ = SetLayeredWindowAttributes(self.ctx.hwnd, 0, alpha_byte, LWA_ALPHA);
    }

    pub fn setSize(self: *Window, width: u32, height: u32) void {
        const SWP_NOMOVE: UINT = 0x0002;
        const SWP_NOZORDER: UINT = 0x0004;
        _ = SetWindowPos(self.ctx.hwnd, null, 0, 0, @intCast(width), @intCast(height), SWP_NOMOVE | SWP_NOZORDER);
    }

    pub fn setPosition(self: *Window, x: i32, y: i32) void {
        const SWP_NOSIZE: UINT = 0x0001;
        const SWP_NOZORDER: UINT = 0x0004;
        _ = SetWindowPos(self.ctx.hwnd, null, @intCast(x), @intCast(y), 0, 0, SWP_NOSIZE | SWP_NOZORDER);
    }

    pub fn center(self: *Window) void {
        // Read the window's current size, the work-area rect of the
        // primary monitor, then SetWindowPos to the centered origin.
        var rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        _ = GetWindowRect(self.ctx.hwnd, &rect);
        const w = rect.right - rect.left;
        const h = rect.bottom - rect.top;
        const SM_CXSCREEN: c_int = 0;
        const SM_CYSCREEN: c_int = 1;
        const screen_w = GetSystemMetrics(SM_CXSCREEN);
        const screen_h = GetSystemMetrics(SM_CYSCREEN);
        const SWP_NOSIZE: UINT = 0x0001;
        const SWP_NOZORDER: UINT = 0x0004;
        _ = SetWindowPos(
            self.ctx.hwnd,
            null,
            @divTrunc(screen_w - w, 2),
            @divTrunc(screen_h - h, 2),
            0,
            0,
            SWP_NOSIZE | SWP_NOZORDER,
        );
    }

    pub fn minimize(self: *Window) void {
        const SW_MINIMIZE: c_int = 6;
        _ = ShowWindow(self.ctx.hwnd, SW_MINIMIZE);
    }

    pub fn maximize(self: *Window) void {
        const SW_MAXIMIZE: c_int = 3;
        _ = ShowWindow(self.ctx.hwnd, SW_MAXIMIZE);
    }

    pub fn restore(self: *Window) void {
        const SW_RESTORE: c_int = 9;
        _ = ShowWindow(self.ctx.hwnd, SW_RESTORE);
    }

    /// True fullscreen on Win32 = strip `WS_OVERLAPPEDWINDOW`, expand
    /// to the monitor's full bounds. Stash the previous style + rect
    /// in `WindowCtx` so restoring works without the caller passing
    /// state back. The flag below is the previous-state cached on
    /// the ctx; non-zero = currently fullscreen.
    pub fn show(self: *Window) void {
        _ = ShowWindow(self.ctx.hwnd, SW_SHOW);
        _ = SetForegroundWindow(self.ctx.hwnd);
    }

    pub fn hide(self: *Window) void {
        const SW_HIDE: c_int = 0;
        _ = ShowWindow(self.ctx.hwnd, SW_HIDE);
    }

    pub fn focus(self: *Window) void {
        const SW_RESTORE: c_int = 9;
        _ = ShowWindow(self.ctx.hwnd, SW_RESTORE);
        _ = SetForegroundWindow(self.ctx.hwnd);
    }

    /// Toggle the `WS_THICKFRAME` style bit (resize handles) +
    /// `WS_MAXIMIZEBOX` (max button). `SetWindowPos` with
    /// `SWP_FRAMECHANGED` repaints the title-bar so the changes are
    /// visible without a restart.
    pub fn setResizeHandler(self: *Window, cb: ?opts_mod.ResizeHandler, ctx: ?*anyopaque) void {
        self.ctx.on_resize = cb;
        self.ctx.on_resize_ctx = ctx;
    }

    pub fn setFocusHandler(self: *Window, cb: ?opts_mod.FocusHandler, ctx: ?*anyopaque) void {
        self.ctx.on_focus = cb;
        self.ctx.on_focus_ctx = ctx;
    }

    pub fn setCloseHandler(self: *Window, cb: ?opts_mod.CloseHandler, ctx: ?*anyopaque) void {
        self.ctx.on_close = cb;
        self.ctx.on_close_ctx = ctx;
    }

    /// Constraints honored by wndProc's WM_GETMINMAXINFO case. `(0, 0)`
    /// clears (no constraint).
    pub fn setMinSize(self: *Window, width: u32, height: u32) void {
        self.ctx.min_width = width;
        self.ctx.min_height = height;
    }

    pub fn setMaxSize(self: *Window, width: u32, height: u32) void {
        self.ctx.max_width = width;
        self.ctx.max_height = height;
    }

    pub fn reload(self: *Window) void {
        const wv = self.ctx.webview orelse return;
        const Reload = vtSlot(*const fn (*Wv2) callconv(.winapi) HRESULT, wv.lpVtbl, SLOT_WV2_Reload);
        _ = Reload(wv);
    }

    pub fn goBack(self: *Window) void {
        const wv = self.ctx.webview orelse return;
        const GoBack = vtSlot(*const fn (*Wv2) callconv(.winapi) HRESULT, wv.lpVtbl, SLOT_WV2_GoBack);
        _ = GoBack(wv);
    }

    pub fn goForward(self: *Window) void {
        const wv = self.ctx.webview orelse return;
        const GoForward = vtSlot(*const fn (*Wv2) callconv(.winapi) HRESULT, wv.lpVtbl, SLOT_WV2_GoForward);
        _ = GoForward(wv);
    }

    pub fn canGoBack(self: *Window) bool {
        const wv = self.ctx.webview orelse return false;
        const G = vtSlot(*const fn (*Wv2, *BOOL) callconv(.winapi) HRESULT, wv.lpVtbl, SLOT_WV2_get_CanGoBack);
        var out: BOOL = 0;
        _ = G(wv, &out);
        return out != 0;
    }

    pub fn canGoForward(self: *Window) bool {
        const wv = self.ctx.webview orelse return false;
        const G = vtSlot(*const fn (*Wv2, *BOOL) callconv(.winapi) HRESULT, wv.lpVtbl, SLOT_WV2_get_CanGoForward);
        var out: BOOL = 0;
        _ = G(wv, &out);
        return out != 0;
    }

    pub fn currentUrl(self: *Window, allocator: std.mem.Allocator) ![]u8 {
        const wv = self.ctx.webview orelse return allocator.dupe(u8, "");
        return wv2StringGetter(wv, SLOT_WV2_get_Source, allocator);
    }

    pub fn currentTitle(self: *Window, allocator: std.mem.Allocator) ![]u8 {
        const wv = self.ctx.webview orelse return allocator.dupe(u8, "");
        return wv2StringGetter(wv, SLOT_WV2_get_DocumentTitle, allocator);
    }

    pub fn setZoom(self: *Window, level: f64) void {
        const ctrl = self.ctx.controller orelse return;
        const Put = vtSlot(*const fn (*Ctrl, f64) callconv(.winapi) HRESULT, ctrl.lpVtbl, SLOT_CTRL_put_ZoomFactor);
        _ = Put(ctrl, level);
    }

    pub fn getZoom(self: *Window) f64 {
        const ctrl = self.ctx.controller orelse return 1.0;
        const Get = vtSlot(*const fn (*Ctrl, *f64) callconv(.winapi) HRESULT, ctrl.lpVtbl, SLOT_CTRL_get_ZoomFactor);
        var out: f64 = 1.0;
        _ = Get(ctrl, &out);
        return out;
    }

    /// HiDPI scale of the window's monitor. `GetDpiForWindow`
    /// reports the actual per-window DPI value on Win10 1607+;
    /// divide by 96 (the standard "unscaled" DPI) for the
    /// multiplier most apps actually want.
    pub fn scaleFactor(self: *Window) f32 {
        const dpi = GetDpiForWindow(self.ctx.hwnd);
        return @as(f32, @floatFromInt(dpi)) / 96.0;
    }

    /// Flash the taskbar entry. `critical = true` → flash until
    /// the user clicks (FLASHW_TIMERNOFG). `false` → flash a
    /// fixed count then stop.
    pub fn isMinimized(self: *Window) bool {
        return IsIconic(self.ctx.hwnd) != 0;
    }

    pub fn isMaximized(self: *Window) bool {
        return IsZoomed(self.ctx.hwnd) != 0;
    }

    pub fn isFullscreen(self: *Window) bool {
        return self.ctx.fullscreen;
    }

    pub fn requestAttention(self: *Window, critical: bool) void {
        const FLASHW_ALL: u32 = 0x3;
        const FLASHW_TIMERNOFG: u32 = 0xC;
        var fwi: FLASHWINFO = .{};
        fwi.cbSize = @sizeOf(FLASHWINFO);
        fwi.hwnd = self.ctx.hwnd;
        fwi.dwFlags = if (critical) FLASHW_ALL | FLASHW_TIMERNOFG else FLASHW_ALL;
        fwi.uCount = if (critical) 0 else 5;
        fwi.dwTimeout = 0;
        _ = FlashWindowEx(&fwi);
    }

    pub fn setResizable(self: *Window, on: bool) void {
        const GWL_STYLE: c_int = -16;
        const WS_THICKFRAME: c_long = 0x00040000;
        const WS_MAXIMIZEBOX: c_long = 0x00010000;
        const SWP_NOMOVE: UINT = 0x0002;
        const SWP_NOSIZE: UINT = 0x0001;
        const SWP_NOZORDER: UINT = 0x0004;
        const SWP_FRAMECHANGED: UINT = 0x0020;
        const mask = WS_THICKFRAME | WS_MAXIMIZEBOX;
        const cur = GetWindowLongPtrW(self.ctx.hwnd, GWL_STYLE);
        const next: c_long = if (on) cur | mask else cur & ~mask;
        _ = SetWindowLongPtrW(self.ctx.hwnd, GWL_STYLE, next);
        _ = SetWindowPos(self.ctx.hwnd, null, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
    }

    pub fn setFullscreen(self: *Window, on: bool) void {
        const GWL_STYLE: c_int = -16;
        const WS_OVERLAPPEDWINDOW_VAL: c_long = 0x00CF0000;
        const SWP_NOZORDER: UINT = 0x0004;
        const SWP_FRAMECHANGED: UINT = 0x0020;
        const SM_CXSCREEN: c_int = 0;
        const SM_CYSCREEN: c_int = 1;
        if (on) {
            if (self.ctx.fullscreen) return;
            // Save current style + bounds.
            self.ctx.saved_style = GetWindowLongPtrW(self.ctx.hwnd, GWL_STYLE);
            _ = GetWindowRect(self.ctx.hwnd, &self.ctx.saved_rect);
            _ = SetWindowLongPtrW(
                self.ctx.hwnd,
                GWL_STYLE,
                self.ctx.saved_style & ~WS_OVERLAPPEDWINDOW_VAL,
            );
            const sw = GetSystemMetrics(SM_CXSCREEN);
            const sh = GetSystemMetrics(SM_CYSCREEN);
            _ = SetWindowPos(self.ctx.hwnd, null, 0, 0, sw, sh, SWP_NOZORDER | SWP_FRAMECHANGED);
            self.ctx.fullscreen = true;
        } else {
            if (!self.ctx.fullscreen) return;
            _ = SetWindowLongPtrW(self.ctx.hwnd, GWL_STYLE, self.ctx.saved_style);
            const r = self.ctx.saved_rect;
            _ = SetWindowPos(
                self.ctx.hwnd,
                null,
                r.left,
                r.top,
                r.right - r.left,
                r.bottom - r.top,
                SWP_NOZORDER | SWP_FRAMECHANGED,
            );
            self.ctx.fullscreen = false;
        }
    }

    pub fn setDragDropHandler(self: *Window, cb: ?opts_mod.DragDropHandler, ctx: ?*anyopaque) void {
        self.ctx.on_drag_drop = cb;
        self.ctx.on_drag_drop_ctx = ctx;
        if (cb == null) {
            if (self.ctx.drop_registered) {
                _ = RevokeDragDrop(self.ctx.hwnd);
                self.ctx.drop_registered = false;
            }
            return;
        }
        if (self.ctx.drop_registered) return;
        _ = OleInitialize(null);
        const hr = RegisterDragDrop(self.ctx.hwnd, &self.ctx.drop_target);
        if (hr >= 0) self.ctx.drop_registered = true;
    }

    /// Synthesize a URL delivery — call the registered handler with
    /// `url`. Used by templates to feed argv-derived cold-launch URLs
    /// through the same callback the future WM_COPYDATA receiver
    /// will eventually drive.
    pub fn deliverUrl(self: *Window, url: []const u8) void {
        if (self.ctx.on_url_open) |cb| cb(self.ctx.on_url_open_ctx, url);
    }

    /// Read `HKCU\…\Personalize\AppsUseLightTheme`. The key only
    /// exists on Windows 10 1809+; absence falls back to .unknown.
    pub fn colorScheme(self: *Window) opts_mod.ColorScheme {
        _ = self;
        return readColorSchemeRegistry();
    }

    pub fn run(self: *Window) void {
        _ = self;
        var msg: MSG = undefined;
        while (GetMessageW(&msg, null, 0, 0) > 0) {
            // Route the keystroke through the per-window accelerator
            // table first. `TranslateAcceleratorW` returns non-zero
            // when the message was consumed (becomes a `WM_COMMAND`)
            // — fall through to dispatch only otherwise. `msg.hwnd`
            // is the foreground HWND for keyboard messages, so the
            // simple lookup is the correct match. Dialog / modal HWNDs
            // have no ctx entry so `accel` stays null and the early-
            // out matches the pre-menu behavior.
            const accel: HACCEL = if (msg.hwnd) |h| blk: {
                const cx = lookupCtx(h) orelse break :blk null;
                break :blk cx.accel;
            } else null;
            if (accel != null and TranslateAcceleratorW(msg.hwnd, accel, &msg) != 0) continue;
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
        return runFileDialogWindows(self, allocator, opts, .open);
    }

    pub fn saveFileDialog(self: *Window, allocator: std.mem.Allocator, opts: opts_mod.FileDialogOptions) opts_mod.DialogError![]u8 {
        return runFileDialogWindows(self, allocator, opts, .save);
    }

    /// Modal alert via `MessageBoxW`. Win32 doesn't honor arbitrary
    /// button labels — the surface accepts up to three buttons and
    /// maps the count onto MB_OK / MB_YESNO / MB_YESNOCANCEL, then
    /// translates the return code back into the caller's button index
    /// (0 = first button). The custom label strings in `opts.buttons`
    /// are ignored on Windows; macOS honors them. Document accordingly.
    pub fn showAlert(self: *Window, opts: opts_mod.AlertOptions) usize {
        const icon: UINT = switch (opts.style) {
            .informational => MB_ICONINFORMATION,
            .warning => MB_ICONWARNING,
            .critical => MB_ICONERROR,
        };
        const button_count: usize = if (opts.buttons.len == 0) 1 else opts.buttons.len;
        const button_flag: UINT = switch (button_count) {
            1 => MB_OK,
            2 => MB_YESNO,
            else => MB_YESNOCANCEL,
        };

        var msg_buf: [1024]u16 = undefined;
        var title_buf: [256]u16 = undefined;

        const msg_ptr: LPCWSTR = if (opts.message.len > 0) blk: {
            const w = std.unicode.utf8ToUtf16Le(&msg_buf, opts.message) catch break :blk null;
            const idx = @min(msg_buf.len - 1, w);
            msg_buf[idx] = 0;
            break :blk @ptrCast(&msg_buf);
        } else null;

        const title_ptr: LPCWSTR = if (opts.title.len > 0) blk: {
            const w = std.unicode.utf8ToUtf16Le(&title_buf, opts.title) catch break :blk null;
            const idx = @min(title_buf.len - 1, w);
            title_buf[idx] = 0;
            break :blk @ptrCast(&title_buf);
        } else null;

        const hwnd: HWND = self.ctx.hwnd;
        const ret = MessageBoxW(hwnd, msg_ptr, title_ptr, button_flag | icon);
        // Map Win32 return codes back to button index in opts.buttons order.
        // Single-button case: IDOK → 0. Two-button: IDYES → 0, IDNO → 1.
        // Three-button: IDYES → 0, IDNO → 1, IDCANCEL → 2.
        return switch (button_count) {
            1 => 0,
            2 => switch (ret) {
                IDYES => 0,
                IDNO => 1,
                else => 0,
            },
            else => switch (ret) {
                IDYES => 0,
                IDNO => 1,
                IDCANCEL => 2,
                else => 0,
            },
        };
    }

    /// Capture the WebView2 contents as PNG. The runtime exposes the
    /// PNG encoder via `ICoreWebView2::CapturePreview`, which writes
    /// into a caller-supplied IStream and signals completion through
    /// a COM handler. Sync-wrap with a nested Win32 message pump —
    /// same pattern as the cookie store and the original macOS
    /// snapshot path. Reads the resulting stream into a buffer and
    /// writes it to disk with `CreateFileW` + `WriteFile`.
    pub fn takeSnapshotPng(self: *Window, path: []const u8) opts_mod.SnapshotError!void {
        const wv = self.ctx.webview orelse return opts_mod.SnapshotError.Unsupported;

        var stream: ?*IStreamW = null;
        // CreateStreamOnHGlobal(NULL, TRUE, ...) gives us a growable
        // HGLOBAL-backed stream that frees its memory on Release.
        if (CreateStreamOnHGlobal(null, 1, &stream) < 0) return opts_mod.SnapshotError.CaptureFailed;
        const stm = stream orelse return opts_mod.SnapshotError.CaptureFailed;
        defer releaseRef(@ptrCast(stm));

        var done = false;
        var err: HRESULT = 0;
        var handler: ICapturePreviewCompletedHandler = .{
            .lpVtbl = &capture_preview_handler_vtbl,
            .done = &done,
            .error_code = &err,
        };

        const capture = vtSlot(
            *const fn (*Wv2, c_int, ?*IStreamW, *const ICapturePreviewCompletedHandler) callconv(.winapi) HRESULT,
            wv.lpVtbl,
            SLOT_WV2_CapturePreview,
        );
        const hr = capture(wv, COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT_PNG, stm, &handler);
        if (hr < 0) return opts_mod.SnapshotError.CaptureFailed;

        pumpMsgUntilDone(&done);
        if (err < 0) return opts_mod.SnapshotError.CaptureFailed;

        // Read stream into a heap buffer. Stat → Seek(0) → Read.
        var stat: STATSTG = .{};
        const istat = vtSlot(*const fn (*IStreamW, *STATSTG, DWORD) callconv(.winapi) HRESULT, stm.lpVtbl, SLOT_IStream_Stat);
        if (istat(stm, &stat, STATFLAG_NONAME) < 0) return opts_mod.SnapshotError.EncodeFailed;
        if (stat.cbSize == 0) return opts_mod.SnapshotError.EncodeFailed;
        if (stat.cbSize > std.math.maxInt(usize)) return opts_mod.SnapshotError.EncodeFailed;

        const iseek = vtSlot(*const fn (*IStreamW, i64, DWORD, ?*u64) callconv(.winapi) HRESULT, stm.lpVtbl, SLOT_IStream_Seek);
        if (iseek(stm, 0, STREAM_SEEK_SET, null) < 0) return opts_mod.SnapshotError.EncodeFailed;

        const size: usize = @intCast(stat.cbSize);
        const buf = self.ctx.allocator.alloc(u8, size) catch return opts_mod.SnapshotError.EncodeFailed;
        defer self.ctx.allocator.free(buf);

        const iread = vtSlot(*const fn (*IStreamW, ?[*]u8, DWORD, ?*DWORD) callconv(.winapi) HRESULT, stm.lpVtbl, SLOT_IStream_Read);
        var read_total: usize = 0;
        while (read_total < size) {
            const chunk: DWORD = @intCast(@min(@as(usize, std.math.maxInt(DWORD)), size - read_total));
            var got: DWORD = 0;
            if (iread(stm, buf.ptr + read_total, chunk, &got) < 0) return opts_mod.SnapshotError.EncodeFailed;
            if (got == 0) break;
            read_total += got;
        }
        if (read_total != size) return opts_mod.SnapshotError.EncodeFailed;

        // Write to disk via Win32. UTF-8 → UTF-16, CreateFileW, WriteFile.
        var path_w: [1024]u16 = undefined;
        const w_len = std.unicode.utf8ToUtf16Le(&path_w, path) catch return opts_mod.SnapshotError.WriteFailed;
        if (w_len >= path_w.len) return opts_mod.SnapshotError.WriteFailed;
        path_w[w_len] = 0;

        const handle = CreateFileW(@ptrCast(&path_w), GENERIC_WRITE, FILE_SHARE_READ, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
        if (handle == INVALID_HANDLE_VALUE) return opts_mod.SnapshotError.WriteFailed;
        defer _ = CloseHandle(handle);

        var written: DWORD = 0;
        var off: usize = 0;
        while (off < size) {
            const chunk: DWORD = @intCast(@min(@as(usize, std.math.maxInt(DWORD)), size - off));
            if (WriteFile(handle, buf.ptr + off, chunk, &written, null) == 0) return opts_mod.SnapshotError.WriteFailed;
            if (written == 0) return opts_mod.SnapshotError.WriteFailed;
            off += written;
        }
    }
};

const FileDialogKind = enum { open, save };

fn runFileDialogWindows(
    self: *Window,
    allocator: std.mem.Allocator,
    opts: opts_mod.FileDialogOptions,
    kind: FileDialogKind,
) opts_mod.DialogError![]u8 {
    // pick_directory isn't natively supported by GetOpenFileNameW
    // (Win32 splits dir-picking into IFileOpenDialog). Surface a clear
    // error so callers know to use a different API on Windows until
    // the IFileDialog port lands.
    if (kind == .open and opts.pick_directory) return opts_mod.DialogError.Unsupported;

    const PATH_BUF_LEN: usize = std.fs.max_path_bytes; // 4096 on x86_64
    var file_buf = allocator.alloc(u16, PATH_BUF_LEN) catch return opts_mod.DialogError.OutOfMemory;
    defer allocator.free(file_buf);
    @memset(file_buf, 0);

    // Pre-populate save dialogs with the default name so the picker
    // opens with a sane suggestion.
    if (kind == .save and opts.default_name.len > 0) {
        const written = std.unicode.utf8ToUtf16Le(file_buf, opts.default_name) catch return opts_mod.DialogError.PathTooLong;
        if (written < file_buf.len) file_buf[written] = 0;
    }

    var title_buf: [256]u16 = undefined;
    @memset(&title_buf, 0);
    const title_ptr: LPCWSTR = if (opts.title.len > 0) blk: {
        const w = std.unicode.utf8ToUtf16Le(&title_buf, opts.title) catch break :blk null;
        const idx = @min(title_buf.len - 1, w);
        title_buf[idx] = 0;
        break :blk @ptrCast(&title_buf);
    } else null;

    var initial_dir_buf: [1024]u16 = undefined;
    @memset(&initial_dir_buf, 0);
    const initial_dir_ptr: LPCWSTR = if (opts.default_path.len > 0) blk: {
        const w = std.unicode.utf8ToUtf16Le(&initial_dir_buf, opts.default_path) catch break :blk null;
        const idx = @min(initial_dir_buf.len - 1, w);
        initial_dir_buf[idx] = 0;
        break :blk @ptrCast(&initial_dir_buf);
    } else null;

    // Filter string format: null-separated pairs, double-null
    // terminated. Each pair is "<description>\0<pattern>\0". Example:
    //   "Allowed types\0*.txt;*.json\0\0"
    var filter_buf: [512]u16 = undefined;
    @memset(&filter_buf, 0);
    const filter_ptr: LPCWSTR = if (opts.allowed_extensions.len > 0) blk: {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        // Zig 0.16: std.ArrayList is unmanaged — the allocator is passed
        // per call, not bound at init.
        var pattern_buf: std.ArrayList(u8) = .empty;
        for (opts.allowed_extensions, 0..) |ext, i| {
            if (i > 0) pattern_buf.append(a, ';') catch break :blk null;
            pattern_buf.appendSlice(a, "*.") catch break :blk null;
            pattern_buf.appendSlice(a, ext) catch break :blk null;
        }
        const description = "Allowed types";
        var idx: usize = 0;
        const w1 = std.unicode.utf8ToUtf16Le(filter_buf[idx..], description) catch break :blk null;
        idx += w1;
        if (idx >= filter_buf.len - 3) break :blk null;
        filter_buf[idx] = 0;
        idx += 1;
        const w2 = std.unicode.utf8ToUtf16Le(filter_buf[idx..], pattern_buf.items) catch break :blk null;
        idx += w2;
        if (idx >= filter_buf.len - 2) break :blk null;
        filter_buf[idx] = 0;
        idx += 1;
        filter_buf[idx] = 0;
        break :blk @ptrCast(&filter_buf);
    } else null;

    var ofn: OPENFILENAMEW = .{
        .lStructSize = @sizeOf(OPENFILENAMEW),
        .hwndOwner = self.ctx.hwnd,
        .lpstrFile = @ptrCast(file_buf.ptr),
        .nMaxFile = @intCast(file_buf.len),
        .lpstrFilter = filter_ptr,
        .lpstrInitialDir = initial_dir_ptr,
        .lpstrTitle = title_ptr,
        .Flags = OFN_EXPLORER | switch (kind) {
            .open => OFN_PATHMUSTEXIST | OFN_FILEMUSTEXIST | (if (opts.allow_multiple) OFN_ALLOWMULTISELECT else @as(DWORD, 0)),
            .save => OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST,
        },
    };

    const ok = switch (kind) {
        .open => GetOpenFileNameW(&ofn),
        .save => GetSaveFileNameW(&ofn),
    };
    if (ok == 0) return opts_mod.DialogError.Cancelled;

    // The result is a UTF-16 null-terminated string. Multi-select
    // mode returns a different format (dir\0file1\0file2\0\0) that
    // we don't unpack here — callers asking for multi-select get the
    // raw dir string today; full multi-select parsing is a follow-up.
    var utf16_len: usize = 0;
    while (utf16_len < file_buf.len and file_buf[utf16_len] != 0) : (utf16_len += 1) {}

    const utf8_buf = allocator.alloc(u8, utf16_len * 3 + 1) catch return opts_mod.DialogError.OutOfMemory;
    errdefer allocator.free(utf8_buf);
    const utf8_len = std.unicode.utf16LeToUtf8(utf8_buf, file_buf[0..utf16_len]) catch return opts_mod.DialogError.PathTooLong;
    // Shrink to the actual used length. realloc on shrink either
    // returns the same pointer with a smaller len or migrates to a
    // smaller block — failure path propagates as OOM rather than
    // returning an undersized slice that won't free correctly.
    return allocator.realloc(utf8_buf, utf8_len) catch return opts_mod.DialogError.OutOfMemory;
}

fn wndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    switch (msg) {
        WM_GETOBJECT => {
            // Hand assistive tech our server-side UIA provider for the
            // window root; all other object ids fall through to default.
            if (lparam == UiaRootObjectId) {
                if (lookupCtx(hwnd)) |cx| {
                    return UiaReturnRawElementProvider(hwnd, wparam, lparam, @ptrCast(&cx.a11y_provider));
                }
            }
            return DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        WM_SIZE => {
            if (lookupCtx(hwnd)) |cx| {
                // Keep the WebView2 controller filling the client area.
                if (cx.controller) |ctrl| {
                    var rect: RECT = undefined;
                    _ = GetClientRect(hwnd, &rect);
                    const putBounds = vtSlot(*const fn (*Ctrl, RECT) callconv(.winapi) HRESULT, ctrl.lpVtbl, SLOT_CTRL_putBounds);
                    _ = putBounds(ctrl, rect);
                }
                // Then fire the app's resize handler. lParam low word =
                // client-area width, high word = height.
                if (cx.on_resize) |cb| {
                    const lp_u: usize = @bitCast(lparam);
                    const w: u32 = @intCast(lp_u & 0xFFFF);
                    const h: u32 = @intCast((lp_u >> 16) & 0xFFFF);
                    cb(cx.on_resize_ctx, w, h);
                }
            }
            return 0;
        },
        WM_SETTINGCHANGE => {
            // lParam → LPCWSTR area name; Windows fires
            // `ImmersiveColorSet` when the user toggles the theme via
            // Settings → Personalization → Colors. wParam is unused
            // on this branch (it carries the SPI_* code for other
            // setting changes, which we don't act on).
            if (lparam != 0) {
                if (lookupCtx(hwnd)) |cx| if (cx.on_color_scheme) |cb| {
                    const area_ptr: [*:0]const u16 = @ptrFromInt(@as(usize, @bitCast(lparam)));
                    var len: usize = 0;
                    while (area_ptr[len] != 0) : (len += 1) {}
                    var utf8_buf: [128]u8 = undefined;
                    const written = std.unicode.utf16LeToUtf8(&utf8_buf, area_ptr[0..len]) catch return 0;
                    if (std.mem.eql(u8, utf8_buf[0..written], "ImmersiveColorSet")) {
                        cb(cx.on_color_scheme_ctx, readColorSchemeRegistry());
                    }
                };
            }
            return 0;
        },
        WM_COPYDATA => {
            // Deep-link URL handoff from a second instance. The
            // `dwData` sentinel guards against random WM_COPYDATA
            // traffic from other processes. Payload is UTF-8 URL bytes
            // with no terminator.
            if (lparam == 0) return 0;
            const cds: *const COPYDATASTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (cds.dwData != URL_COPYDATA_SENTINEL) return 0;
            if (cds.cbData == 0) return 0;
            if (cds.cbData > 4096) return 0;
            const data_ptr = cds.lpData orelse return 0;
            const url_ptr: [*]const u8 = @ptrCast(data_ptr);
            const url = url_ptr[0..cds.cbData];
            if (lookupCtx(hwnd)) |cx| if (cx.on_url_open) |cb| {
                cb(cx.on_url_open_ctx, url);
            };
            return 1;
        },
        WM_COMMAND => {
            // Default menu commands. Only File→Quit fires real work;
            // Edit items intentionally fall through to no-op so the
            // OOP WebView2 host keeps handling Ctrl+C/V/X/Z/Y/A itself.
            // Quit posts WM_CLOSE rather than PostQuitMessage so the
            // standard close path runs — last-window-quit semantics
            // route through the registry count in WM_DESTROY below.
            // Tray menu IDs (`0xC000` block) are forwarded into
            // `tray.zig` via the optional dispatcher registered when a
            // tray exists.
            const id: u16 = @truncate(wparam & 0xFFFF);
            if (id == ID_FILE_QUIT) {
                _ = SendMessageW(hwnd, WM_CLOSE, 0, 0);
            } else if ((id & 0xF000) == 0xC000) {
                if (tray_dispatch_command) |dispatch| _ = dispatch(@ptrCast(hwnd), id);
            }
            return 0;
        },
        WM_VERVE_TRAY => {
            // Shell32 fires this on tray-icon mouse events; the
            // forwarder is installed by `tray.zig` on first `Tray.init`.
            // No-op if no tray was created in this process.
            if (tray_dispatch_message) |dispatch| dispatch(@ptrCast(hwnd), wparam, lparam);
            return 0;
        },
        WM_ACTIVATE => {
            // wParam low word: 0 = inactive (focus lost),
            // 1 = active by-non-mouse, 2 = activated by click.
            if (lookupCtx(hwnd)) |cx| if (cx.on_focus) |cb| {
                const state: u32 = @as(u32, @intCast(wparam & 0xFFFF));
                cb(cx.on_focus_ctx, state != 0);
            };
            return 0;
        },
        WM_GETMINMAXINFO => {
            // Caller hasn't called setMinSize / setMaxSize? Fall
            // through to default behavior.
            const cx = lookupCtx(hwnd) orelse return DefWindowProcW(hwnd, msg, wparam, lparam);
            if (cx.min_width == 0 and cx.min_height == 0 and cx.max_width == 0 and cx.max_height == 0) {
                return DefWindowProcW(hwnd, msg, wparam, lparam);
            }
            const mmi: *MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (cx.min_width != 0) mmi.ptMinTrackSize.x = @intCast(cx.min_width);
            if (cx.min_height != 0) mmi.ptMinTrackSize.y = @intCast(cx.min_height);
            if (cx.max_width != 0) mmi.ptMaxTrackSize.x = @intCast(cx.max_width);
            if (cx.max_height != 0) mmi.ptMaxTrackSize.y = @intCast(cx.max_height);
            return 0;
        },
        WM_CLOSE => {
            // User clicked the title-bar X (or System menu → Close).
            // Run the close handler if present; non-true return
            // suppresses the standard close path. Without a handler,
            // fall through to DefWindowProc which calls DestroyWindow.
            if (lookupCtx(hwnd)) |cx| if (cx.on_close) |cb| {
                if (!cb(cx.on_close_ctx)) return 0;
            };
            return DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        WM_DESTROY => {
            // Multi-window quit: unregister this HWND, only post
            // WM_QUIT when the last live window destroys. Win32 has
            // no equivalent of NSApp's automatic last-window tracking
            // so the registry size IS the live-window count.
            if (lookupCtx(hwnd)) |cx| {
                if (cx.accel) |a| {
                    _ = DestroyAcceleratorTable(a);
                    cx.accel = null;
                }
                if (cx.drop_registered) {
                    _ = RevokeDragDrop(hwnd);
                    cx.drop_registered = false;
                }
                if (cx.a11y_role_desc) |s| {
                    cx.allocator.free(s);
                    cx.a11y_role_desc = null;
                }
                if (cx.a11y_help) |s| {
                    cx.allocator.free(s);
                    cx.a11y_help = null;
                }
            }
            unregisterCtx(hwnd);
            if (registry.count() == 0) PostQuitMessage(0);
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// Build + install the default File + Edit menu bar for `ctx.hwnd`.
/// Stores the HMENU and HACCEL on the ctx so `WM_DESTROY` can free
/// the accelerator table (the HMENU is freed transitively when the
/// window is destroyed). Failures are non-fatal — the window opens
/// menu-less and logs at debug level.
fn installDefaultMenuBar(ctx: *WindowCtx) void {
    const bar = CreateMenu() orelse {
        std.log.debug("verve.desktop[windows]: CreateMenu failed", .{});
        return;
    };
    const file_menu = CreatePopupMenu() orelse {
        _ = DestroyMenu(bar);
        return;
    };
    const edit_menu = CreatePopupMenu() orelse {
        _ = DestroyMenu(file_menu);
        _ = DestroyMenu(bar);
        return;
    };

    // `\t` in the menu label tells Win32 to right-align the rest of
    // the text as the shortcut hint, matching the standard look.
    _ = AppendMenuW(file_menu, MF_STRING, ID_FILE_QUIT, wstr("&Quit\tCtrl+Q"));
    _ = AppendMenuW(bar, MF_POPUP, @intCast(@intFromPtr(file_menu)), wstr("&File"));

    _ = AppendMenuW(edit_menu, MF_STRING, ID_EDIT_UNDO, wstr("&Undo\tCtrl+Z"));
    _ = AppendMenuW(edit_menu, MF_STRING, ID_EDIT_REDO, wstr("&Redo\tCtrl+Y"));
    _ = AppendMenuW(edit_menu, MF_SEPARATOR, 0, null);
    _ = AppendMenuW(edit_menu, MF_STRING, ID_EDIT_CUT, wstr("Cu&t\tCtrl+X"));
    _ = AppendMenuW(edit_menu, MF_STRING, ID_EDIT_COPY, wstr("&Copy\tCtrl+C"));
    _ = AppendMenuW(edit_menu, MF_STRING, ID_EDIT_PASTE, wstr("&Paste\tCtrl+V"));
    _ = AppendMenuW(edit_menu, MF_STRING, ID_EDIT_SELECT_ALL, wstr("Select &All\tCtrl+A"));
    _ = AppendMenuW(bar, MF_POPUP, @intCast(@intFromPtr(edit_menu)), wstr("&Edit"));

    if (SetMenu(ctx.hwnd, bar) == 0) {
        _ = DestroyMenu(bar);
        return;
    }
    ctx.menu = bar;

    // Only Quit gets an accelerator-table entry. Edit shortcuts are
    // intentionally absent so the WebView2 OOP host keeps owning
    // them — adding an accel-table entry would route the key through
    // `WM_COMMAND` first and break clipboard inside HTML inputs.
    const accels = [_]ACCEL{
        .{ .fVirt = FVIRTKEY | FCONTROL, .key = 'Q', .cmd = ID_FILE_QUIT },
    };
    ctx.accel = CreateAcceleratorTableW(&accels, accels.len);
}

/// Compile-time UTF-16 literal helper for menu labels. Wraps
/// `std.unicode.utf8ToUtf16LeStringLiteral` so the call sites stay
/// short and the cast to `LPCWSTR` is implicit.
fn wstr(comptime s: []const u8) LPCWSTR {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

/// Module-level color-scheme reader used by both `Window.colorScheme`
/// and the WM_SETTINGCHANGE handler. Encapsulates the registry probe
/// so the message path doesn't depend on having a `*Window`.
fn readColorSchemeRegistry() opts_mod.ColorScheme {
    const subkey = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize");
    const value = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");
    var data: DWORD = 0;
    var size: DWORD = @sizeOf(DWORD);
    const r = RegGetValueW(HKEY_CURRENT_USER, subkey, value, RRF_RT_REG_DWORD, null, &data, &size);
    if (r != ERROR_SUCCESS) return .unknown;
    return if (data == 0) .dark else .light;
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

const drop_target_vtbl: IDropTargetVtbl = .{
    .QueryInterface = @ptrCast(&comQI),
    .AddRef = @ptrCast(&comAddRef),
    .Release = @ptrCast(&comRelease),
    .DragEnter = &dropEnter,
    .DragOver = &dropOver,
    .DragLeave = &dropLeave,
    .Drop = &dropPerform,
};

fn dropEnter(_this: ?*const IDropTarget, _data: *IDataObject, _ks: DWORD, _pt: POINTL, effect: *DWORD) callconv(.winapi) HRESULT {
    _ = _this;
    _ = _data;
    _ = _ks;
    _ = _pt;
    effect.* = DROPEFFECT_COPY;
    return 0;
}

fn dropOver(_this: ?*const IDropTarget, _ks: DWORD, _pt: POINTL, effect: *DWORD) callconv(.winapi) HRESULT {
    _ = _this;
    _ = _ks;
    _ = _pt;
    effect.* = DROPEFFECT_COPY;
    return 0;
}

fn dropLeave(_this: ?*const IDropTarget) callconv(.winapi) HRESULT {
    _ = _this;
    return 0;
}

fn dropPerform(this: ?*const IDropTarget, dataObj: *IDataObject, _ks: DWORD, _pt: POINTL, effect: *DWORD) callconv(.winapi) HRESULT {
    _ = _ks;
    _ = _pt;
    effect.* = DROPEFFECT_NONE;
    const self = this orelse return 0;
    const ctx = self.ctx;
    const cb = ctx.on_drag_drop orelse return 0;

    var fmt: FORMATETC = .{
        .cfFormat = CF_HDROP,
        .ptd = null,
        .dwAspect = DVASPECT_CONTENT,
        .lindex = -1,
        .tymed = TYMED_HGLOBAL,
    };
    var medium: STGMEDIUM = .{ .tymed = 0, .handle = null, .pUnkForRelease = null };

    const GetData = vtSlot(
        *const fn (*IDataObject, *const FORMATETC, *STGMEDIUM) callconv(.winapi) HRESULT,
        dataObj.lpVtbl,
        SLOT_IDataObject_GetData,
    );
    const hr = GetData(dataObj, &fmt, &medium);
    if (hr < 0) return 0;
    defer ReleaseStgMedium(&medium);

    const hdrop = medium.handle orelse return 0;

    const SENTINEL_COUNT: UINT = 0xFFFFFFFF;
    const n = DragQueryFileW(hdrop, SENTINEL_COUNT, null, 0);
    if (n == 0) return 0;

    var gpa = std.heap.page_allocator;
    var paths_buf = gpa.alloc([]const u8, n) catch return 0;
    defer gpa.free(paths_buf);
    var owned: usize = 0;
    defer {
        var i: usize = 0;
        while (i < owned) : (i += 1) gpa.free(paths_buf[i]);
    }

    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const wlen = DragQueryFileW(hdrop, i, null, 0);
        const w_buf = gpa.alloc(u16, wlen + 1) catch {
            paths_buf[i] = "";
            continue;
        };
        defer gpa.free(w_buf);
        _ = DragQueryFileW(hdrop, i, w_buf.ptr, @intCast(w_buf.len));
        var u8_buf = gpa.alloc(u8, @as(usize, wlen) * 4) catch {
            paths_buf[i] = "";
            continue;
        };
        const u8_len = std.unicode.utf16LeToUtf8(u8_buf, w_buf[0..wlen]) catch {
            gpa.free(u8_buf);
            paths_buf[i] = "";
            continue;
        };
        const final = gpa.realloc(u8_buf, u8_len) catch u8_buf[0..u8_len];
        paths_buf[i] = final;
        owned += 1;
    }

    cb(ctx.on_drag_drop_ctx, paths_buf);
    effect.* = DROPEFFECT_COPY;
    return 0;
}

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
    // Prefer ICoreWebView2_22's source-kinds filter so the TOP-LEVEL document
    // request of the custom scheme is intercepted (the legacy filter only sees
    // sub-resources → blank page). Fall back to the legacy filter on runtimes
    // that predate _22 (which also predate custom schemes, so they were never
    // going to render anyway, but keep the call for parity).
    var wv22_raw: ?*anyopaque = null;
    const QI22 = vtSlot(*const fn (*Wv2, *const IID, *?*anyopaque) callconv(.winapi) HRESULT, wv.?.lpVtbl, 0);
    const qi22_hr = QI22(wv.?, &IID_ICoreWebView2_22, &wv22_raw);
    if (qi22_hr >= 0 and wv22_raw != null) {
        const wv22: *Wv2_22 = @ptrCast(@alignCast(wv22_raw.?));
        defer releaseRef(@ptrCast(wv22));
        const addFilterSK = vtSlot(*const fn (*Wv2_22, LPCWSTR, c_int, u32) callconv(.winapi) HRESULT, wv22.lpVtbl, SLOT_WV2_22_AddWebResourceRequestedFilterWithRequestSourceKinds);
        _ = addFilterSK(wv22, @ptrCast(&filter_buf), COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL, COREWEBVIEW2_WEB_RESOURCE_REQUEST_SOURCE_KINDS_ALL);
    } else {
        // Pre-_22 runtime: best-effort legacy filter (covers sub-resources only).
        const addFilter = vtSlot(*const fn (*Wv2, LPCWSTR, c_int) callconv(.winapi) HRESULT, wv.?.lpVtbl, SLOT_WV2_AddWebResourceRequestedFilter);
        _ = addFilter(wv.?, @ptrCast(&filter_buf), COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);
    }

    const addResource = vtSlot(*const fn (*Wv2, *const IResourceRequestedHandler, *anyopaque) callconv(.winapi) HRESULT, wv.?.lpVtbl, SLOT_WV2_add_WebResourceRequested);
    var token2: i64 = 0;
    _ = addResource(wv.?, &cx.res_handler, @ptrCast(&token2));

    // Initial navigation through the custom scheme; the resource handler
    // serves the embedded asset bytes.
    if (cx.opts.initial_path.len > 0) {
        const gpa = std.heap.page_allocator;
        const utf8 = std.fmt.allocPrint(gpa, "{s}://app/{s}", .{ cx.opts.scheme, cx.opts.initial_path }) catch return 0;
        defer gpa.free(utf8);
        const w_url = std.unicode.utf8ToUtf16LeAllocZ(gpa, utf8) catch return 0;
        defer gpa.free(w_url);
        const Navigate = vtSlot(*const fn (*Wv2, LPCWSTR) callconv(.winapi) HRESULT, wv.?.lpVtbl, SLOT_WV2_Navigate);
        const nav_hr = Navigate(wv.?, w_url.ptr);
        if (nav_hr < 0) std.log.warn("verve.desktop[windows]: Navigate '{s}' failed hr=0x{x:0>8}", .{ utf8, @as(u32, @bitCast(nav_hr)) });
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
    const payload = buf[0..utf8_len];
    // Intercept the title-sync marker before forwarding.
    const title_prefix = "__verve_title:";
    if (std.mem.startsWith(u8, payload, title_prefix)) {
        const title = payload[title_prefix.len..];
        var title_buf: [512]u16 = undefined;
        const tlen = std.unicode.utf8ToUtf16Le(&title_buf, title) catch return 0;
        title_buf[@min(title_buf.len - 1, tlen)] = 0;
        _ = SetWindowTextW(cx.hwnd, @ptrCast(&title_buf));
        return 0;
    }
    if (cx.on_message) |handler| handler(cx.on_message_ctx, payload);
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

    const resolved = blk: {
        if (cx.opts.dev_assets) |dev| {
            break :blk router.resolveWithFallback(cx.allocator, dev.io, cx.opts.assets, path, dev.dir) catch {
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
        }
        break :blk router.resolve(cx.opts.assets, path) catch {
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
    };
    defer resolved.deinit(cx.allocator);

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

fn onCapturePreviewDone(self: ?*const ICapturePreviewCompletedHandler, error_code: HRESULT) callconv(.winapi) HRESULT {
    const handler = self orelse return 0;
    handler.error_code.* = error_code;
    handler.done.* = true;
    return 0;
}

const capture_preview_handler_vtbl: ICapturePreviewCompletedHandlerVtbl = .{
    .QueryInterface = @ptrCast(&comQI),
    .AddRef = @ptrCast(&comAddRef),
    .Release = @ptrCast(&comRelease),
    .Invoke = &onCapturePreviewDone,
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

// ---- Clipboard --------------------------------------------------------------
//
// Win32 clipboard is owned process-globally. Acquire via
// `OpenClipboard(hwnd)`, mutate, `CloseClipboard()`. For text we use
// CF_UNICODETEXT (UTF-16LE, NUL-terminated) — the SetClipboardData
// path transfers ownership of an HGLOBAL to the system, which then
// frees it on the next EmptyClipboard.

pub fn clipboardWriteText(window: *anyopaque, text: []const u8) opts_mod.ClipboardError!void {
    const self: *Window = @ptrCast(@alignCast(window));

    // Worst-case UTF-16 length is text.len + 1 (per code unit on input;
    // bmp covers everything below U+10000 in a single u16, surrogates
    // expand to two). The +1 is the NUL terminator.
    const cap = text.len + 1;
    const handle = GlobalAlloc(GMEM_MOVEABLE, cap * 2) orelse return opts_mod.ClipboardError.OutOfMemory;
    errdefer _ = GlobalFree(handle);

    const locked = GlobalLock(handle) orelse {
        _ = GlobalFree(handle);
        return opts_mod.ClipboardError.Backend;
    };
    const utf16_buf: [*]u16 = @ptrCast(@alignCast(locked));
    const w_len = std.unicode.utf8ToUtf16Le(utf16_buf[0..cap], text) catch {
        _ = GlobalUnlock(handle);
        _ = GlobalFree(handle);
        return opts_mod.ClipboardError.Backend;
    };
    if (w_len >= cap) {
        _ = GlobalUnlock(handle);
        _ = GlobalFree(handle);
        return opts_mod.ClipboardError.Backend;
    }
    utf16_buf[w_len] = 0;
    _ = GlobalUnlock(handle);

    if (OpenClipboard(self.ctx.hwnd) == 0) return opts_mod.ClipboardError.Backend;
    defer _ = CloseClipboard();

    if (EmptyClipboard() == 0) return opts_mod.ClipboardError.Backend;
    // SetClipboardData takes ownership; only free on failure.
    if (SetClipboardData(CF_UNICODETEXT, handle) == null) {
        _ = GlobalFree(handle);
        return opts_mod.ClipboardError.Backend;
    }
}

pub fn clipboardReadText(window: *anyopaque, allocator: std.mem.Allocator) opts_mod.ClipboardError!?[]u8 {
    const self: *Window = @ptrCast(@alignCast(window));

    if (IsClipboardFormatAvailable(CF_UNICODETEXT) == 0) return null;
    if (OpenClipboard(self.ctx.hwnd) == 0) return opts_mod.ClipboardError.Backend;
    defer _ = CloseClipboard();

    const handle = GetClipboardData(CF_UNICODETEXT) orelse return null;
    const locked = GlobalLock(handle) orelse return opts_mod.ClipboardError.Backend;
    defer _ = GlobalUnlock(handle);

    const total_bytes = GlobalSize(handle);
    if (total_bytes < 2) return null;
    const utf16_max_len = total_bytes / 2;

    const utf16_buf: [*]const u16 = @ptrCast(@alignCast(locked));
    // Walk until NUL or buffer end.
    var w_len: usize = 0;
    while (w_len < utf16_max_len and utf16_buf[w_len] != 0) : (w_len += 1) {}
    if (w_len == 0) return null;

    const out = allocator.alloc(u8, w_len * 3) catch return opts_mod.ClipboardError.OutOfMemory;
    errdefer allocator.free(out);
    const written = std.unicode.utf16LeToUtf8(out, utf16_buf[0..w_len]) catch return opts_mod.ClipboardError.Backend;
    return allocator.realloc(out, written) catch return opts_mod.ClipboardError.OutOfMemory;
}

// CF_HTML clipboard support — Microsoft-specific header format that
// nests the fragment inside a minimal `<html><body>` shell with byte
// offsets pointing at the fragment boundaries. The format ID is
// dynamic (assigned per process via RegisterClipboardFormatW("HTML
// Format")), unlike the static CF_* values for text/bitmap.
//
// Spec: https://learn.microsoft.com/en-us/windows/win32/dataxchg/html-clipboard-format

const CF_HTML_NAME = std.unicode.utf8ToUtf16LeStringLiteral("HTML Format");

fn cfHtmlFormatId() UINT {
    // Idempotent — repeated calls return the same registered ID. No
    // memoization needed; lookup is a fast table read in user32.
    return RegisterClipboardFormatW(CF_HTML_NAME);
}

pub fn clipboardWriteHtml(window: *anyopaque, html: []const u8) opts_mod.ClipboardError!void {
    const self: *Window = @ptrCast(@alignCast(window));

    // Build the CF_HTML payload. Header offsets are zero-padded to 10
    // ASCII digits each so we can compute the total length up front:
    //
    //   Version:0.9\r\n
    //   StartHTML:0000000XXX\r\n
    //   EndHTML:0000000XXX\r\n
    //   StartFragment:0000000XXX\r\n
    //   EndFragment:0000000XXX\r\n
    //   <html>\r\n<body>\r\n<!--StartFragment-->
    //   <fragment>
    //   <!--EndFragment-->\r\n</body>\r\n</html>
    //
    // Offsets are byte counts from the start of the buffer.
    const header_template =
        "Version:0.9\r\n" ++
        "StartHTML:0000000000\r\n" ++
        "EndHTML:0000000000\r\n" ++
        "StartFragment:0000000000\r\n" ++
        "EndFragment:0000000000\r\n";
    const html_prefix = "<html>\r\n<body>\r\n<!--StartFragment-->";
    const html_suffix = "<!--EndFragment-->\r\n</body>\r\n</html>";

    const start_html = header_template.len;
    const start_fragment = start_html + html_prefix.len;
    const end_fragment = start_fragment + html.len;
    const end_html = end_fragment + html_suffix.len;

    const total = end_html;
    const buf = self.ctx.allocator.alloc(u8, total + 1) catch return opts_mod.ClipboardError.OutOfMemory;
    defer self.ctx.allocator.free(buf);

    @memcpy(buf[0..header_template.len], header_template);
    writeOffset(buf, "StartHTML:", start_html);
    writeOffset(buf, "EndHTML:", end_html);
    writeOffset(buf, "StartFragment:", start_fragment);
    writeOffset(buf, "EndFragment:", end_fragment);
    @memcpy(buf[start_html..][0..html_prefix.len], html_prefix);
    @memcpy(buf[start_fragment..][0..html.len], html);
    @memcpy(buf[end_fragment..][0..html_suffix.len], html_suffix);
    buf[total] = 0;

    const handle = GlobalAlloc(GMEM_MOVEABLE, total + 1) orelse return opts_mod.ClipboardError.OutOfMemory;
    errdefer _ = GlobalFree(handle);

    const locked = GlobalLock(handle) orelse {
        _ = GlobalFree(handle);
        return opts_mod.ClipboardError.Backend;
    };
    const dst: [*]u8 = @ptrCast(@alignCast(locked));
    @memcpy(dst[0 .. total + 1], buf[0 .. total + 1]);
    _ = GlobalUnlock(handle);

    if (OpenClipboard(self.ctx.hwnd) == 0) return opts_mod.ClipboardError.Backend;
    defer _ = CloseClipboard();
    if (EmptyClipboard() == 0) return opts_mod.ClipboardError.Backend;

    const fmt = cfHtmlFormatId();
    if (fmt == 0) return opts_mod.ClipboardError.Backend;
    if (SetClipboardData(fmt, handle) == null) {
        _ = GlobalFree(handle);
        return opts_mod.ClipboardError.Backend;
    }
}

/// Patch a 10-digit zero-padded offset into `buf` immediately after
/// the literal `label` (which is part of `header_template`). Caller
/// has already populated `buf[0..header_template.len]` with the
/// template; we just overwrite the `0000000000` placeholder bytes.
fn writeOffset(buf: []u8, label: []const u8, offset: usize) void {
    const idx = std.mem.indexOf(u8, buf, label) orelse return;
    const digits_start = idx + label.len;
    var n = offset;
    var i: usize = 10;
    while (i > 0) : (i -= 1) {
        buf[digits_start + i - 1] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
    }
}

pub fn clipboardReadHtml(window: *anyopaque, allocator: std.mem.Allocator) opts_mod.ClipboardError!?[]u8 {
    const self: *Window = @ptrCast(@alignCast(window));

    const fmt = cfHtmlFormatId();
    if (fmt == 0) return opts_mod.ClipboardError.Backend;
    if (IsClipboardFormatAvailable(fmt) == 0) return null;
    if (OpenClipboard(self.ctx.hwnd) == 0) return opts_mod.ClipboardError.Backend;
    defer _ = CloseClipboard();

    const handle = GetClipboardData(fmt) orelse return null;
    const locked = GlobalLock(handle) orelse return opts_mod.ClipboardError.Backend;
    defer _ = GlobalUnlock(handle);

    const total = GlobalSize(handle);
    if (total == 0) return null;
    const src: [*]const u8 = @ptrCast(@alignCast(locked));
    const bytes = src[0..total];

    // Parse StartFragment / EndFragment offsets out of the header.
    // Producers that wrap the fragment differently (Google Chrome,
    // Word, etc.) all agree on the header format; only the fragment
    // bytes vary.
    const start = parseOffset(bytes, "StartFragment:") orelse return opts_mod.ClipboardError.Backend;
    const end = parseOffset(bytes, "EndFragment:") orelse return opts_mod.ClipboardError.Backend;
    if (start >= end or end > total) return opts_mod.ClipboardError.Backend;

    const fragment = bytes[start..end];
    return allocator.dupe(u8, fragment) catch return opts_mod.ClipboardError.OutOfMemory;
}

// ---- Image clipboard (CF_DIBV5 via WIC) ------------------------------------
//
// The cross-platform wire format is raw PNG bytes (macOS parity). The
// Windows clipboard image format is a DIB: `CF_DIBV5` (BITMAPV5HEADER,
// carries an alpha channel) on write, `CF_DIBV5` || `CF_DIB` on read.
// PNG <-> 32bpp-BGRA transcoding goes through WIC (`windowscodecs`) — the
// pure byte<->DIB plumbing (`buildDibV5` / `dibToBgra`) is factored out so
// it is unit-testable without a live COM stack.
//
// COM objects here are short-lived per call; we CoInitialize best-effort
// (the WebView2 thread has usually already initialised an apartment, so
// `S_FALSE` / `RPC_E_CHANGED_MODE` are expected and ignored) and Release
// every interface on the way out via the shared `releaseRef` helper.

extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, coinit: DWORD) callconv(.winapi) HRESULT;
extern "ole32" fn CoCreateInstance(
    rclsid: *const GUID,
    unk_outer: ?*anyopaque,
    cls_context: DWORD,
    riid: *const GUID,
    ppv: *?*anyopaque,
) callconv(.winapi) HRESULT;
extern "ole32" fn GetHGlobalFromStream(pstm: *IStreamW, phglobal: *?*anyopaque) callconv(.winapi) HRESULT;
// `CreateStreamOnHGlobal` and `SHCreateMemStream` are declared above
// (CapturePreview path) — reused here.

const CLSCTX_INPROC_SERVER: DWORD = 1;
const COINIT_APARTMENTTHREADED: DWORD = 2;
const CF_DIB: UINT = 8;
const CF_DIBV5: UINT = 17;
const BI_RGB: u32 = 0;
const BI_BITFIELDS: u32 = 3;
const LCS_sRGB: u32 = 0x7352_4742; // 'sRGB'
const LCS_GM_IMAGES: u32 = 4;

// WIC enum values (from wincodec.h).
const WICDecodeMetadataCacheOnDemand: c_int = 0;
const WICBitmapDitherTypeNone: c_int = 0;
const WICBitmapPaletteTypeCustom: c_int = 0;
const WICBitmapEncoderNoCache: c_int = 2;

const CLSID_WICImagingFactory: GUID = .{ .Data1 = 0xcacaf262, .Data2 = 0x9370, .Data3 = 0x4615, .Data4 = .{ 0xa1, 0x3b, 0x9f, 0x55, 0x39, 0xda, 0x4c, 0x0a } };
const IID_IWICImagingFactory: GUID = .{ .Data1 = 0xec5ec8a9, .Data2 = 0xc395, .Data3 = 0x4314, .Data4 = .{ 0x9c, 0x77, 0x54, 0xd7, 0xa9, 0x35, 0xff, 0x70 } };
const GUID_WICPixelFormat32bppBGRA: GUID = .{ .Data1 = 0x6fddc324, .Data2 = 0x4e03, .Data3 = 0x4bfe, .Data4 = .{ 0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x0f } };
const GUID_ContainerFormatPng: GUID = .{ .Data1 = 0x1b7cfaf4, .Data2 = 0x713f, .Data3 = 0x473c, .Data4 = .{ 0xbb, 0xcd, 0x61, 0x37, 0x42, 0x5f, 0xae, 0xaf } };

// Generic WIC interface handle — every interface we touch begins with an
// `lpVtbl` pointer, so one shape + offset-based `vtSlot` covers them all.
const WicObj = extern struct { lpVtbl: *const anyopaque };

// Vtable slots (wincodec.h; first three are IUnknown).
const SLOT_WICFactory_CreateDecoderFromStream: usize = 4;
const SLOT_WICFactory_CreateEncoder: usize = 8;
const SLOT_WICFactory_CreateFormatConverter: usize = 10;
const SLOT_WICFactory_CreateBitmapFromMemory: usize = 20;
const SLOT_WICSource_GetSize: usize = 3;
const SLOT_WICSource_CopyPixels: usize = 7;
const SLOT_WICDecoder_GetFrame: usize = 13;
const SLOT_WICConverter_Initialize: usize = 8;
const SLOT_WICEncoder_Initialize: usize = 3;
const SLOT_WICEncoder_CreateNewFrame: usize = 10;
const SLOT_WICEncoder_Commit: usize = 11;
const SLOT_WICFrame_Initialize: usize = 3;
const SLOT_WICFrame_SetSize: usize = 4;
const SLOT_WICFrame_WriteSource: usize = 11;
const SLOT_WICFrame_Commit: usize = 12;

const CIEXYZ = extern struct { x: i32 = 0, y: i32 = 0, z: i32 = 0 };
const CIEXYZTRIPLE = extern struct { r: CIEXYZ = .{}, g: CIEXYZ = .{}, b: CIEXYZ = .{} };
const BITMAPV5HEADER = extern struct {
    bV5Size: u32 = 124,
    bV5Width: i32 = 0,
    bV5Height: i32 = 0,
    bV5Planes: u16 = 1,
    bV5BitCount: u16 = 32,
    bV5Compression: u32 = 0,
    bV5SizeImage: u32 = 0,
    bV5XPelsPerMeter: i32 = 0,
    bV5YPelsPerMeter: i32 = 0,
    bV5ClrUsed: u32 = 0,
    bV5ClrImportant: u32 = 0,
    bV5RedMask: u32 = 0,
    bV5GreenMask: u32 = 0,
    bV5BlueMask: u32 = 0,
    bV5AlphaMask: u32 = 0,
    bV5CSType: u32 = 0,
    bV5Endpoints: CIEXYZTRIPLE = .{},
    bV5GammaRed: u32 = 0,
    bV5GammaGreen: u32 = 0,
    bV5GammaBlue: u32 = 0,
    bV5Intent: u32 = 0,
    bV5ProfileData: u32 = 0,
    bV5ProfileSize: u32 = 0,
    bV5Reserved: u32 = 0,
};

comptime {
    // The DIBV5 layout is ABI-fixed at 124 bytes; a mis-sized header
    // means SetClipboardData hands the shell a malformed bitmap.
    if (@sizeOf(BITMAPV5HEADER) != 124) @compileError("BITMAPV5HEADER must be 124 bytes");
}

// Reject absurd dimensions before any width*height*4 allocation so a
// hostile or corrupt DIB can't overflow the size math.
const MAX_IMAGE_BYTES: usize = 256 * 1024 * 1024;

fn wicCreateFactory() ?*WicObj {
    _ = CoInitializeEx(null, COINIT_APARTMENTTHREADED); // best-effort; S_FALSE/changed-mode tolerated
    var factory: ?*anyopaque = null;
    const hr = CoCreateInstance(&CLSID_WICImagingFactory, null, CLSCTX_INPROC_SERVER, &IID_IWICImagingFactory, &factory);
    if (hr < 0 or factory == null) return null;
    return @ptrCast(@alignCast(factory));
}

pub fn clipboardWriteImage(window: *anyopaque, png: []const u8) opts_mod.ClipboardError!void {
    const self: *Window = @ptrCast(@alignCast(window));
    if (png.len == 0) return opts_mod.ClipboardError.Backend;

    const factory = wicCreateFactory() orelse return opts_mod.ClipboardError.Backend;
    defer releaseRef(@ptrCast(factory));

    // PNG bytes -> read IStream (SHCreateMemStream copies the buffer, so
    // `png` need not outlive the call).
    const stream = SHCreateMemStream(png.ptr, @intCast(png.len)) orelse return opts_mod.ClipboardError.Backend;
    defer releaseRef(@ptrCast(stream));

    const CreateDecoder = vtSlot(*const fn (*WicObj, *IStreamW, ?*const GUID, c_int, *?*WicObj) callconv(.winapi) HRESULT, factory.lpVtbl, SLOT_WICFactory_CreateDecoderFromStream);
    var decoder: ?*WicObj = null;
    if (CreateDecoder(factory, stream, null, WICDecodeMetadataCacheOnDemand, &decoder) < 0 or decoder == null) return opts_mod.ClipboardError.Backend;
    defer releaseRef(@ptrCast(decoder.?));

    const GetFrame = vtSlot(*const fn (*WicObj, u32, *?*WicObj) callconv(.winapi) HRESULT, decoder.?.lpVtbl, SLOT_WICDecoder_GetFrame);
    var frame: ?*WicObj = null;
    if (GetFrame(decoder.?, 0, &frame) < 0 or frame == null) return opts_mod.ClipboardError.Backend;
    defer releaseRef(@ptrCast(frame.?));

    // Normalise to 32bpp BGRA regardless of the PNG's native format.
    const CreateConv = vtSlot(*const fn (*WicObj, *?*WicObj) callconv(.winapi) HRESULT, factory.lpVtbl, SLOT_WICFactory_CreateFormatConverter);
    var conv: ?*WicObj = null;
    if (CreateConv(factory, &conv) < 0 or conv == null) return opts_mod.ClipboardError.Backend;
    defer releaseRef(@ptrCast(conv.?));

    const ConvInit = vtSlot(*const fn (*WicObj, *WicObj, *const GUID, c_int, ?*anyopaque, f64, c_int) callconv(.winapi) HRESULT, conv.?.lpVtbl, SLOT_WICConverter_Initialize);
    if (ConvInit(conv.?, frame.?, &GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone, null, 0.0, WICBitmapPaletteTypeCustom) < 0) return opts_mod.ClipboardError.Backend;

    const GetSize = vtSlot(*const fn (*WicObj, *u32, *u32) callconv(.winapi) HRESULT, conv.?.lpVtbl, SLOT_WICSource_GetSize);
    var w: u32 = 0;
    var h: u32 = 0;
    if (GetSize(conv.?, &w, &h) < 0 or w == 0 or h == 0) return opts_mod.ClipboardError.Backend;

    const stride: usize = @as(usize, w) * 4;
    const pixel_bytes: usize = stride * @as(usize, h);
    if (pixel_bytes > MAX_IMAGE_BYTES) return opts_mod.ClipboardError.Backend;

    const bgra = self.ctx.allocator.alloc(u8, pixel_bytes) catch return opts_mod.ClipboardError.OutOfMemory;
    defer self.ctx.allocator.free(bgra);

    const CopyPixels = vtSlot(*const fn (*WicObj, ?*const anyopaque, u32, u32, [*]u8) callconv(.winapi) HRESULT, conv.?.lpVtbl, SLOT_WICSource_CopyPixels);
    if (CopyPixels(conv.?, null, @intCast(stride), @intCast(pixel_bytes), bgra.ptr) < 0) return opts_mod.ClipboardError.Backend;

    // Pack a bottom-up CF_DIBV5 blob (header + reversed rows).
    const dib = buildDibV5(self.ctx.allocator, w, h, bgra) catch return opts_mod.ClipboardError.OutOfMemory;
    defer self.ctx.allocator.free(dib);

    const handle = GlobalAlloc(GMEM_MOVEABLE, dib.len) orelse return opts_mod.ClipboardError.OutOfMemory;
    errdefer _ = GlobalFree(handle);
    const locked = GlobalLock(handle) orelse {
        _ = GlobalFree(handle);
        return opts_mod.ClipboardError.Backend;
    };
    const dst: [*]u8 = @ptrCast(@alignCast(locked));
    @memcpy(dst[0..dib.len], dib);
    _ = GlobalUnlock(handle);

    if (OpenClipboard(self.ctx.hwnd) == 0) return opts_mod.ClipboardError.Backend;
    defer _ = CloseClipboard();
    if (EmptyClipboard() == 0) return opts_mod.ClipboardError.Backend;
    // SetClipboardData takes ownership of the HGLOBAL on success.
    if (SetClipboardData(CF_DIBV5, handle) == null) {
        _ = GlobalFree(handle);
        return opts_mod.ClipboardError.Backend;
    }
}

pub fn clipboardReadImage(window: *anyopaque, allocator: std.mem.Allocator) opts_mod.ClipboardError!?[]u8 {
    const self: *Window = @ptrCast(@alignCast(window));

    const fmt: UINT = if (IsClipboardFormatAvailable(CF_DIBV5) != 0)
        CF_DIBV5
    else if (IsClipboardFormatAvailable(CF_DIB) != 0)
        CF_DIB
    else
        return null;

    if (OpenClipboard(self.ctx.hwnd) == 0) return opts_mod.ClipboardError.Backend;
    defer _ = CloseClipboard();

    const handle = GetClipboardData(fmt) orelse return null;
    const locked = GlobalLock(handle) orelse return opts_mod.ClipboardError.Backend;
    defer _ = GlobalUnlock(handle);
    const total = GlobalSize(handle);
    if (total < 40) return null;
    const src: [*]const u8 = @ptrCast(@alignCast(locked));

    // DIB -> top-down 32bpp BGRA (owned by `allocator`).
    const img = dibToBgra(allocator, src[0..total]) catch |e| switch (e) {
        error.OutOfMemory => return opts_mod.ClipboardError.OutOfMemory,
        else => return opts_mod.ClipboardError.Backend,
    };
    defer allocator.free(img.pixels);

    const factory = wicCreateFactory() orelse return opts_mod.ClipboardError.Backend;
    defer releaseRef(@ptrCast(factory));

    // Wrap the pixels as a WIC bitmap source, then PNG-encode it into a
    // growable HGLOBAL-backed stream.
    const stride: u32 = img.width * 4;
    const buf_size: u32 = stride * img.height;
    const CreateBmp = vtSlot(*const fn (*WicObj, u32, u32, *const GUID, u32, u32, [*]const u8, *?*WicObj) callconv(.winapi) HRESULT, factory.lpVtbl, SLOT_WICFactory_CreateBitmapFromMemory);
    var bitmap: ?*WicObj = null;
    if (CreateBmp(factory, img.width, img.height, &GUID_WICPixelFormat32bppBGRA, stride, buf_size, img.pixels.ptr, &bitmap) < 0 or bitmap == null) return opts_mod.ClipboardError.Backend;
    defer releaseRef(@ptrCast(bitmap.?));

    var ostream: ?*IStreamW = null;
    if (CreateStreamOnHGlobal(null, 1, &ostream) < 0 or ostream == null) return opts_mod.ClipboardError.Backend;
    defer releaseRef(@ptrCast(ostream.?)); // frees the backing HGLOBAL (delete-on-release)

    const CreateEnc = vtSlot(*const fn (*WicObj, *const GUID, ?*const GUID, *?*WicObj) callconv(.winapi) HRESULT, factory.lpVtbl, SLOT_WICFactory_CreateEncoder);
    var encoder: ?*WicObj = null;
    if (CreateEnc(factory, &GUID_ContainerFormatPng, null, &encoder) < 0 or encoder == null) return opts_mod.ClipboardError.Backend;
    defer releaseRef(@ptrCast(encoder.?));

    const EncInit = vtSlot(*const fn (*WicObj, *IStreamW, c_int) callconv(.winapi) HRESULT, encoder.?.lpVtbl, SLOT_WICEncoder_Initialize);
    if (EncInit(encoder.?, ostream.?, WICBitmapEncoderNoCache) < 0) return opts_mod.ClipboardError.Backend;

    const CreateFrame = vtSlot(*const fn (*WicObj, *?*WicObj, *?*anyopaque) callconv(.winapi) HRESULT, encoder.?.lpVtbl, SLOT_WICEncoder_CreateNewFrame);
    var enc_frame: ?*WicObj = null;
    var bag: ?*anyopaque = null;
    if (CreateFrame(encoder.?, &enc_frame, &bag) < 0 or enc_frame == null) return opts_mod.ClipboardError.Backend;
    defer releaseRef(@ptrCast(enc_frame.?));

    const FrameInit = vtSlot(*const fn (*WicObj, ?*anyopaque) callconv(.winapi) HRESULT, enc_frame.?.lpVtbl, SLOT_WICFrame_Initialize);
    if (FrameInit(enc_frame.?, bag) < 0) return opts_mod.ClipboardError.Backend;

    const SetFrameSize = vtSlot(*const fn (*WicObj, u32, u32) callconv(.winapi) HRESULT, enc_frame.?.lpVtbl, SLOT_WICFrame_SetSize);
    if (SetFrameSize(enc_frame.?, img.width, img.height) < 0) return opts_mod.ClipboardError.Backend;

    const WriteSource = vtSlot(*const fn (*WicObj, *WicObj, ?*const anyopaque) callconv(.winapi) HRESULT, enc_frame.?.lpVtbl, SLOT_WICFrame_WriteSource);
    if (WriteSource(enc_frame.?, bitmap.?, null) < 0) return opts_mod.ClipboardError.Backend;

    const FrameCommit = vtSlot(*const fn (*WicObj) callconv(.winapi) HRESULT, enc_frame.?.lpVtbl, SLOT_WICFrame_Commit);
    if (FrameCommit(enc_frame.?) < 0) return opts_mod.ClipboardError.Backend;
    const EncCommit = vtSlot(*const fn (*WicObj) callconv(.winapi) HRESULT, encoder.?.lpVtbl, SLOT_WICEncoder_Commit);
    if (EncCommit(encoder.?) < 0) return opts_mod.ClipboardError.Backend;

    // Pull the encoded PNG straight off the stream's HGLOBAL.
    var hmem: ?*anyopaque = null;
    if (GetHGlobalFromStream(ostream.?, &hmem) < 0 or hmem == null) return opts_mod.ClipboardError.Backend;
    const png_locked = GlobalLock(hmem) orelse return opts_mod.ClipboardError.Backend;
    defer _ = GlobalUnlock(hmem);
    const png_size = GlobalSize(hmem);
    if (png_size == 0) return opts_mod.ClipboardError.Backend;
    const png_src: [*]const u8 = @ptrCast(@alignCast(png_locked));
    return allocator.dupe(u8, png_src[0..png_size]) catch return opts_mod.ClipboardError.OutOfMemory;
}

// ---- Pure DIB <-> BGRA helpers (no COM; unit-testable) ---------------------

/// Pack a top-down 32bpp-BGRA pixel buffer into a `CF_DIBV5` blob:
/// a `BITMAPV5HEADER` (BI_BITFIELDS, explicit BGRA masks, positive height
/// = bottom-up) followed by the rows in bottom-up order. Caller owns the
/// returned slice.
fn buildDibV5(allocator: std.mem.Allocator, w: u32, h: u32, bgra_topdown: []const u8) error{OutOfMemory}![]u8 {
    const stride: usize = @as(usize, w) * 4;
    const pixels: usize = stride * @as(usize, h);
    const out = try allocator.alloc(u8, 124 + pixels);
    errdefer allocator.free(out);

    var hdr: BITMAPV5HEADER = .{};
    hdr.bV5Width = @intCast(w);
    hdr.bV5Height = @intCast(h); // positive => bottom-up rows
    hdr.bV5Compression = BI_BITFIELDS;
    hdr.bV5SizeImage = @intCast(pixels);
    hdr.bV5RedMask = 0x00FF_0000;
    hdr.bV5GreenMask = 0x0000_FF00;
    hdr.bV5BlueMask = 0x0000_00FF;
    hdr.bV5AlphaMask = 0xFF00_0000;
    hdr.bV5CSType = LCS_sRGB;
    hdr.bV5Intent = LCS_GM_IMAGES;
    @memcpy(out[0..124], std.mem.asBytes(&hdr));

    var y: usize = 0;
    while (y < h) : (y += 1) {
        const src_off = y * stride; // top-down source row y
        const dst_off = 124 + (@as(usize, h) - 1 - y) * stride; // bottom-up dest
        @memcpy(out[dst_off..][0..stride], bgra_topdown[src_off..][0..stride]);
    }
    return out;
}

const DibImage = struct { width: u32, height: u32, pixels: []u8 };

/// Decode a packed DIB (`CF_DIB` / `CF_DIBV5` payload) into a top-down
/// 32bpp-BGRA buffer. Supports 24bpp and 32bpp source DIBs (BI_RGB and
/// BI_BITFIELDS); paletted/compressed inputs return `error.Unsupported`.
/// A 32bpp source whose alpha bytes are entirely zero is treated as opaque
/// (the common BGRX-as-BGRA screenshot case). Caller owns `pixels`.
fn dibToBgra(allocator: std.mem.Allocator, bytes: []const u8) error{ OutOfMemory, Unsupported, Malformed }!DibImage {
    if (bytes.len < 40) return error.Malformed;
    const header_size = readU32(bytes, 0);
    if (header_size < 40 or header_size > bytes.len) return error.Malformed;

    const width_raw = readI32(bytes, 4);
    const height_raw = readI32(bytes, 8);
    const bit_count = readU16(bytes, 14);
    const compression = readU32(bytes, 16);
    if (width_raw <= 0 or height_raw == 0) return error.Malformed;
    if (bit_count != 24 and bit_count != 32) return error.Unsupported;

    const top_down = height_raw < 0;
    const width: u32 = @intCast(width_raw);
    const height: u32 = @intCast(if (height_raw < 0) -height_raw else height_raw);

    // Pixel data offset: V4/V5 (>=108) carry their masks inside the
    // header; a 40-byte header with BI_BITFIELDS is followed by three
    // DWORD masks; BI_RGB has no mask/palette block for >8bpp.
    var pixel_off: usize = header_size;
    if (header_size < 108 and compression == BI_BITFIELDS) {
        pixel_off += 12;
    } else if (compression != BI_RGB and compression != BI_BITFIELDS) {
        return error.Unsupported;
    }

    const src_stride: usize = ((@as(usize, bit_count) * width + 31) / 32) * 4; // DWORD-aligned
    const need = pixel_off + src_stride * @as(usize, height);
    if (need > bytes.len) return error.Malformed;

    const dst_stride: usize = @as(usize, width) * 4;
    const dst_bytes: usize = dst_stride * @as(usize, height);
    if (dst_bytes > MAX_IMAGE_BYTES) return error.Malformed;

    const pixels = try allocator.alloc(u8, dst_bytes);
    errdefer allocator.free(pixels);

    var any_alpha = false;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        // Source row index: bottom-up DIBs store the last image row first.
        const src_row = if (top_down) y else (@as(usize, height) - 1 - y);
        const s = bytes[pixel_off + src_row * src_stride ..];
        const d = pixels[y * dst_stride ..];
        var x: usize = 0;
        while (x < width) : (x += 1) {
            if (bit_count == 32) {
                const b = s[x * 4 + 0];
                const g = s[x * 4 + 1];
                const r = s[x * 4 + 2];
                const a = s[x * 4 + 3];
                if (a != 0) any_alpha = true;
                d[x * 4 + 0] = b;
                d[x * 4 + 1] = g;
                d[x * 4 + 2] = r;
                d[x * 4 + 3] = a;
            } else { // 24bpp BGR
                d[x * 4 + 0] = s[x * 3 + 0];
                d[x * 4 + 1] = s[x * 3 + 1];
                d[x * 4 + 2] = s[x * 3 + 2];
                d[x * 4 + 3] = 0xFF;
                any_alpha = true;
            }
        }
    }
    // A 32bpp DIB with no alpha information at all is opaque BGRX.
    if (!any_alpha) {
        var i: usize = 3;
        while (i < pixels.len) : (i += 4) pixels[i] = 0xFF;
    }
    return .{ .width = width, .height = height, .pixels = pixels };
}

fn readU16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}
fn readU32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}
fn readI32(b: []const u8, off: usize) i32 {
    return std.mem.readInt(i32, b[off..][0..4], .little);
}

fn parseOffset(buf: []const u8, label: []const u8) ?usize {
    const idx = std.mem.indexOf(u8, buf, label) orelse return null;
    var i = idx + label.len;
    // Skip optional whitespace; CF_HTML producers vary in padding.
    while (i < buf.len and (buf[i] == ' ' or buf[i] == '\t')) : (i += 1) {}
    var n: usize = 0;
    var saw_digit = false;
    while (i < buf.len and std.ascii.isDigit(buf[i])) : (i += 1) {
        n = n * 10 + (buf[i] - '0');
        saw_digit = true;
    }
    return if (saw_digit) n else null;
}

// ---- WinRT Toast notifications ----------------------------------------------
//
// The modern Action Center toast (vs. the legacy `Shell_NotifyIconW` balloon
// in tray.zig). Three prerequisites the balloon path doesn't have:
//
//   1. An Application User Model ID (AUMID) — the identity a toast is filed
//      under. Set process-wide via `SetCurrentProcessExplicitAppUserModelID`.
//   2. A Start-menu `.lnk` shortcut carrying that same AUMID in its
//      `System.AppUserModel.ID` property — without it the shell silently
//      drops toasts from unpackaged (non-MSIX) apps. Created once.
//   3. WinRT activation: `RoActivateInstance` an `XmlDocument`, load a
//      `ToastGeneric` template, then `ToastNotificationManager` →
//      `IToastNotifier::Show`.
//
// All of this is hand-rolled COM/WinRT over `vtSlot`; the WinRT vtables put
// three IInspectable methods (GetIids/GetRuntimeClassName/GetTrustLevel)
// after IUnknown, so runtime-class methods start at slot 6. Links the WinRT
// API-set stubs (Ro*/Windows*String) + `Shell32`/`Ole32`/`Shlwapi`
// (shortcut). `notifications.show` calls this first and falls back to the
// balloon.

pub const ToastError = error{ Unsupported, Backend, OutOfMemory };

// The WinRT activation + HSTRING entry points are exported by combase.dll,
// but zig's bundled mingw ships no x86_64 `combase` import lib — only the
// split API-set stubs. Link the two that carry our symbols:
//   api-ms-win-core-winrt-l1-1-0        -> Ro* (Initialize/Activate/Factory)
//   api-ms-win-core-winrt-string-l1-1-0 -> Windows*String (HSTRING)
extern "api-ms-win-core-winrt-l1-1-0" fn RoInitialize(init_type: c_int) callconv(.winapi) HRESULT;
extern "api-ms-win-core-winrt-string-l1-1-0" fn WindowsCreateString(src: [*]const u16, len: u32, out: *?*anyopaque) callconv(.winapi) HRESULT;
extern "api-ms-win-core-winrt-string-l1-1-0" fn WindowsDeleteString(str: ?*anyopaque) callconv(.winapi) HRESULT;
extern "api-ms-win-core-winrt-l1-1-0" fn RoGetActivationFactory(class_id: ?*anyopaque, iid: *const IID, factory: *?*anyopaque) callconv(.winapi) HRESULT;
extern "api-ms-win-core-winrt-l1-1-0" fn RoActivateInstance(class_id: ?*anyopaque, instance: *?*anyopaque) callconv(.winapi) HRESULT;
extern "shell32" fn SetCurrentProcessExplicitAppUserModelID(id: [*:0]const u16) callconv(.winapi) HRESULT;
extern "kernel32" fn GetModuleFileNameW(module: HMODULE, buf: [*]u16, size: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: [*]u16, size: DWORD) callconv(.winapi) DWORD;
extern "shlwapi" fn PathFileExistsW(path: [*:0]const u16) callconv(.winapi) BOOL;

const RO_INIT_SINGLETHREADED: c_int = 0;

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

fn comQueryInterface(obj: *WicObj, iid: *const IID, out: *?*anyopaque) HRESULT {
    const QI = vtSlot(*const fn (*WicObj, *const IID, *?*anyopaque) callconv(.winapi) HRESULT, obj.lpVtbl, 0);
    return QI(obj, iid, out);
}

/// Create an HSTRING from a comptime ASCII class id. Caller deletes via
/// `WindowsDeleteString`.
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

/// `RoActivateInstance` a runtime class by comptime id, returning its
/// IInspectable. Caller Releases via `releaseRef`.
fn roActivate(comptime class: []const u8) ?*WicObj {
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

/// Emit the running executable's basename (no directory, `.exe` stripped)
/// as UTF-16 into `out`; returns the length or null on failure. Used to
/// derive a per-app AUMID and shortcut name.
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
    // Strip a trailing ".exe" (case-insensitive).
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

/// Create the AUMID Start-menu shortcut once (idempotent — skips if the
/// `.lnk` already exists). Best-effort: any failure leaves toasts to fall
/// back. `*_z` are NUL-terminated UTF-16.
fn ensureAumidShortcut(exe_z: [*:0]const u16, aumid_z: [*:0]const u16, lnk_z: [*:0]const u16) void {
    if (PathFileExistsW(lnk_z) != 0) return;
    _ = CoInitializeEx(null, COINIT_APARTMENTTHREADED);

    var sl_p: ?*anyopaque = null;
    if (CoCreateInstance(&CLSID_ShellLink, null, CLSCTX_INPROC_SERVER, &IID_IShellLinkW, &sl_p) < 0 or sl_p == null) return;
    const sl: *WicObj = @ptrCast(@alignCast(sl_p));
    defer releaseRef(@ptrCast(sl));

    const SetPath = vtSlot(*const fn (*WicObj, [*:0]const u16) callconv(.winapi) HRESULT, sl.lpVtbl, SLOT_ShellLink_SetPath);
    if (SetPath(sl, exe_z) < 0) return;

    var ps_p: ?*anyopaque = null;
    if (comQueryInterface(sl, &IID_IPropertyStore, &ps_p) < 0 or ps_p == null) return;
    const ps: *WicObj = @ptrCast(@alignCast(ps_p));
    defer releaseRef(@ptrCast(ps));

    var pv: PROPVARIANT = .{ .vt = VT_LPWSTR, .val = @intFromPtr(aumid_z) };
    const SetValue = vtSlot(*const fn (*WicObj, *const PROPERTYKEY, *const PROPVARIANT) callconv(.winapi) HRESULT, ps.lpVtbl, SLOT_PropertyStore_SetValue);
    if (SetValue(ps, &PKEY_AppUserModel_ID, &pv) < 0) return;
    const Commit = vtSlot(*const fn (*WicObj) callconv(.winapi) HRESULT, ps.lpVtbl, SLOT_PropertyStore_Commit);
    _ = Commit(ps);

    var pf_p: ?*anyopaque = null;
    if (comQueryInterface(sl, &IID_IPersistFile, &pf_p) < 0 or pf_p == null) return;
    const pf: *WicObj = @ptrCast(@alignCast(pf_p));
    defer releaseRef(@ptrCast(pf));
    const Save = vtSlot(*const fn (*WicObj, [*:0]const u16, BOOL) callconv(.winapi) HRESULT, pf.lpVtbl, SLOT_PersistFile_Save);
    _ = Save(pf, lnk_z, 1);
}

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
    defer releaseRef(@ptrCast(xml_doc));

    var docio_p: ?*anyopaque = null;
    if (comQueryInterface(xml_doc, &IID_IXmlDocumentIO, &docio_p) < 0 or docio_p == null) return error.Backend;
    const docio: *WicObj = @ptrCast(@alignCast(docio_p));
    defer releaseRef(@ptrCast(docio));

    const xml = buildToastXml(allocator, title, body) catch return error.OutOfMemory;
    defer allocator.free(xml);
    const xml_w = std.unicode.utf8ToUtf16LeAlloc(allocator, xml) catch return error.OutOfMemory;
    defer allocator.free(xml_w);
    const xml_h = winrtString(xml_w) orelse return error.Backend;
    defer _ = WindowsDeleteString(xml_h);

    const LoadXml = vtSlot(*const fn (*WicObj, ?*anyopaque) callconv(.winapi) HRESULT, docio.lpVtbl, SLOT_XmlDocumentIO_LoadXml);
    if (LoadXml(docio, xml_h) < 0) return error.Backend;

    // The XmlDocument as IXmlDocument (what CreateToastNotification wants).
    var doc_p: ?*anyopaque = null;
    if (comQueryInterface(xml_doc, &IID_IXmlDocument, &doc_p) < 0 or doc_p == null) return error.Backend;
    const doc: *WicObj = @ptrCast(@alignCast(doc_p));
    defer releaseRef(@ptrCast(doc));

    // ---- notifier (AUMID) ----
    const mgr_id = hstr("Windows.UI.Notifications.ToastNotificationManager") orelse return error.Backend;
    defer _ = WindowsDeleteString(mgr_id);
    var statics_p: ?*anyopaque = null;
    if (RoGetActivationFactory(mgr_id, &IID_IToastNotificationManagerStatics, &statics_p) < 0 or statics_p == null) return error.Backend;
    const statics: *WicObj = @ptrCast(@alignCast(statics_p));
    defer releaseRef(@ptrCast(statics));

    const aumid_h = winrtString(aumid[0..ai]) orelse return error.Backend;
    defer _ = WindowsDeleteString(aumid_h);
    const CreateNotifier = vtSlot(*const fn (*WicObj, ?*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT, statics.lpVtbl, SLOT_ToastMgr_CreateToastNotifierWithId);
    var notifier_p: ?*anyopaque = null;
    if (CreateNotifier(statics, aumid_h, &notifier_p) < 0 or notifier_p == null) return error.Backend;
    const notifier: *WicObj = @ptrCast(@alignCast(notifier_p));
    defer releaseRef(@ptrCast(notifier));

    // ---- toast from the xml ----
    const toast_id = hstr("Windows.UI.Notifications.ToastNotification") orelse return error.Backend;
    defer _ = WindowsDeleteString(toast_id);
    var tfac_p: ?*anyopaque = null;
    if (RoGetActivationFactory(toast_id, &IID_IToastNotificationFactory, &tfac_p) < 0 or tfac_p == null) return error.Backend;
    const tfac: *WicObj = @ptrCast(@alignCast(tfac_p));
    defer releaseRef(@ptrCast(tfac));

    const CreateToast = vtSlot(*const fn (*WicObj, *WicObj, *?*anyopaque) callconv(.winapi) HRESULT, tfac.lpVtbl, SLOT_ToastFactory_CreateToastNotification);
    var toast_p: ?*anyopaque = null;
    if (CreateToast(tfac, doc, &toast_p) < 0 or toast_p == null) return error.Backend;
    const toast: *WicObj = @ptrCast(@alignCast(toast_p));
    defer releaseRef(@ptrCast(toast));

    const Show = vtSlot(*const fn (*WicObj, *WicObj) callconv(.winapi) HRESULT, notifier.lpVtbl, SLOT_ToastNotifier_Show);
    if (Show(notifier, toast) < 0) return error.Backend;
}

/// Re-resolve the full exe path as a NUL-terminated UTF-16 buffer for the
/// shortcut target. Returns a process-static buffer (single-threaded toast
/// path); falls back to an empty string on failure (SetPath then no-ops).
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

/// XML-escape `&`, `<`, `>`, `"` for safe interpolation into the toast
/// template. Caller owns the result.
fn xmlEscape(allocator: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Build a `ToastGeneric` toast XML payload (title + body). Caller owns the
/// result.
fn buildToastXml(allocator: std.mem.Allocator, title: []const u8, body: []const u8) error{OutOfMemory}![]u8 {
    const et = try xmlEscape(allocator, title);
    defer allocator.free(et);
    const eb = try xmlEscape(allocator, body);
    defer allocator.free(eb);
    return std.fmt.allocPrint(
        allocator,
        "<toast><visual><binding template=\"ToastGeneric\"><text>{s}</text><text>{s}</text></binding></visual></toast>",
        .{ et, eb },
    );
}

// ---- tests (pure DIB helpers; run on a Windows host build) -----------------

const testing = std.testing;

test "buildDibV5: header + bottom-up packing" {
    // 2x2 top-down BGRA: rows [A,B] then [C,D].
    const px = [_]u8{
        1, 2, 3, 4, 5, 6, 7, 8, // row0: A,B
        9, 10, 11, 12, 13, 14, 15, 16, // row1: C,D
    };
    const out = try buildDibV5(testing.allocator, 2, 2, &px);
    defer testing.allocator.free(out);

    try testing.expectEqual(@as(usize, 124 + 16), out.len);
    try testing.expectEqual(@as(u32, 124), readU32(out, 0));
    try testing.expectEqual(@as(i32, 2), readI32(out, 4)); // width
    try testing.expectEqual(@as(i32, 2), readI32(out, 8)); // height (positive => bottom-up)
    try testing.expectEqual(BI_BITFIELDS, readU32(out, 16));
    // Bottom-up: stored row0 == source row1 (C,D).
    try testing.expectEqualSlices(u8, px[8..16], out[124..][0..8]);
    try testing.expectEqualSlices(u8, px[0..8], out[124 + 8 ..][0..8]);
}

test "dibToBgra: round-trips buildDibV5" {
    const px = [_]u8{
        10, 20, 30, 255, 40, 50, 60, 128,
        70, 80, 90, 1,   11, 22, 33, 200,
    };
    const dib = try buildDibV5(testing.allocator, 2, 2, &px);
    defer testing.allocator.free(dib);

    const img = try dibToBgra(testing.allocator, dib);
    defer testing.allocator.free(img.pixels);
    try testing.expectEqual(@as(u32, 2), img.width);
    try testing.expectEqual(@as(u32, 2), img.height);
    try testing.expectEqualSlices(u8, &px, img.pixels);
}

test "dibToBgra: 24bpp BI_RGB with row padding, opaque alpha" {
    // 3x1 24bpp: row stride = ceil(3*24/32)*4 = 12 bytes (1 pad byte).
    var bytes = [_]u8{0} ** (40 + 12);
    std.mem.writeInt(u32, bytes[0..4], 40, .little); // header size
    std.mem.writeInt(i32, bytes[4..8], 3, .little); // width
    std.mem.writeInt(i32, bytes[8..12], -1, .little); // top-down height
    std.mem.writeInt(u16, bytes[14..16], 24, .little); // bitcount
    std.mem.writeInt(u32, bytes[16..20], BI_RGB, .little);
    // pixels (BGR): (1,2,3)(4,5,6)(7,8,9) + 1 pad byte
    const pix = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 0 };
    @memcpy(bytes[40..][0..pix.len], &pix);

    const img = try dibToBgra(testing.allocator, &bytes);
    defer testing.allocator.free(img.pixels);
    try testing.expectEqual(@as(u32, 3), img.width);
    const expect = [_]u8{ 1, 2, 3, 255, 4, 5, 6, 255, 7, 8, 9, 255 };
    try testing.expectEqualSlices(u8, &expect, img.pixels);
}

test "dibToBgra: 32bpp all-zero alpha treated as opaque" {
    var bytes = [_]u8{0} ** (40 + 4);
    std.mem.writeInt(u32, bytes[0..4], 40, .little);
    std.mem.writeInt(i32, bytes[4..8], 1, .little);
    std.mem.writeInt(i32, bytes[8..12], -1, .little);
    std.mem.writeInt(u16, bytes[14..16], 32, .little);
    std.mem.writeInt(u32, bytes[16..20], BI_RGB, .little);
    @memcpy(bytes[40..][0..4], &[_]u8{ 5, 6, 7, 0 }); // BGRX, alpha 0
    const img = try dibToBgra(testing.allocator, &bytes);
    defer testing.allocator.free(img.pixels);
    try testing.expectEqualSlices(u8, &[_]u8{ 5, 6, 7, 255 }, img.pixels);
}

test "a11y subrole: dialogs flagged, all map to Window control type" {
    try testing.expect(!isDialogSubrole(.standard));
    try testing.expect(!isDialogSubrole(.floating));
    try testing.expect(isDialogSubrole(.dialog));
    try testing.expect(isDialogSubrole(.system_dialog));
    try testing.expectEqual(UIA_WindowControlTypeId, controlTypeForSubrole(.standard));
    try testing.expectEqual(UIA_WindowControlTypeId, controlTypeForSubrole(.dialog));
}

test "VARIANT is the 24-byte x64 layout with value at offset 8" {
    try testing.expectEqual(@as(usize, 24), @sizeOf(VARIANT));
    try testing.expectEqual(@as(usize, 8), @offsetOf(VARIANT, "val"));
}

test "xmlEscape: escapes the XML metacharacters" {
    const out = try xmlEscape(testing.allocator, "a & b < c > d \" e");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a &amp; b &lt; c &gt; d &quot; e", out);
}

test "buildToastXml: ToastGeneric with escaped title/body" {
    const out = try buildToastXml(testing.allocator, "Hi <there>", "x & y");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "<toast><visual><binding template=\"ToastGeneric\"><text>Hi &lt;there&gt;</text><text>x &amp; y</text></binding></visual></toast>",
        out,
    );
}

test "PROPVARIANT matches the 24-byte VARIANT-shaped layout" {
    try testing.expectEqual(@as(usize, 24), @sizeOf(PROPVARIANT));
    try testing.expectEqual(@as(usize, 8), @offsetOf(PROPVARIANT, "val"));
}

test "dibToBgra: rejects paletted 8bpp" {
    var bytes = [_]u8{0} ** 64;
    std.mem.writeInt(u32, bytes[0..4], 40, .little);
    std.mem.writeInt(i32, bytes[4..8], 1, .little);
    std.mem.writeInt(i32, bytes[8..12], 1, .little);
    std.mem.writeInt(u16, bytes[14..16], 8, .little);
    try testing.expectError(error.Unsupported, dibToBgra(testing.allocator, &bytes));
}

comptime {
    // Keep std + builtin alive in case future trimming inadvertently
    // drops references.
    _ = builtin;
}
