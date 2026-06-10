//! Wire deltas for live graph streaming. Instead of shipping a full
//! `{nodes, edges}` snapshot every tick, the server diffs the old and new
//! graphs into a small op list and publishes
//! `{"seq":N,"ops":[{"op":"+n",...},...]}` over the push channel. The client
//! applies ops to its model and reconciles; a `seq` gap means it missed a
//! frame and must resync via the pull path (`/api/vizGraph`).
//!
//! Op grammar (`op` field): `+n` add node, `-n` remove node, `~n` relabel
//! node, `+e` add edge, `-e` remove edge. Nodes key on `id`; edges on the
//! `from|to` pair.

const std = @import("std");
const graph = @import("graph.zig");

pub const GraphNode = graph.GraphNode;
pub const GraphEdge = graph.GraphEdge;

pub const Op = union(enum) {
    add_node: struct { id: []const u8, label: []const u8 },
    remove_node: struct { id: []const u8 },
    update_node: struct { id: []const u8, label: []const u8 },
    add_edge: struct { from: []const u8, to: []const u8 },
    remove_edge: struct { from: []const u8, to: []const u8 },
};

/// Keyed diff old → new. Removals first (so an id reused with a new label
/// never coexists with its old self), then adds, relabels, edge changes.
/// Slices in the returned ops alias the input graphs; caller owns the op
/// slice (arena).
pub fn diffGraphs(
    a: std.mem.Allocator,
    old_nodes: []const GraphNode,
    old_edges: []const GraphEdge,
    new_nodes: []const GraphNode,
    new_edges: []const GraphEdge,
) ![]Op {
    var ops: std.ArrayList(Op) = .empty;

    for (old_nodes) |on| {
        if (findNode(new_nodes, on.id) == null) {
            try ops.append(a, .{ .remove_node = .{ .id = on.id } });
        }
    }
    for (new_nodes) |nn| {
        if (findNode(old_nodes, nn.id)) |on| {
            if (!std.mem.eql(u8, on.label, nn.label)) {
                try ops.append(a, .{ .update_node = .{ .id = nn.id, .label = nn.label } });
            }
        } else {
            try ops.append(a, .{ .add_node = .{ .id = nn.id, .label = nn.label } });
        }
    }
    for (old_edges) |oe| {
        if (!hasEdge(new_edges, oe)) {
            try ops.append(a, .{ .remove_edge = .{ .from = oe.from, .to = oe.to } });
        }
    }
    for (new_edges) |ne| {
        if (!hasEdge(old_edges, ne)) {
            try ops.append(a, .{ .add_edge = .{ .from = ne.from, .to = ne.to } });
        }
    }
    return ops.toOwnedSlice(a);
}

fn findNode(nodes: []const GraphNode, id: []const u8) ?GraphNode {
    for (nodes) |n| if (std.mem.eql(u8, n.id, id)) return n;
    return null;
}

fn hasEdge(edges: []const GraphEdge, e: GraphEdge) bool {
    for (edges) |x| {
        if (std.mem.eql(u8, x.from, e.from) and std.mem.eql(u8, x.to, e.to)) return true;
    }
    return false;
}

