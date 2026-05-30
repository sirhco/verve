//! Pure-Zig GFM markdown → `Node` subtree.
//!
//! Parses CommonMark-style block structure (P4) and inline spans (P5) plus
//! the GFM extensions tables + task lists (P6), emitting a real `Node` tree.
//! Every text leaf goes through `ctx.textNode` / `.text`, so the renderer's
//! escaper is the only escaper — markdown can never inject markup. Link/image
//! URLs are filtered through `core/sanitize.zig`; raw HTML in the source is
//! stripped, not passed through. Fenced code blocks are syntax-highlighted via
//! `core/highlight.zig`.
//!
//! The whole module is pure functions over slices + an explicit allocator, so
//! it compiles to the wasm client target unchanged for future live preview.

const std = @import("std");
const Context = @import("context.zig").Context;
const Node = @import("node.zig").Node;
const highlight = @import("highlight.zig");
const inline_mod = @import("markdown_inline.zig");

pub const Options = struct {
    /// GFM extensions: tables, task lists, strikethrough, autolinks.
    gfm: bool = true,
    /// Syntax-highlight fenced code blocks carrying a language hint.
    highlight: bool = true,
    /// Resolve root-relative/relative link & image URLs against this base
    /// (optional; null leaves them untouched).
    base_url: ?[]const u8 = null,
};

/// Parse GFM `src` into a fragment `Node` (tag = "") holding the block
/// children. Drop it into a tree with `.children(.{ try ctx.markdown(src) })`
/// or return it directly from a route.
pub fn render(alloc: std.mem.Allocator, ctx: *const Context, src: []const u8, opts: Options) !*Node {
    var lines: std.ArrayList([]const u8) = .empty;
    try splitLines(alloc, &lines, src);

    var refs: std.ArrayList(inline_mod.RefDef) = .empty;
    const body = try collectRefs(alloc, lines.items, &refs);

    var p = Parser{ .alloc = alloc, .ctx = ctx, .opts = opts, .refs = refs.items };
    const frag = ctx.el("");
    try p.parseBlocks(frag, body);
    return frag.build();
}

