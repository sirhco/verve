//! clipboard_codec.zig — target-agnostic CF_HTML marshalling for the Windows
//! native-host backend.
//!
//! The Windows clipboard's HTML payload uses Microsoft's `CF_HTML` format: the
//! HTML fragment is nested inside a minimal `<html><body>` shell, prefixed by a
//! plain-ASCII header carrying byte offsets that point at the fragment
//! boundaries. Building and parsing that header is pure string/offset work with
//! no Win32 dependency, so it lives here in Zig (imports only std + options.zig)
//! and its `test` blocks run on any host under `zig build test` — exactly the
//! same precedent as `cookie_codec.zig`.
//!
//! `windows_native.zig`'s clipboardWriteHtml/ReadHtml call `wrapCfHtml` /
//! `extractCfHtmlFragment` here and ship the finished CF_HTML bytes across the C
//! ABI; the native host just `SetClipboardData`'s / `GetClipboardData`'s the
//! registered "HTML Format" with those raw bytes. The tested code IS the shipped
//! code.
//!
//! The header format + offset math are ported byte-for-byte from the legacy
//! `windows.zig` clipboardWriteHtml/ReadHtml so paste targets (Word, browsers)
//! accept the output: offsets are byte counts from buffer start, zero-padded to
//! 10 ASCII digits.
//!
//! Spec: https://learn.microsoft.com/en-us/windows/win32/dataxchg/html-clipboard-format

const std = @import("std");
const opts_mod = @import("../options.zig");

pub const ClipboardError = opts_mod.ClipboardError;

// The header carries four 10-digit zero-padded offsets; the placeholders below
// are overwritten in place by `writeOffset`. The trailing CRLF closes the
// header so the fragment shell begins at exactly `header_template.len`.
const header_template =
    "Version:0.9\r\n" ++
    "StartHTML:0000000000\r\n" ++
    "EndHTML:0000000000\r\n" ++
    "StartFragment:0000000000\r\n" ++
    "EndFragment:0000000000\r\n";
const html_prefix = "<html>\r\n<body>\r\n<!--StartFragment-->";
const html_suffix = "<!--EndFragment-->\r\n</body>\r\n</html>";

/// Wrap a raw HTML `fragment` in the CF_HTML envelope, back-patching the four
/// header offsets so StartFragment/EndFragment point at the real fragment bytes.
/// The returned buffer is NUL-terminated (the byte at `len` is 0) but the slice
/// length excludes that NUL — callers that need a NUL (the Win32 clipboard does
/// not require one for "HTML Format") can index one past `.len`. Caller owns the
/// returned slice.
pub fn wrapCfHtml(allocator: std.mem.Allocator, fragment: []const u8) ClipboardError![]u8 {
    const start_html = header_template.len;
    const start_fragment = start_html + html_prefix.len;
    const end_fragment = start_fragment + fragment.len;
    const end_html = end_fragment + html_suffix.len;

    const total = end_html;
    // +1 for a trailing NUL — harmless and matches the legacy backend, which
    // allocated `total + 1` and NUL-terminated the HGLOBAL.
    const buf = allocator.alloc(u8, total + 1) catch return error.OutOfMemory;
    errdefer allocator.free(buf);

    @memcpy(buf[0..header_template.len], header_template);
    writeOffset(buf, "StartHTML:", start_html);
    writeOffset(buf, "EndHTML:", end_html);
    writeOffset(buf, "StartFragment:", start_fragment);
    writeOffset(buf, "EndFragment:", end_fragment);
    @memcpy(buf[start_html..][0..html_prefix.len], html_prefix);
    @memcpy(buf[start_fragment..][0..fragment.len], fragment);
    @memcpy(buf[end_fragment..][0..html_suffix.len], html_suffix);
    buf[total] = 0;

    // Hand back the CF_HTML bytes WITHOUT the trailing NUL in the length; the
    // NUL still lives at buf[total] for any consumer that wants it.
    return allocator.realloc(buf, total) catch return error.OutOfMemory;
}