/// Serialize `{"seq":N,"ops":[...]}` into `buf`. Errors when the frame
/// doesn't fit (the publisher should then fall back to a resync frame).
pub fn writeDeltaJson(buf: []u8, seq: u64, ops: []const Op) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.print("{{\"seq\":{d},\"ops\":[", .{seq});
    for (ops, 0..) |op, i| {
        if (i != 0) try w.writeAll(",");
        switch (op) {
            .add_node => |o| {
                try w.writeAll("{\"op\":\"+n\",\"id\":");
                try writeJsonString(&w, o.id);
                try w.writeAll(",\"label\":");
                try writeJsonString(&w, o.label);
                try w.writeAll("}");
            },
            .remove_node => |o| {
                try w.writeAll("{\"op\":\"-n\",\"id\":");
                try writeJsonString(&w, o.id);
                try w.writeAll("}");
            },
            .update_node => |o| {
                try w.writeAll("{\"op\":\"~n\",\"id\":");
                try writeJsonString(&w, o.id);
                try w.writeAll(",\"label\":");
                try writeJsonString(&w, o.label);
                try w.writeAll("}");
            },
            .add_edge => |o| {
                try w.writeAll("{\"op\":\"+e\",\"from\":");
                try writeJsonString(&w, o.from);
                try w.writeAll(",\"to\":");
                try writeJsonString(&w, o.to);
                try w.writeAll("}");
            },
            .remove_edge => |o| {
                try w.writeAll("{\"op\":\"-e\",\"from\":");
                try writeJsonString(&w, o.from);
                try w.writeAll(",\"to\":");
                try writeJsonString(&w, o.to);
                try w.writeAll("}");
            },
        }
    }
    try w.writeAll("]}");
    return w.buffered();
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (c < 0x20) {
            try w.print("\\u{x:0>4}", .{c});
        } else {
            try w.writeAll(&.{c});
        },
    };
    try w.writeAll("\"");
}

pub const Applied = struct { nodes: []GraphNode, edges: []GraphEdge };

/// Apply `ops` to a graph, returning the new node/edge sets (arena-owned).
/// This is the canonical apply semantics the wasm chunk mirrors against its
/// fixed-capacity model arrays: removes drop the keyed entry (and a removed
/// node's incident edges), adds append, relabels rewrite in place; redundant
/// ops are no-ops.
pub fn applyOps(
    a: std.mem.Allocator,
    nodes: []const GraphNode,
    edges: []const GraphEdge,
    ops: []const Op,
) !Applied {
    var ns: std.ArrayList(GraphNode) = .empty;
    try ns.appendSlice(a, nodes);
    var es: std.ArrayList(GraphEdge) = .empty;
    try es.appendSlice(a, edges);

    for (ops) |op| switch (op) {
        .add_node => |o| {
            if (indexOfNode(ns.items, o.id) == null) {
                try ns.append(a, .{ .id = o.id, .label = o.label });
            }
        },
        .remove_node => |o| {
            if (indexOfNode(ns.items, o.id)) |i| {
                _ = ns.orderedRemove(i);
                var k: usize = 0;
                while (k < es.items.len) {
                    const e = es.items[k];
                    if (std.mem.eql(u8, e.from, o.id) or std.mem.eql(u8, e.to, o.id)) {
                        _ = es.orderedRemove(k);
                    } else k += 1;
                }
            }
        },
        .update_node => |o| {
            if (indexOfNode(ns.items, o.id)) |i| ns.items[i].label = o.label;
        },
        .add_edge => |o| {
            const e = GraphEdge{ .from = o.from, .to = o.to };
            if (!hasEdge(es.items, e)) try es.append(a, e);
        },
        .remove_edge => |o| {
            for (es.items, 0..) |e, i| {
                if (std.mem.eql(u8, e.from, o.from) and std.mem.eql(u8, e.to, o.to)) {
                    _ = es.orderedRemove(i);
                    break;
                }
            }
        },
    };
    return .{ .nodes = try ns.toOwnedSlice(a), .edges = try es.toOwnedSlice(a) };
}

fn indexOfNode(nodes: []const GraphNode, id: []const u8) ?usize {
    for (nodes, 0..) |n, i| if (std.mem.eql(u8, n.id, id)) return i;
    return null;
}

// ---- tests ---------------------------------------------------------------

const testing = std.testing;

test "diff of equal graphs is empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const nodes = [_]GraphNode{ .{ .id = "a", .label = "A" }, .{ .id = "b", .label = "B" } };
    const edges = [_]GraphEdge{.{ .from = "a", .to = "b" }};
    const ops = try diffGraphs(arena.allocator(), &nodes, &edges, &nodes, &edges);
    try testing.expectEqual(@as(usize, 0), ops.len);
}

