//! System-wide hotkey registration. Fires the callback even when
//! the app is blurred.
//!
//! Per-platform strategy:
//! - **macOS** — Carbon's `RegisterEventHotKey` +
//!   `InstallEventHandler` on the application event target.
//!   Carbon is deprecated but `RegisterEventHotKey` keeps shipping —
//!   it's the only public path for global hotkeys on macOS short
//!   of Accessibility API event taps. Needs `linkFramework("Carbon")`
//!   in the scaffold.
//! - **Windows** — `RegisterHotKey` against a hidden message-only
//!   window owned by the manager. The existing app message loop
//!   delivers `WM_HOTKEY` to that window's wndProc, which fires
//!   the callback. Self-contained — no changes to the rest of
//!   the Win backend. Callback fires on the main (UI) thread.
//! - **Linux (X11)** — `XGrabKey` on the root window. libX11 is
//!   loaded at runtime via `dlopen("libX11.so.6")` so apps on
//!   Wayland-only / headless installs build cleanly; the call
//!   returns `error.Unsupported` when libX11 isn't present or when
//!   `XDG_SESSION_TYPE=wayland` (Wayland has no portable
//!   global-hotkey API today — needs the GlobalShortcuts xdg
//!   portal which is a separate D-Bus integration). A dedicated
//!   worker thread runs `XNextEvent` and fires the callback from
//!   that thread (caller marshals to main thread if needed).
//!   NumLock + CapsLock variants are bound separately so the hotkey
//!   fires regardless of toggle state.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    Unsupported,
    Backend,
    OutOfMemory,
    AlreadyRegistered,
};

/// Modifier flags. OR them together for multi-modifier combos
/// (e.g. `.{ .cmd = true, .shift = true }`).
pub const Modifiers = packed struct {
    cmd: bool = false,
    ctrl: bool = false,
    option: bool = false,
    shift: bool = false,
    _pad: u4 = 0,
};

/// Fires when the registered combo is pressed. `id` is the same
/// id the caller passed to `register`, so a single callback can
/// dispatch multiple bindings.
pub const HotkeyHandler = *const fn (ctx: ?*anyopaque, id: u32) void;

pub const Manager = struct {
    macos_impl: ?*MacosManager = null,
    windows_impl: ?*WindowsManager = null,
    linux_impl: ?*LinuxManager = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Manager) void {
        if (self.macos_impl) |p| {
            p.deinit();
            self.allocator.destroy(p);
            self.macos_impl = null;
        }
        if (self.windows_impl) |p| {
            p.deinit();
            self.allocator.destroy(p);
            self.windows_impl = null;
        }
        if (self.linux_impl) |p| {
            p.deinit();
            self.allocator.destroy(p);
            self.linux_impl = null;
        }
    }

    /// Register a global hotkey. `id` is opaque to the platform —
    /// pick a value that's unique per-binding within this Manager.
    /// `keycode` is a platform virtual key code (see references
    /// like macOS `HIToolbox/Events.h` `kVK_ANSI_*`, Win32
    /// `VK_*` from `winuser.h`, or X11 keysyms `XK_*` from
    /// `keysymdef.h`).
    pub fn register(self: *Manager, id: u32, modifiers: Modifiers, keycode: u32) Error!void {
        if (self.macos_impl) |p| return p.register(id, modifiers, keycode);
        if (self.windows_impl) |p| return p.register(id, modifiers, keycode);
        if (self.linux_impl) |p| return p.register(id, modifiers, keycode);
        return error.Unsupported;
    }

    /// Remove a previously-registered binding. No-op for unknown ids.
    pub fn unregister(self: *Manager, id: u32) void {
        if (self.macos_impl) |p| p.unregister(id);
        if (self.windows_impl) |p| p.unregister(id);
        if (self.linux_impl) |p| p.unregister(id);
    }
};

