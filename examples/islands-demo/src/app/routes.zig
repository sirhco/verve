//! Route table for the islands demo. Two pages:
//!   - `/`       — places the Counter island (typed props + island state +
//!                 a chunk-side click handler).
//!   - `/plain`  — a plain SSR page, no island.

const std = @import("std");
const verve = @import("verve");
const api = @import("api.zig");
const islands = api.islands;
const components = @import("components.zig");

pub const routes: []const verve.Route = &.{
    verve.Route.init("/", renderHome),
    verve.Route.init("/plain", renderPlain),
};

fn renderHome(ctx: *verve.Context) !*verve.Node {
    try ctx.setTitle("Verve Islands Demo");

    // The SSR subtree the chunk hydrates in place. The label span carries a
    // `data-ref` the chunk resolves via `queryRef`; the value span binds to
    // the "counter" signal the chunk registers. The button carries a
    // `data-ref` too: a chunk-side closure handler is registered via
    // `registerEvent` at hydrate time, and its slot id is stamped onto the
    // button as `z-on-click-id` (the bridge's closure-dispatch path —
    // string `z-on-click` resolves against the MAIN client exports, not the
    // chunk, so chunk handlers must use the id form).
    const inner = ctx.div().class("counter").children(.{
        ctx.span().attr("data-ref", "counter-label").text("…"),
        ctx.span().bind("counter").textInt(0),
        ctx.el("button").attr("data-ref", "counter-btn").text("+"),
    });

    const widget = verve.island(ctx, .{
        .name = "Counter",
        .props = try verve.encodeProps(ctx, islands.Counter.Props{ .initial = 3, .label = "Clicks" }),
        .state = try ctx.islandState(.{ .seed = @as(i32, 100) }),
    }, inner);

    const body = ctx.div().children(.{
        ctx.h1("Islands demo"),
        ctx.p().text("The counter below is a hydrated island: typed props (initial=3, label=\"Clicks\") + island state (seed=100). The chunk seeds the signal to initial+seed=103 and the + button runs chunk code."),
        ctx.section().class("card").children(.{widget}),
        ctx.p().children(.{ verve.link(ctx, "/plain", "Plain page", .{}) }),
    });
    return components.shell.page(ctx, body);
}

fn renderPlain(ctx: *verve.Context) !*verve.Node {
    try ctx.setTitle("Plain page — Verve Islands Demo");
    const body = ctx.div().children(.{
        ctx.h1("Plain page"),
        ctx.p().text("No island here — pure server-rendered HTML."),
        ctx.p().children(.{ verve.link(ctx, "/", "Home", .{}) }),
    });
    return components.shell.page(ctx, body);
}
