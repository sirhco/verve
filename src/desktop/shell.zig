//! Hooks into the host OS shell — for opening URLs / files in
//! their default apps without the embedded WebView navigating.
//!
//! Cross-platform `openUrl(allocator, url)` ships first. `url` can
//! be:
//!  - `http://` / `https://` — opens in the system default browser.
//!  - `file://` — opens the file in the default app for its MIME.
//!  - `mailto:`, `tel:`, `verve://` (etc.) — handed off to whatever
//!    app the OS registered for the scheme.
//!
//! Per-platform strategy:
//!
//! - **macOS** — `[NSWorkspace.sharedWorkspace openURL:]` with an
//!   `NSURL` built from the input string.
//! - **Windows** — `ShellExecuteW(NULL, "open", url, NULL, NULL,
//!   SW_SHOWNORMAL)`. Same call handles HTTP URLs and local file
//!   paths.
//! - **Linux** — spawn `xdg-open <url>` via `posix.fork` +
//!   `execvp`. `xdg-open` is part of `xdg-utils`, present by
//!   default on every freedesktop install. Failure to spawn is
//!   surfaced as `error.Backend`.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    Unsupported,
    OutOfMemory,
    Backend,
};

/// Hand `url` to the OS shell. Returns immediately — the browser /
/// default app launches asynchronously. Errors only on the launch
/// itself (invalid URL on macOS, ShellExecute failure on Win, fork
/// failure on Linux); any subsequent app crash is not reported.
pub fn openUrl(allocator: std.mem.Allocator, url: []const u8) Error!void {
    return switch (builtin.os.tag) {
        .macos => openUrlMacos(url),
        .windows => openUrlWindows(allocator, url),
        .linux => openUrlLinux(allocator, url),
        else => error.Unsupported,
    };
}

// ---- macOS — NSWorkspace ----------------------------------------------------

fn openUrlMacos(url: []const u8) Error!void {
    if (builtin.os.tag != .macos) return error.Unsupported;
    const m = @import("msg.zig");
    const id = ?*anyopaque;
    const SEL = ?*anyopaque;

    const NSString = m.getClass("NSString");
    const stringWithUTF8 = m.cast(*const fn (id, SEL, [*]const u8) callconv(.c) id);
    var buf: [4096]u8 = undefined;
    if (url.len >= buf.len) return error.OutOfMemory;
    @memcpy(buf[0..url.len], url);
    buf[url.len] = 0;
    const ns_str = stringWithUTF8(@as(id, @ptrCast(NSString)), m.sel("stringWithUTF8String:"), &buf);

    const NSURL = m.getClass("NSURL");
    const urlWithString = m.cast(*const fn (id, SEL, id) callconv(.c) id);
    const ns_url = urlWithString(@as(id, @ptrCast(NSURL)), m.sel("URLWithString:"), ns_str);
    if (@intFromPtr(ns_url) == 0) return error.Backend;

    const NSWorkspace = m.getClass("NSWorkspace");
    const sharedSel = m.cast(*const fn (id, SEL) callconv(.c) id);
    const ws = sharedSel(@as(id, @ptrCast(NSWorkspace)), m.sel("sharedWorkspace"));
    const openUrlSel = m.cast(*const fn (id, SEL, id) callconv(.c) bool);
    if (!openUrlSel(ws, m.sel("openURL:"), ns_url)) return error.Backend;
}

// ---- Windows — ShellExecuteW ------------------------------------------------

extern "shell32" fn ShellExecuteW(
    hwnd: ?*anyopaque,
    op: ?[*:0]const u16,
    file: ?[*:0]const u16,
    params: ?[*:0]const u16,
    dir: ?[*:0]const u16,
    show: c_int,
) callconv(.winapi) ?*anyopaque;

fn openUrlWindows(allocator: std.mem.Allocator, url: []const u8) Error!void {
    if (builtin.os.tag != .windows) return error.Unsupported;
    const SW_SHOWNORMAL: c_int = 1;
    const w_url = std.unicode.utf8ToUtf16LeAllocZ(allocator, url) catch return error.OutOfMemory;
    defer allocator.free(w_url);
    const verb = std.unicode.utf8ToUtf16LeStringLiteral("open");
    // ShellExecuteW returns an HINSTANCE; values > 32 = success per
    // MSDN. The "instance" return is opaque, so cast to uintptr for
    // the threshold check.
    const rc = ShellExecuteW(null, verb, w_url.ptr, null, null, SW_SHOWNORMAL);
    if (@intFromPtr(rc) <= 32) return error.Backend;
}

// ---- Linux — xdg-open via fork + execvp -------------------------------------

extern fn fork() c_int;
extern fn execvp(file: [*:0]const u8, argv: [*]const ?[*:0]const u8) c_int;
extern fn _exit(status: c_int) noreturn;

fn openUrlLinux(allocator: std.mem.Allocator, url: []const u8) Error!void {
    if (builtin.os.tag != .linux) return error.Unsupported;

    const url_z = allocator.dupeZ(u8, url) catch return error.OutOfMemory;
    defer allocator.free(url_z);

    const pid = fork();
    if (pid < 0) return error.Backend;
    if (pid == 0) {
        // Child process. `xdg-open` lives on $PATH on every
        // freedesktop install. The argv array is null-terminated.
        const argv = [_]?[*:0]const u8{ "xdg-open", url_z.ptr, null };
        _ = execvp("xdg-open", &argv);
        // execvp only returns on failure — exit with a non-zero
        // status so the parent can tell if anything weird happens
        // (we don't wait though, so this is mostly cosmetic).
        _exit(127);
    }
    // Parent returns immediately; we don't waitpid because xdg-open
    // forks the actual browser and returns quickly. Wait would block
    // on long-running child processes.
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "openUrl rejects empty allocator wrap" {
    // No-op smoke test — `openUrl` performs side effects, so we
    // don't actually invoke it in unit tests. This compile-only
    // assertion checks the function exists with the documented
    // signature.
    const T = @TypeOf(openUrl);
    try testing.expect(T == fn (std.mem.Allocator, []const u8) Error!void);
}
