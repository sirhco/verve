//! Islands — opt-in hydration boundary. Server renders the full HTML
//! inline (so search engines and noscript clients see content), and
//! wraps the subtree in a `<verve-island>` marker carrying the
//! component name + JSON-serialized props. The Phase 8 client runtime
//! (deferred) walks these markers, dynamically loads the per-island
//! WASM chunk, and hydrates the subtree in place.
//!
//! Phase 7's scaffold ships the server-side marker emission + a
//! placeholder client-side custom element that absorbs the marker
//! without changing behavior. Full per-island WASM bundling, hash
//! dedup, and the hydration loader come with Phase 8.

const std = @import("std");
const Context = @import("context.zig").Context;
const Node = @import("node.zig").Node;

/// Per-render island id sequence. The server resets it to 1 at the top of each
/// request (mirrors `renderer.current_nonce`). Each `island()` without an
/// explicit `IslandOpts.id` consumes the next value as its `data-vid`.
///
/// vid 0 is reserved for the route/app scope sentinel (see the client
/// `unmountIsland`/`ensureOwner` handling) — auto-assigned island vids start
/// at 1 so the first island per render is never mis-scoped into the route owner.
pub threadlocal var vid_seq: u32 = 1;

pub fn resetRenderVidSeq() void {
    vid_seq = 1;
}

pub const IslandOpts = struct {
    /// Component identifier (typically `@typeName(Component)`). Phase
    /// 8 uses this to look up the WASM chunk that owns this island.
    name: []const u8,
    /// Pre-serialized props blob (JSON or binary). Passed back to the
    /// island's render fn during hydration. Caller is responsible for
    /// encoding it.
    props: []const u8 = "",
    /// Serialized resource-state blob (from `ctx.islandState(...)`). Recorded
    /// under this island's `vid` and emitted in the page state script so the
    /// client hydrates the resource without re-fetching.
    state: ?[]const u8 = null,
    /// When false, the inline HTML is emitted but no marker is set
    /// (effectively turns the island into a plain SSR subtree). Used
    /// for build-time A/B between island vs static.
    hydrate: bool = true,
    /// Optional stable per-instance id, stamped as `data-vid` on the
    /// marker. Reserved for future per-island disposal — recorded by the
    /// client dispatch but not yet wired to a per-instance owner.
    id: ?u32 = null,
};

fn rewriteBindings(node: *Node, vid: u32, alloc: std.mem.Allocator) void {
    if (node.z_bind_name) |bn| {
        var buf: [256]u8 = undefined;
        const suffixed = vidBindName(bn, vid, &buf);
        if (suffixed.ptr != bn.ptr) node.z_bind_name = alloc.dupe(u8, suffixed) catch bn;
    }
    for (node.attrs.items) |*a| {
        if (std.mem.eql(u8, a.key, "data-ref")) {
            var buf: [256]u8 = undefined;
            const suffixed = vidBindName(a.value, vid, &buf);
            if (suffixed.ptr != a.value.ptr) a.value = alloc.dupe(u8, suffixed) catch a.value;
        }
    }
    for (node.children_list.items) |child| rewriteBindings(child, vid, alloc);
}

/// Wrap `inner` in an island marker. Server emits both the marker AND
/// the inner HTML inline; Phase 8 hydration upgrades the marker to a
/// reactive component.
pub fn island(ctx: *const Context, opts: IslandOpts, inner: *Node) *Node {
    if (!opts.hydrate) return inner;

    const vid = opts.id orelse blk: {
        const v = vid_seq;
        vid_seq += 1;
        break :blk v;
    };

    rewriteBindings(inner, vid, ctx.allocator);

    if (opts.state) |blob| {
        if (@import("island_state.zig").current) |reg| {
            reg.record(vid, blob) catch {};
        }
    }

    var node = ctx.el("verve-island")
        .attr("data-name", opts.name)
        .attr("data-props", opts.props);
    node = node.attrFmt("data-vid", "{d}", .{vid});
    return node.children(.{inner});
}

/// Per-island DOM binding name: `name` for the route scope (vid 0), or
/// `name__v{vid}` for island vid > 0. The server stamps the suffixed form on
/// the island's SSR `z-bind`/`data-ref`; the client drives the DOM with the
/// same suffixed name, so two instances of one component don't cross-update.
/// `__v` is a reserved separator. Result is written into `buf`; returns `name`
/// directly when vid == 0 (or on overflow).
pub fn vidBindName(name: []const u8, vid: u32, buf: []u8) []const u8 {
    if (vid == 0) return name;
    return std.fmt.bufPrint(buf, "{s}__v{d}", .{ name, vid }) catch name;
}

// ---- tests ------------------------------------------------------------

const testing = std.testing;

test "island wraps subtree with data-name and data-props" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const inner = ctx.div().class("counter").text("0");
    const wrapped = island(&ctx, .{ .name = "Counter", .props = "{}" }, inner);

    try testing.expectEqualStrings("verve-island", wrapped.tag);
    var has_name = false;
    var has_props = false;
    for (wrapped.attrs.items) |a| {
        if (std.mem.eql(u8, a.key, "data-name") and std.mem.eql(u8, a.value, "Counter")) has_name = true;
        if (std.mem.eql(u8, a.key, "data-props") and std.mem.eql(u8, a.value, "{}")) has_props = true;
    }
    try testing.expect(has_name);
    try testing.expect(has_props);
    try testing.expectEqual(@as(usize, 1), wrapped.children_list.items.len);
}

