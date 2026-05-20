//! Example components for the demo app.

const std = @import("std");
const verve = @import("verve");

pub fn counter(ctx: *const verve.Context, initial: i32) !*verve.Node {
    return ctx.div().class("counter-card").children(.{
        ctx.h1("Verve Counter"),
        ctx.span().class("count").bind("count").textInt(initial),
        // +/- buttons are wrapped in forms so they work without JS (native
        // submit → 303 to Referer). When wasm/WS is available, the bridge's
        // delegated click handler calls preventDefault and routes through
        // the wasm export instead.
        ctx.actionForm(.{ .post = "/api/incrementCount", .class = "counter-form" }).children(.{
            ctx.button("+").type_("submit").onClick("increment_counter"),
        }),
        ctx.actionForm(.{ .post = "/api/decrementCount", .class = "counter-form" }).children(.{
            ctx.button("-").type_("submit").onClick("decrement_counter"),
        }),
        ctx.p().class("clicks").children(.{
            ctx.span().text("Total clicks: "),
            ctx.span().bind("clicks").text("0"),
        }),
    }).build();
}

pub fn home(ctx: *const verve.Context) !*verve.Node {
    return ctx.main_().class("home").children(.{
        ctx.h1("Verve"),
        ctx.p().text("Full-stack Zig web framework — fine-grained reactivity, no macros."),
        ctx.p().children(.{ verve.link(ctx, "/counter", "Counter demo →", .{ .prefetch_on_hover = true }) }),
        ctx.p().children(.{ verve.link(ctx, "/todos", "Todo list (form fallback) →", .{}) }),
        ctx.p().children(.{ verve.link(ctx, "/work/hello-world", "Path-param demo (/work/:slug) →", .{}) }),
    }).build();
}

pub fn workDetail(ctx: *const verve.Context, slug: []const u8) !*verve.Node {
    // Per-page <head> contributions. The shell drains ctx.head in
    // priority order before emitting the body, so canonical / OG /
    // JSON-LD end up correctly ordered regardless of where they were
    // contributed from.
    try ctx.setTitle(try std.fmt.allocPrint(ctx.alloc(), "Work — {s}", .{slug}));
    try ctx.metaTag(.{ .name = "description", .content = "Work-detail demo for path params + per-page head." });
    try ctx.linkTag(.{ .rel = "canonical", .href = try std.fmt.allocPrint(ctx.alloc(), "https://example.com/work/{s}", .{slug}) });
    try ctx.metaTag(.{ .name = "og:title", .content = slug, .is_property = true, .priority = 40 });
    try ctx.jsonLd(try std.fmt.allocPrint(
        ctx.alloc(),
        "{{\"@context\":\"https://schema.org\",\"@type\":\"CreativeWork\",\"name\":\"{s}\"}}",
        .{slug},
    ));

    return ctx.main_().class("home").children(.{
        ctx.h1("Work Detail"),
        ctx.p().children(.{
            ctx.span().text("Slug: "),
            ctx.code(slug),
        }),
        ctx.p().text("This route uses /work/:slug. The matched parameter is bound to ctx.params[\"slug\"] by the router."),
        ctx.p().children(.{ ctx.a("/", "← Home") }),
    }).build();
}

pub fn todoList(ctx: *const verve.Context, items: []const []const u8) !*verve.Node {
    const list = ctx.ul().class("todo-list");
    for (items, 0..) |item_text, i| {
        _ = list.children(.{
            ctx.li().children(.{
                ctx.span().text(item_text),
                ctx.actionForm(.{ .post = "/api/removeTodo", .class = "todo-remove" }).children(.{
                    ctx.input().type_("hidden").name("index").attrFmt("value", "{d}", .{i}),
                    ctx.button("×").type_("submit"),
                }),
            }),
        });
    }

    return ctx.main_().class("home").children(.{
        ctx.h1("Todos"),
        ctx.p().text("Pure server-rendered list. Submissions degrade gracefully without wasm."),
        ctx.actionForm(.{ .post = "/api/addTodo", .class = "todo-form" }).children(.{
            ctx.input().name("text").type_("text").placeholder("Write something to do").required().autofocus(),
            ctx.button("Add").type_("submit"),
        }),
        list,
    }).build();
}

pub fn notFound(ctx: *const verve.Context, path: []const u8) !*verve.Node {
    return ctx.main_().class("home").children(.{
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
    return ctx.main_().class("home").children(.{
        ctx.el("h1").textFmt("{d} — {s}", .{ status_code, status_text }),
        ctx.p().text(message),
        ctx.p().children(.{ ctx.a("/", "← Home") }),
    }).build();
}

pub fn page(ctx: *const verve.Context, body: *verve.Node) !*verve.Node {
    // Provide a default title only if the page didn't set one of its own.
    try ctx.setTitleIfUnset("Verve");

    // Drain ctx.head into a static byte buffer that we emit verbatim
    // inside <head>. The accumulator already produces <meta charset>,
    // <title>, plus any meta/link/json-ld the page contributed.
    var aw: std.Io.Writer.Allocating = .init(ctx.alloc());
    try ctx.head.?.render(&aw.writer);
    const head_html = aw.written();

    return ctx.el("html").children(.{
        ctx.el("head").children(.{
            ctx.raw(head_html),
            ctx.style(
                \\body{font:16px system-ui;margin:2rem;background:#0e0e10;color:#f5f5f5}
                \\.counter-card{padding:1.5rem;border:1px solid #333;border-radius:8px;max-width:24rem}
                \\.count{font-size:3rem;display:block;margin:1rem 0;font-variant-numeric:tabular-nums}
                \\button{font:inherit;padding:.5rem 1rem;margin-right:.5rem;background:#1f6feb;color:#fff;border:0;border-radius:4px;cursor:pointer}
                \\button:hover{background:#388bfd}
                \\.counter-form{display:inline}
                \\a{color:#58a6ff;text-decoration:none}
                \\a:hover{text-decoration:underline}
                \\.home{max-width:36rem}
                \\.todo-form{display:flex;gap:.5rem;margin:1rem 0}
                \\.todo-form input[type=text]{flex:1;padding:.5rem;background:#1c1c1f;color:inherit;border:1px solid #333;border-radius:4px;font:inherit}
                \\.todo-list{list-style:none;padding:0;margin:1rem 0}
                \\.todo-list li{display:flex;align-items:center;gap:.5rem;padding:.5rem;border-bottom:1px solid #222}
                \\.todo-list li span{flex:1}
                \\.todo-remove button{background:#3d1d1d;padding:.25rem .5rem}
                \\.todo-remove button:hover{background:#5b2727}
            ),
        }),
        ctx.el("body").children(.{
            body,
            ctx.script("/verve.js"),
        }),
    }).build();
}