pub fn init(
    allocator: std.mem.Allocator,
    cb: HotkeyHandler,
    ctx: ?*anyopaque,
) Error!Manager {
    switch (builtin.os.tag) {
        .macos => {
            const heap = allocator.create(MacosManager) catch return error.OutOfMemory;
            errdefer allocator.destroy(heap);
            heap.* = try MacosManager.start(allocator, cb, ctx);
            return .{ .macos_impl = heap, .allocator = allocator };
        },
        .windows => {
            const heap = allocator.create(WindowsManager) catch return error.OutOfMemory;
            errdefer allocator.destroy(heap);
            try WindowsManager.start(heap, allocator, cb, ctx);
            return .{ .windows_impl = heap, .allocator = allocator };
        },
        .linux => {
            const heap = allocator.create(LinuxManager) catch return error.OutOfMemory;
            errdefer allocator.destroy(heap);
            try LinuxManager.start(heap, allocator, cb, ctx);
            return .{ .linux_impl = heap, .allocator = allocator };
        },
        else => return error.Unsupported,
    }
}

// ---- macOS — Carbon RegisterEventHotKey ------------------------------------

const OSStatus = i32;
const EventHandlerRef = ?*anyopaque;
const EventTargetRef = ?*anyopaque;
const EventRef = ?*anyopaque;
const EventHotKeyRef = ?*anyopaque;

const EventTypeSpec = extern struct {
    eventClass: u32,
    eventKind: u32,
};

const EventHotKeyID = extern struct {
    signature: u32,
    id: u32,
};

// FourCharCode: 'htk1' = ('h' << 24) | ('t' << 16) | ('k' << 8) | '1'
const kEventClassKeyboard: u32 = 0x6B657962; // 'keyb'
const kEventHotKeyPressed: u32 = 5;
const kEventParamDirectObject: u32 = 0x2D2D2D2D; // '----'
const typeEventHotKeyID: u32 = 0x686B6964; // 'hkid'

// Carbon modifier mask bits (NSEventModifierFlags >> 16).
const cmdKey: u32 = 0x0100;
const shiftKey: u32 = 0x0200;
const optionKey: u32 = 0x0800;
const controlKey: u32 = 0x1000;

extern "Carbon" fn GetApplicationEventTarget() EventTargetRef;
extern "Carbon" fn InstallEventHandler(
    target: EventTargetRef,
    handler: *const fn (
        next: ?*anyopaque,
        event: EventRef,
        user: ?*anyopaque,
    ) callconv(.c) OSStatus,
    num_types: u32,
    types: [*]const EventTypeSpec,
    user: ?*anyopaque,
    out_ref: ?*EventHandlerRef,
) OSStatus;
extern "Carbon" fn RemoveEventHandler(ref: EventHandlerRef) OSStatus;
extern "Carbon" fn RegisterEventHotKey(
    keycode: u32,
    modifiers: u32,
    id: EventHotKeyID,
    target: EventTargetRef,
    options: u32,
    out_ref: *EventHotKeyRef,
) OSStatus;
extern "Carbon" fn UnregisterEventHotKey(ref: EventHotKeyRef) OSStatus;
extern "Carbon" fn GetEventParameter(
    event: EventRef,
    name: u32,
    desired_type: u32,
    actual_type: ?*u32,
    buffer_size: u32,
    actual_size: ?*u32,
    out_data: ?*anyopaque,
) OSStatus;

const Binding = struct {
    id: u32,
    ref: EventHotKeyRef,
};

