const std = @import("std");
const verve = @import("verve");

pub fn page(ctx: *const verve.Context, body: verve.Node) !verve.Node {
    const alloc = ctx.alloc();
    const head_kids = try alloc.alloc(verve.Node, 3);
    head_kids[0] = .{ .tag = "meta", .attrs = &.{.{ .key = "charset", .value = "utf-8" }} };
    head_kids[1] = .{ .tag = "title", .text = "Verve Stopwatch" };
    head_kids[2] = .{
        .tag = "style",
        .text =
        \\body{font:16px system-ui;margin:0;background:#0e0e10;color:#f5f5f5;min-height:100vh;display:grid;place-items:center}
        \\main{text-align:center}
        \\.display{font:600 4.5rem ui-monospace,monospace;font-variant-numeric:tabular-nums;margin:1rem 0;letter-spacing:.05em}
        \\.controls{display:flex;gap:.75rem;justify-content:center;margin-top:1rem}
        \\button{font:inherit;padding:.75rem 1.5rem;background:#1f6feb;color:#fff;border:0;border-radius:6px;cursor:pointer;font-weight:600}
        \\button.danger{background:#5b2727}
        \\button.ghost{background:transparent;color:#888;border:1px solid #333}
        \\button:hover{filter:brightness(1.15)}
        \\.muted{color:#666;margin-top:2rem;font-size:.85em}
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

pub fn stopwatch(ctx: *const verve.Context) !verve.Node {
    const alloc = ctx.alloc();

    const display = verve.Node{
        .tag = "div",
        .attrs = &.{.{ .key = "class", .value = "display" }},
        .z_bind = "display",
        .text = "00:00.000",
    };

    const start_btn = verve.Node{
        .tag = "button",
        .text = "Start",
        .z_on_click = "start_stopwatch",
    };
    const stop_btn = verve.Node{
        .tag = "button",
        .text = "Stop",
        .z_on_click = "stop_stopwatch",
    };
    const reset_btn = verve.Node{
        .tag = "button",
        .text = "Reset",
        .z_on_click = "reset_stopwatch",
        .attrs = &.{.{ .key = "class", .value = "ghost" }},
    };

    const controls_kids = try alloc.alloc(verve.Node, 3);
    controls_kids[0] = start_btn;
    controls_kids[1] = stop_btn;
    controls_kids[2] = reset_btn;

    const controls = verve.Node{
        .tag = "div",
        .attrs = &.{.{ .key = "class", .value = "controls" }},
        .children = controls_kids,
    };

    const muted = verve.Node{
        .tag = "p",
        .attrs = &.{.{ .key = "class", .value = "muted" }},
        .text = "All state lives in the wasm module. JS only drives a 50 ms tick.",
    };

    const kids = try alloc.alloc(verve.Node, 4);
    kids[0] = .{ .tag = "h1", .text = "Stopwatch" };
    kids[1] = display;
    kids[2] = controls;
    kids[3] = muted;

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
