//! Pure-Zig syntax highlighting.
//!
//! Tokenizes source code into a stream of `Token`s and emits them as a
//! `Node` subtree: each classified token becomes a `<span class="tok-…">`
//! wrapping escaped text, and unclassified runs become bare escaped text
//! nodes (`ctx.textNode`). No raw HTML is produced — every byte of source
//! flows through the renderer's escaper, so highlighting can never inject
//! markup. The stable `tok-*` class names are themed by
//! `core/highlight_theme.zig`.
//!
//! `core/markdown.zig` calls `block()` for fenced code blocks; apps call it
//! directly via `ctx.codeBlock(src, lang)` / `verve.highlight`.
//!
//! Tokenizers are hand-written scanners. The C-family languages (Zig, JS/TS,
//! Bash, and the generic fallback) share `tokenizeSpec` parameterized by a
//! `LangSpec`; JSON/HTML/CSS/Markdown get bespoke scanners. The whole module
//! is pure functions over slices + an explicit allocator, so it compiles to
//! the wasm client target unchanged.

const std = @import("std");
const Context = @import("context.zig").Context;
const Node = @import("node.zig").Node;

pub const Lang = enum {
    zig,
    js,
    ts,
    json,
    html,
    css,
    bash,
    markdown,
    generic,
    plain,
};

/// Token classes. `cssClass` returns the stable public class name; `.ident`
/// and `.text` carry no class and render as bare text.
pub const TokenKind = enum {
    keyword,
    ident,
    string,
    number,
    comment,
    operator,
    punctuation,
    builtin,
    type,
    attr,
    tag,
    property,
    regex,
    escape,
    text,

    pub fn cssClass(self: TokenKind) []const u8 {
        return switch (self) {
            .keyword => "tok-kw",
            .string => "tok-str",
            .number => "tok-num",
            .comment => "tok-com",
            .operator => "tok-op",
            .punctuation => "tok-punc",
            .builtin => "tok-builtin",
            .type => "tok-type",
            .attr => "tok-attr",
            .tag => "tok-tag",
            .property => "tok-prop",
            .regex => "tok-regex",
            .escape => "tok-esc",
            .ident, .text => "",
        };
    }
};

pub const Token = struct { kind: TokenKind, text: []const u8 };

/// Map a fenced-code info string to a `Lang`. Only the first whitespace-
/// delimited word is considered (so "ts title=foo" → ts). Empty → `.plain`
/// (render without highlighting); unknown-but-present → `.generic`.
pub fn detectLang(info: []const u8) Lang {
    var end: usize = 0;
    while (end < info.len and info[end] != ' ' and info[end] != '\t') : (end += 1) {}
    const w = info[0..end];
    if (w.len == 0) return .plain;

    const map = .{
        .{ "zig", Lang.zig },
        .{ "js", Lang.js },
        .{ "javascript", Lang.js },
        .{ "jsx", Lang.js },
        .{ "mjs", Lang.js },
        .{ "ts", Lang.ts },
        .{ "typescript", Lang.ts },
        .{ "tsx", Lang.ts },
        .{ "json", Lang.json },
        .{ "jsonc", Lang.json },
        .{ "html", Lang.html },
        .{ "xml", Lang.html },
        .{ "svg", Lang.html },
        .{ "css", Lang.css },
        .{ "bash", Lang.bash },
        .{ "sh", Lang.bash },
        .{ "shell", Lang.bash },
        .{ "zsh", Lang.bash },
        .{ "md", Lang.markdown },
        .{ "markdown", Lang.markdown },
    };
    inline for (map) |pair| {
        if (std.ascii.eqlIgnoreCase(w, pair[0])) return pair[1];
    }
    return .generic;
}

