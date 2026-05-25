//! Cross-platform tray / status-bar icon.
//!
//! Exposes a small `Tray` value: create an icon, set its tooltip,
//! destroy it. No click handlers, no submenus in this pass — those
//! sit on the cross-platform surface as a future follow-up. Apps that
//! need rich tray menus today drop down to the platform-native APIs.
//!
//! Per-platform strategy:
//!
//! - **macOS** — `[[NSStatusBar systemStatusBar]
//!   statusItemWithLength:NSVariableStatusItemLength]`. Title is a
//!   short text label rendered next to the menubar; tooltip is the
//!   `button.toolTip` property.
//! - **Windows** — `Shell_NotifyIconW(NIM_ADD)` with a
//!   `NOTIFYICONDATAW` carrying `IDI_APPLICATION` (stock icon — apps
//!   wanting custom icons can rotate `hIcon` themselves once a
//!   future bundle exposes `setIcon`).
//! - **Linux** — `app_indicator_new` (libayatana-appindicator3). The
//!   indicator only renders when its status is set to
//!   `APP_INDICATOR_STATUS_ACTIVE`. A minimal one-item GtkMenu is
//!   attached because some Ayatana versions refuse to draw the icon
//!   without a menu reference.
//!
//! Notifications are a separate concern — see `notifications.zig`.

const std = @import("std");
const builtin = @import("builtin");
const window_mod = @import("window.zig");

pub const Error = error{
    Unsupported,
    OutOfMemory,
    Backend,
};

pub const TrayOptions = struct {
    /// Tooltip shown on hover. Empty string disables the tooltip.
    tooltip: []const u8 = "",
    /// Status-bar label. macOS renders this text next to the icon
    /// in the menubar; Win + Linux ignore it (Win shows the tooltip,
    /// Linux uses the indicator's `id` / theme icon name).
    label: []const u8 = "Verve",
};

pub const Tray = struct {
    impl: switch (builtin.os.tag) {
        .macos => MacosTray,
        .windows => WindowsTray,
        .linux => LinuxTray,
        else => @compileError("verve.desktop.tray: unsupported OS"),
    },

    pub fn deinit(self: *Tray) void {
        self.impl.deinit();
    }

    pub fn setTooltip(self: *Tray, tooltip: []const u8) void {
        self.impl.setTooltip(tooltip);
    }
};

pub fn init(
    allocator: std.mem.Allocator,
    window: *window_mod.Window,
    opts: TrayOptions,
) Error!Tray {
    switch (builtin.os.tag) {
        .macos => return .{ .impl = try MacosTray.init(allocator, window, opts) },
        .windows => return .{ .impl = try WindowsTray.init(allocator, window, opts) },
        .linux => return .{ .impl = try LinuxTray.init(allocator, window, opts) },
        else => return error.Unsupported,
    }
}

// ---- macOS — NSStatusItem ---------------------------------------------------

