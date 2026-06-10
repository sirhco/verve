//! Interactive graph island: wheel-zoom, drag-to-pan, node drag (incident edges
//! follow), hover tooltip, click-select, dblclick subtree collapse, **runtime
//! add/remove** of nodes + edges (keyed reconciler, preserving zoom/pan +
//! selection + collapse), layout-aware relayout with tweening (tree/radial/dag
//! via `viz_core`), and live SSE wire-delta streaming with seq-gap resync.
//! Nodes are keyed by stable id (not index) so mutation is stable.
//!
//! Single instance per page (module-static state). Gestures are
//! pointer-captured, so they survive the pointer leaving the svg; they end on
//! `pointerup` / `pointercancel`.

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
    layout: u32,
    margin: f64,
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

// ---- subtree collapse --------------------------------------------------------
// The model always holds the FULL graph; `collapsed` (user dblclick toggles)
// derives `hidden`, which only filters what reaches the DOM. Live deltas
// mutate the model unconditionally and visibility is recomputed afterward, so
// collapse composes with streaming updates.
var collapsed: [MAX_N]bool = @splat(false);
var hidden: [MAX_N]bool = @splat(false);
var bfs_visited: [MAX_N]bool = undefined;
var bfs_queue: [MAX_N]usize = undefined;

/// Mirror of core/viz/interact.zig `collapseHidden` (unit-tested there; chunks
/// can't import across the module boundary): BFS each collapsed root's
/// directed out-edges, hiding everything reached except the root itself.
fn recomputeHidden() void {
    @memset(hidden[0..n], false);
    for (0..n) |root| {
        if (!collapsed[root]) continue;
        @memset(bfs_visited[0..n], false);
        bfs_visited[root] = true;
        var head: usize = 0;
        var tail: usize = 0;
        bfs_queue[tail] = root;
        tail += 1;
        while (head < tail) {
            const cur = bfs_queue[head];
            head += 1;
            for (0..edge_n) |e| {
                if (ef[e] != cur) continue;
                const t = et[e];
                if (t >= n or bfs_visited[t]) continue;
                bfs_visited[t] = true;
                hidden[t] = true;
                if (tail < MAX_N) {
                    bfs_queue[tail] = t;
                    tail += 1;
                }
            }
        }
    }
}

/// Hidden-descendant count for a collapsed node's `+N` badge.
fn hiddenCountFrom(root: usize) usize {
    @memset(bfs_visited[0..n], false);
    bfs_visited[root] = true;
    var head: usize = 0;
    var tail: usize = 0;
    var count: usize = 0;
    bfs_queue[tail] = root;
    tail += 1;
    while (head < tail) {
        const cur = bfs_queue[head];
        head += 1;
        for (0..edge_n) |e| {
            if (ef[e] != cur) continue;
            const t = et[e];
            if (t >= n or bfs_visited[t]) continue;
            bfs_visited[t] = true;
            if (hidden[t]) count += 1;
            if (tail < MAX_N) {
                bfs_queue[tail] = t;
                tail += 1;
            }
        }
    }
    return count;
}

fn edgeVisible(e: usize) bool {
    return !hidden[ef[e]] and !hidden[et[e]];
}

// ---- layout transitions --------------------------------------------------
// For the deterministic layouts (tree/radial/dag) runtime mutation recomputes
// the whole layout via `verve.viz_core` — the exact algorithms + fit SSR used
// — then tweens survivors from their current positions to the new targets.
// The tween is driven by the JS `verveRafNamed` loop calling the NAMED
// `viz_tick` export each frame (no function-table entry).
const LAYOUT_FORCE: u32 = 2; // @intFromEnum(viz.Layout.force)
var layout_kind: u32 = LAYOUT_FORCE;
var margin_p: f64 = 40;
var txs: [MAX_N]f64 = undefined;
var tys: [MAX_N]f64 = undefined;
var anim_sx: [MAX_N]f64 = undefined;
var anim_sy: [MAX_N]f64 = undefined;
var anim_frame: u32 = 0;
var anim_on: bool = false;
const ANIM_TOTAL: u32 = 24;

