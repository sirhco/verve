//! Deep-link URL forwarding between processes.
//!
//! macOS handles warm-launch URL delivery natively via
//! `NSAppleEventManager` — the OS never spawns a second process when
//! a `verve://...` URL is clicked while the app is running. Windows
//! and Linux do spawn a second process: the OS finds the registered
//! handler binary, runs it with the URL in argv, and that second
//! instance has to (a) detect via `single_instance` that a copy is
//! already alive and (b) hand the URL off to the running instance.
//!
//! This module exposes the two halves of that handoff:
//!
//! - `forwardToRunningInstance(allocator, name, url)` — second-instance
//!   call. Locates the running instance by `name` and ships `url` over
//!   to it via the platform-native IPC. Returns `error.NotFound` when
//!   no running instance is reachable (the caller usually falls back to
//!   starting up normally in that case).
//!
//! - `startListener(window, name)` — running-instance call. Binds the
//!   receive end of the IPC. Inbound URLs route through the window's
//!   `setUrlOpenHandler` callback.
//!
//! macOS makes both calls no-ops; the AEH installed by
//! `Window.setUrlOpenHandler` already covers warm-launch delivery.

const std = @import("std");
const builtin = @import("builtin");
const window_mod = @import("window.zig");
// Linux backend is reached directly for GIOChannel-side socket
// attachment. Other targets shortcut to a void struct so the import
// graph stays acyclic and the file compiles on every host.
const linux_backend = if (builtin.os.tag == .linux) @import("linux.zig") else struct {};

pub const Error = error{
    /// The platform does not require / does not support cross-process
    /// URL forwarding for this operation. macOS returns this from
    /// `forwardToRunningInstance` because the OS does not spawn a
    /// second instance — Cocoa routes URLs through the existing
    /// process's AEH directly.
    Unsupported,
    /// No running instance answered. The single-instance lock was held
    /// at acquisition time but the window-/socket-bound listener was
    /// not reachable (e.g. the running process is still in early
    /// startup before `startListener` ran, or `name` doesn't match).
    NotFound,
    OutOfMemory,
    /// Native socket / window-discovery failure. Diagnose with the OS
    /// (`GetLastError`, `errno`) when this fires in practice — the
    /// framework collapses the various failure modes into one tag so
    /// call sites stay short.
    Backend,
};

pub fn forwardToRunningInstance(
    allocator: std.mem.Allocator,
    name: []const u8,
    url: []const u8,
) Error!void {
    return backend.forwardToRunningInstance(allocator, name, url);
}

pub fn startListener(window: *window_mod.Window, name: []const u8) Error!void {
    return backend.startListener(window, name);
}

/// Register this app as the default handler for `<scheme>://...`
/// URLs at runtime. Complements the build-time path
/// (`-Durl-scheme=verve` on macOS injects `CFBundleURLTypes` into
/// `Info.plist`); the runtime call is useful when the app wants
/// to claim a scheme conditionally (after a setting toggle, on
/// first launch, etc).
///
/// - **macOS** — `LSSetDefaultHandlerForURLScheme` from
///   LaunchServices. Requires the app to be a bundled `.app`
///   with a `CFBundleIdentifier` matching `bundle_id`; bare
///   `zig-out/bin/app` invocations have no bundle and the call
///   returns `error.Backend`. The bundle must also already
///   declare the scheme via `CFBundleURLTypes` — Launch Services
///   refuses to associate a scheme with an app that doesn't
///   advertise it. So this is "switch which already-known
///   bundle handles the scheme," not "advertise a brand new
///   scheme from a non-bundle binary."
/// - **Windows + Linux** — return `error.Unsupported`. Win
///   needs `HKCU\Software\Classes\<scheme>` registry tree;
///   Linux needs `.desktop` + `xdg-mime`. Future bundles.
pub fn registerScheme(scheme: []const u8, bundle_id: []const u8) Error!void {
    return backend.registerScheme(scheme, bundle_id);
}

const backend = switch (builtin.os.tag) {
    .macos => MacosBackend,
    .windows => WindowsBackend,
    .linux => LinuxBackend,
    else => @compileError("verve.desktop.deep_link: unsupported OS"),
};

// ---- macOS — both calls are no-ops, AEH covers warm-launch -----------------

