//! Auto-updater (pure stdlib, no native APIs).
//!
//! Two phases:
//!
//! 1. **Check** — `checkForUpdate(allocator, feed_url, current_version)`
//!    fetches a JSON feed, compares versions, returns `?UpdateInfo`
//!    (null when up to date). Cross-platform, works everywhere
//!    `std.http.Client` does.
//!
//! 2. **Apply** — `applyUpdate(allocator, io, info)` downloads the
//!    artifact at `info.download_url`, verifies it against
//!    `info.sha256`, and installs it. macOS swaps the running `.app`
//!    bundle (atomic rename) and `open -n` relaunches; Windows extracts
//!    to a temp dir and hands a detached `swap.cmd` helper the job of
//!    replacing the locked install dir + relaunching (pure-Zig
//!    side-by-side swap — no Squirrel/MSIX). Linux returns
//!    `error.Unsupported` (AppImageUpdate territory).
//!
//! Feed format (JSON):
//!
//! ```json
//! {
//!   "version": "1.2.3",
//!   "download_url": "https://example.com/myapp-1.2.3-aarch64-macos.tar.gz",
//!   "sha256": "abcdef0123...64-hex-chars",
//!   "notes": "Fixed the splat bug."
//! }
//! ```
//!
//! `version` follows the standard `<major>.<minor>.<patch>` shape
//! (extra suffixes like `-rc1` lex but only the numeric prefix is
//! compared). `notes` is optional. `sha256` is required only when
//! the caller intends to invoke `applyUpdate`; `checkForUpdate`
//! tolerates its absence (defaults to "").
//!
//! Trust model: the feed URL itself is the trust anchor. Serve it
//! over HTTPS from infrastructure you control. SHA-256 verifies the
//! download against the digest the feed advertises — it catches
//! transport corruption and a compromised CDN, but not a compromised
//! feed host. Apps that need stronger guarantees should layer code
//! signing (notarized `.app`) on top.

const std = @import("std");
const builtin = @import("builtin");
const Writer = std.Io.Writer;

/// libc on darwin. Resolves the running process's executable path
/// into `buf`. On entry `*size` is the buffer capacity; on success
/// the buffer holds a NUL-terminated path. Returns 0 on success,
/// non-zero on buffer-too-small (with `*size` updated to the
/// required capacity).
extern "c" fn _NSGetExecutablePath(buf: [*]u8, size: *u32) c_int;

/// Win32: full path of the running `.exe` into `buf` (UTF-16). Returns the
/// length, or `size` on truncation, 0 on failure.
extern "kernel32" fn GetModuleFileNameW(module: ?*anyopaque, buf: [*]u16, size: u32) callconv(.winapi) u32;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: [*]u16, size: u32) callconv(.winapi) u32;

pub const Error = error{
    Network,
    BadResponse,
    InvalidVersion,
    OutOfMemory,
    UnsupportedOnClient,
};

pub const ApplyError = error{
    /// Apply phase unsupported on this OS (Linux — AppImageUpdate
    /// territory). macOS + Windows are implemented.
    Unsupported,
    /// HTTP request failed or returned non-2xx.
    Network,
    /// Downloaded bytes failed the SHA-256 check.
    BadChecksum,
    /// Running process is not inside an `.app` bundle (bare-binary
    /// dev mode). The apply path needs a bundle to swap.
    NotBundled,
    /// Archive extraction failed (`tar` exited non-zero).
    ExtractFailed,
    /// Atomic rename of the new bundle over the old one failed,
    /// usually due to filesystem permissions or cross-volume swap.
    SwapFailed,
    /// `open -n` of the freshly-installed bundle failed.
    RelaunchFailed,
    /// `info.sha256` was empty or not 64 hex chars — caller must
    /// supply a digest before invoking apply.
    MissingChecksum,
    OutOfMemory,
};

