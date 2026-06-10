//! viz-live — live graph streaming over the server-push hub.
//!
//! The server owns a tiny evolving graph model (3 stable nodes + 0..3
//! ephemeral ones). The framework server spawns a publisher thread because
//! this module declares `vizAdvanceTick`: once per second — and only while
//! someone is subscribed to the `viz` push channel — it advances the model,
//! diffs old vs new (`verve.viz.diffGraphs`), and broadcasts the wire delta
//! (`{"seq":N,"ops":[...]}`) over `GET /push?channel=viz`.
//!
//! The pull endpoint (`Actions.vizGraph`) returns a seq-stamped snapshot of
//! the same model: the island uses it as the push baseline and as the resync
//! source whenever it detects a seq gap.

const std = @import("std");
const verve = @import("verve");

pub const components = @import("components.zig");
pub const islands = @import("islands.zig");
const routes_mod = @import("routes.zig");
pub const Route = routes_mod.Route;
pub const routes = routes_mod.routes;

/// Read by the framework's /metrics + counter endpoints.
pub var last_count: std.atomic.Value(i32) = .init(0);

pub const VizNode = struct { id: []const u8, label: []const u8 };
pub const VizEdge = struct { from: []const u8, to: []const u8 };
/// Seq-stamped pull snapshot — push deltas and pull resyncs share one
/// ordering domain (a delta applies only when `seq == last_seen + 1`).
pub const VizSnapshot = struct { seq: u64, nodes: []const VizNode, edges: []const VizEdge };

var viz_mu: std.atomic.Mutex = .unlocked;
var viz_seq: u64 = 0;
var viz_extra: u32 = 0;

fn lockViz() void {
    while (!viz_mu.tryLock()) std.atomic.spinLoopHint();
}

const VIZ_EPH_IDS = [_][]const u8{ "e0", "e1", "e2" };

/// Fill `nodes`/`edges` with the graph for `extra` ephemeral nodes. All
/// strings are literals, so the filled slices are stable forever.
fn vizBuild(extra: u32, nodes: *[8]verve.viz.GraphNode, edges: *[8]verve.viz.GraphEdge) struct { n: usize, e: usize } {
    nodes[0] = .{ .id = "core", .label = "core" };
    nodes[1] = .{ .id = "io", .label = "io" };
    nodes[2] = .{ .id = "ui", .label = "ui" };
    edges[0] = .{ .from = "core", .to = "io" };
    edges[1] = .{ .from = "core", .to = "ui" };
    var nc: usize = 3;
    var ec: usize = 2;
    var i: usize = 0;
    while (i < extra) : (i += 1) {
        nodes[nc] = .{ .id = VIZ_EPH_IDS[i], .label = VIZ_EPH_IDS[i] };
        edges[ec] = .{ .from = "core", .to = VIZ_EPH_IDS[i] };
        nc += 1;
        ec += 1;
    }
    return .{ .n = nc, .e = ec };
}

/// The framework server's publisher loop calls this once per second while
/// the `viz` channel has subscribers: advance the model one step and
/// serialize the resulting wire delta into `buf`. Declaring this fn is what
/// opts the app into the publisher thread.
pub fn vizAdvanceTick(buf: []u8) ?[]const u8 {
    lockViz();
    defer viz_mu.unlock();

    var old_nodes: [8]verve.viz.GraphNode = undefined;
    var old_edges: [8]verve.viz.GraphEdge = undefined;
    const old = vizBuild(viz_extra, &old_nodes, &old_edges);

    const next_extra = (viz_extra + 1) % 4;
    var new_nodes: [8]verve.viz.GraphNode = undefined;
    var new_edges: [8]verve.viz.GraphEdge = undefined;
    const new = vizBuild(next_extra, &new_nodes, &new_edges);

    var ops_buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&ops_buf);
    const ops = verve.viz.diffGraphs(
        fba.allocator(),
        old_nodes[0..old.n],
        old_edges[0..old.e],
        new_nodes[0..new.n],
        new_edges[0..new.e],
    ) catch return null;

    const frame = verve.viz.writeDeltaJson(buf, viz_seq + 1, ops) catch return null;
    viz_extra = next_extra;
    viz_seq += 1;
    return frame;
}

// Per-thread snapshot storage: `vizGraph` returns slices into these,
// serialized on the same thread by the api_handler — no race, no allocator.
threadlocal var tl_nodes: [8]VizNode = undefined;
threadlocal var tl_edges: [8]VizEdge = undefined;

pub const Actions = struct {
    /// Seq-stamped snapshot of the current model. Pure read — the model only
    /// moves when the publisher ticks it, so pull-only clients see a stable
    /// graph and push clients resync coherently.
    pub fn vizGraph(_: struct {}) VizSnapshot {
        lockViz();
        const extra = viz_extra;
        const seq = viz_seq;
        viz_mu.unlock();

        var nodes: [8]verve.viz.GraphNode = undefined;
        var edges: [8]verve.viz.GraphEdge = undefined;
        const counts = vizBuild(extra, &nodes, &edges);
        for (nodes[0..counts.n], 0..) |nd, i| tl_nodes[i] = .{ .id = nd.id, .label = nd.label };
        for (edges[0..counts.e], 0..) |e, i| tl_edges[i] = .{ .from = e.from, .to = e.to };
        return .{ .seq = seq, .nodes = tl_nodes[0..counts.n], .edges = tl_edges[0..counts.e] };
    }
};
