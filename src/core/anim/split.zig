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
//! Default `chars` splitting is per UTF-8 codepoint, so combining marks
//! and ZWJ emoji split apart. Use `By.graphemes` for extended-grapheme-
//! cluster splitting (UAX#29, computed SSR in Zig via grapheme.zig — no
//! JS): combining marks, ZWJ emoji families, skin-tone modifiers,
//! regional-indicator flags, and Hangul syllables stay whole. Spans need
//! `display:inline-block` in CSS for transforms to apply.
//!
//! RTL/bidi: when `Options.rtl_aware = true`, consecutive codepoints of
//! the same strong direction are grouped into runs; RTL runs are wrapped
//! in `<span dir="rtl">` so the user-agent reorders glyphs within each
//! run while `data-st-i` indices remain logical-order dense across the
//! whole text. Full UAX#9 bidi reordering ACROSS runs (e.g. interleaved
//! LTR/RTL tokens within a single word) remains the browser's
//! responsibility and is not performed server-side.
//!
//! This file depends only on std + node.zig — no descriptor/serializer
//! coupling (the node.zig <-> split.zig file cycle is legal and
//! precedented by route.zig).

const std = @import("std");
const node_mod = @import("../node.zig");
const Node = node_mod.Node;
const grapheme = @import("grapheme.zig");

pub const By = enum {
    chars,
    /// Like `chars` but keeps extended grapheme clusters (combining marks,
    /// ZWJ emoji, skin-tone modifiers, regional-indicator flags, Hangul
    /// syllables) whole — boundaries computed SSR in Zig per UAX#29
    /// (`grapheme.zig` + `grapheme_table.zig`), zero JS.
    graphemes,
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
    /// When true, detect strong bidi direction per codepoint/cluster run
    /// and wrap RTL runs in `<span dir="rtl">` so the browser reorders
    /// glyphs within the run. LTR and neutral runs are unaffected.
    /// Default `false` keeps output byte-identical to the non-RTL path.
    rtl_aware: bool = false,
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

/// Classify the strong Unicode bidi direction of a codepoint.
/// Returns `.rtl` for Hebrew/Arabic blocks, `.ltr` for strong LTR
/// scripts, `.neutral` for punctuation, digits, whitespace, and other
/// weakly-directional characters.
pub const Dir = enum { ltr, rtl, neutral };

pub fn strongDir(cp: u21) Dir {
    return switch (cp) {
        // Strong LTR: Basic Latin letters (A-Z, a-z)
        'A'...'Z', 'a'...'z' => .ltr,
        // Latin Extended
        0x00C0...0x024F => .ltr,
        // Greek and Coptic
        0x0370...0x03FF => .ltr,
        // Cyrillic
        0x0400...0x04FF => .ltr,
        // Syriac (0x0700–074F, before Arabic Supplement 0x0750)
        0x0700...0x074F => .rtl,
        // Arabic Supplement
        0x0750...0x077F => .rtl,
        // Thaana (Maldivian — RTL)
        0x0780...0x07BF => .rtl,
        // N'Ko
        0x07C0...0x07FF => .rtl,
        // Samaritan
        0x0800...0x083F => .rtl,
        // Mandaic
        0x0840...0x085F => .rtl,
        // Arabic Extended-A
        0x08A0...0x08FF => .rtl,
        // Hebrew block
        0x0590...0x05FF => .rtl,
        // Arabic block
        0x0600...0x06FF => .rtl,
        // Hiragana, Katakana
        0x3040...0x30FF => .ltr,
        // CJK Unified Ideographs (treated as LTR for our purposes)
        0x4E00...0x9FFF => .ltr,
        // Hangul syllables
        0xAC00...0xD7AF => .ltr,
        // Hebrew presentation forms
        0xFB1D...0xFB4F => .rtl,
        // Arabic Presentation Forms-A
        0xFB50...0xFDFF => .rtl,
        // Arabic Presentation Forms-B
        0xFE70...0xFEFF => .rtl,
        else => .neutral,
    };
}

/// Resolve the strong direction of a UTF-8 encoded unit (codepoint or
/// grapheme cluster). Returns the direction of the first strong codepoint
/// found, or `.neutral` if none.
fn unitDir(unit: []const u8) Dir {
    var j: usize = 0;
    while (j < unit.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(unit[j]) catch 1;
        const end = @min(j + cp_len, unit.len);
        const cp = std.unicode.utf8Decode(unit[j..end]) catch {
            j = end;
            continue;
        };
        const d = strongDir(cp);
        if (d != .neutral) return d;
        j = end;
    }
    return .neutral;
}

/// Advance one unit from byte offset `start` in `word`, returning the
/// byte offset of the next unit boundary.  When `by_grapheme` is true
/// uses UAX#29 extended-grapheme-cluster boundaries; otherwise advances
/// by one UTF-8 codepoint.
fn nextUnit(word: []const u8, start: usize, by_grapheme: bool) usize {
    if (by_grapheme) return grapheme.nextBoundary(word, start);
    return @min(start + (std.unicode.utf8ByteSequenceLength(word[start]) catch 1), word.len);
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

        if (!opts.rtl_aware) {
            // Fast path: byte-identical to pre-RTL behaviour.
            switch (opts.by) {
                .chars => emitChars(arena, parent, word, opts, idx, false),
                .graphemes => emitChars(arena, parent, word, opts, idx, true),
                .words, .lines => {
                    const w = node_mod.create(arena, "span").class(opts.word_class).text(word);
                    stampIndex(w, opts, "data-st-i", idx);
                    _ = parent.children(w);
                },
                .words_and_chars => {
                    const w = node_mod.create(arena, "span").class(opts.word_class);
                    stampIndex(w, opts, "data-st-w", word_idx);
                    emitChars(arena, w, word, opts, idx, false);
                    _ = parent.children(w);
                },
            }
        } else {
            // RTL-aware path: group units by strong direction and wrap
            // RTL runs in <span dir="rtl">.
            emitRtlAware(arena, parent, word, opts, idx, word_idx);
        }
        if (parent.err != null) return;
    }
}

