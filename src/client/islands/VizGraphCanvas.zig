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

var canvas_handle: ?i32 = null;
var n: u32 = 0;
var e: u32 = 0;
var xs: [MAX_N]f32 = undefined;
var ys: [MAX_N]f32 = undefined;
var ef: [MAX_E]u32 = undefined;
var et: [MAX_E]u32 = undefined;
var cam_x: f32 = 0;
var cam_y: f32 = 0;
var scale: f32 = 1;
var hover: i32 = -1;
var select: i32 = -1;
var panning: bool = false;
var last_x: f64 = 0;
var last_y: f64 = 0;
var draw_buf: [cbuf.header_size + MAX_N * 8 + MAX_E * 8]u8 = undefined;

fn clampf(v: f64, lo: f64, hi: f64) f64 {
    return @max(lo, @min(hi, v));
}

// ── hydrate ─────────────────────────────────────────────────────────────────

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;
    canvas_handle = verve.queryRef(@as([]const u8, "vizcanvas-canvas"));
    hover = -1;
    select = -1;
    panning = false;
    genGraph();
    fitCamera();
    if (canvas_handle != null) {
        var out: [16]u8 = undefined;
        _ = verve.host("verveRafNamed", "{\"island\":\"VizGraphCanvas\",\"export\":\"vizcanvas_tick\",\"on\":1}", &out);
    }
}

/// Synthesize the demo graph: GRAPH_N nodes on a deterministic jittered grid,
/// each linked to its left + upper neighbour (index-seeded; no RNG).
fn genGraph() void {
    n = @min(GRAPH_N, MAX_N);
    e = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const col = i % GRAPH_COLS;
        const row = i / GRAPH_COLS;
        const hsh = (i *% 2654435761) >> 16;
        const jx: f32 = @as(f32, @floatFromInt(hsh % 17)) - 8;
        const jy: f32 = @as(f32, @floatFromInt((hsh / 17) % 17)) - 8;
        xs[i] = @as(f32, @floatFromInt(col)) * 22 + jx;
        ys[i] = @as(f32, @floatFromInt(row)) * 22 + jy;
        if (i > 0 and e < MAX_E) {
            ef[e] = i;
            et[e] = i - 1;
            e += 1;
        }
        if (i >= GRAPH_COLS and e < MAX_E) {
            ef[e] = i;
            et[e] = i - GRAPH_COLS;
            e += 1;
        }
    }
}

/// Fit the camera so the graph's bounding box fills the view (with margin).
fn fitCamera() void {
    if (n == 0) {
        cam_x = 0;
        cam_y = 0;
        scale = 1;
        return;
    }
    var minx: f32 = xs[0];
    var maxx: f32 = xs[0];
    var miny: f32 = ys[0];
    var maxy: f32 = ys[0];
    for (0..n) |i| {
        minx = @min(minx, xs[i]);
        maxx = @max(maxx, xs[i]);
        miny = @min(miny, ys[i]);
        maxy = @max(maxy, ys[i]);
    }
    const gw = @max(maxx - minx, 1);
    const gh = @max(maxy - miny, 1);
    const margin: f32 = 30;
    const sx = (@as(f32, VIEW_W) - 2 * margin) / gw;
    const sy = (@as(f32, VIEW_H) - 2 * margin) / gh;
    scale = @floatCast(clampf(@min(sx, sy), MIN_Z, MAX_Z));
    cam_x = margin - minx * scale + (@as(f32, VIEW_W) - 2 * margin - gw * scale) / 2;
    cam_y = margin - miny * scale + (@as(f32, VIEW_H) - 2 * margin - gh * scale) / 2;
}

// ── frame ───────────────────────────────────────────────────────────────────

