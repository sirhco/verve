//! Interactive graph island: wheel-zoom, drag-to-pan, node drag (incident edges
//! follow), hover tooltip, click-select, dblclick subtree collapse, **runtime
//! add/remove** of nodes + edges (keyed reconciler, preserving zoom/pan +
//! selection + collapse), layout-aware relayout with tweening (tree/radial/dag
//! via `viz_core`), and live SSE wire-delta streaming with seq-gap resync.
//! Nodes are keyed by stable id (not index) so mutation is stable.
//!
//! Supports up to MAX_INSTANCES concurrent island instances per page (each
//! isolated in its own `Inst` slot). Gestures are pointer-captured, so they
//! survive the pointer leaving the svg; they end on `pointerup` / `pointercancel`.

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

// ---- constants --------------------------------------------------------------
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

// For the deterministic layouts (tree/radial/dag) runtime mutation recomputes
// the whole layout via `verve.viz_core` — the exact algorithms + fit SSR used
// — then tweens survivors from their current positions to the new targets.
// The tween is driven by the JS `verveRafNamed` loop calling the NAMED
// `viz_tick` export each frame (no function-table entry).
const LAYOUT_FORCE: u32 = 2; // @intFromEnum(viz.Layout.force)
const ANIM_TOTAL: u32 = 24;

// ---- per-island instance state -----------------------------------------------
const Inst = struct {
    in_use: bool = false,
    vid: u32 = 0,

    gx: [MAX_N]f64 = undefined,
    gy: [MAX_N]f64 = undefined,
    n: usize = 0,
    ef: [MAX_E]usize = undefined, // edge from-slot
    et: [MAX_E]usize = undefined, // edge to-slot
    edge_n: usize = 0,
    id_buf: [MAX_N * MAX_ID]u8 = undefined,
    id_off: [MAX_N + 1]usize = undefined,
    label_buf: [MAX_N * MAX_LABEL]u8 = undefined,
    label_off: [MAX_N + 1]usize = undefined,

    view: View = .{},
    vbw: f64 = 0,
    vbh: f64 = 0,

    drag_node: ?usize = null,
    panning: bool = false,
    last_sx: f64 = 0,
    last_sy: f64 = 0,
    sel_buf: [MAX_ID]u8 = undefined,
    sel_len: usize = 0,

    // subtree collapse
    // The model always holds the FULL graph; `collapsed` (user dblclick toggles)
    // derives `hidden`, which only filters what reaches the DOM. Live deltas
    // mutate the model unconditionally and visibility is recomputed afterward, so
    // collapse composes with streaming updates.
    collapsed: [MAX_N]bool = @splat(false),
    hidden: [MAX_N]bool = @splat(false),
    bfs_visited: [MAX_N]bool = undefined,
    bfs_queue: [MAX_N]usize = undefined,

    // layout transitions
    layout_kind: u32 = LAYOUT_FORCE,
    margin_p: f64 = 40,
    txs: [MAX_N]f64 = undefined,
    tys: [MAX_N]f64 = undefined,
    anim_sx: [MAX_N]f64 = undefined,
    anim_sy: [MAX_N]f64 = undefined,
    anim_frame: u32 = 0,
    anim_on: bool = false,

    // force relaxation scratch
    fvx: [MAX_N]f64 = undefined,
    fvy: [MAX_N]f64 = undefined,

    // live-data streaming (SSE push + poll fallback)
    polling: bool = false,
    /// True while the SSE push path is active (EventSource available).
    live_push: bool = false,
    /// Last applied seq (0 = no baseline yet). A delta applies only when its seq
    /// is exactly `last_seq + 1`; any gap forces a snapshot resync.
    last_seq: u64 = 0,
    awaiting_resync: bool = false,

    // demo mutation counter
    add_seq: u32 = 0,
};

// ---- slot machinery ----------------------------------------------------------
const MAX_INSTANCES = 2;
var instances: [MAX_INSTANCES]Inst = .{Inst{}} ** MAX_INSTANCES;
// The instance the bridge selected for the in-flight dispatch (frame / event /
// asset callback / restore). Set by `viz_select`; null = unknown vid (every
// export null-guards → silent no-op).
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
export fn viz_select(root_id: u32) void {
    current = findSlot(root_id);
}

/// Bridge calls this when an island's container disconnects. Reclaims the slot
/// so add/remove cycles don't exhaust the pool.
export fn viz_unmount(root_id: u32) void {
    if (findSlot(root_id)) |inst| {
        if (current == inst) current = null;
        inst.* = Inst{}; // in_use=false, vid=0
    }
}

// ---- subtree collapse --------------------------------------------------------

