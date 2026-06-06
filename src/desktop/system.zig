//! Small grab-bag of host-system queries: user locale, OS version
//! string. Apps that want to localize formatting, log diagnostic
//! context, or branch on OS version use these.
//!
//! Per-platform strategy:
//!
//! - **macOS** — `[[NSLocale currentLocale] localeIdentifier]` for
//!   the BCP-47-ish tag (e.g. `en_US`), and
//!   `[NSProcessInfo.processInfo operatingSystemVersionString]` for
//!   the human-readable OS string.
//! - **Windows** — `GetUserDefaultLocaleName` (LPWSTR up to
//!   `LOCALE_NAME_MAX_LENGTH = 85`). Version via `RtlGetVersion`
//!   (`OSVERSIONINFOEXW`), formatted like "Windows 10.0.22631".
//! - **Linux** — `LC_ALL` / `LANG` env vars for locale (caller
//!   threads the `Environ`). Version from `/etc/os-release`
//!   parsed for `PRETTY_NAME` or fallback `NAME`.

const std = @import("std");
const builtin = @import("builtin");

pub const Environ = std.process.Environ;

pub const Error = error{
    Unsupported,
    OutOfMemory,
    NotFound,
};

/// IETF-style locale tag the user has configured. Owned UTF-8.
pub fn locale(allocator: std.mem.Allocator, environ: Environ) Error![]u8 {
    return switch (builtin.os.tag) {
        .macos => localeMacos(allocator),
        .windows => localeWindows(allocator),
        .linux => localeLinux(allocator, environ),
        else => error.Unsupported,
    };
}

/// Human-readable OS version. Format is per-platform — apps that
/// need a structured `major.minor.patch` should parse this string.
/// Owned UTF-8.
pub fn osVersion(allocator: std.mem.Allocator) Error![]u8 {
    return switch (builtin.os.tag) {
        .macos => osVersionMacos(allocator),
        .windows => osVersionWindows(allocator),
        .linux => osVersionLinux(allocator),
        else => error.Unsupported,
    };
}

/// Trigger the system bell / audible alert. macOS: `NSBeep()`.
/// Windows: `MessageBeep(MB_OK)`. Linux: writes BEL (0x07) to
/// stdout — every terminal-aware compositor surfaces it as the
/// system audible-alert sound. Silent if the user has disabled
/// the alert in OS settings.
pub fn beep() void {
    switch (builtin.os.tag) {
        .macos => NSBeep(),
        .windows => _ = MessageBeep(0),
        .linux => {
            const bel = "\x07";
            _ = std.posix.write(std.posix.STDOUT_FILENO, bel) catch {};
        },
        else => {},
    }
}

/// Current process ID. Useful for log correlation, IPC keying,
/// crash diagnostics.
pub fn processId() u32 {
    return switch (builtin.os.tag) {
        .windows => @intCast(GetCurrentProcessId()),
        else => @intCast(std.posix.getpid()),
    };
}

/// Logical CPU count. Includes hyperthreads. Returns 1 on
/// platforms where the stdlib query fails.
pub fn cpuCount() usize {
    return std.Thread.getCpuCount() catch 1;
}

/// Total physical RAM in bytes, or 0 if the stdlib query fails
/// (unsupported platform / sandbox blocks). Useful for log
/// diagnostics + capacity-aware caching.
pub fn totalMemory() u64 {
    return std.process.totalSystemMemory() catch 0;
}

/// Seconds since the system booted. Returns 0 if the platform
/// can't report it (sandbox blocks /proc/uptime, exotic target).
pub fn uptime() u64 {
    return switch (builtin.os.tag) {
        .macos => uptimeMacos(),
        .windows => uptimeWindows(),
        .linux => uptimeLinux(),
        else => 0,
    };
}

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

fn uptimeWindows() u64 {
    if (builtin.os.tag != .windows) return 0;
    return GetTickCount64() / 1000;
}

const Timeval = extern struct { tv_sec: c_long, tv_usec: c_long };
extern fn sysctlbyname(name: [*:0]const u8, oldp: ?*anyopaque, oldlenp: ?*usize, newp: ?*const anyopaque, newlen: usize) c_int;

extern "c" fn time(t: ?*c_long) c_long;

fn uptimeMacos() u64 {
    if (builtin.os.tag != .macos) return 0;
    var boottime: Timeval = .{ .tv_sec = 0, .tv_usec = 0 };
    var size: usize = @sizeOf(Timeval);
    if (sysctlbyname("kern.boottime", &boottime, &size, null, 0) != 0) return 0;
    // POSIX `time(NULL)` returns seconds since epoch. std.time has no
    // timestamp() in Zig 0.16 and std.posix.clock_gettime isn't
    // surfaced either, so go through libc directly.
    const now: i64 = @intCast(time(null));
    if (now <= boottime.tv_sec) return 0;
    return @intCast(now - @as(i64, boottime.tv_sec));
}