const MacosManager = struct {
    allocator: std.mem.Allocator,
    cb: HotkeyHandler,
    cb_ctx: ?*anyopaque,
    handler_ref: EventHandlerRef = null,
    bindings: std.ArrayList(Binding) = .empty,

    fn start(
        allocator: std.mem.Allocator,
        cb: HotkeyHandler,
        ctx: ?*anyopaque,
    ) Error!MacosManager {
        if (builtin.os.tag != .macos) return error.Unsupported;
        var self: MacosManager = .{
            .allocator = allocator,
            .cb = cb,
            .cb_ctx = ctx,
        };

        const target = GetApplicationEventTarget() orelse return error.Backend;
        const types = [_]EventTypeSpec{.{
            .eventClass = kEventClassKeyboard,
            .eventKind = kEventHotKeyPressed,
        }};
        // Singleton — the handler trampoline routes to whichever
        // MacosManager pointer was last installed. Multi-manager
        // apps would need the user_data to point at a registry.
        var ref: EventHandlerRef = null;
        const status = InstallEventHandler(
            target,
            hotkeyTrampoline,
            1,
            &types,
            null, // user data unused — we route via g_singleton.
            &ref,
        );
        if (status != 0) return error.Backend;
        self.handler_ref = ref;
        g_singleton = &self;
        return self;
    }

    fn register(self: *MacosManager, id: u32, modifiers: Modifiers, keycode: u32) Error!void {
        // Reject duplicate ids — multiple bindings with the same id
        // make the callback ambiguous.
        for (self.bindings.items) |b| if (b.id == id) return error.AlreadyRegistered;

        var mask: u32 = 0;
        if (modifiers.cmd) mask |= cmdKey;
        if (modifiers.ctrl) mask |= controlKey;
        if (modifiers.option) mask |= optionKey;
        if (modifiers.shift) mask |= shiftKey;

        const hk_id = EventHotKeyID{
            .signature = 0x76657276, // 'verv'
            .id = id,
        };
        var hk_ref: EventHotKeyRef = null;
        const target = GetApplicationEventTarget();
        const status = RegisterEventHotKey(keycode, mask, hk_id, target, 0, &hk_ref);
        if (status != 0) return error.Backend;
        self.bindings.append(self.allocator, .{ .id = id, .ref = hk_ref }) catch {
            _ = UnregisterEventHotKey(hk_ref);
            return error.OutOfMemory;
        };
    }

    fn unregister(self: *MacosManager, id: u32) void {
        var i: usize = 0;
        while (i < self.bindings.items.len) : (i += 1) {
            if (self.bindings.items[i].id == id) {
                _ = UnregisterEventHotKey(self.bindings.items[i].ref);
                _ = self.bindings.orderedRemove(i);
                return;
            }
        }
    }

    pub fn deinit(self: *MacosManager) void {
        for (self.bindings.items) |b| {
            _ = UnregisterEventHotKey(b.ref);
        }
        self.bindings.deinit(self.allocator);
        if (self.handler_ref) |r| {
            _ = RemoveEventHandler(r);
            self.handler_ref = null;
        }
        if (g_singleton == self) g_singleton = null;
    }
};

var g_singleton: ?*MacosManager = null;

fn hotkeyTrampoline(
    _: ?*anyopaque,
    event: EventRef,
    _: ?*anyopaque,
) callconv(.c) OSStatus {
    const mgr = g_singleton orelse return 0;
    var hk_id: EventHotKeyID = .{ .signature = 0, .id = 0 };
    _ = GetEventParameter(
        event,
        kEventParamDirectObject,
        typeEventHotKeyID,
        null,
        @sizeOf(EventHotKeyID),
        null,
        @ptrCast(&hk_id),
    );
    mgr.cb(mgr.cb_ctx, hk_id.id);
    return 0;
}

// ---- Windows — RegisterHotKey + hidden message-only window ----------------

const HWND = ?*opaque {};
const HINSTANCE = ?*opaque {};
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const UINT = c_uint;

const WM_HOTKEY: UINT = 0x0312;
const WM_DESTROY: UINT = 0x0002;

const MOD_ALT: UINT = 0x0001;
const MOD_CONTROL: UINT = 0x0002;
const MOD_SHIFT: UINT = 0x0004;
const MOD_WIN: UINT = 0x0008;
const MOD_NOREPEAT: UINT = 0x4000;

const HWND_MESSAGE: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));

