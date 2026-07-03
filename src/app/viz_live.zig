//! Mutable canvas-graph model for the live viz canvas demo (CL1).
//!
//! 256-node jittered-grid graph (16×16), ~495 edges. Mutates each tick
//! (position jitter on a rotating window of 8 nodes). The publisher loop
//! in main.zig calls `vizCanvasAdvanceTick` once per second while the
//! "vizcanvas" push channel has subscribers; the /viz/live-graph.bin route
//! handler calls `packLiveGraph` to serve the current snapshot as
//! canvas_buf binary.

const std = @import("std");
const verve = @import("verve");
const canvas_buf = verve.viz.canvas_buf;

// ---------------------------------------------------------------------------
// Graph dimensions
// ---------------------------------------------------------------------------

pub const LIVE_NODES: u32 = 256;
const GRID_COLS: u32 = 16;
/// Left-neighbour edges (i→i-1 for i>0): LIVE_NODES-1 = 255.
/// Upper-neighbour edges (i→i-GRID_COLS for i>=GRID_COLS): 256-16 = 240.
pub const LIVE_EDGE_COUNT: u32 = (LIVE_NODES - 1) + (LIVE_NODES - GRID_COLS);

// ---------------------------------------------------------------------------
// Mutable model (mutex-protected)
// ---------------------------------------------------------------------------

var canvas_mu: std.atomic.Mutex = .unlocked;
var canvas_seq: u64 = 0;
var canvas_xs: [LIVE_NODES]f32 = undefined;
var canvas_ys: [LIVE_NODES]f32 = undefined;
var canvas_ef: [LIVE_EDGE_COUNT]u32 = undefined;
var canvas_et: [LIVE_EDGE_COUNT]u32 = undefined;
var canvas_initialized: bool = false;

fn lockCanvas() void {
    while (!canvas_mu.tryLock()) std.atomic.spinLoopHint();
}

/// Lay out the grid and wire edges. Must be called under the mutex.
fn initModelLocked() void {
    const SPACING: f32 = 22.0;
    for (0..LIVE_NODES) |i| {
        const col: f32 = @floatFromInt(i % GRID_COLS);
        const row: f32 = @floatFromInt(i / GRID_COLS);
        canvas_xs[i] = col * SPACING;
        canvas_ys[i] = row * SPACING;
    }
    var e: u32 = 0;
    for (0..LIVE_NODES) |i| {
        if (i > 0) {
            canvas_ef[e] = @intCast(i);
            canvas_et[e] = @intCast(i - 1);
            e += 1;
        }
        if (i >= GRID_COLS) {
            canvas_ef[e] = @intCast(i);
            canvas_et[e] = @intCast(i - GRID_COLS);
            e += 1;
        }
    }
    std.debug.assert(e == LIVE_EDGE_COUNT);
    canvas_seq = 0;
    canvas_initialized = true;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Advance the live canvas model one step: jitter a rotating window of 8 node
/// positions and bump `seq`. Serialises a small JSON ping `{"seq":N}` into
/// `buf` and returns it. Returns null only if `buf` is absurdly small (< ~16 B).
/// Called once/sec by `vizCanvasPublisherLoop` in main.zig while subscribers exist.
pub fn vizCanvasAdvanceTick(buf: []u8) ?[]const u8 {
    lockCanvas();
    defer canvas_mu.unlock();
    if (!canvas_initialized) initModelLocked();

    canvas_seq += 1;
    const seq = canvas_seq;

    // Rotate a window of 8 nodes, shifting their positions sinusoidally.
    const stride: u32 = 8;
    const start: u32 = @intCast((seq * stride) % LIVE_NODES);
    for (0..stride) |k| {
        const idx: u32 = (start + @as(u32, @intCast(k))) % LIVE_NODES;
        const phase: f32 = @as(f32, @floatFromInt(seq)) * 0.3 +
            @as(f32, @floatFromInt(idx)) * 0.1;
        canvas_xs[idx] += std.math.sin(phase) * 2.0;
        canvas_ys[idx] += std.math.cos(phase) * 2.0;
    }

    return std.fmt.bufPrint(buf, "{{\"seq\":{d}}}", .{seq}) catch null;
}

/// Pack the current live model as canvas_buf binary. Caller owns the slice.
/// Called by the /viz/live-graph.bin route handler.
pub fn packLiveGraph(alloc: std.mem.Allocator) ![]u8 {
    lockCanvas();
    defer canvas_mu.unlock();
    if (!canvas_initialized) initModelLocked();
    return canvas_buf.packGraph(
        alloc,
        &canvas_xs,
        &canvas_ys,
        &canvas_ef,
        &canvas_et,
    );
}

/// Reset the model to its initial state. Tests call this for isolation.
pub fn resetLiveCanvasModel() void {
    lockCanvas();
    defer canvas_mu.unlock();
    canvas_initialized = false;
    canvas_seq = 0;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "vizCanvasAdvanceTick mutates model and increments seq" {
    const alloc = std.testing.allocator;
    resetLiveCanvasModel();

    var buf: [64]u8 = undefined;

    // First tick — payload must be {"seq":1}.
    const p1 = vizCanvasAdvanceTick(&buf) orelse return error.NullPayload;
    const s1 = try alloc.dupe(u8, p1);
    defer alloc.free(s1);
    try std.testing.expectEqualStrings("{\"seq\":1}", s1);

    // Pack snapshot after tick 1.
    const snap1 = try packLiveGraph(alloc);
    defer alloc.free(snap1);

    // Second tick — payload must be {"seq":2}.
    const p2 = vizCanvasAdvanceTick(&buf) orelse return error.NullPayload;
    const s2 = try alloc.dupe(u8, p2);
    defer alloc.free(s2);
    try std.testing.expectEqualStrings("{\"seq\":2}", s2);

    // Pack snapshot after tick 2.
    const snap2 = try packLiveGraph(alloc);
    defer alloc.free(snap2);

    // The two snapshots must differ (mutation proof).
    try std.testing.expect(!std.mem.eql(u8, snap1, snap2));
}

test "packLiveGraph round-trip size and field values" {
    const alloc = std.testing.allocator;
    resetLiveCanvasModel();

    // Initialise via one tick.
    var buf: [64]u8 = undefined;
    _ = vizCanvasAdvanceTick(&buf);

    const bytes = try packLiveGraph(alloc);
    defer alloc.free(bytes);

    // Byte length must equal sizeFor(LIVE_NODES, LIVE_EDGE_COUNT).
    const expected = canvas_buf.sizeFor(LIVE_NODES, LIVE_EDGE_COUNT);
    try std.testing.expectEqual(@as(usize, expected), bytes.len);

    // Header: node_count at offset 12, edge_count at offset 16.
    const nc = std.mem.readInt(u32, bytes[12..16], .little);
    const ec = std.mem.readInt(u32, bytes[16..20], .little);
    try std.testing.expectEqual(LIVE_NODES, nc);
    try std.testing.expectEqual(LIVE_EDGE_COUNT, ec);

    // hover (offset 20) and select (offset 24) default to -1.
    const hover = std.mem.readInt(i32, bytes[20..24], .little);
    const sel = std.mem.readInt(i32, bytes[24..28], .little);
    try std.testing.expectEqual(@as(i32, -1), hover);
    try std.testing.expectEqual(@as(i32, -1), sel);
}
