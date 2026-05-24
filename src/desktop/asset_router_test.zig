//! Headless tests for `asset_router.resolve` and `guessContentType`.
//! These compile on every host so the desktop subsystem participates
//! in `zig build test` even where no windowing system exists.
//!
//! Acts as the aggregator entry for `zig build test` — other
//! desktop-side headless test files (`cookies_test.zig`,
//! `surface_test.zig`) are pulled in below so their `test {}` blocks
//! run in the same artifact.

const std = @import("std");
const router = @import("asset_router.zig");
const options = @import("options.zig");

comptime {
    _ = @import("cookies_test.zig");
    _ = @import("surface_test.zig");
}

const entries = [_]options.AssetEntry{
    .{ .path = "index.html", .bytes = "<!doctype html>", .content_type = "" },
    .{ .path = "client.wasm", .bytes = &.{ 0x00, 0x61, 0x73, 0x6d }, .content_type = "" },
    .{ .path = "css/main.css", .bytes = "body{}", .content_type = "text/css; charset=utf-8" },
};

test "resolves leading-slash path" {
    const r = try router.resolve(&entries, "/index.html");
    try std.testing.expectEqualStrings("<!doctype html>", r.bytes);
    try std.testing.expectEqualStrings("text/html; charset=utf-8", r.content_type);
}

test "resolves bare path" {
    const r = try router.resolve(&entries, "client.wasm");
    try std.testing.expectEqual(@as(usize, 4), r.bytes.len);
    try std.testing.expectEqualStrings("application/wasm", r.content_type);
}

test "empty path defaults to index.html" {
    const r = try router.resolve(&entries, "");
    try std.testing.expectEqualStrings("<!doctype html>", r.bytes);
}

test "honors explicit content_type" {
    const r = try router.resolve(&entries, "css/main.css");
    try std.testing.expectEqualStrings("text/css; charset=utf-8", r.content_type);
}

test "missing path returns NotFound" {
    try std.testing.expectError(error.NotFound, router.resolve(&entries, "missing.json"));
}

test "guessContentType handles common extensions" {
    try std.testing.expectEqualStrings("application/wasm", router.guessContentType("a/b.wasm"));
    try std.testing.expectEqualStrings("application/javascript", router.guessContentType("x.mjs"));
    try std.testing.expectEqualStrings("font/woff2", router.guessContentType("FONT.WOFF2"));
    try std.testing.expectEqualStrings("application/octet-stream", router.guessContentType("noext"));
}