const Parser = struct {
    alloc: std.mem.Allocator,
    ctx: *const Context,
    opts: Options,
    refs: []const inline_mod.RefDef,

    fn parseBlocks(self: *Parser, parent: *Node, lines: []const []const u8) anyerror!void {
        var i: usize = 0;
        while (i < lines.len) {
            const line = lines[i];
            if (isBlank(line)) {
                i += 1;
                continue;
            }

            const cols = indentCols(line);
            const fnw = firstNonWs(line);
            const content = line[fnw..];

            // Indented code block (≥4 columns).
            if (cols >= 4) {
                var code: std.ArrayList(u8) = .empty;
                var j = i;
                while (j < lines.len and (isBlank(lines[j]) or indentCols(lines[j]) >= 4)) : (j += 1) {
                    if (j > i) try code.append(self.alloc, '\n');
                    try code.appendSlice(self.alloc, stripCols(lines[j], 4));
                }
                try self.emitCodeBlock(parent, trimTrailingBlankBytes(code.items), "");
                i = j;
                continue;
            }

            // Thematic break.
            if (isHr(content)) {
                _ = parent.children(.{self.ctx.hr()});
                i += 1;
                continue;
            }

            // Fenced code block.
            if (fenceInfo(content)) |f| {
                var body: std.ArrayList(u8) = .empty;
                var j = i + 1;
                var first = true;
                while (j < lines.len) : (j += 1) {
                    const inner = lines[j];
                    const ic = inner[firstNonWs(inner)..];
                    if (isClosingFence(ic, f.char, f.len)) {
                        j += 1;
                        break;
                    }
                    if (!first) try body.append(self.alloc, '\n');
                    first = false;
                    // strip up to the fence's own indentation
                    try body.appendSlice(self.alloc, stripCols(inner, cols));
                }
                try self.emitCodeBlock(parent, body.items, if (self.opts.highlight) f.info else "");
                i = j;
                continue;
            }

            // Blockquote — collect consecutive `>` lines, strip one marker.
            if (content[0] == '>') {
                var inner: std.ArrayList([]const u8) = .empty;
                var j = i;
                while (j < lines.len and !isBlank(lines[j]) and indentCols(lines[j]) < 4 and
                    lines[j][firstNonWs(lines[j])] == '>')
                {
                    try inner.append(self.alloc, stripBlockquoteMarker(lines[j]));
                    j += 1;
                }
                const bq = self.ctx.el("blockquote");
                try self.parseBlocks(bq, inner.items);
                _ = parent.children(.{bq});
                i = j;
                continue;
            }

            // List (ordered / unordered).
            if (listMarker(content) != null) {
                i = try self.parseList(parent, lines, i);
                continue;
            }

            // ATX heading.
            if (content[0] == '#') {
                var k: usize = 0;
                while (k < content.len and content[k] == '#') : (k += 1) {}
                if (k >= 1 and k <= 6 and (k == content.len or content[k] == ' ' or content[k] == '\t')) {
                    const text = trimAtxText(content[k..]);
                    try self.emitHeading(parent, k, text);
                    i += 1;
                    continue;
                }
            }

            // GFM table.
            if (self.opts.gfm and isTableStart(lines, i)) {
                i = try self.parseTable(parent, lines, i);
                continue;
            }

            // Paragraph (with setext-heading lookahead).
            i = try self.parseParagraph(parent, lines, i);
        }
    }

    fn parseParagraph(self: *Parser, parent: *Node, lines: []const []const u8, start: usize) !usize {
        var para: std.ArrayList([]const u8) = .empty;
        var j = start;
        while (j < lines.len and !isBlank(lines[j])) {
            const line = lines[j];
            const content = line[firstNonWs(line)..];

            // setext underline turns the collected paragraph into a heading
            if (j > start and indentCols(line) < 4 and setextLevel(content) != 0) {
                const level = setextLevel(content);
                try self.emitHeading(parent, level, try joinSpace(self.alloc, para.items));
                return j + 1;
            }
            // a new block interrupts the paragraph
            if (j > start and indentCols(line) < 4 and
                (content[0] == '#' or fenceInfo(content) != null or isHr(content) or
                    content[0] == '>' or listMarker(content) != null))
            {
                break;
            }
            // keep trailing spaces (two+ trailing spaces = hard line break)
            try para.append(self.alloc, std.mem.trimEnd(u8, content, "\r"));
            j += 1;
        }
        const p = self.ctx.p();
        try inline_mod.renderInline(self.alloc, self.ctx, p, try joinNewline(self.alloc, para.items), self.opts, self.refs);
        _ = parent.children(.{p});
        return j;
    }

    fn parseList(self: *Parser, parent: *Node, lines: []const []const u8, start: usize) anyerror!usize {
        const first = listMarker(lines[start][firstNonWs(lines[start])..]).?;
        const list = if (first.ordered) self.ctx.ol() else self.ctx.ul();

        var idx = start;
        while (idx < lines.len) {
            const line = lines[idx];
            if (isBlank(line)) {
                idx += 1;
                continue;
            }
            const cols = indentCols(line);
            const fnw = firstNonWs(line);
            const content = line[fnw..];
            const m = listMarker(content) orelse break;
            if (cols >= 4 or m.ordered != first.ordered) break;

            const content_col = cols + m.text_offset;
            var item_lines: std.ArrayList([]const u8) = .empty;
            try item_lines.append(self.alloc, line[fnw + m.text_offset ..]);
            idx += 1;
            while (idx < lines.len and (isBlank(lines[idx]) or indentCols(lines[idx]) >= content_col)) : (idx += 1) {
                if (isBlank(lines[idx])) {
                    try item_lines.append(self.alloc, "");
                } else {
                    try item_lines.append(self.alloc, stripCols(lines[idx], content_col));
                }
            }

            const li = self.ctx.li();
            try self.parseListItem(li, item_lines.items);
            _ = list.children(.{li});
        }
        _ = parent.children(.{list});
        return idx;
    }

    fn parseListItem(self: *Parser, li: *Node, lines: []const []const u8) anyerror!void {
        // GFM task-list item: `[ ]` / `[x]` becomes a disabled checkbox.
        if (self.opts.gfm and lines.len > 0) {
            const first = lines[0];
            const c = first[firstNonWs(first)..];
            if (taskMarker(c)) |checked| {
                _ = li.class("task-list-item");
                const box = self.ctx.input().type_("checkbox").attr("disabled", "");
                if (checked) _ = box.attr("checked", "");
                _ = li.children(.{box});
                var parts: std.ArrayList([]const u8) = .empty;
                try parts.append(self.alloc, std.mem.trimStart(u8, c[3..], " "));
                if (lines.len > 1) try parts.appendSlice(self.alloc, lines[1..]);
                try inline_mod.renderInline(self.alloc, self.ctx, li, try joinNewline(self.alloc, parts.items), self.opts, self.refs);
                return;
            }
        }

        // Tight item: no blank separators and no nested block constructs →
        // render inline directly into the <li> (matches GFM tight lists).
        var has_blank = false;
        var has_block = false;
        for (lines, 0..) |l, k| {
            if (isBlank(l)) {
                if (k != lines.len - 1) has_blank = true;
                continue;
            }
            const c = l[firstNonWs(l)..];
            if (listMarker(c) != null or fenceInfo(c) != null or c[0] == '>' or
                (c[0] == '#' and indentCols(l) < 4))
            {
                has_block = true;
            }
        }
        if (!has_blank and !has_block) {
            try inline_mod.renderInline(self.alloc, self.ctx, li, try joinNewline(self.alloc, lines), self.opts, self.refs);
        } else {
            try self.parseBlocks(li, lines);
        }
    }

    fn emitHeading(self: *Parser, parent: *Node, level: usize, text: []const u8) !void {
        const tag = switch (level) {
            1 => "h1",
            2 => "h2",
            3 => "h3",
            4 => "h4",
            5 => "h5",
            else => "h6",
        };
        const h = self.ctx.el(tag);
        try inline_mod.renderInline(self.alloc, self.ctx, h, text, self.opts, self.refs);
        _ = parent.children(.{h});
    }

    fn emitCodeBlock(self: *Parser, parent: *Node, body: []const u8, info: []const u8) !void {
        _ = parent.children(.{try highlight.block(self.ctx, body, info)});
    }

    fn parseTable(self: *Parser, parent: *Node, lines: []const []const u8, start: usize) anyerror!usize {
        var headers: std.ArrayList([]const u8) = .empty;
        try splitCells(self.alloc, &headers, lines[start]);
        var aligns: std.ArrayList(Align) = .empty;
        try parseAligns(self.alloc, &aligns, lines[start + 1]);

        const table = self.ctx.el("table");
        const thead = self.ctx.el("thead");
        const htr = self.ctx.el("tr");
        for (headers.items, 0..) |cell, col| {
            const th = self.ctx.el("th");
            applyAlign(th, alignAt(aligns.items, col));
            try inline_mod.renderInline(self.alloc, self.ctx, th, cell, self.opts, self.refs);
            _ = htr.children(.{th});
        }
        _ = thead.children(.{htr});
        _ = table.children(.{thead});

        const tbody = self.ctx.el("tbody");
        var j = start + 2;
        while (j < lines.len and !isBlank(lines[j]) and indentCols(lines[j]) < 4 and
            std.mem.indexOfScalar(u8, lines[j], '|') != null) : (j += 1)
        {
            var cells: std.ArrayList([]const u8) = .empty;
            try splitCells(self.alloc, &cells, lines[j]);
            const tr = self.ctx.el("tr");
            for (0..headers.items.len) |col| {
                const td = self.ctx.el("td");
                applyAlign(td, alignAt(aligns.items, col));
                const cell = if (col < cells.items.len) cells.items[col] else "";
                try inline_mod.renderInline(self.alloc, self.ctx, td, cell, self.opts, self.refs);
                _ = tr.children(.{td});
            }
            _ = tbody.children(.{tr});
        }
        _ = table.children(.{tbody});
        _ = parent.children(.{table});
        return j;
    }
};

