//! UAX#29 extended-grapheme-cluster boundary detection, computed
//! entirely server-side in Zig over the embedded Grapheme_Break property
//! table (`grapheme_table.zig`). Pure table lookup + a small state
//! machine — no allocator, no OS calls, no global mutable state — so it
//! compiles unchanged for native AND wasm32-freestanding (island chunks
//! use it too).
//!
//! `nextBoundary(text, i)` returns the byte index *after* the extended
//! grapheme cluster that starts at byte `i`. Callers iterate:
//!
//!     var i: usize = 0;
//!     while (i < text.len) {
//!         const end = grapheme.nextBoundary(text, i);
//!         // text[i..end] is one grapheme cluster
//!         i = end;
//!     }
//!
//! `text` MUST be valid UTF-8 (split.zig validates the whole string
//! before calling). Invalid bytes are treated as single-byte clusters so
//! the loop always advances.
//!
//! Implements the GB1–GB999 rules for *extended* grapheme clusters:
//!   GB3   CR × LF
//!   GB4   (Control|CR|LF) ÷
//!   GB5   ÷ (Control|CR|LF)
//!   GB6   L × (L|V|LV|LVT)
//!   GB7   (LV|V) × (V|T)
//!   GB8   (LVT|T) × T
//!   GB9   × (Extend|ZWJ)
//!   GB9a  × SpacingMark
//!   GB9b  Prepend ×
//!   GB11  \p{Extended_Pictographic} Extend* ZWJ × \p{Extended_Pictographic}
//!   GB12/GB13  sot (RI RI)* RI × RI   (even-count regional indicators)
//!   GB999 any ÷ any

const std = @import("std");
const table = @import("grapheme_table.zig");
const Prop = table.Prop;

// Comptime sortedness guard: catch any future hand-edit that breaks the
// strictly-ascending, non-overlapping invariant required by the binary
// search in propOf(). Zero runtime / wasm cost.
comptime {
    const r = table.ranges;
    var i: usize = 1;
    while (i < r.len) : (i += 1) {
        if (r[i].lo <= r[i - 1].hi)
            @compileError(std.fmt.comptimePrint(
                "grapheme_table: range[{}] (lo=0x{X:0>4}) is not strictly after range[{}] (hi=0x{X:0>4})",
                .{ i, r[i].lo, i - 1, r[i - 1].hi },
            ));
    }
}

/// Decode one UTF-8 codepoint at `text[i]`. Returns the codepoint and the
/// byte length. Treats malformed bytes as a single-byte U+FFFD-ish unit so
/// callers always advance (split.zig pre-validates, so this is defensive).
fn decode(text: []const u8, i: usize) struct { cp: u32, len: usize } {
    const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return .{ .cp = text[i], .len = 1 };
    if (i + len > text.len) return .{ .cp = text[i], .len = 1 };
    const cp = std.unicode.utf8Decode(text[i .. i + len]) catch return .{ .cp = text[i], .len = 1 };
    return .{ .cp = cp, .len = len };
}

/// Grapheme_Break property of a codepoint via binary search over the
/// sorted range table. Hangul LV/LVT precomposed syllables are split out
/// of the AC00..D7A3 block here (the table stores the whole block as .lv).
pub fn propOf(cp: u32) Prop {
    if (cp >= 0xAC00 and cp <= 0xD7A3) {
        // LV if it's a syllable base (no trailing jamo), else LVT.
        return if ((cp - 0xAC00) % 28 == 0) .lv else .lvt;
    }
    const r = table.ranges;
    var lo: usize = 0;
    var hi: usize = r.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < r[mid].lo) {
            hi = mid;
        } else if (cp > r[mid].hi) {
            lo = mid + 1;
        } else {
            return r[mid].prop;
        }
    }
    return .other;
}