/// Recompute `txs`/`tys` for the current deterministic layout. Returns false
/// for force (incremental relax handles it) or on failure.
fn recomputeTargets(a: std.mem.Allocator) bool {
    const vc = verve.viz_core;
    if (n == 0) return false;
    const pairs = a.alloc(vc.common.Edge, edge_n) catch return false;
    for (0..edge_n) |e| pairs[e] = .{ ef[e], et[e] };
    const center = vc.geom.Vec2{ .x = vbw / 2.0, .y = vbh / 2.0 };
    const positions = switch (layout_kind) {
        0 => vc.tree.layout(a, n, pairs, .{}) catch return false,
        1 => vc.radial.layout(a, n, pairs, .{ .center = center }) catch return false,
        3 => vc.dag.layout(a, n, pairs, .{}) catch return false,
        else => return false,
    };
    const f = vc.geom.fitBox(positions, vbw, vbh, margin_p);
    for (positions, 0..) |p, i| {
        const q = vc.geom.applyFit(p, f);
        txs[i] = q.x;
        tys[i] = q.y;
    }
    return true;
}

fn startTween() void {
    anim_frame = 0;
    anim_on = true;
    var out: [16]u8 = undefined;
    _ = verve.host("verveRafNamed", "{\"island\":\"VizGraphInteractive\",\"export\":\"viz_tick\",\"on\":1}", &out);
}

/// One tween frame; returns 1 while the JS rAF loop should continue.
export fn viz_tick() i32 {
    if (!anim_on) return 0;
    anim_frame += 1;
    const t = @min(1.0, @as(f64, @floatFromInt(anim_frame)) / @as(f64, @floatFromInt(ANIM_TOTAL)));
    const s = verve.viz_core.interact.easeOutCubic(t);
    for (0..n) |i| {
        gx[i] = anim_sx[i] + (txs[i] - anim_sx[i]) * s;
        gy[i] = anim_sy[i] + (tys[i] - anim_sy[i]) * s;
    }
    for (0..n) |i| {
        if (!hidden[i]) setNodeXY(i);
    }
    for (0..edge_n) |e| {
        if (edgeVisible(e)) updateEdge(e);
    }
    if (anim_frame >= ANIM_TOTAL) {
        for (0..n) |i| {
            gx[i] = txs[i];
            gy[i] = tys[i];
        }
        anim_on = false;
        return 0;
    }
    return 1;
}

