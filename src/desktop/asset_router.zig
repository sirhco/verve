//! Pure-Zig resolver for the `verve://app/<path>` custom URL scheme.
//!
//! Every platform backend funnels resource requests through `resolve`,
//! which performs a linear scan of the supplied entry table and returns
//! the matching bytes plus a MIME guess. The implementation never
//! allocates and never touches the filesystem — the asset bytes live in
//! the embedded `public_assets` module the build emits.
//!
//! The MIME table mirrors `build.zig:guessContentType` plus a handful of
//! extra entries WKWebView and WebView2 are strict about (notably
//! `application/javascript` for `.mjs` and `application/wasm` for
//! streaming-instantiated WebAssembly).

const std = @import("std");
const options = @import("options.zig");

/// Successful resolution result. `bytes` aliases into the entry table
/// — the caller must not free it. `content_type` is one of the strings
/// from `mime_table` and is also static.
pub const Resolved = struct {
    bytes: []const u8,
    content_type: []const u8,
};

pub const ResolveError = error{
    NotFound,
};

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
