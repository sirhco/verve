//! Demonstrates:
//!   - verve.Context (full surface)
//!   - verve.link, verve.LinkOpts (SPA navigation)
//!   - ctx.setTitle, ctx.setTitleIfUnset, ctx.metaTag, ctx.linkTag, ctx.jsonLd
//!   - ctx.head + verve.Head + verve.HeadMeta + verve.HeadLink (raw drain)
//!   - ctx.assetHref (hashed asset URLs — falls through to raw when no manifest)
//!   - ctx.location, Location.isActive (nav highlighting)
//!   - verve.Renderer (handled by framework when serializing)

const std = @import("std");
const verve = @import("verve");
const i18n = @import("i18n.zig");

/// Top-level shell: drains ctx.head, injects design tokens, mounts the
/// nav header and the framework's /verve.js bridge. Pages call this
/// last with their body subtree.
pub fn page(ctx: *const verve.Context, body: *verve.Node) !*verve.Node {
    try ctx.setTitleIfUnset("Verve Showcase");

    var aw: std.Io.Writer.Allocating = .init(ctx.alloc());
    try ctx.head.?.render(&aw.writer);
    const head_html = aw.written();

    const locale = i18n.resolve(ctx) catch "en";

    return ctx.el("html").attr("lang", locale).children(.{
        ctx.el("head").children(.{
            ctx.raw(head_html),
            ctx.style(tokens_css),
            ctx.style(app_css),
        }),
        ctx.el("body").children(.{
            shellHeader(ctx, locale),
            ctx.main_().class("shell-main").children(.{ body }),
            shellFooter(ctx, locale),
            ctx.script("/verve.js"),
        }),
    }).build();
}

fn shellHeader(ctx: *const verve.Context, locale: []const u8) *verve.Node {
    return ctx.el("header").class("shell-header").children(.{
        ctx.div().class("shell-header-inner").children(.{
            ctx.div().class("shell-brand").children(.{
                ctx.a("/", "Verve").class("shell-brand-link"),
                ctx.span().class("shell-brand-tag").text("showcase"),
            }),
            ctx.nav().class("shell-nav").children(.{
                verve.link(ctx, "/",      i18n.t(locale, "ui.home"),    .{ .prefetch_on_hover = true }),
                verve.link(ctx, "/blog",  i18n.t(locale, "ui.blog"),    .{ .prefetch_on_hover = true }),
                verve.link(ctx, "/app",   i18n.t(locale, "ui.tracker"), .{}),
                verve.link(ctx, "/admin", i18n.t(locale, "ui.admin"),   .{}),
            }),
            localePicker(ctx, locale),
        }),
    });
}

fn shellFooter(ctx: *const verve.Context, locale: []const u8) *verve.Node {
    _ = locale;
    return ctx.el("footer").class("shell-footer").children(.{
        ctx.span().text("Verve showcase · pure Zig · "),
        ctx.a("/health", "/health"),
        ctx.span().text(" · "),
        ctx.a("/metrics", "/metrics"),
        ctx.span().text(" · "),
        ctx.a("/blog/rss.xml", "RSS"),
        ctx.span().text(" · "),
        ctx.a("/blog/sitemap.xml", "Sitemap"),
    });
}

fn localePicker(ctx: *const verve.Context, current: []const u8) *verve.Node {
    const make = struct {
        fn item(c: *const verve.Context, code: []const u8, label: []const u8, active: bool) *verve.Node {
            const n = verve.link(c, code_href(code), label, .{});
            if (active) _ = n.class("locale-active");
            return n;
        }
        fn code_href(code: []const u8) []const u8 {
            // Locale cookie set via /admin/settings. Pre-Phase D the
            // path-prefix form (/blog/<lang>/...) also flips locale.
            return switch (code[0]) {
                'e' => if (code[1] == 'n') "/?lang=en" else "/?lang=es",
                'f' => "/?lang=fr",
                else => "/",
            };
        }
    };
    return ctx.div().class("shell-locale").children(.{
        make.item(ctx, "en", "EN", std.mem.eql(u8, current, "en")),
        make.item(ctx, "es", "ES", std.mem.eql(u8, current, "es")),
        make.item(ctx, "fr", "FR", std.mem.eql(u8, current, "fr")),
    });
}