/// Build `<pre><code class="language-<info>">…</code></pre>` for `source`.
/// `info` is the language hint; `""` renders plain text (no spans).
pub fn block(ctx: *const Context, source: []const u8, info: []const u8) !*Node {
    const lang = detectLang(info);
    const pre = ctx.pre();
    const code = ctx.el("code");
    if (info.len > 0) _ = code.attrFmt("class", "language-{s}", .{info});
    if (lang == .plain) {
        _ = code.text(source);
    } else {
        try highlightInto(ctx, code, source, lang);
    }
    if (code.err) |e| return e;
    return pre.children(.{code}).build();
}

/// Tokenize `source` as `lang` and append the resulting token nodes as
/// children of `code_node` (a `<code>` element). Shared seam used by both
/// `block()` and markdown's fenced-code path.
pub fn highlightInto(ctx: *const Context, code_node: *Node, source: []const u8, lang: Lang) !void {
    var toks: std.ArrayList(Token) = .empty;
    try tokenize(ctx.allocator, &toks, source, lang);
    for (toks.items) |t| {
        if (t.kind == .text or t.kind == .ident) {
            _ = code_node.children(.{ctx.textNode(t.text)});
        } else {
            _ = code_node.children(.{ctx.el("span").class(t.kind.cssClass()).text(t.text)});
        }
        if (code_node.err) |e| return e;
    }
}

fn tokenize(alloc: std.mem.Allocator, toks: *std.ArrayList(Token), src: []const u8, lang: Lang) !void {
    switch (lang) {
        .zig => try tokenizeSpec(alloc, toks, src, zig_spec),
        .js => try tokenizeSpec(alloc, toks, src, js_spec),
        .ts => try tokenizeSpec(alloc, toks, src, ts_spec),
        .bash => try tokenizeSpec(alloc, toks, src, bash_spec),
        .json => try tokenizeJson(alloc, toks, src),
        .html => try tokenizeHtml(alloc, toks, src),
        .css => try tokenizeCss(alloc, toks, src),
        .markdown => try tokenizeMarkdown(alloc, toks, src),
        .generic => try tokenizeSpec(alloc, toks, src, generic_spec),
        .plain => try push(alloc, toks, .text, src),
    }
}

// ---- C-family spec tokenizer ---------------------------------------------

const LangSpec = struct {
    keywords: []const []const u8 = &.{},
    builtins: []const []const u8 = &.{},
    types: []const []const u8 = &.{},
    line_comment: []const u8 = "",
    block_open: []const u8 = "",
    block_close: []const u8 = "",
    double_q: bool = true,
    single_q: bool = true,
    backtick: bool = false,
    /// Zig `@import`-style builtins: `@` + ident → `.builtin`.
    at_builtin: bool = false,
    /// Zig multiline string lines: `\\…` to end of line → `.string`.
    backslash_string: bool = false,
    /// Only treat `line_comment` as a comment at line start or after
    /// whitespace (so bash `#` doesn't fire inside `${#x}` or `a#b`).
    line_comment_boundary: bool = false,
};