const MacosTray = struct {
    status_item: ?*anyopaque = null,
    allocator: std.mem.Allocator = undefined,

    const m = if (builtin.os.tag == .macos) @import("msg.zig") else struct {};
    const id = ?*anyopaque;
    const SEL = ?*anyopaque;

    fn init(allocator: std.mem.Allocator, _: *window_mod.Window, opts: TrayOptions) Error!MacosTray {
        if (builtin.os.tag != .macos) return error.Unsupported;

        const NSStatusBar = m.getClass("NSStatusBar");
        const systemStatusBar = m.cast(*const fn (id, SEL) callconv(.c) id);
        const bar = systemStatusBar(@as(id, @ptrCast(NSStatusBar)), m.sel("systemStatusBar"));

        // NSVariableStatusItemLength = -1.0 (CGFloat).
        const variable_length: f64 = -1.0;
        const statusItemWithLength = m.cast(*const fn (id, SEL, f64) callconv(.c) id);
        const item = statusItemWithLength(bar, m.sel("statusItemWithLength:"), variable_length);
        if (@intFromPtr(item) == 0) return error.Backend;

        // Retain so the bar holds a strong ref past this stack frame.
        const retain = m.cast(*const fn (id, SEL) callconv(.c) id);
        _ = retain(item, m.sel("retain"));

        const button_sel = m.cast(*const fn (id, SEL) callconv(.c) id);
        const button = button_sel(item, m.sel("button"));
        if (@intFromPtr(button) != 0 and opts.label.len > 0) {
            const setTitle = m.cast(*const fn (id, SEL, id) callconv(.c) void);
            setTitle(button, m.sel("setTitle:"), nsString(opts.label));
        }
        if (@intFromPtr(button) != 0 and opts.tooltip.len > 0) {
            const setToolTip = m.cast(*const fn (id, SEL, id) callconv(.c) void);
            setToolTip(button, m.sel("setToolTip:"), nsString(opts.tooltip));
        }

        return .{ .status_item = item, .allocator = allocator };
    }

    fn deinit(self: *MacosTray) void {
        if (builtin.os.tag != .macos) return;
        const item = self.status_item orelse return;

        // Detach from the status bar.
        const NSStatusBar = m.getClass("NSStatusBar");
        const systemStatusBar = m.cast(*const fn (id, SEL) callconv(.c) id);
        const bar = systemStatusBar(@as(id, @ptrCast(NSStatusBar)), m.sel("systemStatusBar"));
        const removeStatusItem = m.cast(*const fn (id, SEL, id) callconv(.c) void);
        removeStatusItem(bar, m.sel("removeStatusItem:"), item);

        const release = m.cast(*const fn (id, SEL) callconv(.c) void);
        release(item, m.sel("release"));
        self.status_item = null;
    }

    fn setTooltip(self: *MacosTray, tooltip: []const u8) void {
        if (builtin.os.tag != .macos) return;
        const item = self.status_item orelse return;
        const button_sel = m.cast(*const fn (id, SEL) callconv(.c) id);
        const button = button_sel(item, m.sel("button"));
        if (@intFromPtr(button) == 0) return;
        const setToolTip = m.cast(*const fn (id, SEL, id) callconv(.c) void);
        setToolTip(button, m.sel("setToolTip:"), nsString(tooltip));
    }

    fn nsString(s: []const u8) id {
        if (builtin.os.tag != .macos) return null;
        const NSString = m.getClass("NSString");
        const stringWithUTF8 = m.cast(*const fn (id, SEL, [*]const u8) callconv(.c) id);
        var buf: [512]u8 = undefined;
        const len = @min(s.len, buf.len - 1);
        @memcpy(buf[0..len], s[0..len]);
        buf[len] = 0;
        return stringWithUTF8(@as(id, @ptrCast(NSString)), m.sel("stringWithUTF8String:"), &buf);
    }
};

// ---- Windows — Shell_NotifyIconW + NOTIFYICONDATAW --------------------------

