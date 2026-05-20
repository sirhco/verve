//! Named children slots for component composition. Mirrors Leptos's
//! typed Slot system: a parent component declares the slots it
//! accepts; the caller fills each one with content. This is what
//! makes layout components ergonomic without resorting to positional
//! children or magic prop names.
//!
//! Phase 6's slot is intentionally minimal — a typed Slot identifier
//! plus a SlotMap the parent walks at render time. Phase 8's island
//! runtime extends this with reactive slot updates.

const std = @import("std");
const Node = @import("node.zig").Node;

/// Identifies a slot position on a parent component. Components
/// declare:
///
///     pub const slots = struct {
///         pub const header: Slot = .{ .name = "header" };
///         pub const body: Slot = .{ .name = "body" };
///     };
///
/// And the caller writes:
///
///     ctx.fillSlot(MyCard.slots.body, body_node)
///
/// At render time the parent does `slot_map.get(slot.name)` to find
/// the matching content.
pub const Slot = struct {
    name: []const u8,
};

/// Per-component slot storage. The parent typically allocates one of
/// these on the request arena and asks each child component to fill
/// it. Order-preserving so multi-fill slots (e.g. card actions) end
/// up in the order the caller declared them.
pub const SlotMap = struct {
    pub const Entry = struct {
        slot: []const u8,
        content: *Node,
    };

    entries: std.ArrayListUnmanaged(Entry) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SlotMap {
        return .{ .allocator = allocator };
    }

    pub fn fill(self: *SlotMap, slot: Slot, content: *Node) !void {
        try self.entries.append(self.allocator, .{ .slot = slot.name, .content = content });
    }

    /// Return the first node filled into `slot`. Multi-fill slots
    /// should iterate `findAll` instead.
    pub fn find(self: *const SlotMap, slot: Slot) ?*Node {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.slot, slot.name)) return e.content;
        }
        return null;
    }

    /// Iterate all nodes filled into `slot`. Useful for the standard
    /// "list of cards" / "list of actions" pattern.
    pub fn findAll(self: *const SlotMap, slot: Slot, out: *std.ArrayListUnmanaged(*Node), allocator: std.mem.Allocator) !void {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.slot, slot.name)) try out.append(allocator, e.content);
        }
    }
};

// ---- tests ------------------------------------------------------------

const testing = std.testing;
const Context = @import("context.zig").Context;

test "SlotMap fills and finds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const Header: Slot = .{ .name = "header" };
    const Body: Slot = .{ .name = "body" };

    var map = SlotMap.init(arena.allocator());
    try map.fill(Header, ctx.h1("Hello"));
    try map.fill(Body, ctx.p().text("Greetings."));

    try testing.expectEqualStrings("h1", map.find(Header).?.tag);
    try testing.expectEqualStrings("p", map.find(Body).?.tag);
    try testing.expect(map.find(.{ .name = "footer" }) == null);
}

test "SlotMap findAll returns all matches in order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const Action: Slot = .{ .name = "action" };
    var map = SlotMap.init(arena.allocator());
    try map.fill(Action, ctx.button("Save"));
    try map.fill(Action, ctx.button("Cancel"));

    var out: std.ArrayListUnmanaged(*Node) = .empty;
    defer out.deinit(arena.allocator());
    try map.findAll(Action, &out, arena.allocator());
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("Save", out.items[0].text_content.?);
    try testing.expectEqualStrings("Cancel", out.items[1].text_content.?);
}
