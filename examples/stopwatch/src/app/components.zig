const verve = @import("verve");

pub fn stopwatch(ctx: *const verve.Context) !*verve.Node {
    return ctx.main_().children(.{
        ctx.h1("Stopwatch"),
        ctx.div().class("display").bind("display").text("00:00.000"),
        ctx.div().class("controls").children(.{
            ctx.button("Start").onClick("start_stopwatch"),
            ctx.button("Stop").onClick("stop_stopwatch"),
            ctx.button("Reset").onClick("reset_stopwatch").class("ghost"),
        }),
        ctx.p().class("muted").text("All state lives in the wasm module. JS only drives a 50 ms tick."),
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
            ctx.title("Verve Stopwatch"),
            ctx.style(
                \\body{font:16px system-ui;margin:0;background:#0e0e10;color:#f5f5f5;min-height:100vh;display:grid;place-items:center}
                \\main{text-align:center}
                \\.display{font:600 4.5rem ui-monospace,monospace;font-variant-numeric:tabular-nums;margin:1rem 0;letter-spacing:.05em}
                \\.controls{display:flex;gap:.75rem;justify-content:center;margin-top:1rem}
                \\button{font:inherit;padding:.75rem 1.5rem;background:#1f6feb;color:#fff;border:0;border-radius:6px;cursor:pointer;font-weight:600}
                \\button.danger{background:#5b2727}
                \\button.ghost{background:transparent;color:#888;border:1px solid #333}
                \\button:hover{filter:brightness(1.15)}
                \\.muted{color:#666;margin-top:2rem;font-size:.85em}
            ),
        }),
        ctx.el("body").children(.{
            body,
            ctx.script("/verve.js"),
        }),
    }).build();
}