const WindowsTray = struct {
    hwnd: ?*anyopaque = null,
    uid: u32 = 1,
    /// Hidden — only flipped to true once `NIM_ADD` succeeded. `deinit`
    /// then issues the matching `NIM_DELETE`.
    added: bool = false,

    const HWND = ?*opaque {};
    const HICON = ?*opaque {};
    const HINSTANCE = ?*opaque {};
    const DWORD = c_ulong;
    const UINT = c_uint;
    const BOOL = c_int;
    const LPCWSTR = ?[*:0]const u16;
    const GUID = extern struct {
        Data1: u32,
        Data2: u16,
        Data3: u16,
        Data4: [8]u8,
    };

    // `NOTIFYICONDATAW` from `<shellapi.h>`. The full struct grows with
    // shell versions; we use the V3 layout (cbSize covers fields up
    // through `hBalloonIcon`) which has been ABI-stable since XP SP2.
    const NOTIFYICONDATAW = extern struct {
        cbSize: DWORD = 0,
        hWnd: HWND = null,
        uID: UINT = 0,
        uFlags: UINT = 0,
        uCallbackMessage: UINT = 0,
        hIcon: HICON = null,
        szTip: [128]u16 = std.mem.zeroes([128]u16),
        dwState: DWORD = 0,
        dwStateMask: DWORD = 0,
        szInfo: [256]u16 = std.mem.zeroes([256]u16),
        uTimeoutOrVersion: UINT = 0,
        szInfoTitle: [64]u16 = std.mem.zeroes([64]u16),
        dwInfoFlags: DWORD = 0,
        guidItem: GUID = .{ .Data1 = 0, .Data2 = 0, .Data3 = 0, .Data4 = .{ 0, 0, 0, 0, 0, 0, 0, 0 } },
        hBalloonIcon: HICON = null,
    };

    const NIF_MESSAGE: UINT = 0x1;
    const NIF_ICON: UINT = 0x2;
    const NIF_TIP: UINT = 0x4;
    const NIM_ADD: DWORD = 0x0;
    const NIM_MODIFY: DWORD = 0x1;
    const NIM_DELETE: DWORD = 0x2;

    // `IDI_APPLICATION` is the stock icon resource; `LoadIconW(NULL, IDI_APPLICATION)`
    // returns a shared HICON we never need to free.
    const IDI_APPLICATION: LPCWSTR = @ptrFromInt(32512);

    extern "shell32" fn Shell_NotifyIconW(message: DWORD, data: *NOTIFYICONDATAW) callconv(.winapi) BOOL;
    extern "user32" fn LoadIconW(hinst: HINSTANCE, name: LPCWSTR) callconv(.winapi) HICON;

    fn init(allocator: std.mem.Allocator, window: *window_mod.Window, opts: TrayOptions) Error!WindowsTray {
        _ = allocator;
        if (builtin.os.tag != .windows) return error.Unsupported;

        const hwnd: HWND = @ptrCast(@alignCast(getHwnd(window) orelse return error.Backend));
        const icon = LoadIconW(null, IDI_APPLICATION);

        var nid: NOTIFYICONDATAW = .{};
        nid.cbSize = @sizeOf(NOTIFYICONDATAW);
        nid.hWnd = hwnd;
        nid.uID = 1;
        nid.uFlags = NIF_ICON | NIF_TIP;
        nid.hIcon = icon;

        // Tooltip is UTF-16, capped at 127 chars + NUL.
        if (opts.tooltip.len > 0) {
            const written = std.unicode.utf8ToUtf16Le(&nid.szTip, opts.tooltip) catch 0;
            nid.szTip[@min(nid.szTip.len - 1, written)] = 0;
        }

        if (Shell_NotifyIconW(NIM_ADD, &nid) == 0) return error.Backend;
        return .{ .hwnd = @ptrCast(hwnd), .uid = 1, .added = true };
    }

    fn deinit(self: *WindowsTray) void {
        if (builtin.os.tag != .windows) return;
        if (!self.added) return;
        var nid: NOTIFYICONDATAW = .{};
        nid.cbSize = @sizeOf(NOTIFYICONDATAW);
        nid.hWnd = @ptrCast(@alignCast(self.hwnd));
        nid.uID = self.uid;
        _ = Shell_NotifyIconW(NIM_DELETE, &nid);
        self.added = false;
    }

    fn setTooltip(self: *WindowsTray, tooltip: []const u8) void {
        if (builtin.os.tag != .windows) return;
        if (!self.added) return;
        var nid: NOTIFYICONDATAW = .{};
        nid.cbSize = @sizeOf(NOTIFYICONDATAW);
        nid.hWnd = @ptrCast(@alignCast(self.hwnd));
        nid.uID = self.uid;
        nid.uFlags = NIF_TIP;
        const written = std.unicode.utf8ToUtf16Le(&nid.szTip, tooltip) catch 0;
        nid.szTip[@min(nid.szTip.len - 1, written)] = 0;
        _ = Shell_NotifyIconW(NIM_MODIFY, &nid);
    }

    /// Reach into the Windows backend to grab the raw HWND out of the
    /// passed-in `Window`. The backend exposes the field as
    /// `ctx.hwnd` (per-window context heap); the cross-platform
    /// `Window` is just a thin wrapper around `*WindowCtx` so the
    /// field offset is stable.
    fn getHwnd(window: *window_mod.Window) ?*anyopaque {
        if (builtin.os.tag != .windows) return null;
        // The Windows backend's `Window` is `struct { ctx: *WindowCtx }`
        // and `WindowCtx.hwnd: HWND`. The `windows` module exposes
        // a public getter via Window's first field.
        const w_backend = if (builtin.os.tag == .windows) @import("windows.zig") else struct {};
        return w_backend.hwndOf(window);
    }
};

