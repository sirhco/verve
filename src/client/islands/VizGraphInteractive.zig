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

/// Arena-backed format via `bufPrint` (NOT `allocPrint`): the chunk shares the
/// main client's indirect function table, and `allocPrint`'s Allocating writer
/// would add a new address-taken `drain` fn that collides with main's table
/// slots (call_indirect signature mismatch). `bufPrint`'s writer is already in
/// the table, so this is safe.
fn aprint(a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ?[]const u8 {
    const buf = a.alloc(u8, 128) catch return null;
    return std.fmt.bufPrint(buf, fmt, args) catch null;
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

// ---- runtime mutation -------------------------------------------------------

var fvx: [MAX_N]f64 = undefined;
var fvy: [MAX_N]f64 = undefined;

/// Relax the current `gx/gy` with `iters` force steps (repulsion + edge springs
/// + centroid gravity). Seeded from current positions → survivors barely move.
fn forceRelax(iters: usize) void {
    if (n == 0) return;
    var ccx: f64 = 0;
    var ccy: f64 = 0;
    for (0..n) |i| {
        ccx += gx[i];
        ccy += gy[i];
    }
    ccx /= @floatFromInt(n);
    ccy /= @floatFromInt(n);
    const rep: f64 = 3000;
    const spring: f64 = 0.04;
    const rest: f64 = 90;
    const grav: f64 = 0.02;
    const damp: f64 = 0.85;
    const dt: f64 = 0.6;
    @memset(fvx[0..n], 0);
    @memset(fvy[0..n], 0);
    for (0..iters) |_| {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            var j: usize = i + 1;
            while (j < n) : (j += 1) {
                var dx = gx[i] - gx[j];
                var dy = gy[i] - gy[j];
                var d = @sqrt(dx * dx + dy * dy);
                if (d < 1) {
                    dx = 1;
                    dy = 0;
                    d = 1;
                }
                const f = rep / (d * d);
                const ux = dx / d * f * dt;
                const uy = dy / d * f * dt;
                fvx[i] += ux;
                fvy[i] += uy;
                fvx[j] -= ux;
                fvy[j] -= uy;
            }
        }
        for (0..edge_n) |e| {
            const u = ef[e];
            const v = et[e];
            if (u >= n or v >= n or u == v) continue;
            const dx = gx[v] - gx[u];
            const dy = gy[v] - gy[u];
            var d = @sqrt(dx * dx + dy * dy);
            if (d < 1) d = 1;
            const f = spring * (d - rest);
            const ux = dx / d * f * dt;
            const uy = dy / d * f * dt;
            fvx[u] += ux;
            fvy[u] += uy;
            fvx[v] -= ux;
            fvy[v] -= uy;
        }
        for (0..n) |k| {
            fvx[k] = (fvx[k] + (ccx - gx[k]) * grav * dt) * damp;
            fvy[k] = (fvy[k] + (ccy - gy[k]) * grav * dt) * damp;
            gx[k] += fvx[k] * dt;
            gy[k] += fvy[k] * dt;
        }
    }
}

// Mirrors core/viz/graph.zig nodeFragment/edgeFragment with the island's style
// constants. `ref` is the full (vid-scoped) data-ref baked in here.
fn nodeFragment(buf: []u8, id: []const u8, refn: []const u8, label: []const u8, x: f64, y: f64) ![]const u8 {
    if (label.len == 0) {
        return std.fmt.bufPrint(buf, "<g data-vkey=\"{s}\" data-ref=\"{s}\" data-node=\"{s}\" class=\"viz-node\" transform=\"translate({d},{d})\" z-on-pointerdown=\"viz_pointerdown\" z-on-pointerover=\"viz_node_over\" z-on-pointerout=\"viz_node_out\" z-on-click=\"viz_node_click\"><circle cx=\"0\" cy=\"0\" r=\"{d}\" fill=\"{s}\"/></g>", .{ id, refn, id, x, y, NODE_R, NODE_FILL });
    }
    return std.fmt.bufPrint(buf, "<g data-vkey=\"{s}\" data-ref=\"{s}\" data-node=\"{s}\" class=\"viz-node\" transform=\"translate({d},{d})\" z-on-pointerdown=\"viz_pointerdown\" z-on-pointerover=\"viz_node_over\" z-on-pointerout=\"viz_node_out\" z-on-click=\"viz_node_click\"><circle cx=\"0\" cy=\"0\" r=\"{d}\" fill=\"{s}\"/><text x=\"0\" y=\"{d}\" text-anchor=\"middle\" font-size=\"{d}\" fill=\"{s}\">{s}</text></g>", .{ id, refn, id, x, y, NODE_R, NODE_FILL, NODE_R + LABEL_SIZE, LABEL_SIZE, LABEL_FILL, label });
}
fn edgeFragment(buf: []u8, key: []const u8, refn: []const u8, x1: f64, y1: f64, x2: f64, y2: f64) ![]const u8 {
    return std.fmt.bufPrint(buf, "<line data-vkey=\"{s}\" data-ref=\"{s}\" x1=\"{d}\" y1=\"{d}\" x2=\"{d}\" y2=\"{d}\" stroke=\"{s}\" stroke-width=\"1.5\"/>", .{ key, refn, x1, y1, x2, y2, EDGE_STROKE });
}

/// Rebuild graph state + DOM from a desired graph (arena-owned id/label copies +
/// slot-pair edges). Survivors keep positions; new nodes seed near the centroid;
/// force relaxes; the keyed reconciler creates/moves/removes DOM elements.
/// Zoom/pan (`viz-root` transform) is untouched → preserved.
fn reconcile(new_ids: []const []const u8, new_labels: []const []const u8, new_edges: []const [2]usize) void {
    const mark = verve.chunkArenaMark();
    defer verve.chunkArenaReset(mark);
    const a = verve.chunkArena();
    const nn = @min(new_ids.len, MAX_N);

    var ccx: f64 = 0;
    var ccy: f64 = 0;
    if (n > 0) {
        for (0..n) |i| {
            ccx += gx[i];
            ccy += gy[i];
        }
        ccx /= @floatFromInt(n);
        ccy /= @floatFromInt(n);
    } else {
        ccx = vbw / 2;
        ccy = vbh / 2;
    }

    const nx = a.alloc(f64, nn) catch return;
    const ny = a.alloc(f64, nn) catch return;
    for (0..nn) |i| {
        if (slotOfId(new_ids[i])) |s| {
            nx[i] = gx[s];
            ny[i] = gy[s];
        } else {
            const ang = 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(@max(nn, 1)));
            nx[i] = ccx + 40 * @cos(ang);
            ny[i] = ccy + 40 * @sin(ang);
        }
    }

    // Capture current DOM keys before overwriting state.
    const old_nkeys = a.alloc([]const u8, n) catch return;
    for (0..n) |i| old_nkeys[i] = a.dupe(u8, idOf(i)) catch return;
    const old_ekeys = a.alloc([]const u8, edge_n) catch return;
    for (0..edge_n) |e| old_ekeys[e] = aprint(a, "{s}|{s}", .{ idOf(ef[e]), idOf(et[e]) }) orelse return;

    // Commit new node state.
    var ioff: usize = 0;
    var loff: usize = 0;
    for (0..nn) |i| {
        gx[i] = nx[i];
        gy[i] = ny[i];
        id_off[i] = ioff;
        const idt = @min(new_ids[i].len, MAX_ID);
        @memcpy(id_buf[ioff .. ioff + idt], new_ids[i][0..idt]);
        ioff += idt;
        label_off[i] = loff;
        const lt = @min(new_labels[i].len, MAX_LABEL);
        @memcpy(label_buf[loff .. loff + lt], new_labels[i][0..lt]);
        loff += lt;
    }
    id_off[nn] = ioff;
    label_off[nn] = loff;
    n = nn;
    edge_n = @min(new_edges.len, MAX_E);
    for (0..edge_n) |e| {
        ef[e] = new_edges[e][0];
        et[e] = new_edges[e][1];
    }

    forceRelax(50);

    // New keys + html (refs baked vid-scoped).
    const nkeys = a.alloc([]const u8, n) catch return;
    const nhtml = a.alloc([]const u8, n) catch return;
    for (0..n) |i| {
        nkeys[i] = idOf(i);
        const base = aprint(a, "viz-node-{s}", .{idOf(i)}) orelse return;
        const sbuf = a.alloc(u8, 96) catch return;
        const sref = scopedRef(sbuf, base) orelse return;
        const hbuf = a.alloc(u8, 1024) catch return;
        nhtml[i] = nodeFragment(hbuf, idOf(i), sref, labelOf(i), gx[i], gy[i]) catch return;
    }
    verve.listDiff("viz-nodes", old_nkeys, nkeys, nhtml);

    const ekeys = a.alloc([]const u8, edge_n) catch return;
    const ehtml = a.alloc([]const u8, edge_n) catch return;
    for (0..edge_n) |e| {
        const key = aprint(a, "{s}|{s}", .{ idOf(ef[e]), idOf(et[e]) }) orelse return;
        ekeys[e] = key;
        const base = aprint(a, "viz-edge-{s}", .{key}) orelse return;
        const sbuf = a.alloc(u8, 96) catch return;
        const sref = scopedRef(sbuf, base) orelse return;
        const hbuf = a.alloc(u8, 320) catch return;
        ehtml[e] = edgeFragment(hbuf, key, sref, gx[ef[e]], gy[ef[e]], gx[et[e]], gy[et[e]]) catch return;
    }
    verve.listDiff("viz-edges", old_ekeys, ekeys, ehtml);

    // Snap survivors to exact final positions (created elements already carry
    // them, but moved survivors need updating).
    for (0..n) |i| setNodeXY(i);
    for (0..edge_n) |e| updateEdge(e);

    drag_node = null;
    panning = false;
    if (sel_len != 0 and slotOfId(sel_buf[0..sel_len]) == null) sel_len = 0;
}

