//! verve.viz canvas render path (phase 3) — drives the /viz-canvas <canvas>.
//! Renders a large node-link graph to canvas2d: each frame packs a draw buffer
//! (core/viz/canvas_buf) + calls the bridge `viz_canvas_draw`. Pan/zoom/hover/
//! select via hit-test (no per-element DOM events). Layout is SSR-computed and
//! arrives as props; the chunk only renders + interacts.
const std = @import("std");
const verve = @import("verve");
const cbuf = verve.viz_core.canvas_buf;

extern "verve_runtime" fn viz_canvas_draw(ref_handle: i32, ptr: [*]const u8, len: u32) void;

// The graph is synthesized in the chunk (a deterministic ~1500-node jittered
// grid) rather than delivered via props — the SSR→hydrate scratch buffer (8 KB)
// can't carry a graph this size, and a perf demo needs no server-authored data.
const GRAPH_N: u32 = 1500;
const GRAPH_COLS: u32 = 50;

const MAX_N = 4096;
const MAX_E = 8192;
const MIN_Z = 0.1;
const MAX_Z = 8.0;
const NODE_R: f32 = 4.0;
const BASE_COLOR: u32 = 0x1f6febff;
const HOVER_COLOR: u32 = 0xffd166ff;
const SELECT_COLOR: u32 = 0xff5577ff;
const EDGE_COLOR: u32 = 0x30363dff;
const VIEW_W: f64 = 640;
const VIEW_H: f64 = 420;

// ── per-instance state ───────────────────────────────────────────────────────

const Inst = struct {
    in_use: bool = false,
    vid: u32 = 0,
    canvas_handle: ?i32 = null,
    n: u32 = 0,
    e: u32 = 0,
    xs: [MAX_N]f32 = undefined,
    ys: [MAX_N]f32 = undefined,
    ef: [MAX_E]u32 = undefined,
    et: [MAX_E]u32 = undefined,
    cam_x: f32 = 0,
    cam_y: f32 = 0,
    scale: f32 = 1,
    hover: i32 = -1,
    select: i32 = -1,
    panning: bool = false,
    last_x: f64 = 0,
    last_y: f64 = 0,
};

// ── slot machinery ───────────────────────────────────────────────────────────

const MAX_INSTANCES = 2;
var instances: [MAX_INSTANCES]Inst = .{Inst{}} ** MAX_INSTANCES;
// The instance the bridge selected for the in-flight dispatch (frame / event /
// asset callback / restore). Set by `vizcanvas_select`; null = unknown vid
// (every export null-guards → silent no-op).
var current: ?*Inst = null;

fn findSlot(vid: u32) ?*Inst {
    for (&instances) |*it| {
        if (it.in_use and it.vid == vid) return it;
    }
    return null;
}

/// Find this vid's slot (re-hydrate) or claim a free one; fully reset to fresh
/// (`Inst{}`) either way. Returns null if the pool is exhausted
/// (> MAX_INSTANCES islands co-resident).
fn allocSlot(vid: u32) ?*Inst {
    const slot = findSlot(vid) orelse blk: {
        for (&instances) |*it| {
            if (!it.in_use) break :blk it;
        }
        return null;
    };
    slot.* = Inst{};
    slot.vid = vid;
    slot.in_use = true;
    return slot;
}

fn slotIndex(inst: *const Inst) usize {
    return (@intFromPtr(inst) - @intFromPtr(&instances[0])) / @sizeOf(Inst);
}

/// Bridge calls this immediately before every frame / event / asset-callback /
/// restore dispatch, so the export operates on the right instance.
export fn vizcanvas_select(root_id: u32) void {
    current = findSlot(root_id);
}

/// Bridge calls this when an island's container disconnects. Reclaims the slot
/// so add/remove cycles don't exhaust the pool.
export fn vizcanvas_unmount(root_id: u32) void {
    if (findSlot(root_id)) |inst| {
        if (current == inst) current = null;
        inst.* = Inst{}; // in_use=false, vid=0
    }
}

// ── module-level transient scratch (NOT per-instance) ────────────────────────
// draw_buf is packed + drawn synchronously each tick; instances never interleave
// within it. Moving it into Inst would needlessly double ~96 KB per instance.

