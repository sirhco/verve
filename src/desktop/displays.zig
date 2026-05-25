//! Multi-display enumeration.
//!
//! `list(allocator)` returns a slice of `Display` records — one per
//! attached monitor. Useful for apps that want to position a window
//! on a specific screen, derive layout from total desktop bounds, or
//! detect HiDPI for asset selection.
//!
//! Coordinate system: each `Display` reports its top-left origin in
//! the OS's virtual-screen coordinate space (multiple monitors share
//! one continuous coordinate plane). macOS's natural origin is
//! bottom-left; we convert to top-left to match Windows + GTK so
//! `Window.setPosition` integrates cleanly. `width` / `height` are
//! the monitor's logical dimensions; `scale` is the HiDPI factor
//! (1.0 on non-HiDPI displays; 2.0 on standard Retina; 1.5 / 1.75
//! on fractional-scale Linux setups).
//!
//! Per-platform strategy:
//!
//! - **macOS** — `[NSScreen screens]` → iterate. `screen.frame` for
//!   bounds (origin in bottom-left coordinates),
//!   `backingScaleFactor` for HiDPI. The primary screen is index 0.
//! - **Windows** — `EnumDisplayMonitors` with a callback that
//!   reads `MONITORINFOEX` for each monitor. `dwFlags &
//!   MONITORINFOF_PRIMARY` flags the primary monitor. DPI via
//!   `GetDpiForMonitor` (Win 8.1+); fallback 1.0 on older.
//! - **Linux** — `gdk_display_get_default` → iterate via
//!   `gdk_display_get_n_monitors` / `gdk_display_get_monitor`.
//!   `gdk_monitor_get_geometry` for bounds;
//!   `gdk_monitor_get_scale_factor` for HiDPI;
//!   `gdk_display_get_primary_monitor` flags primary.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    Unsupported,
    OutOfMemory,
    Backend,
};

pub const Display = struct {
    /// Top-left x of the monitor in virtual-screen coordinates.
    x: i32,
    /// Top-left y of the monitor in virtual-screen coordinates.
    y: i32,
    /// Logical width in OS-logical pixels (not scaled by `scale`).
    width: u32,
    height: u32,
    /// HiDPI factor. `1.0` on standard displays; `2.0` on Retina.
    /// Linux compositors may report fractional values.
    scale: f32,
    /// True for the OS-designated primary monitor.
    primary: bool,
};

/// Enumerate attached displays. Caller frees the returned slice via
/// `allocator.free(slice)`. Order matches the OS enumeration —
/// macOS lists primary first; Windows lists in the order
/// `EnumDisplayMonitors` reports; Linux lists in GDK monitor index
/// order. Apps that need a stable order should sort by `primary`
/// then `x`.
pub fn list(allocator: std.mem.Allocator) Error![]Display {
    return switch (builtin.os.tag) {
        .macos => listMacos(allocator),
        .windows => listWindows(allocator),
        .linux => listLinux(allocator),
        else => error.Unsupported,
    };
}

// ---- macOS — NSScreen.screens ----------------------------------------------

fn listMacos(allocator: std.mem.Allocator) Error![]Display {
    if (builtin.os.tag != .macos) return error.Unsupported;
    const m = @import("msg.zig");
    const id = ?*anyopaque;
    const SEL = ?*anyopaque;
    const NSPoint = extern struct { x: f64, y: f64 };
    const NSSize = extern struct { width: f64, height: f64 };
    const NSRect = extern struct { origin: NSPoint, size: NSSize };

    const NSScreen = m.getClass("NSScreen");
    const screensSel = m.cast(*const fn (id, SEL) callconv(.c) id);
    const screens = screensSel(@as(id, @ptrCast(NSScreen)), m.sel("screens"));
    if (@intFromPtr(screens) == 0) return error.Backend;

    const count_sel = m.cast(*const fn (id, SEL) callconv(.c) usize);
    const n = count_sel(screens, m.sel("count"));
    if (n == 0) return allocator.alloc(Display, 0) catch return error.OutOfMemory;

    // Build a list. The "primary" screen on macOS is index 0 in
    // `[NSScreen screens]`; its frame origin is `(0, 0)` in the
    // bottom-left coordinate system. We need that origin to flip
    // every other screen's y into top-left coordinates.
    const objectAtIndex = m.cast(*const fn (id, SEL, usize) callconv(.c) id);
    const frame_sel = m.cast(*const fn (id, SEL) callconv(.c) NSRect);
    const scale_sel = m.cast(*const fn (id, SEL) callconv(.c) f64);

    // First pass: find the union top edge so we can convert each
    // bottom-left origin into a top-left origin.
    var union_top: f64 = -std.math.inf(f64);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const scr = objectAtIndex(screens, m.sel("objectAtIndex:"), i);
        const r = frame_sel(scr, m.sel("frame"));
        const top = r.origin.y + r.size.height;
        if (top > union_top) union_top = top;
    }

    var out = allocator.alloc(Display, n) catch return error.OutOfMemory;
    i = 0;
    while (i < n) : (i += 1) {
        const scr = objectAtIndex(screens, m.sel("objectAtIndex:"), i);
        const r = frame_sel(scr, m.sel("frame"));
        const scale = scale_sel(scr, m.sel("backingScaleFactor"));
        // Flip Y so origin becomes top-left.
        const top_y = union_top - (r.origin.y + r.size.height);
        out[i] = .{
            .x = @intFromFloat(r.origin.x),
            .y = @intFromFloat(top_y),
            .width = @intFromFloat(@max(r.size.width, 0)),
            .height = @intFromFloat(@max(r.size.height, 0)),
            .scale = @floatCast(scale),
            .primary = i == 0,
        };
    }
    return out;
}

