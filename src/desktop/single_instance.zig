//! Single-instance enforcement for desktop apps.
//!
//! Most desktop apps want at most one running copy per user, so a
//! double-click on the dock icon or a second `open -a` from the
//! terminal doesn't spawn a parallel window. This module exposes a
//! cross-platform `acquire(name)` that returns an opaque `Lock`
//! held for the process lifetime — drop it (or just exit) to release.
//!
//! Strategy per OS:
//! - **macOS + Linux** — open a lock file at
//!   `<TMPDIR or /tmp>/verve.<name>.lock` and `flock(LOCK_EX | LOCK_NB)`.
//!   The kernel reclaims advisory locks on process exit so a crash
//!   doesn't leave a stale lock. EWOULDBLOCK means another live
//!   process holds it → `error.AlreadyRunning`.
//! - **Windows** — `CreateMutexW(NULL, FALSE, "Local\\Verve.<name>")`
//!   under the per-session `Local\` namespace. `ERROR_ALREADY_EXISTS`
//!   from `GetLastError` after the call indicates a prior holder →
//!   `error.AlreadyRunning`. The kernel releases the named mutex on
//!   handle close / process exit.
//!
//! Activation of the existing instance (raise its window, forward
//! arguments) is intentionally out of scope for this pass; the
//! lock-only path is the smallest correct primitive and apps that
//! want activation semantics can build them on top.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    AlreadyRunning,
    /// Lock-file directory unavailable or unwritable. Typically a
    /// readonly tmp mount in a sandbox; nothing the framework can do.
    AcquireFailed,
    OutOfMemory,
};

/// Opaque per-OS lock. Hold this for the lifetime you want the
/// single-instance guarantee to apply — usually until process exit.
/// `release` is wired to platform-native cleanup; the kernel also
/// reclaims the lock automatically when the process dies.
pub const Lock = struct {
    impl: switch (builtin.target.os.tag) {
        .windows => WindowsImpl,
        else => PosixImpl,
    },

    pub fn release(self: *Lock) void {
        self.impl.release();
    }
};

pub fn acquire(allocator: std.mem.Allocator, name: []const u8) Error!Lock {
    if (!isValidName(name)) return error.AcquireFailed;
    switch (builtin.target.os.tag) {
        .windows => return .{ .impl = try WindowsImpl.acquire(allocator, name) },
        else => return .{ .impl = try PosixImpl.acquire(allocator, name) },
    }
}

/// Restrict the slug to a small alphabet so the resulting path /
/// kernel-object name is always safe: ASCII letters, digits, `-`,
/// `_`, `.`. No traversal, no shell metachars, no Windows reserved
/// punctuation (`\`, `/`, `:`). Pure-`.` and leading-`.` slugs are
/// rejected so `.` / `..` can't appear as the entire name.
fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (name[0] == '.') return false;
    var has_alnum = false;
    for (name) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.';
        if (!ok) return false;
        if (std.ascii.isAlphanumeric(c)) has_alnum = true;
    }
    return has_alnum;
}

// ---- POSIX (macOS + Linux) --------------------------------------------------

const PosixImpl = struct {
    fd: c_int,

    // `std.c.open` is variadic (`fn(path, O, ...) c_int`) — the mode
    // argument has to ride the C varargs slot or the kernel reads
    // garbage from the third register on darwin arm64 and creates the
    // file with mode 0o000, which then makes every subsequent open()
    // fail with EACCES even from the same uid. Use the std.c wrapper
    // so the ABI is correct.
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn flock(fd: c_int, op: c_int) c_int;
    extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
    // errno isn't read here: flock with LOCK_NB returns -1 on any
    // failure and "another process holds it" is the only outcome we
    // care about — every other -1 condition (EBADF, ENOLCK) is also
    // a hard fail. Stale lock files left by crashes are harmless: the
    // advisory lock is released by the kernel when the holding fd is
    // closed at process death.

    const LOCK_EX: c_int = 2;
    const LOCK_NB: c_int = 4;
    const LOCK_UN: c_int = 8;

    fn acquire(allocator: std.mem.Allocator, name: []const u8) Error!PosixImpl {
        const tmp = getenv("TMPDIR") orelse "/tmp";
        const tmp_slice = std.mem.span(tmp);
        // Strip a trailing slash so the join is deterministic.
        const tmp_clean = if (tmp_slice.len > 0 and tmp_slice[tmp_slice.len - 1] == '/')
            tmp_slice[0 .. tmp_slice.len - 1]
        else
            tmp_slice;

        // allocPrint + explicit NUL terminator. `allocPrintZ` is gone
        // in 0.16; this is the standard replacement idiom.
        const path = std.fmt.allocPrint(allocator, "{s}/verve.{s}.lock\x00", .{ tmp_clean, name }) catch return error.OutOfMemory;
        defer allocator.free(path);
        const path_z: [*:0]const u8 = @ptrCast(path.ptr);

        // `std.c.open` is variadic; the host libc reads the mode from
        // the variadic slot. Pass it as a Zig integer that promotes to
        // c_int through the .c call convention.
        const flags: std.c.O = .{ .ACCMODE = .RDWR, .CREAT = true };
        const fd = std.c.open(path_z, flags, @as(c_int, 0o600));
        if (fd < 0) return error.AcquireFailed;
        errdefer _ = close(fd);

        if (flock(fd, LOCK_EX | LOCK_NB) != 0) return error.AlreadyRunning;
        return .{ .fd = fd };
    }

    fn release(self: *PosixImpl) void {
        // flock LOCK_UN explicitly so any caller polling the lock
        // file before the kernel teardown sees it free immediately.
        _ = flock(self.fd, LOCK_UN);
        _ = close(self.fd);
        self.fd = -1;
    }
};

