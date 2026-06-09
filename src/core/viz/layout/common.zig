//! Shared scaffolding for the hierarchical layouts (tree, radial): derive a
//! rooted spanning tree from an undirected edge list via breadth-first search.
//! Non-tree edges are ignored for placement — they still draw, they just
//! don't influence node position.

const std = @import("std");

pub const Edge = [2]usize;

/// Rooted hierarchy over `n` nodes. All slices are indexed by node id and owned
/// by the caller; free via `deinit`.
pub const Hierarchy = struct {
    parent: []usize, // std.math.maxInt(usize) for the root and unreached nodes
    depth: []usize,
    children: [][]usize,
    /// Node ids in BFS visitation order (roots/components first).
    order: []usize,
    alloc: std.mem.Allocator,

    pub const no_parent = std.math.maxInt(usize);

    pub fn deinit(self: *Hierarchy) void {
        for (self.children) |c| self.alloc.free(c);
        self.alloc.free(self.children);
        self.alloc.free(self.parent);
        self.alloc.free(self.depth);
        self.alloc.free(self.order);
    }
};

/// Build a BFS spanning forest rooted at `root`. Any nodes unreachable from
/// `root` are treated as additional roots (depth 0) so disconnected graphs
/// still place every node.
pub fn buildHierarchy(alloc: std.mem.Allocator, n: usize, edges: []const Edge, root: usize) !Hierarchy {
    var adj = try alloc.alloc(std.ArrayList(usize), n);
    defer {
        for (adj) |*a| a.deinit(alloc);
        alloc.free(adj);
    }
    for (adj) |*a| a.* = .empty;
    for (edges) |e| {
        if (e[0] >= n or e[1] >= n or e[0] == e[1]) continue;
        try adj[e[0]].append(alloc, e[1]);
        try adj[e[1]].append(alloc, e[0]);
    }

    const parent = try alloc.alloc(usize, n);
    const depth = try alloc.alloc(usize, n);
    var child_lists = try alloc.alloc(std.ArrayList(usize), n);
    defer alloc.free(child_lists);
    for (child_lists) |*c| c.* = .empty;
    const visited = try alloc.alloc(bool, n);
    defer alloc.free(visited);
    @memset(parent, Hierarchy.no_parent);
    @memset(depth, 0);
    @memset(visited, false);

    var order: std.ArrayList(usize) = .empty;
    errdefer order.deinit(alloc);
    var queue: std.ArrayList(usize) = .empty;
    defer queue.deinit(alloc);

    // Seed with `root` first, then sweep remaining nodes as new roots.
    var seed: usize = 0;
    while (seed <= n) : (seed += 1) {
        const s = if (seed == 0) (if (root < n) root else 0) else seed - 1;
        if (s >= n or visited[s]) continue;
        visited[s] = true;
        try queue.append(alloc, s);
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const u = queue.items[head];
            try order.append(alloc, u);
            for (adj[u].items) |v| {
                if (visited[v]) continue;
                visited[v] = true;
                parent[v] = u;
                depth[v] = depth[u] + 1;
                try child_lists[u].append(alloc, v);
                try queue.append(alloc, v);
            }
        }
        queue.clearRetainingCapacity();
    }

    const children = try alloc.alloc([]usize, n);
    for (child_lists, 0..) |*c, i| children[i] = try c.toOwnedSlice(alloc);

    return .{
        .parent = parent,
        .depth = depth,
        .children = children,
        .order = try order.toOwnedSlice(alloc),
        .alloc = alloc,
    };
}