fn uptimeLinux() u64 {
    if (builtin.os.tag != .linux) return 0;
    // /proc/uptime contains "<uptime_seconds> <idle_seconds>\n".
    // We only want the first float, truncated to seconds.
    const fd = std.posix.openat(std.posix.AT.FDCWD, "/proc/uptime", .{ .ACCMODE = .RDONLY }, 0) catch return 0;
    defer std.posix.close(fd);
    var buf: [64]u8 = undefined;
    const n = std.posix.read(fd, &buf) catch return 0;
    if (n == 0) return 0;
    const space = std.mem.indexOfScalar(u8, buf[0..n], ' ') orelse return 0;
    const seconds_str = buf[0..space];
    const dot = std.mem.indexOfScalar(u8, seconds_str, '.') orelse seconds_str.len;
    return std.fmt.parseInt(u64, seconds_str[0..dot], 10) catch 0;
}

extern "AppKit" fn NSBeep() void;
extern "user32" fn MessageBeep(ty: c_uint) callconv(.winapi) c_int;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) c_ulong;

// ---- macOS — NSLocale + NSProcessInfo --------------------------------------

fn localeMacos(allocator: std.mem.Allocator) Error![]u8 {
    if (builtin.os.tag != .macos) return error.Unsupported;
    const m = @import("msg.zig");
    const id = ?*anyopaque;
    const SEL = ?*anyopaque;

    const NSLocale = m.getClass("NSLocale");
    const currentLocale = m.cast(*const fn (id, SEL) callconv(.c) id);
    const loc = currentLocale(@as(id, @ptrCast(NSLocale)), m.sel("currentLocale"));
    if (@intFromPtr(loc) == 0) return error.Unsupported;
    const identifier = m.cast(*const fn (id, SEL) callconv(.c) id);
    const ident = identifier(loc, m.sel("localeIdentifier"));
    return nsStringDupe(allocator, ident);
}

fn osVersionMacos(allocator: std.mem.Allocator) Error![]u8 {
    if (builtin.os.tag != .macos) return error.Unsupported;
    const m = @import("msg.zig");
    const id = ?*anyopaque;
    const SEL = ?*anyopaque;

    const NSProcessInfo = m.getClass("NSProcessInfo");
    const sharedSel = m.cast(*const fn (id, SEL) callconv(.c) id);
    const pi = sharedSel(@as(id, @ptrCast(NSProcessInfo)), m.sel("processInfo"));
    if (@intFromPtr(pi) == 0) return error.Unsupported;
    const verSel = m.cast(*const fn (id, SEL) callconv(.c) id);
    const ver = verSel(pi, m.sel("operatingSystemVersionString"));
    return nsStringDupe(allocator, ver);
}

fn nsStringDupe(allocator: std.mem.Allocator, ns_str: ?*anyopaque) Error![]u8 {
    if (builtin.os.tag != .macos) return error.Unsupported;
    const m = @import("msg.zig");
    const id = ?*anyopaque;
    const SEL = ?*anyopaque;
    if (@intFromPtr(ns_str) == 0) return allocator.dupe(u8, "") catch error.OutOfMemory;
    const utf8 = m.cast(*const fn (id, SEL) callconv(.c) ?[*:0]const u8);
    const cstr = utf8(ns_str, m.sel("UTF8String")) orelse return allocator.dupe(u8, "") catch error.OutOfMemory;
    const slice = std.mem.span(cstr);
    return allocator.dupe(u8, slice) catch error.OutOfMemory;
}

// ---- Windows — GetUserDefaultLocaleName + RtlGetVersion --------------------

const LOCALE_NAME_MAX_LENGTH: c_int = 85;
extern "kernel32" fn GetUserDefaultLocaleName(buf: [*]u16, size: c_int) callconv(.winapi) c_int;

const OSVERSIONINFOEXW = extern struct {
    dwOSVersionInfoSize: u32 = 0,
    dwMajorVersion: u32 = 0,
    dwMinorVersion: u32 = 0,
    dwBuildNumber: u32 = 0,
    dwPlatformId: u32 = 0,
    szCSDVersion: [128]u16 = std.mem.zeroes([128]u16),
    wServicePackMajor: u16 = 0,
    wServicePackMinor: u16 = 0,
    wSuiteMask: u16 = 0,
    wProductType: u8 = 0,
    wReserved: u8 = 0,
};
extern "ntdll" fn RtlGetVersion(info: *OSVERSIONINFOEXW) callconv(.winapi) c_long;

fn localeWindows(allocator: std.mem.Allocator) Error![]u8 {
    if (builtin.os.tag != .windows) return error.Unsupported;
    var wbuf: [LOCALE_NAME_MAX_LENGTH]u16 = undefined;
    const n = GetUserDefaultLocaleName(&wbuf, LOCALE_NAME_MAX_LENGTH);
    if (n <= 0) return error.NotFound;
    // `n` includes the trailing NUL; strip before UTF-8 conversion.
    const len: usize = @intCast(n - 1);
    var out = allocator.alloc(u8, len * 3 + 1) catch return error.OutOfMemory;
    const written = std.unicode.utf16LeToUtf8(out, wbuf[0..len]) catch {
        allocator.free(out);
        return error.NotFound;
    };
    return allocator.realloc(out, written) catch out[0..written];
}

