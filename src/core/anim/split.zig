//! SplitText (verve.anim phase 5): break a node's text into animatable
//! spans, server-side — the SSR knows the text at render time, so chars /
//! words splitting is pure node-tree surgery with zero JS. Only `lines`
//! needs the browser (wrap depends on layout): it emits word spans plus a
//! `data-split-lines` marker the bridge groups by offsetTop post-hydrate.
//!
//! Output shape (a11y: the parent reads as the original text, the span
//! soup is hidden from screen readers behind ONE wrapper):
//!
//!   <h1 aria-label="Hi">
//!     <span aria-hidden="true" data-split-wrap>
//!       <span class="st-char">H</span><span class="st-char">i</span>
//!     </span>
//!   </h1>
//!
//! Whitespace runs are preserved VERBATIM as plain text nodes between
//! spans so wrapping and collapsing behave exactly like the unsplit text.
//! Splitting is per UTF-8 codepoint — grapheme clusters (combining marks,
//! ZWJ emoji) may split apart, and bidi/RTL reordering across spans is
//! unsupported; both documented caveats. Spans need
//! `display:inline-block` in CSS for transforms to apply.
//!
//! This file depends only on std + node.zig — no descriptor/serializer
//! coupling (the node.zig <-> split.zig file cycle is legal and
//! precedented by route.zig).

const std = @import("std");
const node_mod = @import("../node.zig");
const Node = node_mod.Node;

pub const By = enum {
    chars,
    words,
    /// Word spans containing char spans — chars animate while the word
    /// box keeps line wrap stable (GSAP parity).
    words_and_chars,
    /// Server emits word spans + `data-split-lines`; the bridge groups
    /// them into line wrappers by offsetTop once at hydrate.
    lines,
};

pub const Options = struct {
    by: By = .chars,
    char_class: []const u8 = "st-char",
    word_class: []const u8 = "st-word",
    line_class: []const u8 = "st-line",
    /// Stamp `data-st-i="<n>"` (sequential, whitespace excluded) on each
    /// leaf span; `words_and_chars` also stamps `data-st-w` on words.
    index_attr: bool = false,
};

/// Transform `node`'s text_content into split spans. Misuse and invalid
/// UTF-8 are deferred errors on `node.err` (chain pattern).
pub fn apply(node: *Node, opts: Options) void {
    if (node.err != null) return;
    const text = node.text_content orelse {
        node.err = error.SplitWithoutText;
        return;
    };
    if (node.raw_inner != null) {
        node.err = error.SplitWithRaw;
        return;
    }
    if (node.children_list.items.len > 0) {
        node.err = error.SplitWithChildren;
        return;
    }
    if (node.z_bind_name != null) {
        node.err = error.SplitWithBinding;
        return;
    }
    if (!std.unicode.utf8ValidateSlice(text)) {
        node.err = error.InvalidUtf8;
        return;
    }
    const arena = node.arena.?;

    const wrap = node_mod.create(arena, "span")
        .attr("aria-hidden", "true")
        .attr("data-split-wrap", "");

    var idx: usize = 0;
    var word_idx: usize = 0;
    buildInto(arena, wrap, text, opts, &idx, &word_idx);
    if (wrap.err) |e| {
        node.err = e;
        return;
    }

    node.text_content = null;
    _ = node.children(wrap);
    if (!hasAttr(node, "aria-label")) _ = node.attr("aria-label", text);
    if (opts.by == .lines) _ = node.attr("data-split-lines", opts.line_class);
}