const WNDCLASSW = extern struct {
    style: UINT = 0,
    lpfnWndProc: *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT,
    cbClsExtra: c_int = 0,
    cbWndExtra: c_int = 0,
    hInstance: HINSTANCE = null,
    hIcon: ?*anyopaque = null,
    hCursor: ?*anyopaque = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
};

extern "user32" fn RegisterClassW(cls: *const WNDCLASSW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(
    dwExStyle: u32,
    lpClassName: [*:0]const u16,
    lpWindowName: ?[*:0]const u16,
    dwStyle: u32,
    x: c_int,
    y: c_int,
    nWidth: c_int,
    nHeight: c_int,
    hWndParent: HWND,
    hMenu: ?*anyopaque,
    hInstance: HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(.winapi) HWND;
extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.winapi) c_int;
extern "user32" fn DefWindowProcW(hwnd: HWND, msg: UINT, w: WPARAM, l: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn RegisterHotKey(hwnd: HWND, id: c_int, mods: UINT, vk: UINT) callconv(.winapi) c_int;
extern "user32" fn UnregisterHotKey(hwnd: HWND, id: c_int) callconv(.winapi) c_int;
extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) HINSTANCE;

const HOTKEY_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("VerveHotkeyMessageWnd");

var g_win_singleton: ?*WindowsManager = null;
var g_class_registered: bool = false;

const WindowsManager = struct {
    allocator: std.mem.Allocator,
    cb: HotkeyHandler,
    cb_ctx: ?*anyopaque,
    hwnd: HWND = null,
    bindings: std.ArrayList(u32) = .empty,

    fn start(
        self: *WindowsManager,
        allocator: std.mem.Allocator,
        cb: HotkeyHandler,
        ctx: ?*anyopaque,
    ) Error!void {
        if (builtin.os.tag != .windows) return error.Unsupported;
        self.* = .{
            .allocator = allocator,
            .cb = cb,
            .cb_ctx = ctx,
        };

        if (!g_class_registered) {
            const wc: WNDCLASSW = .{
                .lpfnWndProc = hotkeyWndProc,
                .hInstance = GetModuleHandleW(null),
                .lpszClassName = HOTKEY_CLASS_NAME,
            };
            if (RegisterClassW(&wc) == 0) return error.Backend;
            g_class_registered = true;
        }

        // Message-only window: HWND_MESSAGE as parent puts the window
        // off-screen and excludes it from the foreground stack, but
        // the GetMessage loop still delivers messages to its wndProc.
        self.hwnd = CreateWindowExW(
            0,
            HOTKEY_CLASS_NAME,
            null,
            0,
            0,
            0,
            0,
            0,
            HWND_MESSAGE,
            null,
            GetModuleHandleW(null),
            null,
        );
        if (self.hwnd == null) return error.Backend;
        g_win_singleton = self;
    }

    fn register(self: *WindowsManager, id: u32, modifiers: Modifiers, keycode: u32) Error!void {
        for (self.bindings.items) |existing| if (existing == id) return error.AlreadyRegistered;

        var mods: UINT = MOD_NOREPEAT;
        if (modifiers.cmd) mods |= MOD_WIN;
        if (modifiers.ctrl) mods |= MOD_CONTROL;
        if (modifiers.option) mods |= MOD_ALT;
        if (modifiers.shift) mods |= MOD_SHIFT;

        if (RegisterHotKey(self.hwnd, @intCast(id), mods, @intCast(keycode)) == 0) {
            return error.Backend;
        }
        self.bindings.append(self.allocator, id) catch {
            _ = UnregisterHotKey(self.hwnd, @intCast(id));
            return error.OutOfMemory;
        };
    }

    fn unregister(self: *WindowsManager, id: u32) void {
        var i: usize = 0;
        while (i < self.bindings.items.len) : (i += 1) {
            if (self.bindings.items[i] == id) {
                _ = UnregisterHotKey(self.hwnd, @intCast(id));
                _ = self.bindings.orderedRemove(i);
                return;
            }
        }
    }

    pub fn deinit(self: *WindowsManager) void {
        if (builtin.os.tag != .windows) return;
        for (self.bindings.items) |id| {
            _ = UnregisterHotKey(self.hwnd, @intCast(id));
        }
        self.bindings.deinit(self.allocator);
        if (self.hwnd) |h| _ = DestroyWindow(h);
        self.hwnd = null;
        if (g_win_singleton == self) g_win_singleton = null;
    }
};

fn hotkeyWndProc(hwnd: HWND, msg: UINT, w: WPARAM, l: LPARAM) callconv(.winapi) LRESULT {
    if (msg == WM_HOTKEY) {
        if (g_win_singleton) |mgr| {
            mgr.cb(mgr.cb_ctx, @intCast(w));
        }
        return 0;
    }
    return DefWindowProcW(hwnd, msg, w, l);
}

// ---- Linux — X11 XGrabKey via dlopen libX11 -------------------------------

// X11 modifier masks. From X11/X.h. Mod1=Alt, Mod4=Super/Cmd.
const X_ShiftMask: c_uint = 1 << 0;
const X_LockMask: c_uint = 1 << 1; // CapsLock
const X_ControlMask: c_uint = 1 << 2;
const X_Mod1Mask: c_uint = 1 << 3; // Alt
const X_Mod2Mask: c_uint = 1 << 4; // NumLock (typical Linux mapping)
const X_Mod4Mask: c_uint = 1 << 6; // Super (Cmd-equivalent)

const X_KeyPress: c_int = 2;
const X_GrabModeAsync: c_int = 1;

const XDisplay = opaque {};
const XWindow = c_ulong;
const KeySym = c_ulong;
const KeyCode = u8;

// 192-byte XEvent union — we only access XKeyEvent fields. Match
// the X11 layout: first u32 is `type`, then for KeyEvent the
// keycode lives at a known offset. Use the documented XKeyEvent
// shape and a u8[192] padding to ensure we allocate the full union.
const XKeyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*XDisplay,
    window: XWindow,
    root: XWindow,
    subwindow: XWindow,
    time: c_ulong,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    keycode: c_uint,
    same_screen: c_int,
};
const XEvent = extern union {
    type: c_int,
    key: XKeyEvent,
    pad: [192]u8,
};

