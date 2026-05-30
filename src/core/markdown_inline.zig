//! Inline-span parsing for markdown.
//!
//! Handles code spans, emphasis/strong, GFM strikethrough, links & images
//! (with URL sanitization), autolinks, hard line breaks, and reference links.
//! Every text leaf flows through `ctx.textNode` / `.text`, and every URL
//! through `core/sanitize.zig`; raw inline HTML is stripped. The emphasis
//! handling is a pragmatic subset of CommonMark's delimiter algorithm — it
//! covers the common cases (`*em*`, `**strong**`, `***both***`, `_`, `~~`)
//! but not every exotic flanking edge case.

const std = @import("std");
const Context = @import("context.zig").Context;
const Node = @import("node.zig").Node;
const Options = @import("markdown.zig").Options;
const sanitize = @import("sanitize.zig");

/// A `[label]: url "title"` reference definition collected by the block pass.
pub const RefDef = struct { label: []const u8, url: []const u8, title: []const u8 };

const max_depth = 16;

/// Parse the inline content of `text` and append the resulting nodes to
/// `parent`.
pub fn renderInline(
    alloc: std.mem.Allocator,
    ctx: *const Context,
    parent: *Node,
    text: []const u8,
    opts: Options,
    refs: []const RefDef,
) !void {
    var inl = Inline{ .alloc = alloc, .ctx = ctx, .opts = opts, .refs = refs };
    try inl.scan(parent, text, 0);
}