test "diff produces minimal add/remove/relabel/edge ops" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const old_n = [_]GraphNode{ .{ .id = "a", .label = "A" }, .{ .id = "b", .label = "B" } };
    const old_e = [_]GraphEdge{.{ .from = "a", .to = "b" }};
    const new_n = [_]GraphNode{ .{ .id = "a", .label = "A2" }, .{ .id = "c", .label = "C" } };
    const new_e = [_]GraphEdge{.{ .from = "a", .to = "c" }};
    const ops = try diffGraphs(arena.allocator(), &old_n, &old_e, &new_n, &new_e);
    try testing.expectEqual(@as(usize, 5), ops.len);
    try testing.expect(ops[0] == .remove_node); // b gone
    try testing.expectEqualStrings("b", ops[0].remove_node.id);
    try testing.expect(ops[1] == .update_node); // a relabeled
    try testing.expectEqualStrings("A2", ops[1].update_node.label);
    try testing.expect(ops[2] == .add_node); // c added
    try testing.expect(ops[3] == .remove_edge);
    try testing.expect(ops[4] == .add_edge);
}

test "writeDeltaJson emits the wire grammar with escaping" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ops = [_]Op{
        .{ .add_node = .{ .id = "n1", .label = "say \"hi\"" } },
        .{ .remove_edge = .{ .from = "a", .to = "b" } },
    };
    var buf: [512]u8 = undefined;
    const json = try writeDeltaJson(&buf, 7, &ops);
    try testing.expectEqualStrings(
        "{\"seq\":7,\"ops\":[{\"op\":\"+n\",\"id\":\"n1\",\"label\":\"say \\\"hi\\\"\"},{\"op\":\"-e\",\"from\":\"a\",\"to\":\"b\"}]}",
        json,
    );
}

test "apply(diff(a,b), a) == b" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old_n = [_]GraphNode{ .{ .id = "core", .label = "core" }, .{ .id = "io", .label = "io" }, .{ .id = "tmp", .label = "t" } };
    const old_e = [_]GraphEdge{ .{ .from = "core", .to = "io" }, .{ .from = "core", .to = "tmp" } };
    const new_n = [_]GraphNode{ .{ .id = "core", .label = "core*" }, .{ .id = "io", .label = "io" }, .{ .id = "ui", .label = "ui" } };
    const new_e = [_]GraphEdge{ .{ .from = "core", .to = "io" }, .{ .from = "io", .to = "ui" } };

    const ops = try diffGraphs(a, &old_n, &old_e, &new_n, &new_e);
    const applied = try applyOps(a, &old_n, &old_e, ops);

    try testing.expectEqual(new_n.len, applied.nodes.len);
    for (new_n) |want| {
        const got = findNode(applied.nodes, want.id) orelse return error.TestExpectedEqual;
        try testing.expectEqualStrings(want.label, got.label);
    }
    try testing.expectEqual(new_e.len, applied.edges.len);
    for (new_e) |want| try testing.expect(hasEdge(applied.edges, want));
}

test "removing a node drops its incident edges" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const nodes = [_]GraphNode{ .{ .id = "a", .label = "" }, .{ .id = "b", .label = "" }, .{ .id = "c", .label = "" } };
    const edges = [_]GraphEdge{ .{ .from = "a", .to = "b" }, .{ .from = "b", .to = "c" }, .{ .from = "a", .to = "c" } };
    const ops = [_]Op{.{ .remove_node = .{ .id = "b" } }};
    const applied = try applyOps(arena.allocator(), &nodes, &edges, &ops);
    try testing.expectEqual(@as(usize, 2), applied.nodes.len);
    try testing.expectEqual(@as(usize, 1), applied.edges.len);
    try testing.expectEqualStrings("a", applied.edges[0].from);
    try testing.expectEqualStrings("c", applied.edges[0].to);
}
