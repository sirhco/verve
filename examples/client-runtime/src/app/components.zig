const verve = @import("verve");

/// The page body: a single mounted island. The SSR subtree below carries the
/// bindings / refs / handler hooks the `JsonProbe` chunk wires up on hydrate —
/// each labeled with the client-runtime phase it exercises.
pub fn index(ctx: *const verve.Context) !*verve.Node {
    // The handler ids below MUST match the `registerEvent` order in
    // src/client/islands/JsonProbe.zig (0 refresh, 1 caps, 2 host, 3 form,
    // 4 keydown). Closure ids are the only dispatch path that reaches an
    // island chunk — string `z-on-click` actions only hit the main client.
    const inner = ctx.section().class("card").children(.{
        // Live status line — every action writes here (str bind).
        ctx.div().class("status").children(.{
            ctx.span().text("status: "),
            ctx.span().class("status-val").bind("json_probe_status").text("ready — click a button"),
        }),

        // Phase 17 — typed IPC. Refresh POSTs /api/json_probe; the reply's
        // `count` is read (accessor + readStruct) and pushed into this bind.
        ctx.div().class("row").children(.{
            ctx.span().text("Server count: "),
            ctx.span().class("count").bind("json_probe_count").textInt(0),
            ctx.button("Refresh (typed IPC)").type_("button").onClickFn(0),
        }),

        // Phase 18 — events with data. ⌘K / Ctrl+K inside this input fires the
        // registered keydown closure (reads mods + key, preventDefault).
        ctx.div().class("row").children(.{
            ctx.input()
                .attr("data-ref", "json_probe_input")
                .name("note")
                .placeholder("Focus me, then press ⌘K / Ctrl+K")
                .onKeydownFn(4),
        }),

        // Phase 20 — forms + measurement. Reads value/rect/viewport/media and
        // serializes the form via formCollect (shown in the status line).
        ctx.form(.{}).bind("json_probe_form").children(.{
            ctx.input().name("field").placeholder("a form field"),
            ctx.button("Inspect form + DOM").type_("button").onClickFn(3),
        }),

        // Phase 19 — timers / storage / clipboard.
        ctx.div().class("row").children(.{
            ctx.button("Run caps (timers/storage/clipboard)").type_("button").onClickFn(1),
        }),

        // Phase 21 — JS interop hatch (sync host + async hostAsync).
        ctx.div().class("row").children(.{
            ctx.button("Call JS host").type_("button").onClickFn(2),
        }),

        // Phase 22 — chunk arena + drag-drop. Drop a file onto this zone.
        ctx.div().bind("json_probe_drop").class("drop").text("Drop a file here (chunk arena)"),

        ctx.p().class("hint").text("Each button writes to the status line above; Refresh also bumps the server count (watch the network tab for /api/json_probe). All wired in src/client/islands/JsonProbe.zig."),
    });

    const island = verve.island(ctx, .{ .name = "JsonProbe", .props = "{}" }, inner);

    return ctx.main_().children(.{
        ctx.h1("Client runtime"),
        ctx.p().text("Every wasm client-runtime primitive from docs/20, exercised by one island."),
        island,
    }).build();
}

pub fn page(ctx: *const verve.Context, body: *verve.Node) !*verve.Node {
    return ctx.el("html").children(.{
        ctx.el("head").children(.{
            ctx.meta("charset", "utf-8"),
            ctx.title("Verve client runtime"),
            ctx.style(
                \\body{font:16px/1.6 system-ui;margin:0;background:#0e0e10;color:#e6e6e6}
                \\main{max-width:42rem;margin:2rem auto;padding:0 1.5rem}
                \\h1{margin-top:0}
                \\.card{background:#15151a;border:1px solid #30363d;border-radius:10px;padding:1.25rem;display:grid;gap:1rem}
                \\.row{display:flex;align-items:center;gap:.75rem;flex-wrap:wrap}
                \\.count{font-variant-numeric:tabular-nums;font-weight:700;color:#58a6ff;min-width:2ch}
                \\input{font:inherit;padding:.5rem;background:#0e0e10;color:inherit;border:1px solid #30363d;border-radius:6px}
                \\button{font:inherit;padding:.5rem .9rem;background:#1f6feb;color:#fff;border:0;border-radius:6px;cursor:pointer}
                \\button:hover{filter:brightness(1.12)}
                \\.drop{border:1px dashed #30363d;border-radius:8px;padding:1.25rem;text-align:center;color:#9aa0a6}
                \\.status{font-size:.95em;color:#9aa0a6}
                \\.status-val{color:#7ee787;font-variant-numeric:tabular-nums}
                \\.hint{color:#9aa0a6;font-size:.9em}
                \\form{display:flex;gap:.75rem;flex-wrap:wrap;align-items:center}
            ),
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
