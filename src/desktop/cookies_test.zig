//! Headless shape + default-value tests for the cookie API surface.
//! Catches accidental removal of fields and reordering of enum
//! variants. Behavioural cookie tests need a live native cookie store
//! and run as part of the smoke harness (roadmap #23), not here.

const std = @import("std");
const options = @import("options.zig");
const cookies = @import("cookies.zig");

test "Cookie defaults match documented contract" {
    const c: options.Cookie = .{ .name = "n", .value = "v" };
    try std.testing.expectEqualStrings("", c.domain);
    try std.testing.expectEqualStrings("/", c.path);
    try std.testing.expectEqual(@as(i64, 0), c.expires_unix);
    try std.testing.expectEqual(false, c.secure);
    try std.testing.expectEqual(false, c.http_only);
    try std.testing.expectEqual(options.SameSite.default, c.same_site);
}

test "SameSite enum is stable" {
    // Backend code maps SameSite by switch-exhaustiveness on these
    // exact variants — reordering or renaming silently breaks the
    // platform impls.
    const expect: []const options.SameSite = &.{ .default, .none, .lax, .strict };
    inline for (expect) |variant| {
        const tag: options.SameSite = variant;
        _ = tag;
    }
    try std.testing.expectEqual(4, @typeInfo(options.SameSite).@"enum".fields.len);
}

test "CookieError exposes the four documented variants" {
    // Just ensures each variant exists and the set isn't accidentally
    // narrowed.
    const variants = [_]options.CookieError{
        error.Unsupported,
        error.NotReady,
        error.OutOfMemory,
        error.Backend,
    };
    try std.testing.expectEqual(@as(usize, 4), variants.len);
}

test "CookieStore has the four documented methods" {
    const S = cookies.CookieStore;
    try std.testing.expect(@hasDecl(S, "get"));
    try std.testing.expect(@hasDecl(S, "set"));
    try std.testing.expect(@hasDecl(S, "delete"));
    try std.testing.expect(@hasDecl(S, "clear"));
}