const LibX11 = struct {
    open_display: *const fn (?[*:0]const u8) callconv(.c) ?*XDisplay,
    close_display: *const fn (*XDisplay) callconv(.c) c_int,
    default_root_window: *const fn (*XDisplay) callconv(.c) XWindow,
    keysym_to_keycode: *const fn (*XDisplay, KeySym) callconv(.c) KeyCode,
    grab_key: *const fn (*XDisplay, c_int, c_uint, XWindow, c_int, c_int, c_int) callconv(.c) c_int,
    ungrab_key: *const fn (*XDisplay, c_int, c_uint, XWindow) callconv(.c) c_int,
    next_event: *const fn (*XDisplay, *XEvent) callconv(.c) c_int,
    pending: *const fn (*XDisplay) callconv(.c) c_int,
    flush: *const fn (*XDisplay) callconv(.c) c_int,
    sync: *const fn (*XDisplay, c_int) callconv(.c) c_int,
    set_error_handler: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
};

var g_libx11: ?LibX11 = null;
var g_libx11_tried: bool = false;

fn loadLibX11() ?*const LibX11 {
    if (g_libx11_tried) return if (g_libx11) |*v| v else null;
    g_libx11_tried = true;

    // Wayland sessions can have libX11 installed (XWayland), but a
    // hotkey grab on the XWayland root only fires when an X11 client
    // has focus — fundamentally broken for "global." Skip outright.
    if (std.c.getenv("XDG_SESSION_TYPE")) |st| {
        const s = std.mem.sliceTo(st, 0);
        if (std.mem.eql(u8, s, "wayland")) return null;
    }

    const handle = std.c.dlopen("libX11.so.6", .{ .LAZY = true }) orelse {
        if (std.c.dlopen("libX11.so", .{ .LAZY = true })) |h2| {
            return resolveLibX11(h2);
        }
        return null;
    };
    return resolveLibX11(handle);
}

