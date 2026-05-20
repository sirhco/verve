//! HTML serializer. Streams Node tree to any Io.Writer.

const std = @import("std");
const Writer = std.Io.Writer;
const node_mod = @import("node.zig");
const Context = @import("context.zig").Context;
const Node = node_mod.Node;

/// Per-render CSP nonce. The server sets this before serialization
/// so the renderer can stamp `nonce="…"` on every emitted `<script>`
/// / `<style>` tag that doesn't already carry one — required when
/// the response's CSP uses `'strict-dynamic'` (the framework default).
///
/// Empty string disables auto-stamping.
pub threadlocal var current_nonce: []const u8 = "";

pub const Renderer = struct {
    pub fn render(w: *Writer, node: *const Node) Writer.Error!void {
        // Outlet placeholder for nested routing — expand into the
        // child route's rendered tree (or emit nothing when no child
        // matched).
        if (std.mem.eql(u8, node.tag, "__outlet__")) {
            if (node.outlet_content) |c| try render(w, c);
            return;
        }
        // Redirect sentinel — never renders to HTML; the server is
        // expected to intercept it before reaching the renderer. Safe
        // fallback: skip silently.
        if (std.mem.eql(u8, node.tag, "__redirect__")) return;

        // Empty tag → fragment. Emit only raw_inner (if set) or children;
        // attrs/bindings/text on a fragment are silently ignored.
        if (node.tag.len == 0) {
            if (node.raw_inner) |inner| {
                try w.writeAll(inner);
                return;
            }
            for (node.children_list.items) |c| try render(w, c);
            return;
        }

        try w.print("<{s}", .{node.tag});

        var has_nonce: bool = false;
        for (node.attrs.items) |a| {
            if (std.mem.eql(u8, a.key, "nonce")) has_nonce = true;
            try w.print(" {s}=\"", .{a.key});
            try escapeAttr(w, a.value);
            try w.writeAll("\"");
        }
        // Auto-stamp the per-request CSP nonce onto script/style tags
        // when the renderer's threadlocal is set and the node doesn't
        // already carry one. Required for CSP `'strict-dynamic'`.
        if (!has_nonce and current_nonce.len > 0 and
            (std.mem.eql(u8, node.tag, "script") or std.mem.eql(u8, node.tag, "style")))
        {
            try w.writeAll(" nonce=\"");
            try escapeAttr(w, current_nonce);
            try w.writeAll("\"");
        }
        if (node.z_bind_name) |bind| {
            try w.writeAll(" z-bind=\"");
            try escapeAttr(w, bind);
            try w.writeAll("\"");
        }
        if (node.z_on_click_action) |action| {
            try w.writeAll(" z-on-click=\"");
            try escapeAttr(w, action);
            try w.writeAll("\"");
        }

        if (node_mod.isVoidTag(node.tag)) {
            try w.writeAll(">");
            return;
        }

        try w.writeAll(">");

        if (node.raw_inner) |inner| {
            try w.writeAll(inner);
        } else {
            if (node.text_content) |t| {
                try escapeHtml(w, t);
            }
            for (node.children_list.items) |c| {
                try render(w, c);
            }
        }

        try w.print("</{s}>", .{node.tag});
    }
};

/// Escape user text appearing inside an element body.
pub fn escapeHtml(w: *Writer, text: []const u8) Writer.Error!void {
    var start: usize = 0;
    for (text, 0..) |c, i| {
        const replacement: ?[]const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            else => null,
        };
        if (replacement) |r| {
            if (i > start) try w.writeAll(text[start..i]);
            try w.writeAll(r);
            start = i + 1;
        }
    }
    if (start < text.len) try w.writeAll(text[start..]);
}

/// Escape text appearing inside a double-quoted attribute value.
pub fn escapeAttr(w: *Writer, text: []const u8) Writer.Error!void {
    var start: usize = 0;
    for (text, 0..) |c, i| {
        const replacement: ?[]const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            else => null,
        };
        if (replacement) |r| {
            if (i > start) try w.writeAll(text[start..i]);
            try w.writeAll(r);
            start = i + 1;
        }
    }
    if (start < text.len) try w.writeAll(text[start..]);
}

test "renders basic element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const node = try ctx.h1("hello").build();
    try Renderer.render(&w, node);
    try std.testing.expectEqualStrings("<h1>hello</h1>", w.buffered());
}

test "renders nested element with attrs and z-bind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const tree = try ctx.div().class("card")
        .children(.{
            ctx.span().bind("count").text("0"),
            ctx.button("+").onClick("increment"),
        })
        .build();
    try Renderer.render(&w, tree);
    try std.testing.expectEqualStrings(
        \\<div class="card"><span z-bind="count">0</span><button z-on-click="increment">+</button></div>
    , w.buffered());
}

test "escapes HTML entities in text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const node = try ctx.p().text("<script>alert(1)</script> & co").build();
    try Renderer.render(&w, node);
    try std.testing.expectEqualStrings(
        "<p>&lt;script&gt;alert(1)&lt;/script&gt; &amp; co</p>",
        w.buffered(),
    );
}

test "escapes quotes in attribute values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const node = try ctx.input().value("a\"b<c").build();
    try Renderer.render(&w, node);
    try std.testing.expectEqualStrings(
        "<input value=\"a&quot;b&lt;c\">",
        w.buffered(),
    );
}

test "void elements omit closing tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    var buf: [128]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const node = try ctx.br().build();
    try Renderer.render(&w, node);
    try std.testing.expectEqualStrings("<br>", w.buffered());
}

test "raw inner HTML bypasses escaping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const node = try ctx.el("script").raw("if (a < b && c > 0) {}").build();
    try Renderer.render(&w, node);
    try std.testing.expectEqualStrings(
        "<script>if (a < b && c > 0) {}</script>",
        w.buffered(),
    );
}

test "ctx.raw fragment emits bytes verbatim with no wrapper tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const xml =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<urlset><url><loc>https://example.com/</loc></url></urlset>
    ;
    const node = try ctx.raw(xml).contentType("application/xml").build();
    try Renderer.render(&w, node);
    try std.testing.expectEqualStrings(xml, w.buffered());
    try std.testing.expectEqualStrings("application/xml", node.content_type_override.?);
}

test "raw_inner takes precedence over text and children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const node = try ctx.div()
        .text("should not appear")
        .children(.{ ctx.span().text("nope") })
        .raw("<i>raw</i>")
        .build();
    try Renderer.render(&w, node);
    try std.testing.expectEqualStrings("<div><i>raw</i></div>", w.buffered());
}