/// Mirror of core/viz/interact.zig `collapseHidden` (unit-tested there; chunks
/// can't import across the module boundary): BFS each collapsed root's
/// directed out-edges, hiding everything reached except the root itself.
fn recomputeHidden(inst: *Inst) void {
    @memset(inst.hidden[0..inst.n], false);
    for (0..inst.n) |root| {
        if (!inst.collapsed[root]) continue;
        @memset(inst.bfs_visited[0..inst.n], false);
        inst.bfs_visited[root] = true;
        var head: usize = 0;
        var tail: usize = 0;
        inst.bfs_queue[tail] = root;
        tail += 1;
        while (head < tail) {
            const cur = inst.bfs_queue[head];
            head += 1;
            for (0..inst.edge_n) |e| {
                if (inst.ef[e] != cur) continue;
                const t = inst.et[e];
                if (t >= inst.n or inst.bfs_visited[t]) continue;
                inst.bfs_visited[t] = true;
                inst.hidden[t] = true;
                if (tail < MAX_N) {
                    inst.bfs_queue[tail] = t;
                    tail += 1;
                }
            }
        }
    }
}

/// Hidden-descendant count for a collapsed node's `+N` badge.
fn hiddenCountFrom(inst: *Inst, root: usize) usize {
    @memset(inst.bfs_visited[0..inst.n], false);
    inst.bfs_visited[root] = true;
    var head: usize = 0;
    var tail: usize = 0;
    var count: usize = 0;
    inst.bfs_queue[tail] = root;
    tail += 1;
    while (head < tail) {
        const cur = inst.bfs_queue[head];
        head += 1;
        for (0..inst.edge_n) |e| {
            if (inst.ef[e] != cur) continue;
            const t = inst.et[e];
            if (t >= inst.n or inst.bfs_visited[t]) continue;
            inst.bfs_visited[t] = true;
            if (inst.hidden[t]) count += 1;
            if (tail < MAX_N) {
                inst.bfs_queue[tail] = t;
                tail += 1;
            }
        }
    }
    return count;
}

fn edgeVisible(inst: *Inst, e: usize) bool {
    return !inst.hidden[inst.ef[e]] and !inst.hidden[inst.et[e]];
}

// ---- layout transitions ------------------------------------------------------

/// Recompute `txs`/`tys` for the current deterministic layout. Returns false
/// for force (incremental relax handles it) or on failure.
fn recomputeTargets(inst: *Inst, a: std.mem.Allocator) bool {
    const vc = verve.viz_core;
    if (inst.n == 0) return false;
    const pairs = a.alloc(vc.common.Edge, inst.edge_n) catch return false;
    for (0..inst.edge_n) |e| pairs[e] = .{ inst.ef[e], inst.et[e] };
    const center = vc.geom.Vec2{ .x = inst.vbw / 2.0, .y = inst.vbh / 2.0 };
    const positions = switch (inst.layout_kind) {
        0 => vc.tree.layout(a, inst.n, pairs, .{}) catch return false,
        1 => vc.radial.layout(a, inst.n, pairs, .{ .center = center }) catch return false,
        3 => vc.dag.layout(a, inst.n, pairs, .{}) catch return false,
        else => return false,
    };
    const f = vc.geom.fitBox(positions, inst.vbw, inst.vbh, inst.margin_p);
    for (positions, 0..) |p, i| {
        const q = vc.geom.applyFit(p, f);
        inst.txs[i] = q.x;
        inst.tys[i] = q.y;
    }
    return true;
}

fn startTween(inst: *Inst) void {
    inst.anim_frame = 0;
    inst.anim_on = true;
    var args_buf: [96]u8 = undefined;
    const args = std.fmt.bufPrint(&args_buf, "{{\"island\":\"VizGraphInteractive\",\"export\":\"viz_tick\",\"on\":1,\"vid\":{d}}}", .{inst.vid}) catch return;
    var out: [16]u8 = undefined;
    _ = verve.host("verveRafNamed", args, &out);
}