fn resolveLibX11(handle: ?*anyopaque) ?*const LibX11 {
    const od = std.c.dlsym(handle, "XOpenDisplay") orelse return null;
    const cd = std.c.dlsym(handle, "XCloseDisplay") orelse return null;
    const drw = std.c.dlsym(handle, "XDefaultRootWindow") orelse return null;
    const ktk = std.c.dlsym(handle, "XKeysymToKeycode") orelse return null;
    const gk = std.c.dlsym(handle, "XGrabKey") orelse return null;
    const ugk = std.c.dlsym(handle, "XUngrabKey") orelse return null;
    const ne = std.c.dlsym(handle, "XNextEvent") orelse return null;
    const pe = std.c.dlsym(handle, "XPending") orelse return null;
    const fl = std.c.dlsym(handle, "XFlush") orelse return null;
    const sy = std.c.dlsym(handle, "XSync") orelse return null;
    const seh = std.c.dlsym(handle, "XSetErrorHandler") orelse return null;

    g_libx11 = .{
        .open_display = @ptrCast(@alignCast(od)),
        .close_display = @ptrCast(@alignCast(cd)),
        .default_root_window = @ptrCast(@alignCast(drw)),
        .keysym_to_keycode = @ptrCast(@alignCast(ktk)),
        .grab_key = @ptrCast(@alignCast(gk)),
        .ungrab_key = @ptrCast(@alignCast(ugk)),
        .next_event = @ptrCast(@alignCast(ne)),
        .pending = @ptrCast(@alignCast(pe)),
        .flush = @ptrCast(@alignCast(fl)),
        .sync = @ptrCast(@alignCast(sy)),
        .set_error_handler = @ptrCast(@alignCast(seh)),
    };
    return &g_libx11.?;
}

const LinuxBinding = struct {
    id: u32,
    keycode: c_int,
    mods: c_uint,
};

