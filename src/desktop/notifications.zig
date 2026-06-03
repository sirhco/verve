//! Cross-platform desktop notifications.
//!
//! Single one-shot `show(allocator, opts)` call delivers a title +
//! body notification through the platform-native API. No notification
//! actions, no persistence, no per-app permission management in this
//! pass — those sit on the cross-platform surface as a future bundle.
//!
//! Per-platform strategy:
//!
//! - **macOS** — `UNUserNotificationCenter`. Requires a signed app
//!   bundle (a bare/un-bundled process has no bundle id and is rejected
//!   with `error.Unsupported`). The first `show` lazily requests
//!   authorization and pumps a nested `NSRunLoop` until the grant
//!   resolves (cookies/snapshot idiom); a denied grant yields
//!   `error.Unsupported`. Delivery builds a `UNMutableNotificationContent`
//!   + `UNNotificationRequest` (nil trigger = immediate).
//! - **Linux** — `notify_init` + `notify_notification_new` +
//!   `notify_notification_show`. libnotify is loaded at runtime via
//!   `dlopen("libnotify.so.4")` so scaffolds on distros that don't
//!   ship it still build; the call returns `error.Unsupported`
//!   when the library isn't present at runtime.
//! - **Windows** — prefers the modern WinRT `ToastNotificationManager`
//!   path (`windows.showToast`): sets a per-app AUMID, lazily creates the
//!   Start-menu shortcut that carries it, then activates an `XmlDocument`
//!   `ToastGeneric` template and `IToastNotifier::Show` — a rich Action
//!   Center toast that needs no tray icon. If WinRT activation fails it
//!   falls back to `Shell_NotifyIconW(NIM_MODIFY, NIF_INFO)` against the
//!   active `desktop.tray` icon (a balloon tip), which requires
//!   `desktop.tray.init` first and otherwise returns `error.Backend`.

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
        .windows => return showWindows(allocator, opts),
        else => return error.Unsupported,
    }
}

fn showWindows(allocator: std.mem.Allocator, opts: NotificationOptions) Error!void {
    if (builtin.os.tag != .windows) return error.Unsupported;
    const win = @import("windows.zig");
    // Prefer the modern WinRT Action Center toast (rich styling + Action
    // Center grouping, no tray icon required). If it can't initialise —
    // older shell, no AUMID shortcut writable, WinRT activation failure —
    // fall back to the legacy `Shell_NotifyIconW` balloon, which needs an
    // active tray icon (`desktop.tray.init`).
    win.showToast(allocator, opts.title, opts.body) catch {
        return tray_mod.showWindowsBalloon(opts.title, opts.body) catch |err| switch (err) {
            tray_mod.Error.Unsupported => Error.Unsupported,
            tray_mod.Error.OutOfMemory => Error.OutOfMemory,
            tray_mod.Error.Backend => Error.Backend,
        };
    };
}

// ---- macOS — UNUserNotificationCenter --------------------------------------

const m = if (builtin.os.tag == .macos) @import("msg.zig") else struct {};
const id = ?*anyopaque;
const SEL = ?*anyopaque;

extern const _NSConcreteStackBlock: anyopaque;

const BlockDescriptor = extern struct {
    reserved: c_ulong = 0,
    size: c_ulong,
};
const auth_block_desc: BlockDescriptor = .{ .size = @sizeOf(AuthBlock) };

/// Completion block for `requestAuthorizationWithOptions:completionHandler:`.
/// Invoke signature `(block, BOOL granted, NSError *error)`. BOOL maps to
/// Zig `bool` on 64-bit darwin per the `msg.zig` ABI audit.
const AuthBlock = extern struct {
    isa: *const anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const fn (*AuthBlock, bool, id) callconv(.c) void,
    descriptor: *const BlockDescriptor,
    granted: *bool,
    done: *bool,
};

fn authBlockInvoke(block: *AuthBlock, granted: bool, err: id) callconv(.c) void {
    _ = err;
    block.granted.* = granted;
    block.done.* = true;
}

// Process-wide authorization cache (requested once) + monotonic request id.
var g_auth: ?bool = null;
var g_note_seq: std.atomic.Value(u32) = .init(0);

/// Spin the current run loop in default mode until `done` flips. Mirrors
/// `macos.zig`'s helper. Re-entrancy: safe from IPC handlers (default
/// mode); unsafe from inside a modal run loop.
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

