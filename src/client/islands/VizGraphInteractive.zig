//! Interactive graph island: wheel-zoom, drag-to-pan, node drag (incident edges
//! follow), hover tooltip, click-select, and **runtime add/remove** of nodes +
//! edges (reconciled via the keyed list reconciler, preserving zoom/pan +
//! selection). Nodes are keyed by stable id (not index) so mutation is stable.
//!
//! Single instance per page (module-static state). Drag/pan bounded to
//! pointer-over-svg — `pointerout` on the svg ends an in-progress gesture.

const std = @import("std");
const verve = @import("verve");

// ---- props (positional mirror of app/islands.zig VizGraphInteractive.Props) -
const Props = struct {
    xs: []const f64,
    ys: []const f64,
    ef: []const u32,
    et: []const u32,
    labels: []const []const u8,
    ids: []const []const u8,
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
const MAX_N = 256;
const MAX_E = 1024;
const MAX_LABEL = 40;
const MAX_ID = 32;
const MIN_Z = 0.2;
const MAX_Z = 8.0;

// Style constants — must match the SSR GraphOpts used for this island.
const NODE_R: f64 = 14;
const NODE_FILL = "#1f6feb";
const LABEL_FILL = "#f5f5f5";
const LABEL_SIZE: f64 = 11;
const EDGE_STROKE = "#30363d";

var gx: [MAX_N]f64 = undefined;
var gy: [MAX_N]f64 = undefined;
var n: usize = 0;
var ef: [MAX_E]usize = undefined; // edge from-slot
var et: [MAX_E]usize = undefined; // edge to-slot
var edge_n: usize = 0;
var id_buf: [MAX_N * MAX_ID]u8 = undefined;
var id_off: [MAX_N + 1]usize = undefined;
var label_buf: [MAX_N * MAX_LABEL]u8 = undefined;
var label_off: [MAX_N + 1]usize = undefined;

var view: View = .{};
var vbw: f64 = 0;
var vbh: f64 = 0;
var vid: u32 = 0;

var drag_node: ?usize = null;
var panning: bool = false;
var last_sx: f64 = 0;
var last_sy: f64 = 0;
var sel_buf: [MAX_ID]u8 = undefined;
var sel_len: usize = 0;

// ---- id storage -------------------------------------------------------------
fn idOf(slot: usize) []const u8 {
    return id_buf[id_off[slot]..id_off[slot + 1]];
}
fn slotOfId(id: []const u8) ?usize {
    for (0..n) |i| if (std.mem.eql(u8, idOf(i), id)) return i;
    return null;
}
fn labelOf(slot: usize) []const u8 {
    return label_buf[label_off[slot]..label_off[slot + 1]];
}

// ---- ref resolution ---------------------------------------------------------
// `verve.queryRef` passes the RAW name; the runtime auto-scopes it to this
// island's vid. Works for both SSR elements (suffixed by rewriteBindings) and
// chunk-created elements (we bake the same suffix into their data-ref below).
fn ref(comptime name: []const u8) ?i32 {
    return verve.queryRef(@as([]const u8, name));
}
fn resolveNodeId(id: []const u8) ?i32 {
    var rbuf: [64]u8 = undefined;
    const r: []const u8 = std.fmt.bufPrint(&rbuf, "viz-node-{s}", .{id}) catch return null;
    return verve.queryRef(r);
}
fn resolveEdge(from: []const u8, to: []const u8) ?i32 {
    var rbuf: [80]u8 = undefined;
    const r: []const u8 = std.fmt.bufPrint(&rbuf, "viz-edge-{s}|{s}", .{ from, to }) catch return null;
    return verve.queryRef(r);
}

/// Append `__v{vid}` (or nothing for vid 0) — mirrors the runtime's
/// `vidBindName`. Used to bake the scoped data-ref into created fragments.
fn scopedRef(buf: []u8, base: []const u8) ?[]const u8 {
    if (vid == 0) return std.fmt.bufPrint(buf, "{s}", .{base}) catch null;
    return std.fmt.bufPrint(buf, "{s}__v{d}", .{ base, vid }) catch null;
}

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    vid = root_id;
    if (props_len == 0) return;
    const bytes = @as([*]const u8, @ptrFromInt(@as(usize, props_ptr)))[0..props_len];
    const mark = verve.chunkArenaMark();
    defer verve.chunkArenaReset(mark);
    const p = verve.decodeProps(Props, bytes, verve.chunkArena()) catch return;

    n = @min(@min(p.xs.len, p.ys.len), MAX_N);
    n = @min(n, p.ids.len);
    var ioff: usize = 0;
    var loff: usize = 0;
    for (0..n) |i| {
        gx[i] = p.xs[i];
        gy[i] = p.ys[i];
        id_off[i] = ioff;
        const idt = @min(p.ids[i].len, MAX_ID);
        @memcpy(id_buf[ioff .. ioff + idt], p.ids[i][0..idt]);
        ioff += idt;
        label_off[i] = loff;
        if (i < p.labels.len) {
            const lt = @min(p.labels[i].len, MAX_LABEL);
            @memcpy(label_buf[loff .. loff + lt], p.labels[i][0..lt]);
            loff += lt;
        }
    }
    id_off[n] = ioff;
    label_off[n] = loff;

    edge_n = @min(@min(p.ef.len, p.et.len), MAX_E);
    for (0..edge_n) |i| {
        ef[i] = @intCast(p.ef[i]);
        et[i] = @intCast(p.et[i]);
    }

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
fn setNodeXY(slot: usize) void {
    const h = resolveNodeId(idOf(slot)) orelse return;
    var b: [64]u8 = undefined;
    const t = std.fmt.bufPrint(&b, "translate({d},{d})", .{ gx[slot], gy[slot] }) catch return;
    verve.setRefAttr(h, "transform", t);
}
fn updateEdge(e: usize) void {
    const h = resolveEdge(idOf(ef[e]), idOf(et[e])) orelse return;
    var b: [24]u8 = undefined;
    verve.setRefAttr(h, "x1", std.fmt.bufPrint(&b, "{d}", .{gx[ef[e]]}) catch return);
    verve.setRefAttr(h, "y1", std.fmt.bufPrint(&b, "{d}", .{gy[ef[e]]}) catch return);
    verve.setRefAttr(h, "x2", std.fmt.bufPrint(&b, "{d}", .{gx[et[e]]}) catch return);
    verve.setRefAttr(h, "y2", std.fmt.bufPrint(&b, "{d}", .{gy[et[e]]}) catch return);
}

fn hitSlot() ?usize {
    var buf: [MAX_ID]u8 = undefined;
    const s = verve.eventTargetAttr("node", &buf);
    if (s.len == 0) return null;
    return slotOfId(s);
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
    if (hitSlot()) |slot| {
        drag_node = slot;
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
        setNodeXY(i);
        for (0..edge_n) |e| {
            if (ef[e] == i or et[e] == i) updateEdge(e);
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
    const i = hitSlot() orelse return;
    if (ref("viz-tooltip-text")) |h| verve.setRefText(h, labelOf(i));
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
    const i = hitSlot() orelse return;
    if (sel_len != 0) {
        if (resolveNodeId(sel_buf[0..sel_len])) |h| verve.setRefClass(h, "selected", false);
    }
    if (resolveNodeId(idOf(i))) |h| verve.setRefClass(h, "selected", true);
    const id = idOf(i);
    sel_len = @min(id.len, MAX_ID);
    @memcpy(sel_buf[0..sel_len], id[0..sel_len]);
}