fn tokenizeSpec(alloc: std.mem.Allocator, toks: *std.ArrayList(Token), src: []const u8, spec: LangSpec) !void {
    var i: usize = 0;
    var text_start: usize = 0;
    while (i < src.len) {
        const c = src[i];

        if (spec.line_comment.len > 0 and startsWith(src, i, spec.line_comment) and
            (!spec.line_comment_boundary or i == 0 or isSpace(src[i - 1])))
        {
            try flush(alloc, toks, src, text_start, i);
            const s = i;
            while (i < src.len and src[i] != '\n') : (i += 1) {}
            try push(alloc, toks, .comment, src[s..i]);
            text_start = i;
            continue;
        }
        if (spec.backslash_string and startsWith(src, i, "\\\\")) {
            try flush(alloc, toks, src, text_start, i);
            const s = i;
            while (i < src.len and src[i] != '\n') : (i += 1) {}
            try push(alloc, toks, .string, src[s..i]);
            text_start = i;
            continue;
        }
        if (spec.block_open.len > 0 and startsWith(src, i, spec.block_open)) {
            try flush(alloc, toks, src, text_start, i);
            const s = i;
            i += spec.block_open.len;
            while (i < src.len and !startsWith(src, i, spec.block_close)) : (i += 1) {}
            if (i < src.len) i += spec.block_close.len;
            try push(alloc, toks, .comment, src[s..i]);
            text_start = i;
            continue;
        }
        if ((spec.double_q and c == '"') or (spec.single_q and c == '\'') or (spec.backtick and c == '`')) {
            try flush(alloc, toks, src, text_start, i);
            const s = i;
            i += 1;
            while (i < src.len) {
                if (src[i] == '\\' and i + 1 < src.len) {
                    i += 2;
                    continue;
                }
                if (src[i] == c) {
                    i += 1;
                    break;
                }
                i += 1;
            }
            try push(alloc, toks, .string, src[s..i]);
            text_start = i;
            continue;
        }
        if (spec.at_builtin and c == '@' and i + 1 < src.len and (isIdentStart(src[i + 1]) or src[i + 1] == '"')) {
            try flush(alloc, toks, src, text_start, i);
            const s = i;
            i += 1;
            while (i < src.len and isIdentChar(src[i])) : (i += 1) {}
            try push(alloc, toks, .builtin, src[s..i]);
            text_start = i;
            continue;
        }
        if (isDigit(c)) {
            try flush(alloc, toks, src, text_start, i);
            const s = i;
            while (i < src.len and isNumberChar(src[i])) : (i += 1) {}
            try push(alloc, toks, .number, src[s..i]);
            text_start = i;
            continue;
        }
        if (isIdentStart(c)) {
            const s = i;
            while (i < src.len and isIdentChar(src[i])) : (i += 1) {}
            const word = src[s..i];
            const kind = classifyWord(spec, word);
            if (kind != .text) {
                try flush(alloc, toks, src, text_start, s);
                try push(alloc, toks, kind, word);
                text_start = i;
            }
            // Plain identifiers stay in the pending text run (text_start
            // unchanged, i already advanced past the word).
            continue;
        }
        if (isOpChar(c)) {
            try flush(alloc, toks, src, text_start, i);
            const s = i;
            while (i < src.len and isOpChar(src[i])) : (i += 1) {}
            try push(alloc, toks, .operator, src[s..i]);
            text_start = i;
            continue;
        }
        if (isPunct(c)) {
            try flush(alloc, toks, src, text_start, i);
            try push(alloc, toks, .punctuation, src[i .. i + 1]);
            i += 1;
            text_start = i;
            continue;
        }
        i += 1; // part of the running text span
    }
    try flush(alloc, toks, src, text_start, src.len);
}

fn classifyWord(spec: LangSpec, word: []const u8) TokenKind {
    for (spec.keywords) |k| {
        if (std.mem.eql(u8, word, k)) return .keyword;
    }
    for (spec.types) |t| {
        if (std.mem.eql(u8, word, t)) return .type;
    }
    for (spec.builtins) |b| {
        if (std.mem.eql(u8, word, b)) return .builtin;
    }
    return .text;
}

// ---- JSON tokenizer ------------------------------------------------------