/// Emit a non-whitespace word slice with RTL-run detection.
///
/// Scan-ahead approach: no per-unit buffer, no fixed cap, no truncation.
/// Starting at byte `j`, determine the run direction from the first unit's
/// strong direction (neutrals attach to the current run per the preceding
/// strong direction, defaulting to LTR at word start per UAX#9 paragraph
/// level).  Scan forward until the direction changes to find `run_end`,
/// then emit the slice `word[run_start..run_end]` directly via
/// `emitChars` or a word span.  Arbitrarily long words are handled with
/// zero fixed-size stack allocation.
///
/// `words_and_chars` + `rtl_aware`: emits ONE `data-st-w` word wrapper
/// per logical (whitespace-delimited) word, with directional `<span
/// dir="rtl">` sub-runs NESTED inside it, so `data-st-w` increments once
/// per logical word regardless of how many direction runs the word
/// contains.
fn emitRtlAware(
    arena: std.mem.Allocator,
    parent: *Node,
    word: []const u8,
    opts: Options,
    idx: *usize,
    word_idx: *usize,
) void {
    const by_grapheme = opts.by == .graphemes;

    // For words_and_chars: create ONE word wrapper for the whole logical
    // word and nest all directional sub-runs inside it.  For all other
    // modes the runs attach directly to `parent`.
    const word_target: *Node = switch (opts.by) {
        .words_and_chars => blk: {
            const w = node_mod.create(arena, "span").class(opts.word_class);
            stampIndex(w, opts, "data-st-w", word_idx);
            _ = parent.children(w);
            break :blk w;
        },
        else => parent,
    };

    var j: usize = 0;
    var prev_strong: Dir = .ltr; // UAX#9 paragraph level default = LTR

    while (j < word.len) {
        const run_start = j;

        // Determine direction of the first unit in this run.
        const first_unit_end = nextUnit(word, j, by_grapheme);
        const first_unit_dir = unitDir(word[run_start..first_unit_end]);
        const run_dir: Dir = if (first_unit_dir != .neutral) blk: {
            prev_strong = first_unit_dir;
            break :blk first_unit_dir;
        } else prev_strong;

        // Scan forward to find where this run ends: stop when we hit a
        // unit whose strong direction differs from run_dir.
        j = first_unit_end;
        while (j < word.len) {
            const unit_end = nextUnit(word, j, by_grapheme);
            const d = unitDir(word[j..unit_end]);
            if (d != .neutral) {
                // Strong direction found — does it match the current run?
                if (d != run_dir) break; // run ends here
                prev_strong = d;
            }
            // neutral or same strong dir: stays in this run
            j = unit_end;
        }

        const run_slice = word[run_start..j];

        // Determine the target for this run's spans.
        const target: *Node = if (run_dir == .rtl) blk: {
            const dir_span = node_mod.create(arena, "span").attr("dir", "rtl");
            _ = word_target.children(dir_span);
            break :blk dir_span;
        } else word_target;

        // Emit spans into target based on opts.by.
        switch (opts.by) {
            .chars => emitChars(arena, target, run_slice, opts, idx, false),
            .graphemes => emitChars(arena, target, run_slice, opts, idx, true),
            .words, .lines => {
                // For word-level splits the whole word is already one
                // non-whitespace token; emit a word span per run segment.
                const w = node_mod.create(arena, "span").class(opts.word_class).text(run_slice);
                stampIndex(w, opts, "data-st-i", idx);
                _ = target.children(w);
            },
            .words_and_chars => {
                // word wrapper already created above; emit chars into target
                // (which is either the dir=rtl span or word_target itself).
                emitChars(arena, target, run_slice, opts, idx, false);
            },
        }
        if (parent.err != null) return;
    }
}

