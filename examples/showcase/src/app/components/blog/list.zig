//! Demonstrates:
//!   - verve.forEach with keyed list (data-vkey for client reconciler)
//!   - verve.show (conditional empty state)
//!   - verve.link with prefetch_on_hover
//!   - ctx.location, isActive (active category highlight)
//!   - ctx.head + canonical link

const std = @import("std");
const verve = @import("verve");
const api = @import("../../api.zig");
const ui = @import("../ui.zig");
const shell = @import("../shell.zig");
const i18n = @import("../i18n.zig");

pub fn blogIndex(ctx: *verve.Context) !*verve.Node {
    try ctx.setTitle("Blog — Verve Showcase");
    try ctx.metaTag(.{ .name = "description", .content = "Posts about Zig, WASM, SSR, and Ops." });
    try ctx.linkTag(.{ .rel = "canonical", .href = "https://example.com/blog" });

    const locale = try i18n.resolve(ctx);
    const items = try api.postsByLocale(ctx.alloc(), locale);

    const body = ctx.div().children(.{
        heroBanner(ctx, locale),
        categoryNav(ctx, null),
        postList(ctx, items, locale),
    });
    return shell.page(ctx, body);
}

pub fn blogCategory(ctx: *verve.Context, slug: []const u8) !*verve.Node {
    const cat_opt: ?api.Category = blk: {
        for (api.categories) |c| if (std.mem.eql(u8, c.slug, slug)) break :blk c;
        break :blk null;
    };
    if (cat_opt == null) return ctx.redirect("/blog");
    const cat = cat_opt.?;

    try ctx.setTitle(try std.fmt.allocPrint(ctx.alloc(), "{s} — Verve Blog", .{cat.name}));
    try ctx.metaTag(.{ .name = "description", .content = cat.description });

    const locale = try i18n.resolve(ctx);
    const items = try api.postsInCategory(ctx.alloc(), slug, locale);

    const body = ctx.div().children(.{
        ctx.div().class("hero").children(.{
            ctx.h1(cat.name),
            ctx.p().class("lead").text(cat.description),
        }),
        categoryNav(ctx, slug),
        postList(ctx, items, locale),
    });
    return shell.page(ctx, body);
}

fn heroBanner(ctx: *const verve.Context, locale: []const u8) *verve.Node {
    _ = locale;
    return ctx.div().class("hero").children(.{
        ctx.h1("The Verve blog"),
        ctx.p().class("lead").text("Notes from building a full-stack Zig framework. Each post is a real Verve route — view source to see the head slots in action."),
    });
}

fn categoryNav(ctx: *const verve.Context, active_slug: ?[]const u8) *verve.Node {
    var nav = ctx.nav().class("tag-row");
    _ = nav.children(.{ allPill(ctx, active_slug == null) });
    for (api.categories) |c| {
        const active = active_slug != null and std.mem.eql(u8, active_slug.?, c.slug);
        _ = nav.children(.{ catPill(ctx, c, active) });
    }
    return nav;
}

fn allPill(ctx: *const verve.Context, active: bool) *verve.Node {
    var n = verve.link(ctx, "/blog", "All", .{ .prefetch_on_hover = true });
    if (active) _ = n.attr("aria-current", "page");
    _ = n.class("badge muted");
    return n;
}

fn catPill(ctx: *const verve.Context, c: api.Category, active: bool) *verve.Node {
    const href = std.fmt.allocPrint(ctx.alloc(), "/blog/c/{s}", .{c.slug}) catch "/blog";
    var n = verve.link(ctx, href, c.name, .{ .prefetch_on_hover = true });
    _ = n.class(if (active) "badge info" else "badge muted");
    return n;
}

fn postList(ctx: *const verve.Context, items: []const api.Post, locale: []const u8) *verve.Node {
    if (items.len == 0) {
        return ctx.div().class("empty").text(i18n.t(locale, "ui.no_posts"));
    }
    var grid = ctx.div().class("grid grid-2");
    for (items) |p| {
        _ = grid.children(.{ postCard(ctx, p, locale) });
    }
    return grid;
}

fn postCard(ctx: *const verve.Context, p: api.Post, locale: []const u8) *verve.Node {
    const href = std.fmt.allocPrint(ctx.alloc(), "/blog/{s}/p/{s}", .{ locale, p.slug }) catch "/blog";
    const author = api.userById(p.author_id) orelse api.users[0];

    // Truncate body to a snippet (~140 chars).
    var snippet: []const u8 = p.body_md;
    if (snippet.len > 140) snippet = snippet[0..140];

    return ctx.section().class("card hoverable")
        .attr("data-vkey", p.slug)
        .children(.{
            ctx.div().class("row").children(.{
                ui.badge(ctx, .info, p.category_slug),
                ctx.span().class("muted").text(p.published_at),
            }),
            ctx.h2(p.title),
            ctx.p().class("muted").text(snippet),
            ctx.div().class("row").children(.{
                ui.avatar(ctx, author.avatar_seed),
                ctx.span().text(author.name),
                ctx.span().class("muted").text(" · "),
                verve.link(
                    ctx,
                    href,
                    std.fmt.allocPrint(ctx.alloc(), "{s} →", .{i18n.t(locale, "ui.read_more")}) catch "Read more",
                    .{},
                ),
            }),
        });
}
