//! Per-request `<head>` accumulator. Components anywhere in the tree
//! push `<title>`, `<meta>`, `<link>`, JSON-LD blocks, and raw HTML
//! into `ctx.head`; the shell drains the collected entries into
//! `<head>` before the body renders, sorted by an explicit priority so
//! canonical / OG / JSON-LD always land in a stable order.
//!
//! Replace-not-append: a `metaTag` whose `name` or `property` matches
//! an existing entry overwrites it. Lets a child override what a layout
//! set without the layout having to make every value optional.

const std = @import("std");

pub const PRIORITY_CHARSET: u8 = 5;
pub const PRIORITY_TITLE: u8 = 10;
pub const PRIORITY_CANONICAL: u8 = 15;
pub const PRIORITY_META_BASIC: u8 = 30;
pub const PRIORITY_OG: u8 = 40;
pub const PRIORITY_TWITTER: u8 = 45;
pub const PRIORITY_LINK: u8 = 50;
pub const PRIORITY_SCRIPT: u8 = 70;
pub const PRIORITY_JSON_LD: u8 = 80;
pub const PRIORITY_RAW: u8 = 90;

pub const Meta = struct {
    /// `name` or `property`. Renderer chooses the attribute name based
    /// on whether `is_property` is set (OG / Twitter use `property=`).
    name: []const u8,
    content: []const u8,
    is_property: bool = false,
    priority: u8 = PRIORITY_META_BASIC,
};

pub const Link = struct {
    rel: []const u8,
    href: []const u8,
    extra: []const Attr = &.{},
    priority: u8 = PRIORITY_LINK,
};

pub const Script = struct {
    src: ?[]const u8 = null,
    inline_body: ?[]const u8 = null,
    type_attr: ?[]const u8 = null,
    defer_attr: bool = false,
    async_attr: bool = false,
    priority: u8 = PRIORITY_SCRIPT,
};

pub const RawEntry = struct {
    html: []const u8,
    priority: u8 = PRIORITY_RAW,
};

pub const Attr = struct { key: []const u8, value: []const u8 };

pub const Head = struct {
    /// Replace-not-append: last writer wins.
    title: ?[]const u8 = null,
    metas: std.ArrayListUnmanaged(Meta) = .empty,
    links: std.ArrayListUnmanaged(Link) = .empty,
    scripts: std.ArrayListUnmanaged(Script) = .empty,
    json_ld: std.ArrayListUnmanaged(RawEntry) = .empty,
    raw: std.ArrayListUnmanaged(RawEntry) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Head {
        return .{ .allocator = allocator };
    }

    /// Set the document title. Last writer wins, so a layout can supply
    /// a default and any page can override.
    pub fn setTitle(self: *Head, t: []const u8) void {
        self.title = t;
    }

    /// Set the title only when no prior `setTitle` has been called.
    /// Useful for the shell layer: lets a page-level component own the
    /// title even when the layout runs last.
    pub fn setTitleIfUnset(self: *Head, t: []const u8) void {
        if (self.title == null) self.title = t;
    }

    /// Add or replace a `<meta name|property=... content=...>` entry.
    /// Matching is by (name, is_property) — useful for OG tags that
    /// share keys with classic meta tags.
    pub fn meta(self: *Head, m: Meta) !void {
        for (self.metas.items) |*existing| {
            if (std.mem.eql(u8, existing.name, m.name) and existing.is_property == m.is_property) {
                existing.* = m;
                return;
            }
        }
        try self.metas.append(self.allocator, m);
    }

    pub fn link(self: *Head, l: Link) !void {
        try self.links.append(self.allocator, l);
    }

    pub fn script(self: *Head, s: Script) !void {
        try self.scripts.append(self.allocator, s);
    }

    /// Append a JSON-LD `<script type=application/ld+json>` block. Body
    /// is emitted verbatim — caller is responsible for ensuring the
    /// JSON is well-formed.
    pub fn jsonLd(self: *Head, json: []const u8) !void {
        try self.json_ld.append(self.allocator, .{ .html = json });
    }

    /// Escape hatch — drops arbitrary HTML into `<head>` at the given
    /// priority. Use sparingly; the helper-typed APIs above cover the
    /// common cases and stay safe under replace-not-append.
    pub fn rawHtml(self: *Head, html: []const u8, priority: u8) !void {
        try self.raw.append(self.allocator, .{ .html = html, .priority = priority });
    }

    /// Render the accumulated head into `writer` in priority order.
    /// Lower priority numbers come first.
    pub fn render(self: *Head, writer: *std.Io.Writer) !void {
        // Collect everything into a flat priority list, then sort.
        var entries: std.ArrayListUnmanaged(Entry) = .empty;
        defer entries.deinit(self.allocator);

        // Charset always first.
        try entries.append(self.allocator, .{ .priority = PRIORITY_CHARSET, .kind = .charset });

        if (self.title) |t| try entries.append(self.allocator, .{ .priority = PRIORITY_TITLE, .kind = .{ .title = t } });
        for (self.metas.items) |m| try entries.append(self.allocator, .{ .priority = m.priority, .kind = .{ .meta = m } });
        for (self.links.items) |l| try entries.append(self.allocator, .{ .priority = l.priority, .kind = .{ .link = l } });
        for (self.scripts.items) |s| try entries.append(self.allocator, .{ .priority = s.priority, .kind = .{ .script = s } });
        for (self.json_ld.items) |j| try entries.append(self.allocator, .{ .priority = j.priority, .kind = .{ .json_ld = j.html } });
        for (self.raw.items) |r| try entries.append(self.allocator, .{ .priority = r.priority, .kind = .{ .raw = r.html } });

        std.sort.block(Entry, entries.items, {}, Entry.less);

        for (entries.items) |e| try writeEntry(writer, e);
    }
};

