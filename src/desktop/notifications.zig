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
//!   `notify_notification_show`. Requires `libnotify` to be linked
//!   into the binary; nearly every desktop installs it by default.
//! - **Windows** — returns `error.Unsupported`. Modern Win10+ uses
//!   Toast notifications which require COM + AUMID + Start-menu
//!   registration; legacy balloon tips are tied to a tray icon and
//!   the tray module's `Tray.notify` will be the cross-cut once it
//!   ships. Apps that want Win notifications today fall back to
//!   `tray.zig` plus a manual `Shell_NotifyIconW(NIF_INFO)` call.

const std = @import("std");
const builtin = @import("builtin");

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
        .windows => return error.Unsupported,
        else => return error.Unsupported,
    }
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

const NotifyNotification = opaque {};
const GError = opaque {};

extern fn notify_init(app_name: [*:0]const u8) c_int;
extern fn notify_is_initted() c_int;
extern fn notify_notification_new(
    summary: [*:0]const u8,
    body: ?[*:0]const u8,
    icon: ?[*:0]const u8,
) *NotifyNotification;
extern fn notify_notification_show(notification: *NotifyNotification, err: ?*?*GError) c_int;
extern fn g_object_unref(o: ?*anyopaque) void;

fn showLinux(allocator: std.mem.Allocator, opts: NotificationOptions) Error!void {
    if (builtin.os.tag != .linux) return error.Unsupported;

    if (notify_is_initted() == 0) {
        const app_z = allocator.dupeZ(u8, "verve-desktop") catch return error.OutOfMemory;
        defer allocator.free(app_z);
        if (notify_init(app_z.ptr) == 0) return error.Backend;
    }

    const title_z = allocator.dupeZ(u8, opts.title) catch return error.OutOfMemory;
    defer allocator.free(title_z);
    const body_z = allocator.dupeZ(u8, opts.body) catch return error.OutOfMemory;
    defer allocator.free(body_z);

    const note = notify_notification_new(title_z.ptr, body_z.ptr, null);
    defer g_object_unref(@ptrCast(note));
    if (notify_notification_show(note, null) == 0) return error.Backend;
}