// ---- line helpers --------------------------------------------------------

fn splitLines(alloc: std.mem.Allocator, out: *std.ArrayList([]const u8), src: []const u8) !void {
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        try out.append(alloc, std.mem.trimEnd(u8, line, "\r"));
    }
    // A trailing '\n' yields a final empty element; harmless (treated blank).
}

/// Pull `[label]: url "title"` reference definitions out of the line list,
/// recording them in `refs` and returning the remaining (non-definition)
/// lines for block parsing.
fn collectRefs(
    alloc: std.mem.Allocator,
    lines: []const []const u8,
    refs: *std.ArrayList(inline_mod.RefDef),
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (lines) |line| {
        if (parseRefDef(line)) |rd| {
            try refs.append(alloc, rd);
        } else {
            try out.append(alloc, line);
        }
    }
    return out.items;
}

fn parseRefDef(line: []const u8) ?inline_mod.RefDef {
    if (indentCols(line) >= 4) return null;
    const content = line[firstNonWs(line)..];
    if (content.len < 4 or content[0] != '[') return null;
    var i: usize = 1;
    while (i < content.len and content[i] != ']') : (i += 1) {}
    if (i >= content.len or i == 1) return null;
    const label = content[1..i];
    if (i + 1 >= content.len or content[i + 1] != ':') return null;
    const rest = std.mem.trim(u8, content[i + 2 ..], " \t\r");
    if (rest.len == 0) return null;
    var k: usize = 0;
    while (k < rest.len and rest[k] != ' ' and rest[k] != '\t') : (k += 1) {}
    const url = rest[0..k];
    if (url.len == 0) return null;
    var title = std.mem.trim(u8, rest[k..], " \t\r");
    if (title.len >= 2 and (title[0] == '"' or title[0] == '\'') and title[title.len - 1] == title[0]) {
        title = title[1 .. title.len - 1];
    }
    return .{ .label = label, .url = url, .title = title };
}