/// Demo control: cycle tree → radial → force → dag, tweening every node from
/// its current position to the new layout.
export fn viz_layout_cycle() void {
    if (n == 0) return;
    layout_kind = (layout_kind + 1) % 4;
    const mark = verve.chunkArenaMark();
    defer verve.chunkArenaReset(mark);
    const a = verve.chunkArena();
    for (0..n) |i| {
        anim_sx[i] = gx[i];
        anim_sy[i] = gy[i];
    }
    if (layout_kind == LAYOUT_FORCE) {
        forceRelax(120);
        for (0..n) |i| {
            txs[i] = gx[i];
            tys[i] = gy[i];
            gx[i] = anim_sx[i];
            gy[i] = anim_sy[i];
        }
    } else if (!recomputeTargets(a)) {
        return;
    }
    startTween();
    if (ref("viz-layout-btn")) |h| {
        const name: []const u8 = switch (layout_kind) {
            0 => "⟳ tree",
            1 => "⟳ radial",
            2 => "⟳ force",
            else => "⟳ dag",
        };
        verve.setRefText(h, name);
    }
}

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

    layout_kind = p.layout;
    margin_p = p.margin;

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
        anim_on = false; // drag wins over a running layout tween
    } else {
        panning = true;
        drag_node = null;
    }
    // Capture the pointer so the gesture survives leaving the svg;
    // capture suppresses node over/out mid-gesture, so hide the tooltip
    // defensively in case it was showing.
    verve.eventCapturePointer();
    if (ref("viz-tooltip")) |h| verve.setRefAttr(h, "style", "display:none");
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
// constants. `ref` is the full (vid-scoped) data-ref baked in here. `klass`
// is "viz-node" or "viz-node collapsed"; `label` arrives pre-badged.
fn nodeFragment(buf: []u8, id: []const u8, refn: []const u8, label: []const u8, x: f64, y: f64, klass: []const u8) ![]const u8 {
    if (label.len == 0) {
        return std.fmt.bufPrint(buf, "<g data-vkey=\"{s}\" data-ref=\"{s}\" data-node=\"{s}\" class=\"{s}\" transform=\"translate({d},{d})\" z-on-pointerdown=\"viz_pointerdown\" z-on-pointerover=\"viz_node_over\" z-on-pointerout=\"viz_node_out\" z-on-click=\"viz_node_click\" z-on-dblclick=\"viz_node_dblclick\"><circle cx=\"0\" cy=\"0\" r=\"{d}\" fill=\"{s}\"/></g>", .{ id, refn, id, klass, x, y, NODE_R, NODE_FILL });
    }
    return std.fmt.bufPrint(buf, "<g data-vkey=\"{s}\" data-ref=\"{s}\" data-node=\"{s}\" class=\"{s}\" transform=\"translate({d},{d})\" z-on-pointerdown=\"viz_pointerdown\" z-on-pointerover=\"viz_node_over\" z-on-pointerout=\"viz_node_out\" z-on-click=\"viz_node_click\" z-on-dblclick=\"viz_node_dblclick\"><circle cx=\"0\" cy=\"0\" r=\"{d}\" fill=\"{s}\"/><text x=\"0\" y=\"{d}\" text-anchor=\"middle\" font-size=\"{d}\" fill=\"{s}\">{s}</text></g>", .{ id, refn, id, klass, x, y, NODE_R, NODE_FILL, NODE_R + LABEL_SIZE, LABEL_SIZE, LABEL_FILL, label });
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
    const is_new = a.alloc(bool, nn) catch return;
    for (0..nn) |i| {
        if (slotOfId(new_ids[i])) |s| {
            nx[i] = gx[s];
            ny[i] = gy[s];
            is_new[i] = false;
        } else {
            const ang = 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(@max(nn, 1)));
            nx[i] = ccx + 40 * @cos(ang);
            ny[i] = ccy + 40 * @sin(ang);
            is_new[i] = true;
        }
    }

    // Capture current *visible* DOM keys before overwriting state — the DOM
    // holds only the un-hidden subset, and listDiff must diff DOM-vs-DOM.
    const old_vis = captureVisibleKeys(a) orelse return;

    // Carry collapsed flags across the rebuild by id (like positions).
    const old_coll = a.alloc([]const u8, n) catch return;
    var oc: usize = 0;
    for (0..n) |i| {
        if (collapsed[i]) {
            old_coll[oc] = a.dupe(u8, idOf(i)) catch return;
            oc += 1;
        }
    }

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

    for (0..n) |i| {
        collapsed[i] = false;
        for (old_coll[0..oc]) |cid| {
            if (std.mem.eql(u8, idOf(i), cid)) collapsed[i] = true;
        }
    }

    if (layout_kind == LAYOUT_FORCE) {
        // Incremental: survivors barely move, new nodes relax in near the
        // centroid seed. Positions are final — no tween.
        forceRelax(50);
        anim_on = false;
    } else if (recomputeTargets(a)) {
        // Global deterministic layout: new nodes appear at their final
        // positions; survivors tween from where they were.
        var any_tween = false;
        for (0..n) |i| {
            anim_sx[i] = gx[i];
            anim_sy[i] = gy[i];
            if (is_new[i]) {
                gx[i] = txs[i];
                gy[i] = tys[i];
                anim_sx[i] = txs[i];
                anim_sy[i] = tys[i];
            } else if (gx[i] != txs[i] or gy[i] != tys[i]) {
                any_tween = true;
            }
        }
        if (any_tween) startTween();
    }
    recomputeHidden();
    syncDom(a, old_vis.nkeys, old_vis.ekeys);

    drag_node = null;
    panning = false;
}

const VisKeys = struct { nkeys: []const []const u8, ekeys: []const []const u8 };