// ---- Windows — EnumDisplayMonitors -----------------------------------------

const RECT = extern struct { left: c_long, top: c_long, right: c_long, bottom: c_long };
const HMONITOR = ?*opaque {};
const HDC = ?*opaque {};
const MONITORINFOF_PRIMARY: u32 = 1;
const CCHDEVICENAME: usize = 32;
const MONITORINFOEXW = extern struct {
    cbSize: u32 = 0,
    rcMonitor: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    rcWork: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    dwFlags: u32 = 0,
    szDevice: [CCHDEVICENAME]u16 = std.mem.zeroes([CCHDEVICENAME]u16),
};

const WinCollect = struct {
    allocator: std.mem.Allocator,
    list_: std.ArrayList(Display),
    err: ?Error = null,
};

extern "user32" fn EnumDisplayMonitors(
    hdc: HDC,
    clip: ?*const RECT,
    callback: *const fn (mon: HMONITOR, hdc_: HDC, rect: *RECT, lparam: isize) callconv(.winapi) c_int,
    lparam: isize,
) callconv(.winapi) c_int;
extern "user32" fn GetMonitorInfoW(mon: HMONITOR, info: *MONITORINFOEXW) callconv(.winapi) c_int;
extern "shcore" fn GetDpiForMonitor(mon: HMONITOR, dpi_type: u32, dpi_x: *u32, dpi_y: *u32) callconv(.winapi) c_long;

fn winMonitorCb(mon: HMONITOR, _hdc: HDC, _rect: *RECT, lparam: isize) callconv(.winapi) c_int {
    _ = _hdc;
    _ = _rect;
    const collect: *WinCollect = @ptrFromInt(@as(usize, @bitCast(lparam)));
    var info: MONITORINFOEXW = .{};
    info.cbSize = @sizeOf(MONITORINFOEXW);
    if (GetMonitorInfoW(mon, &info) == 0) return 1;
    var dpi_x: u32 = 96;
    var dpi_y: u32 = 96;
    // MDT_EFFECTIVE_DPI = 0.
    _ = GetDpiForMonitor(mon, 0, &dpi_x, &dpi_y);
    const display = Display{
        .x = @intCast(info.rcMonitor.left),
        .y = @intCast(info.rcMonitor.top),
        .width = @intCast(info.rcMonitor.right - info.rcMonitor.left),
        .height = @intCast(info.rcMonitor.bottom - info.rcMonitor.top),
        .scale = @as(f32, @floatFromInt(dpi_x)) / 96.0,
        .primary = (info.dwFlags & MONITORINFOF_PRIMARY) != 0,
    };
    collect.list_.append(collect.allocator, display) catch {
        collect.err = error.OutOfMemory;
        return 0;
    };
    return 1;
}

fn listWindows(allocator: std.mem.Allocator) Error![]Display {
    if (builtin.os.tag != .windows) return error.Unsupported;
    var collect = WinCollect{ .allocator = allocator, .list_ = .empty };
    errdefer collect.list_.deinit(allocator);
    const lp: isize = @bitCast(@intFromPtr(&collect));
    _ = EnumDisplayMonitors(null, null, &winMonitorCb, lp);
    if (collect.err) |e| return e;
    return collect.list_.toOwnedSlice(allocator) catch error.OutOfMemory;
}

// ---- Linux — GdkDisplay ----------------------------------------------------

const GdkDisplay = opaque {};
const GdkMonitor = opaque {};
const GdkRectangle = extern struct {
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
};

extern fn gdk_display_get_default() ?*GdkDisplay;
extern fn gdk_display_get_n_monitors(display: *GdkDisplay) c_int;
extern fn gdk_display_get_monitor(display: *GdkDisplay, idx: c_int) ?*GdkMonitor;
extern fn gdk_display_get_primary_monitor(display: *GdkDisplay) ?*GdkMonitor;
extern fn gdk_monitor_get_geometry(monitor: *GdkMonitor, geometry: *GdkRectangle) void;
extern fn gdk_monitor_get_scale_factor(monitor: *GdkMonitor) c_int;

fn listLinux(allocator: std.mem.Allocator) Error![]Display {
    if (builtin.os.tag != .linux) return error.Unsupported;
    const display = gdk_display_get_default() orelse return error.Backend;
    const n = gdk_display_get_n_monitors(display);
    if (n <= 0) return allocator.alloc(Display, 0) catch return error.OutOfMemory;
    const primary = gdk_display_get_primary_monitor(display);

    var out = allocator.alloc(Display, @intCast(n)) catch return error.OutOfMemory;
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        const mon = gdk_display_get_monitor(display, i) orelse continue;
        var rect: GdkRectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        gdk_monitor_get_geometry(mon, &rect);
        const sf = gdk_monitor_get_scale_factor(mon);
        out[@intCast(i)] = .{
            .x = @intCast(rect.x),
            .y = @intCast(rect.y),
            .width = @intCast(@max(rect.width, 0)),
            .height = @intCast(@max(rect.height, 0)),
            .scale = @floatFromInt(sf),
            .primary = mon == primary,
        };
    }
    return out;
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "Display struct shape stable" {
    const d: Display = .{ .x = 0, .y = 0, .width = 1920, .height = 1080, .scale = 2.0, .primary = true };
    try testing.expectEqual(@as(i32, 0), d.x);
    try testing.expectEqual(@as(u32, 1920), d.width);
    try testing.expectEqual(@as(f32, 2.0), d.scale);
    try testing.expect(d.primary);
}
