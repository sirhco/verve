# markdown

Server-side **GFM markdown rendering** + **syntax highlighting**, pure-Zig —
a drop-in replacement for a `marked` + `highlight.js` JavaScript stack. The
page renders a markdown document at SSR time via `ctx.markdown(...)`; there is
no client wasm and no JavaScript.

```sh
zig build run
# open http://127.0.0.1:8080
```

## What it shows

- `ctx.markdown(src)` → a safe `Node` subtree: headings, lists, a
  GFM table with alignment, a task list, blockquotes, links, and emphasis.
- Fenced code blocks auto-highlighted (Zig + TypeScript here) into stable
  `tok-*` spans.
- The bundled theme included via `ctx.style(verve.highlightThemeCss)`
  (light/dark).
- Safe-by-default rendering: `javascript:` URLs and raw HTML in the source are
  stripped — try editing `src/app/components.zig` and adding some.

## Files

- `src/app/components.zig` — the markdown source string, the page shell, and
  the theme include.
- `src/app/routes.zig` — a single `/` route.
- `src/app/api.zig` — wires `components` / `routes` for the framework server.

See [`docs/21-markdown-and-highlighting.md`](../../docs/21-markdown-and-highlighting.md)
for the full feature matrix and security model.
