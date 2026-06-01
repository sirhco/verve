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
    // `data-ref` the chunk resolves via `queryRef` + `setRefText` (typed
    // prop); the value span binds to the "counter" signal the chunk seeds
    // from props + island state; the button's `z-on-click` dispatches to the
    // chunk's exported `counter_bump` (the bridge scopes it to this island).
    const inner = ctx.div().class("counter").children(.{
        ctx.span().attr("data-ref", "counter-label").text("…"),
        ctx.span().bind("counter").textInt(0),
        ctx.el("button").attr("z-on-click", "counter_bump").text("+"),
    });

    const widget = verve.island(ctx, .{
        .name = "Counter",
        .props = try verve.encodeProps(ctx, islands.Counter.Props{ .initial = 3, .label = "Clicks" }),
        .state = try ctx.islandState(.{ .seed = @as(i32, 100) }),
    }, inner);

    const body = ctx.div().children(.{
        ctx.h1("Islands demo"),
        ctx.p().text("The counter below is a hydrated island: typed props (initial=3, label=\"Clicks\") decoded from base64 data-props + island state (seed=100) from the verve-state script. The chunk seeds the signal to initial+seed=103 and sets the label from the typed prop."),
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
