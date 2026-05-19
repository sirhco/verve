const std = @import("std");
const verve = @import("verve");

pub fn page(ctx: *const verve.Context, body: verve.Node) !verve.Node {
    const alloc = ctx.alloc();
    const head_kids = try alloc.alloc(verve.Node, 3);
    head_kids[0] = .{ .tag = "meta", .attrs = &.{.{ .key = "charset", .value = "utf-8" }} };
    head_kids[1] = .{ .tag = "title", .text = "Verve Keystrokes" };
    head_kids[2] = .{
        .tag = "style",
        .text =
        \\body{font:16px system-ui;margin:0;background:#0e0e10;color:#f5f5f5;min-height:100vh;display:grid;place-items:center}
        \\main{text-align:center;max-width:30rem;padding:1rem}
        \\.total{font:600 5rem ui-monospace,monospace;margin:.5rem 0;font-variant-numeric:tabular-nums;color:#58a6ff}
        \\.last{font:600 2rem ui-monospace,monospace;padding:.5rem 1rem;background:#15151a;border:1px solid #333;border-radius:6px;display:inline-block;min-width:6rem}
        \\.label{color:#888;font-size:.85em;margin:1rem 0 .25rem}
        \\button{font:inherit;margin-top:1.5rem;padding:.6rem 1.2rem;background:#5b2727;color:#fff;border:0;border-radius:6px;cursor:pointer}
        \\button:hover{filter:brightness(1.15)}
        \\.muted{color:#666;margin-top:2rem;font-size:.85em;line-height:1.5}
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

pub fn keystrokes(ctx: *const verve.Context) !verve.Node {
    const alloc = ctx.alloc();

    const kids = try alloc.alloc(verve.Node, 7);
    kids[0] = .{ .tag = "h1", .text = "Keystrokes" };

    kids[1] = .{ .tag = "p", .attrs = &.{.{ .key = "class", .value = "label" }}, .text = "Total keys" };
    kids[2] = .{
        .tag = "div",
        .attrs = &.{.{ .key = "class", .value = "total" }},
        .z_bind = "total",
        .text = "0",
    };

    kids[3] = .{ .tag = "p", .attrs = &.{.{ .key = "class", .value = "label" }}, .text = "Last key" };
    kids[4] = .{
        .tag = "div",
        .attrs = &.{.{ .key = "class", .value = "last" }},
        .z_bind = "last",
        .text = "(none)",
    };

    kids[5] = .{
        .tag = "button",
        .text = "Reset",
        .z_on_click = "reset_count",
    };

    kids[6] = .{
        .tag = "p",
        .attrs = &.{.{ .key = "class", .value = "muted" }},
        .text = "Press any key. The string is UTF-8 encoded into a wasm-owned buffer; wasm counts and re-emits the bound display.",
    };

    return .{ .tag = "main", .children = kids };
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
    return .{ .tag = "main", .children = kids };
}

pub fn errorPage(
    ctx: *const verve.Context,
    status_code: u16,
    status_text: []const u8,
    message: []const u8,
) !verve.Node {
    const alloc = ctx.alloc();
    var hb: [64]u8 = undefined;
    var hw: std.Io.Writer = .fixed(&hb);
    try hw.print("{d} — {s}", .{ status_code, status_text });
    const kids = try alloc.alloc(verve.Node, 3);
    kids[0] = .{ .tag = "h1", .text = try alloc.dupe(u8, hw.buffered()) };
    kids[1] = .{ .tag = "p", .text = message };
    const link_kids = try alloc.alloc(verve.Node, 1);
    link_kids[0] = .{ .tag = "a", .text = "← Home", .attrs = &.{
        .{ .key = "href", .value = "/" },
    } };
    kids[2] = .{ .tag = "p", .children = link_kids };
    return .{ .tag = "main", .children = kids };
}
