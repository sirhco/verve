//! Interactive graph island: wheel-zoom toward the cursor, drag-to-pan, node
//! drag (incident edges follow), hover tooltip, click-select. Mutates only the
//! fixed SSR element set (`viz-svg` / `viz-root` / `viz-node-<i>` /
//! `viz-edge-<e>` / `viz-tooltip`) via `setRefAttr` + `setRefClass`. No new
//! elements are created.
//!
//! Single instance per page (module-static state); multi-instance namespacing
//! by `root_id` is deferred. Drag/pan are bounded to pointer-over-svg — a
//! `pointerout` on the svg ends an in-progress gesture so it can't strand.

const std = @import("std");
const verve = @import("verve");

// ---- props (positional mirror of app/islands.zig VizGraphInteractive.Props) -
const Props = struct {
    xs: []const f64,
    ys: []const f64,
    ef: []const u32,
    et: []const u32,
    labels: []const []const u8,
};

// ---- pure math (mirror of core/viz/interact.zig — unit-tested there) --------
const Vec2 = struct { x: f64 = 0, y: f64 = 0 };
const View = struct { z: f64 = 1, tx: f64 = 0, ty: f64 = 0 };

fn clampf(v: f64, lo: f64, hi: f64) f64 {
    return @max(lo, @min(hi, v));
}
fn clientToSvg(rx: f64, ry: f64, rw: f64, rh: f64, vw: f64, vh: f64, cx: f64, cy: f64) Vec2 {
    const sx = if (rw == 0) 0 else (cx - rx) / rw * vw;
    const sy = if (rh == 0) 0 else (cy - ry) / rh * vh;
    return .{ .x = sx, .y = sy };
}
fn svgToGraph(v: View, svg: Vec2) Vec2 {
    return .{ .x = (svg.x - v.tx) / v.z, .y = (svg.y - v.ty) / v.z };
}
fn zoomToward(v: View, c: Vec2, factor: f64, min_z: f64, max_z: f64) View {
    const nz = clampf(v.z * factor, min_z, max_z);
    const g = svgToGraph(v, c);
    return .{ .z = nz, .tx = c.x - g.x * nz, .ty = c.y - g.y * nz };
}

// ---- module state -----------------------------------------------------------
const MAX_N = 512;
const MAX_E = 2048;
const MAX_LABEL = 48;
const MIN_Z = 0.2;
const MAX_Z = 8.0;

var gx: [MAX_N]f64 = undefined;
var gy: [MAX_N]f64 = undefined;
var n: usize = 0;
var ef: [MAX_E]u32 = undefined;
var et: [MAX_E]u32 = undefined;
var edge_n: usize = 0;
var label_buf: [MAX_N * MAX_LABEL]u8 = undefined;
var label_off: [MAX_N + 1]usize = undefined;

var view: View = .{};
var vbw: f64 = 0;
var vbh: f64 = 0;

var drag_node: ?usize = null;
var panning: bool = false;
var last_sx: f64 = 0;
var last_sy: f64 = 0;
var selected: ?usize = null;
// This island's vid (server `data-vid`). The framework suffixes every
// `data-ref` with `__v{vid}` for vid>0 so multiple instances don't collide, and
// `query_ref` does NOT auto-scope — so we suffix ref names ourselves.
var vid: u32 = 0;

/// Resolve a (possibly vid-suffixed) `data-ref` to an element handle.
fn resolve(name: []const u8) ?i32 {
    if (vid == 0) return verve.queryRef(name);
    var buf: [80]u8 = undefined;
    const full: []const u8 = std.fmt.bufPrint(&buf, "{s}__v{d}", .{ name, vid }) catch return null;
    return verve.queryRef(full);
}

fn ref(comptime name: []const u8) ?i32 {
    return resolve(@as([]const u8, name));
}

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    vid = root_id;
    if (props_len == 0) return;
    const bytes = @as([*]const u8, @ptrFromInt(@as(usize, props_ptr)))[0..props_len];
    const mark = verve.chunkArenaMark();
    defer verve.chunkArenaReset(mark);
    const p = verve.decodeProps(Props, bytes, verve.chunkArena()) catch return;

    n = @min(@min(p.xs.len, p.ys.len), MAX_N);
    for (0..n) |i| {
        gx[i] = p.xs[i];
        gy[i] = p.ys[i];
    }
    edge_n = @min(@min(p.ef.len, p.et.len), MAX_E);
    for (0..edge_n) |i| {
        ef[i] = p.ef[i];
        et[i] = p.et[i];
    }
    var off: usize = 0;
    for (0..n) |i| {
        label_off[i] = off;
        if (i < p.labels.len) {
            const take = @min(p.labels[i].len, MAX_LABEL);
            @memcpy(label_buf[off .. off + take], p.labels[i][0..take]);
            off += take;
        }
    }
    label_off[n] = off;

    // viewBox extent ≈ the svg's rendered size (assumes no CSS scaling — see the
    // limitation noted in docs/22). Used to map client px → svg user units.
    if (ref("viz-svg")) |h| {
        const r = verve.refRect(h);
        vbw = r.w;
        vbh = r.h;
    }
}