fn hasAttr(node: *const Node, key: []const u8) bool {
    for (node.attrs.items) |at| {
        if (std.mem.eql(u8, at.key, key)) return true;
    }
    return false;
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn buildInto(
    arena: std.mem.Allocator,
    parent: *Node,
    text: []const u8,
    opts: Options,
    idx: *usize,
    word_idx: *usize,
) void {
    var i: usize = 0;
    while (i < text.len) {
        if (isWs(text[i])) {
            // whitespace run, preserved verbatim as a plain text node
            const start = i;
            while (i < text.len and isWs(text[i])) i += 1;
            _ = parent.children(node_mod.create(arena, "__text__").text(text[start..i]));
            continue;
        }
        const start = i;
        while (i < text.len and !isWs(text[i])) i += 1;
        const word = text[start..i];
        switch (opts.by) {
            .chars => emitChars(arena, parent, word, opts, idx),
            .words, .lines => {
                const w = node_mod.create(arena, "span").class(opts.word_class).text(word);
                stampIndex(w, opts, "data-st-i", idx);
                _ = parent.children(w);
            },
            .words_and_chars => {
                const w = node_mod.create(arena, "span").class(opts.word_class);
                stampIndex(w, opts, "data-st-w", word_idx);
                emitChars(arena, w, word, opts, idx);
                _ = parent.children(w);
            },
        }
        if (parent.err != null) return;
    }
}

fn emitChars(arena: std.mem.Allocator, parent: *Node, word: []const u8, opts: Options, idx: *usize) void {
    // utf8ValidateSlice already ran on the whole text — iterate by
    // codepoint length without re-validating.
    var i: usize = 0;
    while (i < word.len) {
        const len = std.unicode.utf8ByteSequenceLength(word[i]) catch 1;
        const end = @min(i + len, word.len);
        const ch = node_mod.create(arena, "span").class(opts.char_class).text(word[i..end]);
        stampIndex(ch, opts, "data-st-i", idx);
        _ = parent.children(ch);
        if (parent.err != null) return;
        i = end;
    }
}

fn stampIndex(n: *Node, opts: Options, key: []const u8, idx: *usize) void {
    if (opts.index_attr) {
        _ = n.attrFmt(key, "{d}", .{idx.*});
    }
    idx.* += 1;
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;
const Renderer = @import("../renderer.zig").Renderer;

fn ta() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

test "chars: structure, wrapper, aria" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();

    const n = node_mod.create(a, "h1").text("Hi");
    apply(n, .{ .by = .chars });
    try testing.expect(n.err == null);
    try testing.expect(n.text_content == null);
    // aria-label restored as an attr
    try testing.expect(hasAttr(n, "aria-label"));
    // one wrapper child
    try testing.expectEqual(@as(usize, 1), n.children_list.items.len);
    const wrap = n.children_list.items[0];
    try testing.expect(hasAttr(wrap, "aria-hidden"));
    try testing.expect(hasAttr(wrap, "data-split-wrap"));
    try testing.expectEqual(@as(usize, 2), wrap.children_list.items.len);
    try testing.expectEqualStrings("H", wrap.children_list.items[0].text_content.?);
    try testing.expectEqualStrings("i", wrap.children_list.items[1].text_content.?);
}

test "chars: whitespace runs are plain text nodes" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();

    const n = node_mod.create(a, "p").text("a  b");
    apply(n, .{ .by = .chars });
    const wrap = n.children_list.items[0];
    try testing.expectEqual(@as(usize, 3), wrap.children_list.items.len);
    try testing.expectEqualStrings("span", wrap.children_list.items[0].tag);
    try testing.expectEqualStrings("__text__", wrap.children_list.items[1].tag);
    try testing.expectEqualStrings("  ", wrap.children_list.items[1].text_content.?);
    try testing.expectEqualStrings("span", wrap.children_list.items[2].tag);
}

test "chars: UTF-8 codepoints kept whole; invalid rejected" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();

    const n = node_mod.create(a, "p").text("héì");
    apply(n, .{ .by = .chars });
    const wrap = n.children_list.items[0];
    try testing.expectEqual(@as(usize, 3), wrap.children_list.items.len);
    try testing.expectEqualStrings("é", wrap.children_list.items[1].text_content.?);
    try testing.expectEqualStrings("ì", wrap.children_list.items[2].text_content.?);

    const bad = node_mod.create(a, "p").text("\xff\xfe");
    apply(bad, .{});
    try testing.expectEqual(@as(?anyerror, error.InvalidUtf8), bad.err);
}

test "words: verbatim whitespace between word spans" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();

    const n = node_mod.create(a, "p").text("foo  bar");
    apply(n, .{ .by = .words, .word_class = "w" });
    const wrap = n.children_list.items[0];
    try testing.expectEqual(@as(usize, 3), wrap.children_list.items.len);
    try testing.expectEqualStrings("foo", wrap.children_list.items[0].text_content.?);
    try testing.expectEqualStrings("  ", wrap.children_list.items[1].text_content.?);
    try testing.expectEqualStrings("bar", wrap.children_list.items[2].text_content.?);
}

