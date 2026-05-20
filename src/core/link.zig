//! `<Link>` component. Server-side this emits a plain anchor with a
//! `data-vlink="1"` marker; the client-side router (in verve.js) hooks
//! delegated clicks on that selector, fetches the target URL, and
//! diffs the response into the current document — head merge plus
//! body content swap — so navigation doesn't lose JS state or reset
//! scroll until we want it to.
//!
//! Falling back to the native anchor behavior is automatic: if the
//! browser has JS disabled or the router script hasn't loaded, a click
//! follows the href normally.

const std = @import("std");
const Context = @import("context.zig").Context;
const Node = @import("node.zig").Node;

pub const LinkOpts = struct {
    /// Optional class applied to the anchor for styling.
    class: ?[]const u8 = null,
    /// When true, the router runs a prefetch on hover.
    prefetch_on_hover: bool = false,
    /// When true, the anchor is annotated with `aria-current` if the
    /// current location matches `href`.
    active_aware: bool = true,
};

pub fn link(ctx: *const Context, href: []const u8, label: []const u8, opts: LinkOpts) *Node {
    var node = ctx.el("a")
        .href(href)
        .attr("data-vlink", "1")
        .text(label);

    if (opts.class) |c| node = node.class(c);
    if (opts.prefetch_on_hover) node = node.attr("data-vprefetch", "hover");

    if (opts.active_aware) {
        if (ctx.location) |loc| if (loc.isActive(href)) {
            node = node.attr("aria-current", "page");
        };
    }
    return node;
}

// ---- tests ------------------------------------------------------------

const testing = std.testing;
const Location = @import("location.zig").Location;

test "link emits data-vlink + href" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const node = link(&ctx, "/about", "About", .{});
    try testing.expectEqualStrings("a", node.tag);
    var has_href = false;
    var has_vlink = false;
    for (node.attrs.items) |a| {
        if (std.mem.eql(u8, a.key, "href") and std.mem.eql(u8, a.value, "/about")) has_href = true;
        if (std.mem.eql(u8, a.key, "data-vlink") and std.mem.eql(u8, a.value, "1")) has_vlink = true;
    }
    try testing.expect(has_href);
    try testing.expect(has_vlink);
    try testing.expectEqualStrings("About", node.text_content.?);
}

test "link adds aria-current when location matches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var loc = Location.parse("/about");
    var ctx = Context.init(&arena);
    ctx.location = &loc;

    const node = link(&ctx, "/about", "About", .{});
    var has_current = false;
    for (node.attrs.items) |a| {
        if (std.mem.eql(u8, a.key, "aria-current") and std.mem.eql(u8, a.value, "page")) has_current = true;
    }
    try testing.expect(has_current);
}

test "link.class applies when supplied" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const node = link(&ctx, "/x", "x", .{ .class = "nav-link" });
    var has_class = false;
    for (node.attrs.items) |a| {
        if (std.mem.eql(u8, a.key, "class") and std.mem.eql(u8, a.value, "nav-link")) has_class = true;
    }
    try testing.expect(has_class);
}