fn emitChars(arena: std.mem.Allocator, parent: *Node, word: []const u8, opts: Options, idx: *usize, by_grapheme: bool) void {
    // utf8ValidateSlice already ran on the whole text — iterate by
    // codepoint length (chars) or extended-grapheme-cluster boundary
    // (graphemes) without re-validating.
    var i: usize = 0;
    while (i < word.len) {
        const end = if (by_grapheme)
            grapheme.nextBoundary(word, i)
        else
            @min(i + (std.unicode.utf8ByteSequenceLength(word[i]) catch 1), word.len);
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

test "graphemes: emoji + skin tone stays one span" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();

    // "a👍🏽b" = 'a', '👍🏽' (thumbs-up + skin tone, 2 codepoints), 'b'.
    // Codepoint split would yield 4 spans; grapheme split yields 3.
    const n = node_mod.create(a, "p").text("a\u{1F44D}\u{1F3FD}b");
    apply(n, .{ .by = .graphemes });
    try testing.expect(n.err == null);
    const wrap = n.children_list.items[0];
    try testing.expectEqual(@as(usize, 3), wrap.children_list.items.len);
    try testing.expectEqualStrings("a", wrap.children_list.items[0].text_content.?);
    try testing.expectEqualStrings("\u{1F44D}\u{1F3FD}", wrap.children_list.items[1].text_content.?);
    try testing.expectEqualStrings("b", wrap.children_list.items[2].text_content.?);
    // aria-label preserves the original text verbatim.
    try testing.expectEqualStrings("a\u{1F44D}\u{1F3FD}b", attrValue(n, "aria-label").?);
}

test "existing aria-label preserved" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    const n = node_mod.create(a, "p").attr("aria-label", "custom").text("hi");
    apply(n, .{});
    try testing.expectEqualStrings("custom", attrValue(n, "aria-label").?);
}

// ---- RTL-aware tests --------------------------------------------------------

test "rtl_aware: strongDir covers expected ranges" {
    // Hebrew
    try testing.expectEqual(Dir.rtl, strongDir(0x05D0)); // alef
    try testing.expectEqual(Dir.rtl, strongDir(0x05E9)); // shin
    // Arabic
    try testing.expectEqual(Dir.rtl, strongDir(0x0627)); // alif
    try testing.expectEqual(Dir.rtl, strongDir(0x0645)); // meem
    // Arabic Supplement
    try testing.expectEqual(Dir.rtl, strongDir(0x0751));
    // Arabic Extended-A
    try testing.expectEqual(Dir.rtl, strongDir(0x08A5));
    // Hebrew presentation forms
    try testing.expectEqual(Dir.rtl, strongDir(0xFB1D));
    // Arabic Presentation Forms-A
    try testing.expectEqual(Dir.rtl, strongDir(0xFB50));
    // Arabic Presentation Forms-B
    try testing.expectEqual(Dir.rtl, strongDir(0xFE70));
    // LTR
    try testing.expectEqual(Dir.ltr, strongDir('A'));
    try testing.expectEqual(Dir.ltr, strongDir('z'));
    // Neutral: space, digit
    try testing.expectEqual(Dir.neutral, strongDir(' '));
    try testing.expectEqual(Dir.neutral, strongDir('5'));
}