fn tokenizeJson(alloc: std.mem.Allocator, toks: *std.ArrayList(Token), src: []const u8) !void {
    var i: usize = 0;
    var text_start: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == '"') {
            try flush(alloc, toks, src, text_start, i);
            const s = i;
            i += 1;
            while (i < src.len) {
                if (src[i] == '\\' and i + 1 < src.len) {
                    i += 2;
                    continue;
                }
                if (src[i] == '"') {
                    i += 1;
                    break;
                }
                i += 1;
            }
            // A string immediately followed (after whitespace) by ':' is a
            // property key, else a string value.
            var j = i;
            while (j < src.len and (src[j] == ' ' or src[j] == '\t' or src[j] == '\n' or src[j] == '\r')) : (j += 1) {}
            const kind: TokenKind = if (j < src.len and src[j] == ':') .property else .string;
            try push(alloc, toks, kind, src[s..i]);
            text_start = i;
            continue;
        }
        if (isDigit(c) or (c == '-' and i + 1 < src.len and isDigit(src[i + 1]))) {
            try flush(alloc, toks, src, text_start, i);
            const s = i;
            i += 1;
            while (i < src.len and isNumberChar(src[i])) : (i += 1) {}
            try push(alloc, toks, .number, src[s..i]);
            text_start = i;
            continue;
        }
        if (isIdentStart(c)) {
            const s = i;
            while (i < src.len and isIdentChar(src[i])) : (i += 1) {}
            const word = src[s..i];
            if (std.mem.eql(u8, word, "true") or std.mem.eql(u8, word, "false") or std.mem.eql(u8, word, "null")) {
                try flush(alloc, toks, src, text_start, s);
                try push(alloc, toks, .keyword, word);
                text_start = i;
            }
            continue;
        }
        if (c == '{' or c == '}' or c == '[' or c == ']' or c == ':' or c == ',') {
            try flush(alloc, toks, src, text_start, i);
            try push(alloc, toks, .punctuation, src[i .. i + 1]);
            i += 1;
            text_start = i;
            continue;
        }
        i += 1;
    }
    try flush(alloc, toks, src, text_start, src.len);
}

// ---- HTML / XML tokenizer ------------------------------------------------

fn tokenizeHtml(alloc: std.mem.Allocator, toks: *std.ArrayList(Token), src: []const u8) !void {
    var i: usize = 0;
    var text_start: usize = 0;
    while (i < src.len) {
        if (startsWith(src, i, "<!--")) {
            try flush(alloc, toks, src, text_start, i);
            const s = i;
            i += 4;
            while (i < src.len and !startsWith(src, i, "-->")) : (i += 1) {}
            if (i < src.len) i += 3;
            try push(alloc, toks, .comment, src[s..i]);
            text_start = i;
            continue;
        }
        if (src[i] == '<' and i + 1 < src.len and (isIdentStart(src[i + 1]) or src[i + 1] == '/' or src[i + 1] == '!')) {
            try flush(alloc, toks, src, text_start, i);
            try push(alloc, toks, .punctuation, src[i .. i + 1]); // '<'
            i += 1;
            if (i < src.len and src[i] == '/') {
                try push(alloc, toks, .punctuation, src[i .. i + 1]);
                i += 1;
            }
            const ns = i;
            while (i < src.len and (isIdentChar(src[i]) or src[i] == ':' or src[i] == '-' or src[i] == '!')) : (i += 1) {}
            try push(alloc, toks, .tag, src[ns..i]);
            text_start = i;
            // attributes until '>'
            while (i < src.len and src[i] != '>') {
                const c = src[i];
                if (c == '"' or c == '\'') {
                    try flush(alloc, toks, src, text_start, i);
                    const s = i;
                    i += 1;
                    while (i < src.len and src[i] != c) : (i += 1) {}
                    if (i < src.len) i += 1;
                    try push(alloc, toks, .string, src[s..i]);
                    text_start = i;
                } else if (isIdentStart(c)) {
                    try flush(alloc, toks, src, text_start, i);
                    const s = i;
                    while (i < src.len and (isIdentChar(src[i]) or src[i] == '-' or src[i] == ':')) : (i += 1) {}
                    try push(alloc, toks, .attr, src[s..i]);
                    text_start = i;
                } else if (c == '=' or c == '/') {
                    try flush(alloc, toks, src, text_start, i);
                    try push(alloc, toks, .punctuation, src[i .. i + 1]);
                    i += 1;
                    text_start = i;
                } else {
                    i += 1; // whitespace stays in the pending text run
                }
            }
            if (i < src.len and src[i] == '>') {
                try flush(alloc, toks, src, text_start, i);
                try push(alloc, toks, .punctuation, src[i .. i + 1]);
                i += 1;
                text_start = i;
            }
            continue;
        }
        i += 1;
    }
    try flush(alloc, toks, src, text_start, src.len);
}

