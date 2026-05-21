//! Demonstrates:
//!   - ctx.raw (fragment node, no wrapping tag)
//!   - .contentType("application/xml") on the root Node
//!   - RSS + sitemap emitted from the SAME server (single binary)

const std = @import("std");
const verve = @import("verve");
const api = @import("../../api.zig");

pub fn rss(ctx: *verve.Context) !*verve.Node {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = ctx.alloc();

    try buf.appendSlice(w,
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<rss version="2.0"><channel>
        \\<title>Verve Blog</title>
        \\<link>https://example.com/blog</link>
        \\<description>Notes from building a full-stack Zig framework.</description>
        \\
    );

    for (api.posts) |p| {
        if (!std.mem.eql(u8, p.locale, "en")) continue;
        const line = try std.fmt.allocPrint(w,
            \\<item><title>{s}</title><link>https://example.com/blog/en/p/{s}</link><guid>https://example.com/blog/en/p/{s}</guid><pubDate>{s}</pubDate></item>
            \\
        , .{ p.title, p.slug, p.slug, p.published_at });
        try buf.appendSlice(w, line);
    }

    try buf.appendSlice(w, "</channel></rss>\n");
    return ctx.raw(buf.items).contentType("application/xml").build();
}

pub fn sitemap(ctx: *verve.Context) !*verve.Node {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = ctx.alloc();

    try buf.appendSlice(w,
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        \\<url><loc>https://example.com/</loc><priority>1.0</priority></url>
        \\<url><loc>https://example.com/blog</loc><priority>0.8</priority></url>
        \\<url><loc>https://example.com/app</loc><priority>0.7</priority></url>
        \\
    );

    for (api.posts) |p| {
        const line = try std.fmt.allocPrint(w,
            \\<url><loc>https://example.com/blog/{s}/p/{s}</loc><lastmod>{s}</lastmod><priority>0.6</priority></url>
            \\
        , .{ p.locale, p.slug, p.published_at });
        try buf.appendSlice(w, line);
    }

    for (api.categories) |c| {
        const line = try std.fmt.allocPrint(w,
            \\<url><loc>https://example.com/blog/c/{s}</loc><priority>0.5</priority></url>
            \\
        , .{c.slug});
        try buf.appendSlice(w, line);
    }

    try buf.appendSlice(w, "</urlset>\n");
    return ctx.raw(buf.items).contentType("application/xml").build();
}
