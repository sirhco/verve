const verve = @import("verve");

const KeyDef = struct { label: []const u8, action: []const u8, class: []const u8 = "" };

const PAD_KEYS = [_]KeyDef{
    .{ .label = "C", .action = "clear", .class = "clr" },
    .{ .label = "÷", .action = "op_div", .class = "op" },
    .{ .label = "×", .action = "op_mul", .class = "op" },
    .{ .label = "−", .action = "op_sub", .class = "op" },

    .{ .label = "7", .action = "digit_7" },
    .{ .label = "8", .action = "digit_8" },
    .{ .label = "9", .action = "digit_9" },
    .{ .label = "+", .action = "op_add", .class = "op" },

    .{ .label = "4", .action = "digit_4" },
    .{ .label = "5", .action = "digit_5" },
    .{ .label = "6", .action = "digit_6" },
    .{ .label = "=", .action = "op_equals", .class = "eq" },

    .{ .label = "1", .action = "digit_1" },
    .{ .label = "2", .action = "digit_2" },
    .{ .label = "3", .action = "digit_3" },
    .{ .label = "0", .action = "digit_0" },
};

pub fn calculator(ctx: *const verve.Context) !*verve.Node {
    const pad = ctx.div().class("pad");
    for (PAD_KEYS) |key| {
        const btn = ctx.button(key.label).onClick(key.action);
        if (key.class.len != 0) _ = btn.class(key.class);
        _ = pad.children(.{btn});
    }

    return ctx.main_().children(.{
        ctx.div().class("calc").children(.{
            ctx.div().class("display").bind("display").text("0"),
            pad,
        }),
        ctx.p().class("muted").text("Wasm holds the state. Keyboard works too: 0-9, +, −, ×, ÷, =, Enter, Esc."),
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
            ctx.title("Verve Calculator"),
            ctx.style(
                \\body{font:16px system-ui;margin:0;background:#0e0e10;color:#f5f5f5;min-height:100vh;display:grid;place-items:center}
                \\.calc{background:#15151a;border:1px solid #333;border-radius:12px;padding:1rem;width:18rem}
                \\.display{background:#0e0e10;border-radius:6px;padding:1rem;text-align:right;font:600 2rem ui-monospace,monospace;font-variant-numeric:tabular-nums;min-height:2.5rem;overflow:hidden;text-overflow:ellipsis;margin-bottom:.75rem}
                \\.pad{display:grid;grid-template-columns:repeat(4, 1fr);gap:.5rem}
                \\button{font:inherit;padding:.85rem;background:#1c1c1f;color:#f5f5f5;border:0;border-radius:6px;cursor:pointer}
                \\button:hover{background:#2a2a2f}
                \\button.op{background:#1f6feb;color:#fff;font-weight:600}
                \\button.op:hover{background:#388bfd}
                \\button.eq{background:#22863a;color:#fff;font-weight:600;grid-column:span 2}
                \\button.eq:hover{background:#2ea043}
                \\button.clr{background:#5b2727;color:#fff;font-weight:600}
                \\button.clr:hover{background:#723232}
                \\.muted{color:#666;font-size:.85em;text-align:center;margin-top:1rem}
            ),
        }),
        ctx.el("body").children(.{
            body,
            ctx.script("/verve.js"),
        }),
    }).build();
}
