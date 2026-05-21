//! Demonstrates:
//!   - path-prefix locale via /blog/:lang/p/:slug
//!   - ctx.setTitle, ctx.metaTag (description, og:title), ctx.linkTag (canonical), ctx.jsonLd
//!   - verve.HeadMeta priority field (og:title priority 40 vs description default 30)
//!   - ctx.assetHref for cache-busted preload links
//!   - verve.Slot / verve.SlotMap (named children for post layout)
//!   - verve.redirect (when locale isn't supported)

const std = @import("std");
const verve = @import("verve");
const api = @import("../../api.zig");
const ui = @import("../ui.zig");
const shell = @import("../shell.zig");
const i18n = @import("../i18n.zig");

pub const slots = struct {
    pub const header: verve.Slot = .{ .name = "post_header" };
    pub const body:   verve.Slot = .{ .name = "post_body" };
    pub const aside:  verve.Slot = .{ .name = "post_aside" };
};

pub fn blogPost(ctx: *verve.Context, lang: []const u8, slug: []const u8) !*verve.Node {
    if (!i18n.catalog.isSupported(lang)) {
        return ctx.redirect(
            try std.fmt.allocPrint(ctx.alloc(), "/blog/en/p/{s}", .{slug}),
        );
    }
    const post = api.postBySlug(slug, lang) orelse return ctx.redirect("/blog");

    try ctx.setTitle(try std.fmt.allocPrint(ctx.alloc(), "{s} — Verve Blog", .{post.title}));
    try ctx.metaTag(.{ .name = "description", .content = "Verve framework post." });
    try ctx.metaTag(.{
        .name = "og:title",
        .content = post.title,
        .is_property = true,
        .priority = 40,
    });
    try ctx.metaTag(.{
        .name = "og:type",
        .content = "article",
        .is_property = true,
        .priority = 40,
    });
    try ctx.linkTag(.{
        .rel = "canonical",
        .href = try std.fmt.allocPrint(ctx.alloc(), "https://example.com/blog/{s}/p/{s}", .{ lang, slug }),
    });
    try ctx.linkTag(.{
        .rel = "alternate",
        .href = try std.fmt.allocPrint(ctx.alloc(), "/blog/{s}/p/{s}", .{ "en", slug }),
        .extra = &.{ .{ .key = "hreflang", .value = "en" } },
    });
    try ctx.linkTag(.{
        .rel = "alternate",
        .href = try std.fmt.allocPrint(ctx.alloc(), "/blog/{s}/p/{s}", .{ "es", slug }),
        .extra = &.{ .{ .key = "hreflang", .value = "es" } },
    });
    try ctx.linkTag(.{
        .rel = "alternate",
        .href = try std.fmt.allocPrint(ctx.alloc(), "/blog/{s}/p/{s}", .{ "fr", slug }),
        .extra = &.{ .{ .key = "hreflang", .value = "fr" } },
    });
    try ctx.linkTag(.{
        .rel = "preload",
        .href = try ctx.assetHref("style.css"),
        .extra = &.{ .{ .key = "as", .value = "style" } },
    });
    try ctx.jsonLd(try std.fmt.allocPrint(
        ctx.alloc(),
        "{{\"@context\":\"https://schema.org\",\"@type\":\"BlogPosting\",\"headline\":\"{s}\",\"datePublished\":\"{s}\",\"inLanguage\":\"{s}\"}}",
        .{ post.title, post.published_at, post.locale },
    ));

    const author = api.userById(post.author_id) orelse api.users[0];

    // Build the slot map; the layout below pulls from it. This exercises
    // the named-children API on a real component.
    var sm = verve.SlotMap.init(ctx.alloc());
    try sm.fill(slots.header, postHeader(ctx, post, author));
    try sm.fill(slots.body, postBody(ctx, post));
    try sm.fill(slots.aside, postAside(ctx, post, lang));

    const body = ctx.article().class("post-layout").children(.{
        sm.find(slots.header) orelse ctx.div(),
        ctx.div().class("post-body").children(.{ sm.find(slots.body) orelse ctx.div() }),
        sm.find(slots.aside) orelse ctx.div(),
    });
    return shell.page(ctx, body);
}

fn postHeader(ctx: *const verve.Context, post: api.Post, author: api.User) *verve.Node {
    return ctx.div().class("hero").children(.{
        ui.breadcrumb(ctx, &.{
            .{ .label = "Blog", .href = "/blog" },
            .{ .label = post.title, .href = null },
        }),
        ctx.h1(post.title),
        ctx.div().class("post-meta").children(.{
            ui.avatar(ctx, author.avatar_seed),
            ctx.span().text(author.name),
            ctx.span().class("muted").text(" · "),
            ctx.span().class("muted").text(post.published_at),
            ctx.span().class("muted").text(" · "),
            ui.badge(ctx, .info, post.category_slug),
        }),
    });
}

fn postBody(ctx: *const verve.Context, post: api.Post) *verve.Node {
    // Body is markdown-ish; we render each paragraph separately. A real
    // app would call a parser; the demo splits on double newlines.
    var n = ctx.div();
    var it = std.mem.splitSequence(u8, post.body_md, "\n\n");
    while (it.next()) |para| {
        if (para.len == 0) continue;
        if (std.mem.startsWith(u8, para, "# ")) {
            _ = n.children(.{ ctx.h1(para[2..]) });
        } else if (std.mem.startsWith(u8, para, "## ")) {
            _ = n.children(.{ ctx.h2(para[3..]) });
        } else {
            _ = n.children(.{ ctx.p().text(para) });
        }
    }
    return n;
}

fn postAside(ctx: *const verve.Context, post: api.Post, lang: []const u8) *verve.Node {
    _ = post;
    return ctx.aside().class("card").children(.{
        ctx.h3(i18n.t(lang, "ui.language")),
        ctx.div().class("tag-row").children(.{
            verve.link(ctx, "/blog/en/p/welcome", "EN", .{}),
            verve.link(ctx, "/blog/es/p/welcome", "ES", .{}),
            verve.link(ctx, "/blog/fr/p/welcome", "FR", .{}),
        }),
        ctx.h3(i18n.t(lang, "ui.categories")),
        ctx.div().class("tag-row").children(.{
            verve.link(ctx, "/blog/c/zig",  "Zig",  .{}),
            verve.link(ctx, "/blog/c/wasm", "WASM", .{}),
            verve.link(ctx, "/blog/c/ssr",  "SSR",  .{}),
            verve.link(ctx, "/blog/c/ops",  "Ops",  .{}),
        }),
    });
}
