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

    // Two instances of the SAME island component. Each inner subtree uses the
    // PLAIN bind-name "counter", data-ref "counter-label", and handler name
    // "counter_bump" — the framework namespaces them per-island by vid
    // (`counter__v1` / `counter__v2`, etc.), so the two counters render and
    // increment independently with no author burden.
    const a = try counterIsland(ctx, 3, "Clicks", 100); // → 103
    const b = try counterIsland(ctx, 50, "Taps", 0); //    → 50

    const body = ctx.div().children(.{
        ctx.h1("Islands demo"),
        ctx.p().text("Two hydrated Counter islands of the same component. Each gets typed props (base64 data-props) + island state (verve-state script). They share bind-name \"counter\" in source; the framework suffixes per-vid so they stay independent — click one and only it increments."),
        ctx.section().class("card").children(.{a}),
        ctx.section().class("card").children(.{b}),
        ctx.p().children(.{ verve.link(ctx, "/plain", "Plain page", .{}) }),
    });
    return components.shell.page(ctx, body);
}

/// One Counter island instance. The inner subtree uses plain binding names;
/// `verve.island` stamps a unique vid and the framework namespaces the SSR
/// `z-bind`/`data-ref` by it.
fn counterIsland(ctx: *verve.Context, initial: i32, label: []const u8, seed: i32) !*verve.Node {
    const inner = ctx.div().class("counter").children(.{
        ctx.span().attr("data-ref", "counter-label").text("…"),
        ctx.span().bind("counter").textInt(0),
        ctx.el("button").attr("z-on-click", "counter_bump").text("+"),
    });
    return verve.island(ctx, .{
        .name = "Counter",
        .props = try verve.encodeProps(ctx, islands.Counter.Props{ .initial = initial, .label = label }),
        .state = try ctx.islandState(.{ .seed = seed }),
    }, inner);
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