/// Arena copies of the keys currently in the DOM: visible nodes + edges whose
/// endpoints are both visible, under the *current* model + `hidden` state.
fn captureVisibleKeys(a: std.mem.Allocator) ?VisKeys {
    const nkeys = a.alloc([]const u8, n) catch return null;
    var nk: usize = 0;
    for (0..n) |i| {
        if (hidden[i]) continue;
        nkeys[nk] = a.dupe(u8, idOf(i)) catch return null;
        nk += 1;
    }
    const ekeys = a.alloc([]const u8, edge_n) catch return null;
    var ek: usize = 0;
    for (0..edge_n) |e| {
        if (!edgeVisible(e)) continue;
        ekeys[ek] = aprint(a, "{s}|{s}", .{ idOf(ef[e]), idOf(et[e]) }) orelse return null;
        ek += 1;
    }
    return .{ .nkeys = nkeys[0..nk], .ekeys = ekeys[0..ek] };
}

/// Drive the keyed reconciler from `old_*keys` (the previous visible DOM set)
/// to the current model's visible subset. Collapsed nodes stay visible with a
/// `collapsed` class and a `+N` hidden-descendant badge in their label.
/// Zoom/pan (`viz-root` transform) is untouched → preserved.
fn syncDom(a: std.mem.Allocator, old_nkeys: []const []const u8, old_ekeys: []const []const u8) void {
    // New keys + html (refs baked vid-scoped).
    const nkeys = a.alloc([]const u8, n) catch return;
    const nhtml = a.alloc([]const u8, n) catch return;
    var nk: usize = 0;
    for (0..n) |i| {
        if (hidden[i]) continue;
        nkeys[nk] = idOf(i);
        const base = aprint(a, "viz-node-{s}", .{idOf(i)}) orelse return;
        const sbuf = a.alloc(u8, 96) catch return;
        const sref = scopedRef(sbuf, base) orelse return;
        var klass: []const u8 = "viz-node";
        var disp: []const u8 = labelOf(i);
        if (collapsed[i]) {
            klass = "viz-node collapsed";
            const hc = hiddenCountFrom(i);
            if (hc > 0) disp = aprint(a, "{s} +{d}", .{ labelOf(i), hc }) orelse return;
        }
        const hbuf = a.alloc(u8, 1024) catch return;
        nhtml[nk] = nodeFragment(hbuf, idOf(i), sref, disp, gx[i], gy[i], klass) catch return;
        nk += 1;
    }
    // `verve_list_diff` does NOT vid-scope the parent bind (unlike queryRef) —
    // pass the already-scoped container name.
    var npbuf: [48]u8 = undefined;
    const nodes_parent = scopedRef(&npbuf, "viz-nodes") orelse return;
    verve.listDiff(nodes_parent, old_nkeys, nkeys[0..nk], nhtml[0..nk]);

    const ekeys = a.alloc([]const u8, edge_n) catch return;
    const ehtml = a.alloc([]const u8, edge_n) catch return;
    var ek: usize = 0;
    for (0..edge_n) |e| {
        if (!edgeVisible(e)) continue;
        const key = aprint(a, "{s}|{s}", .{ idOf(ef[e]), idOf(et[e]) }) orelse return;
        ekeys[ek] = key;
        const base = aprint(a, "viz-edge-{s}", .{key}) orelse return;
        const sbuf = a.alloc(u8, 96) catch return;
        const sref = scopedRef(sbuf, base) orelse return;
        const hbuf = a.alloc(u8, 320) catch return;
        ehtml[ek] = edgeFragment(hbuf, key, sref, gx[ef[e]], gy[ef[e]], gx[et[e]], gy[et[e]]) catch return;
        ek += 1;
    }
    var epbuf: [48]u8 = undefined;
    const edges_parent = scopedRef(&epbuf, "viz-edges") orelse return;
    verve.listDiff(edges_parent, old_ekeys, ekeys[0..ek], ehtml[0..ek]);

    // Snap survivors to exact final positions (created elements already carry
    // them, but moved survivors need updating). Hidden elements have no DOM —
    // their queryRef misses are harmless no-ops.
    for (0..n) |i| {
        if (!hidden[i]) setNodeXY(i);
    }
    for (0..edge_n) |e| {
        if (edgeVisible(e)) updateEdge(e);
    }

    // Selection dies when its node leaves the graph or the visible set.
    if (sel_len != 0) {
        if (slotOfId(sel_buf[0..sel_len])) |s| {
            if (hidden[s]) sel_len = 0;
        } else sel_len = 0;
    }
}