const Entry = struct {
    priority: u8,
    kind: union(enum) {
        charset,
        title: []const u8,
        meta: Meta,
        link: Link,
        script: Script,
        json_ld: []const u8,
        raw: []const u8,
    },

    fn less(_: void, a: Entry, b: Entry) bool {
        return a.priority < b.priority;
    }
};

fn writeEntry(w: *std.Io.Writer, e: Entry) !void {
    switch (e.kind) {
        .charset => try w.writeAll("<meta charset=\"utf-8\">"),
        .title => |t| {
            try w.writeAll("<title>");
            try escapeText(w, t);
            try w.writeAll("</title>");
        },
        .meta => |m| {
            const key = if (m.is_property) "property" else "name";
            try w.writeAll("<meta ");
            try w.writeAll(key);
            try w.writeAll("=\"");
            try escapeAttr(w, m.name);
            try w.writeAll("\" content=\"");
            try escapeAttr(w, m.content);
            try w.writeAll("\">");
        },
        .link => |l| {
            try w.writeAll("<link rel=\"");
            try escapeAttr(w, l.rel);
            try w.writeAll("\" href=\"");
            try escapeAttr(w, l.href);
            try w.writeAll("\"");
            for (l.extra) |a| {
                try w.writeAll(" ");
                try w.writeAll(a.key);
                try w.writeAll("=\"");
                try escapeAttr(w, a.value);
                try w.writeAll("\"");
            }
            try w.writeAll(">");
        },
        .script => |s| {
            try w.writeAll("<script");
            if (s.type_attr) |t| {
                try w.writeAll(" type=\"");
                try escapeAttr(w, t);
                try w.writeAll("\"");
            }
            if (s.src) |src| {
                try w.writeAll(" src=\"");
                try escapeAttr(w, src);
                try w.writeAll("\"");
            }
            if (s.defer_attr) try w.writeAll(" defer");
            if (s.async_attr) try w.writeAll(" async");
            try w.writeAll(">");
            if (s.inline_body) |body| try w.writeAll(body);
            try w.writeAll("</script>");
        },
        .json_ld => |body| {
            try w.writeAll("<script type=\"application/ld+json\">");
            try w.writeAll(body);
            try w.writeAll("</script>");
        },
        .raw => |html| try w.writeAll(html),
    }
}

fn escapeText(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        else => try w.writeByte(c),
    };
}

fn escapeAttr(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(c),
    };
}

// ---- tests ------------------------------------------------------------

const testing = std.testing;

test "Head renders charset + title + meta in priority order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var head = Head.init(arena.allocator());
    head.setTitle("Verve");
    try head.meta(.{ .name = "description", .content = "A Zig web framework." });
    try head.meta(.{ .name = "og:title", .content = "Verve OG", .is_property = true, .priority = PRIORITY_OG });

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try head.render(&w);

    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "<meta charset=\"utf-8\">") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<title>Verve</title>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "name=\"description\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "property=\"og:title\"") != null);

    // Charset comes before title, title before meta.
    const charset_pos = std.mem.indexOf(u8, out, "<meta charset").?;
    const title_pos = std.mem.indexOf(u8, out, "<title>").?;
    const desc_pos = std.mem.indexOf(u8, out, "name=\"description\"").?;
    try testing.expect(charset_pos < title_pos);
    try testing.expect(title_pos < desc_pos);
}

test "Head.meta replaces matching entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var head = Head.init(arena.allocator());
    try head.meta(.{ .name = "description", .content = "first" });
    try head.meta(.{ .name = "description", .content = "second" });

    try testing.expectEqual(@as(usize, 1), head.metas.items.len);
    try testing.expectEqualStrings("second", head.metas.items[0].content);
}

test "Head.jsonLd appends script with correct type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var head = Head.init(arena.allocator());
    try head.jsonLd("{\"@context\":\"https://schema.org\"}");

    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try head.render(&w);

    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "<script type=\"application/ld+json\">") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"@context\":\"https://schema.org\"") != null);
}

test "Head escapes title text but emits json-ld verbatim" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var head = Head.init(arena.allocator());
    head.setTitle("Hello & <World>");
    try head.jsonLd("{\"q\":\"<not escaped>\"}");

    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try head.render(&w);

    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "<title>Hello &amp; &lt;World&gt;</title>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"q\":\"<not escaped>\"") != null);
}
