//! Sankey (flow) diagram: weighted directed links between nodes arranged in
//! columns, node height ∝ flow volume, links drawn as cubic ribbons whose
//! stroke width is the flow value. Pure layout (`layout`) + a chart-style
//! renderer (`sankey`) following the `verve.viz` conventions.

const std = @import("std");
const Node = @import("../node.zig").Node;
const Context = @import("../context.zig").Context;
const scene = @import("scene.zig");
const geom = @import("geom.zig");
const chart = @import("chart.zig");

pub const SankeyNode = struct { id: []const u8, label: []const u8 = "" };
pub const SankeyLink = struct { from: []const u8, to: []const u8, value: f64 };

pub const SankeyOpts = struct {
    width: f64 = 800,
    height: f64 = 500,
    node_width: f64 = 16,
    node_gap: f64 = 10,
    margin: f64 = 20,
    colors: []const []const u8 = &chart.palette,
    link_color: []const u8 = "#94a3b8",
    link_opacity: f64 = 0.4,
    label_size: f64 = 11,
    label_color: []const u8 = "#1e293b",
};

/// Index-resolved link (unknown-id links are dropped before layout).
pub const ResolvedLink = struct { from: usize, to: usize, value: f64 };

pub const NodeBox = struct { x: f64, y: f64, w: f64, h: f64 };

pub const Layout = struct {
    /// One box per node. Zero-flow nodes get a zero-height box.
    boxes: []NodeBox,
    /// Column index per node (longest path from a source).
    col: []usize,
    /// Per-link: y center at the source's right edge / target's left edge,
    /// and the stroke thickness. Zero/negative-value links get thickness 0.
    src_y: []f64,
    dst_y: []f64,
    thickness: []f64,
};

const LayoutCfg = struct {
    width: f64,
    height: f64,
    node_width: f64,
    node_gap: f64,
    margin: f64,
};