/// Double-click toggles a node's subtree collapse. The model is untouched —
/// only visibility recomputes, then the DOM syncs from the previous visible
/// set to the new one.
export fn viz_node_dblclick() void {
    const slot = hitSlot() orelse return;
    const mark = verve.chunkArenaMark();
    defer verve.chunkArenaReset(mark);
    const a = verve.chunkArena();
    const old_vis = captureVisibleKeys(a) orelse return;
    collapsed[slot] = !collapsed[slot];
    recomputeHidden();
    syncDom(a, old_vis.nkeys, old_vis.ekeys);
    if (ref("viz-tooltip")) |h| verve.setRefAttr(h, "style", "display:none");
}

// ---- live-data streaming (SSE push + poll fallback) --------------------------

var polling: bool = false;
/// True while the SSE push path is active (EventSource available).
var live_push: bool = false;
/// Last applied seq (0 = no baseline yet). A delta applies only when its seq
/// is exactly `last_seq + 1`; any gap forces a snapshot resync.
var last_seq: u64 = 0;
var awaiting_resync: bool = false;

/// Pull a fresh `{seq, nodes, edges}` snapshot via the JS one-shot fetch and
/// hand it to `viz_apply_snapshot` — used as the push path's baseline and
/// whenever a delta seq gap (missed frame / ring overrun) is detected.
fn requestResync() void {
    if (awaiting_resync) return;
    awaiting_resync = true;
    verve.fetchToExport("vizGraph", "VizGraphInteractive", "viz_apply_snapshot");
}

/// Mirror of core/viz/graph.zig mapSnapshotEdges (chunk can't import across the
/// module boundary).
fn mapSnapshotEdges(ids: []const []const u8, froms: []const []const u8, tos: []const []const u8, out: [][2]usize) usize {
    const lookup = struct {
        fn of(list: []const []const u8, id: []const u8) ?usize {
            for (list, 0..) |x, i| if (std.mem.eql(u8, x, id)) return i;
            return null;
        }
    }.of;
    var k: usize = 0;
    const m = @min(froms.len, tos.len);
    for (0..m) |i| {
        const f = lookup(ids, froms[i]) orelse continue;
        const t = lookup(ids, tos[i]) orelse continue;
        if (k >= out.len) break;
        out[k] = .{ f, t };
        k += 1;
    }
    return k;
}

/// Apply a `{"value":{"nodes":[{id,label}],"edges":[{from,to}]}}` snapshot and
/// reconcile. A NAMED export (not address-taken) called by the JS poll loop with
/// the reply bytes staged in island scratch — so the chunk adds no entry to the
/// shared indirect function table (a `&handler` would collide; see the table
/// footprint note above).
export fn viz_apply_snapshot(ptr: u32, len: u32) void {
    awaiting_resync = false;
    const bytes = @as([*]const u8, @ptrFromInt(@as(usize, ptr)))[0..len];
    const doc = verve.parseJson(bytes) orelse return;
    defer doc.free();
    const value = doc.get("value") orelse return;
    // Seq-stamp the baseline so subsequent push deltas order against it
    // (absent on pre-seq servers → 0, which accepts any next delta via resync).
    if (value.get("seq")) |s| last_seq = @intCast(@max(s.int(), 0));
    const nodes = value.get("nodes") orelse return;
    const edges = value.get("edges") orelse return;
    const node_n_i = nodes.len();
    if (node_n_i <= 0) return;
    const node_n: usize = @min(@as(usize, @intCast(node_n_i)), MAX_N);

    const m = verve.chunkArenaMark();
    defer verve.chunkArenaReset(m);
    const a = verve.chunkArena();

    const ids = a.alloc([]const u8, node_n) catch return;
    const labels = a.alloc([]const u8, node_n) catch return;
    for (0..node_n) |i| {
        const nd = nodes.at(@intCast(i)) orelse return;
        const id_j = nd.get("id") orelse return;
        const lab_j = nd.get("label") orelse id_j;
        const ib = a.alloc(u8, MAX_ID) catch return;
        ids[i] = a.dupe(u8, id_j.str(ib)) catch return;
        const lb = a.alloc(u8, MAX_LABEL) catch return;
        labels[i] = a.dupe(u8, lab_j.str(lb)) catch return;
    }

    const edge_n_i = edges.len();
    const ecap: usize = if (edge_n_i <= 0) 0 else @min(@as(usize, @intCast(edge_n_i)), MAX_E);
    const froms = a.alloc([]const u8, ecap) catch return;
    const tos = a.alloc([]const u8, ecap) catch return;
    for (0..ecap) |i| {
        const ed = edges.at(@intCast(i)) orelse return;
        const fj = ed.get("from") orelse return;
        const tj = ed.get("to") orelse return;
        const fb = a.alloc(u8, MAX_ID) catch return;
        const tb = a.alloc(u8, MAX_ID) catch return;
        froms[i] = a.dupe(u8, fj.str(fb)) catch return;
        tos[i] = a.dupe(u8, tj.str(tb)) catch return;
    }
    const pairs = a.alloc([2]usize, ecap) catch return;
    const k = mapSnapshotEdges(ids, froms, tos, pairs);

    reconcile(ids, labels, pairs[0..k]);
}

