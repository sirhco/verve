//! Integration test: the build-generated `i18n_catalog` module (from the
//! `i18n/` fixture) loads into a `LazyCatalog` and resolves keys end-to-end.

const std = @import("std");
const verve = @import("verve");
const catalog = @import("i18n_catalog");

test "generated i18n_catalog drives a LazyCatalog" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var cat = verve.I18nLazyCatalog.init(catalog.locales, catalog.default_locale, arena.allocator());

    // Fixture: i18n/en.json has greeting+farewell; i18n/fr.json has greeting.
    try std.testing.expect(cat.isSupported("en"));
    try std.testing.expect(cat.isSupported("fr"));
    try std.testing.expectEqualStrings("Bonjour", cat.lookup("fr", "greeting"));
    // farewell missing in fr → default (en) fallback.
    try std.testing.expectEqualStrings("Goodbye", cat.lookup("fr", "farewell"));
}