/// Pure sankey layout. Caller owns all slices (arena).
pub fn layout(a: std.mem.Allocator, n: usize, links: []const ResolvedLink, cfg: LayoutCfg) !Layout {
    const boxes = try a.alloc(NodeBox, n);
    const col = try a.alloc(usize, n);
    const src_y = try a.alloc(f64, links.len);
    const dst_y = try a.alloc(f64, links.len);
    const thickness = try a.alloc(f64, links.len);
    if (n == 0) return .{ .boxes = boxes, .col = col, .src_y = src_y, .dst_y = dst_y, .thickness = thickness };

    // 1. Columns: longest path from sources, bounded relaxation (cycles
    // tolerated, won't layer cleanly — same policy as the dag layout).
    @memset(col, 0);
    var pass: usize = 0;
    while (pass < n) : (pass += 1) {
        var changed = false;
        for (links) |l| {
            if (l.from >= n or l.to >= n or l.from == l.to) continue;
            if (col[l.to] < col[l.from] + 1) {
                col[l.to] = col[l.from] + 1;
                changed = true;
            }
        }
        if (!changed) break;
    }
    var max_col: usize = 0;
    for (col) |c| max_col = @max(max_col, c);

    // 2. Node flow value = max(in, out); column value scale so the heaviest
    // column fills the available height.
    const value = try a.alloc(f64, n);
    {
        const in_sum = try a.alloc(f64, n);
        const out_sum = try a.alloc(f64, n);
        @memset(in_sum, 0);
        @memset(out_sum, 0);
        for (links) |l| {
            if (l.from >= n or l.to >= n or l.value <= 0) continue;
            out_sum[l.from] += l.value;
            in_sum[l.to] += l.value;
        }
        for (0..n) |i| value[i] = @max(in_sum[i], out_sum[i]);
    }
    const avail_h = cfg.height - 2 * cfg.margin;
    var k = std.math.floatMax(f64);
    {
        const col_total = try a.alloc(f64, max_col + 1);
        const col_count = try a.alloc(usize, max_col + 1);
        @memset(col_total, 0);
        @memset(col_count, 0);
        for (0..n) |i| {
            col_total[col[i]] += value[i];
            col_count[col[i]] += 1;
        }
        for (0..max_col + 1) |c| {
            if (col_total[c] <= 0) continue;
            const gaps = @as(f64, @floatFromInt(col_count[c] -| 1)) * cfg.node_gap;
            k = @min(k, (avail_h - gaps) / col_total[c]);
        }
        if (k == std.math.floatMax(f64)) k = 1;
    }

    // 3. In-column order: index order, then 2 barycenter sweeps over neighbor
    // box centers (computed against the previous pass's y assignment).
    const order = try a.alloc(usize, n); // node → rank within its column
    const ys = try a.alloc(f64, n);
    assignY(n, col, max_col, value, k, cfg, order, ys, a) catch return error.OutOfMemory;
    var sweep: usize = 0;
    while (sweep < 2) : (sweep += 1) {
        const score = try a.alloc(f64, n);
        for (0..n) |i| {
            var sum: f64 = 0;
            var cnt: f64 = 0;
            for (links) |l| {
                if (l.value <= 0) continue;
                if (l.to == i and l.from < n) {
                    sum += ys[l.from] + value[l.from] * k / 2;
                    cnt += 1;
                }
                if (l.from == i and l.to < n) {
                    sum += ys[l.to] + value[l.to] * k / 2;
                    cnt += 1;
                }
            }
            score[i] = if (cnt > 0) sum / cnt else ys[i];
        }
        sortColumnsBy(n, col, max_col, score, order);
        reassignY(n, col, max_col, value, k, cfg, order, ys, a) catch return error.OutOfMemory;
    }

    // 4. Boxes.
    const avail_w = cfg.width - 2 * cfg.margin - cfg.node_width;
    const col_step = if (max_col == 0) 0 else avail_w / @as(f64, @floatFromInt(max_col));
    for (0..n) |i| {
        boxes[i] = .{
            .x = cfg.margin + @as(f64, @floatFromInt(col[i])) * col_step,
            .y = ys[i],
            .w = cfg.node_width,
            .h = value[i] * k,
        };
    }

    // 5. Per-node stacked link offsets: outgoing on the right edge (sorted by
    // target y), incoming on the left edge (sorted by source y).
    const out_off = try a.alloc(f64, n);
    const in_off = try a.alloc(f64, n);
    @memset(out_off, 0);
    @memset(in_off, 0);
    const link_idx = try a.alloc(usize, links.len);
    for (0..links.len) |i| link_idx[i] = i;
    // stable sort by (source node, target y) so stacking is deterministic
    std.sort.pdq(usize, link_idx, SortCtx{ .links = links, .ys = ys }, SortCtx.lessThan);
    for (link_idx) |li| {
        const l = links[li];
        if (l.from >= n or l.to >= n or l.value <= 0) {
            thickness[li] = 0;
            src_y[li] = 0;
            dst_y[li] = 0;
            continue;
        }
        const t = l.value * k;
        thickness[li] = t;
        src_y[li] = boxes[l.from].y + out_off[l.from] + t / 2;
        out_off[l.from] += t;
        dst_y[li] = boxes[l.to].y + in_off[l.to] + t / 2;
        in_off[l.to] += t;
    }

    return .{ .boxes = boxes, .col = col, .src_y = src_y, .dst_y = dst_y, .thickness = thickness };
}

const SortCtx = struct {
    links: []const ResolvedLink,
    ys: []const f64,

    fn lessThan(ctx: SortCtx, ai: usize, bi: usize) bool {
        const la = ctx.links[ai];
        const lb = ctx.links[bi];
        if (la.from != lb.from) return la.from < lb.from;
        const ya = if (la.to < ctx.ys.len) ctx.ys[la.to] else 0;
        const yb = if (lb.to < ctx.ys.len) ctx.ys[lb.to] else 0;
        if (ya != yb) return ya < yb;
        return ai < bi;
    }
};

fn assignY(n: usize, col: []const usize, max_col: usize, value: []const f64, k: f64, cfg: LayoutCfg, order: []usize, ys: []f64, a: std.mem.Allocator) !void {
    // initial rank = index order within each column
    const next = try a.alloc(usize, max_col + 1);
    @memset(next, 0);
    for (0..n) |i| {
        order[i] = next[col[i]];
        next[col[i]] += 1;
    }
    try reassignY(n, col, max_col, value, k, cfg, order, ys, a);
}