// ---- Linux — libayatana-appindicator3 ---------------------------------------

const LinuxTray = struct {
    indicator: ?*anyopaque = null,
    label_buf: ?[]u8 = null,
    allocator: std.mem.Allocator = undefined,

    const AppIndicator = opaque {};
    const GtkWidget = opaque {};
    const AppIndicatorCategory = c_uint;
    const AppIndicatorStatus = c_uint;

    const APP_INDICATOR_CATEGORY_APPLICATION_STATUS: AppIndicatorCategory = 0;
    const APP_INDICATOR_STATUS_ACTIVE: AppIndicatorStatus = 1;

    extern fn app_indicator_new(
        id: [*:0]const u8,
        icon_name: [*:0]const u8,
        category: AppIndicatorCategory,
    ) *AppIndicator;
    extern fn app_indicator_set_status(self: *AppIndicator, status: AppIndicatorStatus) void;
    extern fn app_indicator_set_title(self: *AppIndicator, title: [*:0]const u8) void;
    extern fn app_indicator_set_label(self: *AppIndicator, label: [*:0]const u8, guide: [*:0]const u8) void;
    extern fn app_indicator_set_menu(self: *AppIndicator, menu: *GtkWidget) void;
    extern fn g_object_unref(o: ?*anyopaque) void;

    // Reuse the GTK menu primitives — same shape the menu-bar bundle
    // declared in `linux.zig`, redeclared here to keep this module
    // standalone in terms of dependencies.
    extern fn gtk_menu_new() *GtkWidget;
    extern fn gtk_widget_show_all(w: *GtkWidget) void;

    fn init(allocator: std.mem.Allocator, _: *window_mod.Window, opts: TrayOptions) Error!LinuxTray {
        if (builtin.os.tag != .linux) return error.Unsupported;

        const id_z = allocator.dupeZ(u8, "verve-desktop") catch return error.OutOfMemory;
        defer allocator.free(id_z);
        const icon_z = allocator.dupeZ(u8, "application-x-executable") catch return error.OutOfMemory;
        defer allocator.free(icon_z);

        const ind = app_indicator_new(id_z.ptr, icon_z.ptr, APP_INDICATOR_CATEGORY_APPLICATION_STATUS);
        app_indicator_set_status(ind, APP_INDICATOR_STATUS_ACTIVE);

        if (opts.tooltip.len > 0) {
            const t = allocator.dupeZ(u8, opts.tooltip) catch return error.OutOfMemory;
            defer allocator.free(t);
            app_indicator_set_title(ind, t.ptr);
        }
        if (opts.label.len > 0) {
            const l = allocator.dupeZ(u8, opts.label) catch return error.OutOfMemory;
            defer allocator.free(l);
            app_indicator_set_label(ind, l.ptr, l.ptr);
        }

        // Some Ayatana versions refuse to render the icon without a
        // menu set. Attach an empty one — apps that want submenus
        // build them on top once a future bundle exposes the API.
        const menu = gtk_menu_new();
        gtk_widget_show_all(menu);
        app_indicator_set_menu(ind, menu);

        return .{
            .indicator = @ptrCast(ind),
            .label_buf = null,
            .allocator = allocator,
        };
    }

    fn deinit(self: *LinuxTray) void {
        if (builtin.os.tag != .linux) return;
        if (self.indicator) |ind| {
            g_object_unref(ind);
            self.indicator = null;
        }
        if (self.label_buf) |b| self.allocator.free(b);
    }

    fn setTooltip(self: *LinuxTray, tooltip: []const u8) void {
        if (builtin.os.tag != .linux) return;
        const ind_raw = self.indicator orelse return;
        const ind: *AppIndicator = @ptrCast(@alignCast(ind_raw));
        const z = self.allocator.dupeZ(u8, tooltip) catch return;
        defer self.allocator.free(z);
        app_indicator_set_title(ind, z.ptr);
    }
};
