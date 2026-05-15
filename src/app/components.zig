//! Example components for the demo app.

const verve = @import("verve");

pub fn counter(ctx: *const verve.Context, initial: i32) !verve.Node {
    const alloc = ctx.alloc();

    var count_str_buf: [12]u8 = undefined;
    const count_str = try printInt(&count_str_buf, initial);
    const count_owned = try alloc.dupe(u8, count_str);

    const children = try alloc.alloc(verve.Node, 5);
    children[0] = .{ .tag = "h1", .text = "Verve Counter" };
    children[1] = .{
        .tag = "span",
        .z_bind = "count",
        .text = count_owned,
        .attrs = &.{.{ .key = "class", .value = "count" }},
    };
    children[2] = .{
        .tag = "button",
        .z_on_click = "increment_counter",
        .text = "+",
    };
    children[3] = .{
        .tag = "button",
        .z_on_click = "decrement_counter",
        .text = "-",
    };
    const clicks_kids = try alloc.alloc(verve.Node, 2);
    clicks_kids[0] = .{ .tag = "span", .text = "Total clicks: " };
    clicks_kids[1] = .{ .tag = "span", .z_bind = "clicks", .text = "0" };
    children[4] = .{
        .tag = "p",
        .attrs = &.{.{ .key = "class", .value = "clicks" }},
        .children = clicks_kids,
    };

    return .{
        .tag = "div",
        .attrs = &.{.{ .key = "class", .value = "counter-card" }},
        .children = children,
    };
}

pub fn home(ctx: *const verve.Context) !verve.Node {
    const alloc = ctx.alloc();
    const kids = try alloc.alloc(verve.Node, 4);
    kids[0] = .{ .tag = "h1", .text = "Verve" };
    kids[1] = .{
        .tag = "p",
        .text = "Full-stack Zig web framework — fine-grained reactivity, no macros.",
    };

    const counter_link = try alloc.alloc(verve.Node, 1);
    counter_link[0] = .{ .tag = "a", .text = "Counter demo →", .attrs = &.{
        .{ .key = "href", .value = "/counter" },
    } };
    kids[2] = .{ .tag = "p", .children = counter_link };

    const todos_link = try alloc.alloc(verve.Node, 1);
    todos_link[0] = .{ .tag = "a", .text = "Todo list (form fallback) →", .attrs = &.{
        .{ .key = "href", .value = "/todos" },
    } };
    kids[3] = .{ .tag = "p", .children = todos_link };

    return .{
        .tag = "main",
        .attrs = &.{.{ .key = "class", .value = "home" }},
        .children = kids,
    };
}

pub fn todoList(ctx: *const verve.Context, items: []const []const u8) !verve.Node {
    const alloc = ctx.alloc();

    const kids = try alloc.alloc(verve.Node, 4);
    kids[0] = .{ .tag = "h1", .text = "Todos" };
    kids[1] = .{
        .tag = "p",
        .text = "Pure server-rendered list. Submissions degrade gracefully without wasm.",
    };

    // Add-form
    const add_inputs = try alloc.alloc(verve.Node, 2);
    add_inputs[0] = .{
        .tag = "input",
        .attrs = &.{
            .{ .key = "name", .value = "text" },
            .{ .key = "type", .value = "text" },
            .{ .key = "placeholder", .value = "Write something to do" },
            .{ .key = "required", .value = "true" },
            .{ .key = "autofocus", .value = "true" },
        },
    };
    add_inputs[1] = .{
        .tag = "button",
        .text = "Add",
        .attrs = &.{.{ .key = "type", .value = "submit" }},
    };
    kids[2] = .{
        .tag = "form",
        .attrs = &.{
            .{ .key = "method", .value = "post" },
            .{ .key = "action", .value = "/api/addTodo" },
            .{ .key = "class", .value = "todo-form" },
        },
        .children = add_inputs,
    };

    // List of items + per-item remove form
    const item_nodes = try alloc.alloc(verve.Node, items.len);
    for (items, 0..) |text, i| {
        var idx_buf: [12]u8 = undefined;
        var iw: @import("std").Io.Writer = .fixed(&idx_buf);
        try iw.print("{d}", .{i});
        const idx_owned = try alloc.dupe(u8, iw.buffered());

        const remove_kids = try alloc.alloc(verve.Node, 2);
        const hidden_attrs = try alloc.alloc(verve.Attr, 3);
        hidden_attrs[0] = .{ .key = "type", .value = "hidden" };
        hidden_attrs[1] = .{ .key = "name", .value = "index" };
        hidden_attrs[2] = .{ .key = "value", .value = idx_owned };
        remove_kids[0] = .{
            .tag = "input",
            .attrs = hidden_attrs,
        };
        remove_kids[1] = .{
            .tag = "button",
            .text = "×",
            .attrs = &.{.{ .key = "type", .value = "submit" }},
        };
        const remove_form = verve.Node{
            .tag = "form",
            .attrs = &.{
                .{ .key = "method", .value = "post" },
                .{ .key = "action", .value = "/api/removeTodo" },
                .{ .key = "class", .value = "todo-remove" },
            },
            .children = remove_kids,
        };

        const li_kids = try alloc.alloc(verve.Node, 2);
        li_kids[0] = .{ .tag = "span", .text = text };
        li_kids[1] = remove_form;
        item_nodes[i] = .{ .tag = "li", .children = li_kids };
    }
    kids[3] = .{
        .tag = "ul",
        .attrs = &.{.{ .key = "class", .value = "todo-list" }},
        .children = item_nodes,
    };

    return .{
        .tag = "main",
        .attrs = &.{.{ .key = "class", .value = "home" }},
        .children = kids,
    };
}