var add_seq: u32 = 0;

/// Demo imperative API: add a synthetic node connected to node 0.
export fn viz_add_node() void {
    if (n == 0 or n >= MAX_N) return;
    const mark = verve.chunkArenaMark();
    defer verve.chunkArenaReset(mark);
    const a = verve.chunkArena();
    add_seq += 1;
    const ids = a.alloc([]const u8, n + 1) catch return;
    const labels = a.alloc([]const u8, n + 1) catch return;
    for (0..n) |i| {
        ids[i] = a.dupe(u8, idOf(i)) catch return;
        labels[i] = a.dupe(u8, labelOf(i)) catch return;
    }
    const new_id = aprint(a, "n{d}", .{add_seq}) orelse return;
    ids[n] = new_id;
    labels[n] = new_id;
    const edges = a.alloc([2]usize, edge_n + 1) catch return;
    for (0..edge_n) |e| edges[e] = .{ ef[e], et[e] };
    edges[edge_n] = .{ 0, n };
    reconcile(ids, labels, edges);
}

/// Demo imperative API: remove the last node + its incident edges.
export fn viz_remove_node() void {
    if (n <= 1) return;
    const mark = verve.chunkArenaMark();
    defer verve.chunkArenaReset(mark);
    const a = verve.chunkArena();
    const gone = n - 1;
    const ids = a.alloc([]const u8, gone) catch return;
    const labels = a.alloc([]const u8, gone) catch return;
    for (0..gone) |i| {
        ids[i] = a.dupe(u8, idOf(i)) catch return;
        labels[i] = a.dupe(u8, labelOf(i)) catch return;
    }
    var edges: std.ArrayList([2]usize) = .empty;
    for (0..edge_n) |e| {
        if (ef[e] < gone and et[e] < gone) edges.append(a, .{ ef[e], et[e] }) catch return;
    }
    reconcile(ids, labels, edges.items);
}
