//! Page components.
//!
//! All HTML is built as a Node tree and streamed by the framework's
//! renderer. The chat page subscribes to /events via a small inline
//! script that reloads the page on counter change, so every visitor
//! sees fresh messages without manual refresh.

const std = @import("std");
const verve = @import("verve");
const api = @import("api.zig");

pub fn page(ctx: *const verve.Context, body: verve.Node) !verve.Node {
    const alloc = ctx.alloc();
    const head_kids = try alloc.alloc(verve.Node, 3);
    head_kids[0] = .{ .tag = "meta", .attrs = &.{.{ .key = "charset", .value = "utf-8" }} };
    head_kids[1] = .{ .tag = "title", .text = "Verve Chat" };
    head_kids[2] = .{
        .tag = "style",
        .text =
        \\body{font:16px system-ui;margin:0;background:#0e0e10;color:#f5f5f5}
        \\main{max-width:42rem;margin:2rem auto;padding:0 1rem}
        \\h1{margin-top:0}
        \\.msg-list{list-style:none;padding:0;margin:1rem 0;border:1px solid #333;border-radius:8px;background:#15151a}
        \\.msg-list li{padding:.75rem 1rem;border-bottom:1px solid #222}
        \\.msg-list li:last-child{border-bottom:0}
        \\.msg-author{font-weight:600;color:#58a6ff}
        \\.msg-time{color:#777;font-size:.85em;margin-left:.5rem}
        \\.msg-body{margin:.25rem 0 0;white-space:pre-wrap;word-wrap:break-word}
        \\.empty{padding:1.5rem;text-align:center;color:#888}
        \\form.post{display:grid;gap:.5rem;margin:1rem 0}
        \\input,textarea{font:inherit;padding:.5rem;background:#1c1c1f;color:inherit;border:1px solid #333;border-radius:4px}
        \\textarea{resize:vertical;min-height:5rem}
        \\button{font:inherit;padding:.5rem 1rem;background:#1f6feb;color:#fff;border:0;border-radius:4px;cursor:pointer}
        \\button.danger{background:#5b2727}
        \\button:hover{filter:brightness(1.15)}
        \\nav{display:flex;gap:1rem;margin-bottom:1rem}
        \\a{color:#58a6ff;text-decoration:none}
        ,
    };

    const body_kids = try alloc.alloc(verve.Node, 1);
    body_kids[0] = body;

    const html_kids = try alloc.alloc(verve.Node, 2);
    html_kids[0] = .{ .tag = "head", .children = head_kids };
    html_kids[1] = .{ .tag = "body", .children = body_kids };

    return .{ .tag = "html", .children = html_kids };
}

pub fn home(ctx: *const verve.Context) !verve.Node {
    const alloc = ctx.alloc();
    const kids = try alloc.alloc(verve.Node, 3);
    kids[0] = .{ .tag = "h1", .text = "Verve Chat" };
    kids[1] = .{
        .tag = "p",
        .text = "A broadcast chat board. Posts fan out to every connected browser via Server-Sent Events.",
    };

    const link_kids = try alloc.alloc(verve.Node, 1);
    link_kids[0] = .{ .tag = "a", .text = "Open the chat room →", .attrs = &.{
        .{ .key = "href", .value = "/chat" },
    } };
    kids[2] = .{ .tag = "p", .children = link_kids };

    return .{ .tag = "main", .children = kids };
}

pub fn chat(ctx: *const verve.Context, messages: []api.Message) !verve.Node {
    const alloc = ctx.alloc();
    var kids: std.ArrayList(verve.Node) = .empty;

    try kids.append(alloc, .{ .tag = "h1", .text = "Chat room" });

    // Nav row.
    const nav_kids = try alloc.alloc(verve.Node, 2);
    nav_kids[0] = .{ .tag = "a", .text = "← Home", .attrs = &.{.{ .key = "href", .value = "/" }} };

    var count_buf: [16]u8 = undefined;
    var cw: std.Io.Writer = .fixed(&count_buf);
    try cw.print("{d} messages", .{messages.len});
    const count_text = try alloc.dupe(u8, cw.buffered());
    nav_kids[1] = .{ .tag = "span", .text = count_text };

    try kids.append(alloc, .{
        .tag = "nav",
        .children = nav_kids,
    });

    // Compose form.
    const form_kids = try alloc.alloc(verve.Node, 3);
    form_kids[0] = .{
        .tag = "input",
        .attrs = &.{
            .{ .key = "name", .value = "author" },
            .{ .key = "type", .value = "text" },
            .{ .key = "placeholder", .value = "Your name" },
            .{ .key = "required", .value = "true" },
            .{ .key = "maxlength", .value = "40" },
        },
    };
    form_kids[1] = .{
        .tag = "textarea",
        .attrs = &.{
            .{ .key = "name", .value = "body" },
            .{ .key = "placeholder", .value = "What's on your mind?" },
            .{ .key = "required", .value = "true" },
            .{ .key = "maxlength", .value = "200" },
        },
    };

    const submit_row = try alloc.alloc(verve.Node, 2);
    submit_row[0] = .{
        .tag = "button",
        .text = "Post",
        .attrs = &.{.{ .key = "type", .value = "submit" }},
    };
    submit_row[1] = .{ .tag = "span", .text = "" }; // spacer
    form_kids[2] = .{ .tag = "div", .children = submit_row };

    try kids.append(alloc, .{
        .tag = "form",
        .attrs = &.{
            .{ .key = "method", .value = "post" },
            .{ .key = "action", .value = "/api/postMessage" },
            .{ .key = "class", .value = "post" },
        },
        .children = form_kids,
    });

    // Message list.
    if (messages.len == 0) {
        try kids.append(alloc, .{
            .tag = "p",
            .attrs = &.{.{ .key = "class", .value = "empty" }},
            .text = "No messages yet. Be the first.",
        });
    } else {
        const list_items = try alloc.alloc(verve.Node, messages.len);
        // Render newest first.
        var idx: usize = 0;
        while (idx < messages.len) : (idx += 1) {
            const src = &messages[messages.len - 1 - idx];

            var seq_buf: [16]u8 = undefined;
            var sw: std.Io.Writer = .fixed(&seq_buf);
            try sw.print("#{d}", .{src.seq});
            const seq_text = try alloc.dupe(u8, sw.buffered());

            const meta_kids = try alloc.alloc(verve.Node, 2);
            meta_kids[0] = .{
                .tag = "span",
                .text = try alloc.dupe(u8, src.authorSlice()),
                .attrs = &.{.{ .key = "class", .value = "msg-author" }},
            };
            meta_kids[1] = .{
                .tag = "span",
                .text = seq_text,
                .attrs = &.{.{ .key = "class", .value = "msg-time" }},
            };

            const li_kids = try alloc.alloc(verve.Node, 2);
            li_kids[0] = .{ .tag = "div", .children = meta_kids };
            li_kids[1] = .{
                .tag = "p",
                .text = try alloc.dupe(u8, src.bodySlice()),
                .attrs = &.{.{ .key = "class", .value = "msg-body" }},
            };
            list_items[idx] = .{ .tag = "li", .children = li_kids };
        }
        try kids.append(alloc, .{
            .tag = "ul",
            .attrs = &.{.{ .key = "class", .value = "msg-list" }},
            .children = list_items,
        });
    }

    // Clear button + auto-reload script.
    try kids.append(alloc, .{
        .tag = "form",
        .attrs = &.{
            .{ .key = "method", .value = "post" },
            .{ .key = "action", .value = "/api/clearMessages" },
        },
        .children = blk: {
            const c = try alloc.alloc(verve.Node, 1);
            c[0] = .{
                .tag = "button",
                .text = "Clear all",
                .attrs = &.{
                    .{ .key = "type", .value = "submit" },
                    .{ .key = "class", .value = "danger" },
                },
            };
            break :blk c;
        },
    });

    try kids.append(alloc, .{
        .tag = "script",
        .text =
        \\(()=>{const seen=Number(document.body.dataset.tick||0);const es=new EventSource('/events');es.addEventListener('count',(e)=>{const v=Number(e.data);if(!Number.isNaN(v)&&v!==seen){location.reload();}});})();
        ,
    });

    return .{
        .tag = "main",
        .children = try kids.toOwnedSlice(alloc),
        .attrs = blk: {
            // Stamp current message count on <main> via data attribute
            // so the inline script knows what state the page was rendered
            // with.
            var tick_buf: [16]u8 = undefined;
            var tw: std.Io.Writer = .fixed(&tick_buf);
            try tw.print("{d}", .{api.last_count.load(.monotonic)});
            const tick = try alloc.dupe(u8, tw.buffered());

            const attrs = try alloc.alloc(verve.Attr, 1);
            attrs[0] = .{ .key = "data-tick", .value = tick };
            break :blk attrs;
        },
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

    return .{ .tag = "main", .children = kids };
}

pub fn errorPage(
    ctx: *const verve.Context,
    status_code: u16,
    status_text: []const u8,
    message: []const u8,
) !verve.Node {
    const alloc = ctx.alloc();

    var heading_buf: [64]u8 = undefined;
    var hw: std.Io.Writer = .fixed(&heading_buf);
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

    return .{ .tag = "main", .children = kids };
}