/// Apply a `{"seq":N,"ops":[...]}` wire delta from the `viz` push channel.
/// Ops mutate arena copies of the model (the canonical semantics live in
/// core/viz/delta.zig `applyOps` — chunks can't import across the module
/// boundary, so this mirrors them); the existing `reconcile` then drives the
/// keyed DOM diff. Out-of-order seq → snapshot resync; stale seq → dropped.
/// NAMED export, called by the JS push dispatcher — no table entry.
export fn viz_apply_delta(ptr: u32, len: u32) void {
    const bytes = @as([*]const u8, @ptrFromInt(@as(usize, ptr)))[0..len];
    const doc = verve.parseJson(bytes) orelse return;
    defer doc.free();
    if (doc.get("resync") != null) {
        requestResync();
        return;
    }
    const seq_j = doc.get("seq") orelse return;
    const seq: u64 = @intCast(@max(seq_j.int(), 0));
    if (seq <= last_seq) return; // duplicate / stale frame
    if (seq != last_seq + 1) {
        requestResync(); // missed at least one frame
        return;
    }
    const ops = doc.get("ops") orelse return;
    const ops_n_i = ops.len();
    if (ops_n_i < 0) return;

    const m = verve.chunkArenaMark();
    defer verve.chunkArenaReset(m);
    const a = verve.chunkArena();

    // Working copies of the model: node ids/labels plus edges as id pairs
    // (slot indices would go stale as removals shift the node set).
    const ids = a.alloc([]const u8, MAX_N) catch return;
    const labels = a.alloc([]const u8, MAX_N) catch return;
    var cnt: usize = 0;
    while (cnt < n) : (cnt += 1) {
        ids[cnt] = a.dupe(u8, idOf(cnt)) catch return;
        labels[cnt] = a.dupe(u8, labelOf(cnt)) catch return;
    }
    const efrom = a.alloc([]const u8, MAX_E) catch return;
    const eto = a.alloc([]const u8, MAX_E) catch return;
    var ecnt: usize = 0;
    while (ecnt < edge_n) : (ecnt += 1) {
        efrom[ecnt] = a.dupe(u8, idOf(ef[ecnt])) catch return;
        eto[ecnt] = a.dupe(u8, idOf(et[ecnt])) catch return;
    }

    var i: u32 = 0;
    while (i < @as(u32, @intCast(ops_n_i))) : (i += 1) {
        const op = ops.at(i) orelse return;
        var kind_buf: [4]u8 = undefined;
        const kind = (op.get("op") orelse return).str(&kind_buf);
        if (std.mem.eql(u8, kind, "+n") or std.mem.eql(u8, kind, "~n")) {
            const idb = a.alloc(u8, MAX_ID) catch return;
            const id = a.dupe(u8, (op.get("id") orelse return).str(idb)) catch return;
            const lb = a.alloc(u8, MAX_LABEL) catch return;
            const label = a.dupe(u8, (op.get("label") orelse return).str(lb)) catch return;
            if (indexOfIdIn(ids[0..cnt], id)) |at| {
                labels[at] = label; // relabel (or redundant add)
            } else if (kind[0] == '+' and cnt < MAX_N) {
                ids[cnt] = id;
                labels[cnt] = label;
                cnt += 1;
            }
        } else if (std.mem.eql(u8, kind, "-n")) {
            var idb: [MAX_ID]u8 = undefined;
            const id = (op.get("id") orelse return).str(&idb);
            if (indexOfIdIn(ids[0..cnt], id)) |at| {
                var j = at;
                while (j + 1 < cnt) : (j += 1) {
                    ids[j] = ids[j + 1];
                    labels[j] = labels[j + 1];
                }
                cnt -= 1;
                var e: usize = 0;
                while (e < ecnt) {
                    if (std.mem.eql(u8, efrom[e], id) or std.mem.eql(u8, eto[e], id)) {
                        var k = e;
                        while (k + 1 < ecnt) : (k += 1) {
                            efrom[k] = efrom[k + 1];
                            eto[k] = eto[k + 1];
                        }
                        ecnt -= 1;
                    } else e += 1;
                }
            }
        } else if (std.mem.eql(u8, kind, "+e")) {
            const fb = a.alloc(u8, MAX_ID) catch return;
            const from = a.dupe(u8, (op.get("from") orelse return).str(fb)) catch return;
            const tb = a.alloc(u8, MAX_ID) catch return;
            const to = a.dupe(u8, (op.get("to") orelse return).str(tb)) catch return;
            var have = false;
            for (0..ecnt) |e| {
                if (std.mem.eql(u8, efrom[e], from) and std.mem.eql(u8, eto[e], to)) have = true;
            }
            if (!have and ecnt < MAX_E) {
                efrom[ecnt] = from;
                eto[ecnt] = to;
                ecnt += 1;
            }
        } else if (std.mem.eql(u8, kind, "-e")) {
            var fb: [MAX_ID]u8 = undefined;
            var tb: [MAX_ID]u8 = undefined;
            const from = (op.get("from") orelse return).str(&fb);
            const to = (op.get("to") orelse return).str(&tb);
            var e: usize = 0;
            while (e < ecnt) : (e += 1) {
                if (std.mem.eql(u8, efrom[e], from) and std.mem.eql(u8, eto[e], to)) {
                    var k = e;
                    while (k + 1 < ecnt) : (k += 1) {
                        efrom[k] = efrom[k + 1];
                        eto[k] = eto[k + 1];
                    }
                    ecnt -= 1;
                    break;
                }
            }
        }
    }

    const pairs = a.alloc([2]usize, ecnt) catch return;
    const k = mapSnapshotEdges(ids[0..cnt], efrom[0..ecnt], eto[0..ecnt], pairs);
    reconcile(ids[0..cnt], labels[0..cnt], pairs[0..k]);
    last_seq = seq;
}

