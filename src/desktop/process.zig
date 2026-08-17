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
    /// The child wrote more than `output_limit_bytes` to stdout or stderr.
    /// Distinct from `SpawnFailed` on purpose: the process started and ran
    /// fine, so collapsing this into a spawn failure sends a reader to check
    /// PATH and permissions for what is actually a size problem.
    OutputTooLarge,
    /// Process spawned but exited with a non-zero status. `Result.code`
    /// carries the exit code; callers that don't care about non-zero
    /// can swallow this with `catch`.
    NonZeroExit,
};

/// Per-stream output cap. Long enough for command output, short enough that
/// a runaway child can't OOM the parent.
pub const output_limit_bytes = 1024 * 1024;

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

/// Map a `std.process.run` failure onto this module's `Error`.
///
/// Split out from `runCapture` so the mapping is unit-testable without
/// spawning a child that emits a megabyte — that would need a shell, and this
/// module builds on Windows too.
fn mapRunError(err: anyerror) Error {
    return switch (err) {
        // std/process.zig:523 — either stream passed its limit.
        error.StreamTooLong => Error.OutputTooLarge,
        error.OutOfMemory => Error.OutOfMemory,
        else => Error.SpawnFailed,
    };
}

/// Run `argv` to completion, capturing stdout + stderr. Inherits the
/// parent's environment.
///
/// Bounded output: each stream is capped at `output_limit_bytes`. Exceeding
/// it is an **error** (`Error.OutputTooLarge`), not a truncation — the caller
/// gets no partial output, because a JSON payload cut in half is worse than
/// no payload at all.
pub fn runCapture(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
) Error!Result {
    // Note: this was previously written against an older `std.process.Child`
    // shape (`Child.run(.{ .allocator, .io, .argv, .max_output_bytes })`,
    // `Term.Exited`) that no longer exists in this toolchain — dead code
    // (nothing called `runCapture` or `spawnDetached` from a test, so the
    // mismatch never got type-checked) until `ai_cli.zig` became the first
    // real caller. Current API: a free `std.process.run(gpa, io, options)`
    // returning `RunResult{ term: Child.Term, stdout, stderr }`, with
    // `Child.Term` tags lowercase (`.exited`, not `.Exited`).
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = std.Io.Limit.limited(output_limit_bytes),
        .stderr_limit = std.Io.Limit.limited(output_limit_bytes),
    }) catch |err| return mapRunError(err);
    return .{
        .code = switch (result.term) {
            .exited => |c| c,
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
    // `allocator` is unused by the current `std.process.spawn` (it takes no
    // allocator at all) — kept as a parameter for API stability; see the
    // note in `runCapture` about this file predating that API.
    _ = allocator;
    _ = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SpawnFailed;
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

test "runCapture: oversized output is OutputTooLarge, not SpawnFailed" {
    // `std.process.run` returns `error.StreamTooLong` when either stream
    // passes its limit (std/process.zig:523). Reporting that as SpawnFailed
    // sends a reader to check PATH and permissions for a process that
    // spawned and ran perfectly well — the output was simply too big.
    //
    // Tested through the mapping function rather than by spawning a child
    // that emits a megabyte: that would need a shell, and this module builds
    // on Windows too.
    try testing.expectEqual(Error.OutputTooLarge, mapRunError(error.StreamTooLong));
}

test "runCapture: allocation failure stays OutOfMemory" {
    try testing.expectEqual(Error.OutOfMemory, mapRunError(error.OutOfMemory));
}

test "runCapture: a genuine spawn failure is still SpawnFailed" {
    try testing.expectEqual(Error.SpawnFailed, mapRunError(error.FileNotFound));
    try testing.expectEqual(Error.SpawnFailed, mapRunError(error.AccessDenied));
}