pub const UpdateInfo = struct {
    /// Latest version reported by the feed. Owned by the caller-
    /// supplied allocator.
    version: []const u8,
    /// Direct URL to the platform-appropriate update artifact
    /// (expected `.tar.gz` containing `<name>.app/`). Owned.
    download_url: []const u8,
    /// Lowercase hex-encoded SHA-256 of the artifact. Empty when the
    /// feed omits it; `applyUpdate` returns `MissingChecksum` in
    /// that case. Owned.
    sha256: []const u8,
    /// Optional release notes string. Empty when the feed omitted
    /// the field. Owned.
    notes: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *const UpdateInfo) void {
        self.allocator.free(self.version);
        self.allocator.free(self.download_url);
        self.allocator.free(self.sha256);
        self.allocator.free(self.notes);
    }
};

/// Fetch `feed_url`, compare against `current_version`, return the
/// update record if a newer version is available. Returns null when
/// `current_version >= feed.version` per SemVer (numeric-prefix)
/// ordering. `error.Network` on connectivity failure;
/// `error.BadResponse` when the feed isn't well-formed JSON or
/// lacks the required fields; `error.InvalidVersion` when either
/// version string fails the numeric-prefix parse.
pub fn checkForUpdate(
    allocator: std.mem.Allocator,
    feed_url: []const u8,
    current_version: []const u8,
) Error!?UpdateInfo {
    if (builtin.target.cpu.arch.isWasm()) return error.UnsupportedOnClient;

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const result = client.fetch(.{
        .location = .{ .url = feed_url },
        .method = .GET,
        .response_writer = &aw.writer,
    }) catch return error.Network;

    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
        return error.Network;
    }

    return try parseUpdateFeed(allocator, aw.written(), current_version);
}

