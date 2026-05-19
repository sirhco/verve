const std = @import("std");
const verve = @import("verve");
const api = @import("api.zig");

pub fn page(ctx: *const verve.Context, body: verve.Node) !verve.Node {
    const alloc = ctx.alloc();
    const head_kids = try alloc.alloc(verve.Node, 3);
    head_kids[0] = .{ .tag = "meta", .attrs = &.{.{ .key = "charset", .value = "utf-8" }} };
    head_kids[1] = .{ .tag = "title", .text = "Verve Poll" };
    head_kids[2] = .{
        .tag = "style",
        .text =
        \\body{font:16px system-ui;margin:0;background:#0e0e10;color:#f5f5f5}
        \\main{max-width:36rem;margin:3rem auto;padding:0 1.5rem}
        \\h1{margin-top:0}
        \\.question{font-size:1.25rem;margin:1rem 0 1.5rem}
        \\.row{display:flex;align-items:center;gap:1rem;padding:.75rem 0;border-bottom:1px solid #222}
        \\.row:last-of-type{border-bottom:0}
        \\.label{flex:1;font-weight:600}
        \\.bar{flex:2;height:.5rem;background:#1c1c1f;border-radius:4px;overflow:hidden}
        \\.bar > span{display:block;height:100%;background:#1f6feb;transition:width .25s ease}
        \\.tally{width:5rem;text-align:right;font-variant-numeric:tabular-nums;color:#bbb}
        \\form.vote{display:inline}
        \\button{font:inherit;padding:.4rem .9rem;background:#1f6feb;color:#fff;border:0;border-radius:4px;cursor:pointer}
        \\button.danger{background:#5b2727}
        \\button:hover{filter:brightness(1.15)}
        \\.actions{display:flex;justify-content:flex-end;margin-top:1rem}
        \\.muted{color:#888;font-size:.9em}
        ,
    };

    const body_kids = try alloc.alloc(verve.Node, 1);
    body_kids[0] = body;

    const html_kids = try alloc.alloc(verve.Node, 2);
    html_kids[0] = .{ .tag = "head", .children = head_kids };
    html_kids[1] = .{ .tag = "body", .children = body_kids };
    return .{ .tag = "html", .children = html_kids };
}

pub fn poll(ctx: *const verve.Context) !verve.Node {
    const alloc = ctx.alloc();

    var totals: u64 = 0;
    var loads: [api.CANDIDATES.len]u32 = undefined;
    for (&api.tallies, &loads) |*v, *out| {
        out.* = v.load(.monotonic);
        totals += out.*;
    }

    var kids: std.ArrayList(verve.Node) = .empty;

    try kids.append(alloc, .{ .tag = "h1", .text = "Indentation showdown" });
    try kids.append(alloc, .{
        .tag = "p",
        .attrs = &.{.{ .key = "class", .value = "question" }},
        .text = "Pick your favorite. Page auto-refreshes on every vote across all browsers.",
    });

    // One row per candidate.
    for (api.CANDIDATES, loads, 0..) |label, votes, idx| {
        const row_kids = try alloc.alloc(verve.Node, 4);
        row_kids[0] = .{
            .tag = "span",
            .attrs = &.{.{ .key = "class", .value = "label" }},
            .text = label,
        };

        const pct: u32 = if (totals == 0) 0 else @intCast((@as(u64, votes) * 100) / totals);
        var pct_buf: [16]u8 = undefined;
        var pw: std.Io.Writer = .fixed(&pct_buf);
        try pw.print("width:{d}%", .{pct});
        const style_text = try alloc.dupe(u8, pw.buffered());

        const bar_inner = try alloc.alloc(verve.Node, 1);
        const inner_attrs = try alloc.alloc(verve.Attr, 1);
        inner_attrs[0] = .{ .key = "style", .value = style_text };
        bar_inner[0] = .{ .tag = "span", .attrs = inner_attrs };
        row_kids[1] = .{
            .tag = "div",
            .attrs = &.{.{ .key = "class", .value = "bar" }},
            .children = bar_inner,
        };

        var tally_buf: [16]u8 = undefined;
        var tw: std.Io.Writer = .fixed(&tally_buf);
        try tw.print("{d} ({d}%)", .{ votes, pct });
        row_kids[2] = .{
            .tag = "span",
            .attrs = &.{.{ .key = "class", .value = "tally" }},
            .text = try alloc.dupe(u8, tw.buffered()),
        };

        var idx_buf: [12]u8 = undefined;
        var iw: std.Io.Writer = .fixed(&idx_buf);
        try iw.print("{d}", .{idx});
        const idx_text = try alloc.dupe(u8, iw.buffered());

        const hidden_attrs = try alloc.alloc(verve.Attr, 3);
        hidden_attrs[0] = .{ .key = "type", .value = "hidden" };
        hidden_attrs[1] = .{ .key = "name", .value = "candidate" };
        hidden_attrs[2] = .{ .key = "value", .value = idx_text };

        const form_inner = try alloc.alloc(verve.Node, 2);
        form_inner[0] = .{ .tag = "input", .attrs = hidden_attrs };
        form_inner[1] = .{
            .tag = "button",
            .text = "Vote",
            .attrs = &.{.{ .key = "type", .value = "submit" }},
        };
        row_kids[3] = .{
            .tag = "form",
            .attrs = &.{
                .{ .key = "method", .value = "post" },
                .{ .key = "action", .value = "/api/vote" },
                .{ .key = "class", .value = "vote" },
            },
            .children = form_inner,
        };

        try kids.append(alloc, .{
            .tag = "div",
            .attrs = &.{.{ .key = "class", .value = "row" }},
            .children = row_kids,
        });
    }

    // Total + reset.
    var total_buf: [32]u8 = undefined;
    var tw: std.Io.Writer = .fixed(&total_buf);
    try tw.print("Total votes: {d}", .{totals});
    try kids.append(alloc, .{
        .tag = "p",
        .attrs = &.{.{ .key = "class", .value = "muted" }},
        .text = try alloc.dupe(u8, tw.buffered()),
    });

    const reset_kids = try alloc.alloc(verve.Node, 1);
    reset_kids[0] = .{
        .tag = "button",
        .text = "Reset tallies",
        .attrs = &.{
            .{ .key = "type", .value = "submit" },
            .{ .key = "class", .value = "danger" },
        },
    };
    try kids.append(alloc, .{
        .tag = "form",
        .attrs = &.{
            .{ .key = "method", .value = "post" },
            .{ .key = "action", .value = "/api/resetTallies" },
            .{ .key = "class", .value = "actions" },
        },
        .children = reset_kids,
    });

    // SSE auto-refresh.
    try kids.append(alloc, .{
        .tag = "script",
        .text =
        \\(()=>{const tick=Number(document.body.dataset.tick||0);const es=new EventSource('/events');es.addEventListener('count',(e)=>{const v=Number(e.data);if(!Number.isNaN(v)&&v!==tick){location.reload();}});})();
        ,
    });

    // Stamp current tick on <main> so the script knows the baseline.
    var tick_buf: [16]u8 = undefined;
    var stamp: std.Io.Writer = .fixed(&tick_buf);
    try stamp.print("{d}", .{api.last_count.load(.monotonic)});
    const main_attrs = try alloc.alloc(verve.Attr, 1);
    main_attrs[0] = .{ .key = "data-tick", .value = try alloc.dupe(u8, stamp.buffered()) };

    return .{
        .tag = "main",
        .attrs = main_attrs,
        .children = try kids.toOwnedSlice(alloc),
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
