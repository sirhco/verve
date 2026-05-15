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
    const kids = try alloc.alloc(verve.Node, 3);
    kids[0] = .{ .tag = "h1", .text = "Verve" };
    kids[1] = .{
        .tag = "p",
        .text = "Full-stack Zig web framework — fine-grained reactivity, no macros.",
    };
    const link_kids = try alloc.alloc(verve.Node, 1);
    link_kids[0] = .{ .tag = "a", .text = "Counter demo →", .attrs = &.{
        .{ .key = "href", .value = "/counter" },
    } };
    kids[2] = .{ .tag = "p", .children = link_kids };

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