pub fn notFound(ctx: *const verve.Context, path: []const u8) !verve.Node {
    const alloc = ctx.alloc();
    const kids = try alloc.alloc(verve.Node, 3);
    kids[0] = .{ .tag = "h1", .text = "404 — Not Found" };

    const path_kids = try alloc.alloc(verve.Node, 2);
    path_kids[0] = .{ .tag = "span", .text = "No route for " };
    path_kids[1] = .{ .tag = "code", .text = path };
    kids[1] = .{ .tag = "p", .children = path_kids };

    const link_kids = try alloc.alloc(verve.Node, 1);
    link_kids[0] = .{ .tag = "a", .text = "← Home", .attrs = &.{
        .{ .key = "href", .value = "/" },
    } };
    kids[2] = .{ .tag = "p", .children = link_kids };

    return .{
        .tag = "main",
        .attrs = &.{.{ .key = "class", .value = "home" }},
        .children = kids,
    };
}

pub fn errorPage(
    ctx: *const verve.Context,
    status_code: u16,
    status_text: []const u8,
    message: []const u8,
) !verve.Node {
    const alloc = ctx.alloc();

    var heading_buf: [64]u8 = undefined;
    var hw: @import("std").Io.Writer = .fixed(&heading_buf);
    try hw.print("{d} — {s}", .{ status_code, status_text });
    const heading_owned = try alloc.dupe(u8, hw.buffered());

    const kids = try alloc.alloc(verve.Node, 3);
    kids[0] = .{ .tag = "h1", .text = heading_owned };
    kids[1] = .{ .tag = "p", .text = message };

    const link_kids = try alloc.alloc(verve.Node, 1);
    link_kids[0] = .{ .tag = "a", .text = "← Home", .attrs = &.{
        .{ .key = "href", .value = "/" },
    } };
    kids[2] = .{ .tag = "p", .children = link_kids };

    return .{
        .tag = "main",
        .attrs = &.{.{ .key = "class", .value = "home" }},
        .children = kids,
    };
}

pub fn page(ctx: *const verve.Context, body: verve.Node) !verve.Node {
    const alloc = ctx.alloc();
    const head_kids = try alloc.alloc(verve.Node, 3);
    head_kids[0] = .{ .tag = "meta", .attrs = &.{.{ .key = "charset", .value = "utf-8" }} };
    head_kids[1] = .{ .tag = "title", .text = "Verve" };
    head_kids[2] = .{
        .tag = "style",
        .text =
        \\body{font:16px system-ui;margin:2rem;background:#0e0e10;color:#f5f5f5}
        \\.counter-card{padding:1.5rem;border:1px solid #333;border-radius:8px;max-width:24rem}
        \\.count{font-size:3rem;display:block;margin:1rem 0;font-variant-numeric:tabular-nums}
        \\button{font:inherit;padding:.5rem 1rem;margin-right:.5rem;background:#1f6feb;color:#fff;border:0;border-radius:4px;cursor:pointer}
        \\button:hover{background:#388bfd}
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
        ,
    };

    const body_kids = try alloc.alloc(verve.Node, 2);
    body_kids[0] = body;
    body_kids[1] = .{
        .tag = "script",
        .attrs = &.{.{ .key = "src", .value = "/verve.js" }},
    };

    const html_kids = try alloc.alloc(verve.Node, 2);
    html_kids[0] = .{ .tag = "head", .children = head_kids };
    html_kids[1] = .{ .tag = "body", .children = body_kids };

    return .{ .tag = "html", .children = html_kids };
}

fn printInt(buf: []u8, value: i32) ![]u8 {
    const std = @import("std");
    var w: std.Io.Writer = .fixed(buf);
    try w.print("{d}", .{value});
    return w.buffered();
}
