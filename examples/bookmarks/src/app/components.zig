const verve = @import("verve");
const api = @import("api.zig");

fn nav(ctx: *const verve.Context) *verve.Node {
    return ctx.nav().children(.{
        ctx.a("/", "Bookmarks"),
        ctx.a("/stats", "Stats"),
        ctx.a("/metrics", "Server /metrics"),
    });
}

pub fn index(ctx: *const verve.Context, items: anytype) !*verve.Node {
    const root = ctx.main_().children(.{
        nav(ctx),
        ctx.h1("Bookmarks"),
        ctx.p().text("Add a link, then click to visit it. Visit counts are tracked server-side and shown in the rightmost column."),
        ctx.form(.{ .post = "/api/addBookmark", .class = "add" }).children(.{
            ctx.input().name("title").type_("text").placeholder("Title").required().attr("maxlength", "120"),
            ctx.input().name("url").type_("url").placeholder("https://example.com").required().attr("maxlength", "500"),
            ctx.button("Add").type_("submit"),
        }),
    });

    if (items.len == 0) {
        _ = root.children(.{ ctx.div().class("empty").text("No bookmarks yet — add one above.") });
    } else {
        const list = ctx.ul().class("bookmarks");
        for (items) |entry| {
            // Title link wired through /api/recordVisit so visit counts
            // accrue server-side. Anchor target is _blank so the page
            // stays put while counts update.
            _ = list.children(.{
                ctx.li().children(.{
                    ctx.div().class("bm-link").children(.{
                        ctx.a(entry.url, entry.title).attr("target", "_blank"),
                        ctx.div().class("bm-url").text(entry.url),
                    }),
                    ctx.span().class("bm-visits").textInt(entry.visits),
                    ctx.form(.{ .post = "/api/removeBookmark" }).children(.{
                        ctx.input().type_("hidden").name("index").attrFmt("value", "{d}", .{entry.index}),
                        ctx.button("Remove").type_("submit").class("danger"),
                    }),
                }),
            });
        }
        _ = root.children(.{list});
    }

    return root.build();
}

pub fn stats(ctx: *const verve.Context, total_bookmarks: usize, total_visits: u64) !*verve.Node {
    return ctx.main_().children(.{
        nav(ctx),
        ctx.h1("App stats"),
        ctx.p().text("Server-side aggregates exposed alongside the framework's /metrics JSON."),
        ctx.div().class("stats").children(.{
            ctx.div().class("stat").children(.{
                ctx.div().class("stat-label").text("Bookmarks"),
                ctx.div().class("stat-value").textInt(total_bookmarks),
            }),
            ctx.div().class("stat").children(.{
                ctx.div().class("stat-label").text("Total visits"),
                ctx.div().class("stat-value").textInt(total_visits),
            }),
        }),
        ctx.p().text("Click 'Server /metrics' in the nav above to see per-route latency histograms from the framework itself."),
    }).build();
}

pub fn notFound(ctx: *const verve.Context, path: []const u8) !*verve.Node {
    return ctx.main_().children(.{
        ctx.h1("404 — Not Found"),
        ctx.p().children(.{
            ctx.span().text("No route for "),
            ctx.code(path),
        }),
        ctx.p().children(.{ ctx.a("/", "← Home") }),
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
        ctx.p().children(.{ ctx.a("/", "← Home") }),
    }).build();
}

pub fn page(ctx: *const verve.Context, body: *verve.Node) !*verve.Node {
    return ctx.el("html").children(.{
        ctx.el("head").children(.{
            ctx.meta("charset", "utf-8"),
            ctx.title("Verve Bookmarks"),
            ctx.style(
                \\body{font:16px system-ui;margin:0;background:#0e0e10;color:#f5f5f5}
                \\main{max-width:48rem;margin:2rem auto;padding:0 1.5rem}
                \\nav{display:flex;gap:1rem;margin-bottom:1.5rem}
                \\nav a{color:#58a6ff;text-decoration:none;padding:.25rem .5rem;border-radius:4px}
                \\nav a:hover{background:#1c1c1f}
                \\h1{margin-top:0}
                \\form.add{display:grid;grid-template-columns:1fr 2fr auto;gap:.5rem;margin:1rem 0}
                \\input{font:inherit;padding:.5rem;background:#1c1c1f;color:inherit;border:1px solid #333;border-radius:4px}
                \\button{font:inherit;padding:.5rem 1rem;background:#1f6feb;color:#fff;border:0;border-radius:4px;cursor:pointer}
                \\button.danger{background:#5b2727}
                \\button.ghost{background:transparent;color:#58a6ff;padding:.25rem .5rem}
                \\button:hover{filter:brightness(1.15)}
                \\.bookmarks{list-style:none;padding:0;margin:1.5rem 0}
                \\.bookmarks li{display:flex;align-items:center;gap:.75rem;padding:.75rem 0;border-bottom:1px solid #222}
                \\.bookmarks li:last-child{border-bottom:0}
                \\.bm-link{flex:1;min-width:0}
                \\.bm-link a{color:#58a6ff;text-decoration:none;display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
                \\.bm-link a:hover{text-decoration:underline}
                \\.bm-url{color:#666;font-size:.85em;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
                \\.bm-visits{color:#999;font-variant-numeric:tabular-nums;width:5rem;text-align:right}
                \\.empty{padding:2rem;text-align:center;color:#888;border:1px dashed #333;border-radius:8px}
                \\.stats{display:grid;grid-template-columns:repeat(2, 1fr);gap:1rem;margin:1.5rem 0}
                \\.stat{padding:1rem;background:#15151a;border:1px solid #333;border-radius:8px}
                \\.stat-label{color:#888;font-size:.85em}
                \\.stat-value{font-size:2rem;font-weight:600;margin:.25rem 0;font-variant-numeric:tabular-nums}
            ),
        }),
        ctx.el("body").children(.{body}),
    }).build();
}