fn isBlank(line: []const u8) bool {
    for (line) |c| {
        if (c != ' ' and c != '\t' and c != '\r') return false;
    }
    return true;
}

// ---- GFM tables ----------------------------------------------------------

const Align = enum { none, left, center, right };

fn isTableStart(lines: []const []const u8, i: usize) bool {
    if (i + 1 >= lines.len) return false;
    const h = lines[i];
    if (indentCols(h) >= 4) return false;
    if (std.mem.indexOfScalar(u8, h, '|') == null) return false;
    return isDelimRow(lines[i + 1]);
}

fn isDelimRow(line: []const u8) bool {
    if (indentCols(line) >= 4) return false;
    var t = std.mem.trim(u8, line, " \t\r");
    if (t.len == 0) return false;
    if (t[0] == '|') t = t[1..];
    if (t.len > 0 and t[t.len - 1] == '|') t = t[0 .. t.len - 1];
    var any = false;
    var it = std.mem.splitScalar(u8, t, '|');
    while (it.next()) |raw| {
        const cell = std.mem.trim(u8, raw, " \t\r");
        if (cell.len == 0) return false;
        var has_dash = false;
        for (cell, 0..) |c, idx| {
            if (c == ':') {
                if (idx != 0 and idx != cell.len - 1) return false;
            } else if (c == '-') {
                has_dash = true;
            } else return false;
        }
        if (!has_dash) return false;
        any = true;
    }
    return any;
}

fn splitCells(alloc: std.mem.Allocator, out: *std.ArrayList([]const u8), line: []const u8) !void {
    var t = std.mem.trim(u8, line, " \t\r");
    if (t.len > 0 and t[0] == '|') t = t[1..];
    if (t.len > 0 and t[t.len - 1] == '|') t = t[0 .. t.len - 1];
    var start: usize = 0;
    var k: usize = 0;
    while (k < t.len) : (k += 1) {
        if (t[k] == '\\') {
            k += 1; // keep the escaped char attached (inline parser unescapes)
            continue;
        }
        if (t[k] == '|') {
            try out.append(alloc, std.mem.trim(u8, t[start..k], " \t\r"));
            start = k + 1;
        }
    }
    try out.append(alloc, std.mem.trim(u8, t[start..], " \t\r"));
}