const Inline = struct {
    alloc: std.mem.Allocator,
    ctx: *const Context,
    opts: Options,
    refs: []const RefDef,

    fn emitText(self: *Inline, parent: *Node, s: []const u8) void {
        if (s.len > 0) _ = parent.children(.{self.ctx.textNode(s)});
    }

    fn scan(self: *Inline, parent: *Node, text: []const u8, depth: usize) anyerror!void {
        if (depth > max_depth) {
            self.emitText(parent, text);
            return;
        }
        const n = text.len;
        var i: usize = 0;
        var ts: usize = 0;
        while (i < n) {
            const c = text[i];

            // Backslash escape of an ASCII punctuation char.
            if (c == '\\' and i + 1 < n and isAsciiPunct(text[i + 1])) {
                self.emitText(parent, text[ts..i]);
                self.emitText(parent, text[i + 1 .. i + 2]);
                i += 2;
                ts = i;
                continue;
            }

            // Code span.
            if (c == '`') {
                var r = i;
                while (r < n and text[r] == '`') : (r += 1) {}
                const rl = r - i;
                if (findCodeClose(text, r, rl)) |cs| {
                    self.emitText(parent, text[ts..i]);
                    var inner = text[r..cs];
                    if (inner.len >= 2 and inner[0] == ' ' and inner[inner.len - 1] == ' ' and !allSpace(inner)) {
                        inner = inner[1 .. inner.len - 1];
                    }
                    _ = parent.children(.{self.ctx.code(inner)});
                    i = cs + rl;
                    ts = i;
                    continue;
                }
                i = r; // unmatched backticks → literal
                continue;
            }

            // Autolink or stripped raw HTML.
            if (c == '<') {
                if (try self.tryAutolink(parent, text, i, ts)) |ni| {
                    i = ni;
                    ts = ni;
                    continue;
                }
                if (stripHtmlTag(text, i)) |ni| {
                    self.emitText(parent, text[ts..i]);
                    i = ni;
                    ts = ni;
                    continue;
                }
                i += 1;
                continue;
            }

            // Image.
            if (c == '!' and i + 1 < n and text[i + 1] == '[') {
                if (try self.tryImage(parent, text, i, &ts, depth)) |ni| {
                    i = ni;
                    continue;
                }
                i += 1;
                continue;
            }

            // Link.
            if (c == '[') {
                if (try self.tryLink(parent, text, i, &ts, depth)) |ni| {
                    i = ni;
                    continue;
                }
                i += 1;
                continue;
            }

            // Line break (hard vs soft).
            if (c == '\n') {
                var seg_end = i;
                var spaces: usize = 0;
                while (seg_end > ts and text[seg_end - 1] == ' ') {
                    seg_end -= 1;
                    spaces += 1;
                }
                const backslash = i > ts and text[i - 1] == '\\';
                const hard = spaces >= 2 or backslash;
                const te = if (spaces >= 2) seg_end else if (backslash) i - 1 else i;
                self.emitText(parent, text[ts..te]);
                if (hard) {
                    _ = parent.children(.{self.ctx.br()});
                } else {
                    self.emitText(parent, " ");
                }
                i += 1;
                ts = i;
                continue;
            }

            // Emphasis / strong / strikethrough.
            if (c == '*' or c == '_' or c == '~') {
                if (try self.tryEmphasis(parent, text, i, &ts, depth)) |ni| {
                    i = ni;
                    continue;
                }
                i += 1;
                continue;
            }

            i += 1;
        }
        self.emitText(parent, text[ts..n]);
    }

    fn tryEmphasis(self: *Inline, parent: *Node, text: []const u8, i: usize, ts: *usize, depth: usize) !?usize {
        const n = text.len;
        const ch = text[i];
        var r = i;
        while (r < n and text[r] == ch) : (r += 1) {}
        const run = r - i;
        if (r >= n or text[r] == ' ' or text[r] == '\n') return null; // opener must be left-flanking
        if (ch == '~' and run < 2) return null; // GFM strikethrough is ~~
        if (ch == '_' and i > 0 and isAlnum(text[i - 1])) return null; // no intraword _

        const close = findEmphClose(text, r, ch) orelse return null;
        const take = @min(run, @min(close.len, if (ch == '~') @as(usize, 2) else @as(usize, 3)));
        if (ch == '~' and take < 2) return null;

        const inner = text[i + take .. close.pos];
        if (inner.len == 0) return null;

        self.emitText(parent, text[ts.*..i]);
        const node = try self.wrapEmphasis(ch, take, inner, depth);
        _ = parent.children(.{node});
        const new_i = close.pos + take;
        ts.* = new_i;
        return new_i;
    }

    fn wrapEmphasis(self: *Inline, ch: u8, take: usize, inner: []const u8, depth: usize) !*Node {
        if (ch == '~') {
            const del = self.ctx.el("del");
            try self.scan(del, inner, depth + 1);
            return del;
        }
        if (take >= 3) {
            const strong = self.ctx.el("strong");
            const em = self.ctx.el("em");
            try self.scan(em, inner, depth + 1);
            _ = strong.children(.{em});
            return strong;
        }
        const tag = if (take == 2) "strong" else "em";
        const node = self.ctx.el(tag);
        try self.scan(node, inner, depth + 1);
        return node;
    }

    fn tryLink(self: *Inline, parent: *Node, text: []const u8, i: usize, ts: *usize, depth: usize) !?usize {
        const close = matchBracket(text, i) orelse return null;
        const label = text[i + 1 .. close];
        const target = self.parseTarget(text, close + 1, label) orelse return null;

        self.emitText(parent, text[ts.*..i]);
        if (sanitize.safeUrl(target.url)) |u| {
            const a = self.ctx.el("a").href(u);
            if (target.title.len > 0) _ = a.attr("title", target.title);
            try self.scan(a, label, depth + 1);
            _ = parent.children(.{a});
        } else {
            // unsafe URL → drop the link, keep the visible text
            try self.scan(parent, label, depth + 1);
        }
        ts.* = target.end;
        return target.end;
    }

    fn tryImage(self: *Inline, parent: *Node, text: []const u8, i: usize, ts: *usize, depth: usize) !?usize {
        _ = depth;
        const close = matchBracket(text, i + 1) orelse return null; // '[' is at i+1
        const alt = text[i + 2 .. close];
        const target = self.parseTarget(text, close + 1, alt) orelse return null;

        self.emitText(parent, text[ts.*..i]);
        if (sanitize.safeUrl(target.url)) |u| {
            const img = self.ctx.el("img").src(u).alt(alt);
            if (target.title.len > 0) _ = img.attr("title", target.title);
            _ = parent.children(.{img});
        } else {
            self.emitText(parent, alt); // unsafe src → fall back to alt text
        }
        ts.* = target.end;
        return target.end;
    }

    const Target = struct { url: []const u8, title: []const u8, end: usize };

    /// Parse a link/image target that begins at `after` (the byte just past
    /// the closing `]`). Handles inline `(url "title")`, full reference
    /// `[ref]`, collapsed `[]`, and shortcut (no brackets) forms. `label` is
    /// the bracket text, used as the implicit reference label.
    fn parseTarget(self: *Inline, text: []const u8, after: usize, label: []const u8) ?Target {
        const n = text.len;
        if (after < n and text[after] == '(') {
            var k = after + 1;
            while (k < n and text[k] == ' ') : (k += 1) {}
            var url: []const u8 = "";
            if (k < n and text[k] == '<') {
                k += 1;
                const s = k;
                while (k < n and text[k] != '>') : (k += 1) {}
                url = text[s..k];
                if (k < n) k += 1;
            } else {
                const s = k;
                var pd: usize = 0; // balance nested parens inside the URL
                while (k < n) : (k += 1) {
                    const ch = text[k];
                    if (ch == ' ') break;
                    if (ch == '(') pd += 1;
                    if (ch == ')') {
                        if (pd == 0) break;
                        pd -= 1;
                    }
                }
                url = text[s..k];
            }
            var title: []const u8 = "";
            while (k < n and text[k] == ' ') : (k += 1) {}
            if (k < n and (text[k] == '"' or text[k] == '\'')) {
                const q = text[k];
                k += 1;
                const s = k;
                while (k < n and text[k] != q) : (k += 1) {}
                title = text[s..k];
                if (k < n) k += 1;
            }
            while (k < n and text[k] == ' ') : (k += 1) {}
            if (k >= n or text[k] != ')') return null;
            return .{ .url = url, .title = title, .end = k + 1 };
        }
        if (after < n and text[after] == '[') {
            var k = after + 1;
            const s = k;
            while (k < n and text[k] != ']') : (k += 1) {}
            if (k >= n) return null;
            const ref = if (k == s) label else text[s..k];
            const rd = self.findRef(ref) orelse return null;
            return .{ .url = rd.url, .title = rd.title, .end = k + 1 };
        }
        // shortcut reference: [label]
        const rd = self.findRef(label) orelse return null;
        return .{ .url = rd.url, .title = rd.title, .end = after };
    }

    fn tryAutolink(self: *Inline, parent: *Node, text: []const u8, i: usize, ts: usize) !?usize {
        const n = text.len;
        var j = i + 1;
        while (j < n and text[j] != '>' and text[j] != ' ' and text[j] != '\n') : (j += 1) {}
        if (j >= n or text[j] != '>') return null;
        const inner = text[i + 1 .. j];
        if (inner.len == 0) return null;

        var url: []const u8 = inner;
        if (hasUriScheme(inner)) {
            url = inner;
        } else if (looksEmail(inner)) {
            url = try std.fmt.allocPrint(self.alloc, "mailto:{s}", .{inner});
        } else {
            return null;
        }
        const safe = sanitize.safeUrl(url) orelse return null;
        self.emitText(parent, text[ts..i]);
        _ = parent.children(.{self.ctx.el("a").href(safe).text(inner)});
        return j + 1;
    }

    fn findRef(self: *Inline, label: []const u8) ?RefDef {
        const want = std.mem.trim(u8, label, " \t\n");
        for (self.refs) |rd| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, rd.label, " \t\n"), want)) return rd;
        }
        return null;
    }
};