var draw_buf: [cbuf.header_size + MAX_N * 8 + MAX_E * 8]u8 = undefined;

fn clampf(v: f64, lo: f64, hi: f64) f64 {
    return @max(lo, @min(hi, v));
}

// ── hydrate ─────────────────────────────────────────────────────────────────

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    const inst = allocSlot(root_id) orelse return;
    current = inst;
    inst.vid = root_id; // allocSlot already sets vid; keep consistent
    inst.canvas_handle = verve.queryRef(@as([]const u8, "vizcanvas-canvas"));
    inst.hover = -1;
    inst.select = -1;
    inst.panning = false;
    genGraph(inst);
    fitCamera(inst);
    if (inst.canvas_handle != null) {
        var buf: [96]u8 = undefined;
        const args = std.fmt.bufPrint(&buf, "{{\"island\":\"VizGraphCanvas\",\"export\":\"vizcanvas_tick\",\"on\":1,\"vid\":{d}}}", .{inst.vid}) catch return;
        var out: [16]u8 = undefined;
        _ = verve.host("verveRafNamed", args, &out);
    }
}

/// Synthesize the demo graph: GRAPH_N nodes on a deterministic jittered grid,
/// each linked to its left + upper neighbour (index-seeded; no RNG).
fn genGraph(inst: *Inst) void {
    inst.n = @min(GRAPH_N, MAX_N);
    inst.e = 0;
    var i: u32 = 0;
    while (i < inst.n) : (i += 1) {
        const col = i % GRAPH_COLS;
        const row = i / GRAPH_COLS;
        const hsh = (i *% 2654435761) >> 16;
        const jx: f32 = @as(f32, @floatFromInt(hsh % 17)) - 8;
        const jy: f32 = @as(f32, @floatFromInt((hsh / 17) % 17)) - 8;
        inst.xs[i] = @as(f32, @floatFromInt(col)) * 22 + jx;
        inst.ys[i] = @as(f32, @floatFromInt(row)) * 22 + jy;
        if (i > 0 and inst.e < MAX_E) {
            inst.ef[inst.e] = i;
            inst.et[inst.e] = i - 1;
            inst.e += 1;
        }
        if (i >= GRAPH_COLS and inst.e < MAX_E) {
            inst.ef[inst.e] = i;
            inst.et[inst.e] = i - GRAPH_COLS;
            inst.e += 1;
        }
    }
}

/// Fit the camera so the graph's bounding box fills the view (with margin).
fn fitCamera(inst: *Inst) void {
    if (inst.n == 0) {
        inst.cam_x = 0;
        inst.cam_y = 0;
        inst.scale = 1;
        return;
    }
    var minx: f32 = inst.xs[0];
    var maxx: f32 = inst.xs[0];
    var miny: f32 = inst.ys[0];
    var maxy: f32 = inst.ys[0];
    for (0..inst.n) |i| {
        minx = @min(minx, inst.xs[i]);
        maxx = @max(maxx, inst.xs[i]);
        miny = @min(miny, inst.ys[i]);
        maxy = @max(maxy, inst.ys[i]);
    }
    const gw = @max(maxx - minx, 1);
    const gh = @max(maxy - miny, 1);
    const margin: f32 = 30;
    const sx = (@as(f32, VIEW_W) - 2 * margin) / gw;
    const sy = (@as(f32, VIEW_H) - 2 * margin) / gh;
    inst.scale = @floatCast(clampf(@min(sx, sy), MIN_Z, MAX_Z));
    inst.cam_x = margin - minx * inst.scale + (@as(f32, VIEW_W) - 2 * margin - gw * inst.scale) / 2;
    inst.cam_y = margin - miny * inst.scale + (@as(f32, VIEW_H) - 2 * margin - gh * inst.scale) / 2;
}

// ── frame ───────────────────────────────────────────────────────────────────