const MacosBackend = struct {
    fn forwardToRunningInstance(_: std.mem.Allocator, _: []const u8, _: []const u8) Error!void {
        return error.Unsupported;
    }
    fn startListener(_: *window_mod.Window, _: []const u8) Error!void {}

    fn registerScheme(scheme: []const u8, bundle_id: []const u8) Error!void {
        if (builtin.os.tag != .macos) return error.Unsupported;
        if (scheme.len == 0 or scheme.len >= 256) return error.Backend;
        if (bundle_id.len == 0 or bundle_id.len >= 512) return error.Backend;

        var s_buf: [256]u8 = undefined;
        @memcpy(s_buf[0..scheme.len], scheme);
        s_buf[scheme.len] = 0;
        var b_buf: [512]u8 = undefined;
        @memcpy(b_buf[0..bundle_id.len], bundle_id);
        b_buf[bundle_id.len] = 0;

        const cf_scheme = CFStringCreateWithCString(null, @ptrCast(&s_buf), kCFStringEncodingUTF8) orelse return error.Backend;
        defer CFRelease(cf_scheme);
        const cf_bundle = CFStringCreateWithCString(null, @ptrCast(&b_buf), kCFStringEncodingUTF8) orelse return error.Backend;
        defer CFRelease(cf_bundle);

        const status = LSSetDefaultHandlerForURLScheme(cf_scheme, cf_bundle);
        if (status != 0) return error.Backend;
    }
};

// LaunchServices: claim default handler for a URL scheme. Returns
// 0 on success, non-zero OSStatus on failure.
const kCFStringEncodingUTF8: u32 = 0x08000100;
extern "CoreFoundation" fn CFStringCreateWithCString(
    allocator: ?*anyopaque,
    cstr: [*:0]const u8,
    encoding: u32,
) ?*anyopaque;
extern "CoreFoundation" fn CFRelease(cf: *anyopaque) void;
extern "CoreServices" fn LSSetDefaultHandlerForURLScheme(
    scheme: *anyopaque,
    bundle_id: *anyopaque,
) i32;

// ---- Windows — FindWindowW + SendMessageW(WM_COPYDATA) ---------------------

const WindowsBackend = struct {
    const HWND = ?*opaque {};
    const UINT = c_uint;
    const WPARAM = usize;
    const LPARAM = isize;
    const LRESULT = isize;
    const LPCWSTR = ?[*:0]const u16;

    const COPYDATASTRUCT = extern struct {
        dwData: usize,
        cbData: c_ulong,
        lpData: ?*const anyopaque,
    };

    const WM_COPYDATA: UINT = 0x004A;
    /// Sentinel `dwData` value the receiver checks before treating the
    /// payload as a URL. Apps that hand WM_COPYDATA messages directly
    /// (without going through this module) won't match the sentinel
    /// and the receiver ignores them.
    const URL_SENTINEL: usize = 0x55524C00; // "URL\0" in little-endian

    extern "user32" fn FindWindowW(class_name: LPCWSTR, window_name: LPCWSTR) callconv(.winapi) HWND;
    extern "user32" fn SendMessageW(hwnd: HWND, msg: UINT, w: WPARAM, l: LPARAM) callconv(.winapi) LRESULT;

    fn forwardToRunningInstance(_: std.mem.Allocator, _: []const u8, url: []const u8) Error!void {
        // Locate the running app by window-class name. Every Verve
        // window registers under "VerveWindow" (see `windows.zig`
        // `Window.init`). `name` is currently unused — Win32 window
        // classes already disambiguate at the process level since
        // single_instance guarantees only one Verve process per user
        // session.
        const class_name = std.unicode.utf8ToUtf16LeStringLiteral("VerveWindow");
        const hwnd = FindWindowW(class_name, null) orelse return error.NotFound;

        const cds: COPYDATASTRUCT = .{
            .dwData = URL_SENTINEL,
            .cbData = @intCast(url.len),
            .lpData = url.ptr,
        };
        // `SendMessageW` is synchronous — the receiver's wndProc runs
        // before this returns. That's the right semantic: when this
        // call completes the running instance has processed the URL.
        _ = SendMessageW(hwnd, WM_COPYDATA, 0, @as(LPARAM, @bitCast(@intFromPtr(&cds))));
    }

    fn startListener(_: *window_mod.Window, _: []const u8) Error!void {
        // No-op on Windows: the wndProc already handles WM_COPYDATA
        // (added alongside this module). The listener side is purely
        // declarative — registering a window class is sufficient.
    }

    fn registerScheme(_: []const u8, _: []const u8) Error!void {
        // Requires HKCU\Software\Classes\<scheme> registry tree
        // (DefaultIcon + shell\open\command). Future bundle.
        return error.Unsupported;
    }
};