/// Lower-level entry point: parse a pre-fetched JSON body and
/// compare. Apps that want custom HTTP (proxies, signed requests,
/// caching) call this directly after their own fetch.
pub fn parseUpdateFeed(
    allocator: std.mem.Allocator,
    body: []const u8,
    current_version: []const u8,
) Error!?UpdateInfo {
    const Feed = struct {
        version: []const u8,
        download_url: []const u8,
        sha256: []const u8 = "",
        notes: []const u8 = "",
    };

    const parsed = std.json.parseFromSlice(Feed, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch return error.BadResponse;
    defer parsed.deinit();

    const cmp = compareSemver(current_version, parsed.value.version) catch return error.InvalidVersion;
    if (cmp >= 0) return null;

    return UpdateInfo{
        .version = allocator.dupe(u8, parsed.value.version) catch return error.OutOfMemory,
        .download_url = allocator.dupe(u8, parsed.value.download_url) catch return error.OutOfMemory,
        .sha256 = allocator.dupe(u8, parsed.value.sha256) catch return error.OutOfMemory,
        .notes = allocator.dupe(u8, parsed.value.notes) catch return error.OutOfMemory,
        .allocator = allocator,
    };
}

/// Download + verify + swap + relaunch. macOS and Windows; Linux returns
/// `error.Unsupported` (AppImageUpdate territory). Dispatches to the
/// platform implementation. Does not return on success (the process is
/// replaced / relaunched) — IPC handlers should reply to the caller first.
pub fn applyUpdate(
    allocator: std.mem.Allocator,
    io: std.Io,
    info: *const UpdateInfo,
) ApplyError!void {
    return switch (builtin.os.tag) {
        .macos => applyUpdateMacos(allocator, io, info),
        .windows => applyUpdateWindows(allocator, io, info),
        else => error.Unsupported,
    };
}

/// macOS apply: resolve the `.app` bundle, download + SHA-256 verify the
/// `.tar.gz`, two-step atomic rename swap, `open -n` relaunch.
///
/// Algorithm:
/// 1. Resolve the current process's `.app` bundle by walking up
///    from `selfExePath`. `error.NotBundled` if we're running as a
///    bare binary (dev mode — apps in `zig-out/bin/` won't update).
/// 2. Download `info.download_url` into memory via `std.http.Client`.
/// 3. SHA-256 over the downloaded bytes; compare to `info.sha256`.
///    Mismatch → `error.BadChecksum`.
/// 4. Stage the archive next to the current bundle (same volume so
///    the final rename is atomic) and extract via `/usr/bin/tar -xzf`.
/// 5. Two-step rename: move current bundle aside, move new bundle
///    into place. Best-effort restore on failure.
/// 6. `open -n <bundle>` to relaunch, then `std.process.exit(0)`.
fn applyUpdateMacos(
    allocator: std.mem.Allocator,
    io: std.Io,
    info: *const UpdateInfo,
) ApplyError!void {
    if (builtin.os.tag != .macos) return error.Unsupported;
    if (info.sha256.len != 64) return error.MissingChecksum;

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    var size: u32 = @intCast(exe_buf.len);
    if (_NSGetExecutablePath(&exe_buf, &size) != 0) return error.NotBundled;
    const exe_path = std.mem.sliceTo(exe_buf[0..], 0);

    const app_path = findAppBundle(allocator, exe_path) orelse return error.NotBundled;
    defer allocator.free(app_path);

    const app_basename = std.fs.path.basename(app_path);
    const parent = std.fs.path.dirname(app_path) orelse return error.SwapFailed;

    // Stage directory next to the target bundle so the final rename
    // is a same-volume operation. Hidden dot-prefix so a half-applied
    // update doesn't litter visible Finder listings.
    const staging = std.fmt.allocPrint(allocator, "{s}/.{s}.verve-update", .{ parent, app_basename }) catch return error.OutOfMemory;
    defer allocator.free(staging);

    rmTree(allocator, io, staging);
    std.Io.Dir.createDirAbsolute(io, staging, .default_dir) catch return error.SwapFailed;
    defer rmTree(allocator, io, staging);

    const archive_path = std.fmt.allocPrint(allocator, "{s}/update.tar.gz", .{staging}) catch return error.OutOfMemory;
    defer allocator.free(archive_path);

    try downloadAndVerify(allocator, io, info.download_url, info.sha256, archive_path);
    try extractTarGz(allocator, io, archive_path, staging);

    const new_app = std.fmt.allocPrint(allocator, "{s}/{s}", .{ staging, app_basename }) catch return error.OutOfMemory;
    defer allocator.free(new_app);

    // Sanity: extracted archive must contain a top-level `<name>.app/`.
    std.Io.Dir.accessAbsolute(io, new_app, .{}) catch return error.ExtractFailed;

    try swapBundle(allocator, io, app_path, new_app);
    try relaunch(allocator, io, app_path);
    // relaunch terminates the process on success; if we reach here,
    // open -n returned but exit() wasn't called — that's a bug.
    unreachable;
}

/// Windows apply: pure-Zig side-by-side swap. A running `.exe` is
/// file-locked, so we can't overwrite it in place (and Squirrel/MSIX both
/// need external tooling + code-signing infra). Instead:
///
/// 1. Resolve the running exe via `GetModuleFileNameW`; `error.NotBundled`
///    in the `\zig-out\` dev layout.
/// 2. Download + SHA-256 verify `info.download_url` (a `.zip` or `.tar.gz`)
///    into a `%TEMP%\verve-update-<pid>` staging dir.
/// 3. Extract with the bundled `tar.exe` (Win10 1803+; bsdtar autodetects
///    zip/gzip) into `staging\new`.
/// 4. Write a detached `swap.cmd` that waits for this PID to exit,
///    robocopy-/MOVEs `new` over the install dir, relaunches the exe, and
///    deletes the staging dir + itself.
/// 5. Spawn the helper via `cmd.exe /c`, then `std.process.exit(0)` so the
///    OS releases the exe lock and the helper can replace it.
///
/// This is unsigned in-place replacement, not a Squirrel delta / MSIX
/// package; apps wanting those layer them on top of `checkForUpdate`.
fn applyUpdateWindows(
    allocator: std.mem.Allocator,
    io: std.Io,
    info: *const UpdateInfo,
) ApplyError!void {
    if (builtin.os.tag != .windows) return error.Unsupported;
    if (info.sha256.len != 64) return error.MissingChecksum;

    var exe_w: [1024]u16 = undefined;
    const n = GetModuleFileNameW(null, &exe_w, exe_w.len);
    if (n == 0 or n >= exe_w.len) return error.NotBundled;
    const exe_path = std.unicode.utf16LeToUtf8Alloc(allocator, exe_w[0..n]) catch return error.OutOfMemory;
    defer allocator.free(exe_path);

    // Dev layout (`...\zig-out\bin\app.exe`) has nothing to update.
    if (std.mem.indexOf(u8, exe_path, "\\zig-out\\") != null) return error.NotBundled;

    const install_dir = std.fs.path.dirname(exe_path) orelse return error.NotBundled;

    // Read %TEMP% via Win32 directly. std.process.getEnvVarOwned was removed in
    // Zig 0.16's io-based process API; GetEnvironmentVariableW keeps this
    // Windows-only path self-contained and matches the file's Win32 idiom.
    var temp_w: [1024]u16 = undefined;
    const tn = GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("TEMP"), &temp_w, temp_w.len);
    if (tn == 0 or tn >= temp_w.len) return error.SwapFailed;
    const temp = std.unicode.utf16LeToUtf8Alloc(allocator, temp_w[0..tn]) catch return error.OutOfMemory;
    defer allocator.free(temp);
    const pid = GetCurrentProcessId();

    const staging = std.fmt.allocPrint(allocator, "{s}\\verve-update-{d}", .{ temp, pid }) catch return error.OutOfMemory;
    defer allocator.free(staging);
    const new_dir = std.fmt.allocPrint(allocator, "{s}\\new", .{staging}) catch return error.OutOfMemory;
    defer allocator.free(new_dir);
    const archive = std.fmt.allocPrint(allocator, "{s}\\update.archive", .{staging}) catch return error.OutOfMemory;
    defer allocator.free(archive);
    const script_path = std.fmt.allocPrint(allocator, "{s}\\swap.cmd", .{staging}) catch return error.OutOfMemory;
    defer allocator.free(script_path);

    // Fresh staging (tolerate a stale dir from a crashed prior run).
    std.Io.Dir.createDirAbsolute(io, staging, .default_dir) catch {};
    std.Io.Dir.createDirAbsolute(io, new_dir, .default_dir) catch {};

    try downloadAndVerify(allocator, io, info.download_url, info.sha256, archive);
    try extractArchiveWindows(allocator, io, archive, new_dir);

    // Extracted archive must contain the new exe at the same basename.
    const exe_base = std.fs.path.basename(exe_path);
    const new_exe = std.fmt.allocPrint(allocator, "{s}\\{s}", .{ new_dir, exe_base }) catch return error.OutOfMemory;
    defer allocator.free(new_exe);
    std.Io.Dir.accessAbsolute(io, new_exe, .{}) catch return error.ExtractFailed;

    const script = buildSwapScript(allocator, pid, new_dir, install_dir, exe_path, staging) catch return error.OutOfMemory;
    defer allocator.free(script);
    {
        var f = std.Io.Dir.createFileAbsolute(io, script_path, .{ .truncate = true }) catch return error.SwapFailed;
        defer f.close(io);
        var wbuf: [1024]u8 = undefined;
        var fw = f.writer(io, &wbuf);
        fw.interface.writeAll(script) catch return error.SwapFailed;
        fw.interface.flush() catch return error.SwapFailed;
    }

    // Detached helper; parent must exit so the exe unlocks.
    _ = std.process.spawn(io, .{
        .argv = &.{ "cmd.exe", "/c", script_path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.RelaunchFailed;
    std.process.exit(0);
}

/// Extract `archive_path` into `dest_dir` using the bundled `tar.exe`
/// (Windows 10 1803+); bsdtar autodetects zip and gzip, so no compression
/// flag is needed.
fn extractArchiveWindows(
    allocator: std.mem.Allocator,
    io: std.Io,
    archive_path: []const u8,
    dest_dir: []const u8,
) ApplyError!void {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "tar.exe", "-xf", archive_path, "-C", dest_dir },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return error.ExtractFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.ExtractFailed,
        else => return error.ExtractFailed,
    }
}

/// Emit the detached swap batch script. Pure string assembly (no I/O) so
/// it is unit-testable off-host. The wait loop polls `tasklist` until the
/// parent PID is gone, then robocopy-/MOVEs the new tree over the install
/// dir, relaunches, and self-deletes the staging dir + script. robocopy
/// exit codes 0–7 are success, so its errorlevel is intentionally ignored.
fn buildSwapScript(
    allocator: std.mem.Allocator,
    pid: u32,
    new_dir: []const u8,
    install_dir: []const u8,
    exe_path: []const u8,
    staging: []const u8,
) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(allocator,
        \\@echo off
        \\:wait
        \\tasklist /FI "PID eq {[pid]d}" | find "{[pid]d}" >nul && (timeout /t 1 /nobreak >nul & goto wait)
        \\robocopy "{[new]s}" "{[install]s}" /E /MOVE >nul
        \\start "" "{[exe]s}"
        \\rmdir /s /q "{[staging]s}" >nul 2>&1
        \\(goto) 2>nul & del "%~f0"
        \\
    , .{ .pid = pid, .new = new_dir, .install = install_dir, .exe = exe_path, .staging = staging });
}