fn parseAligns(alloc: std.mem.Allocator, out: *std.ArrayList(Align), line: []const u8) !void {
    var cells: std.ArrayList([]const u8) = .empty;
    try splitCells(alloc, &cells, line);
    for (cells.items) |cell| {
        const left = cell.len > 0 and cell[0] == ':';
        const right = cell.len > 0 and cell[cell.len - 1] == ':';
        const a: Align = if (left and right) .center else if (right) .right else if (left) .left else .none;
        try out.append(alloc, a);
    }
}

fn alignAt(aligns: []const Align, col: usize) Align {
    return if (col < aligns.len) aligns[col] else .none;
}

fn applyAlign(node: *Node, a: Align) void {
    switch (a) {
        .none => {},
        .left => _ = node.attr("style", "text-align:left"),
        .center => _ = node.attr("style", "text-align:center"),
        .right => _ = node.attr("style", "text-align:right"),
    }
}

/// `[ ]` / `[x]` / `[X]` task marker → returns whether it is checked.
fn taskMarker(content: []const u8) ?bool {
    if (content.len < 3 or content[0] != '[' or content[2] != ']') return null;
    const mid = content[1];
    if (mid != ' ' and mid != 'x' and mid != 'X') return null;
    if (content.len > 3 and content[3] != ' ') return null;
    return mid != ' ';
}

fn firstNonWs(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return i;
}

fn indentCols(line: []const u8) usize {
    var col: usize = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == ' ') {
            col += 1;
        } else if (line[i] == '\t') {
            col += 4;
        } else break;
    }
    return col;
}

fn stripCols(line: []const u8, n: usize) []const u8 {
    var col: usize = 0;
    var i: usize = 0;
    while (i < line.len and col < n) : (i += 1) {
        if (line[i] == ' ') {
            col += 1;
        } else if (line[i] == '\t') {
            col += 4;
        } else break;
    }
    return line[i..];
}

fn isHr(content: []const u8) bool {
    var ch: u8 = 0;
    var n: usize = 0;
    for (content) |c| {
        if (c == ' ' or c == '\t' or c == '\r') continue;
        if (c != '-' and c != '*' and c != '_') return false;
        if (ch == 0) ch = c else if (c != ch) return false;
        n += 1;
    }
    return n >= 3;
}

const Fence = struct { char: u8, len: usize, info: []const u8 };

fn fenceInfo(content: []const u8) ?Fence {
    if (content.len < 3) return null;
    const c = content[0];
    if (c != '`' and c != '~') return null;
    var n: usize = 0;
    while (n < content.len and content[n] == c) : (n += 1) {}
    if (n < 3) return null;
    const info = std.mem.trim(u8, content[n..], " \t\r");
    // An info string for a backtick fence may not contain a backtick.
    if (c == '`' and std.mem.indexOfScalar(u8, info, '`') != null) return null;
    return .{ .char = c, .len = n, .info = info };
}

fn isClosingFence(content: []const u8, ch: u8, min_len: usize) bool {
    var n: usize = 0;
    while (n < content.len and content[n] == ch) : (n += 1) {}
    if (n < min_len) return false;
    return isBlank(content[n..]);
}

fn setextLevel(content: []const u8) usize {
    if (content.len == 0) return 0;
    const c = content[0];
    if (c != '=' and c != '-') return 0;
    var n: usize = 0;
    while (n < content.len and content[n] == c) : (n += 1) {}
    if (!isBlank(content[n..])) return 0;
    return if (c == '=') 1 else 2;
}

fn trimAtxText(s: []const u8) []const u8 {
    var t = std.mem.trim(u8, s, " \t\r");
    // strip an optional trailing run of '#'
    var end = t.len;
    while (end > 0 and t[end - 1] == '#') : (end -= 1) {}
    if (end < t.len and (end == 0 or t[end - 1] == ' ' or t[end - 1] == '\t')) {
        t = std.mem.trimEnd(u8, t[0..end], " \t");
    }
    return t;
}

