//! Control-flow helpers: `<Show>`, `<For>`, `<Portal>`. Server-side
//! these are straight value-time renders — `show` picks a branch,
//! `forEach` iterates, `portal` annotates the destination. The
//! client-side reconciler that makes them update reactively without a
//! full re-render lands with the Phase 8 island runtime.

const std = @import("std");
const Context = @import("context.zig").Context;
const Node = @import("node.zig").Node;

/// Conditional render. Returns `then_node` when `cond` is true,
/// otherwise `else_node`. Matches the `<Show when=... fallback=...>`
/// API used by SolidJS / Leptos. Both branches are evaluated at the
/// call site — pass cheap-to-build subtrees if either branch is hot.
pub fn show(ctx: *const Context, cond: bool, then_node: *Node, else_node: ?*Node) *Node {
    _ = ctx;
    if (cond) return then_node;
    if (else_node) |n| return n;
    return placeholderEmpty();
}

/// Shared empty fallback node for `show` calls with no else branch.
/// Phase 1's `core/node.zig` exposes a poison sentinel for OOM; we
/// reuse the empty-tag fragment idiom here so the renderer emits zero
/// bytes.
fn placeholderEmpty() *Node {
    return &empty_node;
}

var empty_node: Node = .{ .tag = "" };

/// Keyed iteration. Produces a parent Node containing one child per
/// item; each child is annotated with `data-vkey="<key>"` so the
/// client-side reconciler can move/insert/remove by key on reactive
/// list changes.
///
/// `items_ctx` is a closure context passed to both `keyFn` and
/// `renderFn` — keeps the API consistent with `useEffect`'s pattern
/// and means callers don't need to leak captures via globals.
pub fn forEach(
    ctx: *const Context,
    comptime ItemT: type,
    items: []const ItemT,
    items_ctx: anytype,
    comptime keyFn: fn (@TypeOf(items_ctx), ItemT) []const u8,
    comptime renderFn: fn (@TypeOf(items_ctx), *const Context, ItemT) anyerror!*Node,
) !*Node {
    const list = ctx.el("ul").class("verve-for");
    for (items) |item| {
        const key = keyFn(items_ctx, item);
        const li = ctx.el("li").attr("data-vkey", key);
        const child = renderFn(items_ctx, ctx, item) catch |err| {
            list.err = err;
            return list;
        };
        _ = li.children(.{child});
        _ = list.children(.{li});
    }
    return list;
}

/// Mark a subtree for client-side relocation. Server emits a sentinel
/// `<template data-vportal="<target_selector>">` wrapper around the
/// child. The Phase 7 client runtime moves the contents into the
/// target element on hydrate.
///
/// Server-side this renders inline so SSR HTML stays self-contained
/// (search engines and noscript clients see the content in-place).
pub fn portal(ctx: *const Context, target_selector: []const u8, child: *Node) *Node {
    return ctx.el("template")
        .attr("data-vportal", target_selector)
        .children(.{child});
}

// ---- tests ------------------------------------------------------------

const testing = std.testing;

test "show returns then-node when cond is true" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const a = ctx.div().class("a");
    const b = ctx.div().class("b");
    const result = show(&ctx, true, a, b);
    try testing.expect(result == a);

    const result2 = show(&ctx, false, a, b);
    try testing.expect(result2 == b);
}

test "show with no else returns empty placeholder" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const a = ctx.div().class("a");
    const result = show(&ctx, false, a, null);
    try testing.expectEqualStrings("", result.tag);
}

test "forEach builds keyed list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const Item = struct { id: []const u8, text: []const u8 };
    const items = [_]Item{
        .{ .id = "a", .text = "alpha" },
        .{ .id = "b", .text = "beta" },
    };

    const Helpers = struct {
        fn key(_: void, it: Item) []const u8 {
            return it.id;
        }
        fn render(_: void, c: *const Context, it: Item) anyerror!*Node {
            return c.span().text(it.text);
        }
    };
    const list = try forEach(&ctx, Item, &items, {}, Helpers.key, Helpers.render);

    try testing.expectEqualStrings("ul", list.tag);
    try testing.expectEqualStrings("verve-for", list.attrs.items[0].value);
    try testing.expectEqual(@as(usize, 2), list.children_list.items.len);

    const li_a = list.children_list.items[0];
    try testing.expectEqualStrings("li", li_a.tag);
    try testing.expectEqualStrings("data-vkey", li_a.attrs.items[0].key);
    try testing.expectEqualStrings("a", li_a.attrs.items[0].value);
}

test "portal wraps child in template with data-vportal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const child = ctx.div().class("toast");
    const p = portal(&ctx, "#toasts", child);
    try testing.expectEqualStrings("template", p.tag);
    try testing.expectEqualStrings("data-vportal", p.attrs.items[0].key);
    try testing.expectEqualStrings("#toasts", p.attrs.items[0].value);
    try testing.expectEqual(@as(usize, 1), p.children_list.items.len);
}