export fn vizcanvas_tick() i32 {
    const h = canvas_handle orelse return 0;
    const hdr = cbuf.Header{
        .cam_x = cam_x,
        .cam_y = cam_y,
        .scale = scale,
        .node_count = n,
        .edge_count = e,
        .hover = hover,
        .select = select,
        .node_r = NODE_R,
        .base_color = BASE_COLOR,
        .hover_color = HOVER_COLOR,
        .select_color = SELECT_COLOR,
        .edge_color = EDGE_COLOR,
    };
    const len = cbuf.pack(&draw_buf, hdr, xs[0..n], ys[0..n], ef[0..e], et[0..e]);
    viz_canvas_draw(h, &draw_buf, len);
    return 1; // keep the loop alive (interaction redraws)
}

// ── interaction (pan/zoom/hover/select via hit-test) ─────────────────────────

/// Client (clientX/Y) → world graph coords, via the canvas rect + camera. The
/// draw transform works in CSS-pixel space (VIEW_W/H); `refRect` is CSS px.
fn clientToWorld(cx: f64, cy: f64, wx: *f64, wy: *f64) bool {
    const h = canvas_handle orelse return false;
    const r = verve.refRect(h);
    if (r.w <= 0 or r.h <= 0) return false;
    const px = (cx - r.x) / r.w * VIEW_W;
    const py = (cy - r.y) / r.h * VIEW_H;
    wx.* = (px - cam_x) / scale;
    wy.* = (py - cam_y) / scale;
    return true;
}

/// Nearest node within ~NODE_R (world units) of (wx,wy); -1 if none.
fn pick(wx: f64, wy: f64) i32 {
    const rr = (@as(f64, NODE_R) / scale) * (@as(f64, NODE_R) / scale) + 4;
    var best: i32 = -1;
    var bestd: f64 = rr;
    for (0..n) |i| {
        const dx = @as(f64, xs[i]) - wx;
        const dy = @as(f64, ys[i]) - wy;
        const d = dx * dx + dy * dy;
        if (d <= bestd) {
            bestd = d;
            best = @intCast(i);
        }
    }
    return best;
}

export fn vizcanvas_pointerdown() void {
    if (verve.eventButton() != 0) return; // primary button only
    verve.eventCapturePointer();
    var wx: f64 = 0;
    var wy: f64 = 0;
    if (!clientToWorld(verve.eventCoordX(), verve.eventCoordY(), &wx, &wy)) return;
    const hit = pick(wx, wy);
    if (hit >= 0) {
        select = hit;
    } else {
        panning = true;
        last_x = verve.eventCoordX();
        last_y = verve.eventCoordY();
    }
}

export fn vizcanvas_pointermove() void {
    const cx = verve.eventCoordX();
    const cy = verve.eventCoordY();
    if (panning) {
        const h = canvas_handle orelse return;
        const r = verve.refRect(h);
        if (r.w <= 0) return;
        cam_x += @floatCast((cx - last_x) / r.w * VIEW_W);
        cam_y += @floatCast((cy - last_y) / r.h * VIEW_H);
        last_x = cx;
        last_y = cy;
        return;
    }
    var wx: f64 = 0;
    var wy: f64 = 0;
    if (clientToWorld(cx, cy, &wx, &wy)) hover = pick(wx, wy);
}

export fn vizcanvas_pointerup() void {
    panning = false;
}

export fn vizcanvas_wheel() void {
    var wx: f64 = 0;
    var wy: f64 = 0;
    if (!clientToWorld(verve.eventCoordX(), verve.eventCoordY(), &wx, &wy)) return;
    // world point under the cursor, in canvas px:
    const px = wx * scale + cam_x;
    const py = wy * scale + cam_y;
    const factor = std.math.exp(-verve.eventDeltaY() * 0.001);
    const nz = clampf(@as(f64, scale) * factor, MIN_Z, MAX_Z);
    scale = @floatCast(nz);
    // keep (wx,wy) under the same canvas px:
    cam_x = @floatCast(px - wx * nz);
    cam_y = @floatCast(py - wy * nz);
}