fn indexOfIdIn(list: []const []const u8, id: []const u8) ?usize {
    for (list, 0..) |x, i| if (std.mem.eql(u8, x, id)) return i;
    return null;
}

/// Toggle the live stream. Push-first: subscribe this island's
/// `viz_apply_delta` export to the `viz` SSE channel (plus an immediate
/// snapshot resync as the seq baseline). When the host has no EventSource,
/// fall back to the JS-driven `verveVizPoll` interval. Both paths reach the
/// chunk only through NAMED exports — no indirect-function-table entries.
export fn viz_toggle_live() void {
    polling = !polling;
    if (polling) {
        live_push = verve.pushSubscribe("viz", "VizGraphInteractive", "viz_apply_delta");
        if (live_push) {
            requestResync();
        } else {
            var out: [16]u8 = undefined;
            _ = verve.host("verveVizPoll", "{\"on\":1,\"interval\":2000}", &out);
        }
    } else {
        if (live_push) {
            verve.pushUnsubscribe("viz", "VizGraphInteractive");
            live_push = false;
        } else {
            var out: [16]u8 = undefined;
            _ = verve.host("verveVizPoll", "{\"on\":0}", &out);
        }
        awaiting_resync = false;
    }
    if (verve.queryRef(@as([]const u8, "viz-live-btn"))) |h| verve.setRefClass(h, "live-on", polling);
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