test "words_and_chars: nesting + index attrs" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();

    const n = node_mod.create(a, "p").text("ab c");
    apply(n, .{ .by = .words_and_chars, .index_attr = true });
    const wrap = n.children_list.items[0];
    const w0 = wrap.children_list.items[0];
    try testing.expect(hasAttr(w0, "data-st-w"));
    try testing.expectEqual(@as(usize, 2), w0.children_list.items.len);
    try testing.expect(hasAttr(w0.children_list.items[0], "data-st-i"));
    // global char index dense across words: a=0 b=1 c=2
    const w1 = wrap.children_list.items[2];
    try testing.expectEqualStrings("2", attrValue(w1.children_list.items[0], "data-st-i").?);
}

fn attrValue(n: *const Node, key: []const u8) ?[]const u8 {
    for (n.attrs.items) |at| {
        if (std.mem.eql(u8, at.key, key)) return at.value;
    }
    return null;
}

test "lines: word output + marker attr" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();

    const n = node_mod.create(a, "p").text("the quick fox");
    apply(n, .{ .by = .lines, .line_class = "row" });
    try testing.expectEqualStrings("row", attrValue(n, "data-split-lines").?);
    const wrap = n.children_list.items[0];
    try testing.expectEqual(@as(usize, 5), wrap.children_list.items.len); // 3 words + 2 spaces
}

test "precondition errors" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();

    const no_text = node_mod.create(a, "p");
    apply(no_text, .{});
    try testing.expectEqual(@as(?anyerror, error.SplitWithoutText), no_text.err);

    const raw = node_mod.create(a, "p").text("x").raw("<b>x</b>");
    apply(raw, .{});
    try testing.expectEqual(@as(?anyerror, error.SplitWithRaw), raw.err);

    const kids = node_mod.create(a, "p").text("x").children(node_mod.create(a, "span"));
    apply(kids, .{});
    try testing.expectEqual(@as(?anyerror, error.SplitWithChildren), kids.err);

    const bound = node_mod.create(a, "p").text("x").bind("sig");
    apply(bound, .{});
    try testing.expectEqual(@as(?anyerror, error.SplitWithBinding), bound.err);

    // double split: second call sees children
    const twice = node_mod.create(a, "p").text("hi").splitText(.{});
    apply(twice, .{});
    try testing.expectEqual(@as(?anyerror, error.SplitWithoutText), twice.err);

    // poisoned node short-circuits untouched
    apply(&node_mod.poison, .{});
    try testing.expectEqual(@as(?anyerror, error.OutOfMemory), node_mod.poison.err);
}

test "empty string: wrapper present, zero spans" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    const n = node_mod.create(a, "p").text("");
    apply(n, .{});
    try testing.expect(n.err == null);
    try testing.expectEqual(@as(usize, 0), n.children_list.items[0].children_list.items.len);
}

test "existing aria-label preserved" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    const n = node_mod.create(a, "p").attr("aria-label", "custom").text("hi");
    apply(n, .{});
    try testing.expectEqualStrings("custom", attrValue(n, "aria-label").?);
}

test "render golden: escape-once (text via escapeHtml, label via escapeAttr)" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();

    const n = node_mod.create(a, "h1").text("a<\"");
    apply(n, .{ .by = .chars });
    try testing.expect(n.err == null);

    const buf = try a.alloc(u8, 1024);
    var w: std.Io.Writer = .fixed(buf);
    try Renderer.render(&w, n);
    const html = w.buffered();
    // text content escapes & < > only (the literal quote stays raw in
    // text); the aria-label attribute value escapes the quote.
    try testing.expect(std.mem.indexOf(u8, html, "aria-label=\"a&lt;&quot;\"") != null or
        std.mem.indexOf(u8, html, "aria-label=\"a<&quot;\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<span class=\"st-char\">a</span>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<span class=\"st-char\">&lt;</span>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "data-split-wrap") != null);
    try testing.expect(std.mem.indexOf(u8, html, "aria-hidden=\"true\"") != null);
    // escape-once: no double-escaped ampersands anywhere
    try testing.expect(std.mem.indexOf(u8, html, "&amp;lt;") == null);
    try testing.expect(std.mem.indexOf(u8, html, "&amp;quot;") == null);
}