test "rtl_aware=false: LTR-only output byte-identical (no dir wrapper)" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();

    // Same string, with and without rtl_aware — output must be structurally
    // identical when text is LTR-only.
    const n1 = node_mod.create(a, "p").text("Hello");
    apply(n1, .{ .by = .chars, .index_attr = true });
    const n2 = node_mod.create(a, "p").text("Hello");
    apply(n2, .{ .by = .chars, .index_attr = true, .rtl_aware = true });

    const wrap1 = n1.children_list.items[0];
    const wrap2 = n2.children_list.items[0];
    // Same child count
    try testing.expectEqual(wrap1.children_list.items.len, wrap2.children_list.items.len);
    // No dir="rtl" spans
    for (wrap2.children_list.items) |ch| {
        try testing.expectEqualStrings("span", ch.tag);
        for (ch.attrs.items) |at| {
            try testing.expect(!std.mem.eql(u8, at.key, "dir"));
        }
    }
}

test "rtl_aware: Hebrew word gets dir=rtl wrapper" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();

    // "שלום" = Hebrew word (4 codepoints, all RTL)
    const n = node_mod.create(a, "p").text("\u{05E9}\u{05DC}\u{05D5}\u{05DD}");
    apply(n, .{ .by = .chars, .rtl_aware = true, .index_attr = true });
    try testing.expect(n.err == null);
    const wrap = n.children_list.items[0];
    // Should have exactly one child: a dir="rtl" span wrapping 4 char spans.
    try testing.expectEqual(@as(usize, 1), wrap.children_list.items.len);
    const dir_span = wrap.children_list.items[0];
    try testing.expectEqualStrings("span", dir_span.tag);
    try testing.expectEqualStrings("rtl", attrValue(dir_span, "dir").?);
    // 4 char spans inside
    try testing.expectEqual(@as(usize, 4), dir_span.children_list.items.len);
    // data-st-i is logical-order dense: 0..3
    for (dir_span.children_list.items, 0..) |ch, k| {
        const val = attrValue(ch, "data-st-i").?;
        var buf: [4]u8 = undefined;
        const expected = std.fmt.bufPrint(&buf, "{d}", .{k}) catch unreachable;
        try testing.expectEqualStrings(expected, val);
    }
}

test "rtl_aware: Arabic run wrapped, LTR run not wrapped" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();

    // "مرحبا" = Arabic word (5 codepoints)
    const n = node_mod.create(a, "p").text("\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}");
    apply(n, .{ .by = .chars, .rtl_aware = true });
    try testing.expect(n.err == null);
    const wrap = n.children_list.items[0];
    try testing.expectEqual(@as(usize, 1), wrap.children_list.items.len);
    const dir_span = wrap.children_list.items[0];
    try testing.expectEqualStrings("rtl", attrValue(dir_span, "dir").?);
    try testing.expectEqual(@as(usize, 5), dir_span.children_list.items.len);
}

test "rtl_aware: mixed LTR then RTL word produces two runs in correct wrapper" {
    // A word that starts LTR then goes RTL (e.g. "Aש" — 'A' Latin, 'ש' Hebrew)
    // Expected: LTR run ('A') emitted directly; RTL run ('ש') wrapped in dir=rtl.
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();

    const n = node_mod.create(a, "p").text("A\u{05E9}");
    apply(n, .{ .by = .chars, .rtl_aware = true });
    try testing.expect(n.err == null);
    const wrap = n.children_list.items[0];
    // 2 children: a plain span (LTR 'A') + a dir=rtl span (Hebrew 'ש')
    try testing.expectEqual(@as(usize, 2), wrap.children_list.items.len);
    const ltr_span = wrap.children_list.items[0];
    try testing.expectEqualStrings("span", ltr_span.tag);
    // LTR span has NO dir attr
    try testing.expect(attrValue(ltr_span, "dir") == null);
    try testing.expectEqualStrings("A", ltr_span.text_content.?);

    const rtl_span = wrap.children_list.items[1];
    try testing.expectEqualStrings("rtl", attrValue(rtl_span, "dir").?);
    try testing.expectEqual(@as(usize, 1), rtl_span.children_list.items.len);
    try testing.expectEqualStrings("\u{05E9}", rtl_span.children_list.items[0].text_content.?);
}

