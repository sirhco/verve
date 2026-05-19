const std = @import("std");
const verve = @import("verve");

pub fn page(ctx: *const verve.Context, body: verve.Node) !verve.Node {
    const alloc = ctx.alloc();
    const head_kids = try alloc.alloc(verve.Node, 3);
    head_kids[0] = .{ .tag = "meta", .attrs = &.{.{ .key = "charset", .value = "utf-8" }} };
    head_kids[1] = .{ .tag = "title", .text = "Verve Calculator" };
    head_kids[2] = .{
        .tag = "style",
        .text =
        \\body{font:16px system-ui;margin:0;background:#0e0e10;color:#f5f5f5;min-height:100vh;display:grid;place-items:center}
        \\.calc{background:#15151a;border:1px solid #333;border-radius:12px;padding:1rem;width:18rem}
        \\.display{background:#0e0e10;border-radius:6px;padding:1rem;text-align:right;font:600 2rem ui-monospace,monospace;font-variant-numeric:tabular-nums;min-height:2.5rem;overflow:hidden;text-overflow:ellipsis;margin-bottom:.75rem}
        \\.pad{display:grid;grid-template-columns:repeat(4, 1fr);gap:.5rem}
        \\button{font:inherit;padding:.85rem;background:#1c1c1f;color:#f5f5f5;border:0;border-radius:6px;cursor:pointer}
        \\button:hover{background:#2a2a2f}
        \\button.op{background:#1f6feb;color:#fff;font-weight:600}
        \\button.op:hover{background:#388bfd}
        \\button.eq{background:#22863a;color:#fff;font-weight:600;grid-column:span 2}
        \\button.eq:hover{background:#2ea043}
        \\button.clr{background:#5b2727;color:#fff;font-weight:600}
        \\button.clr:hover{background:#723232}
        \\.muted{color:#666;font-size:.85em;text-align:center;margin-top:1rem}
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

const KeyDef = struct { label: []const u8, action: []const u8, class: []const u8 = "" };

const KEYS = [_]KeyDef{
    .{ .label = "C", .action = "clear", .class = "clr" },
    .{ .label = "÷", .action = "op_div", .class = "op" },
    .{ .label = "×", .action = "op_mul", .class = "op" },
    .{ .label = "−", .action = "op_sub", .class = "op" },

    .{ .label = "7", .action = "digit_7" },
    .{ .label = "8", .action = "digit_8" },
    .{ .label = "9", .action = "digit_9" },
    .{ .label = "+", .action = "op_add", .class = "op" },

    .{ .label = "4", .action = "digit_4" },
    .{ .label = "5", .action = "digit_5" },
    .{ .label = "6", .action = "digit_6" },
    .{ .label = "1", .action = "digit_1" }, // placeholder; replaced below
};

pub fn calculator(ctx: *const verve.Context) !verve.Node {
    const alloc = ctx.alloc();

    const display = verve.Node{
        .tag = "div",
        .attrs = &.{.{ .key = "class", .value = "display" }},
        .z_bind = "display",
        .text = "0",
    };

    const pad_buttons = [_]KeyDef{
        .{ .label = "C", .action = "clear", .class = "clr" },
        .{ .label = "÷", .action = "op_div", .class = "op" },
        .{ .label = "×", .action = "op_mul", .class = "op" },
        .{ .label = "−", .action = "op_sub", .class = "op" },

        .{ .label = "7", .action = "digit_7" },
        .{ .label = "8", .action = "digit_8" },
        .{ .label = "9", .action = "digit_9" },
        .{ .label = "+", .action = "op_add", .class = "op" },

        .{ .label = "4", .action = "digit_4" },
        .{ .label = "5", .action = "digit_5" },
        .{ .label = "6", .action = "digit_6" },
        .{ .label = "=", .action = "op_equals", .class = "eq" },

        .{ .label = "1", .action = "digit_1" },
        .{ .label = "2", .action = "digit_2" },
        .{ .label = "3", .action = "digit_3" },
        .{ .label = "0", .action = "digit_0" },
    };

    const pad_kids = try alloc.alloc(verve.Node, pad_buttons.len);
    for (pad_buttons, 0..) |key, i| {
        const class_attr = try alloc.alloc(verve.Attr, 1);
        class_attr[0] = .{ .key = "class", .value = key.class };
        pad_kids[i] = .{
            .tag = "button",
            .text = key.label,
            .z_on_click = key.action,
            .attrs = if (key.class.len == 0) &.{} else class_attr,
        };
    }

    const pad = verve.Node{
        .tag = "div",
        .attrs = &.{.{ .key = "class", .value = "pad" }},
        .children = pad_kids,
    };

    const calc_kids = try alloc.alloc(verve.Node, 2);
    calc_kids[0] = display;
    calc_kids[1] = pad;

    const calc = verve.Node{
        .tag = "div",
        .attrs = &.{.{ .key = "class", .value = "calc" }},
        .children = calc_kids,
    };

    const muted = verve.Node{
        .tag = "p",
        .attrs = &.{.{ .key = "class", .value = "muted" }},
        .text = "Wasm holds the state. Keyboard works too: 0-9, +, −, ×, ÷, =, Enter, Esc.",
    };

    const kids = try alloc.alloc(verve.Node, 2);
    kids[0] = calc;
    kids[1] = muted;

    _ = KEYS; // silence unused-decl when iterating on the layout above
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