// ---- CSS tokenizer -------------------------------------------------------

fn tokenizeCss(alloc: std.mem.Allocator, toks: *std.ArrayList(Token), src: []const u8) !void {
    var i: usize = 0;
    var text_start: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (startsWith(src, i, "/*")) {
            try flush(alloc, toks, src, text_start, i);
            const s = i;
            i += 2;
            while (i < src.len and !startsWith(src, i, "*/")) : (i += 1) {}
            if (i < src.len) i += 2;
            try push(alloc, toks, .comment, src[s..i]);
            text_start = i;
            continue;
        }
        if (c == '"' or c == '\'') {
            try flush(alloc, toks, src, text_start, i);
            const s = i;
            i += 1;
            while (i < src.len and src[i] != c) : (i += 1) {}
            if (i < src.len) i += 1;
            try push(alloc, toks, .string, src[s..i]);
            text_start = i;
            continue;
        }
        if (c == '@') { // at-rule (@media, @import, …)
            try flush(alloc, toks, src, text_start, i);
            const s = i;
            i += 1;
            while (i < src.len and isIdentChar(src[i])) : (i += 1) {}
            try push(alloc, toks, .keyword, src[s..i]);
            text_start = i;
            continue;
        }
        if (isDigit(c) or (c == '.' and i + 1 < src.len and isDigit(src[i + 1]))) {
            try flush(alloc, toks, src, text_start, i);
            const s = i;
            i += 1;
            while (i < src.len and (isNumberChar(src[i]) or src[i] == '%')) : (i += 1) {}
            try push(alloc, toks, .number, src[s..i]);
            text_start = i;
            continue;
        }
        if (isIdentStart(c)) {
            const s = i;
            while (i < src.len and (isIdentChar(src[i]) or src[i] == '-')) : (i += 1) {}
            // property name when the next non-space char is ':'
            var j = i;
            while (j < src.len and isSpace(src[j])) : (j += 1) {}
            if (j < src.len and src[j] == ':') {
                try flush(alloc, toks, src, text_start, s);
                try push(alloc, toks, .property, src[s..i]);
                text_start = i;
            }
            continue;
        }
        if (c == '{' or c == '}' or c == ';' or c == ':' or c == ',' or c == '(' or c == ')') {
            try flush(alloc, toks, src, text_start, i);
            try push(alloc, toks, .punctuation, src[i .. i + 1]);
            i += 1;
            text_start = i;
            continue;
        }
        i += 1;
    }
    try flush(alloc, toks, src, text_start, src.len);
}

// ---- Markdown tokenizer (highlighting markdown *source*) -----------------

