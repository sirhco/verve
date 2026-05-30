//! Default CSS theme for syntax-highlighted code blocks.
//!
//! `core/highlight.zig` emits `<span class="tok-…">` tokens using the stable
//! class names below. This module ships a ready-to-use light/dark theme keyed
//! on those classes; apps include it via `ctx.style(verve.highlightThemeCss)`
//! (or copy it into their own stylesheet). The class names are a public
//! contract — once shipped they are never renamed.
//!
//! Stable token classes:
//!   tok-kw tok-str tok-num tok-com tok-op tok-punc tok-builtin
//!   tok-type tok-attr tok-tag tok-prop tok-regex tok-esc
//! Unclassified text is emitted as bare text nodes (no span), inheriting the
//! surrounding `pre`/`code` color.

/// A self-contained CSS theme. Light by default, dark under
/// `prefers-color-scheme: dark`. Scoped to `pre code` so it only affects
/// highlighted blocks, not inline `<code>`.
pub const css: []const u8 =
    \\pre code{color:#24292e}
    \\pre code .tok-kw{color:#d73a49}
    \\pre code .tok-str{color:#032f62}
    \\pre code .tok-num{color:#005cc5}
    \\pre code .tok-com{color:#6a737d;font-style:italic}
    \\pre code .tok-op{color:#d73a49}
    \\pre code .tok-punc{color:#24292e}
    \\pre code .tok-builtin{color:#6f42c1}
    \\pre code .tok-type{color:#6f42c1}
    \\pre code .tok-attr{color:#6f42c1}
    \\pre code .tok-tag{color:#22863a}
    \\pre code .tok-prop{color:#005cc5}
    \\pre code .tok-regex{color:#032f62}
    \\pre code .tok-esc{color:#e36209}
    \\@media (prefers-color-scheme:dark){
    \\pre code{color:#e1e4e8}
    \\pre code .tok-kw{color:#f97583}
    \\pre code .tok-str{color:#9ecbff}
    \\pre code .tok-num{color:#79b8ff}
    \\pre code .tok-com{color:#6a737d;font-style:italic}
    \\pre code .tok-op{color:#f97583}
    \\pre code .tok-punc{color:#e1e4e8}
    \\pre code .tok-builtin{color:#b392f0}
    \\pre code .tok-type{color:#b392f0}
    \\pre code .tok-attr{color:#b392f0}
    \\pre code .tok-tag{color:#85e89d}
    \\pre code .tok-prop{color:#79b8ff}
    \\pre code .tok-regex{color:#9ecbff}
    \\pre code .tok-esc{color:#ffab70}
    \\}
;

const std = @import("std");

test "theme css is non-empty and defines the keyword token class" {
    try std.testing.expect(css.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, css, ".tok-kw{") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "prefers-color-scheme:dark") != null);
}