/// Best-effort recursive delete. Shells out to `/bin/rm -rf` because
/// the only volume layout we run on (APFS) makes this fast enough,
/// and the call-sites tolerate failure (stale staging dir from a
/// prior run just gets overwritten on the next attempt).
fn rmTree(allocator: std.mem.Allocator, io: std.Io, path: []const u8) void {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "/bin/rm", "-rf", path },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    }) catch return;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

/// Walk parent dirs from `exe_path` until one ends in `.app`. Returns
/// a heap-allocated owned copy of the bundle path, or null when no
/// `.app` ancestor exists.
fn findAppBundle(allocator: std.mem.Allocator, exe_path: []const u8) ?[]u8 {
    var cur: []const u8 = exe_path;
    while (std.fs.path.dirname(cur)) |parent| : (cur = parent) {
        if (std.mem.endsWith(u8, parent, ".app")) {
            return allocator.dupe(u8, parent) catch null;
        }
    }
    return null;
}

fn downloadAndVerify(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    expected_sha256_hex: []const u8,
    out_path: []const u8,
) ApplyError!void {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &aw.writer,
    }) catch return error.Network;

    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
        return error.Network;
    }

    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    sha.update(aw.written());
    var digest: [32]u8 = undefined;
    sha.final(&digest);

    var hex_buf: [64]u8 = undefined;
    bytesToHexLower(&hex_buf, &digest);

    if (!std.ascii.eqlIgnoreCase(&hex_buf, expected_sha256_hex)) {
        return error.BadChecksum;
    }

    var file = std.Io.Dir.createFileAbsolute(io, out_path, .{ .truncate = true }) catch return error.SwapFailed;
    defer file.close(io);
    var w_buf: [4096]u8 = undefined;
    var fw = file.writer(io, &w_buf);
    fw.interface.writeAll(aw.written()) catch return error.SwapFailed;
    fw.interface.flush() catch return error.SwapFailed;
}

