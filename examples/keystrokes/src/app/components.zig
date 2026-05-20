const verve = @import("verve");

pub fn keystrokes(ctx: *const verve.Context) !*verve.Node {
    return ctx.main_().children(.{
        ctx.h1("Keystrokes"),
        ctx.p().class("label").text("Total keys"),
        ctx.div().class("total").bind("total").text("0"),
        ctx.p().class("label").text("Last key"),
        ctx.div().class("last").bind("last").text("(none)"),
        ctx.button("Reset").onClick("reset_count"),
        ctx.p().class("muted").text("Press any key. The string is UTF-8 encoded into a wasm-owned buffer; wasm counts and re-emits the bound display."),
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
            ctx.title("Verve Keystrokes"),
            ctx.style(
                \\body{font:16px system-ui;margin:0;background:#0e0e10;color:#f5f5f5;min-height:100vh;display:grid;place-items:center}
                \\main{text-align:center;max-width:30rem;padding:1rem}
                \\.total{font:600 5rem ui-monospace,monospace;margin:.5rem 0;font-variant-numeric:tabular-nums;color:#58a6ff}
                \\.last{font:600 2rem ui-monospace,monospace;padding:.5rem 1rem;background:#15151a;border:1px solid #333;border-radius:6px;display:inline-block;min-width:6rem}
                \\.label{color:#888;font-size:.85em;margin:1rem 0 .25rem}
                \\button{font:inherit;margin-top:1.5rem;padding:.6rem 1.2rem;background:#5b2727;color:#fff;border:0;border-radius:6px;cursor:pointer}
                \\button:hover{filter:brightness(1.15)}
                \\.muted{color:#666;margin-top:2rem;font-size:.85em;line-height:1.5}
            ),
        }),
        ctx.el("body").children(.{
            body,
            ctx.script("/verve.js"),
        }),
    }).build();
}
