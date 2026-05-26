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
/// `bundle_id` semantics per platform:
/// - **macOS** — the `CFBundleIdentifier` of the running `.app`.
///   The bundle must already declare the scheme via
///   `CFBundleURLTypes`. The call returns `error.Backend` when
///   the running process isn't bundled.
/// - **Windows** — a display label used as the registry key's
///   default value (`URL:<bundle_id>` form). The actual handler
///   binary is resolved at runtime via `GetModuleFileNameW`. No
///   bundle layout required.
/// - **Linux** — the basename for the generated `.desktop` file
///   under `~/.local/share/applications/<bundle_id>.desktop`.
///   The handler binary is resolved via `/proc/self/exe`.
///   `xdg-mime default ...` is then invoked to set the
///   association.
pub fn registerScheme(allocator: std.mem.Allocator, scheme: []const u8, bundle_id: []const u8) Error!void {
    return backend.registerScheme(allocator, scheme, bundle_id);
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

    fn registerScheme(allocator: std.mem.Allocator, scheme: []const u8, bundle_id: []const u8) Error!void {
        _ = allocator;
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

    // Registry surface for registerScheme — mirrors the autostart.zig
    // pattern. advapi32 / kernel32 are auto-linked via the `extern "<lib>"`
    // hints, so no template build.zig changes are needed.
    const HKEY = ?*opaque {};
    const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
    const KEY_WRITE: u32 = 0x20006;
    const REG_SZ: u32 = 1;
    const ERROR_SUCCESS: c_long = 0;

    extern "advapi32" fn RegCreateKeyExW(
        hkey: HKEY,
        sub: ?[*:0]const u16,
        reserved: u32,
        class: ?[*:0]const u16,
        options: u32,
        access: u32,
        sa: ?*anyopaque,
        out: *HKEY,
        disposition: ?*u32,
    ) callconv(.winapi) c_long;
    extern "advapi32" fn RegSetValueExW(
        hkey: HKEY,
        name: ?[*:0]const u16,
        reserved: u32,
        ty: u32,
        data: ?[*]const u8,
        size: u32,
    ) callconv(.winapi) c_long;
    extern "advapi32" fn RegCloseKey(hkey: HKEY) callconv(.winapi) c_long;
    extern "kernel32" fn GetModuleFileNameW(
        hModule: ?*anyopaque,
        lpFilename: [*]u16,
        nSize: u32,
    ) callconv(.winapi) u32;

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

    fn registerScheme(allocator: std.mem.Allocator, scheme: []const u8, bundle_id: []const u8) Error!void {
        if (builtin.os.tag != .windows) return error.Unsupported;
        if (scheme.len == 0 or scheme.len >= 128) return error.Backend;
        if (bundle_id.len == 0 or bundle_id.len >= 256) return error.Backend;
        // Reject schemes containing path separators or other registry-
        // unsafe characters — the scheme becomes a key name and must
        // be a single path component.
        for (scheme) |ch| {
            if (ch == '\\' or ch == '/' or ch == 0) return error.Backend;
        }

        // Resolve the running executable's absolute path.
        var exe_w: [4096]u16 = undefined;
        const len = GetModuleFileNameW(null, &exe_w, exe_w.len);
        if (len == 0 or len >= exe_w.len) return error.Backend;
        const exe_path_w = exe_w[0..len];

        // Compose `"<exe_path>" "%1"` for the shell\open\command default
        // value, in UTF-16 directly (skip a UTF-8 round-trip).
        var cmd_w: std.ArrayList(u16) = .empty;
        defer cmd_w.deinit(allocator);
        try cmd_w.append(allocator, '"');
        try cmd_w.appendSlice(allocator, exe_path_w);
        try cmd_w.appendSlice(allocator, &[_]u16{ '"', ' ', '"', '%', '1', '"' });
        try cmd_w.append(allocator, 0);

        // HKCU\Software\Classes\<scheme>
        const key_path_u8 = std.fmt.allocPrint(allocator, "Software\\Classes\\{s}", .{scheme}) catch return error.OutOfMemory;
        defer allocator.free(key_path_u8);
        const key_path_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, key_path_u8) catch return error.OutOfMemory;
        defer allocator.free(key_path_w);

        var scheme_key: HKEY = null;
        if (RegCreateKeyExW(HKEY_CURRENT_USER, key_path_w.ptr, 0, null, 0, KEY_WRITE, null, &scheme_key, null) != ERROR_SUCCESS) {
            return error.Backend;
        }
        defer _ = RegCloseKey(scheme_key);

        // (Default) = "URL:<bundle_id>"
        const default_u8 = std.fmt.allocPrint(allocator, "URL:{s}", .{bundle_id}) catch return error.OutOfMemory;
        defer allocator.free(default_u8);
        const default_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, default_u8) catch return error.OutOfMemory;
        defer allocator.free(default_w);
        const default_bytes: u32 = @intCast((default_w.len + 1) * @sizeOf(u16));
        if (RegSetValueExW(scheme_key, null, 0, REG_SZ, @ptrCast(default_w.ptr), default_bytes) != ERROR_SUCCESS) return error.Backend;

        // "URL Protocol" = "" — the marker Windows uses to recognize
        // this key as a URL-protocol handler.
        const url_proto_name = std.unicode.utf8ToUtf16LeStringLiteral("URL Protocol");
        const empty: [1]u16 = .{0};
        if (RegSetValueExW(scheme_key, url_proto_name, 0, REG_SZ, @ptrCast(&empty), @sizeOf(u16)) != ERROR_SUCCESS) return error.Backend;

        // ...\shell\open\command (Default) = `"<exe>" "%1"`
        const cmd_subkey_u8 = std.fmt.allocPrint(allocator, "Software\\Classes\\{s}\\shell\\open\\command", .{scheme}) catch return error.OutOfMemory;
        defer allocator.free(cmd_subkey_u8);
        const cmd_subkey_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, cmd_subkey_u8) catch return error.OutOfMemory;
        defer allocator.free(cmd_subkey_w);

        var cmd_key: HKEY = null;
        if (RegCreateKeyExW(HKEY_CURRENT_USER, cmd_subkey_w.ptr, 0, null, 0, KEY_WRITE, null, &cmd_key, null) != ERROR_SUCCESS) {
            return error.Backend;
        }
        defer _ = RegCloseKey(cmd_key);

        const cmd_bytes: u32 = @intCast(cmd_w.items.len * @sizeOf(u16));
        if (RegSetValueExW(cmd_key, null, 0, REG_SZ, @ptrCast(cmd_w.items.ptr), cmd_bytes) != ERROR_SUCCESS) return error.Backend;
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

    fn registerScheme(allocator: std.mem.Allocator, scheme: []const u8, bundle_id: []const u8) Error!void {
        if (builtin.os.tag != .linux) return error.Unsupported;
        if (scheme.len == 0 or scheme.len >= 128) return error.Backend;
        if (bundle_id.len == 0 or bundle_id.len >= 256) return error.Backend;
        // bundle_id becomes the .desktop filename — no separators.
        for (bundle_id) |ch| {
            if (ch == '/' or ch == '\\' or ch == 0) return error.Backend;
        }
        for (scheme) |ch| {
            if (ch == '/' or ch == '\\' or ch == 0 or ch == ';') return error.Backend;
        }

        // Resolve $HOME without bringing in std.process.Environ —
        // posix getenv is the canonical lookup and matches the rest
        // of the Linux backend.
        const home_ptr = std.c.getenv("HOME") orelse return error.Backend;
        const home = std.mem.sliceTo(home_ptr, 0);
        if (home.len == 0) return error.Backend;

        // /proc/self/exe symlink → absolute exe path.
        var exe_buf: [4096]u8 = undefined;
        const exe_len = readlink("/proc/self/exe", &exe_buf, exe_buf.len);
        if (exe_len <= 0 or @as(usize, @intCast(exe_len)) >= exe_buf.len) return error.Backend;
        const exe_path = exe_buf[0..@intCast(exe_len)];

        const apps_dir = std.fmt.allocPrint(allocator, "{s}/.local/share/applications", .{home}) catch return error.OutOfMemory;
        defer allocator.free(apps_dir);

        // mkdir -p the parent. POSIX `mkdir` returns -1 with EEXIST
        // when the dir already exists, which we treat as success.
        mkdirP(allocator, apps_dir) catch return error.Backend;

        const desktop_path = std.fmt.allocPrint(allocator, "{s}/{s}.desktop", .{ apps_dir, bundle_id }) catch return error.OutOfMemory;
        defer allocator.free(desktop_path);
        const desktop_path_z = allocator.dupeZ(u8, desktop_path) catch return error.OutOfMemory;
        defer allocator.free(desktop_path_z);

        // .desktop entry. NoDisplay=true keeps it out of the
        // application menu — this is a URL handler, not a launcher.
        // StartupWMClass mirrors the GTK WM_CLASS set by `linux.zig`
        // so xdotool / wmctrl can pin the running window.
        const content = std.fmt.allocPrint(allocator,
            \\[Desktop Entry]
            \\Type=Application
            \\Name={s}
            \\Exec="{s}" %u
            \\NoDisplay=true
            \\MimeType=x-scheme-handler/{s};
            \\Terminal=false
            \\StartupNotify=true
            \\StartupWMClass={s}
            \\
        , .{ bundle_id, exe_path, scheme, bundle_id }) catch return error.OutOfMemory;
        defer allocator.free(content);

        writeFileAtomic(desktop_path_z, content) catch return error.Backend;

        // v1 stops here. The freedesktop spec says a `.desktop` file
        // with `MimeType=x-scheme-handler/<scheme>` advertised in a
        // user-applications directory is sufficient for the OS to
        // register the app as a handler on the next desktop-database
        // refresh. Setting it as the *default* handler when a user
        // already has another handler installed requires
        // `xdg-mime default <id>.desktop x-scheme-handler/<scheme>`
        // — the framework intentionally does not shell out here
        // (avoids needing an `io: std.Io` parameter for a
        // best-effort side effect). Apps that want the explicit
        // default-set can run that command themselves after this
        // call returns.
    }

    extern "c" fn readlink(path: [*:0]const u8, buf: [*]u8, bufsize: usize) isize;
    extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
    extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
    extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
    extern "c" fn __errno_location() *c_int;

    const O_WRONLY: c_int = 0o1;
    const O_CREAT: c_int = 0o100;
    const O_TRUNC: c_int = 0o1000;
    const EEXIST: c_int = 17;

    fn mkdirP(allocator: std.mem.Allocator, path: []const u8) !void {
        // Walk components, mkdir each one. Idempotent: EEXIST is fine.
        var i: usize = 1; // skip leading '/'
        while (i <= path.len) : (i += 1) {
            if (i == path.len or path[i] == '/') {
                const prefix = path[0..i];
                const z = try allocator.dupeZ(u8, prefix);
                defer allocator.free(z);
                if (mkdir(z.ptr, 0o755) != 0) {
                    if (__errno_location().* != EEXIST) return error.Backend;
                }
            }
        }
    }

    fn writeFileAtomic(path_z: [:0]const u8, data: []const u8) !void {
        const fd = open(path_z.ptr, O_WRONLY | O_CREAT | O_TRUNC, 0o644);
        if (fd < 0) return error.Backend;
        defer _ = close(fd);
        var written: usize = 0;
        while (written < data.len) {
            const n = write(fd, data.ptr + written, data.len - written);
            if (n < 0) return error.Backend;
            written += @intCast(n);
        }
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
