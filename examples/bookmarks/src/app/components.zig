const std = @import("std");
const verve = @import("verve");
const api = @import("api.zig");

pub fn page(ctx: *const verve.Context, body: verve.Node) !verve.Node {
    const alloc = ctx.alloc();
    const head_kids = try alloc.alloc(verve.Node, 3);
    head_kids[0] = .{ .tag = "meta", .attrs = &.{.{ .key = "charset", .value = "utf-8" }} };
    head_kids[1] = .{ .tag = "title", .text = "Verve Bookmarks" };
    head_kids[2] = .{
        .tag = "style",
        .text =
        \\body{font:16px system-ui;margin:0;background:#0e0e10;color:#f5f5f5}
        \\main{max-width:48rem;margin:2rem auto;padding:0 1.5rem}
        \\nav{display:flex;gap:1rem;margin-bottom:1.5rem}
        \\nav a{color:#58a6ff;text-decoration:none;padding:.25rem .5rem;border-radius:4px}
        \\nav a:hover{background:#1c1c1f}
        \\h1{margin-top:0}
        \\form.add{display:grid;grid-template-columns:1fr 2fr auto;gap:.5rem;margin:1rem 0}
        \\input{font:inherit;padding:.5rem;background:#1c1c1f;color:inherit;border:1px solid #333;border-radius:4px}
        \\button{font:inherit;padding:.5rem 1rem;background:#1f6feb;color:#fff;border:0;border-radius:4px;cursor:pointer}
        \\button.danger{background:#5b2727}
        \\button.ghost{background:transparent;color:#58a6ff;padding:.25rem .5rem}
        \\button:hover{filter:brightness(1.15)}
        \\.bookmarks{list-style:none;padding:0;margin:1.5rem 0}
        \\.bookmarks li{display:flex;align-items:center;gap:.75rem;padding:.75rem 0;border-bottom:1px solid #222}
        \\.bookmarks li:last-child{border-bottom:0}
        \\.bm-link{flex:1;min-width:0}
        \\.bm-link a{color:#58a6ff;text-decoration:none;display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        \\.bm-link a:hover{text-decoration:underline}
        \\.bm-url{color:#666;font-size:.85em;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        \\.bm-visits{color:#999;font-variant-numeric:tabular-nums;width:5rem;text-align:right}
        \\.empty{padding:2rem;text-align:center;color:#888;border:1px dashed #333;border-radius:8px}
        \\.stats{display:grid;grid-template-columns:repeat(2, 1fr);gap:1rem;margin:1.5rem 0}
        \\.stat{padding:1rem;background:#15151a;border:1px solid #333;border-radius:8px}
        \\.stat-label{color:#888;font-size:.85em}
        \\.stat-value{font-size:2rem;font-weight:600;margin:.25rem 0;font-variant-numeric:tabular-nums}
        ,
    };

    const body_kids = try alloc.alloc(verve.Node, 1);
    body_kids[0] = body;
    const html_kids = try alloc.alloc(verve.Node, 2);
    html_kids[0] = .{ .tag = "head", .children = head_kids };
    html_kids[1] = .{ .tag = "body", .children = body_kids };
    return .{ .tag = "html", .children = html_kids };
}

fn nav(ctx: *const verve.Context) !verve.Node {
    const alloc = ctx.alloc();
    const kids = try alloc.alloc(verve.Node, 3);
    kids[0] = .{ .tag = "a", .text = "Bookmarks", .attrs = &.{.{ .key = "href", .value = "/" }} };
    kids[1] = .{ .tag = "a", .text = "Stats", .attrs = &.{.{ .key = "href", .value = "/stats" }} };
    kids[2] = .{ .tag = "a", .text = "Server /metrics", .attrs = &.{.{ .key = "href", .value = "/metrics" }} };
    return .{ .tag = "nav", .children = kids };
}

pub fn index(
    ctx: *const verve.Context,
    items: anytype,
) !verve.Node {
    const alloc = ctx.alloc();
    var kids: std.ArrayList(verve.Node) = .empty;

    try kids.append(alloc, try nav(ctx));
    try kids.append(alloc, .{ .tag = "h1", .text = "Bookmarks" });
    try kids.append(alloc, .{
        .tag = "p",
        .text = "Add a link, then click to visit it. Visit counts are tracked server-side and shown in the rightmost column.",
    });

    // Add form.
    const form_kids = try alloc.alloc(verve.Node, 3);
    form_kids[0] = .{
        .tag = "input",
        .attrs = &.{
            .{ .key = "name", .value = "title" },
            .{ .key = "type", .value = "text" },
            .{ .key = "placeholder", .value = "Title" },
            .{ .key = "required", .value = "true" },
            .{ .key = "maxlength", .value = "120" },
        },
    };
    form_kids[1] = .{
        .tag = "input",
        .attrs = &.{
            .{ .key = "name", .value = "url" },
            .{ .key = "type", .value = "url" },
            .{ .key = "placeholder", .value = "https://example.com" },
            .{ .key = "required", .value = "true" },
            .{ .key = "maxlength", .value = "500" },
        },
    };
    form_kids[2] = .{
        .tag = "button",
        .text = "Add",
        .attrs = &.{.{ .key = "type", .value = "submit" }},
    };
    try kids.append(alloc, .{
        .tag = "form",
        .attrs = &.{
            .{ .key = "method", .value = "post" },
            .{ .key = "action", .value = "/api/addBookmark" },
            .{ .key = "class", .value = "add" },
        },
        .children = form_kids,
    });

    // List.
    if (items.len == 0) {
        try kids.append(alloc, .{
            .tag = "div",
            .attrs = &.{.{ .key = "class", .value = "empty" }},
            .text = "No bookmarks yet — add one above.",
        });
    } else {
        const list_kids = try alloc.alloc(verve.Node, items.len);
        for (items, 0..) |entry, i| {
            var idx_buf: [12]u8 = undefined;
            var iw: std.Io.Writer = .fixed(&idx_buf);
            try iw.print("{d}", .{entry.index});
            const idx_text = try alloc.dupe(u8, iw.buffered());

            // Title link wired through /api/recordVisit so visit counts
            // accrue server-side. Anchor target lives in `formaction`
            // attribute to point at the user's URL after the action
            // returns its 303.
            const link_attrs = try alloc.alloc(verve.Attr, 2);
            link_attrs[0] = .{ .key = "href", .value = entry.url };
            link_attrs[1] = .{ .key = "target", .value = "_blank" };

            const url_attrs = try alloc.alloc(verve.Attr, 1);
            url_attrs[0] = .{ .key = "class", .value = "bm-url" };

            const link_inner = try alloc.alloc(verve.Node, 2);
            link_inner[0] = .{ .tag = "a", .text = entry.title, .attrs = link_attrs };
            link_inner[1] = .{ .tag = "div", .text = entry.url, .attrs = url_attrs };

            var visits_buf: [16]u8 = undefined;
            var vw: std.Io.Writer = .fixed(&visits_buf);
            try vw.print("{d}", .{entry.visits});

            const remove_attrs = try alloc.alloc(verve.Attr, 3);
            remove_attrs[0] = .{ .key = "type", .value = "hidden" };
            remove_attrs[1] = .{ .key = "name", .value = "index" };
            remove_attrs[2] = .{ .key = "value", .value = idx_text };

            const remove_kids = try alloc.alloc(verve.Node, 2);
            remove_kids[0] = .{ .tag = "input", .attrs = remove_attrs };
            remove_kids[1] = .{
                .tag = "button",
                .text = "Remove",
                .attrs = &.{
                    .{ .key = "type", .value = "submit" },
                    .{ .key = "class", .value = "danger" },
                },
            };

            const li_kids = try alloc.alloc(verve.Node, 3);
            li_kids[0] = .{
                .tag = "div",
                .attrs = &.{.{ .key = "class", .value = "bm-link" }},
                .children = link_inner,
            };
            li_kids[1] = .{
                .tag = "span",
                .text = try alloc.dupe(u8, vw.buffered()),
                .attrs = &.{.{ .key = "class", .value = "bm-visits" }},
            };
            li_kids[2] = .{
                .tag = "form",
                .attrs = &.{
                    .{ .key = "method", .value = "post" },
                    .{ .key = "action", .value = "/api/removeBookmark" },
                },
                .children = remove_kids,
            };
            list_kids[i] = .{ .tag = "li", .children = li_kids };
        }
        try kids.append(alloc, .{
            .tag = "ul",
            .attrs = &.{.{ .key = "class", .value = "bookmarks" }},
            .children = list_kids,
        });
    }

    return .{
        .tag = "main",
        .children = try kids.toOwnedSlice(alloc),
    };
}

pub fn stats(ctx: *const verve.Context, total_bookmarks: usize, total_visits: u64) !verve.Node {
    const alloc = ctx.alloc();
    var kids: std.ArrayList(verve.Node) = .empty;

    try kids.append(alloc, try nav(ctx));
    try kids.append(alloc, .{ .tag = "h1", .text = "App stats" });
    try kids.append(alloc, .{
        .tag = "p",
        .text = "Server-side aggregates exposed alongside the framework's /metrics JSON.",
    });

    var bm_buf: [16]u8 = undefined;
    var bw: std.Io.Writer = .fixed(&bm_buf);
    try bw.print("{d}", .{total_bookmarks});

    var v_buf: [24]u8 = undefined;
    var vw: std.Io.Writer = .fixed(&v_buf);
    try vw.print("{d}", .{total_visits});

    const stat_kids = try alloc.alloc(verve.Node, 2);

    {
        const inner = try alloc.alloc(verve.Node, 2);
        inner[0] = .{ .tag = "div", .text = "Bookmarks", .attrs = &.{.{ .key = "class", .value = "stat-label" }} };
        inner[1] = .{
            .tag = "div",
            .text = try alloc.dupe(u8, bw.buffered()),
            .attrs = &.{.{ .key = "class", .value = "stat-value" }},
        };
        stat_kids[0] = .{
            .tag = "div",
            .attrs = &.{.{ .key = "class", .value = "stat" }},
            .children = inner,
        };
    }
    {
        const inner = try alloc.alloc(verve.Node, 2);
        inner[0] = .{ .tag = "div", .text = "Total visits", .attrs = &.{.{ .key = "class", .value = "stat-label" }} };
        inner[1] = .{
            .tag = "div",
            .text = try alloc.dupe(u8, vw.buffered()),
            .attrs = &.{.{ .key = "class", .value = "stat-value" }},
        };
        stat_kids[1] = .{
            .tag = "div",
            .attrs = &.{.{ .key = "class", .value = "stat" }},
            .children = inner,
        };
    }

    try kids.append(alloc, .{
        .tag = "div",
        .attrs = &.{.{ .key = "class", .value = "stats" }},
        .children = stat_kids,
    });

    try kids.append(alloc, .{
        .tag = "p",
        .text = "Click 'Server /metrics' in the nav above to see per-route latency histograms from the framework itself.",
    });

    return .{
        .tag = "main",
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