/// Returns the byte index after the grapheme cluster starting at `i`.
/// `i` must be a codepoint boundary and `i < text.len`.
pub fn nextBoundary(text: []const u8, i: usize) usize {
    var pos = i;
    const cur = decode(text, pos);
    var cur_prop = propOf(cur.cp);
    pos += cur.len;

    // Regional-indicator parity: GB12/GB13 break between RI pairs. Track
    // whether the cluster so far is a single (odd) trailing RI.
    var ri_odd = (cur_prop == .regional_indicator);

    // GB11 emoji ZWJ sequence: did the run start \p{ExtPict} (Extend* )?
    // We track "last non-Extend base was Extended_Pictographic" so a ZWJ
    // can extend it to a following Extended_Pictographic.
    var last_was_pictographic = (cur_prop == .extended_pictographic);

    while (pos < text.len) {
        const nxt = decode(text, pos);
        const nxt_prop = propOf(nxt.cp);

        if (!shouldExtend(cur_prop, nxt_prop, last_was_pictographic, ri_odd)) break;

        // Advance over the boundary; update tracking state.
        switch (nxt_prop) {
            .extend, .zwj => {
                // GB9: stays in cluster. last_was_pictographic persists
                // across Extend* but is reset by anything else (handled in
                // the else branch). ZWJ keeps it so GB11 can fire next.
            },
            .regional_indicator => {
                // We only get here when ri_odd was true (GB12/13); the new
                // RI completes a pair, so parity flips to even.
                ri_odd = false;
                last_was_pictographic = false;
            },
            else => {
                ri_odd = (nxt_prop == .regional_indicator);
                last_was_pictographic = (nxt_prop == .extended_pictographic);
            },
        }
        cur_prop = nxt_prop;
        pos += nxt.len;
    }
    return pos;
}

/// Decide whether the boundary between `prev` (current cluster tail) and
/// `next` is suppressed (× = stay together) per UAX#29. Returns true to
/// keep `next` in the same cluster.
fn shouldExtend(prev: Prop, next: Prop, prev_pictographic: bool, ri_odd: bool) bool {
    // GB3: CR × LF
    if (prev == .cr and next == .lf) return true;
    // GB4: (Control|CR|LF) ÷
    if (prev == .control or prev == .cr or prev == .lf) return false;
    // GB5: ÷ (Control|CR|LF)
    if (next == .control or next == .cr or next == .lf) return false;

    // GB6: L × (L|V|LV|LVT)
    if (prev == .l and (next == .l or next == .v or next == .lv or next == .lvt)) return true;
    // GB7: (LV|V) × (V|T)
    if ((prev == .lv or prev == .v) and (next == .v or next == .t)) return true;
    // GB8: (LVT|T) × T
    if ((prev == .lvt or prev == .t) and next == .t) return true;

    // GB9: × (Extend|ZWJ)
    if (next == .extend or next == .zwj) return true;
    // GB9a: × SpacingMark
    if (next == .spacing_mark) return true;
    // GB9b: Prepend ×
    if (prev == .prepend) return true;

    // GB11: \p{ExtPict} Extend* ZWJ × \p{ExtPict}
    if (prev == .zwj and prev_pictographic and next == .extended_pictographic) return true;

    // GB12/GB13: RI × RI when an odd number of RIs precedes (forms a pair)
    if (prev == .regional_indicator and next == .regional_indicator and ri_odd) return true;

    // GB999: otherwise break
    return false;
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

/// Helper: collect cluster byte-lengths by walking nextBoundary.
fn clusters(text: []const u8, buf: [][2]usize) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < text.len) : (n += 1) {
        const end = nextBoundary(text, i);
        buf[n] = .{ i, end };
        i = end;
    }
    return n;
}

test "ab splits into two clusters" {
    var buf: [8][2]usize = undefined;
    const n = clusters("ab", &buf);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("a", "ab"[buf[0][0]..buf[0][1]]);
    try testing.expectEqualStrings("b", "ab"[buf[1][0]..buf[1][1]]);
}