fn svgRect() verve.Rect {
    if (ref("viz-svg")) |h| return verve.refRect(h);
    return .{ .x = 0, .y = 0, .w = vbw, .h = vbh };
}

fn pointerSvg() Vec2 {
    const r = svgRect();
    return clientToSvg(r.x, r.y, r.w, r.h, vbw, vbh, verve.eventCoordX(), verve.eventCoordY());
}

fn applyRootTransform() void {
    const h = ref("viz-root") orelse return;
    var buf: [96]u8 = undefined;
    const t = std.fmt.bufPrint(&buf, "translate({d},{d}) scale({d})", .{ view.tx, view.ty, view.z }) catch return;
    verve.setRefAttr(h, "transform", t);
}

fn resolveNode(i: usize) ?i32 {
    var rbuf: [32]u8 = undefined;
    const id: []const u8 = std.fmt.bufPrint(&rbuf, "viz-node-{d}", .{i}) catch return null;
    return resolve(id);
}

fn setNodeTransform(i: usize, p: Vec2) void {
    const h = resolveNode(i) orelse return;
    var tbuf: [64]u8 = undefined;
    const t = std.fmt.bufPrint(&tbuf, "translate({d},{d})", .{ p.x, p.y }) catch return;
    verve.setRefAttr(h, "transform", t);
}

fn setEdgeEnd(e: usize, comptime suffix: []const u8, p: Vec2) void {
    var rbuf: [32]u8 = undefined;
    const id: []const u8 = std.fmt.bufPrint(&rbuf, "viz-edge-{d}", .{e}) catch return;
    const h = resolve(id) orelse return;
    var vbuf: [24]u8 = undefined;
    const xv = std.fmt.bufPrint(&vbuf, "{d}", .{p.x}) catch return;
    verve.setRefAttr(h, "x" ++ suffix, xv);
    const yv = std.fmt.bufPrint(&vbuf, "{d}", .{p.y}) catch return;
    verve.setRefAttr(h, "y" ++ suffix, yv);
}

fn hitNode() ?usize {
    var buf: [16]u8 = undefined;
    const s = verve.eventTargetAttr("node", &buf);
    if (s.len == 0) return null;
    return std.fmt.parseInt(usize, s, 10) catch null;
}

export fn viz_wheel() void {
    verve.eventPreventDefault();
    const c = pointerSvg();
    const factor: f64 = if (verve.eventDeltaY() < 0) 1.1 else 1.0 / 1.1;
    view = zoomToward(view, c, factor, MIN_Z, MAX_Z);
    applyRootTransform();
}

export fn viz_pointerdown() void {
    const svg = pointerSvg();
    last_sx = svg.x;
    last_sy = svg.y;
    if (hitNode()) |i| {
        drag_node = if (i < n) i else null;
        panning = false;
    } else {
        panning = true;
        drag_node = null;
    }
}

export fn viz_pointermove() void {
    const svg = pointerSvg();
    if (drag_node) |i| {
        const gp = svgToGraph(view, svg);
        gx[i] = gp.x;
        gy[i] = gp.y;
        setNodeTransform(i, gp);
        for (0..edge_n) |e| {
            if (ef[e] == i) setEdgeEnd(e, "1", gp);
            if (et[e] == i) setEdgeEnd(e, "2", gp);
        }
    } else if (panning) {
        view.tx += svg.x - last_sx;
        view.ty += svg.y - last_sy;
        last_sx = svg.x;
        last_sy = svg.y;
        applyRootTransform();
    }
}

export fn viz_pointerup() void {
    drag_node = null;
    panning = false;
}

export fn viz_node_over() void {
    const i = hitNode() orelse return;
    if (i >= n) return;
    if (ref("viz-tooltip-text")) |h| verve.setRefText(h, label_buf[label_off[i]..label_off[i + 1]]);
    if (ref("viz-tooltip")) |h| {
        var buf: [64]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, "translate({d},{d})", .{ gx[i], gy[i] }) catch return;
        verve.setRefAttr(h, "transform", t);
        verve.setRefAttr(h, "style", "display:block");
    }
}

export fn viz_node_out() void {
    if (ref("viz-tooltip")) |h| verve.setRefAttr(h, "style", "display:none");
}

export fn viz_node_click() void {
    const i = hitNode() orelse return;
    if (i >= n) return;
    if (selected) |prev| {
        if (resolveNode(prev)) |h| verve.setRefClass(h, "selected", false);
    }
    if (resolveNode(i)) |h| verve.setRefClass(h, "selected", true);
    selected = i;
}