fn osVersionWindows(allocator: std.mem.Allocator) Error![]u8 {
    if (builtin.os.tag != .windows) return error.Unsupported;
    var info: OSVERSIONINFOEXW = .{};
    info.dwOSVersionInfoSize = @sizeOf(OSVERSIONINFOEXW);
    if (RtlGetVersion(&info) < 0) return error.NotFound;
    return std.fmt.allocPrint(allocator, "Windows {d}.{d}.{d}", .{
        info.dwMajorVersion,
        info.dwMinorVersion,
        info.dwBuildNumber,
    }) catch error.OutOfMemory;
}

// ---- Linux — LC_ALL / LANG + /etc/os-release --------------------------------

fn localeLinux(allocator: std.mem.Allocator, environ: Environ) Error![]u8 {
    if (builtin.os.tag != .linux) return error.Unsupported;
    // Prefer LC_ALL (full override) then LANG.
    if (environ.getAlloc(allocator, "LC_ALL") catch null) |v| {
        return stripCodeset(allocator, v);
    }
    if (environ.getAlloc(allocator, "LANG") catch null) |v| {
        return stripCodeset(allocator, v);
    }
    return error.NotFound;
}

/// `LC_ALL` / `LANG` values are like `en_US.UTF-8` — split on the
/// codeset dot and return the locale portion. Drops the trailing
/// modifier (`@euro`) too. Frees the input on success since the
/// returned slice is freshly allocated.
fn stripCodeset(allocator: std.mem.Allocator, raw: []u8) Error![]u8 {
    defer allocator.free(raw);
    var end = raw.len;
    if (std.mem.indexOfScalar(u8, raw, '.')) |dot| end = dot;
    if (std.mem.indexOfScalar(u8, raw[0..end], '@')) |at| end = at;
    return allocator.dupe(u8, raw[0..end]) catch error.OutOfMemory;
}

fn osVersionLinux(allocator: std.mem.Allocator) Error![]u8 {
    if (builtin.os.tag != .linux) return error.Unsupported;
    // `/etc/os-release` is the freedesktop standard; every modern
    // distro ships it. We parse manually (no shell, no `source`)
    // and look for `PRETTY_NAME=...` first, fall back to `NAME=...`.
    const file = std.fs.cwd().openFile("/etc/os-release", .{}) catch {
        return allocator.dupe(u8, "Linux") catch error.OutOfMemory;
    };
    defer file.close();

    var buf: [4096]u8 = undefined;
    const n = file.readAll(&buf) catch {
        return allocator.dupe(u8, "Linux") catch error.OutOfMemory;
    };
    const body = buf[0..n];

    if (extractOsReleaseValue(body, "PRETTY_NAME")) |v| {
        return allocator.dupe(u8, v) catch error.OutOfMemory;
    }
    if (extractOsReleaseValue(body, "NAME")) |v| {
        return allocator.dupe(u8, v) catch error.OutOfMemory;
    }
    return allocator.dupe(u8, "Linux") catch error.OutOfMemory;
}

/// Find `<key>=...` in `body`, strip surrounding quotes from the
/// value. Returns a slice into `body` — caller dupes if it needs
/// to outlive the buffer.
fn extractOsReleaseValue(body: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeScalar(u8, body, '\n');
    while (it.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const name = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.mem.eql(u8, name, key)) continue;
        var val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
            val = val[1 .. val.len - 1];
        }
        return val;
    }
    return null;
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "extractOsReleaseValue parses PRETTY_NAME with quotes" {
    const body =
        \\NAME="Ubuntu"
        \\VERSION="22.04 LTS"
        \\PRETTY_NAME="Ubuntu 22.04.3 LTS"
        \\
    ;
    const got = extractOsReleaseValue(body, "PRETTY_NAME") orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("Ubuntu 22.04.3 LTS", got);
}

test "extractOsReleaseValue tolerates unquoted values" {
    const body = "NAME=Arch\nID=arch\n";
    const got = extractOsReleaseValue(body, "NAME") orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("Arch", got);
}

test "stripCodeset drops .UTF-8 and @modifier" {
    const a = try testing.allocator.dupe(u8, "en_US.UTF-8");
    const got_a = try stripCodeset(testing.allocator, a);
    defer testing.allocator.free(got_a);
    try testing.expectEqualStrings("en_US", got_a);

    const b = try testing.allocator.dupe(u8, "de_DE@euro");
    const got_b = try stripCodeset(testing.allocator, b);
    defer testing.allocator.free(got_b);
    try testing.expectEqualStrings("de_DE", got_b);
}
