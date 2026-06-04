//! toast_codec.zig — pure-Zig helper for the WinRT toast XML payload.
//!
//! Host-tested (imported by `windows_native.zig` AND the desktop test root
//! `src/desktop/asset_router_test.zig`), same precedent as `cookie_codec.zig`
//! and `clipboard_codec.zig`. The WinRT `showToast` path widens this UTF-8 XML
//! to UTF-16 and hands it to `IXmlDocumentIO::LoadXml`; the escaping here keeps
//! a title/body with `&`, `<`, `>`, or `"` from breaking the XML template.

const std = @import("std");

/// XML-escape `&`, `<`, `>`, `"` for safe interpolation into the toast
/// template. Caller owns the result. Mirrors the legacy `windows.zig`
/// `xmlEscape`.
pub fn xmlEscape(allocator: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Build a `ToastGeneric` toast XML payload (title + body). Caller owns the
/// result. Mirrors the legacy `windows.zig` `buildToastXml`.
pub fn buildToastXml(allocator: std.mem.Allocator, title: []const u8, body: []const u8) error{OutOfMemory}![]u8 {
    const et = try xmlEscape(allocator, title);
    defer allocator.free(et);
    const eb = try xmlEscape(allocator, body);
    defer allocator.free(eb);
    return std.fmt.allocPrint(
        allocator,
        "<toast><visual><binding template=\"ToastGeneric\"><text>{s}</text><text>{s}</text></binding></visual></toast>",
        .{ et, eb },
    );
}

const testing = std.testing;

test "xmlEscape: escapes the four XML metacharacters we care about" {
    const out = try xmlEscape(testing.allocator, "a&b<c>d\"e");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a&amp;b&lt;c&gt;d&quot;e", out);
}

test "xmlEscape: passes plain text through unchanged" {
    const out = try xmlEscape(testing.allocator, "Build finished");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Build finished", out);
}

test "buildToastXml: title + body land in the two <text> nodes" {
    const out = try buildToastXml(testing.allocator, "Deploy", "Done in 3s");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "<toast><visual><binding template=\"ToastGeneric\"><text>Deploy</text><text>Done in 3s</text></binding></visual></toast>",
        out,
    );
}

test "buildToastXml: escapes interpolated title + body so markup can't inject" {
    const out = try buildToastXml(testing.allocator, "<b>hi</b>", "a & b");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "<toast><visual><binding template=\"ToastGeneric\"><text>&lt;b&gt;hi&lt;/b&gt;</text><text>a &amp; b</text></binding></visual></toast>",
        out,
    );
}