fn reassignY(n: usize, col: []const usize, max_col: usize, value: []const f64, k: f64, cfg: LayoutCfg, order: []const usize, ys: []f64, a: std.mem.Allocator) !void {
    // stack each column top-down in rank order
    const cursor = try a.alloc(f64, max_col + 1);
    for (cursor) |*c| c.* = cfg.margin;
    var rank: usize = 0;
    while (rank < n) : (rank += 1) {
        for (0..n) |i| {
            if (order[i] != rank) continue;
            ys[i] = cursor[col[i]];
            cursor[col[i]] += value[i] * k + cfg.node_gap;
        }
    }
}

/// Rank nodes within each column by (score, index) — a stable O(n²) rank,
/// fine at chart scale.
fn sortColumnsBy(n: usize, col: []const usize, max_col: usize, score: []const f64, order: []usize) void {
    for (0..max_col + 1) |c| {
        for (0..n) |i| {
            if (col[i] != c) continue;
            var rank: usize = 0;
            for (0..n) |j| {
                if (col[j] != c or j == i) continue;
                if (score[j] < score[i] or (score[j] == score[i] and j < i)) rank += 1;
            }
            order[i] = rank;
        }
    }
}

/// Render a sankey diagram. Unknown link endpoints and non-positive values
/// are dropped, matching graph-edge semantics.
pub fn sankey(ctx: *const Context, nodes: []const SankeyNode, links: []const SankeyLink, opts: SankeyOpts) *Node {
    const a = ctx.allocator;

    var resolved: std.ArrayList(ResolvedLink) = .empty;
    for (links) |l| {
        const fi = indexOf(nodes, l.from) orelse continue;
        const ti = indexOf(nodes, l.to) orelse continue;
        if (l.value <= 0) continue;
        resolved.append(a, .{ .from = fi, .to = ti, .value = l.value }) catch return errNode(ctx);
    }

    const lay = layout(a, nodes.len, resolved.items, .{
        .width = opts.width,
        .height = opts.height,
        .node_width = opts.node_width,
        .node_gap = opts.node_gap,
        .margin = opts.margin,
    }) catch return errNode(ctx);

    var shapes: std.ArrayList(scene.Shape) = .empty;

    // Links first so nodes draw on top. One cubic per link, stroked at the
    // flow thickness: M x0,y0 C mx,y0 mx,y1 x1,y1.
    for (resolved.items, 0..) |l, li| {
        if (lay.thickness[li] <= 0) continue;
        const x0 = lay.boxes[l.from].x + lay.boxes[l.from].w;
        const x1 = lay.boxes[l.to].x;
        const mx = (x0 + x1) / 2;
        const d = std.fmt.allocPrint(a, "M {d},{d} C {d},{d} {d},{d} {d},{d}", .{
            x0, lay.src_y[li], mx, lay.src_y[li], mx, lay.dst_y[li], x1, lay.dst_y[li],
        }) catch return errNode(ctx);
        shapes.append(a, .{ .path = .{ .d = d, .style = .{
            .stroke = opts.link_color,
            .stroke_width = lay.thickness[li],
            .opacity = opts.link_opacity,
            .fill = "none",
        } } }) catch return errNode(ctx);
    }

    for (nodes, 0..) |nd, i| {
        const b = lay.boxes[i];
        if (b.h <= 0) continue;
        shapes.append(a, .{ .rect = .{
            .x = b.x,
            .y = b.y,
            .w = b.w,
            .h = b.h,
            .style = .{ .fill = opts.colors[i % opts.colors.len] },
        } }) catch return errNode(ctx);
        const label = if (nd.label.len != 0) nd.label else nd.id;
        if (label.len != 0) {
            const on_left_half = b.x < opts.width / 2;
            shapes.append(a, .{ .text = .{
                .x = if (on_left_half) b.x + b.w + 4 else b.x - 4,
                .y = b.y + b.h / 2 + opts.label_size / 3,
                .content = label,
                .anchor = if (on_left_half) .start else .end,
                .font_size = opts.label_size,
                .style = .{ .fill = opts.label_color },
            } }) catch return errNode(ctx);
        }
    }

    return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = shapes.items });
}

fn indexOf(nodes: []const SankeyNode, id: []const u8) ?usize {
    for (nodes, 0..) |nd, i| if (std.mem.eql(u8, nd.id, id)) return i;
    return null;
}

