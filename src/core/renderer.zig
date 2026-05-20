//! HTML serializer. Streams Node tree to any Io.Writer.

const std = @import("std");
const Writer = std.Io.Writer;
const node_mod = @import("node.zig");
const Context = @import("context.zig").Context;
const Node = node_mod.Node;

pub const Renderer = struct {
    pub fn render(w: *Writer, node: *const Node) Writer.Error!void {
        try w.print("<{s}", .{node.tag});

        for (node.attrs.items) |a| {
            try w.print(" {s}=\"", .{a.key});
            try escapeAttr(w, a.value);
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

        if (node.text_content) |t| {
            try escapeHtml(w, t);
        }
        for (node.children_list.items) |c| {
            try render(w, c);
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
