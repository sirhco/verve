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
    _ = @import("single_instance.zig");
    _ = @import("updates.zig");
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

test "resolveWithFallback returns embedded match without touching disk" {
    const r = try router.resolveWithFallback(
        std.testing.allocator,
        std.testing.io,
        &entries,
        "index.html",
        null,
    );
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(!r.owned);
    try std.testing.expectEqualStrings("<!doctype html>", r.bytes);
}

test "resolveWithFallback reads disk on embedded miss" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const css_body = "/* hot-reloaded css */";
    try tmp.dir.writeFile(io, .{ .sub_path = "new-asset.css", .data = css_body });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const r = try router.resolveWithFallback(
        std.testing.allocator,
        io,
        &entries,
        "new-asset.css",
        dir_path,
    );
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r.owned);
    try std.testing.expectEqualStrings(css_body, r.bytes);
    try std.testing.expectEqualStrings("text/css; charset=utf-8", r.content_type);
}

test "resolveWithFallback disk overrides embedded when both exist" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The embedded entry `index.html` has body "<!doctype html>". Drop
    // a different body on disk and assert it wins. This is the hot-
    // reload semantics that make `--dev` useful at all.
    const overridden = "<!doctype html><body>dev override</body>";
    try tmp.dir.writeFile(io, .{ .sub_path = "index.html", .data = overridden });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const r = try router.resolveWithFallback(
        std.testing.allocator,
        io,
        &entries,
        "index.html",
        dir_path,
    );
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r.owned);
    try std.testing.expectEqualStrings(overridden, r.bytes);
}

test "resolveWithFallback falls through to embedded on disk miss" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    // `index.html` is in the embedded table but the tmp dir is empty,
    // so the request should fall through and return the static bytes.
    const r = try router.resolveWithFallback(
        std.testing.allocator,
        io,
        &entries,
        "index.html",
        dir_path,
    );
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(!r.owned);
    try std.testing.expectEqualStrings("<!doctype html>", r.bytes);
}

test "resolveWithFallback rejects parent-dir traversal" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    try std.testing.expectError(error.AccessDenied, router.resolveWithFallback(
        std.testing.allocator,
        io,
        &entries,
        "../etc/passwd",
        dir_path,
    ));
}

test "resolveWithFallback rejects absolute paths" {
    // Scheme handlers strip a single leading slash, so the absolute-path
    // guard kicks in for paths that remain absolute after that strip
    // (`//etc/passwd` on POSIX, `C:\...` on Windows).
    try std.testing.expectError(error.AccessDenied, router.resolveWithFallback(
        std.testing.allocator,
        std.testing.io,
        &entries,
        "//etc/passwd",
        "/tmp",
    ));
}

test "resolveWithFallback returns NotFound when dir missing and disk missing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    try std.testing.expectError(error.NotFound, router.resolveWithFallback(
        std.testing.allocator,
        io,
        &entries,
        "missing.json",
        dir_path,
    ));
}