export fn vizcanvas_tick() i32 {
    const inst = current orelse return 0;
    const h = inst.canvas_handle orelse return 0;
    const hdr = cbuf.Header{
        .cam_x = inst.cam_x,
        .cam_y = inst.cam_y,
        .scale = inst.scale,
        .node_count = inst.n,
        .edge_count = inst.e,
        .hover = inst.hover,
        .select = inst.select,
        .node_r = NODE_R,
        .base_color = BASE_COLOR,
        .hover_color = HOVER_COLOR,
        .select_color = SELECT_COLOR,
        .edge_color = EDGE_COLOR,
    };
    const len = cbuf.pack(&draw_buf, hdr, inst.xs[0..inst.n], inst.ys[0..inst.n], inst.ef[0..inst.e], inst.et[0..inst.e]);
    viz_canvas_draw(h, &draw_buf, len);
    return 1; // keep the loop alive (interaction redraws)
}

// ── interaction (pan/zoom/hover/select via hit-test) ─────────────────────────

/// Client (clientX/Y) → world graph coords, via the canvas rect + camera. The
/// draw transform works in CSS-pixel space (VIEW_W/H); `refRect` is CSS px.
fn clientToWorld(inst: *const Inst, cx: f64, cy: f64, wx: *f64, wy: *f64) bool {
    const h = inst.canvas_handle orelse return false;
    const r = verve.refRect(h);
    if (r.w <= 0 or r.h <= 0) return false;
    const px = (cx - r.x) / r.w * VIEW_W;
    const py = (cy - r.y) / r.h * VIEW_H;
    wx.* = (px - inst.cam_x) / inst.scale;
    wy.* = (py - inst.cam_y) / inst.scale;
    return true;
}

/// Nearest node within ~NODE_R (world units) of (wx,wy); -1 if none.
fn pick(inst: *const Inst, wx: f64, wy: f64) i32 {
    const rr = (@as(f64, NODE_R) / inst.scale) * (@as(f64, NODE_R) / inst.scale) + 4;
    var best: i32 = -1;
    var bestd: f64 = rr;
    for (0..inst.n) |i| {
        const dx = @as(f64, inst.xs[i]) - wx;
        const dy = @as(f64, inst.ys[i]) - wy;
        const d = dx * dx + dy * dy;
        if (d <= bestd) {
            bestd = d;
            best = @intCast(i);
        }
    }
    return best;
}

export fn vizcanvas_pointerdown() void {
    const inst = current orelse return;
    if (verve.eventButton() != 0) return; // primary button only
    verve.eventCapturePointer();
    var wx: f64 = 0;
    var wy: f64 = 0;
    if (!clientToWorld(inst, verve.eventCoordX(), verve.eventCoordY(), &wx, &wy)) return;
    const hit = pick(inst, wx, wy);
    if (hit >= 0) {
        inst.select = hit;
    } else {
        inst.panning = true;
        inst.last_x = verve.eventCoordX();
        inst.last_y = verve.eventCoordY();
    }
}

export fn vizcanvas_pointermove() void {
    const inst = current orelse return;
    const cx = verve.eventCoordX();
    const cy = verve.eventCoordY();
    if (inst.panning) {
        const h = inst.canvas_handle orelse return;
        const r = verve.refRect(h);
        if (r.w <= 0) return;
        inst.cam_x += @floatCast((cx - inst.last_x) / r.w * VIEW_W);
        inst.cam_y += @floatCast((cy - inst.last_y) / r.h * VIEW_H);
        inst.last_x = cx;
        inst.last_y = cy;
        return;
    }
    var wx: f64 = 0;
    var wy: f64 = 0;
    if (clientToWorld(inst, cx, cy, &wx, &wy)) inst.hover = pick(inst, wx, wy);
}

export fn vizcanvas_pointerup() void {
    const inst = current orelse return;
    inst.panning = false;
}

export fn vizcanvas_wheel() void {
    const inst = current orelse return;
    var wx: f64 = 0;
    var wy: f64 = 0;
    if (!clientToWorld(inst, verve.eventCoordX(), verve.eventCoordY(), &wx, &wy)) return;
    // world point under the cursor, in canvas px:
    const px = wx * inst.scale + inst.cam_x;
    const py = wy * inst.scale + inst.cam_y;
    const factor = std.math.exp(-verve.eventDeltaY() * 0.001);
    const nz = clampf(@as(f64, inst.scale) * factor, MIN_Z, MAX_Z);
    inst.scale = @floatCast(nz);
    // keep (wx,wy) under the same canvas px:
    inst.cam_x = @floatCast(px - wx * nz);
    inst.cam_y = @floatCast(py - wy * nz);
}
