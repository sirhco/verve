//! verve.viz canvas render path (phase 3) — drives the /viz-canvas <canvas>.
//! Renders a large node-link graph to canvas2d: each frame packs a draw buffer
//! (core/viz/canvas_buf) + calls the bridge `viz_canvas_draw`. Pan/zoom/hover/
//! select via hit-test (no per-element DOM events). Layout is SSR-computed and
//! arrives as props; the chunk only renders + interacts.
const std = @import("std");
const verve = @import("verve");
const cbuf = verve.viz.canvas_buf;

extern "verve_runtime" fn viz_canvas_draw(ref_handle: i32, ptr: [*]const u8, len: u32) void;

const Props = struct {
    xs: []const f64,
    ys: []const f64,
    ef: []const u32,
    et: []const u32,
};

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
    _ = root_id;
    canvas_handle = verve.queryRef(@as([]const u8, "vizcanvas-canvas"));
    hover = -1;
    select = -1;
    panning = false;
    n = 0;
    e = 0;
    if (props_len != 0) {
        const bytes = @as([*]const u8, @ptrFromInt(@as(usize, props_ptr)))[0..props_len];
        if (verve.decodeProps(Props, bytes, verve.chunkArena())) |p| {
            n = @intCast(@min(@min(p.xs.len, p.ys.len), MAX_N));
            for (0..n) |i| {
                xs[i] = @floatCast(p.xs[i]);
                ys[i] = @floatCast(p.ys[i]);
            }
            e = @intCast(@min(@min(p.ef.len, p.et.len), MAX_E));
            for (0..e) |i| {
                ef[i] = if (p.ef[i] < n) p.ef[i] else 0;
                et[i] = if (p.et[i] < n) p.et[i] else 0;
            }
        } else |_| {}
    }
    fitCamera();
    if (canvas_handle != null) {
        var out: [16]u8 = undefined;
        _ = verve.host("verveRafNamed", "{\"island\":\"VizGraphCanvas\",\"export\":\"vizcanvas_tick\",\"on\":1}", &out);
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
