//! Minimal page shell: drains ctx.head, injects a little CSS, mounts the
//! framework's /verve.js bridge, and wraps the page body.

const std = @import("std");
const verve = @import("verve");

pub fn page(ctx: *const verve.Context, body: *verve.Node) !*verve.Node {
    try ctx.setTitleIfUnset("Verve Islands Demo");

    var aw: std.Io.Writer.Allocating = .init(ctx.alloc());
    try ctx.head.?.render(&aw.writer);
    const head_html = aw.written();

    return ctx.el("html").attr("lang", "en").children(.{
        ctx.el("head").children(.{
            ctx.raw(head_html),
            ctx.style(app_css),
        }),
        ctx.el("body").children(.{
            ctx.main_().class("wrap").children(.{ body }),
            ctx.script("/verve.js"),
        }),
    }).build();
}

const app_css =
    \\*{box-sizing:border-box}
    \\body{margin:0;font:16px/1.5 system-ui,sans-serif;background:#0e0e10;color:#f5f5f7}
    \\.wrap{max-width:40rem;margin:0 auto;padding:2rem 1.5rem}
    \\a{color:#388bfd}
    \\h1{font-size:1.8rem}
    \\.counter{display:flex;align-items:center;gap:.75rem;font-size:1.4rem;margin:1.5rem 0}
    \\.counter button{font:inherit;padding:.25rem .9rem;border:0;border-radius:6px;background:#1f6feb;color:#fff;cursor:pointer}
    \\.counter [data-ref=counter-label]{color:#80808c;font-size:1rem}
;
