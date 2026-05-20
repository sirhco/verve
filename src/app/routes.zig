//! Page routes for the demo app. Server matches `path` against this table
//! at request time; the matched `render` builds the page Node tree.

const std = @import("std");
const verve = @import("verve");
const components = @import("components.zig");
const api = @import("api.zig");

pub const routes: []const verve.Route = &.{
    verve.Route.init("/", renderHome),
    verve.Route.init("/counter", renderCounter),
    verve.Route.init("/todos", renderTodos),
    verve.Route.init("/work/:slug", renderWorkDetail),
};

fn renderHome(ctx: *verve.Context) !*verve.Node {
    const body = try components.home(ctx);
    return components.page(ctx, body);
}

fn renderCounter(ctx: *verve.Context) !*verve.Node {
    const body = try components.counter(ctx, api.currentCount());
    return components.page(ctx, body);
}

fn renderTodos(ctx: *verve.Context) !*verve.Node {
    const items = try api.copyTodosInto(ctx.alloc());
    const body = try components.todoList(ctx, items);
    return components.page(ctx, body);
}

fn renderWorkDetail(ctx: *verve.Context) !*verve.Node {
    const slug = ctx.param("slug") orelse "";
    const body = try components.workDetail(ctx, slug);
    return components.page(ctx, body);
}