fn bytesToHexLower(out: *[64]u8, bytes: *const [32]u8) void {
    const charset = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = charset[b >> 4];
        out[i * 2 + 1] = charset[b & 0x0F];
    }
}

fn extractTarGz(
    allocator: std.mem.Allocator,
    io: std.Io,
    archive_path: []const u8,
    dest_dir: []const u8,
) ApplyError!void {
    const argv: []const []const u8 = &.{ "/usr/bin/tar", "-xzf", archive_path, "-C", dest_dir };
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return error.ExtractFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.ExtractFailed,
        else => return error.ExtractFailed,
    }
}

/// Two-step swap: rename current bundle aside, then move new into
/// place. POSIX `rename` on a directory whose destination already
/// exists as a non-empty directory returns ENOTEMPTY, so we cannot
/// just `rename(new, current)` in one shot. On failure of step 2,
/// best-effort restore the old bundle.
fn swapBundle(
    allocator: std.mem.Allocator,
    io: std.Io,
    current: []const u8,
    new: []const u8,
) ApplyError!void {
    const backup = std.fmt.allocPrint(allocator, "{s}.old", .{current}) catch return error.OutOfMemory;
    defer allocator.free(backup);

    // Stale backup from a previous failed run — discard.
    rmTree(allocator, io, backup);

    std.Io.Dir.renameAbsolute(current, backup, io) catch return error.SwapFailed;

    std.Io.Dir.renameAbsolute(new, current, io) catch {
        // Restore the original; if even that fails, the bundle is
        // in `backup` and the user can recover manually.
        std.Io.Dir.renameAbsolute(backup, current, io) catch {};
        return error.SwapFailed;
    };

    // Best-effort cleanup. The new bundle is in place either way.
    rmTree(allocator, io, backup);
}