test "combining: e + U+0301 acute is one cluster" {
    const s = "e\u{0301}"; // é (decomposed)
    var buf: [8][2]usize = undefined;
    const n = clusters(s, &buf);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(usize, s.len), buf[0][1]);
}

test "ZWJ family emoji is one cluster" {
    // 👨‍👩‍👧 = man ZWJ woman ZWJ girl
    const s = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    var buf: [16][2]usize = undefined;
    const n = clusters(s, &buf);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(usize, s.len), buf[0][1]);
}

test "skin-tone modifier clusters with base emoji" {
    // 👍🏽 = thumbs up + medium skin tone (U+1F3FD)
    const s = "\u{1F44D}\u{1F3FD}";
    var buf: [8][2]usize = undefined;
    const n = clusters(s, &buf);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(usize, s.len), buf[0][1]);
}

test "regional-indicator flag is one cluster (two RIs)" {
    // 🇺🇸 = RI U + RI S
    const s = "\u{1F1FA}\u{1F1F8}";
    var buf: [8][2]usize = undefined;
    const n = clusters(s, &buf);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(usize, s.len), buf[0][1]);
}

test "two adjacent flags split into two clusters" {
    // 🇺🇸🇬🇧 = US flag + GB flag (four RIs → two clusters)
    const s = "\u{1F1FA}\u{1F1F8}\u{1F1EC}\u{1F1E7}";
    var buf: [8][2]usize = undefined;
    const n = clusters(s, &buf);
    try testing.expectEqual(@as(usize, 2), n);
}

test "CRLF is one cluster" {
    const s = "\r\n";
    var buf: [8][2]usize = undefined;
    const n = clusters(s, &buf);
    try testing.expectEqual(@as(usize, 1), n);
}

test "mixed ascii + emoji + combining" {
    // a 👍🏽 b  → 'a' , ' ' , '👍🏽' , ' ' , 'b'  = 5 clusters
    const s = "a \u{1F44D}\u{1F3FD} b";
    var buf: [16][2]usize = undefined;
    const n = clusters(s, &buf);
    try testing.expectEqual(@as(usize, 5), n);
}

test "Hangul syllable jamo sequence is one cluster" {
    // L V T : U+1100 (L) U+1161 (V) U+11A8 (T)
    const s = "\u{1100}\u{1161}\u{11A8}";
    var buf: [8][2]usize = undefined;
    const n = clusters(s, &buf);
    try testing.expectEqual(@as(usize, 1), n);
}

test "propOf spot checks" {
    try testing.expectEqual(Prop.lf, propOf(0x000A));
    try testing.expectEqual(Prop.cr, propOf(0x000D));
    try testing.expectEqual(Prop.zwj, propOf(0x200D));
    try testing.expectEqual(Prop.extend, propOf(0x0301));
    try testing.expectEqual(Prop.regional_indicator, propOf(0x1F1FA));
    try testing.expectEqual(Prop.extended_pictographic, propOf(0x1F44D));
    try testing.expectEqual(Prop.extend, propOf(0x1F3FD)); // skin tone
    try testing.expectEqual(Prop.other, propOf('a'));
    try testing.expectEqual(Prop.lv, propOf(0xAC00)); // 가 (LV base)
    try testing.expectEqual(Prop.lvt, propOf(0xAC01)); // 각 (LVT)
}

test "U+20E3 keycap combines with base digit (previously-unreachable Extend range)" {
    // "1⃣" = digit one (U+0031) + COMBINING ENCLOSING KEYCAP (U+20E3).
    // U+20E3 is in the 0x20D0..0x20F0 Extend block. Before the sort-order
    // fix it resolved to .other → wrongly broke from the base digit.
    const s = "1\u{20E3}";
    // propOf check: U+20E3 must be .extend
    try testing.expectEqual(Prop.extend, propOf(0x20E3));
    // Cluster check: the whole 4-byte sequence is ONE grapheme cluster.
    var buf: [4][2]usize = undefined;
    const n = clusters(s, &buf);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(usize, s.len), buf[0][1]);
}
