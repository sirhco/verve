//! Cross-platform desktop notifications.
//!
//! Single one-shot `show(allocator, opts)` call delivers a title +
//! body notification through the platform-native API. No notification
//! actions, no persistence, no per-app permission management in this
//! pass — those sit on the cross-platform surface as a future bundle.
//!
//! Per-platform strategy:
//!
//! - **macOS** — `[NSUserNotification new]` +
//!   `[NSUserNotificationCenter deliverNotification:]`. Deprecated on
//!   macOS 11+ in favor of `UNUserNotificationCenter` but still
//!   functional and avoids the permission-grant flow.
//! - **Linux** — `notify_init` + `notify_notification_new` +
//!   `notify_notification_show`. libnotify is loaded at runtime via
//!   `dlopen("libnotify.so.4")` so scaffolds on distros that don't
//!   ship it still build; the call returns `error.Unsupported`
//!   when the library isn't present at runtime.
//! - **Windows** — `Shell_NotifyIconW(NIM_MODIFY, NIF_INFO)` against
//!   the active `desktop.tray` icon. Renders as a standard Win10/11
//!   balloon tip (older shell) / Action Center entry (modern
//!   shell). Requires `desktop.tray.init` to have been called first;
//!   without an active tray the call returns `error.Backend`. The
//!   modern WinRT `ToastNotificationManager` path needs COM + AUMID +
//!   Start-menu shortcut registration and is deferred.

const std = @import("std");
const builtin = @import("builtin");
const tray_mod = @import("tray.zig");

pub const Error = error{
    Unsupported,
    OutOfMemory,
    Backend,
};

pub const NotificationOptions = struct {
    title: []const u8,
    body: []const u8,
};

pub fn show(allocator: std.mem.Allocator, opts: NotificationOptions) Error!void {
    switch (builtin.os.tag) {
        .macos => return showMacos(allocator, opts),
        .linux => return showLinux(allocator, opts),
        .windows => return showWindows(opts),
        else => return error.Unsupported,
    }
}

fn showWindows(opts: NotificationOptions) Error!void {
    if (builtin.os.tag != .windows) return error.Unsupported;
    // Delegate to the tray module's NIF_INFO helper. The error
    // domain matches ours (Unsupported / Backend), so propagate
    // directly.
    return tray_mod.showWindowsBalloon(opts.title, opts.body) catch |err| switch (err) {
        tray_mod.Error.Unsupported => Error.Unsupported,
        tray_mod.Error.OutOfMemory => Error.OutOfMemory,
        tray_mod.Error.Backend => Error.Backend,
    };
}

// ---- macOS — NSUserNotification --------------------------------------------

const m = if (builtin.os.tag == .macos) @import("msg.zig") else struct {};
const id = ?*anyopaque;
const SEL = ?*anyopaque;

fn showMacos(allocator: std.mem.Allocator, opts: NotificationOptions) Error!void {
    if (builtin.os.tag != .macos) return error.Unsupported;
    _ = allocator;

    const NSUserNotification = m.getClass("NSUserNotification");
    const alloc_id = m.cast(*const fn (id, SEL) callconv(.c) id);
    const init_id = m.cast(*const fn (id, SEL) callconv(.c) id);
    const note = init_id(alloc_id(@as(id, @ptrCast(NSUserNotification)), m.sel("alloc")), m.sel("init"));
    if (@intFromPtr(note) == 0) return error.Backend;

    const setTitle = m.cast(*const fn (id, SEL, id) callconv(.c) void);
    setTitle(note, m.sel("setTitle:"), nsString(opts.title));
    const setInformativeText = m.cast(*const fn (id, SEL, id) callconv(.c) void);
    setInformativeText(note, m.sel("setInformativeText:"), nsString(opts.body));

    const NSUserNotificationCenter = m.getClass("NSUserNotificationCenter");
    const defaultCenter = m.cast(*const fn (id, SEL) callconv(.c) id);
    const center = defaultCenter(
        @as(id, @ptrCast(NSUserNotificationCenter)),
        m.sel("defaultUserNotificationCenter"),
    );
    const deliver = m.cast(*const fn (id, SEL, id) callconv(.c) void);
    deliver(center, m.sel("deliverNotification:"), note);

    const release = m.cast(*const fn (id, SEL) callconv(.c) void);
    release(note, m.sel("release"));
}

