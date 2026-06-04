//! cookie_codec.zig — target-agnostic cookie field marshalling for the
//! Windows native-host backend.
//!
//! This module holds the pure-Zig half of the cookie surface: the SameSite
//! enum <-> int mapping that crosses the C ABI, and the `decodeCookie` builder
//! that turns the flat scalar/string args returned by `wv2_cookie_get` into an
//! owned `options.Cookie`. It deliberately imports NO extern host functions, so
//! it compiles and its `test` blocks run on any host (macOS / Linux CI), and the
//! real `windows_native.zig` cookie path calls straight into these helpers — the
//! tested code IS the shipped code.
//!
//! Wire mapping (must match webview2_host.cpp's int values, which mirror
//! COREWEBVIEW2_COOKIE_SAME_SITE_KIND): none=0, lax=1, strict=2. `.default`
//! (Verve's "unset") marshals as LAX on the way out — matching the legacy
//! `windows.zig` backend, where WebView2 has no distinct "default" kind and the
//! framework treats an unspecified SameSite as Lax.

const std = @import("std");
const opts_mod = @import("../options.zig");

pub const Cookie = opts_mod.Cookie;
pub const CookieError = opts_mod.CookieError;
pub const SameSite = opts_mod.SameSite;

/// COREWEBVIEW2_COOKIE_SAME_SITE_KIND integer values (the C ABI / WebView2 enum).
pub const SAME_SITE_NONE: i32 = 0;
pub const SAME_SITE_LAX: i32 = 1;
pub const SAME_SITE_STRICT: i32 = 2;

/// Map a Verve `SameSite` onto the native int sent across the C ABI when
/// *setting* a cookie. `.default` and `.lax` both map to LAX — WebView2 has no
/// "unspecified" kind and the legacy backend coalesced default->Lax.
pub fn sameSiteToInt(ss: SameSite) i32 {
    return switch (ss) {
        .none => SAME_SITE_NONE,
        .default, .lax => SAME_SITE_LAX,
        .strict => SAME_SITE_STRICT,
    };
}

/// Map a native int (from `wv2_cookie_get`) back onto a Verve `SameSite`.
/// Unknown values fall back to `.default`, matching legacy `marshalCookie`.
pub fn sameSiteFromInt(v: i32) SameSite {
    return switch (v) {
        SAME_SITE_NONE => .none,
        SAME_SITE_LAX => .lax,
        SAME_SITE_STRICT => .strict,
        else => .default,
    };
}

/// Build an owned `Cookie` from the flat fields `wv2_cookie_get` filled in.
///
/// The four string slices are duped into `allocator` (the CookieStore contract:
/// the caller frees `name`/`value`/`domain`/`path`). On any allocation failure
/// the partial dupes are freed before returning `error.OutOfMemory`.
///
/// `has_expiry` == 0 means a session cookie -> `expires_unix = 0`. When set, the
/// double epoch-seconds value is truncated to `i64`; a non-positive expiry (the
/// WebView2 "session" sentinel, which surfaces as -1 / 0) also yields 0, so
/// `expires_unix == 0` uniformly means "session, no Expires attribute".
pub fn decodeCookie(
    allocator: std.mem.Allocator,
    name: []const u8,
    value: []const u8,
    domain: []const u8,
    path: []const u8,
    has_expiry: bool,
    expiry: f64,
    secure: bool,
    http_only: bool,
    same_site_int: i32,
) CookieError!Cookie {
    const name_owned = allocator.dupe(u8, name) catch return error.OutOfMemory;
    errdefer allocator.free(name_owned);
    const value_owned = allocator.dupe(u8, value) catch return error.OutOfMemory;
    errdefer allocator.free(value_owned);
    const domain_owned = allocator.dupe(u8, domain) catch return error.OutOfMemory;
    errdefer allocator.free(domain_owned);
    const path_owned = allocator.dupe(u8, path) catch return error.OutOfMemory;
    errdefer allocator.free(path_owned);

    return .{
        .name = name_owned,
        .value = value_owned,
        .domain = domain_owned,
        .path = path_owned,
        .expires_unix = expiryToUnix(has_expiry, expiry),
        .secure = secure,
        .http_only = http_only,
        .same_site = sameSiteFromInt(same_site_int),
    };
}

