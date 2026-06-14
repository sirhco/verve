const verve = @import("verve");
const api = @import("api.zig");

pub fn poll(ctx: *const verve.Context) !*verve.Node {
    var totals: u64 = 0;
    var loads: [api.CANDIDATES.len]u32 = undefined;
    for (&api.tallies, &loads) |*v, *out| {
        out.* = v.load(.monotonic);
        totals += out.*;
    }

    const root = ctx.main_().attrFmt("data-tick", "{d}", .{api.last_count.load(.monotonic)}).children(.{
        ctx.h1("Indentation showdown"),
        ctx.p().class("question").text("Pick your favorite. Page auto-refreshes on every vote across all browsers."),
    });

    for (api.CANDIDATES, loads, 0..) |label, votes, idx| {
        const pct: u32 = if (totals == 0) 0 else @intCast((@as(u64, votes) * 100) / totals);
        _ = root.children(.{
            ctx.div().class("row").children(.{
                ctx.span().class("label").text(label),
                ctx.div().class("bar").children(.{
                    ctx.span().attrFmt("style", "width:{d}%", .{pct}),
                }),
                ctx.span().class("tally").textFmt("{d} ({d}%)", .{ votes, pct }),
                ctx.actionForm(.{ .post = "/api/vote", .class = "vote" }).children(.{
                    ctx.input().type_("hidden").name("candidate").attrFmt("value", "{d}", .{idx}),
                    ctx.button("Vote").type_("submit"),
                }),
            }),
        });
    }

    _ = root.children(.{
        ctx.p().class("muted").textFmt("Total votes: {d}", .{totals}),
        ctx.actionForm(.{ .post = "/api/resetTallies", .class = "actions" }).children(.{
            ctx.button("Reset tallies").type_("submit").class("danger"),
        }),
        ctx.el("script").text(
            \\(()=>{const tick=Number(document.body.dataset.tick||0);const es=new EventSource('/events');es.addEventListener('count',(e)=>{const v=Number(e.data);if(!Number.isNaN(v)&&v!==tick){location.reload();}});})();
        ),
    });

    return root.build();
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
            ctx.title("Verve Poll"),
            ctx.style(
                \\body{font:16px system-ui;margin:0;background:#0e0e10;color:#f5f5f5}
                \\main{max-width:36rem;margin:3rem auto;padding:0 1.5rem}
                \\h1{margin-top:0}
                \\.question{font-size:1.25rem;margin:1rem 0 1.5rem}
                \\.row{display:flex;align-items:center;gap:1rem;padding:.75rem 0;border-bottom:1px solid #222}
                \\.row:last-of-type{border-bottom:0}
                \\.label{flex:1;font-weight:600}
                \\.bar{flex:2;height:.5rem;background:#1c1c1f;border-radius:4px;overflow:hidden}
                \\.bar > span{display:block;height:100%;background:#1f6feb;transition:width .25s ease}
                \\.tally{width:5rem;text-align:right;font-variant-numeric:tabular-nums;color:#bbb}
                \\form.vote{display:inline}
                \\button{font:inherit;padding:.4rem .9rem;background:#1f6feb;color:#fff;border:0;border-radius:4px;cursor:pointer}
                \\button.danger{background:#5b2727}
                \\button:hover{filter:brightness(1.15)}
                \\.actions{display:flex;justify-content:flex-end;margin-top:1rem}
                \\.muted{color:#888;font-size:.9em}
            ),
        }),
        ctx.el("body").children(.{body}),
    }).build();
}