const Marker = struct { ordered: bool, text_offset: usize };

fn listMarker(content: []const u8) ?Marker {
    if (content.len == 0) return null;
    const c0 = content[0];
    if (c0 == '-' or c0 == '*' or c0 == '+') {
        if (content.len == 1) return .{ .ordered = false, .text_offset = 1 };
        if (content[1] == ' ' or content[1] == '\t') {
            return .{ .ordered = false, .text_offset = skipSpaces(content, 1) };
        }
        return null;
    }
    var k: usize = 0;
    while (k < content.len and content[k] >= '0' and content[k] <= '9') : (k += 1) {}
    if (k == 0 or k > 9) return null;
    if (k >= content.len) return null;
    if (content[k] != '.' and content[k] != ')') return null;
    if (k + 1 == content.len) return .{ .ordered = true, .text_offset = k + 1 };
    if (content[k + 1] == ' ' or content[k + 1] == '\t') {
        return .{ .ordered = true, .text_offset = skipSpaces(content, k + 1) };
    }
    return null;
}

fn skipSpaces(s: []const u8, from: usize) usize {
    var i = from;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    return i;
}

fn stripBlockquoteMarker(line: []const u8) []const u8 {
    const fnw = firstNonWs(line);
    var i = fnw + 1; // skip '>'
    if (i < line.len and line[i] == ' ') i += 1;
    return line[i..];
}

fn trimTrailingBlankBytes(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, "\n \t\r");
}

fn joinNewline(alloc: std.mem.Allocator, lines: []const []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (lines, 0..) |l, i| {
        if (i > 0) try buf.append(alloc, '\n');
        try buf.appendSlice(alloc, l);
    }
    return buf.items;
}

fn joinSpace(alloc: std.mem.Allocator, lines: []const []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (lines, 0..) |l, i| {
        if (i > 0) try buf.append(alloc, ' ');
        try buf.appendSlice(alloc, std.mem.trim(u8, l, " \t\r"));
    }
    return buf.items;
}

// ---- tests ---------------------------------------------------------------

const Renderer = @import("renderer.zig").Renderer;
const Writer = std.Io.Writer;

fn md(arena: *std.heap.ArenaAllocator, src: []const u8, buf: []u8) ![]const u8 {
    const ctx = Context.init(arena);
    const node = try render(arena.allocator(), &ctx, src, .{});
    var w: Writer = .fixed(buf);
    try Renderer.render(&w, node);
    return w.buffered();
}

test "headings: atx and setext" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("<h1>Title</h1>", try md(&arena, "# Title", &buf));
    try std.testing.expectEqualStrings("<h3>Deep</h3>", try md(&arena, "### Deep ###", &buf));
    try std.testing.expectEqualStrings("<h1>Setext</h1>", try md(&arena, "Setext\n======", &buf));
    try std.testing.expectEqualStrings("<h2>Sub</h2>", try md(&arena, "Sub\n---", &buf));
}

test "paragraph and thematic break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("<p>hello world</p>", try md(&arena, "hello world", &buf));
    try std.testing.expectEqualStrings("<hr><p>after</p>", try md(&arena, "---\nafter", &buf));
}

test "fenced code block is highlighted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [1024]u8 = undefined;
    const out = try md(&arena, "```zig\nconst x = 1;\n```", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "<pre><code class=\"language-zig\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-kw\">const</span>") != null);
}

test "fenced code escapes html and does not inject markup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [1024]u8 = undefined;
    const out = try md(&arena, "```\n<script>alert(1)</script>\n```", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "&lt;script&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<script>") == null);
}

test "unordered and ordered tight lists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("<ul><li>a</li><li>b</li></ul>", try md(&arena, "- a\n- b", &buf));
    try std.testing.expectEqualStrings("<ol><li>one</li><li>two</li></ol>", try md(&arena, "1. one\n2. two", &buf));
}

test "blockquote wraps inner blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("<blockquote><p>quoted</p></blockquote>", try md(&arena, "> quoted", &buf));
}

