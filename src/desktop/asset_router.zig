//! Pure-Zig resolver for the `verve://app/<path>` custom URL scheme.
//!
//! Every platform backend funnels resource requests through `resolve`
//! (production path) or `resolveWithFallback` (dev path).
//!
//! `resolve` performs a linear scan of the supplied entry table and
//! returns the matching bytes plus a MIME guess. It never allocates
//! and never touches the filesystem — the asset bytes live in the
//! embedded `public_assets` module the build emits.
//!
//! `resolveWithFallback` consults `dev_assets_dir` FIRST and falls
//! through to the embedded table only when the disk file is missing.
//! Disk wins so a developer editing `frontend/style.css` reloads with
//! their change instead of the build-time copy. This is the runtime
//! backbone of `--dev <dir>` mode: edit a frontend file, reload the
//! WebView, see changes without rebuilding the binary. Returned bytes
//! carry an `owned` flag so the caller knows whether to free them.
//!
//! The MIME table mirrors `build.zig:guessContentType` plus a handful of
//! extra entries WKWebView and WebView2 are strict about (notably
//! `application/javascript` for `.mjs` and `application/wasm` for
//! streaming-instantiated WebAssembly).

const std = @import("std");
const options = @import("options.zig");

/// Successful resolution result. When `owned == false`, `bytes` aliases
/// into the entry table and the caller must not free it. When
/// `owned == true`, `bytes` was allocated by `resolveWithFallback` and
/// the caller is responsible for calling `deinit`.
pub const Resolved = struct {
    bytes: []const u8,
    content_type: []const u8,
    owned: bool = false,

    pub fn deinit(self: Resolved, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.bytes);
    }
};

pub const ResolveError = error{
    NotFound,
};

/// Errors `resolveWithFallback` can produce beyond the plain
/// `ResolveError`. `AccessDenied` is the path-traversal guard; the
/// rest are I/O outcomes propagated for diagnostics.
pub const FallbackResolveError = error{
    NotFound,
    AccessDenied,
    OutOfMemory,
    FileTooLarge,
    IoFailed,
};

/// Hard cap on disk-fallback files. Dev mode is meant for hand-written
/// frontend assets, not arbitrary downloads — keeping the ceiling small
/// turns a misconfigured directory into a 4xx instead of a runaway alloc.
pub const max_dev_file_size: usize = 16 * 1024 * 1024;

/// Look up `path` in `entries`. Strips a leading slash so callers can
/// pass either `/index.html` (typical of platform request URLs) or
/// `index.html` (typical of the build's manifest) and get a hit either
/// way. Empty paths resolve to `index.html` as a convenience for the
/// scheme-handler entry point.
pub fn resolve(entries: []const options.AssetEntry, path: []const u8) ResolveError!Resolved {
    var key = path;
    if (key.len > 0 and key[0] == '/') key = key[1..];
    if (key.len == 0) key = "index.html";

    for (entries) |e| {
        if (std.mem.eql(u8, e.path, key)) {
            const ct = if (e.content_type.len > 0) e.content_type else guessContentType(e.path);
            return .{ .bytes = e.bytes, .content_type = ct };
        }
    }
    return error.NotFound;
}

/// Try `<dev_assets_dir>/<path>` first; on disk miss, fall through to
/// `resolve(entries, path)`. Rejects absolute paths and any segment
/// equal to `..` so a malicious request can't escape the dev directory.
/// Returned `Resolved` with `.owned = true` must be deinit'd with the
/// same allocator. When `dev_assets_dir == null`, this collapses to a
/// plain `resolve` call and never allocates.
pub fn resolveWithFallback(
    allocator: std.mem.Allocator,
    io: std.Io,
    entries: []const options.AssetEntry,
    path: []const u8,
    dev_assets_dir: ?[]const u8,
) FallbackResolveError!Resolved {
    const dir_path = dev_assets_dir orelse {
        return resolve(entries, path) catch return error.NotFound;
    };

    var key = path;
    if (key.len > 0 and key[0] == '/') key = key[1..];
    if (key.len == 0) key = "index.html";

    if (std.fs.path.isAbsolute(key)) return error.AccessDenied;
    var iter = std.mem.tokenizeAny(u8, key, "/\\");
    while (iter.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return error.AccessDenied;
    }

    if (tryReadFromDisk(allocator, io, dir_path, key)) |bytes| {
        return .{
            .bytes = bytes,
            .content_type = guessContentType(key),
            .owned = true,
        };
    } else |err| switch (err) {
        error.NotFound => {},
        else => |e| return e,
    }

    return resolve(entries, path) catch return error.NotFound;
}

fn tryReadFromDisk(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    key: []const u8,
) FallbackResolveError![]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return error.NotFound;
    defer dir.close(io);

    var file = dir.openFile(io, key, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.IsDir => return error.NotFound,
        else => return error.IoFailed,
    };
    defer file.close(io);

    const stat = file.stat(io) catch return error.IoFailed;
    if (stat.size > max_dev_file_size) return error.FileTooLarge;

    const size: usize = @intCast(stat.size);
    const bytes = allocator.alloc(u8, size) catch return error.OutOfMemory;
    errdefer allocator.free(bytes);
    _ = file.readPositionalAll(io, bytes, 0) catch return error.IoFailed;
    return bytes;
}

/// Extension → MIME type table. Matched case-insensitively against the
/// substring following the last `.` in the path. Returns
/// `application/octet-stream` when no row matches — WKWebView treats
/// that as a download trigger, so make sure new asset kinds land here.
pub fn guessContentType(path: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "application/octet-stream";
    const ext = path[dot + 1 ..];
    inline for (mime_table) |row| {
        if (std.ascii.eqlIgnoreCase(ext, row[0])) return row[1];
    }
    return "application/octet-stream";
}

const mime_table = .{
    .{ "html", "text/html; charset=utf-8" },
    .{ "htm", "text/html; charset=utf-8" },
    .{ "css", "text/css; charset=utf-8" },
    .{ "js", "application/javascript" },
    .{ "mjs", "application/javascript" },
    .{ "map", "application/json" },
    .{ "json", "application/json" },
    .{ "wasm", "application/wasm" },
    .{ "txt", "text/plain; charset=utf-8" },
    .{ "svg", "image/svg+xml" },
    .{ "png", "image/png" },
    .{ "jpg", "image/jpeg" },
    .{ "jpeg", "image/jpeg" },
    .{ "webp", "image/webp" },
    .{ "gif", "image/gif" },
    .{ "ico", "image/x-icon" },
    .{ "woff", "font/woff" },
    .{ "woff2", "font/woff2" },
    .{ "ttf", "font/ttf" },
    .{ "otf", "font/otf" },
};
