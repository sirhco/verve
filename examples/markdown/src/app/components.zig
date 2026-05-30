const verve = @import("verve");

/// A representative markdown document exercising headings, lists, tables,
/// task lists, blockquotes, links, and fenced code in several languages.
const sample =
    \\# Verve Markdown
    \\
    \\Rendered **server-side** by `ctx.markdown(...)` — no `marked`, no
    \\`highlight.js`, no JavaScript at all. Just *pure Zig*.
    \\
    \\## Features
    \\
    \\- GFM headings, lists, and ~~strikethrough~~
    \\- Tables with alignment
    \\- Task lists
    \\- Fenced code with syntax highlighting
    \\- Safe-by-default: `javascript:` URLs and raw HTML are stripped
    \\
    \\### Task list
    \\
    \\- [x] Markdown block parser
    \\- [x] Syntax highlighting
    \\- [ ] Mermaid diagrams (later phase)
    \\
    \\### A table
    \\
    \\| Language | Highlighted | Notes            |
    \\|:---------|:-----------:|-----------------:|
    \\| Zig      | yes         | first-class      |
    \\| TS/JS    | yes         | template strings |
    \\| JSON     | yes         | keys vs values   |
    \\
    \\> Code fences pick up the language from the info string and emit
    \\> stable `tok-*` classes themed by `verve.highlightThemeCss`.
    \\
    \\```zig
    \\const std = @import("std");
    \\pub fn main() void {
    \\    std.debug.print("hello, {s}\n", .{"verve"});
    \\}
    \\```
    \\
    \\```ts
    \\interface User { name: string; age: number }
    \\const greet = (u: User): string => `hi ${u.name}`;
    \\```
    \\
    \\See the [documentation](/docs) for the full feature matrix.
;

pub fn doc(ctx: *const verve.Context) !*verve.Node {
    return ctx.article().class("doc").children(.{
        try ctx.markdown(sample),
    }).build();
}

pub fn page(ctx: *const verve.Context, body: *verve.Node) !*verve.Node {
    return ctx.el("html").children(.{
        ctx.el("head").children(.{
            ctx.meta("charset", "utf-8"),
            ctx.title("Verve Markdown"),
            // Base page chrome.
            ctx.style(
                \\body{font:16px/1.6 system-ui;margin:0;background:#0e0e10;color:#e6e6e6}
                \\.doc{max-width:46rem;margin:2rem auto;padding:0 1.5rem}
                \\h1,h2,h3{line-height:1.25}
                \\a{color:#58a6ff}
                \\code{background:#1c1c1f;padding:.1em .35em;border-radius:4px;font-size:.9em}
                \\pre{background:#161b22;padding:1rem;border-radius:8px;overflow:auto}
                \\pre code{background:none;padding:0}
                \\table{border-collapse:collapse;width:100%}
                \\th,td{border:1px solid #30363d;padding:.4rem .6rem}
                \\blockquote{border-left:3px solid #30363d;margin:1rem 0;padding:.2rem 1rem;color:#9aa0a6}
                \\.task-list-item{list-style:none}
            ),
            // The bundled syntax-highlighting theme (light + dark).
            ctx.style(verve.highlightThemeCss),
        }),
        ctx.el("body").children(.{body}),
    }).build();
}

pub fn notFound(ctx: *const verve.Context, path: []const u8) !*verve.Node {
    return ctx.main_().children(.{
        ctx.h1("404 — Not Found"),
        ctx.p().children(.{ ctx.span().text("No route for "), ctx.code(path) }),
        ctx.p().children(.{ctx.a("/", "← Home")}),
    }).build();
}

pub fn errorPage(
    ctx: *const verve.Context,
    status_code: u16,
    status_text: []const u8,
    message: []const u8,
) !*verve.Node {
    return ctx.main_().children(.{
        ctx.el("h1").textFmt("{d} — {s}", .{ status_code, status_text }),
        ctx.p().text(message),
        ctx.p().children(.{ctx.a("/", "← Home")}),
    }).build();
}
