//! Spawn child processes with desktop-friendly defaults.
//!
//! Thin wrapper over `std.process.Child` for the two common cases:
//! - `runCapture` — block until exit, return stdout + stderr + exit
//!   code. For short utility commands (probe `defaults read`, run a
//!   converter, query `pmset -g batt`).
//! - `spawnDetached` — fire-and-forget. Spawns, doesn't wait, returns.
//!   Useful for launching helper apps the parent doesn't observe.
//!
//! Cross-platform via Zig stdlib — no per-OS branches. Surfaced under
//! `desktop.process` so apps that use the rest of the desktop module
//! aren't forced to import `std.process` separately.

const std = @import("std");

pub const Error = error{
    OutOfMemory,
    SpawnFailed,
    /// Process spawned but exited with a non-zero status. `Result.code`
    /// carries the exit code; callers that don't care about non-zero
    /// can swallow this with `catch`.
    NonZeroExit,
};

pub const Result = struct {
    code: u8,
    stdout: []u8,
    stderr: []u8,
    /// True when the child exited 0. Mirrors `code == 0` for ergonomics.
    pub fn ok(self: Result) bool {
        return self.code == 0;
    }
    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Run `argv` to completion, capturing stdout + stderr. Inherits the
/// parent's environment. Bounded output: each stream caps at
/// `max_output_bytes` (default 1 MiB) before being truncated — long
/// enough for command output, short enough that a hung child doesn't
/// OOM the parent.
pub fn runCapture(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
) Error!Result {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .io = io,
        .argv = argv,
        .max_output_bytes = 1024 * 1024,
    }) catch return error.SpawnFailed;
    return .{
        .code = switch (result.term) {
            .Exited => |c| c,
            else => 1,
        },
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

/// Spawn `argv` and return immediately without waiting. The child runs
/// in the background; the parent does NOT collect its exit status, so
/// the child becomes an orphan on parent exit (or gets reaped by init
/// on POSIX, by Windows on Win32). Pipes are inherited from the parent
/// — pass `stdin_behavior = .Ignore` etc. via a future option pack if
/// you want isolation.
pub fn spawnDetached(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
) Error!void {
    var child = std.process.Child.init(argv, allocator);
    child.io = io;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return error.SpawnFailed;
    // Intentionally drop the handle. POSIX would prefer a double-fork
    // for true daemonization; the stdlib doesn't expose that surface
    // yet, so v1 ships the simpler path.
}

const testing = std.testing;

test "Result.ok mirrors code" {
    var r1: Result = .{ .code = 0, .stdout = &.{}, .stderr = &.{} };
    var r2: Result = .{ .code = 1, .stdout = &.{}, .stderr = &.{} };
    try testing.expect(r1.ok());
    try testing.expect(!r2.ok());
}

test "Error set stable" {
    const e: Error = error.SpawnFailed;
    try testing.expect(e == error.SpawnFailed);
    try testing.expect(@as(Error, error.NonZeroExit) == error.NonZeroExit);
}