// ---- id storage -------------------------------------------------------------
fn idOf(inst: *Inst, slot: usize) []const u8 {
    return inst.id_buf[inst.id_off[slot]..inst.id_off[slot + 1]];
}
fn slotOfId(inst: *Inst, id: []const u8) ?usize {
    for (0..inst.n) |i| if (std.mem.eql(u8, idOf(inst, i), id)) return i;
    return null;
}
fn labelOf(inst: *Inst, slot: usize) []const u8 {
    return inst.label_buf[inst.label_off[slot]..inst.label_off[slot + 1]];
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
fn scopedRef(inst: *Inst, buf: []u8, base: []const u8) ?[]const u8 {
    if (inst.vid == 0) return std.fmt.bufPrint(buf, "{s}", .{base}) catch null;
    return std.fmt.bufPrint(buf, "{s}__v{d}", .{ base, inst.vid }) catch null;
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

// ---- DOM helpers -------------------------------------------------------------
fn svgRect(inst: *Inst) verve.Rect {
    if (ref("viz-svg")) |h| return verve.refRect(h);
    return .{ .x = 0, .y = 0, .w = inst.vbw, .h = inst.vbh };
}
fn pointerSvg(inst: *Inst) Vec2 {
    const r = svgRect(inst);
    return clientToSvg(r.x, r.y, r.w, r.h, inst.vbw, inst.vbh, verve.eventCoordX(), verve.eventCoordY());
}
fn applyRootTransform(inst: *Inst) void {
    const h = ref("viz-root") orelse return;
    var buf: [96]u8 = undefined;
    const t = std.fmt.bufPrint(&buf, "translate({d},{d}) scale({d})", .{ inst.view.tx, inst.view.ty, inst.view.z }) catch return;
    verve.setRefAttr(h, "transform", t);
}
fn setNodeXY(inst: *Inst, slot: usize) void {
    const h = resolveNodeId(idOf(inst, slot)) orelse return;
    var b: [64]u8 = undefined;
    const t = std.fmt.bufPrint(&b, "translate({d},{d})", .{ inst.gx[slot], inst.gy[slot] }) catch return;
    verve.setRefAttr(h, "transform", t);
}
fn updateEdge(inst: *Inst, e: usize) void {
    const h = resolveEdge(idOf(inst, inst.ef[e]), idOf(inst, inst.et[e])) orelse return;
    var b: [24]u8 = undefined;
    verve.setRefAttr(h, "x1", std.fmt.bufPrint(&b, "{d}", .{inst.gx[inst.ef[e]]}) catch return);
    verve.setRefAttr(h, "y1", std.fmt.bufPrint(&b, "{d}", .{inst.gy[inst.ef[e]]}) catch return);
    verve.setRefAttr(h, "x2", std.fmt.bufPrint(&b, "{d}", .{inst.gx[inst.et[e]]}) catch return);
    verve.setRefAttr(h, "y2", std.fmt.bufPrint(&b, "{d}", .{inst.gy[inst.et[e]]}) catch return);
}

fn hitSlot(inst: *Inst) ?usize {
    var buf: [MAX_ID]u8 = undefined;
    const s = verve.eventTargetAttr("node", &buf);
    if (s.len == 0) return null;
    return slotOfId(inst, s);
}

// ---- tween frame export ------------------------------------------------------

/// One tween frame; returns 1 while the JS rAF loop should continue.
export fn viz_tick() i32 {
    const inst = current orelse return 0;
    if (!inst.anim_on) return 0;
    inst.anim_frame += 1;
    const t = @min(1.0, @as(f64, @floatFromInt(inst.anim_frame)) / @as(f64, @floatFromInt(ANIM_TOTAL)));
    const s = verve.viz_core.interact.easeOutCubic(t);
    for (0..inst.n) |i| {
        inst.gx[i] = inst.anim_sx[i] + (inst.txs[i] - inst.anim_sx[i]) * s;
        inst.gy[i] = inst.anim_sy[i] + (inst.tys[i] - inst.anim_sy[i]) * s;
    }
    for (0..inst.n) |i| {
        if (!inst.hidden[i]) setNodeXY(inst, i);
    }
    for (0..inst.edge_n) |e| {
        if (edgeVisible(inst, e)) updateEdge(inst, e);
    }
    if (inst.anim_frame >= ANIM_TOTAL) {
        for (0..inst.n) |i| {
            inst.gx[i] = inst.txs[i];
            inst.gy[i] = inst.tys[i];
        }
        inst.anim_on = false;
        return 0;
    }
    return 1;
}

/// Demo control: cycle tree → radial → force → dag, tweening every node from
/// its current position to the new layout.
export fn viz_layout_cycle() void {
    const inst = current orelse return;
    if (inst.n == 0) return;
    inst.layout_kind = (inst.layout_kind + 1) % 4;
    const mark = verve.chunkArenaMark();
    defer verve.chunkArenaReset(mark);
    const a = verve.chunkArena();
    for (0..inst.n) |i| {
        inst.anim_sx[i] = inst.gx[i];
        inst.anim_sy[i] = inst.gy[i];
    }
    if (inst.layout_kind == LAYOUT_FORCE) {
        forceRelax(inst, 120);
        for (0..inst.n) |i| {
            inst.txs[i] = inst.gx[i];
            inst.tys[i] = inst.gy[i];
            inst.gx[i] = inst.anim_sx[i];
            inst.gy[i] = inst.anim_sy[i];
        }
    } else if (!recomputeTargets(inst, a)) {
        return;
    }
    startTween(inst);
    if (ref("viz-layout-btn")) |h| {
        const name: []const u8 = switch (inst.layout_kind) {
            0 => "⟳ tree",
            1 => "⟳ radial",
            2 => "⟳ force",
            else => "⟳ dag",
        };
        verve.setRefText(h, name);
    }
}

// ---- runtime mutation -------------------------------------------------------

/// Relax the current `gx/gy` with `iters` force steps (repulsion + edge springs
/// + centroid gravity). Seeded from current positions → survivors barely move.
fn forceRelax(inst: *Inst, iters: usize) void {
    if (inst.n == 0) return;
    var ccx: f64 = 0;
    var ccy: f64 = 0;
    for (0..inst.n) |i| {
        ccx += inst.gx[i];
        ccy += inst.gy[i];
    }
    ccx /= @floatFromInt(inst.n);
    ccy /= @floatFromInt(inst.n);
    const rep: f64 = 3000;
    const spring: f64 = 0.04;
    const rest: f64 = 90;
    const grav: f64 = 0.02;
    const damp: f64 = 0.85;
    const dt: f64 = 0.6;
    @memset(inst.fvx[0..inst.n], 0);
    @memset(inst.fvy[0..inst.n], 0);
    for (0..iters) |_| {
        var i: usize = 0;
        while (i < inst.n) : (i += 1) {
            var j: usize = i + 1;
            while (j < inst.n) : (j += 1) {
                var dx = inst.gx[i] - inst.gx[j];
                var dy = inst.gy[i] - inst.gy[j];
                var d = @sqrt(dx * dx + dy * dy);
                if (d < 1) {
                    dx = 1;
                    dy = 0;
                    d = 1;
                }
                const f = rep / (d * d);
                const ux = dx / d * f * dt;
                const uy = dy / d * f * dt;
                inst.fvx[i] += ux;
                inst.fvy[i] += uy;
                inst.fvx[j] -= ux;
                inst.fvy[j] -= uy;
            }
        }
        for (0..inst.edge_n) |e| {
            const u = inst.ef[e];
            const v = inst.et[e];
            if (u >= inst.n or v >= inst.n or u == v) continue;
            const dx = inst.gx[v] - inst.gx[u];
            const dy = inst.gy[v] - inst.gy[u];
            var d = @sqrt(dx * dx + dy * dy);
            if (d < 1) d = 1;
            const f = spring * (d - rest);
            const ux = dx / d * f * dt;
            const uy = dy / d * f * dt;
            inst.fvx[u] += ux;
            inst.fvy[u] += uy;
            inst.fvx[v] -= ux;
            inst.fvy[v] -= uy;
        }
        for (0..inst.n) |k| {
            inst.fvx[k] = (inst.fvx[k] + (ccx - inst.gx[k]) * grav * dt) * damp;
            inst.fvy[k] = (inst.fvy[k] + (ccy - inst.gy[k]) * grav * dt) * damp;
            inst.gx[k] += inst.fvx[k] * dt;
            inst.gy[k] += inst.fvy[k] * dt;
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
fn reconcile(inst: *Inst, new_ids: []const []const u8, new_labels: []const []const u8, new_edges: []const [2]usize) void {
    const mark = verve.chunkArenaMark();
    defer verve.chunkArenaReset(mark);
    const a = verve.chunkArena();
    const nn = @min(new_ids.len, MAX_N);

    var ccx: f64 = 0;
    var ccy: f64 = 0;
    if (inst.n > 0) {
        for (0..inst.n) |i| {
            ccx += inst.gx[i];
            ccy += inst.gy[i];
        }
        ccx /= @floatFromInt(inst.n);
        ccy /= @floatFromInt(inst.n);
    } else {
        ccx = inst.vbw / 2;
        ccy = inst.vbh / 2;
    }

    const nx = a.alloc(f64, nn) catch return;
    const ny = a.alloc(f64, nn) catch return;
    const is_new = a.alloc(bool, nn) catch return;
    for (0..nn) |i| {
        if (slotOfId(inst, new_ids[i])) |s| {
            nx[i] = inst.gx[s];
            ny[i] = inst.gy[s];
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
    const old_vis = captureVisibleKeys(inst, a) orelse return;

    // Carry collapsed flags across the rebuild by id (like positions).
    const old_coll = a.alloc([]const u8, inst.n) catch return;
    var oc: usize = 0;
    for (0..inst.n) |i| {
        if (inst.collapsed[i]) {
            old_coll[oc] = a.dupe(u8, idOf(inst, i)) catch return;
            oc += 1;
        }
    }

    // Commit new node state.
    var ioff: usize = 0;
    var loff: usize = 0;
    for (0..nn) |i| {
        inst.gx[i] = nx[i];
        inst.gy[i] = ny[i];
        inst.id_off[i] = ioff;
        const idt = @min(new_ids[i].len, MAX_ID);
        @memcpy(inst.id_buf[ioff .. ioff + idt], new_ids[i][0..idt]);
        ioff += idt;
        inst.label_off[i] = loff;
        const lt = @min(new_labels[i].len, MAX_LABEL);
        @memcpy(inst.label_buf[loff .. loff + lt], new_labels[i][0..lt]);
        loff += lt;
    }
    inst.id_off[nn] = ioff;
    inst.label_off[nn] = loff;
    inst.n = nn;
    inst.edge_n = @min(new_edges.len, MAX_E);
    for (0..inst.edge_n) |e| {
        inst.ef[e] = new_edges[e][0];
        inst.et[e] = new_edges[e][1];
    }

    for (0..inst.n) |i| {
        inst.collapsed[i] = false;
        for (old_coll[0..oc]) |cid| {
            if (std.mem.eql(u8, idOf(inst, i), cid)) inst.collapsed[i] = true;
        }
    }

    if (inst.layout_kind == LAYOUT_FORCE) {
        // Incremental: survivors barely move, new nodes relax in near the
        // centroid seed. Positions are final — no tween.
        forceRelax(inst, 50);
        inst.anim_on = false;
    } else if (recomputeTargets(inst, a)) {
        // Global deterministic layout: new nodes appear at their final
        // positions; survivors tween from where they were.
        var any_tween = false;
        for (0..inst.n) |i| {
            inst.anim_sx[i] = inst.gx[i];
            inst.anim_sy[i] = inst.gy[i];
            if (is_new[i]) {
                inst.gx[i] = inst.txs[i];
                inst.gy[i] = inst.tys[i];
                inst.anim_sx[i] = inst.txs[i];
                inst.anim_sy[i] = inst.tys[i];
            } else if (inst.gx[i] != inst.txs[i] or inst.gy[i] != inst.tys[i]) {
                any_tween = true;
            }
        }
        if (any_tween) startTween(inst);
    }
    recomputeHidden(inst);
    syncDom(inst, a, old_vis.nkeys, old_vis.ekeys);

    inst.drag_node = null;
    inst.panning = false;
}

const VisKeys = struct { nkeys: []const []const u8, ekeys: []const []const u8 };

/// Arena copies of the keys currently in the DOM: visible nodes + edges whose
/// endpoints are both visible, under the *current* model + `hidden` state.
fn captureVisibleKeys(inst: *Inst, a: std.mem.Allocator) ?VisKeys {
    const nkeys = a.alloc([]const u8, inst.n) catch return null;
    var nk: usize = 0;
    for (0..inst.n) |i| {
        if (inst.hidden[i]) continue;
        nkeys[nk] = a.dupe(u8, idOf(inst, i)) catch return null;
        nk += 1;
    }
    const ekeys = a.alloc([]const u8, inst.edge_n) catch return null;
    var ek: usize = 0;
    for (0..inst.edge_n) |e| {
        if (!edgeVisible(inst, e)) continue;
        ekeys[ek] = aprint(a, "{s}|{s}", .{ idOf(inst, inst.ef[e]), idOf(inst, inst.et[e]) }) orelse return null;
        ek += 1;
    }
    return .{ .nkeys = nkeys[0..nk], .ekeys = ekeys[0..ek] };
}

/// Drive the keyed reconciler from `old_*keys` (the previous visible DOM set)
/// to the current model's visible subset. Collapsed nodes stay visible with a
/// `collapsed` class and a `+N` hidden-descendant badge in their label.
/// Zoom/pan (`viz-root` transform) is untouched → preserved.
fn syncDom(inst: *Inst, a: std.mem.Allocator, old_nkeys: []const []const u8, old_ekeys: []const []const u8) void {
    // New keys + html (refs baked vid-scoped).
    const nkeys = a.alloc([]const u8, inst.n) catch return;
    const nhtml = a.alloc([]const u8, inst.n) catch return;
    var nk: usize = 0;
    for (0..inst.n) |i| {
        if (inst.hidden[i]) continue;
        nkeys[nk] = idOf(inst, i);
        const base = aprint(a, "viz-node-{s}", .{idOf(inst, i)}) orelse return;
        const sbuf = a.alloc(u8, 96) catch return;
        const sref = scopedRef(inst, sbuf, base) orelse return;
        var klass: []const u8 = "viz-node";
        var disp: []const u8 = labelOf(inst, i);
        if (inst.collapsed[i]) {
            klass = "viz-node collapsed";
            const hc = hiddenCountFrom(inst, i);
            if (hc > 0) disp = aprint(a, "{s} +{d}", .{ labelOf(inst, i), hc }) orelse return;
        }
        const hbuf = a.alloc(u8, 1024) catch return;
        nhtml[nk] = nodeFragment(hbuf, idOf(inst, i), sref, disp, inst.gx[i], inst.gy[i], klass) catch return;
        nk += 1;
    }
    // `verve_list_diff` does NOT vid-scope the parent bind (unlike queryRef) —
    // pass the already-scoped container name.
    var npbuf: [48]u8 = undefined;
    const nodes_parent = scopedRef(inst, &npbuf, "viz-nodes") orelse return;
    verve.listDiff(nodes_parent, old_nkeys, nkeys[0..nk], nhtml[0..nk]);

    const ekeys = a.alloc([]const u8, inst.edge_n) catch return;
    const ehtml = a.alloc([]const u8, inst.edge_n) catch return;
    var ek: usize = 0;
    for (0..inst.edge_n) |e| {
        if (!edgeVisible(inst, e)) continue;
        const key = aprint(a, "{s}|{s}", .{ idOf(inst, inst.ef[e]), idOf(inst, inst.et[e]) }) orelse return;
        ekeys[ek] = key;
        const base = aprint(a, "viz-edge-{s}", .{key}) orelse return;
        const sbuf = a.alloc(u8, 96) catch return;
        const sref = scopedRef(inst, sbuf, base) orelse return;
        const hbuf = a.alloc(u8, 320) catch return;
        ehtml[ek] = edgeFragment(hbuf, key, sref, inst.gx[inst.ef[e]], inst.gy[inst.ef[e]], inst.gx[inst.et[e]], inst.gy[inst.et[e]]) catch return;
        ek += 1;
    }
    var epbuf: [48]u8 = undefined;
    const edges_parent = scopedRef(inst, &epbuf, "viz-edges") orelse return;
    verve.listDiff(edges_parent, old_ekeys, ekeys[0..ek], ehtml[0..ek]);

    // Snap survivors to exact final positions (created elements already carry
    // them, but moved survivors need updating). Hidden elements have no DOM —
    // their queryRef misses are harmless no-ops.
    for (0..inst.n) |i| {
        if (!inst.hidden[i]) setNodeXY(inst, i);
    }
    for (0..inst.edge_n) |e| {
        if (edgeVisible(inst, e)) updateEdge(inst, e);
    }

    // Selection dies when its node leaves the graph or the visible set.
    if (inst.sel_len != 0) {
        if (slotOfId(inst, inst.sel_buf[0..inst.sel_len])) |s| {
            if (inst.hidden[s]) inst.sel_len = 0;
        } else inst.sel_len = 0;
    }
}

// ---- hydrate + gesture exports -----------------------------------------------

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    const inst = allocSlot(root_id) orelse return;
    current = inst;
    if (props_len == 0) return;
    const bytes = @as([*]const u8, @ptrFromInt(@as(usize, props_ptr)))[0..props_len];
    const mark = verve.chunkArenaMark();
    defer verve.chunkArenaReset(mark);
    const p = verve.decodeProps(Props, bytes, verve.chunkArena()) catch return;

    inst.n = @min(@min(p.xs.len, p.ys.len), MAX_N);
    inst.n = @min(inst.n, p.ids.len);
    var ioff: usize = 0;
    var loff: usize = 0;
    for (0..inst.n) |i| {
        inst.gx[i] = p.xs[i];
        inst.gy[i] = p.ys[i];
        inst.id_off[i] = ioff;
        const idt = @min(p.ids[i].len, MAX_ID);
        @memcpy(inst.id_buf[ioff .. ioff + idt], p.ids[i][0..idt]);
        ioff += idt;
        inst.label_off[i] = loff;
        if (i < p.labels.len) {
            const lt = @min(p.labels[i].len, MAX_LABEL);
            @memcpy(inst.label_buf[loff .. loff + lt], p.labels[i][0..lt]);
            loff += lt;
        }
    }
    inst.id_off[inst.n] = ioff;
    inst.label_off[inst.n] = loff;

    inst.edge_n = @min(@min(p.ef.len, p.et.len), MAX_E);
    for (0..inst.edge_n) |i| {
        inst.ef[i] = @intCast(p.ef[i]);
        inst.et[i] = @intCast(p.et[i]);
    }

    inst.layout_kind = p.layout;
    inst.margin_p = p.margin;

    if (ref("viz-svg")) |h| {
        const r = verve.refRect(h);
        inst.vbw = r.w;
        inst.vbh = r.h;
    }
}

export fn viz_wheel() void {
    const inst = current orelse return;
    verve.eventPreventDefault();
    const c = pointerSvg(inst);
    const factor: f64 = if (verve.eventDeltaY() < 0) 1.1 else 1.0 / 1.1;
    inst.view = zoomToward(inst.view, c, factor, MIN_Z, MAX_Z);
    applyRootTransform(inst);
}

export fn viz_pointerdown() void {
    const inst = current orelse return;
    const svg = pointerSvg(inst);
    inst.last_sx = svg.x;
    inst.last_sy = svg.y;
    if (hitSlot(inst)) |slot| {
        inst.drag_node = slot;
        inst.panning = false;
        inst.anim_on = false; // drag wins over a running layout tween
    } else {
        inst.panning = true;
        inst.drag_node = null;
    }
    // Capture the pointer so the gesture survives leaving the svg;
    // capture suppresses node over/out mid-gesture, so hide the tooltip
    // defensively in case it was showing.
    verve.eventCapturePointer();
    if (ref("viz-tooltip")) |h| verve.setRefAttr(h, "style", "display:none");
}

export fn viz_pointermove() void {
    const inst = current orelse return;
    const svg = pointerSvg(inst);
    if (inst.drag_node) |i| {
        const gp = svgToGraph(inst.view, svg);
        inst.gx[i] = gp.x;
        inst.gy[i] = gp.y;
        setNodeXY(inst, i);
        for (0..inst.edge_n) |e| {
            if (inst.ef[e] == i or inst.et[e] == i) updateEdge(inst, e);
        }
    } else if (inst.panning) {
        inst.view.tx += svg.x - inst.last_sx;
        inst.view.ty += svg.y - inst.last_sy;
        inst.last_sx = svg.x;
        inst.last_sy = svg.y;
        applyRootTransform(inst);
    }
}

export fn viz_pointerup() void {
    const inst = current orelse return;
    inst.drag_node = null;
    inst.panning = false;
}

export fn viz_node_over() void {
    const inst = current orelse return;
    const i = hitSlot(inst) orelse return;
    if (ref("viz-tooltip-text")) |h| verve.setRefText(h, labelOf(inst, i));
    if (ref("viz-tooltip")) |h| {
        var buf: [64]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, "translate({d},{d})", .{ inst.gx[i], inst.gy[i] }) catch return;
        verve.setRefAttr(h, "transform", t);
        verve.setRefAttr(h, "style", "display:block");
    }
}

export fn viz_node_out() void {
    _ = current orelse return;
    if (ref("viz-tooltip")) |h| verve.setRefAttr(h, "style", "display:none");
}

export fn viz_node_click() void {
    const inst = current orelse return;
    const i = hitSlot(inst) orelse return;
    if (inst.sel_len != 0) {
        if (resolveNodeId(inst.sel_buf[0..inst.sel_len])) |h| verve.setRefClass(h, "selected", false);
    }
    if (resolveNodeId(idOf(inst, i))) |h| verve.setRefClass(h, "selected", true);
    const id = idOf(inst, i);
    inst.sel_len = @min(id.len, MAX_ID);
    @memcpy(inst.sel_buf[0..inst.sel_len], id[0..inst.sel_len]);
}

/// Double-click toggles a node's subtree collapse. The model is untouched —
/// only visibility recomputes, then the DOM syncs from the previous visible
/// set to the new one.
export fn viz_node_dblclick() void {
    const inst = current orelse return;
    const slot = hitSlot(inst) orelse return;
    const mark = verve.chunkArenaMark();
    defer verve.chunkArenaReset(mark);
    const a = verve.chunkArena();
    const old_vis = captureVisibleKeys(inst, a) orelse return;
    inst.collapsed[slot] = !inst.collapsed[slot];
    recomputeHidden(inst);
    syncDom(inst, a, old_vis.nkeys, old_vis.ekeys);
    if (ref("viz-tooltip")) |h| verve.setRefAttr(h, "style", "display:none");
}

// ---- live-data streaming (SSE push + poll fallback) --------------------------

/// Pull a fresh `{seq, nodes, edges}` snapshot via the JS one-shot fetch and
/// hand it to `viz_apply_snapshot` — used as the push path's baseline and
/// whenever a delta seq gap (missed frame / ring overrun) is detected.
fn requestResync(inst: *Inst) void {
    if (inst.awaiting_resync) return;
    inst.awaiting_resync = true;
    verve.fetchToExport("vizGraph", "VizGraphInteractive", "viz_apply_snapshot", inst.vid);
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
    const inst = current orelse return;
    inst.awaiting_resync = false;
    const bytes = @as([*]const u8, @ptrFromInt(@as(usize, ptr)))[0..len];
    const doc = verve.parseJson(bytes) orelse return;
    defer doc.free();
    const value = doc.get("value") orelse return;
    // Seq-stamp the baseline so subsequent push deltas order against it
    // (absent on pre-seq servers → 0, which accepts any next delta via resync).
    if (value.get("seq")) |s| inst.last_seq = @intCast(@max(s.int(), 0));
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

    reconcile(inst, ids, labels, pairs[0..k]);
}

/// Apply a `{"seq":N,"ops":[...]}` wire delta from the `viz` push channel.
/// Ops mutate arena copies of the model (the canonical semantics live in
/// core/viz/delta.zig `applyOps` — chunks can't import across the module
/// boundary, so this mirrors them); the existing `reconcile` then drives the
/// keyed DOM diff. Out-of-order seq → snapshot resync; stale seq → dropped.
/// NAMED export, called by the JS push dispatcher — no table entry.
export fn viz_apply_delta(ptr: u32, len: u32) void {
    const inst = current orelse return;
    const bytes = @as([*]const u8, @ptrFromInt(@as(usize, ptr)))[0..len];
    const doc = verve.parseJson(bytes) orelse return;
    defer doc.free();
    if (doc.get("resync") != null) {
        requestResync(inst);
        return;
    }
    const seq_j = doc.get("seq") orelse return;
    const seq: u64 = @intCast(@max(seq_j.int(), 0));
    if (seq <= inst.last_seq) return; // duplicate / stale frame
    if (seq != inst.last_seq + 1) {
        requestResync(inst); // missed at least one frame
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
    while (cnt < inst.n) : (cnt += 1) {
        ids[cnt] = a.dupe(u8, idOf(inst, cnt)) catch return;
        labels[cnt] = a.dupe(u8, labelOf(inst, cnt)) catch return;
    }
    const efrom = a.alloc([]const u8, MAX_E) catch return;
    const eto = a.alloc([]const u8, MAX_E) catch return;
    var ecnt: usize = 0;
    while (ecnt < inst.edge_n) : (ecnt += 1) {
        efrom[ecnt] = a.dupe(u8, idOf(inst, inst.ef[ecnt])) catch return;
        eto[ecnt] = a.dupe(u8, idOf(inst, inst.et[ecnt])) catch return;
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
    reconcile(inst, ids[0..cnt], labels[0..cnt], pairs[0..k]);
    inst.last_seq = seq;
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
    const inst = current orelse return;
    inst.polling = !inst.polling;
    if (inst.polling) {
        inst.live_push = verve.pushSubscribe("viz", "VizGraphInteractive", "viz_apply_delta", inst.vid);
        if (inst.live_push) {
            requestResync(inst);
        } else {
            var args_buf: [48]u8 = undefined;
            const args = std.fmt.bufPrint(&args_buf, "{{\"on\":1,\"interval\":2000,\"vid\":{d}}}", .{inst.vid}) catch return;
            var out: [16]u8 = undefined;
            _ = verve.host("verveVizPoll", args, &out);
        }
    } else {
        if (inst.live_push) {
            verve.pushUnsubscribe("viz", "VizGraphInteractive", inst.vid);
            inst.live_push = false;
        } else {
            var args_buf: [32]u8 = undefined;
            const args = std.fmt.bufPrint(&args_buf, "{{\"on\":0,\"vid\":{d}}}", .{inst.vid}) catch return;
            var out: [16]u8 = undefined;
            _ = verve.host("verveVizPoll", args, &out);
        }
        inst.awaiting_resync = false;
    }
    if (verve.queryRef(@as([]const u8, "viz-live-btn"))) |h| verve.setRefClass(h, "live-on", inst.polling);
}

/// Demo imperative API: add a synthetic node connected to node 0.
export fn viz_add_node() void {
    const inst = current orelse return;
    if (inst.n == 0 or inst.n >= MAX_N) return;
    const mark = verve.chunkArenaMark();
    defer verve.chunkArenaReset(mark);
    const a = verve.chunkArena();
    inst.add_seq += 1;
    const ids = a.alloc([]const u8, inst.n + 1) catch return;
    const labels = a.alloc([]const u8, inst.n + 1) catch return;
    for (0..inst.n) |i| {
        ids[i] = a.dupe(u8, idOf(inst, i)) catch return;
        labels[i] = a.dupe(u8, labelOf(inst, i)) catch return;
    }
    const new_id = aprint(a, "n{d}", .{inst.add_seq}) orelse return;
    ids[inst.n] = new_id;
    labels[inst.n] = new_id;
    const edges = a.alloc([2]usize, inst.edge_n + 1) catch return;
    for (0..inst.edge_n) |e| edges[e] = .{ inst.ef[e], inst.et[e] };
    edges[inst.edge_n] = .{ 0, inst.n };
    reconcile(inst, ids, labels, edges);
}

/// Demo imperative API: remove the last node + its incident edges.
export fn viz_remove_node() void {
    const inst = current orelse return;
    if (inst.n <= 1) return;
    const mark = verve.chunkArenaMark();
    defer verve.chunkArenaReset(mark);
    const a = verve.chunkArena();
    const gone = inst.n - 1;
    const ids = a.alloc([]const u8, gone) catch return;
    const labels = a.alloc([]const u8, gone) catch return;
    for (0..gone) |i| {
        ids[i] = a.dupe(u8, idOf(inst, i)) catch return;
        labels[i] = a.dupe(u8, labelOf(inst, i)) catch return;
    }
    var edges: std.ArrayList([2]usize) = .empty;
    for (0..inst.edge_n) |e| {
        if (inst.ef[e] < gone and inst.et[e] < gone) edges.append(a, .{ inst.ef[e], inst.et[e] }) catch return;
    }
    reconcile(inst, ids, labels, edges.items);
}