/// CSS variables defining the design system. Lives inline in the
/// shell so apps that strip --public-dir still get the styling.
const tokens_css =
    \\:root{
    \\  --bg:#0e0e10;--surface:#16161a;--surface-2:#1c1c22;--surface-3:#22222a;
    \\  --border:#28282e;--border-strong:#3a3a44;
    \\  --ink:#f5f5f7;--ink-mute:#b1b1ba;--ink-soft:#80808c;
    \\  --accent:#1f6feb;--accent-soft:#1f6feb22;--accent-strong:#388bfd;
    \\  --ok:#2ea043;--ok-soft:#2ea04322;
    \\  --warn:#d29922;--warn-soft:#d2992222;
    \\  --err:#f85149;--err-soft:#f8514922;
    \\  --radius:8px;--radius-sm:4px;--radius-lg:12px;
    \\  --space-1:.25rem;--space-2:.5rem;--space-3:.75rem;--space-4:1rem;--space-5:1.25rem;--space-6:1.5rem;--space-8:2rem;--space-10:2.5rem;--space-12:3rem;
    \\  --shadow-1:0 1px 0 rgba(255,255,255,.04),0 1px 2px rgba(0,0,0,.4);
    \\  --shadow-2:0 4px 16px rgba(0,0,0,.5);
    \\  --font-sans:ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
    \\  --font-mono:ui-monospace,"JetBrains Mono",Menlo,Consolas,monospace;
    \\  --type-fs-xs:.75rem;--type-fs-sm:.875rem;--type-fs-md:1rem;--type-fs-lg:1.125rem;--type-fs-xl:1.4rem;--type-fs-2xl:2rem;
    \\  --leading:1.55;
    \\}
;

