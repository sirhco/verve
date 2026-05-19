//! Gzip compression helper. Wraps std.compress.flate with the `.gzip`
//! container so output is a fully-formed gzip stream (header + deflate
//! body + crc32 + isize footer) ready to ship as a single Content-Length
//! response.

const std = @import("std");
const flate = std.compress.flate;

/// Compress `input` into a heap-allocated gzip stream. Caller owns the
/// returned slice (free with the same allocator).
pub fn compress(gpa: std.mem.Allocator, input: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    // Ensure the output writer has capacity for at least the gzip header
    // (10 bytes) — flate.Compress.init asserts output.buffer.len > 8.
    try aw.ensureUnusedCapacity(64);

    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);

    var compressor = try flate.Compress.init(&aw.writer, window, .gzip, flate.Compress.Options.default);
    try compressor.writer.writeAll(input);
    try compressor.finish();

    return aw.toOwnedSlice();
}

/// True when the content-type is worth compressing. Skips already-
/// compressed binary formats (PNG / WEBP / WASM) where gzip costs CPU
/// for negligible size win.
pub fn shouldCompress(content_type: []const u8) bool {
    if (startsAny(content_type, &.{
        "text/",
        "application/json",
        "application/javascript",
        "image/svg+xml",
    })) return true;
    return false;
}

fn startsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (std.mem.startsWith(u8, haystack, n)) return true;
    }
    return false;
}

test "gzip roundtrip via std.compress.flate Decompress" {
    const gpa = std.testing.allocator;
    const input = "the quick brown fox jumps over the lazy dog. " ** 32;

    const compressed = try compress(gpa, input);
    defer gpa.free(compressed);

    // gzip magic bytes
    try std.testing.expectEqual(@as(u8, 0x1f), compressed[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), compressed[1]);

    // Decompress and verify the body matches.
    var in_reader: std.Io.Reader = .fixed(compressed);
    var decompress_buf: [flate.max_window_len]u8 = undefined;
    var dc: flate.Decompress = .init(&in_reader, .gzip, &decompress_buf);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try dc.reader.streamRemaining(&out.writer);
    try std.testing.expectEqualStrings(input, out.written());
}

test "shouldCompress selects text-ish types" {
    try std.testing.expect(shouldCompress("text/html; charset=utf-8"));
    try std.testing.expect(shouldCompress("application/json"));
    try std.testing.expect(shouldCompress("application/javascript"));
    try std.testing.expect(shouldCompress("image/svg+xml"));
    try std.testing.expect(!shouldCompress("image/png"));
    try std.testing.expect(!shouldCompress("application/wasm"));
    try std.testing.expect(!shouldCompress("application/octet-stream"));
}
