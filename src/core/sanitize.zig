//! URL sanitization for safe-by-default rich-content rendering.
//!
//! The markdown renderer (core/markdown.zig) feeds every link `href` and
//! image `src` through `safeUrl`, and strips embedded raw HTML entirely —
//! there is no allowlist pass-through. Text always flows through the
//! renderer's escaper (core/renderer.zig `escapeHtml`/`escapeAttr`), so this
//! module only guards the one channel escaping can't cover: the URL scheme.
//!
//! A single bypass here is a stored-XSS hole, so the policy is strict and
//! default-deny: a URL is allowed only if it has no scheme (relative /
//! root-relative / fragment / query) or a scheme on a tiny allowlist. We
//! never decode percent-escapes or entities — ambiguous input is rejected,
//! not normalized.

const std = @import("std");

/// Schemes safe to place in an `href`/`src`. Compared ASCII-case-insensitively.
const safe_schemes = [_][]const u8{ "http", "https", "mailto", "tel" };

/// Return `url` unchanged when it is safe to emit into an href/src
/// attribute, else `null` (caller drops the link/image).
///
/// Allowed:
///   - relative (`./a`, `a/b`), root-relative (`/path`), fragment (`#id`),
///     query (`?q=1`) — anything with no scheme.
///   - explicit schemes: http, https, mailto, tel.
///
/// Rejected: every other scheme — most importantly `javascript:`,
/// `vbscript:`, `data:`, and `file:`.
///
/// Bypass defenses (mirrors what browsers do before navigating):
///   - leading ASCII whitespace and C0 control bytes are skipped before
///     scheme detection.
///   - tab (0x09), LF (0x0A) and CR (0x0D) bytes *anywhere* in the scheme
///     portion are ignored, so `java&Tab;script:` collapses to `javascript:`
///     and is rejected rather than slipping through as a "weird relative".
///   - any other non-scheme byte before the `:` poisons the scheme so it
///     can't match the allowlist.
pub fn safeUrl(url: []const u8) ?[]const u8 {
    // Skip leading whitespace + C0 controls (browsers strip these).
    var start: usize = 0;
    while (start < url.len and url[start] <= 0x20) : (start += 1) {}
    if (start >= url.len) return null;

    var scheme_buf: [16]u8 = undefined;
    var n: usize = 0;
    var poisoned = false;
    var has_scheme = false;

    var i: usize = start;
    while (i < url.len) : (i += 1) {
        const c = url[i];
        // Browsers strip these from URLs before parsing — do the same so a
        // scheme can't be smuggled past us by splitting it with controls.
        if (c == 0x09 or c == 0x0A or c == 0x0D) continue;
        if (c == ':') {
            has_scheme = true;
            break;
        }
        // A path/query/fragment delimiter before any ':' means there is no
        // scheme at all → relative URL, which is always safe.
        if (c == '/' or c == '?' or c == '#') break;
        if (isSchemeChar(c)) {
            if (n < scheme_buf.len) {
                scheme_buf[n] = std.ascii.toLower(c);
                n += 1;
            } else {
                poisoned = true; // longer than any safe scheme
            }
        } else {
            poisoned = true; // junk in the scheme position
        }
    }

    if (!has_scheme) return url; // relative / root-relative / fragment / query
    if (poisoned) return null;
    if (isSafeScheme(scheme_buf[0..n])) return url;
    return null;
}

/// Scheme characters per RFC 3986: ALPHA / DIGIT / "+" / "-" / ".".
fn isSchemeChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.';
}

fn isSafeScheme(scheme: []const u8) bool {
    for (safe_schemes) |s| {
        if (std.ascii.eqlIgnoreCase(scheme, s)) return true;
    }
    return false;
}

// ---- tests ---------------------------------------------------------------

test "safeUrl allows relative and absolute-path URLs" {
    try std.testing.expect(safeUrl("about") != null);
    try std.testing.expect(safeUrl("./docs/intro") != null);
    try std.testing.expect(safeUrl("../up") != null);
    try std.testing.expect(safeUrl("/root/path") != null);
    try std.testing.expect(safeUrl("#section") != null);
    try std.testing.expect(safeUrl("?q=1") != null);
}

test "safeUrl allows http/https/mailto/tel" {
    try std.testing.expect(safeUrl("http://example.com") != null);
    try std.testing.expect(safeUrl("https://example.com/a?b#c") != null);
    try std.testing.expect(safeUrl("HTTPS://EXAMPLE.COM") != null);
    try std.testing.expect(safeUrl("mailto:a@b.com") != null);
    try std.testing.expect(safeUrl("tel:+15555555") != null);
}

test "safeUrl rejects javascript and other dangerous schemes" {
    try std.testing.expect(safeUrl("javascript:alert(1)") == null);
    try std.testing.expect(safeUrl("JaVaScRiPt:alert(1)") == null);
    try std.testing.expect(safeUrl("vbscript:msgbox(1)") == null);
    try std.testing.expect(safeUrl("data:text/html,<script>") == null);
    try std.testing.expect(safeUrl("file:///etc/passwd") == null);
}

test "safeUrl defeats control-char and whitespace bypasses" {
    // leading control byte
    try std.testing.expect(safeUrl("\x01javascript:alert(1)") == null);
    // leading whitespace
    try std.testing.expect(safeUrl("  javascript:alert(1)") == null);
    // tab embedded inside the scheme
    try std.testing.expect(safeUrl("java\tscript:alert(1)") == null);
    // newline embedded inside the scheme
    try std.testing.expect(safeUrl("java\nscript:alert(1)") == null);
    // CR embedded inside the scheme
    try std.testing.expect(safeUrl("java\r\nscript:alert(1)") == null);
}

test "safeUrl rejects empty and whitespace-only" {
    try std.testing.expect(safeUrl("") == null);
    try std.testing.expect(safeUrl("   ") == null);
}
