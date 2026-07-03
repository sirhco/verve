//! Server-side deterministic graph generator for /viz/graph.bin.
//!
//! Mirrors VizGraphCanvas.zig's `genGraph` exactly (jittered grid, left +
//! upper-neighbour edges, index-seeded, no RNG) so that the server-authored
//! binary the chunk fetches is byte-identical to what the chunk would
//! synthesise locally. The graph is packed at build time by
//! tools/viz_graph_gen.zig using canvas_buf.packGraph.
const std = @import("std");

pub const GRAPH_N: u32 = 1500;
pub const GRAPH_COLS: u32 = 50;

pub const Graph = struct {
    xs: []f32,
    ys: []f32,
    ef: []u32,
    et: []u32,

    pub fn deinit(self: Graph, alloc: std.mem.Allocator) void {
        alloc.free(self.xs);
        alloc.free(self.ys);
        alloc.free(self.ef);
        alloc.free(self.et);
    }
};

/// Build the deterministic 1500-node jittered-grid graph.
/// Left-neighbour edge: i → i-1 for every i > 0.
/// Upper-neighbour edge: i → i-GRAPH_COLS for every i >= GRAPH_COLS.
/// Total edges = (GRAPH_N-1) + (GRAPH_N-GRAPH_COLS) = 2949.
pub fn buildGraph(alloc: std.mem.Allocator) !Graph {
    const n = GRAPH_N;
    const exact_e: u32 = (n - 1) + (n - GRAPH_COLS);

    const xs = try alloc.alloc(f32, n);
    errdefer alloc.free(xs);
    const ys = try alloc.alloc(f32, n);
    errdefer alloc.free(ys);
    const ef = try alloc.alloc(u32, exact_e);
    errdefer alloc.free(ef);
    const et = try alloc.alloc(u32, exact_e);
    errdefer alloc.free(et);

    var e: u32 = 0;
    for (0..n) |ii| {
        const i: u32 = @intCast(ii);
        const col = i % GRAPH_COLS;
        const row = i / GRAPH_COLS;
        const hsh = (i *% 2654435761) >> 16;
        const jx: f32 = @as(f32, @floatFromInt(hsh % 17)) - 8;
        const jy: f32 = @as(f32, @floatFromInt((hsh / 17) % 17)) - 8;
        xs[ii] = @as(f32, @floatFromInt(col)) * 22 + jx;
        ys[ii] = @as(f32, @floatFromInt(row)) * 22 + jy;
        if (i > 0) {
            ef[e] = i;
            et[e] = i - 1;
            e += 1;
        }
        if (i >= GRAPH_COLS) {
            ef[e] = i;
            et[e] = i - GRAPH_COLS;
            e += 1;
        }
    }
    std.debug.assert(e == exact_e);

    return Graph{ .xs = xs, .ys = ys, .ef = ef, .et = et };
}