fn errNode(ctx: *const Context) *Node {
    const node = ctx.el("svg");
    node.err = error.OutOfMemory;
    return node;
}

// ---- tests ---------------------------------------------------------------

const testing = std.testing;

const TEST_CFG = LayoutCfg{ .width = 400, .height = 300, .node_width = 16, .node_gap = 8, .margin = 20 };

test "sankey columns strictly increase along every link" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const links = [_]ResolvedLink{
        .{ .from = 0, .to = 2, .value = 5 },
        .{ .from = 1, .to = 2, .value = 3 },
        .{ .from = 2, .to = 3, .value = 8 },
        .{ .from = 0, .to = 3, .value = 2 }, // skip link
    };
    const lay = try layout(arena.allocator(), 4, &links, TEST_CFG);
    for (links) |l| try testing.expect(lay.col[l.to] > lay.col[l.from]);
}

test "sankey conserves flow: stacked link thickness equals node height on balanced nodes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // node 2 receives 5+3 and emits 8 → balanced
    const links = [_]ResolvedLink{
        .{ .from = 0, .to = 2, .value = 5 },
        .{ .from = 1, .to = 2, .value = 3 },
        .{ .from = 2, .to = 3, .value = 8 },
    };
    const lay = try layout(arena.allocator(), 4, &links, TEST_CFG);
    var in_sum: f64 = 0;
    var out_sum: f64 = 0;
    for (links, 0..) |l, i| {
        if (l.to == 2) in_sum += lay.thickness[i];
        if (l.from == 2) out_sum += lay.thickness[i];
    }
    try testing.expectApproxEqAbs(lay.boxes[2].h, in_sum, 1e-9);
    try testing.expectApproxEqAbs(lay.boxes[2].h, out_sum, 1e-9);
}

test "sankey boxes stay within the margin box" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const links = [_]ResolvedLink{
        .{ .from = 0, .to = 1, .value = 4 },
        .{ .from = 0, .to = 2, .value = 6 },
        .{ .from = 1, .to = 3, .value = 4 },
        .{ .from = 2, .to = 3, .value = 6 },
    };
    const lay = try layout(arena.allocator(), 4, &links, TEST_CFG);
    for (lay.boxes) |b| {
        try testing.expect(b.x >= TEST_CFG.margin - 1e-9);
        try testing.expect(b.x + b.w <= TEST_CFG.width - TEST_CFG.margin + 1e-9);
        try testing.expect(b.y >= TEST_CFG.margin - 1e-9);
        try testing.expect(b.y + b.h <= TEST_CFG.height - TEST_CFG.margin + 1e-9);
    }
}

test "sankey layout is deterministic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const links = [_]ResolvedLink{
        .{ .from = 0, .to = 1, .value = 4 },
        .{ .from = 0, .to = 2, .value = 6 },
    };
    const l1 = try layout(arena.allocator(), 3, &links, TEST_CFG);
    const l2 = try layout(arena.allocator(), 3, &links, TEST_CFG);
    for (l1.boxes, l2.boxes) |a_box, b_box| {
        try testing.expectEqual(a_box.x, b_box.x);
        try testing.expectEqual(a_box.y, b_box.y);
        try testing.expectEqual(a_box.h, b_box.h);
    }
}

test "sankey render emits one path per surviving link, drops bad links" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Renderer = @import("../renderer.zig").Renderer;
    const ctx = Context.init(&arena);
    const nodes = [_]SankeyNode{ .{ .id = "a" }, .{ .id = "b" }, .{ .id = "c" } };
    const links = [_]SankeyLink{
        .{ .from = "a", .to = "b", .value = 3 },
        .{ .from = "a", .to = "c", .value = 5 },
        .{ .from = "a", .to = "ghost", .value = 9 }, // unknown endpoint
        .{ .from = "b", .to = "c", .value = 0 }, // non-positive value
    };
    const tree = try sankey(&ctx, &nodes, &links, .{}).build();
    var buf: [16384]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try Renderer.render(&w, tree);
    const out = w.buffered();
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, out, i, "<path")) |at| {
        count += 1;
        i = at + 5;
    }
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expect(std.mem.indexOf(u8, out, "<rect") != null);
}