fn tokenizeMarkdown(alloc: std.mem.Allocator, toks: *std.ArrayList(Token), src: []const u8) !void {
    var i: usize = 0;
    var text_start: usize = 0;
    var at_line_start = true;
    while (i < src.len) {
        const c = src[i];
        if (at_line_start and (c == '#' or c == '>')) {
            try flush(alloc, toks, src, text_start, i);
            const s = i;
            while (i < src.len and (src[i] == '#' or src[i] == '>' or src[i] == ' ')) : (i += 1) {}
            try push(alloc, toks, .keyword, src[s..i]);
            text_start = i;
            at_line_start = false;
            continue;
        }
        if (c == '`') { // inline code span or fence run
            try flush(alloc, toks, src, text_start, i);
            const s = i;
            while (i < src.len and src[i] == '`') : (i += 1) {}
            const ticks = src[s..i];
            // consume until a matching run of the same length (inline span)
            if (ticks.len < 3) {
                while (i < src.len and !startsWith(src, i, ticks)) : (i += 1) {}
                if (i < src.len) i += ticks.len;
            }
            try push(alloc, toks, .string, src[s..i]);
            text_start = i;
            at_line_start = false;
            continue;
        }
        if (c == '*' or c == '_' or c == '~') {
            try flush(alloc, toks, src, text_start, i);
            const s = i;
            while (i < src.len and (src[i] == '*' or src[i] == '_' or src[i] == '~')) : (i += 1) {}
            try push(alloc, toks, .operator, src[s..i]);
            text_start = i;
            at_line_start = false;
            continue;
        }
        if (c == '[' or c == ']' or c == '(' or c == ')' or c == '!') {
            try flush(alloc, toks, src, text_start, i);
            try push(alloc, toks, .punctuation, src[i .. i + 1]);
            i += 1;
            text_start = i;
            at_line_start = false;
            continue;
        }
        at_line_start = (c == '\n');
        i += 1;
    }
    try flush(alloc, toks, src, text_start, src.len);
}

// ---- shared helpers ------------------------------------------------------

fn push(alloc: std.mem.Allocator, toks: *std.ArrayList(Token), kind: TokenKind, text: []const u8) !void {
    if (text.len == 0) return;
    try toks.append(alloc, .{ .kind = kind, .text = text });
}

fn flush(alloc: std.mem.Allocator, toks: *std.ArrayList(Token), src: []const u8, from: usize, to: usize) !void {
    if (to > from) try push(alloc, toks, .text, src[from..to]);
}

fn startsWith(src: []const u8, i: usize, needle: []const u8) bool {
    if (i + needle.len > src.len) return false;
    return std.mem.eql(u8, src[i .. i + needle.len], needle);
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}
fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}
fn isNumberChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '.' or c == '_';
}
fn isOpChar(c: u8) bool {
    return std.mem.indexOfScalar(u8, "+-*/%=<>!&|^~?", c) != null;
}
fn isPunct(c: u8) bool {
    return std.mem.indexOfScalar(u8, "()[]{};,.:", c) != null;
}
fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

// ---- language specs ------------------------------------------------------

const zig_spec = LangSpec{
    .keywords = &.{
        "const",       "var",         "fn",        "pub",      "return",      "if",
        "else",        "while",       "for",       "switch",   "struct",      "enum",
        "union",       "error",       "try",       "catch",    "defer",       "errdefer",
        "comptime",    "inline",      "test",      "and",      "or",          "orelse",
        "unreachable", "break",       "continue",  "async",    "await",       "suspend",
        "resume",      "nosuspend",   "export",    "extern",   "threadlocal", "usingnamespace",
        "asm",         "volatile",    "align",     "callconv", "noalias",     "opaque",
        "packed",      "linksection", "allowzero", "true",     "false",       "null",
        "undefined",
    },
    .types = &.{
        "void",     "bool",     "type",         "anytype",        "anyopaque",
        "anyerror", "noreturn", "comptime_int", "comptime_float", "i8",
        "i16",      "i32",      "i64",          "i128",           "isize",
        "u8",       "u16",      "u32",          "u64",            "u128",
        "usize",    "f16",      "f32",          "f64",            "f80",
        "f128",     "c_int",    "c_uint",
    },
    .line_comment = "//",
    .double_q = true,
    .single_q = true,
    .at_builtin = true,
    .backslash_string = true,
};