const LinuxManager = struct {
    allocator: std.mem.Allocator,
    cb: HotkeyHandler,
    cb_ctx: ?*anyopaque,
    x: ?*const LibX11 = null,
    display: ?*XDisplay = null,
    root: XWindow = 0,
    bindings: std.ArrayList(LinuxBinding) = .empty,
    thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = .init(false),

    fn start(
        self: *LinuxManager,
        allocator: std.mem.Allocator,
        cb: HotkeyHandler,
        ctx: ?*anyopaque,
    ) Error!void {
        if (builtin.os.tag != .linux) return error.Unsupported;
        self.* = .{
            .allocator = allocator,
            .cb = cb,
            .cb_ctx = ctx,
        };

        const x = loadLibX11() orelse return error.Unsupported;
        const display = x.open_display(null) orelse return error.Unsupported;

        self.x = x;
        self.display = display;
        self.root = x.default_root_window(display);

        // Swallow X errors from XGrabKey (BadAccess when another
        // client owns the combo). The default handler aborts the
        // process, which would surprise an app that uses other X11
        // libs alongside us. Setting a no-op handler globally is
        // standard practice for hotkey libs.
        _ = x.set_error_handler(@ptrCast(@constCast(&xNoopErrorHandler)));

        self.thread = std.Thread.spawn(.{}, x11ThreadEntry, .{self}) catch {
            _ = x.close_display(display);
            self.display = null;
            return error.Backend;
        };
    }

    fn register(self: *LinuxManager, id: u32, modifiers: Modifiers, keysym: u32) Error!void {
        const x = self.x orelse return error.Backend;
        const display = self.display orelse return error.Backend;

        for (self.bindings.items) |b| if (b.id == id) return error.AlreadyRegistered;

        var mods: c_uint = 0;
        if (modifiers.cmd) mods |= X_Mod4Mask;
        if (modifiers.ctrl) mods |= X_ControlMask;
        if (modifiers.option) mods |= X_Mod1Mask;
        if (modifiers.shift) mods |= X_ShiftMask;

        const keycode = x.keysym_to_keycode(display, @intCast(keysym));
        if (keycode == 0) return error.Backend;

        // Grab all 4 variants so the hotkey fires regardless of
        // NumLock + CapsLock toggle state. X11 requires exact
        // modifier match on the grab.
        const variants = [_]c_uint{ 0, X_LockMask, X_Mod2Mask, X_LockMask | X_Mod2Mask };
        for (variants) |extra| {
            _ = x.grab_key(display, keycode, mods | extra, self.root, 0, X_GrabModeAsync, X_GrabModeAsync);
        }
        _ = x.flush(display);

        self.bindings.append(self.allocator, .{ .id = id, .keycode = keycode, .mods = mods }) catch {
            // best-effort ungrab on OOM
            for (variants) |extra| _ = x.ungrab_key(display, keycode, mods | extra, self.root);
            return error.OutOfMemory;
        };
    }

    fn unregister(self: *LinuxManager, id: u32) void {
        const x = self.x orelse return;
        const display = self.display orelse return;

        var i: usize = 0;
        while (i < self.bindings.items.len) : (i += 1) {
            if (self.bindings.items[i].id != id) continue;
            const b = self.bindings.items[i];
            const variants = [_]c_uint{ 0, X_LockMask, X_Mod2Mask, X_LockMask | X_Mod2Mask };
            for (variants) |extra| _ = x.ungrab_key(display, b.keycode, b.mods | extra, self.root);
            _ = x.flush(display);
            _ = self.bindings.orderedRemove(i);
            return;
        }
    }

    pub fn deinit(self: *LinuxManager) void {
        if (builtin.os.tag != .linux) return;
        self.stop_flag.store(true, .release);
        // Best-effort: ungrab everything so the worker's XNextEvent
        // doesn't have anything pending; close the display to break
        // any in-flight blocking call.
        if (self.x) |x| {
            if (self.display) |d| {
                for (self.bindings.items) |b| {
                    const variants = [_]c_uint{ 0, X_LockMask, X_Mod2Mask, X_LockMask | X_Mod2Mask };
                    for (variants) |extra| _ = x.ungrab_key(d, b.keycode, b.mods | extra, self.root);
                }
                _ = x.flush(d);
                _ = x.close_display(d);
                self.display = null;
            }
        }
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.bindings.deinit(self.allocator);
    }
};

fn x11ThreadEntry(self: *LinuxManager) void {
    const x = self.x orelse return;
    const display = self.display orelse return;
    while (!self.stop_flag.load(.acquire)) {
        var ev: XEvent = std.mem.zeroes(XEvent);
        // XNextEvent blocks; close_display from deinit unblocks it.
        _ = x.next_event(display, &ev);
        if (self.stop_flag.load(.acquire)) return;
        if (ev.type != X_KeyPress) continue;

        const got_code: c_int = @intCast(ev.key.keycode);
        // Mask off NumLock + CapsLock before matching so all four
        // grab variants funnel to the same binding lookup.
        const got_mods: c_uint = ev.key.state & ~(X_LockMask | X_Mod2Mask);

        for (self.bindings.items) |b| {
            if (b.keycode == got_code and b.mods == got_mods) {
                self.cb(self.cb_ctx, b.id);
                break;
            }
        }
    }
}

fn xNoopErrorHandler(_: ?*XDisplay, _: ?*anyopaque) callconv(.c) c_int {
    return 0;
}

const testing = std.testing;

test "Modifiers fits in a byte" {
    try testing.expectEqual(@as(usize, 1), @sizeOf(Modifiers));
}

test "Hotkeys Error set stable" {
    const e: Error = error.Unsupported;
    try testing.expect(e == error.Unsupported);
    try testing.expect(@as(Error, error.AlreadyRegistered) == error.AlreadyRegistered);
}
