//! HTML serializer. Streams Node tree to any Io.Writer.

const std = @import("std");
const Writer = std.Io.Writer;
const node_mod = @import("node.zig");
const Node = node_mod.Node;

pub const Renderer = struct {
    pub fn render(w: *Writer, node: Node) Writer.Error!void {
        try w.print("<{s}", .{node.tag});

        for (node.attrs) |attr| {
            try w.print(" {s}=\"", .{attr.key});
            try escapeAttr(w, attr.value);
            try w.writeAll("\"");
        }
        if (node.z_bind) |bind| {
            try w.print(" z-bind=\"", .{});
            try escapeAttr(w, bind);
            try w.writeAll("\"");
        }
        if (node.z_on_click) |action| {
            try w.print(" z-on-click=\"", .{});
            try escapeAttr(w, action);
            try w.writeAll("\"");
        }

        if (node_mod.isVoidTag(node.tag)) {
            try w.writeAll(">");
            return;
        }

        try w.writeAll(">");

        if (node.text) |t| {
            try escapeHtml(w, t);
        }
        for (node.children) |child| {
            try render(w, child);
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
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try Renderer.render(&w, .{ .tag = "h1", .text = "hello" });
    try std.testing.expectEqualStrings("<h1>hello</h1>", w.buffered());
}

test "renders nested element with attrs and z-bind" {
    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const tree: Node = .{
        .tag = "div",
        .attrs = &.{.{ .key = "class", .value = "card" }},
        .children = &.{
            .{ .tag = "span", .z_bind = "count", .text = "0" },
            .{ .tag = "button", .z_on_click = "increment", .text = "+" },
        },
    };
    try Renderer.render(&w, tree);
    try std.testing.expectEqualStrings(
        \\<div class="card"><span z-bind="count">0</span><button z-on-click="increment">+</button></div>
    , w.buffered());
}

test "escapes HTML entities in text" {
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try Renderer.render(&w, .{ .tag = "p", .text = "<script>alert(1)</script> & co" });
    try std.testing.expectEqualStrings(
        "<p>&lt;script&gt;alert(1)&lt;/script&gt; &amp; co</p>",
        w.buffered(),
    );
}

test "escapes quotes in attribute values" {
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try Renderer.render(&w, .{
        .tag = "input",
        .attrs = &.{.{ .key = "value", .value = "a\"b<c" }},
    });
    try std.testing.expectEqualStrings(
        "<input value=\"a&quot;b&lt;c\">",
        w.buffered(),
    );
}

test "void elements omit closing tag" {
    var buf: [128]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try Renderer.render(&w, .{ .tag = "br" });
    try std.testing.expectEqualStrings("<br>", w.buffered());
}