fn nsString(s: []const u8) id {
    if (builtin.os.tag != .macos) return null;
    const NSString = m.getClass("NSString");
    const stringWithUTF8 = m.cast(*const fn (id, SEL, [*]const u8) callconv(.c) id);
    var buf: [1024]u8 = undefined;
    const len = @min(s.len, buf.len - 1);
    @memcpy(buf[0..len], s[0..len]);
    buf[len] = 0;
    return stringWithUTF8(@as(id, @ptrCast(NSString)), m.sel("stringWithUTF8String:"), &buf);
}

// ---- Linux — libnotify ------------------------------------------------------

// libnotify is loaded at runtime via dlopen so Verve apps that never
// call `notifications.show` build and run on distros without it.
// Apps that DO call show on a host missing libnotify get
// `error.Unsupported` instead of a link-time failure that affects
// every Linux scaffold.

const NotifyNotification = opaque {};
const GError = opaque {};

const InitFn = *const fn ([*:0]const u8) callconv(.c) c_int;
const IsInittedFn = *const fn () callconv(.c) c_int;
const NewFn = *const fn ([*:0]const u8, ?[*:0]const u8, ?[*:0]const u8) callconv(.c) *NotifyNotification;
const ShowFn = *const fn (*NotifyNotification, ?*?*GError) callconv(.c) c_int;

const LibNotify = struct {
    init: InitFn,
    is_initted: IsInittedFn,
    new: NewFn,
    show: ShowFn,
};

var g_libnotify: ?LibNotify = null;
var g_libnotify_tried: bool = false;

fn loadLibnotify() ?*const LibNotify {
    if (g_libnotify_tried) {
        return if (g_libnotify) |*v| v else null;
    }
    g_libnotify_tried = true;

    const candidates = [_][:0]const u8{
        "libnotify.so.4",
        "libnotify.so",
    };
    var handle: ?*anyopaque = null;
    for (candidates) |name| {
        handle = std.c.dlopen(name.ptr, .{ .LAZY = true });
        if (handle != null) break;
    }
    if (handle == null) return null;

    const init_p = std.c.dlsym(handle, "notify_init") orelse return null;
    const is_initted_p = std.c.dlsym(handle, "notify_is_initted") orelse return null;
    const new_p = std.c.dlsym(handle, "notify_notification_new") orelse return null;
    const show_p = std.c.dlsym(handle, "notify_notification_show") orelse return null;

    g_libnotify = .{
        .init = @ptrCast(@alignCast(init_p)),
        .is_initted = @ptrCast(@alignCast(is_initted_p)),
        .new = @ptrCast(@alignCast(new_p)),
        .show = @ptrCast(@alignCast(show_p)),
    };
    return &g_libnotify.?;
}

// g_object_unref lives in glib (already linked transitively via gtk).
extern fn g_object_unref(o: ?*anyopaque) void;

fn showLinux(allocator: std.mem.Allocator, opts: NotificationOptions) Error!void {
    if (builtin.os.tag != .linux) return error.Unsupported;

    const ln = loadLibnotify() orelse return error.Unsupported;

    if (ln.is_initted() == 0) {
        const app_z = allocator.dupeZ(u8, "verve-desktop") catch return error.OutOfMemory;
        defer allocator.free(app_z);
        if (ln.init(app_z.ptr) == 0) return error.Backend;
    }

    const title_z = allocator.dupeZ(u8, opts.title) catch return error.OutOfMemory;
    defer allocator.free(title_z);
    const body_z = allocator.dupeZ(u8, opts.body) catch return error.OutOfMemory;
    defer allocator.free(body_z);

    const note = ln.new(title_z.ptr, body_z.ptr, null);
    defer g_object_unref(@ptrCast(note));
    if (ln.show(note, null) == 0) return error.Backend;
}
