//! ScrollSmoother authoring (verve.anim phase 6). SSR-only — operates on
//! *Node; not re-exported from client_core. Emits the wrapper structure
//! + config attribute the verve.js smoother engine adopts at hydrate:
//!
//!   <div data-smooth-wrapper='{"sm":1.5}'>
//!     <original node, stamped data-smooth-content>
//!   </div>
//!
//! The engine (position:fixed viewport wrapper, content translated by the
//! smoothed scroll, body-height spacer, smoothed trigger math,
//! transform-pins, data-speed/data-lag parallax) lives entirely in the
//! bridge; this file owns config + JSON encoding. Native scrolling is
//! preserved — scrollbar, keyboard, anchors, and a11y keep working; only
//! the visual position eases. One smoother per page.

const std = @import("std");
const node_mod = @import("../node.zig");
const Node = node_mod.Node;

pub const Smoother = struct {
    /// Seconds the content takes to catch up to the scrollbar. 0 =
    /// passthrough (engine skips installation when no parallax exists).
    smooth: f64 = 1.0,
    /// Touch-device smoothing seconds; 0 (default) = native touch
    /// scrolling (native momentum is already smooth — GSAP parity).
    touch: f64 = 0,
    /// Honor `data-speed` / `data-lag` parallax attributes on
    /// descendants.
    parallax: bool = true,

    pub fn validate(self: Smoother) ?anyerror {
        if (!(std.math.isFinite(self.smooth) and self.smooth >= 0))
            return error.SmoothOutOfRange;
        if (!(std.math.isFinite(self.touch) and self.touch >= 0))
            return error.TouchOutOfRange;
        return null;
    }
};

/// `{"sm":1.5,"tch":0.8,"px":0}` — defaults omitted; all-default = `{}`.
pub fn optsToJson(buf: []u8, o: Smoother) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.writeAll("{");
    var first = true;
    if (o.smooth != 1.0) {
        try comma(&w, &first);
        try w.print("\"sm\":{d}", .{o.smooth});
    }
    if (o.touch != 0) {
        try comma(&w, &first);
        try w.print("\"tch\":{d}", .{o.touch});
    }
    if (!o.parallax) {
        try comma(&w, &first);
        try w.writeAll("\"px\":0");
    }
    try w.writeAll("}");
    return w.buffered();
}

fn comma(w: *std.Io.Writer, first: *bool) !void {
    if (!first.*) try w.writeAll(",");
    first.* = false;
}

/// Wrap `node` in the smoother structure and return the WRAPPER — render
/// the return value, not the original node. Errors defer onto `node`
/// (chain pattern).
pub fn apply(node: *Node, opts: Smoother) *Node {
    if (node.err != null) return node;
    if (opts.validate()) |e| {
        node.err = e;
        return node;
    }
    var buf: [96]u8 = undefined;
    const json = optsToJson(&buf, opts) catch {
        node.err = error.OutOfMemory;
        return node;
    };
    _ = node.attr("data-smooth-content", "");
    return node_mod.create(node.arena.?, "div")
        .attrFmt("data-smooth-wrapper", "{s}", .{json})
        .children(node);
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "optsToJson goldens" {
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings("{}", try optsToJson(&buf, .{}));
    try testing.expectEqualStrings(
        "{\"sm\":1.5,\"tch\":0.8}",
        try optsToJson(&buf, .{ .smooth = 1.5, .touch = 0.8 }),
    );
    try testing.expectEqualStrings(
        "{\"px\":0}",
        try optsToJson(&buf, .{ .parallax = false }),
    );
}

test "validate negatives" {
    try testing.expectEqual(@as(?anyerror, error.SmoothOutOfRange), (Smoother{ .smooth = -1 }).validate());
    try testing.expectEqual(@as(?anyerror, error.SmoothOutOfRange), (Smoother{ .smooth = std.math.nan(f64) }).validate());
    try testing.expectEqual(@as(?anyerror, error.TouchOutOfRange), (Smoother{ .touch = -0.1 }).validate());
    try testing.expectEqual(@as(?anyerror, null), (Smoother{ .smooth = 0 }).validate());
}

test "apply builds wrapper > content; errors defer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const content = node_mod.create(a, "main").class("page");
    const wrap = apply(content, .{ .smooth = 1.2 });
    try testing.expect(wrap != content);
    try testing.expectEqualStrings("div", wrap.tag);
    try testing.expectEqualStrings("data-smooth-wrapper", wrap.attrs.items[0].key);
    try testing.expectEqualStrings("{\"sm\":1.2}", wrap.attrs.items[0].value);
    try testing.expectEqual(@as(usize, 1), wrap.children_list.items.len);
    try testing.expect(wrap.children_list.items[0] == content);
    // content stamped
    var found = false;
    for (content.attrs.items) |at| {
        if (std.mem.eql(u8, at.key, "data-smooth-content")) found = true;
    }
    try testing.expect(found);

    const bad = node_mod.create(a, "main");
    const ret = apply(bad, .{ .smooth = -1 });
    try testing.expect(ret == bad);
    try testing.expectEqual(@as(?anyerror, error.SmoothOutOfRange), bad.err);
}
