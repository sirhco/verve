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

// ---- RTL helpers -------------------------------------------------------

fn langOf(locale: []const u8) []const u8 {
    var end: usize = 0;
    while (end < locale.len and locale[end] != '-' and locale[end] != '_') : (end += 1) {}
    return locale[0..end];
}

const rtl_langs = [_][]const u8{ "ar", "he", "fa", "ur", "ps", "sd", "ug", "yi", "dv", "ckb" };

pub fn isRtl(locale: []const u8) bool {
    const lang = langOf(locale);
    for (rtl_langs) |r| if (std.ascii.eqlIgnoreCase(lang, r)) return true;
    return false;
}

pub fn dir(locale: []const u8) []const u8 {
    return if (isRtl(locale)) "rtl" else "ltr";
}

// ---- Plural rules -------------------------------------------------------

pub const PluralCategory = enum { zero, one, two, few, many, other };

const PluralFamily = enum { other_only, english, french, east_slavic, polish, czech, arabic };

fn pluralFamily(lang: []const u8) PluralFamily {
    const eq = struct {
        fn f(a: []const u8, b: []const u8) bool {
            return std.ascii.eqlIgnoreCase(a, b);
        }
    }.f;
    const other_only = [_][]const u8{ "ja", "zh", "ko", "th", "vi", "id", "ms", "lo", "my", "km" };
    for (other_only) |l| if (eq(lang, l)) return .other_only;
    if (eq(lang, "fr")) return .french;
    if (eq(lang, "ru") or eq(lang, "uk")) return .east_slavic;
    if (eq(lang, "pl")) return .polish;
    if (eq(lang, "cs") or eq(lang, "sk")) return .czech;
    if (eq(lang, "ar")) return .arabic;
    return .english;
}

pub fn pluralCategory(locale: []const u8, n: u64) PluralCategory {
    const lang = langOf(locale);
    return switch (pluralFamily(lang)) {
        .other_only => .other,
        .english => if (n == 1) .one else .other,
        .french => if (n == 0 or n == 1) .one else .other,
        .east_slavic => blk: {
            const m10 = n % 10;
            const m100 = n % 100;
            if (m10 == 1 and m100 != 11) break :blk .one;
            if (m10 >= 2 and m10 <= 4 and !(m100 >= 12 and m100 <= 14)) break :blk .few;
            break :blk .many;
        },
        .polish => blk: {
            const m10 = n % 10;
            const m100 = n % 100;
            if (n == 1) break :blk .one;
            if (m10 >= 2 and m10 <= 4 and !(m100 >= 12 and m100 <= 14)) break :blk .few;
            break :blk .many;
        },
        .czech => blk: {
            if (n == 1) break :blk .one;
            if (n >= 2 and n <= 4) break :blk .few;
            break :blk .other;
        },
        .arabic => blk: {
            const m100 = n % 100;
            if (n == 0) break :blk .zero;
            if (n == 1) break :blk .one;
            if (n == 2) break :blk .two;
            if (m100 >= 3 and m100 <= 10) break :blk .few;
            if (m100 >= 11 and m100 <= 99) break :blk .many;
            break :blk .other;
        },
    };
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

test "pluralCategory CLDR cardinal rules per family" {
    try testing.expectEqual(PluralCategory.other, pluralCategory("en", 0));
    try testing.expectEqual(PluralCategory.one, pluralCategory("en", 1));
    try testing.expectEqual(PluralCategory.other, pluralCategory("en", 2));
    try testing.expectEqual(PluralCategory.one, pluralCategory("de", 1));
    try testing.expectEqual(PluralCategory.one, pluralCategory("fr", 0));
    try testing.expectEqual(PluralCategory.one, pluralCategory("fr", 1));
    try testing.expectEqual(PluralCategory.other, pluralCategory("fr", 2));
    try testing.expectEqual(PluralCategory.one, pluralCategory("ru", 1));
    try testing.expectEqual(PluralCategory.few, pluralCategory("ru", 2));
    try testing.expectEqual(PluralCategory.many, pluralCategory("ru", 5));
    try testing.expectEqual(PluralCategory.many, pluralCategory("ru", 11));
    try testing.expectEqual(PluralCategory.one, pluralCategory("ru", 21));
    try testing.expectEqual(PluralCategory.few, pluralCategory("ru", 22));
    try testing.expectEqual(PluralCategory.many, pluralCategory("ru-RU", 25));
    try testing.expectEqual(PluralCategory.one, pluralCategory("pl", 1));
    try testing.expectEqual(PluralCategory.few, pluralCategory("pl", 2));
    try testing.expectEqual(PluralCategory.many, pluralCategory("pl", 5));
    try testing.expectEqual(PluralCategory.few, pluralCategory("pl", 22));
    try testing.expectEqual(PluralCategory.many, pluralCategory("pl", 25));
    try testing.expectEqual(PluralCategory.one, pluralCategory("cs", 1));
    try testing.expectEqual(PluralCategory.few, pluralCategory("cs", 3));
    try testing.expectEqual(PluralCategory.other, pluralCategory("cs", 5));
    try testing.expectEqual(PluralCategory.zero, pluralCategory("ar", 0));
    try testing.expectEqual(PluralCategory.one, pluralCategory("ar", 1));
    try testing.expectEqual(PluralCategory.two, pluralCategory("ar", 2));
    try testing.expectEqual(PluralCategory.few, pluralCategory("ar", 3));
    try testing.expectEqual(PluralCategory.many, pluralCategory("ar", 11));
    try testing.expectEqual(PluralCategory.other, pluralCategory("ar", 100));
    try testing.expectEqual(PluralCategory.other, pluralCategory("ja", 1));
    try testing.expectEqual(PluralCategory.other, pluralCategory("zh", 5));
    try testing.expectEqual(PluralCategory.one, pluralCategory("xx", 1));
    try testing.expectEqual(PluralCategory.other, pluralCategory("xx", 2));
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

test "isRtl + dir by language prefix" {
    try testing.expect(isRtl("ar"));
    try testing.expect(isRtl("ar-EG"));
    try testing.expect(isRtl("fa_IR"));
    try testing.expect(isRtl("he"));
    try testing.expect(isRtl("ckb"));
    try testing.expect(isRtl("UR"));
    try testing.expect(!isRtl("en"));
    try testing.expect(!isRtl("es-MX"));
    try testing.expect(!isRtl(""));
    try testing.expectEqualStrings("rtl", dir("ar"));
    try testing.expectEqualStrings("ltr", dir("en"));
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
