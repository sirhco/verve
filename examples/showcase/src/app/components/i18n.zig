//! Demonstrates:
//!   - verve.I18nCatalog, verve.I18nEntry, verve.resolveLocale

const std = @import("std");
const verve = @import("verve");

pub const catalog: verve.I18nCatalog = .{
    .entries = &.{
        .{ .locale = "en", .key = "ui.home",      .value = "Home" },
        .{ .locale = "en", .key = "ui.blog",      .value = "Blog" },
        .{ .locale = "en", .key = "ui.tracker",   .value = "Tracker" },
        .{ .locale = "en", .key = "ui.admin",     .value = "Admin" },
        .{ .locale = "en", .key = "ui.posts",     .value = "Posts" },
        .{ .locale = "en", .key = "ui.categories",.value = "Categories" },
        .{ .locale = "en", .key = "ui.read_more", .value = "Read more" },
        .{ .locale = "en", .key = "ui.no_posts",  .value = "No posts here yet." },
        .{ .locale = "en", .key = "ui.published", .value = "Published" },
        .{ .locale = "en", .key = "ui.language",  .value = "Language" },

        .{ .locale = "es", .key = "ui.home",      .value = "Inicio" },
        .{ .locale = "es", .key = "ui.blog",      .value = "Blog" },
        .{ .locale = "es", .key = "ui.tracker",   .value = "Tracker" },
        .{ .locale = "es", .key = "ui.admin",     .value = "Admin" },
        .{ .locale = "es", .key = "ui.posts",     .value = "Publicaciones" },
        .{ .locale = "es", .key = "ui.categories",.value = "Categorías" },
        .{ .locale = "es", .key = "ui.read_more", .value = "Leer más" },
        .{ .locale = "es", .key = "ui.no_posts",  .value = "Aún no hay publicaciones." },
        .{ .locale = "es", .key = "ui.published", .value = "Publicado" },
        .{ .locale = "es", .key = "ui.language",  .value = "Idioma" },

        .{ .locale = "fr", .key = "ui.home",      .value = "Accueil" },
        .{ .locale = "fr", .key = "ui.blog",      .value = "Blog" },
        .{ .locale = "fr", .key = "ui.tracker",   .value = "Tracker" },
        .{ .locale = "fr", .key = "ui.admin",     .value = "Admin" },
        .{ .locale = "fr", .key = "ui.posts",     .value = "Articles" },
        .{ .locale = "fr", .key = "ui.categories",.value = "Catégories" },
        .{ .locale = "fr", .key = "ui.read_more", .value = "Lire plus" },
        .{ .locale = "fr", .key = "ui.no_posts",  .value = "Aucun article pour l'instant." },
        .{ .locale = "fr", .key = "ui.published", .value = "Publié" },
        .{ .locale = "fr", .key = "ui.language",  .value = "Langue" },
    },
    .default_locale = "en",
    .supported = &.{ "en", "es", "fr" },
};

pub fn resolve(ctx: *const verve.Context) ![]const u8 {
    return verve.resolveLocale(catalog, ctx.request_meta, ctx.location, ctx.alloc());
}

pub fn t(locale: []const u8, key: []const u8) []const u8 {
    return catalog.lookup(locale, key);
}
