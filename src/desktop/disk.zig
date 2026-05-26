//! Filesystem-level disk space query.
//!
//! `spaceAt(path)` returns the total / available / free byte
//! counts of the filesystem mount that owns `path`. Useful for
//! capacity dashboards, pre-flight checks before large writes,
//! showing "X GB left" in download UIs.
//!
//! Per-platform strategy:
//!
//! - **POSIX (macOS + Linux)** — `statvfs(path)`. `f_blocks * f_frsize`
//!   for total; `f_bavail * f_frsize` for available (after reserved
//!   blocks); `f_bfree * f_frsize` for the raw free count (root can
//!   use the reserved portion).
//! - **Windows** — `GetDiskFreeSpaceExW`. Returns three
//!   ULARGE_INTEGER values directly: free-for-caller / total /
//!   free-on-volume. We map them to available / total / free.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    Unsupported,
    OutOfMemory,
    Backend,
};

pub const Space = struct {
    /// Total capacity of the filesystem in bytes.
    total: u64,
    /// Bytes a regular user can write. Excludes the reserved
    /// portion that's only available to the root user on POSIX.
    available: u64,
    /// Raw unused bytes including reserved portion.
    free: u64,
};

pub fn spaceAt(allocator: std.mem.Allocator, path: []const u8) Error!Space {
    return switch (builtin.os.tag) {
        .macos, .linux => spaceAtPosix(allocator, path),
        .windows => spaceAtWindows(allocator, path),
        else => error.Unsupported,
    };
}

// ---- POSIX — statvfs --------------------------------------------------------

// macOS `fsblkcnt_t` / `fsfilcnt_t` are `unsigned int` (32-bit);
// Linux's are `unsigned long` (64-bit on LP64). Sharing one extern
// struct across both backends mis-aligns every field after f_frsize
// on macOS — reading f_blocks as c_ulong picks up the high half of
// the next field, producing huge garbage values that overflow when
// multiplied by f_frsize. Split per platform.
const fsblkcnt_t = if (builtin.os.tag == .macos) c_uint else c_ulong;
const fsfilcnt_t = fsblkcnt_t;

const StatvfsPosix = extern struct {
    f_bsize: c_ulong = 0,
    f_frsize: c_ulong = 0,
    f_blocks: fsblkcnt_t = 0,
    f_bfree: fsblkcnt_t = 0,
    f_bavail: fsblkcnt_t = 0,
    f_files: fsfilcnt_t = 0,
    f_ffree: fsfilcnt_t = 0,
    f_favail: fsfilcnt_t = 0,
    f_fsid: c_ulong = 0,
    f_flag: c_ulong = 0,
    f_namemax: c_ulong = 0,
    // Linux pads; macOS doesn't. We never read past namemax so
    // the trailing fields aren't relevant for our purposes.
    _pad: [64]u8 = std.mem.zeroes([64]u8),
};

extern fn statvfs(path: [*:0]const u8, buf: *StatvfsPosix) c_int;

fn spaceAtPosix(allocator: std.mem.Allocator, path: []const u8) Error!Space {
    const z = allocator.dupeZ(u8, path) catch return error.OutOfMemory;
    defer allocator.free(z);
    var st: StatvfsPosix = .{};
    if (statvfs(z.ptr, &st) != 0) return error.Backend;
    const block: u64 = @intCast(st.f_frsize);
    return .{
        .total = @as(u64, @intCast(st.f_blocks)) * block,
        .available = @as(u64, @intCast(st.f_bavail)) * block,
        .free = @as(u64, @intCast(st.f_bfree)) * block,
    };
}

// ---- Windows — GetDiskFreeSpaceExW -----------------------------------------

extern "kernel32" fn GetDiskFreeSpaceExW(
    path: ?[*:0]const u16,
    free_for_caller: *u64,
    total: *u64,
    total_free: *u64,
) callconv(.winapi) c_int;

fn spaceAtWindows(allocator: std.mem.Allocator, path: []const u8) Error!Space {
    if (builtin.os.tag != .windows) return error.Unsupported;
    const w_path = std.unicode.utf8ToUtf16LeAllocZ(allocator, path) catch return error.OutOfMemory;
    defer allocator.free(w_path);

    var available: u64 = 0;
    var total: u64 = 0;
    var free: u64 = 0;
    if (GetDiskFreeSpaceExW(w_path.ptr, &available, &total, &free) == 0) {
        return error.Backend;
    }
    return .{ .total = total, .available = available, .free = free };
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "Space struct shape stable" {
    const s: Space = .{ .total = 1_000_000_000, .available = 500_000_000, .free = 600_000_000 };
    try testing.expectEqual(@as(u64, 1_000_000_000), s.total);
    try testing.expect(s.available <= s.free);
}