// ---- Windows ----------------------------------------------------------------

const WindowsImpl = struct {
    handle: ?*anyopaque,

    const HANDLE = ?*anyopaque;
    const DWORD = c_ulong;
    const BOOL = c_int;
    const LPCWSTR = ?[*:0]const u16;

    const ERROR_ALREADY_EXISTS: DWORD = 183;

    extern "kernel32" fn CreateMutexW(sec: ?*anyopaque, owned: BOOL, name: LPCWSTR) callconv(.winapi) HANDLE;
    extern "kernel32" fn ReleaseMutex(handle: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

    fn acquire(allocator: std.mem.Allocator, name: []const u8) Error!WindowsImpl {
        // Build the full name with the `Local\` session prefix so the
        // mutex doesn't leak across user sessions on the same machine.
        // UTF-8 → UTF-16, NUL-terminated.
        var name_buf: [256]u16 = undefined;
        var idx: usize = 0;
        // "Local\\Verve." prefix
        const prefix = "Local\\Verve.";
        for (prefix) |c| {
            if (idx >= name_buf.len - 1) return error.AcquireFailed;
            name_buf[idx] = c;
            idx += 1;
        }
        const w = std.unicode.utf8ToUtf16Le(name_buf[idx..], name) catch return error.AcquireFailed;
        idx += w;
        if (idx >= name_buf.len) return error.AcquireFailed;
        name_buf[idx] = 0;

        _ = allocator; // Windows path doesn't allocate

        const handle = CreateMutexW(null, 0, @ptrCast(&name_buf));
        if (handle == null) return error.AcquireFailed;
        if (GetLastError() == ERROR_ALREADY_EXISTS) {
            _ = CloseHandle(handle);
            return error.AlreadyRunning;
        }
        return .{ .handle = handle };
    }

    fn release(self: *WindowsImpl) void {
        if (self.handle) |h| {
            _ = CloseHandle(h);
            self.handle = null;
        }
    }
};

// ---- Tests ------------------------------------------------------------------

test "isValidName accepts safe slugs" {
    try std.testing.expect(isValidName("my-app"));
    try std.testing.expect(isValidName("my_app"));
    try std.testing.expect(isValidName("my.app.v2"));
    try std.testing.expect(isValidName("a"));
}

test "isValidName rejects path-traversal and metachars" {
    try std.testing.expect(!isValidName(""));
    try std.testing.expect(!isValidName("a/b"));
    try std.testing.expect(!isValidName("a\\b"));
    try std.testing.expect(!isValidName(".."));
    try std.testing.expect(!isValidName("a b"));
    try std.testing.expect(!isValidName("a:b"));
    // 65-char string exceeds the length cap.
    try std.testing.expect(!isValidName("a" ** 65));
}

test "acquire + release round-trips on host OS" {
    // Use the buffer address as a per-run unique id so concurrent test
    // runs don't collide on the lock file. ASLR makes this differ
    // every process invocation.
    var buf: [64]u8 = undefined;
    const r: u32 = @truncate(@intFromPtr(&buf));
    const slug = std.fmt.bufPrint(&buf, "test-{x}", .{r}) catch return error.SkipZigTest;

    var lock = try acquire(std.testing.allocator, slug);
    defer lock.release();

    // Second acquire of the SAME slug should fail with AlreadyRunning.
    try std.testing.expectError(error.AlreadyRunning, acquire(std.testing.allocator, slug));
}