/// Extract the inner HTML fragment from a CF_HTML payload by reading the
/// StartFragment / EndFragment header offsets and slicing those bytes out. Mirrors
/// the legacy ReadHtml parse: producers (Chrome, Word, …) all agree on the header
/// shape, only the fragment varies. Returns `null` when the header is absent or
/// the offsets are inconsistent (so a clipboard holding non-CF_HTML data reads as
/// "no HTML" rather than erroring). The returned slice is owned by `allocator`.
pub fn extractCfHtmlFragment(allocator: std.mem.Allocator, cf_html: []const u8) ClipboardError!?[]u8 {
    const start = parseOffset(cf_html, "StartFragment:") orelse return null;
    const end = parseOffset(cf_html, "EndFragment:") orelse return null;
    if (start >= end or end > cf_html.len) return null;
    const fragment = cf_html[start..end];
    return allocator.dupe(u8, fragment) catch return error.OutOfMemory;
}

/// Patch a 10-digit zero-padded `offset` into `buf` immediately after the literal
/// `label` (part of `header_template`). The caller has already copied the template
/// into `buf`; this overwrites the `0000000000` placeholder digits in place.
fn writeOffset(buf: []u8, label: []const u8, offset: usize) void {
    const idx = std.mem.indexOf(u8, buf, label) orelse return;
    const digits_start = idx + label.len;
    var n = offset;
    var i: usize = 10;
    while (i > 0) : (i -= 1) {
        buf[digits_start + i - 1] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
    }
}

/// Read the decimal integer following `label` in `buf`, skipping optional inline
/// whitespace (CF_HTML producers vary in padding). Returns null when the label is
/// absent or no digits follow. The CF_HTML spec uses fixed 10-digit offset
/// fields, so digit accumulation is capped at 10 — a longer (untrusted) run is
/// rejected as null rather than wrapping `usize`.
fn parseOffset(buf: []const u8, label: []const u8) ?usize {
    const idx = std.mem.indexOf(u8, buf, label) orelse return null;
    var i = idx + label.len;
    while (i < buf.len and (buf[i] == ' ' or buf[i] == '\t')) : (i += 1) {}
    var n: usize = 0;
    var digits: usize = 0;
    while (i < buf.len and std.ascii.isDigit(buf[i])) : (i += 1) {
        // CF_HTML offsets are 10 digits; an over-long field is malformed.
        if (digits == 10) return null;
        n = n * 10 + (buf[i] - '0');
        digits += 1;
    }
    return if (digits != 0) n else null;
}

// ---- tests (run on the host that builds `zig build test`) -------------------

test "wrapCfHtml round-trips through extractCfHtmlFragment" {
    const a = std.testing.allocator;
    const fragment = "<b>hello</b> &amp; <i>world</i>";

    const cf = try wrapCfHtml(a, fragment);
    defer a.free(cf);

    const back = (try extractCfHtmlFragment(a, cf)).?;
    defer a.free(back);

    try std.testing.expectEqualStrings(fragment, back);
}

test "wrapCfHtml offsets point at the real fragment bytes" {
    const a = std.testing.allocator;
    const fragment = "<p>offset check</p>";

    const cf = try wrapCfHtml(a, fragment);
    defer a.free(cf);

    // The StartFragment/EndFragment offsets in the header must bracket exactly
    // the fragment bytes — byte-accurate or paste targets reject the payload.
    const start = parseOffset(cf, "StartFragment:").?;
    const end = parseOffset(cf, "EndFragment:").?;
    try std.testing.expectEqualStrings(fragment, cf[start..end]);

    // StartHTML points at the start of the <html> shell; EndHTML at the buffer
    // end (== cf.len, since wrap drops the trailing NUL from the slice length).
    const start_html = parseOffset(cf, "StartHTML:").?;
    const end_html = parseOffset(cf, "EndHTML:").?;
    try std.testing.expect(std.mem.startsWith(u8, cf[start_html..], "<html>"));
    try std.testing.expectEqual(cf.len, end_html);

    // The fragment is wrapped by the documented prefix/suffix markers.
    try std.testing.expect(std.mem.indexOf(u8, cf, "<!--StartFragment-->") != null);
    try std.testing.expect(std.mem.indexOf(u8, cf, "<!--EndFragment-->") != null);
}