/// Epoch-seconds double -> Verve's `expires_unix` (0 = session). Centralised so
/// the set-path and get-path agree on the session sentinel.
pub fn expiryToUnix(has_expiry: bool, expiry: f64) i64 {
    if (!has_expiry) return 0;
    if (expiry > 0) return @intFromFloat(expiry);
    return 0;
}

// ---- tests (run on the host that builds `zig build test`) -------------------

test "sameSite round-trips for every concrete kind" {
    // none / lax / strict have exact native ints and round-trip cleanly.
    try std.testing.expectEqual(SAME_SITE_NONE, sameSiteToInt(.none));
    try std.testing.expectEqual(SAME_SITE_LAX, sameSiteToInt(.lax));
    try std.testing.expectEqual(SAME_SITE_STRICT, sameSiteToInt(.strict));

    try std.testing.expectEqual(SameSite.none, sameSiteFromInt(SAME_SITE_NONE));
    try std.testing.expectEqual(SameSite.lax, sameSiteFromInt(SAME_SITE_LAX));
    try std.testing.expectEqual(SameSite.strict, sameSiteFromInt(SAME_SITE_STRICT));
}

test "sameSite .default coalesces to LAX on the wire" {
    // WebView2 has no "unspecified" kind; legacy mapped default->Lax on set,
    // and a Lax cookie reads back as .lax (never .default).
    try std.testing.expectEqual(SAME_SITE_LAX, sameSiteToInt(.default));
    try std.testing.expectEqual(SameSite.lax, sameSiteFromInt(sameSiteToInt(.default)));
}

test "sameSiteFromInt clamps unknown ints to .default" {
    try std.testing.expectEqual(SameSite.default, sameSiteFromInt(7));
    try std.testing.expectEqual(SameSite.default, sameSiteFromInt(-3));
}

test "decodeCookie dupes all four strings into the allocator" {
    const a = std.testing.allocator;
    const c = try decodeCookie(
        a,
        "sid",
        "abc123",
        "example.com",
        "/app",
        true,
        1_700_000_000.0,
        true,
        true,
        SAME_SITE_STRICT,
    );
    defer {
        a.free(c.name);
        a.free(c.value);
        a.free(c.domain);
        a.free(c.path);
    }

    try std.testing.expectEqualStrings("sid", c.name);
    try std.testing.expectEqualStrings("abc123", c.value);
    try std.testing.expectEqualStrings("example.com", c.domain);
    try std.testing.expectEqualStrings("/app", c.path);
    try std.testing.expectEqual(@as(i64, 1_700_000_000), c.expires_unix);
    try std.testing.expect(c.secure);
    try std.testing.expect(c.http_only);
    try std.testing.expectEqual(SameSite.strict, c.same_site);

    // Owned, not aliased: mutating the source strings would not corrupt the
    // dupes. (Verify by checking the dupes are distinct backing memory.)
    const src_name = "sid";
    try std.testing.expect(c.name.ptr != src_name.ptr);
}

test "decodeCookie has_expiry=0 yields a session cookie" {
    const a = std.testing.allocator;
    const c = try decodeCookie(
        a,
        "tmp",
        "v",
        "",
        "/",
        false,
        9_999_999.0, // ignored because has_expiry=false
        false,
        false,
        SAME_SITE_LAX,
    );
    defer {
        a.free(c.name);
        a.free(c.value);
        a.free(c.domain);
        a.free(c.path);
    }

    try std.testing.expectEqual(@as(i64, 0), c.expires_unix);
    try std.testing.expectEqual(SameSite.lax, c.same_site);
    try std.testing.expect(!c.secure);
    try std.testing.expect(!c.http_only);
}

test "expiryToUnix session sentinels collapse to 0" {
    try std.testing.expectEqual(@as(i64, 0), expiryToUnix(false, 1234.0));
    try std.testing.expectEqual(@as(i64, 0), expiryToUnix(true, 0.0));
    try std.testing.expectEqual(@as(i64, 0), expiryToUnix(true, -1.0));
    try std.testing.expectEqual(@as(i64, 1_650_000_000), expiryToUnix(true, 1_650_000_000.4));
}