fn relaunch(
    allocator: std.mem.Allocator,
    io: std.Io,
    app_path: []const u8,
) ApplyError!void {
    _ = allocator;
    _ = std.process.spawn(io, .{
        .argv = &.{ "/usr/bin/open", "-n", app_path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.RelaunchFailed;
    std.process.exit(0);
}

/// Compare two SemVer-shaped strings. Returns negative when `a < b`,
/// zero when equal, positive when `a > b`. Walks the leading
/// numeric components (major.minor.patch); any suffix after a `-`
/// or non-digit is ignored, so `1.2.3-rc1` and `1.2.3` compare as
/// equal — sufficient for "is there a newer release?" checks.
pub fn compareSemver(a: []const u8, b: []const u8) error{InvalidVersion}!i32 {
    var a_parts = splitNumericComponents(a);
    var b_parts = splitNumericComponents(b);
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const av = a_parts.next() catch return error.InvalidVersion;
        const bv = b_parts.next() catch return error.InvalidVersion;
        if (av < bv) return -1;
        if (av > bv) return 1;
    }
    return 0;
}

const ComponentIter = struct {
    src: []const u8,
    idx: usize,

    fn next(self: *ComponentIter) error{InvalidVersion}!u32 {
        // Skip leading dots / `v` prefix.
        while (self.idx < self.src.len and (self.src[self.idx] == '.' or self.src[self.idx] == 'v')) {
            self.idx += 1;
        }
        if (self.idx >= self.src.len) return 0;
        const start = self.idx;
        while (self.idx < self.src.len and std.ascii.isDigit(self.src[self.idx])) : (self.idx += 1) {}
        if (self.idx == start) return error.InvalidVersion;
        const slice = self.src[start..self.idx];
        // Skip non-digit, non-dot trailing chars (e.g. "-rc1") so the
        // next call's leading-dot skip lands cleanly.
        while (self.idx < self.src.len and self.src[self.idx] != '.') self.idx += 1;
        return std.fmt.parseInt(u32, slice, 10) catch error.InvalidVersion;
    }
};

fn splitNumericComponents(s: []const u8) ComponentIter {
    return .{ .src = s, .idx = 0 };
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "compareSemver: ordering" {
    try testing.expectEqual(@as(i32, -1), try compareSemver("1.2.3", "1.2.4"));
    try testing.expectEqual(@as(i32, 1), try compareSemver("1.2.4", "1.2.3"));
    try testing.expectEqual(@as(i32, 0), try compareSemver("1.2.3", "1.2.3"));
    try testing.expectEqual(@as(i32, -1), try compareSemver("1.2.3", "1.3.0"));
    try testing.expectEqual(@as(i32, -1), try compareSemver("0.9.0", "1.0.0"));
}

test "compareSemver: v-prefix and suffix tolerated" {
    try testing.expectEqual(@as(i32, 0), try compareSemver("v1.2.3", "1.2.3"));
    try testing.expectEqual(@as(i32, 0), try compareSemver("1.2.3-rc1", "1.2.3"));
    try testing.expectEqual(@as(i32, -1), try compareSemver("1.2.3-rc1", "1.2.4"));
}

test "parseUpdateFeed: newer available" {
    const body =
        \\{"version":"1.2.4","download_url":"https://example.com/app.tar.gz","sha256":"deadbeef","notes":"fixes"}
    ;
    var info = (try parseUpdateFeed(testing.allocator, body, "1.2.3")) orelse return error.TestExpectedNonNull;
    defer info.deinit();
    try testing.expectEqualStrings("1.2.4", info.version);
    try testing.expectEqualStrings("https://example.com/app.tar.gz", info.download_url);
    try testing.expectEqualStrings("deadbeef", info.sha256);
    try testing.expectEqualStrings("fixes", info.notes);
}

test "parseUpdateFeed: sha256 optional in feed" {
    const body =
        \\{"version":"2.0.0","download_url":"https://example.com/app.tar.gz"}
    ;
    var info = (try parseUpdateFeed(testing.allocator, body, "1.0.0")) orelse return error.TestExpectedNonNull;
    defer info.deinit();
    try testing.expectEqualStrings("", info.sha256);
}

test "parseUpdateFeed: up-to-date returns null" {
    const body =
        \\{"version":"1.2.3","download_url":"https://example.com/app.tar.gz"}
    ;
    const got = try parseUpdateFeed(testing.allocator, body, "1.2.3");
    try testing.expect(got == null);
}

test "parseUpdateFeed: bad json yields BadResponse" {
    const body = "not json";
    try testing.expectError(error.BadResponse, parseUpdateFeed(testing.allocator, body, "1.0.0"));
}

test "bytesToHexLower encodes correctly" {
    const input = [_]u8{ 0x00, 0x01, 0xab, 0xff } ++ ([_]u8{0} ** 28);
    var out: [64]u8 = undefined;
    bytesToHexLower(&out, &input);
    try testing.expectEqualStrings("0001abff", out[0..8]);
}

test "findAppBundle returns nearest .app ancestor" {
    const allocator = testing.allocator;
    const path = "/Applications/Foo.app/Contents/MacOS/Foo";
    const got = findAppBundle(allocator, path) orelse return error.TestExpectedNonNull;
    defer allocator.free(got);
    try testing.expectEqualStrings("/Applications/Foo.app", got);
}

test "findAppBundle returns null for bare binary" {
    const allocator = testing.allocator;
    const path = "/home/user/project/zig-out/bin/app";
    try testing.expect(findAppBundle(allocator, path) == null);
}

test "applyUpdate rejects empty sha256" {
    if (builtin.os.tag != .macos and builtin.os.tag != .windows) return; // else-branch returns Unsupported
    const info = UpdateInfo{
        .version = "",
        .download_url = "",
        .sha256 = "",
        .notes = "",
        .allocator = testing.allocator,
    };
    try testing.expectError(error.MissingChecksum, applyUpdate(testing.allocator, std.testing.io, &info));
}

test "buildSwapScript: wait loop + robocopy MOVE + relaunch + self-delete" {
    const s = try buildSwapScript(
        testing.allocator,
        4321,
        "C:\\Temp\\verve-update-4321\\new",
        "C:\\Program Files\\MyApp",
        "C:\\Program Files\\MyApp\\MyApp.exe",
        "C:\\Temp\\verve-update-4321",
    );
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "PID eq 4321") != null);
    try testing.expect(std.mem.indexOf(u8, s, "goto wait") != null);
    try testing.expect(std.mem.indexOf(u8, s, "robocopy \"C:\\Temp\\verve-update-4321\\new\" \"C:\\Program Files\\MyApp\" /E /MOVE") != null);
    try testing.expect(std.mem.indexOf(u8, s, "start \"\" \"C:\\Program Files\\MyApp\\MyApp.exe\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "del \"%~f0\"") != null);
}