const generic_spec = LangSpec{
    .keywords = &.{
        "if",      "else",      "elif",      "for",       "while",      "do",
        "return",  "break",     "continue",  "function",  "fn",         "def",
        "class",   "struct",    "enum",      "interface", "trait",      "impl",
        "const",   "let",       "var",       "val",       "mut",        "static",
        "public",  "private",   "protected", "internal",  "abstract",   "final",
        "void",    "new",       "delete",    "import",    "export",     "from",
        "package", "namespace", "module",    "using",     "use",        "switch",
        "case",    "default",   "match",     "when",      "where",      "try",
        "catch",   "finally",   "throw",     "throws",    "async",      "await",
        "yield",   "true",      "false",     "null",      "nil",        "none",
        "this",    "self",      "super",     "extends",   "implements", "type",
        "typedef", "then",      "end",       "begin",     "in",         "of",
        "as",      "is",        "and",       "or",        "not",
    },
    .line_comment = "//",
    .block_open = "/*",
    .block_close = "*/",
    .double_q = true,
    .single_q = true,
};

const js_keywords = [_][]const u8{
    "break",    "case",       "catch",  "class",     "const",  "continue",
    "debugger", "default",    "delete", "do",        "else",   "export",
    "extends",  "finally",    "for",    "function",  "if",     "import",
    "in",       "instanceof", "new",    "return",    "super",  "switch",
    "this",     "throw",      "try",    "typeof",    "var",    "void",
    "while",    "with",       "yield",  "let",       "static", "async",
    "await",    "of",         "as",     "from",      "get",    "set",
    "true",     "false",      "null",   "undefined", "NaN",    "Infinity",
};

const js_builtins = [_][]const u8{
    "console", "window",  "document", "Math",   "JSON",    "Object",
    "Array",   "Promise", "String",   "Number", "Boolean", "Symbol",
    "Map",     "Set",     "Date",     "RegExp", "Error",   "globalThis",
};

const ts_extra_keywords = [_][]const u8{
    "interface",  "type",   "enum",    "namespace", "declare",  "abstract",
    "implements", "public", "private", "protected", "readonly", "keyof",
    "infer",      "is",     "asserts", "satisfies", "override", "module",
};

const ts_types = [_][]const u8{
    "string", "number", "boolean", "any", "unknown", "never", "void", "object", "symbol", "bigint",
};

const js_spec = LangSpec{
    .keywords = &js_keywords,
    .builtins = &js_builtins,
    .line_comment = "//",
    .block_open = "/*",
    .block_close = "*/",
    .double_q = true,
    .single_q = true,
    .backtick = true,
};

const ts_spec = LangSpec{
    .keywords = &(js_keywords ++ ts_extra_keywords),
    .builtins = &js_builtins,
    .types = &ts_types,
    .line_comment = "//",
    .block_open = "/*",
    .block_close = "*/",
    .double_q = true,
    .single_q = true,
    .backtick = true,
};

const bash_spec = LangSpec{
    .keywords = &.{
        "if",       "then",   "else",     "elif",    "fi",      "for",
        "while",    "until",  "do",       "done",    "case",    "esac",
        "function", "in",     "select",   "return",  "break",   "continue",
        "local",    "export", "readonly", "declare", "typeset", "unset",
        "shift",    "eval",   "exec",     "source",  "alias",   "set",
        "trap",     "echo",   "printf",   "read",    "cd",      "test",
    },
    .line_comment = "#",
    .line_comment_boundary = true,
    .double_q = true,
    .single_q = true,
    .backtick = true,
};

// ---- tests ---------------------------------------------------------------

const Renderer = @import("renderer.zig").Renderer;
const Writer = std.Io.Writer;

fn renderToBuf(node: *Node, buf: []u8) ![]const u8 {
    var w: Writer = .fixed(buf);
    try Renderer.render(&w, node);
    return w.buffered();
}

test "detectLang maps aliases and falls back" {
    try std.testing.expectEqual(Lang.zig, detectLang("zig"));
    try std.testing.expectEqual(Lang.ts, detectLang("typescript"));
    try std.testing.expectEqual(Lang.js, detectLang("JS"));
    try std.testing.expectEqual(Lang.json, detectLang("json"));
    try std.testing.expectEqual(Lang.plain, detectLang(""));
    try std.testing.expectEqual(Lang.generic, detectLang("cobol"));
    try std.testing.expectEqual(Lang.ts, detectLang("ts title=demo"));
}