test "island hydrate=false returns inner unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const inner = ctx.div().class("static");
    const wrapped = island(&ctx, .{ .name = "x", .hydrate = false }, inner);
    try testing.expect(wrapped == inner);
}

test "island stamps data-vid when an id is provided" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const inner = ctx.div().class("counter").text("0");
    const wrapped = island(&ctx, .{ .name = "Counter", .props = "{}", .id = 7 }, inner);

    var has_vid = false;
    for (wrapped.attrs.items) |a| {
        if (std.mem.eql(u8, a.key, "data-vid") and std.mem.eql(u8, a.value, "7")) has_vid = true;
    }
    try testing.expect(has_vid);
}

test "island auto-assigns sequential data-vid per render" {
    resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const a = island(&ctx, .{ .name = "Counter" }, ctx.div());
    const b = island(&ctx, .{ .name = "Counter" }, ctx.div());

    try testing.expectEqualStrings("1", attrValue(a, "data-vid").?);
    try testing.expectEqualStrings("2", attrValue(b, "data-vid").?);
}

test "explicit id overrides the auto sequence" {
    resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const a = island(&ctx, .{ .name = "X", .id = 42 }, ctx.div());
    try testing.expectEqualStrings("42", attrValue(a, "data-vid").?);
}

fn attrValue(node: *Node, key: []const u8) ?[]const u8 {
    for (node.attrs.items) |a| {
        if (std.mem.eql(u8, a.key, key)) return a.value;
    }
    return null;
}

test "vidBindName suffixes only for non-zero vid" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("counter", vidBindName("counter", 0, &buf));
    try testing.expectEqualStrings("counter__v1", vidBindName("counter", 1, &buf));
    try testing.expectEqualStrings("counter__v42", vidBindName("counter", 42, &buf));
}

test "island records its state blob under the assigned vid" {
    const island_state = @import("island_state.zig");
    var reg = island_state.Registry.init(testing.allocator);
    defer reg.deinit();
    island_state.current = &reg;
    defer island_state.current = null;
    resetRenderVidSeq();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const blob = try ctx.islandState(.{ .n = @as(i32, 7), .label = @as([]const u8, "hi") });
    _ = island(&ctx, .{ .name = "Counter", .state = blob }, ctx.div());

    try testing.expectEqual(@as(usize, 1), reg.entries.items.len);
    try testing.expectEqual(@as(u32, 1), reg.entries.items[0].vid);
    try testing.expectEqual(@as(i32, 7), (try island_state.lookup(reg.entries.items[0].blob, "n")).?.i32);
    try testing.expectEqualStrings("hi", (try island_state.lookup(reg.entries.items[0].blob, "label")).?.str);
}

test "island suffixes inner z-bind and data-ref by vid" {
    resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const inner1 = ctx.div().children(.{
        ctx.span().bind("counter"),
        ctx.span().attr("data-ref", "lbl"),
        ctx.el("button").attr("z-on-click", "bump"),
    });
    _ = island(&ctx, .{ .name = "Counter" }, inner1); // vid 1

    const inner2 = ctx.div().children(.{ ctx.span().bind("counter") });
    _ = island(&ctx, .{ .name = "Counter" }, inner2); // vid 2

    try testing.expectEqualStrings("counter__v1", inner1.children_list.items[0].z_bind_name.?);
    try testing.expectEqualStrings("lbl__v1", attrVal(inner1.children_list.items[1], "data-ref").?);
    try testing.expectEqualStrings("bump", attrVal(inner1.children_list.items[2], "z-on-click").?);
    try testing.expectEqualStrings("counter__v2", inner2.children_list.items[0].z_bind_name.?);
}

test "island hydrate=false leaves inner unchanged" {
    resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    const inner = ctx.span().bind("counter");
    _ = island(&ctx, .{ .name = "X", .hydrate = false }, inner);
    try testing.expectEqualStrings("counter", inner.z_bind_name.?);
}

fn attrVal(node: *Node, key: []const u8) ?[]const u8 {
    for (node.attrs.items) |a| if (std.mem.eql(u8, a.key, key)) return a.value;
    return null;
}

test "islandStateStruct records a serialized struct under the vid" {
    const island_state = @import("island_state.zig");
    var reg = island_state.Registry.init(testing.allocator);
    defer reg.deinit();
    island_state.current = &reg;
    defer island_state.current = null;
    resetRenderVidSeq();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const Cfg = struct { w: u32, name: []const u8 };
    const sblob = try ctx.islandStateStruct("cfg", Cfg{ .w = 4, .name = "grid" });
    _ = island(&ctx, .{ .name = "Board", .state = sblob }, ctx.div());

    try testing.expectEqual(@as(usize, 1), reg.entries.items.len);
    const v = (try island_state.lookup(reg.entries.items[0].blob, "cfg")).?;
    const got = try @import("serialize.zig").decode(Cfg, v.str, arena.allocator());
    try testing.expectEqual(@as(u32, 4), got.w);
    try testing.expectEqualStrings("grid", got.name);
}