test "indented code block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("<pre><code>code()</code></pre>", try md(&arena, "    code()", &buf));
}

test "inline emphasis, strong, strikethrough, code span" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("<p>a <em>b</em> c</p>", try md(&arena, "a *b* c", &buf));
    try std.testing.expectEqualStrings("<p>a <strong>b</strong></p>", try md(&arena, "a **b**", &buf));
    try std.testing.expectEqualStrings("<p><strong><em>x</em></strong></p>", try md(&arena, "***x***", &buf));
    try std.testing.expectEqualStrings("<p><del>gone</del></p>", try md(&arena, "~~gone~~", &buf));
    try std.testing.expectEqualStrings("<p>use <code>x &lt; y</code></p>", try md(&arena, "use `x < y`", &buf));
}

test "inline escapes text and ignores raw html" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [512]u8 = undefined;
    // raw inline HTML is stripped; the angle-bracketed tag does not appear
    const out = try md(&arena, "hi <b>bold</b> and <script>x</script>", &buf);
    try std.testing.expectEqualStrings("<p>hi bold and x</p>", out);
}

test "links: inline and reference, with safe and unsafe URLs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "<p><a href=\"/x\">go</a></p>",
        try md(&arena, "[go](/x)", &buf),
    );
    try std.testing.expectEqualStrings(
        "<p><a href=\"https://e.com\" title=\"T\">e</a></p>",
        try md(&arena, "[e](https://e.com \"T\")", &buf),
    );
    // reference link
    try std.testing.expectEqualStrings(
        "<p><a href=\"https://ref.com\">r</a></p>",
        try md(&arena, "[r][id]\n\n[id]: https://ref.com", &buf),
    );
    // javascript: URL is dropped, visible text kept
    try std.testing.expectEqualStrings(
        "<p>click</p>",
        try md(&arena, "[click](javascript:alert(1))", &buf),
    );
}

test "image with safe and unsafe src" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "<p><img src=\"/a.png\" alt=\"alt\"></p>",
        try md(&arena, "![alt](/a.png)", &buf),
    );
    // unsafe data: src falls back to alt text
    try std.testing.expectEqualStrings(
        "<p>alt</p>",
        try md(&arena, "![alt](javascript:x)", &buf),
    );
}

test "autolink url and email" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "<p><a href=\"https://v.dev\">https://v.dev</a></p>",
        try md(&arena, "<https://v.dev>", &buf),
    );
    try std.testing.expectEqualStrings(
        "<p><a href=\"mailto:a@b.com\">a@b.com</a></p>",
        try md(&arena, "<a@b.com>", &buf),
    );
}

test "hard line break via two trailing spaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("<p>a<br>b</p>", try md(&arena, "a  \nb", &buf));
}

test "gfm table with alignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [1024]u8 = undefined;
    const src =
        \\| a | b |
        \\|:--|--:|
        \\| 1 | 2 |
    ;
    const out = try md(&arena, src, &buf);
    try std.testing.expectEqualStrings(
        "<table><thead><tr><th style=\"text-align:left\">a</th><th style=\"text-align:right\">b</th></tr></thead>" ++
            "<tbody><tr><td style=\"text-align:left\">1</td><td style=\"text-align:right\">2</td></tr></tbody></table>",
        out,
    );
}

test "gfm task list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [1024]u8 = undefined;
    const out = try md(&arena, "- [ ] todo\n- [x] done", &buf);
    try std.testing.expectEqualStrings(
        "<ul><li class=\"task-list-item\"><input type=\"checkbox\" disabled=\"\">todo</li>" ++
            "<li class=\"task-list-item\"><input type=\"checkbox\" disabled=\"\" checked=\"\">done</li></ul>",
        out,
    );
}

test "gfm autolink bare url is plain text without gfm-bare support" {
    // table cells with inline content still escape html
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [1024]u8 = undefined;
    const src =
        \\| h |
        \\|---|
        \\| <script>x</script> |
    ;
    const out = try md(&arena, src, &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "<script>") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "x") != null);
}