/// App-level layout + component CSS — uses only the tokens above.
const app_css =
    \\*{box-sizing:border-box}
    \\html,body{margin:0;padding:0}
    \\body{font:var(--type-fs-md)/var(--leading) var(--font-sans);background:var(--bg);color:var(--ink);min-height:100vh;display:flex;flex-direction:column}
    \\code,pre{font-family:var(--font-mono);font-size:.92em}
    \\code{background:var(--surface-2);padding:0 var(--space-1);border-radius:var(--radius-sm)}
    \\pre{background:var(--surface-2);padding:var(--space-4);border-radius:var(--radius);overflow:auto}
    \\a{color:var(--accent-strong);text-decoration:none}
    \\a:hover{text-decoration:underline}
    \\h1,h2,h3,h4{line-height:1.2;margin:0 0 var(--space-3)}
    \\h1{font-size:var(--type-fs-2xl);font-weight:700;letter-spacing:-.01em}
    \\h2{font-size:var(--type-fs-xl);font-weight:600}
    \\h3{font-size:var(--type-fs-lg);font-weight:600;color:var(--ink-mute)}
    \\hr{border:0;border-top:1px solid var(--border);margin:var(--space-6) 0}
    \\.shell-header{position:sticky;top:0;z-index:50;background:rgba(14,14,16,.85);backdrop-filter:blur(10px);border-bottom:1px solid var(--border)}
    \\.shell-header-inner{max-width:80rem;margin:0 auto;padding:var(--space-3) var(--space-6);display:flex;align-items:center;gap:var(--space-6)}
    \\.shell-brand{display:flex;align-items:baseline;gap:var(--space-2)}
    \\.shell-brand-link{color:var(--ink);font-weight:700;font-size:var(--type-fs-lg)}
    \\.shell-brand-link:hover{text-decoration:none;color:var(--accent-strong)}
    \\.shell-brand-tag{color:var(--ink-soft);font-size:var(--type-fs-xs);text-transform:uppercase;letter-spacing:.1em}
    \\.shell-nav{flex:1;display:flex;gap:var(--space-2)}
    \\.shell-nav a{padding:var(--space-2) var(--space-3);border-radius:var(--radius-sm);color:var(--ink-mute);font-weight:500;font-size:var(--type-fs-sm);transition:background .15s,color .15s}
    \\.shell-nav a:hover{background:var(--surface-2);color:var(--ink);text-decoration:none}
    \\.shell-nav a[aria-current=page]{background:var(--accent-soft);color:var(--accent-strong)}
    \\.shell-locale{display:flex;gap:var(--space-1);font-size:var(--type-fs-xs)}
    \\.shell-locale a{padding:var(--space-1) var(--space-2);border-radius:var(--radius-sm);color:var(--ink-soft);font-weight:600;letter-spacing:.06em}
    \\.shell-locale a:hover{background:var(--surface-2);color:var(--ink);text-decoration:none}
    \\.shell-locale a.locale-active{background:var(--accent-soft);color:var(--accent-strong)}
    \\.shell-main{flex:1;max-width:80rem;width:100%;margin:0 auto;padding:var(--space-8) var(--space-6)}
    \\.shell-footer{max-width:80rem;width:100%;margin:0 auto;padding:var(--space-4) var(--space-6);border-top:1px solid var(--border);color:var(--ink-soft);font-size:var(--type-fs-sm)}
    \\.shell-footer a{color:var(--ink-mute)}
    \\.card{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);padding:var(--space-5);transition:border-color .15s,transform .15s}
    \\.card.hoverable:hover{border-color:var(--border-strong);transform:translateY(-1px)}
    \\.card-head{padding:var(--space-3) var(--space-5);border-bottom:1px solid var(--border);display:flex;align-items:center;justify-content:space-between;margin:calc(-1*var(--space-5)) calc(-1*var(--space-5)) var(--space-4)}
    \\.card-head h2,.card-head h3{margin:0}
    \\.badge{display:inline-flex;align-items:center;gap:var(--space-1);font-size:var(--type-fs-xs);font-weight:600;padding:var(--space-1) var(--space-2);border-radius:var(--radius-sm);text-transform:uppercase;letter-spacing:.06em;border:1px solid transparent}
    \\.badge.info{background:var(--accent-soft);color:var(--accent-strong);border-color:var(--accent-soft)}
    \\.badge.ok{background:var(--ok-soft);color:var(--ok);border-color:var(--ok-soft)}
    \\.badge.warn{background:var(--warn-soft);color:var(--warn);border-color:var(--warn-soft)}
    \\.badge.err{background:var(--err-soft);color:var(--err);border-color:var(--err-soft)}
    \\.badge.muted{background:var(--surface-2);color:var(--ink-soft);border-color:var(--border)}
    \\.grid{display:grid;gap:var(--space-4)}
    \\.grid-2{grid-template-columns:repeat(auto-fit,minmax(20rem,1fr))}
    \\.grid-3{grid-template-columns:repeat(auto-fit,minmax(16rem,1fr))}
    \\.row{display:flex;align-items:center;gap:var(--space-3);flex-wrap:wrap}
    \\.muted{color:var(--ink-soft)}
    \\.kpi{display:flex;flex-direction:column;gap:var(--space-2);padding:var(--space-4);background:var(--surface);border:1px solid var(--border);border-radius:var(--radius)}
    \\.kpi-label{font-size:var(--type-fs-xs);color:var(--ink-soft);text-transform:uppercase;letter-spacing:.08em}
    \\.kpi-value{font-size:var(--type-fs-2xl);font-weight:700;color:var(--ink)}
    \\.kpi-delta{font-size:var(--type-fs-xs);color:var(--ok)}
    \\.alert{padding:var(--space-3) var(--space-4);border:1px solid var(--border);border-radius:var(--radius);background:var(--surface);display:flex;align-items:start;gap:var(--space-3)}
    \\.alert.info{border-color:var(--accent-soft);background:var(--accent-soft)}
    \\.alert.warn{border-color:var(--warn-soft);background:var(--warn-soft)}
    \\.alert.err{border-color:var(--err-soft);background:var(--err-soft)}
    \\.crumb{display:flex;gap:var(--space-2);color:var(--ink-soft);font-size:var(--type-fs-sm);margin-bottom:var(--space-4)}
    \\.crumb a{color:var(--ink-mute)}
    \\.crumb-sep{color:var(--border-strong)}
    \\.avatar{display:inline-flex;align-items:center;justify-content:center;width:1.75rem;height:1.75rem;border-radius:50%;background:linear-gradient(135deg,#1f6feb,#9333ea);color:#fff;font-size:.7rem;font-weight:700;letter-spacing:.04em}
    \\.btn{font:inherit;display:inline-flex;align-items:center;gap:var(--space-2);padding:var(--space-2) var(--space-4);background:var(--accent);color:#fff;border:0;border-radius:var(--radius-sm);cursor:pointer;font-weight:500;font-size:var(--type-fs-sm);transition:background .15s}
    \\.btn:hover{background:var(--accent-strong);text-decoration:none}
    \\.btn.secondary{background:var(--surface-2);color:var(--ink);border:1px solid var(--border)}
    \\.btn.secondary:hover{background:var(--surface-3);border-color:var(--border-strong)}
    \\.btn.ghost{background:transparent;color:var(--ink-mute);border:1px solid var(--border)}
    \\.btn.ghost:hover{background:var(--surface-2);color:var(--ink)}
    \\.input,.textarea{font:inherit;padding:var(--space-2) var(--space-3);background:var(--surface);color:var(--ink);border:1px solid var(--border);border-radius:var(--radius-sm);width:100%}
    \\.input:focus,.textarea:focus{outline:none;border-color:var(--accent);box-shadow:0 0 0 3px var(--accent-soft)}
    \\.textarea{resize:vertical;min-height:5rem;font-family:inherit}
    \\.hero{padding:var(--space-10) 0 var(--space-6);border-bottom:1px solid var(--border);margin-bottom:var(--space-8)}
    \\.hero h1{font-size:2.4rem;margin-bottom:var(--space-3)}
    \\.hero p.lead{font-size:var(--type-fs-lg);color:var(--ink-mute);max-width:42rem;margin:0}
    \\.tag-row{display:flex;flex-wrap:wrap;gap:var(--space-2);margin:var(--space-4) 0}
    \\.post-meta{display:flex;gap:var(--space-3);color:var(--ink-soft);font-size:var(--type-fs-sm);margin:var(--space-3) 0}
    \\.post-body{font-size:var(--type-fs-md);line-height:1.65;color:var(--ink);max-width:42rem}
    \\.post-body p{margin:0 0 var(--space-4)}
    \\.post-body h1,.post-body h2{margin-top:var(--space-6)}
    \\.empty{padding:var(--space-8);text-align:center;color:var(--ink-soft);border:1px dashed var(--border);border-radius:var(--radius)}
;