// ---- helpers -------------------------------------------------------------

fn findCodeClose(text: []const u8, from: usize, run_len: usize) ?usize {
    var i = from;
    const n = text.len;
    while (i < n) {
        if (text[i] == '`') {
            var k = i;
            while (k < n and text[k] == '`') : (k += 1) {}
            if (k - i == run_len) return i;
            i = k;
        } else i += 1;
    }
    return null;
}

const Run = struct { pos: usize, len: usize };

fn findEmphClose(text: []const u8, from: usize, ch: u8) ?Run {
    var j = from;
    const n = text.len;
    while (j < n) {
        if (text[j] == '\\') {
            j += 2;
            continue;
        }
        if (text[j] == ch) {
            var k = j;
            while (k < n and text[k] == ch) : (k += 1) {}
            const before = if (j > 0) text[j - 1] else ' ';
            var valid = before != ' ' and before != '\n';
            if (ch == '_') {
                const after = if (k < n) text[k] else ' ';
                if (isAlnum(after)) valid = false;
            }
            if (valid) return .{ .pos = j, .len = k - j };
            j = k;
            continue;
        }
        j += 1;
    }
    return null;
}

fn matchBracket(text: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var j = open + 1;
    const n = text.len;
    while (j < n) {
        const c = text[j];
        if (c == '\\') {
            j += 2;
            continue;
        }
        if (c == '[') depth += 1;
        if (c == ']') {
            if (depth == 0) return j;
            depth -= 1;
        }
        j += 1;
    }
    return null;
}

fn stripHtmlTag(text: []const u8, i: usize) ?usize {
    const n = text.len;
    if (i + 1 < n and (std.ascii.isAlphabetic(text[i + 1]) or text[i + 1] == '/' or text[i + 1] == '!')) {
        var j = i + 1;
        while (j < n and text[j] != '>') : (j += 1) {}
        if (j < n) j += 1;
        return j;
    }
    return null;
}

fn hasUriScheme(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len and s[i] != ':') : (i += 1) {
        const c = s[i];
        if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return false;
    }
    return i >= 2 and i < s.len and std.ascii.isAlphabetic(s[0]);
}

fn looksEmail(s: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, s, '@') orelse return false;
    if (at == 0 or at == s.len - 1) return false;
    if (std.mem.indexOfScalar(u8, s, ':') != null) return false;
    return std.mem.indexOfScalarPos(u8, s, at, '.') != null;
}

fn isAsciiPunct(c: u8) bool {
    return std.mem.indexOfScalar(u8, "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~", c) != null;
}
fn isAlnum(c: u8) bool {
    return std.ascii.isAlphanumeric(c);
}
fn allSpace(s: []const u8) bool {
    for (s) |c| {
        if (c != ' ') return false;
    }
    return true;
}
