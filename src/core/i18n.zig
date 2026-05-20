//! Locale resolution + translation key lookup. The framework owns the
//! resolution chain (cookie > query > Accept-Language > default) and
//! provides a tiny lookup helper; the actual translation table is
//! caller-supplied so apps can ship whatever data shape they like
//! (build-time JSON, runtime DB, etc.).
//!
//! Apps that want comptime-baked translations should set up a
//! `--i18n-dir` walker in `build.zig` that compiles each locale's
//! key/value JSON into a `pub const messages: []const Entry`. The
//! lookup here is a linear scan — fine for hundreds of keys, time to
//! upgrade to a hashmap when an app crosses a few thousand.

const std = @import("std");
const RequestMeta = @import("request_meta.zig").RequestMeta;
const Location = @import("location.zig").Location;

pub const COOKIE_NAME = "lang";
pub const QUERY_NAME = "lang";

pub const Entry = struct {
    locale: []const u8,
    key: []const u8,
    value: []const u8,
};

pub const Catalog = struct {
    entries: []const Entry,
    default_locale: []const u8,
    supported: []const []const u8,

    /// Look up `key` in `locale`, falling back to the default locale,
    /// then to the key itself. Linear scan — sufficient for small
    /// catalogs; replace with a hashmap if it ever shows up in a
    /// profile.
    pub fn lookup(self: Catalog, locale: []const u8, key: []const u8) []const u8 {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.locale, locale) and std.mem.eql(u8, e.key, key)) {
                return e.value;
            }
        }
        if (!std.mem.eql(u8, locale, self.default_locale)) {
            for (self.entries) |e| {
                if (std.mem.eql(u8, e.locale, self.default_locale) and std.mem.eql(u8, e.key, key)) {
                    return e.value;
                }
            }
        }
        return key;
    }

    /// True when `locale` is in the catalog's supported list.
    pub fn isSupported(self: Catalog, locale: []const u8) bool {
        for (self.supported) |s| {
            if (std.mem.eql(u8, s, locale)) return true;
        }
        return false;
    }
};

/// Resolve the active locale for the current request. Walks:
///   1. cookie `lang=`
///   2. query `?lang=`
///   3. first parseable `Accept-Language` candidate that we support
///   4. catalog default
pub fn resolveLocale(catalog: Catalog, meta: ?*const RequestMeta, location: ?*Location, arena: std.mem.Allocator) ![]const u8 {
    if (meta) |m| {
        if (m.cookie(COOKIE_NAME)) |c| if (catalog.isSupported(c)) return c;
    }
    if (location) |loc| {
        if (try loc.queryGet(arena, QUERY_NAME)) |q| if (catalog.isSupported(q)) return q;
    }
    if (meta) |m| if (m.accept_language) |al| {
        var it = std.mem.tokenizeScalar(u8, al, ',');
        while (it.next()) |raw| {
            const tag = parseLangTag(raw);
            if (catalog.isSupported(tag)) return tag;
            // Try the language-only prefix (e.g. "en-GB" → "en").
            const prefix = languagePrefix(tag);
            if (catalog.isSupported(prefix)) return prefix;
        }
    };
    return catalog.default_locale;
}

fn parseLangTag(raw: []const u8) []const u8 {
    var tag = std.mem.trim(u8, raw, " \t");
    if (std.mem.indexOfScalar(u8, tag, ';')) |p| tag = tag[0..p];
    return tag;
}

fn languagePrefix(tag: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, tag, '-')) |p| return tag[0..p];
    return tag;
}

// ---- tests ------------------------------------------------------------

const testing = std.testing;

test "Catalog.lookup falls back to default then key" {
    const catalog: Catalog = .{
        .entries = &.{
            .{ .locale = "en", .key = "hello", .value = "Hello" },
            .{ .locale = "es", .key = "hello", .value = "Hola" },
            .{ .locale = "en", .key = "bye", .value = "Goodbye" },
        },
        .default_locale = "en",
        .supported = &.{ "en", "es" },
    };

    try testing.expectEqualStrings("Hola", catalog.lookup("es", "hello"));
    try testing.expectEqualStrings("Hello", catalog.lookup("en", "hello"));
    // missing-in-locale → falls back to default
    try testing.expectEqualStrings("Goodbye", catalog.lookup("es", "bye"));
    // missing-everywhere → returns the key itself
    try testing.expectEqualStrings("missing.key", catalog.lookup("en", "missing.key"));
}

test "resolveLocale prefers cookie over query over header" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const catalog: Catalog = .{
        .entries = &.{},
        .default_locale = "en",
        .supported = &.{ "en", "es", "fr" },
    };

    var loc = Location.parse("/x?lang=fr");

    // Cookie wins.
    const meta_cookie: RequestMeta = .{ .cookie_header = "lang=es" };
    try testing.expectEqualStrings("es", try resolveLocale(catalog, &meta_cookie, &loc, arena.allocator()));

    // No cookie → query wins.
    const meta_no_cookie: RequestMeta = .{};
    try testing.expectEqualStrings("fr", try resolveLocale(catalog, &meta_no_cookie, &loc, arena.allocator()));

    // No cookie, no query, header → header parses.
    var loc_no_query = Location.parse("/x");
    const meta_header: RequestMeta = .{ .accept_language = "fr-CA,fr;q=0.9,en;q=0.5" };
    try testing.expectEqualStrings("fr", try resolveLocale(catalog, &meta_header, &loc_no_query, arena.allocator()));

    // Nothing → default.
    const meta_empty: RequestMeta = .{};
    try testing.expectEqualStrings("en", try resolveLocale(catalog, &meta_empty, &loc_no_query, arena.allocator()));
}

test "resolveLocale language-prefix fallback" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const catalog: Catalog = .{
        .entries = &.{},
        .default_locale = "en",
        .supported = &.{ "en", "fr" },
    };

    var loc = Location.parse("/x");
    const meta: RequestMeta = .{ .accept_language = "fr-CA,en;q=0.5" };
    // fr-CA not supported, but the "fr" prefix is — should match.
    try testing.expectEqualStrings("fr", try resolveLocale(catalog, &meta, &loc, arena.allocator()));
}