test "wrapCfHtml header uses 10-digit zero-padded offsets" {
    const a = std.testing.allocator;
    const cf = try wrapCfHtml(a, "x");
    defer a.free(cf);

    // Every offset label is followed by exactly 10 ASCII digits.
    for ([_][]const u8{ "StartHTML:", "EndHTML:", "StartFragment:", "EndFragment:" }) |label| {
        const idx = std.mem.indexOf(u8, cf, label).?;
        const digits = cf[idx + label.len ..][0..10];
        for (digits) |d| try std.testing.expect(std.ascii.isDigit(d));
    }
}

test "extractCfHtmlFragment parses a known external CF_HTML sample" {
    const a = std.testing.allocator;
    // A real-world-shaped CF_HTML blob (offsets computed for this exact string).
    // StartFragment=141, EndFragment=153 bracket "Hello, world".
    const sample =
        "Version:0.9\r\n" ++
        "StartHTML:0000000105\r\n" ++
        "EndHTML:0000000189\r\n" ++
        "StartFragment:0000000141\r\n" ++
        "EndFragment:0000000153\r\n" ++
        "<html>\r\n<body>\r\n<!--StartFragment-->Hello, world<!--EndFragment-->\r\n</body>\r\n</html>";

    // Sanity-check the literal offsets actually point where we claim.
    try std.testing.expectEqualStrings("Hello, world", sample[141..153]);

    const frag = (try extractCfHtmlFragment(a, sample)).?;
    defer a.free(frag);
    try std.testing.expectEqualStrings("Hello, world", frag);
}

test "extractCfHtmlFragment returns null on non-CF_HTML or bad offsets" {
    const a = std.testing.allocator;

    // No header at all.
    try std.testing.expectEqual(@as(?[]u8, null), try extractCfHtmlFragment(a, "just some plain text"));

    // StartFragment present but EndFragment missing.
    try std.testing.expectEqual(
        @as(?[]u8, null),
        try extractCfHtmlFragment(a, "StartFragment:0000000010\r\nxxxxxxxxxx"),
    );

    // Offsets out of range (end > len).
    try std.testing.expectEqual(
        @as(?[]u8, null),
        try extractCfHtmlFragment(a, "StartFragment:0000000000\r\nEndFragment:0000009999\r\n"),
    );

    // start >= end.
    try std.testing.expectEqual(
        @as(?[]u8, null),
        try extractCfHtmlFragment(a, "StartFragment:0000000005\r\nEndFragment:0000000005\r\n"),
    );
}

test "parseOffset rejects over-long offset fields instead of wrapping usize" {
    // A 20+ digit field (well past CF_HTML's fixed 10) must read as null, not a
    // silently wrapped usize that could slice out of bounds downstream.
    try std.testing.expectEqual(@as(?usize, null), parseOffset("StartFragment:99999999999999999999\r\n", "StartFragment:"));

    // The boundary still parses: exactly 10 digits is the spec width.
    try std.testing.expectEqual(@as(?usize, 9999999999), parseOffset("StartFragment:9999999999\r\n", "StartFragment:"));

    // …and an over-long field makes the whole extract return null.
    const a = std.testing.allocator;
    try std.testing.expectEqual(
        @as(?[]u8, null),
        try extractCfHtmlFragment(a, "StartFragment:99999999999999999999\r\nEndFragment:0000000010\r\n"),
    );
}