test "rtl_aware: data-st-i logical-order dense across LTR+RTL runs" {
    // "Hi שלום" — 2 LTR chars, space, 4 RTL chars
    // Expected indices: H=0, i=1, (space text node, no idx), ש=2, ל=3, ו=4, ם=5
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();

    const n = node_mod.create(a, "p").text("Hi \u{05E9}\u{05DC}\u{05D5}\u{05DD}");
    apply(n, .{ .by = .chars, .rtl_aware = true, .index_attr = true });
    try testing.expect(n.err == null);
    const wrap = n.children_list.items[0];
    // wrap children: span('H',idx=0), span('i',idx=1), __text__(' '), span[dir=rtl](4 chars, idx 2..5)
    // The LTR run "Hi" has no dir wrapper; chars are direct children.
    // Count: 2 LTR char spans + 1 text node + 1 dir=rtl span = 4
    try testing.expectEqual(@as(usize, 4), wrap.children_list.items.len);

    const h_span = wrap.children_list.items[0];
    try testing.expectEqualStrings("0", attrValue(h_span, "data-st-i").?);
    const i_span = wrap.children_list.items[1];
    try testing.expectEqualStrings("1", attrValue(i_span, "data-st-i").?);
    const space_node = wrap.children_list.items[2];
    try testing.expectEqualStrings("__text__", space_node.tag);
    const rtl_wrap = wrap.children_list.items[3];
    try testing.expectEqualStrings("rtl", attrValue(rtl_wrap, "dir").?);
    const rtl_chars = rtl_wrap.children_list.items;
    try testing.expectEqual(@as(usize, 4), rtl_chars.len);
    try testing.expectEqualStrings("2", attrValue(rtl_chars[0], "data-st-i").?);
    try testing.expectEqualStrings("5", attrValue(rtl_chars[3], "data-st-i").?);
}

test "rtl_aware: graphemes + Hebrew (cluster direction preserved)" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();

    // Hebrew word via grapheme mode — should still wrap in dir=rtl
    const n = node_mod.create(a, "p").text("\u{05E9}\u{05DC}\u{05D5}\u{05DD}");
    apply(n, .{ .by = .graphemes, .rtl_aware = true });
    try testing.expect(n.err == null);
    const wrap = n.children_list.items[0];
    try testing.expectEqual(@as(usize, 1), wrap.children_list.items.len);
    const dir_span = wrap.children_list.items[0];
    try testing.expectEqualStrings("rtl", attrValue(dir_span, "dir").?);
    // 4 grapheme clusters (each Hebrew letter is a single cluster here)
    try testing.expectEqual(@as(usize, 4), dir_span.children_list.items.len);
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

test "rtl_aware: no truncation — RTL word >256 units emits all chars" {
    // Fix 2: prove that a single RTL word of >256 units is fully emitted
    // (no truncation / silent drop at index 256).
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();

    // Build a 300-char Arabic string: U+0627 (alif) repeated 300 times.
    // Each codepoint is 2 UTF-8 bytes, so the word is 600 bytes.
    const alif = "\u{0627}"; // 2-byte UTF-8 encoding of U+0627
    const count = 300;
    const word_text = try a.alloc(u8, alif.len * count);
    for (0..count) |k| {
        @memcpy(word_text[k * alif.len .. (k + 1) * alif.len], alif);
    }

    // Test with .by = .chars
    {
        const n = node_mod.create(a, "p").text(word_text);
        apply(n, .{ .by = .chars, .rtl_aware = true });
        try testing.expect(n.err == null);
        const wrap = n.children_list.items[0];
        // All units inside a single dir=rtl wrapper
        try testing.expectEqual(@as(usize, 1), wrap.children_list.items.len);
        const dir_span = wrap.children_list.items[0];
        try testing.expectEqualStrings("rtl", attrValue(dir_span, "dir").?);
        // Must emit ALL 300 char spans — no truncation at 256
        try testing.expectEqual(@as(usize, count), dir_span.children_list.items.len);
    }

    // Test with .by = .graphemes
    {
        const n2 = node_mod.create(a, "p").text(word_text);
        apply(n2, .{ .by = .graphemes, .rtl_aware = true });
        try testing.expect(n2.err == null);
        const wrap2 = n2.children_list.items[0];
        try testing.expectEqual(@as(usize, 1), wrap2.children_list.items.len);
        const dir_span2 = wrap2.children_list.items[0];
        try testing.expectEqualStrings("rtl", attrValue(dir_span2, "dir").?);
        // Each alif is a single grapheme cluster — still 300 spans
        try testing.expectEqual(@as(usize, count), dir_span2.children_list.items.len);
    }
}