fn showMacos(allocator: std.mem.Allocator, opts: NotificationOptions) Error!void {
    if (builtin.os.tag != .macos) return error.Unsupported;
    _ = allocator;

    // UNUserNotificationCenter requires a bundle identifier; a bare
    // (un-bundled) process raises on `currentNotificationCenter`.
    const NSBundle = m.getClass("NSBundle");
    const mainBundle = m.cast(*const fn (id, SEL) callconv(.c) id);
    const bundle = mainBundle(@as(id, @ptrCast(NSBundle)), m.sel("mainBundle"));
    const bundleId = m.cast(*const fn (id, SEL) callconv(.c) id);
    const bid = bundleId(bundle, m.sel("bundleIdentifier"));
    if (@intFromPtr(bid) == 0) {
        std.log.warn("verve.desktop[macos]: notifications require an app bundle (no bundle id); skipping", .{});
        return error.Unsupported;
    }

    const UNUserNotificationCenter = m.getClass("UNUserNotificationCenter");
    const currentCenter = m.cast(*const fn (id, SEL) callconv(.c) id);
    const center = currentCenter(
        @as(id, @ptrCast(UNUserNotificationCenter)),
        m.sel("currentNotificationCenter"),
    );
    if (@intFromPtr(center) == 0) return error.Backend;

    // Lazy one-time authorization, synchronous via nested run-loop pump.
    if (g_auth == null) {
        var granted: bool = false;
        var done: bool = false;
        var block: AuthBlock = .{
            .isa = &_NSConcreteStackBlock,
            .flags = 0,
            .reserved = 0,
            .invoke = &authBlockInvoke,
            .descriptor = &auth_block_desc,
            .granted = &granted,
            .done = &done,
        };
        const UNAuthorizationOptionSound: c_ulong = 1 << 1;
        const UNAuthorizationOptionAlert: c_ulong = 1 << 2;
        const requestAuth = m.cast(*const fn (id, SEL, c_ulong, *AuthBlock) callconv(.c) void);
        requestAuth(
            center,
            m.sel("requestAuthorizationWithOptions:completionHandler:"),
            UNAuthorizationOptionAlert | UNAuthorizationOptionSound,
            &block,
        );
        pumpUntilDone(&done);
        g_auth = granted;
    }
    if (!(g_auth orelse false)) return error.Unsupported;

    // Build the notification content.
    const UNMutableNotificationContent = m.getClass("UNMutableNotificationContent");
    const alloc_id = m.cast(*const fn (id, SEL) callconv(.c) id);
    const init_id = m.cast(*const fn (id, SEL) callconv(.c) id);
    const content = init_id(
        alloc_id(@as(id, @ptrCast(UNMutableNotificationContent)), m.sel("alloc")),
        m.sel("init"),
    );
    if (@intFromPtr(content) == 0) return error.Backend;
    const release = m.cast(*const fn (id, SEL) callconv(.c) void);

    const setTitle = m.cast(*const fn (id, SEL, id) callconv(.c) void);
    setTitle(content, m.sel("setTitle:"), nsString(opts.title));
    const setBody = m.cast(*const fn (id, SEL, id) callconv(.c) void);
    setBody(content, m.sel("setBody:"), nsString(opts.body));

    // Unique request identifier from a process-static counter.
    var idbuf: [32]u8 = undefined;
    const seq = g_note_seq.fetchAdd(1, .monotonic);
    const ident = std.fmt.bufPrint(&idbuf, "verve-note-{d}", .{seq}) catch "verve-note";

    const UNNotificationRequest = m.getClass("UNNotificationRequest");
    const reqWith = m.cast(*const fn (id, SEL, id, id, id) callconv(.c) id);
    const req = reqWith(
        @as(id, @ptrCast(UNNotificationRequest)),
        m.sel("requestWithIdentifier:content:trigger:"),
        nsString(ident),
        content,
        null,
    );
    if (@intFromPtr(req) == 0) {
        release(content, m.sel("release"));
        return error.Backend;
    }

    const addReq = m.cast(*const fn (id, SEL, id, ?*anyopaque) callconv(.c) void);
    addReq(center, m.sel("addNotificationRequest:withCompletionHandler:"), req, null);

    release(content, m.sel("release"));
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