// ---- Linux — abstract AF_UNIX SOCK_DGRAM ------------------------------------

const LinuxBackend = struct {
    const AF_UNIX: c_int = 1;
    const SOCK_DGRAM: c_int = 2;
    const SOCK_CLOEXEC: c_int = 0o2000000;
    const SOCK_NONBLOCK: c_int = 0o4000;

    /// `sockaddr_un` from `<sys/un.h>`. The 108-byte path is the
    /// glibc / musl convention; abstract sockets use the path bytes
    /// starting with a NUL.
    const sockaddr_un = extern struct {
        sun_family: u16,
        sun_path: [108]u8,
    };

    extern "c" fn socket(domain: c_int, ty: c_int, protocol: c_int) c_int;
    extern "c" fn bind(fd: c_int, addr: *const sockaddr_un, addrlen: c_uint) c_int;
    extern "c" fn connect(fd: c_int, addr: *const sockaddr_un, addrlen: c_uint) c_int;
    extern "c" fn send(fd: c_int, buf: *const anyopaque, len: usize, flags: c_int) isize;
    extern "c" fn recv(fd: c_int, buf: *anyopaque, len: usize, flags: c_int) isize;
    extern "c" fn close(fd: c_int) c_int;

    fn forwardToRunningInstance(allocator: std.mem.Allocator, name: []const u8, url: []const u8) Error!void {
        _ = allocator;
        if (url.len == 0 or url.len > 4096) return error.Backend;

        var addr: sockaddr_un = .{ .sun_family = AF_UNIX, .sun_path = std.mem.zeroes([108]u8) };
        const path_len = buildAbstractPath(&addr.sun_path, name) catch return error.Backend;

        const fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
        if (fd < 0) return error.Backend;
        defer _ = close(fd);

        // `connect` on a SOCK_DGRAM socket sets the default peer; the
        // subsequent `send` requires no addr argument. The address
        // length includes `sun_family` (2 bytes) + the abstract name
        // length including the leading NUL.
        const addr_len: c_uint = @intCast(@sizeOf(u16) + path_len);
        if (connect(fd, &addr, addr_len) != 0) return error.NotFound;
        const sent = send(fd, url.ptr, url.len, 0);
        if (sent < 0) return error.Backend;
    }

    fn startListener(window: *window_mod.Window, name: []const u8) Error!void {
        var addr: sockaddr_un = .{ .sun_family = AF_UNIX, .sun_path = std.mem.zeroes([108]u8) };
        const path_len = buildAbstractPath(&addr.sun_path, name) catch return error.Backend;

        const fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
        if (fd < 0) return error.Backend;

        const addr_len: c_uint = @intCast(@sizeOf(u16) + path_len);
        if (bind(fd, &addr, addr_len) != 0) {
            _ = close(fd);
            return error.Backend;
        }

        // Hand the fd to the GTK backend so it can wrap it in a
        // GIOChannel watch. The backend-internal call lives in
        // linux.zig because the GTK externs are declared there.
        linux_backend.attachUrlSocket(window, fd) catch |err| {
            _ = close(fd);
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.Backend,
            }
        };
    }

    fn registerScheme(_: []const u8, _: []const u8) Error!void {
        // Requires writing ~/.local/share/applications/<name>.desktop
        // with `MimeType=x-scheme-handler/<scheme>;` + invoking
        // `xdg-mime default ...`. Future bundle.
        return error.Unsupported;
    }

    /// Build the abstract-socket path bytes. Format: a leading NUL
    /// followed by `"verve-deeplink-" ++ name`. Returns the total
    /// path length including the leading NUL.
    fn buildAbstractPath(buf: *[108]u8, name: []const u8) !usize {
        const prefix = "verve-deeplink-";
        const total = 1 + prefix.len + name.len;
        if (total > buf.len) return error.Backend;
        buf[0] = 0;
        @memcpy(buf[1..][0..prefix.len], prefix);
        @memcpy(buf[1 + prefix.len ..][0..name.len], name);
        return total;
    }
};

/// Cap on the URL bytes a single WM_COPYDATA / datagram delivery may
/// carry. Long enough for any realistic OAuth callback URL but bounded
/// so a hostile sender can't slow the running process by flooding it.
pub const max_url_bytes: usize = 4096;
