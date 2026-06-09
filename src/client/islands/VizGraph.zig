//! VizGraph island chunk (shared-runtime). Reveals a server-rendered
//! `verve.viz` graph: each node `<g>` is scaled from 0→1 in place over a short
//! animation, driven by `requestAnimationFrame` and `setRefAttr("transform")`.
//!
//! Phase-1 contract: the SVG element set is fixed by the server (each node
//! group carries `data-ref="viz-node-<i>"`); the client only mutates existing
//! attributes — no element creation, no new bridge events. The final positions
//! arrive as typed props (`VizGraph.Props`, base64 `data-props`), so the reveal
//! lands exactly on the SSR layout and the no-JS view is already correct.

const std = @import("std");
const verve = @import("verve");

/// Mirrors `app/islands.zig`'s `VizGraph.Props`. Kept local because Zig
/// forbids importing across the island chunk's module boundary; the serialize
/// codec is positional, so field order + types are what must match (they do).
const Props = struct {
    xs: []const f64,
    ys: []const f64,
};

/// Upper bound on animated nodes; positions are copied into static storage so
/// they survive across animation frames (the chunk arena recycles per dispatch).
const MAX_NODES = 256;
const TOTAL_FRAMES: u32 = 24;

var fx: [MAX_NODES]f64 = undefined;
var fy: [MAX_NODES]f64 = undefined;
var node_count: usize = 0;
var frame: u32 = 0;

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = root_id;
    if (props_len == 0) return;
    const bytes = @as([*]const u8, @ptrFromInt(@as(usize, props_ptr)))[0..props_len];

    const mark = verve.chunkArenaMark();
    defer verve.chunkArenaReset(mark);
    const props = verve.decodeProps(Props, bytes, verve.chunkArena()) catch return;

    node_count = @min(@min(props.xs.len, props.ys.len), MAX_NODES);
    for (0..node_count) |i| {
        fx[i] = props.xs[i];
        fy[i] = props.ys[i];
    }
    frame = 0;
    _ = verve.requestAnimationFrame(&tick);
}

fn tick() void {
    frame += 1;
    const t = @min(1.0, @as(f64, @floatFromInt(frame)) / @as(f64, @floatFromInt(TOTAL_FRAMES)));
    const s = easeOutCubic(t);

    var ref_buf: [32]u8 = undefined;
    var tr_buf: [96]u8 = undefined;
    for (0..node_count) |i| {
        const id: []const u8 = std.fmt.bufPrint(&ref_buf, "viz-node-{d}", .{i}) catch continue;
        const handle = verve.queryRef(id) orelse continue;
        // Scale about the group origin (the node center), so connected edges —
        // anchored at those same centers — stay attached while nodes pop in.
        const transform = std.fmt.bufPrint(&tr_buf, "translate({d},{d}) scale({d})", .{ fx[i], fy[i], s }) catch continue;
        verve.setRefAttr(handle, "transform", transform);
    }

    if (frame < TOTAL_FRAMES) _ = verve.requestAnimationFrame(&tick);
}

fn easeOutCubic(t: f64) f64 {
    const inv = 1.0 - t;
    return 1.0 - inv * inv * inv;
}
