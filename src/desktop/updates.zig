//! Auto-updater check (pure stdlib, no native APIs).
//!
//! `checkForUpdate(allocator, feed_url, current_version)` fetches a JSON
//! feed describing the latest release, compares versions, and returns
//! `?UpdateInfo` — null when the caller is already up to date,
//! otherwise the latest version + download URL + release notes.
//!
//! This is the **check** half of an auto-updater. Actually applying
//! the update (downloading the binary, verifying signatures, swapping
//! the running executable, restarting) is per-platform work — Sparkle
//! on macOS / Squirrel or MSIX on Windows / AppImageUpdate on Linux.
//! Those stay out of scope for this module; apps that ship one of
//! those frameworks call this `checkForUpdate` first, then hand off
//! to the platform updater when an update exists.
//!
//! Feed format (JSON):
//!
//! ```json
//! {
//!   "version": "1.2.3",
//!   "download_url": "https://example.com/myapp-1.2.3-aarch64-macos.tar.gz",
//!   "notes": "Fixed the splat bug."
//! }
//! ```
//!
//! `version` follows the standard `<major>.<minor>.<patch>` shape
//! (extra suffixes like `-rc1` lex but only the numeric prefix is
//! compared). `notes` is optional.
//!
//! Cross-platform: pure stdlib HTTP + JSON, identical on macOS /
//! Windows / Linux. No native auto-updater frameworks linked.

const std = @import("std");
const builtin = @import("builtin");
const Writer = std.Io.Writer;

pub const Error = error{
    Network,
    BadResponse,
    InvalidVersion,
    OutOfMemory,
    UnsupportedOnClient,
};

pub const UpdateInfo = struct {
    /// Latest version reported by the feed. Owned by the caller-
    /// supplied allocator.
    version: []const u8,
    /// Direct URL to the platform-appropriate update artifact. Owned.
    download_url: []const u8,
    /// Optional release notes string. Empty when the feed omitted
    /// the field. Owned.
    notes: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *const UpdateInfo) void {
        self.allocator.free(self.version);
        self.allocator.free(self.download_url);
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
        .notes = allocator.dupe(u8, parsed.value.notes) catch return error.OutOfMemory,
        .allocator = allocator,
    };
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
        \\{"version":"1.2.4","download_url":"https://example.com/app.tar.gz","notes":"fixes"}
    ;
    var info = (try parseUpdateFeed(testing.allocator, body, "1.2.3")) orelse return error.TestExpectedNonNull;
    defer info.deinit();
    try testing.expectEqualStrings("1.2.4", info.version);
    try testing.expectEqualStrings("https://example.com/app.tar.gz", info.download_url);
    try testing.expectEqualStrings("fixes", info.notes);
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
