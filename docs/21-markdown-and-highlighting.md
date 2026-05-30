# Markdown & syntax highlighting

Pure-Zig, server-side GFM markdown rendering and code syntax highlighting,
emitted straight into the `Node` tree at SSR time. These replace the usual
third-party `marked` / `markdown-it` + `highlight.js` / `prism` JavaScript
dependencies — zero deps, no client wasm, SEO-friendly, safe by default.

Both features live in `src/core/` and are pure functions over slices + an
explicit allocator, so they also compile to the wasm client target for a
future live-preview path.

## Markdown

```zig
const body = try ctx.markdown(
    \\# Title
    \\
    \\Some **bold** text and a [link](/docs).
    \\
    \\```zig
    \\const x = 1;
    \\```
);
// drop into a page tree
return ctx.article().children(.{body}).build();
```

`ctx.markdown(src)` parses GFM and returns a **fragment `Node`** (tag `""`)
holding the block-level children. `ctx.markdownOpts(src, opts)` takes an
explicit `MarkdownOptions`:

| Option | Default | Effect |
|--------|---------|--------|
| `gfm` | `true` | Tables, task lists, strikethrough, autolinks |
| `highlight` | `true` | Syntax-highlight fenced code with a language hint |
| `base_url` | `null` | (reserved) base for relative URL resolution |

### Supported syntax

CommonMark core: ATX (`#`) and setext headings, paragraphs, `*`/`_` emphasis
and `**`/`__` strong, inline code spans, fenced (```` ``` ````/`~~~`) and
indented code, blockquotes, ordered/unordered (nested) lists, thematic
breaks, links and images, autolinks (`<https://…>`), reference links
(`[text][id]` + `[id]: url`), and backslash escapes.

GFM extensions: tables with per-column alignment, task lists
(`- [ ]` / `- [x]`), strikethrough (`~~…~~`).

> The emphasis parser is a pragmatic subset of CommonMark's delimiter
> algorithm — it covers the common cases (`*em*`, `**strong**`, `***both***`,
> `_`, `~~`) but a few exotic flanking edge cases are not handled.

## Syntax highlighting

```zig
const block = try ctx.codeBlock(zig_source, "zig");
// → <pre><code class="language-zig">…<span class="tok-kw">const</span>…</code></pre>
```

`ctx.codeBlock(src, lang)` (and `verve.highlight`) build a highlighted
`<pre><code>` block. Markdown fenced code calls the same engine. `lang` is the
info-string hint; an unknown hint falls back to a generic tokenizer and `""`
renders plain (no highlighting).

> `ctx.codeBlock(src, lang)` is distinct from `ctx.code(text)`, which is an
> inline `<code>` element.

First-class languages: **Zig, JavaScript/TypeScript, JSON, HTML/XML, CSS,
Bash**, plus Markdown source and a generic fallback.

### Token classes (stable contract)

Each token is a `<span class="tok-…">`; plain runs are bare (escaped) text.
These class names are a **public contract** and will not be renamed:

```
tok-kw tok-str tok-num tok-com tok-op tok-punc tok-builtin
tok-type tok-attr tok-tag tok-prop tok-regex tok-esc
```

Include the bundled light/dark theme (keyed on those classes):

```zig
ctx.style(verve.highlightThemeCss)
```

Or copy it into your own stylesheet and restyle the `tok-*` classes.

## Security model

Markdown rendering is **safe by default** — user-authored content can be
rendered without an extra sanitizer pass:

- **Text** is escaped by the renderer (the framework's single `escapeHtml`).
  Markdown emits a real `Node` tree, never raw HTML, so there is no second
  escaper to get wrong.
- **URLs** (link `href`, image `src`, autolinks) pass through
  `verve.sanitizeUrl`. Only `http`, `https`, `mailto`, `tel`, and
  scheme-less (relative / root-relative / fragment / query) URLs are allowed;
  `javascript:`, `vbscript:`, `data:`, `file:` and control-character bypasses
  (`java&Tab;script:`) are rejected. A rejected link keeps its visible text;
  a rejected image falls back to its alt text.
- **Raw HTML in the source is stripped**, not passed through. There is no
  allowlist in this version. If you deliberately want raw HTML, use
  `ctx.raw(bytes)` outside markdown.

`verve.sanitizeUrl(url)` is exported standalone for reuse.

## Public API

| Symbol | Meaning |
|--------|---------|
| `ctx.markdown(src)` / `verve.markdown(alloc, ctx, src, opts)` | GFM → `Node` fragment |
| `ctx.markdownOpts(src, opts)` | markdown with explicit options |
| `verve.MarkdownOptions` | options struct |
| `ctx.codeBlock(src, lang)` / `verve.highlight(ctx, src, lang)` | highlighted `<pre><code>` |
| `verve.HighlightLang`, `verve.detectLang(info)` | language enum + info-string mapping |
| `verve.highlightThemeCss` | bundled light/dark token theme |
| `verve.sanitizeUrl(url)` | URL scheme allowlist filter |

## Example

`examples/markdown/` renders a full GFM document (headings, lists, a table, a
task list, blockquotes, and highlighted Zig + TypeScript code) and includes
the theme — a drop-in replacement for a JS markdown stack. Build and run:

```sh
cd examples/markdown
zig build run
```

## Next

- [02 — Components](02-components.md) — `Node`, `Context`, factories.
- [13 — Security](13-security.md) — escaping, CSP, the broader threat model.
- [Index](README.md) — full doc tree.