test "rtl_aware: render byte-identity for LTR text (explicit false vs default)" {
    // Fix 3: render-and-compare byte strings to prove rtl_aware=false
    // produces output byte-identical to rtl_aware not set (default false).
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();

    const text = "Hello world";

    const n1 = node_mod.create(a, "p").text(text);
    apply(n1, .{ .by = .chars });

    const n2 = node_mod.create(a, "p").text(text);
    apply(n2, .{ .by = .chars, .rtl_aware = false });

    try testing.expect(n1.err == null);
    try testing.expect(n2.err == null);

    const buf1 = try a.alloc(u8, 4096);
    var w1: std.Io.Writer = .fixed(buf1);
    try Renderer.render(&w1, n1);
    const html1 = w1.buffered();

    const buf2 = try a.alloc(u8, 4096);
    var w2: std.Io.Writer = .fixed(buf2);
    try Renderer.render(&w2, n2);
    const html2 = w2.buffered();

    try testing.expectEqualStrings(html1, html2);
}

test "rtl_aware: pure LTR text emits no dir=rtl wrapper" {
    // Fix 5: rtl_aware=true on pure LTR text must produce zero dir="rtl" spans.
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();

    const n = node_mod.create(a, "p").text("Hello world test");
    apply(n, .{ .by = .chars, .rtl_aware = true });
    try testing.expect(n.err == null);

    // Walk all descendants and assert no span has dir="rtl"
    const wrap = n.children_list.items[0];
    for (wrap.children_list.items) |child| {
        // Direct children: either __text__ nodes or char spans (no dir wrapper)
        if (std.mem.eql(u8, child.tag, "span")) {
            try testing.expect(attrValue(child, "dir") == null);
        }
    }
}

test "rtl_aware: words_and_chars emits ONE data-st-w per logical word" {
    // Fix 4 (option a): a mixed-direction word gets ONE word wrapper,
    // with directional sub-runs nested inside it.
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();

    // "Aש Bמ" — two words, each with one LTR char + one RTL char.
    // Each word must produce exactly ONE data-st-w increment.
    const n = node_mod.create(a, "p").text("A\u{05E9} B\u{05DE}");
    apply(n, .{ .by = .words_and_chars, .rtl_aware = true, .index_attr = true });
    try testing.expect(n.err == null);

    const wrap = n.children_list.items[0];
    // 3 children: word0, __text__(' '), word1
    try testing.expectEqual(@as(usize, 3), wrap.children_list.items.len);

    const word0 = wrap.children_list.items[0];
    try testing.expect(hasAttr(word0, "data-st-w"));
    // word0 should contain: LTR char span 'A' + dir=rtl span containing 'ש'
    try testing.expectEqual(@as(usize, 2), word0.children_list.items.len);
    try testing.expect(attrValue(word0.children_list.items[0], "dir") == null); // LTR, no dir attr
    try testing.expectEqualStrings("rtl", attrValue(word0.children_list.items[1], "dir").?);

    const word1 = wrap.children_list.items[2];
    try testing.expect(hasAttr(word1, "data-st-w"));
    // word1 should contain: LTR char span 'B' + dir=rtl span containing 'מ'
    try testing.expectEqual(@as(usize, 2), word1.children_list.items.len);
    try testing.expect(attrValue(word1.children_list.items[0], "dir") == null);
    try testing.expectEqualStrings("rtl", attrValue(word1.children_list.items[1], "dir").?);
}