test "zig highlight classifies keywords, types, builtins, strings, comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const node = try block(&ctx, "const x: u32 = @intCast(1); // hi", "zig");
    var buf: [1024]u8 = undefined;
    const out = try renderToBuf(node, &buf);

    try std.testing.expect(std.mem.indexOf(u8, out, "<pre><code class=\"language-zig\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-kw\">const</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-type\">u32</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-builtin\">@intCast</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-num\">1</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-com\">// hi</span>") != null);
    // plain identifier `x` is not wrapped in a span
    try std.testing.expect(std.mem.indexOf(u8, out, ">x<") == null);
}

test "highlight escapes html-significant chars inside tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const node = try block(&ctx, "const s = \"a<b&c\";", "zig");
    var buf: [1024]u8 = undefined;
    const out = try renderToBuf(node, &buf);

    try std.testing.expect(std.mem.indexOf(u8, out, "&lt;b&amp;c") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<b&c") == null);
}

test "json highlight distinguishes property keys from string values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const node = try block(&ctx, "{\"name\": \"verve\", \"ok\": true}", "json");
    var buf: [1024]u8 = undefined;
    const out = try renderToBuf(node, &buf);

    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-prop\">\"name\"</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-str\">\"verve\"</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-kw\">true</span>") != null);
}

test "empty lang renders plain code with no spans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const node = try block(&ctx, "const x = 1;", "");
    var buf: [256]u8 = undefined;
    const out = try renderToBuf(node, &buf);
    try std.testing.expectEqualStrings("<pre><code>const x = 1;</code></pre>", out);
}

test "js highlight classifies keywords, builtins, template strings, comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const node = try block(&ctx, "const x = `hi`; console.log(x); // note", "js");
    var buf: [1024]u8 = undefined;
    const out = try renderToBuf(node, &buf);

    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-kw\">const</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-str\">`hi`</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-builtin\">console</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-com\">// note</span>") != null);
}

test "ts highlight adds interface keyword and primitive types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const node = try block(&ctx, "interface P { name: string; age: number }", "ts");
    var buf: [1024]u8 = undefined;
    const out = try renderToBuf(node, &buf);

    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-kw\">interface</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-type\">string</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-type\">number</span>") != null);
}

test "bash highlight: keywords, comment boundary, no false comment in word" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const node = try block(&ctx, "for x in a; do echo a#b; done # loop", "bash");
    var buf: [1024]u8 = undefined;
    const out = try renderToBuf(node, &buf);

    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-kw\">for</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-kw\">echo</span>") != null);
    // trailing comment after whitespace IS highlighted
    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-com\"># loop</span>") != null);
    // `a#b` does NOT start a comment (no boundary before #)
    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-com\">#b") == null);
}

test "html highlight: tags, attrs, string values, comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const node = try block(&ctx, "<a href=\"/x\">hi</a><!-- c -->", "html");
    var buf: [1024]u8 = undefined;
    const out = try renderToBuf(node, &buf);

    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-tag\">a</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-attr\">href</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-str\">\"/x\"</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-com\">&lt;!-- c --&gt;</span>") != null);
}

test "css highlight: properties, numbers, at-rules, comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const node = try block(&ctx, "@media x { color: red; width: 10px; } /* c */", "css");
    var buf: [1024]u8 = undefined;
    const out = try renderToBuf(node, &buf);

    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-kw\">@media</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-prop\">color</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-num\">10px</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-com\">/* c */</span>") != null);
}

test "markdown source highlight: headings, emphasis, code spans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const node = try block(&ctx, "# Title\n**bold** and `code`", "md");
    var buf: [1024]u8 = undefined;
    const out = try renderToBuf(node, &buf);

    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-kw\"># </span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-op\">**</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-str\">`code`</span>") != null);
}
