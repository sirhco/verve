# Visualization (`verve.viz`)

Native, pure-Zig, declarative toolkit for **graphs, hierarchies, and charts**.
Layout and geometry are computed in Zig (server-side or in the wasm client);
output is an SVG `*Node` tree that serializes through the normal renderer. The
same call works for SSR (no-JS-friendly, SEO-clean) and as the SSR half of an
interactive island. No canvas, no d3, no cytoscape — zero dependencies.

Everything is reached through `verve.viz`. Implementation lives under
`src/core/viz/`.

```zig
const verve = @import("verve");
const viz = verve.viz;
```

Runnable demo: the `/viz` route in `src/app` renders an interactive force graph
plus three charts. `zig build run`, then open <http://127.0.0.1:8080/viz>.

## Table of contents

1. [Quick start](#quick-start)
2. [Charts](#charts) — bar, line, scatter
3. [Scales](#scales) — linear, band, log, time
4. [Axes](#axes)
5. [Graphs](#graphs) — tree, radial, force
6. [Low-level layouts](#low-level-layouts)
7. [The scene model](#the-scene-model) — build any custom SVG viz
8. [Geometry helpers](#geometry-helpers)
9. [Interactive islands](#interactive-islands) — the `VizGraph` pattern
10. [Performance & limits](#performance--limits)

---

## Quick start

A node-link graph and a bar chart, each one call, each returning a `*Node` you
drop straight into a page tree:

```zig
pub fn dashboard(ctx: *const verve.Context) !*verve.Node {
    // 1. A force-directed graph.
    const g = viz.Graph{
        .nodes = &.{
            .{ .id = "a", .label = "API" },
            .{ .id = "b", .label = "DB" },
            .{ .id = "c", .label = "Cache" },
        },
        .edges = &.{
            .{ .from = "a", .to = "b" },
            .{ .from = "a", .to = "c" },
        },
        .layout = .force, // .tree | .radial | .force
    };
    const graph_svg = viz.renderGraph(ctx, g, .{ .width = 600, .height = 400 });

    // 2. A bar chart.
    const bar_svg = viz.barChart(ctx, &.{
        .{ .label = "Mon", .value = 12 },
        .{ .label = "Tue", .value = 19 },
        .{ .label = "Wed", .value = 7 },
    }, .{ .width = 480, .height = 280 });

    return ctx.div().children(.{ graph_svg, bar_svg }).build();
}
```

`renderGraph` / `barChart` allocate from the request arena (`ctx.allocator`),
so there is nothing to free. Errors (only OOM) surface at the enclosing
`.build()`, exactly like every other node chain.

---

## Charts

Three entry points, each taking data + an options struct:

```zig
viz.barChart(ctx, data: []const viz.Datum,  opts: viz.ChartOpts) *Node
viz.stackedBarChart(ctx, categories: []const []const u8, series: []const viz.StackSeries, opts: viz.ChartOpts) *Node
viz.groupedBarChart(ctx, categories: []const []const u8, series: []const viz.StackSeries, opts: viz.ChartOpts) *Node
viz.lineChart(ctx, data: []const viz.Point, opts: viz.ChartOpts) *Node
viz.areaChart(ctx, data: []const viz.Point, opts: viz.ChartOpts) *Node
viz.scatterChart(ctx, data: []const viz.Point, opts: viz.ChartOpts) *Node
viz.pieChart(ctx, data: []const viz.Datum,  opts: viz.PieOpts)   *Node
viz.candlestickChart(ctx, data: []const viz.Candle, opts: viz.CandleOpts) *Node
viz.boxPlotChart(ctx, data: []const viz.BoxStats, opts: viz.ChartOpts) *Node
viz.heatmapChart(ctx, rows: []const []const u8, cols: []const []const u8, values: []const f64, opts: viz.HeatOpts) *Node
viz.radarChart(ctx, axes: []const []const u8, series: []const viz.StackSeries, opts: viz.ChartOpts) *Node
viz.violinChart(ctx, data: []const viz.ViolinSeries, opts: viz.ChartOpts) *Node
```

Data shapes:

```zig
pub const Datum = struct { label: []const u8, value: f64 }; // bar
pub const Point = struct { x: f64, y: f64 };                // line, scatter
```

Options (all fields optional — defaults shown):

```zig
pub const ChartOpts = struct {
    width: f64 = 600,
    height: f64 = 400,
    margin: Margin = .{ .top = 20, .right = 20, .bottom = 40, .left = 48 },
    color: []const u8 = "#4f46e5",      // series color
    axis_color: []const u8 = "#888",
    tick_count: usize = 5,              // approximate; rounded to nice values
};
```

### Bar chart

A band scale spreads categories across the x range; a linear y scale runs from
0 to the max value. Category labels are drawn under each band; a left axis with
nice ticks is drawn automatically.

```zig
const revenue = [_]viz.Datum{
    .{ .label = "Q1", .value = 120 },
    .{ .label = "Q2", .value = 185 },
    .{ .label = "Q3", .value = 97 },
    .{ .label = "Q4", .value = 240 },
};
const node = viz.barChart(ctx, &revenue, .{
    .width = 520,
    .height = 320,
    .color = "#1f6feb",
    .tick_count = 6,
});
```

### Stacked bar chart

Categories (x bands) with multiple series stacked bottom-to-top. Each
`StackSeries` carries a `values` slice (one per category) and an optional color
(defaults to the palette). A small legend (swatch + name) is drawn along the top.

```zig
const quarters = [_][]const u8{ "Q1", "Q2", "Q3", "Q4" };
const series = [_]viz.StackSeries{
    .{ .name = "web",  .values = &.{ 12, 19, 9, 22 }, .color = "#1f6feb" },
    .{ .name = "api",  .values = &.{ 8, 11, 14, 7 } },
    .{ .name = "jobs", .values = &.{ 4, 6, 5, 9 } },
};
const node = viz.stackedBarChart(ctx, &quarters, &series, .{ .width = 480, .height = 300 });
```

`viz.groupedBarChart` takes the same `(categories, series)` shape but places the
series **side-by-side** within each band instead of stacking them.

### Candlestick (OHLC)

Financial candles: a thin high–low wick with a thick open–close body per period,
colored up (`close ≥ open`) or down. The price axis spans `[min low, max high]`
(not zero-anchored).

```zig
const candles = [_]viz.Candle{
    .{ .label = "Mon", .open = 100, .high = 112, .low = 96, .close = 109 },
    .{ .label = "Tue", .open = 109, .high = 114, .low = 104, .close = 106 },
};
const node = viz.candlestickChart(ctx, &candles, .{ .width = 480, .height = 300 });
```

### Box plot

A Q1–Q3 box with a median line and min/max whiskers per category. Pass a
`BoxStats` five-number summary, or derive one from raw samples with
`viz.boxStats(alloc, samples)` (interpolated quartiles).

```zig
const boxes = [_]viz.BoxStats{
    .{ .label = "p50", .min = 8, .q1 = 14, .median = 19, .q3 = 26, .max = 34 },
    .{ .label = "p95", .min = 20, .q1 = 32, .median = 41, .q3 = 55, .max = 72 },
};
const node = viz.boxPlotChart(ctx, &boxes, .{ .width = 480, .height = 300 });
```

### Heatmap

A grid of cells colored by value, interpolated from `opts.low` to `opts.high`
(RGB). `values` is row-major (`values[r*cols + c]`); row labels run down the
left, column labels along the bottom. Set `show_values = true` to print numbers.

```zig
const rows = [_][]const u8{ "Mon", "Tue", "Wed" };
const cols = [_][]const u8{ "00h", "12h", "18h" };
const vals = [_]f64{ 2, 8, 5,  3, 12, 7,  4, 15, 9 }; // 3×3 row-major
const node = viz.heatmapChart(ctx, &rows, &cols, &vals, .{ .width = 420, .height = 280 });
```

### Radar (spider)

One axis per dimension radiating from the center, a closed polygon per series.
Reuses `StackSeries` (one value per axis); needs ≥3 axes. Grid rings + spokes use
`opts.axis_color`; series cycle the palette.

```zig
const axes = [_][]const u8{ "speed", "power", "range", "safety", "cost" };
const series = [_]viz.StackSeries{
    .{ .name = "EV",  .values = &.{ 8, 6, 5, 9, 4 }, .color = "#1f6feb" },
    .{ .name = "ICE", .values = &.{ 6, 8, 9, 6, 7 }, .color = "#f59e0b" },
};
const node = viz.radarChart(ctx, &axes, &series, .{ .width = 360, .height = 360 });
```

### Violin plot

A mirrored kernel-density shape per category (width ∝ sample density at each y)
with a median tick. Pass raw `samples`; densities use a Gaussian kernel. The y
axis spans `[min, max]` across all samples.

```zig
const data = [_]viz.ViolinSeries{
    .{ .label = "ctrl", .samples = &.{ 18, 20, 21, 22, 23, 24, 25, 27, 30 } },
    .{ .label = "new",  .samples = &.{ 8, 10, 11, 12, 13, 14, 16, 20 } },
};
const node = viz.violinChart(ctx, &data, .{ .width = 480, .height = 320 });
```

### Line chart

Points are drawn in array order as a single open polyline. Both axes are
generated from the data extent (x from min..max, y from 0..max).

```zig
const series = [_]viz.Point{
    .{ .x = 0, .y = 2 }, .{ .x = 1, .y = 5 }, .{ .x = 2, .y = 3 },
    .{ .x = 3, .y = 8 }, .{ .x = 4, .y = 6 }, .{ .x = 5, .y = 9 },
};
const node = viz.lineChart(ctx, &series, .{ .color = "#10b981" });
```

### Scatter plot

```zig
const cloud = [_]viz.Point{
    .{ .x = 1.2, .y = 3.4 }, .{ .x = 2.8, .y = 5.1 }, .{ .x = 4.0, .y = 2.2 },
    .{ .x = 4.6, .y = 7.7 }, .{ .x = 5.9, .y = 4.0 },
};
const node = viz.scatterChart(ctx, &cloud, .{ .color = "#f59e0b" });
```

### Area chart

Same shape as a line chart, but the region under the curve is filled to the
y=0 baseline (semi-transparent fill + a solid stroke on top).

```zig
const node = viz.areaChart(ctx, &series, .{ .color = "#06b6d4" });
```

### Pie / donut

Slice angle is proportional to each datum's value. Set `inner_ratio` for a
donut. Colors cycle through `opts.colors` (defaults to `viz.palette`).

```zig
const share = [_]viz.Datum{
    .{ .label = "core", .value = 40 },
    .{ .label = "client", .value = 25 },
    .{ .label = "server", .value = 20 },
    .{ .label = "desktop", .value = 15 },
};
const donut = viz.pieChart(ctx, &share, .{
    .width = 300, .height = 300,
    .inner_ratio = 0.55, // 0 = full pie
});
```

```zig
pub const PieOpts = struct {
    width: f64 = 360,
    height: f64 = 360,
    inner_ratio: f64 = 0,                    // 0 pie, 0.5 donut
    pad: f64 = 8,
    colors: []const []const u8 = &viz.palette,
    stroke: []const u8 = "#0e0e10",
};
```

### Multiple series

The built-in chart helpers draw one series. For overlays (two lines, a line
over bars, …) drop to the [scene model](#the-scene-model) and compose shapes
against shared scales — see the [custom sparkline](#example-custom-sparkline)
example below.

---

## Scales

Scales map data values (the *domain*) onto pixel positions (the *range*). They
are plain structs you can use standalone — for custom charts, tick grids,
positioning, or hit-testing.

### Linear

```zig
const x = viz.LinearScale{ .domain = .{ 0, 100 }, .range = .{ 0, 500 } };
x.map(50);     // => 250
x.invert(250); // => 50   (pixel back to data — useful for pointer hit-testing)
```

The range may be **inverted** — essential for SVG's top-down y-axis, where
larger data should sit higher (smaller y):

```zig
const y = viz.LinearScale{ .domain = .{ 0, 10 }, .range = .{ 300, 0 } };
y.map(0);  // => 300 (bottom)
y.map(10); // => 0   (top)
```

Nice ticks (caller owns the returned slice):

```zig
const ticks = try x.ticks(ctx.alloc(), 5); // ~5 ticks at 1/2/5×10ⁿ steps
for (ticks) |t| {
    // t.value — the domain value (e.g. 20)
    // t.pos   — its mapped pixel position (e.g. 100)
}
```

### Band (ordinal / categorical)

For bar charts and categorical axes: N categories across a range with
proportional inner padding.

```zig
const b = viz.BandScale{ .count = 4, .range = .{ 0, 400 }, .padding = 0.2 };
b.bandwidth(); // => 80   width of one bar
b.map(0);      // => 10   left edge of band 0 (offset by half the gap)
b.center(2);   // => 250  center of band 2 (where a label/point belongs)
```

### Log

Base-10 over a strictly positive domain — decades map to equal pixel spans:

```zig
const s = viz.LogScale{ .domain = .{ 1, 1000 }, .range = .{ 0, 300 } };
s.map(1);    // => 0
s.map(10);   // => 100
s.map(1000); // => 300
```

### Time

`viz.TimeScale` is a thin alias over `LinearScale` for f64 timestamps (epoch
ms, seconds, whatever you choose). Tick stepping is numeric, not calendar-aware
— format the labels yourself.

```zig
const t = viz.TimeScale{ .domain = .{ start_ms, end_ms }, .range = .{ 0, 720 } };
const px = t.map(event_ms);
```

---

## Axes

Turn a scale into the SVG shapes for an axis (domain line + tick marks + tick
labels). Returns `[]viz.Shape` for the [scene model](#the-scene-model); the
chart helpers use this internally.

```zig
const y = viz.LinearScale{ .domain = .{ 0, 100 }, .range = .{ 280, 20 } };
const shapes = try viz.Axis.build(ctx.alloc(), .{
    .orient = .left,    // .left | .bottom
    .scale  = y,
    .cross  = 48,       // x position of a left axis (y for a bottom axis)
    .tick_count = 5,
    .tick_len = 6,
    .color = "#888",
    .label_size = 10,
});
// embed `shapes` into your own Scene (see below)
```

---

## Graphs

Node-link diagrams. Hand a `Graph`; pick a layout; get an SVG tree. Each node is
rendered as a `<g>` carrying a stable `data-ref` (so an island can animate it).

```zig
pub const GraphNode = struct { id: []const u8, label: []const u8 = "" };
pub const GraphEdge = struct { from: []const u8, to: []const u8 };
pub const Layout = enum { tree, radial, force, dag };

pub const Graph = struct {
    nodes: []const GraphNode,
    edges: []const GraphEdge,
    layout: Layout = .force,
};
```

Options:

```zig
pub const GraphOpts = struct {
    width: f64 = 800,
    height: f64 = 600,
    margin: f64 = 40,
    node_radius: f64 = 14,
    node_color: []const u8 = "#4f46e5",
    edge_color: []const u8 = "#cbd5e1",
    label_color: []const u8 = "#1e293b",
    label_size: f64 = 11,
    ref_prefix: []const u8 = "viz-node", // data-ref="viz-node-<i>"
    force_iterations: usize = 300,
};
```

Whatever layout you choose, positions are uniformly scaled and centered to fit
inside the margin box, so the drawing always fills the viewport.

### Hierarchy (tidy tree)

Edges are read as an undirected graph; a spanning tree is rooted at the first
node. Leaves spread left-to-right; parents center over their children; depth
maps to y.

```zig
const org = viz.Graph{
    .nodes = &.{
        .{ .id = "ceo", .label = "CEO" },
        .{ .id = "eng", .label = "Eng" },
        .{ .id = "sales", .label = "Sales" },
        .{ .id = "be", .label = "Backend" },
        .{ .id = "fe", .label = "Frontend" },
    },
    .edges = &.{
        .{ .from = "ceo", .to = "eng" },
        .{ .from = "ceo", .to = "sales" },
        .{ .from = "eng", .to = "be" },
        .{ .from = "eng", .to = "fe" },
    },
    .layout = .tree,
};
const svg = viz.renderGraph(ctx, org, .{ .width = 700, .height = 420 });
```

### Radial

Depth maps to ring radius; leaves are spread evenly by angle; parents sit at the
mean angle of their children. `layout` is a field on the `Graph`, not on
`GraphOpts`:

```zig
const radial = viz.Graph{ .nodes = org.nodes, .edges = org.edges, .layout = .radial };
const svg = viz.renderGraph(ctx, radial, .{ .width = 600, .height = 600 });
```

### Force-directed (general networks)

A small physics sim — pairwise repulsion, spring attraction along edges, gentle
center gravity. The cytoscape/d3 default for arbitrary graphs. Initial positions
are deterministic (nodes seeded on a ring by index), so the same input always
produces the same layout.

```zig
const net = viz.Graph{
    .nodes = &.{
        .{ .id = "1", .label = "1" }, .{ .id = "2", .label = "2" },
        .{ .id = "3", .label = "3" }, .{ .id = "4", .label = "4" },
        .{ .id = "5", .label = "5" },
    },
    .edges = &.{
        .{ .from = "1", .to = "2" }, .{ .from = "2", .to = "3" },
        .{ .from = "3", .to = "4" }, .{ .from = "4", .to = "1" },
        .{ .from = "1", .to = "5" },
    },
    .layout = .force,
};
const svg = viz.renderGraph(ctx, net, .{
    .width = 640,
    .height = 480,
    .force_iterations = 400, // more = more settled (server-side cost)
    .node_color = "#1f6feb",
});
```

Unknown edge endpoints are skipped, not fatal — a stray `.to = "ghost"` simply
draws no edge.

### Layered DAG (directed)

For flowcharts, pipelines, and dependency graphs. Edges are read as **directed**
(`from → to`); longest-path layering assigns each node to a row one below its
deepest predecessor. A crossing-minimization pass (median/barycenter sweeps,
keeping the ordering with the fewest crossings) then reorders nodes within each
layer to untangle edges — set `crossing_iterations = 0` (on `GraphOpts` or the
low-level `dagLayout`) to skip it. Forward edges spanning more than one layer are
split into **virtual nodes** — one per intermediate layer — so crossing
minimization accounts for them at every boundary, the virtuals reserve routing
channels, and each long edge renders as a **polyline bending** through them
rather than cutting straight across. `renderGraph(..., .{ .layout = .dag })`
draws these automatically; `dagLayoutRouted` exposes the positions + per-edge
polylines for custom rendering. Cycles are tolerated (bounded relaxation) but
won't layer cleanly.

```zig
const pipeline = viz.Graph{
    .nodes = &.{
        .{ .id = "src", .label = "source" },
        .{ .id = "parse", .label = "parse" },
        .{ .id = "opt", .label = "optimize" },
        .{ .id = "emit", .label = "emit" },
    },
    .edges = &.{
        .{ .from = "src", .to = "parse" },
        .{ .from = "parse", .to = "opt" },
        .{ .from = "opt", .to = "emit" },
        .{ .from = "src", .to = "emit" }, // skip-edge: emit stays on the deepest layer
    },
    .layout = .dag,
};
const svg = viz.renderGraph(ctx, pipeline, .{ .width = 560, .height = 360 });
```

---

## Low-level layouts

Need positions for your own rendering (custom node shapes, edge routing,
canvas-bound export later)? Call the layout algorithms directly. They take a
node count + index-pair edges and return one `viz.Vec2` per node. Caller owns
the slice.

```zig
// edges as [from_index, to_index] pairs
const edges = [_][2]usize{ .{ 0, 1 }, .{ 0, 2 }, .{ 1, 3 } };

const tree_pos   = try viz.treeLayout(ctx.alloc(), 4, &edges, .{ .x_gap = 60, .y_gap = 80 });
const radial_pos = try viz.radialLayout(ctx.alloc(), 4, &edges, .{ .ring_gap = 90, .center = .{ .x = 300, .y = 300 } });
const dag_pos    = try viz.dagLayout(ctx.alloc(), 4, &edges, .{ .x_gap = 90, .y_gap = 90 });
const force_pos  = try viz.forceLayout(ctx.alloc(), 4, &edges, .{ .iterations = 300, .center = .{ .x = 320, .y = 240 } });

for (force_pos) |p| {
    // p.x, p.y — place your own shapes here
}
```

Force options worth tuning: `repulsion`, `spring`, `rest_length`, `gravity`,
`damping`, `dt`, `iterations`, `seed_radius`.

### Animating force frame-by-frame

For client-side animation, drive the sim a frame at a time via `ForceState`:

```zig
var state = try viz.forceInit(ctx.alloc(), n, edges, .{ .center = c });
defer state.deinit();
state.step();            // advance one frame
// read state.positions[i] each frame, write to the DOM
```

This is exactly what the [interactive island](#interactive-islands) section
builds on.

---

## The scene model

Every chart and graph is sugar over a small, resolution-independent **scene
model**. Reach for it to build *any* custom visualization — heatmaps, gauges,
small multiples, annotated diagrams.

A `Scene` is a viewport extent plus a flat list of `Shape`s. `viz.sceneToNode`
walks it once and emits the `<svg>` tree.

```zig
pub const Scene = struct { width: f64, height: f64, shapes: []const Shape };

pub const Shape = union(enum) {
    circle:   Circle,   // { cx, cy, r, style, ref }
    rect:     RectShape,// { x, y, w, h, rx, style, ref }
    line:     Line,     // { x1, y1, x2, y2, style, ref }
    polyline: Polyline, // { points: []const Vec2, closed, style, ref }
    path:     Path,     // { d: []const u8, style, ref }  (raw SVG path data)
    text:     Text,     // { x, y, content, anchor, font_size, style, ref }
    group:    Group,    // { transform, children: []const Shape, style, ref }
};

pub const Style = struct {
    fill: ?[]const u8 = null,
    stroke: ?[]const u8 = null,
    stroke_width: ?f64 = null,
    opacity: ?f64 = null,
    class: ?[]const u8 = null, // attach your own CSS class
};
```

Any shape's optional `ref` becomes `data-ref="<id>"` on the element — the hook
an island uses to mutate it later.

### Example: a heatmap

A grid of colored cells, built straight from scene rects:

```zig
pub fn heatmap(ctx: *const verve.Context, rows: usize, cols: usize, v: []const f64) !*verve.Node {
    const cell: f64 = 28;
    var shapes: std.ArrayList(viz.Shape) = .empty;
    for (0..rows) |r| {
        for (0..cols) |c| {
            const value = v[r * cols + c];               // 0..1
            const shade: u8 = @intFromFloat(value * 255);
            const fill = try std.fmt.allocPrint(ctx.alloc(), "rgb({d},{d},255)", .{ 255 - shade, 255 - shade });
            try shapes.append(ctx.alloc(), .{ .rect = .{
                .x = @as(f64, @floatFromInt(c)) * cell,
                .y = @as(f64, @floatFromInt(r)) * cell,
                .w = cell - 2,
                .h = cell - 2,
                .rx = 3,
                .style = .{ .fill = fill },
            } });
        }
    }
    return viz.sceneToNode(ctx, .{
        .width = @as(f64, @floatFromInt(cols)) * cell,
        .height = @as(f64, @floatFromInt(rows)) * cell,
        .shapes = shapes.items,
    });
}
```

### Example: custom sparkline (overlay two series)

Compose against shared scales to overlay shapes the built-in helpers don't:

```zig
pub fn sparkline(ctx: *const verve.Context, a: []const f64, b: []const f64) !*verve.Node {
    const w: f64 = 240;
    const h: f64 = 60;
    const x = viz.BandScale{ .count = a.len, .range = .{ 0, w }, .padding = 0 };
    const y = viz.LinearScale{ .domain = .{ 0, 10 }, .range = .{ h, 0 } };

    const pa = try ctx.alloc().alloc(viz.Vec2, a.len);
    const pb = try ctx.alloc().alloc(viz.Vec2, b.len);
    for (a, 0..) |val, i| pa[i] = .{ .x = x.center(i), .y = y.map(val) };
    for (b, 0..) |val, i| pb[i] = .{ .x = x.center(i), .y = y.map(val) };

    const shapes = [_]viz.Shape{
        .{ .polyline = .{ .points = pa, .style = .{ .stroke = "#1f6feb", .stroke_width = 2, .fill = "none" } } },
        .{ .polyline = .{ .points = pb, .style = .{ .stroke = "#f59e0b", .stroke_width = 2, .fill = "none" } } },
    };
    return viz.sceneToNode(ctx, .{ .width = w, .height = h, .shapes = &shapes });
}
```

### Example: groups and transforms

`group` nests children under a shared `transform` — the building block for
positioned, individually-animatable units (this is how graph nodes are built):

```zig
const node_shape = viz.Shape{ .group = .{
    .transform = "translate(120,80)",
    .ref = "widget-3",
    .children = &.{
        .{ .circle = .{ .cx = 0, .cy = 0, .r = 16, .style = .{ .fill = "#1f6feb" } } },
        .{ .text = .{ .x = 0, .y = 28, .content = "Node 3", .anchor = .middle, .font_size = 11 } },
    },
} };
```

A `closed` polyline emits a `<polygon>` instead of `<polyline>` — handy for
filled radar/area shapes.

---

## Geometry helpers

```zig
viz.Vec2  // { x, y } + .add .sub .scale .dot .len .dist .normalize
viz.Rect  // { x, y, w, h } + .contains(p) .center() .bounds(points)
viz.lerp(a, b, t)     // linear interpolation
viz.clamp(v, lo, hi)
```

```zig
const mid = viz.lerp(0, 100, 0.5);            // 50
const box = viz.Rect.bounds(force_pos);       // bounding box of a layout
const d = viz.Vec2.dist(a, b);                // distance between two nodes
```

---

## Interactive islands

Phase 1 keeps the client path free of new bridge primitives by a simple
contract: **the SVG element set is fixed at SSR time** (each node group carries
`data-ref="viz-node-<i>"`), and the client only **mutates existing element
attributes**. The bundled `VizGraph` island uses this to reveal nodes on
hydrate — scaling each from 0→1 in place — while the page is fully rendered with
JS off.

The pattern has three parts.

### 1. Declare the island + its props (`src/app/islands.zig`)

```zig
pub const VizGraph = struct {
    pub const props_schema: []const u8 = "{\"xs\":\"f64[]\",\"ys\":\"f64[]\"}";
    pub const Props = struct { xs: []const f64, ys: []const f64 };
};
```

### 2. Render server-side, encoding the exact positions (`components.zig`)

Compute positions **once** with `viz.graphPositions`, reuse them for both the
SSR tree (`viz.renderGraphWith`) and the encoded props — so the client reveal
lands precisely on the server layout:

```zig
const g = viz.Graph{ .nodes = &nodes, .edges = &edges, .layout = .force };
const opts = viz.GraphOpts{ .width = 640, .height = 420 };

const positions = try viz.graphPositions(ctx, g, opts);
const xs = try ctx.alloc().alloc(f64, positions.len);
const ys = try ctx.alloc().alloc(f64, positions.len);
for (positions, 0..) |p, i| { xs[i] = p.x; ys[i] = p.y; }

const props = try verve.encodeProps(ctx, islands.VizGraph.Props{ .xs = xs, .ys = ys });
const svg = viz.renderGraphWith(ctx, g, opts, positions);
const island = verve.island(ctx, .{ .name = "VizGraph", .props = props }, svg);
```

### 3. The client chunk (`src/client/islands/VizGraph.zig`)

Decode the props, then animate each node group's `transform` by ref over a few
`requestAnimationFrame`s. Positions are copied into static storage so they
survive across frames (the chunk arena recycles per dispatch):

```zig
const std = @import("std");
const verve = @import("verve");

// Mirrors app/islands.zig's VizGraph.Props (the serialize codec is positional,
// so field order + types are what must match — chunks can't import across the
// module boundary).
const Props = struct { xs: []const f64, ys: []const f64 };

const MAX_NODES = 256;
const TOTAL_FRAMES: u32 = 24;
var fx: [MAX_NODES]f64 = undefined;
var fy: [MAX_NODES]f64 = undefined;
var node_count: usize = 0;
var frame: u32 = 0;

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = root_id;
    if (props_len == 0) return;
    const bytes = @as([*]const u8, @ptrFromInt(@as(usize, props_ptr)))[0..props_len];

    const mark = verve.chunkArenaMark();
    defer verve.chunkArenaReset(mark);
    const props = verve.decodeProps(Props, bytes, verve.chunkArena()) catch return;

    node_count = @min(@min(props.xs.len, props.ys.len), MAX_NODES);
    for (0..node_count) |i| { fx[i] = props.xs[i]; fy[i] = props.ys[i]; }
    frame = 0;
    _ = verve.requestAnimationFrame(&tick);
}

fn tick() void {
    frame += 1;
    const t = @min(1.0, @as(f64, @floatFromInt(frame)) / @as(f64, @floatFromInt(TOTAL_FRAMES)));
    const inv = 1.0 - t;
    const s = 1.0 - inv * inv * inv; // easeOutCubic

    var ref_buf: [32]u8 = undefined;
    var tr_buf: [96]u8 = undefined;
    for (0..node_count) |i| {
        const id: []const u8 = std.fmt.bufPrint(&ref_buf, "viz-node-{d}", .{i}) catch continue;
        const handle = verve.queryRef(id) orelse continue;
        const transform = std.fmt.bufPrint(&tr_buf, "translate({d},{d}) scale({d})", .{ fx[i], fy[i], s }) catch continue;
        verve.setRefAttr(handle, "transform", transform);
    }
    if (frame < TOTAL_FRAMES) _ = verve.requestAnimationFrame(&tick);
}
```

Scaling about each group's origin (the node center) keeps edges — anchored at
those same centers — attached while the nodes pop in. The same
`queryRef` + `setRefAttr` + `requestAnimationFrame` loop drives any
attribute-only animation (pulsing a selection, recoloring on a server reply,
re-stepping a `ForceState` live).

### Full interaction (zoom / pan / drag / hover / select)

A second, batteries-included island wires real interaction. Build the graph with
`verve.viz.renderGraphInteractive` and wrap it in the framework
`VizGraphInteractive` island with props carrying positions, edges, and labels:

```zig
const g = verve.viz.Graph{ .nodes = &nodes, .edges = &edges, .layout = .force };
const opts = verve.viz.GraphOpts{ .width = 640, .height = 420 };

const positions = try verve.viz.graphPositions(ctx, g, opts);
const xs = try ctx.alloc().alloc(f64, positions.len);
const ys = try ctx.alloc().alloc(f64, positions.len);
const labels = try ctx.alloc().alloc([]const u8, nodes.len);
for (positions, 0..) |p, i| { xs[i] = p.x; ys[i] = p.y; }
for (nodes, 0..) |nd, i| labels[i] = nd.label;

// Edge endpoints as node indices (ef → et).
var ef: std.ArrayList(u32) = .empty;
var et: std.ArrayList(u32) = .empty;
for (edges) |e| {
    var fi: u32 = 0; var ti: u32 = 0;
    for (nodes, 0..) |nd, i| {
        if (std.mem.eql(u8, nd.id, e.from)) fi = @intCast(i);
        if (std.mem.eql(u8, nd.id, e.to)) ti = @intCast(i);
    }
    try ef.append(ctx.alloc(), fi);
    try et.append(ctx.alloc(), ti);
}

const props = try verve.encodeProps(ctx, islands.VizGraphInteractive.Props{
    .xs = xs, .ys = ys, .ef = ef.items, .et = et.items, .labels = labels,
});
const svg = verve.viz.renderGraphInteractive(ctx, g, opts);
const island = verve.island(ctx, .{ .name = "VizGraphInteractive", .props = props }, svg);
```

Declare the island (`src/app/islands.zig`):

```zig
pub const VizGraphInteractive = struct {
    pub const props_schema: []const u8 = "{\"xs\":\"f64[]\",\"ys\":\"f64[]\",\"ef\":\"u32[]\",\"et\":\"u32[]\",\"labels\":\"string[]\"}";
    pub const Props = struct {
        xs: []const f64, ys: []const f64,
        ef: []const u32, et: []const u32,
        labels: []const []const u8,
    };
};
```

Add a little CSS (the island toggles a `selected` class on the clicked node;
`touch-action:none` lets wheel/pointer gestures own the svg):

```css
.viz-node{cursor:grab}
.viz-node.selected circle{stroke:#fff;stroke-width:3}
svg{touch-action:none}
```

**What you get:** wheel zooms toward the cursor (one `viz-root` group transform),
background drag pans, node drag repositions a node and its incident edges follow,
hover shows a labeled tooltip, click toggles a highlight. With JS off the graph
still renders fully — interaction is pure enhancement.

**How it works:** SSR stamps `viz-svg`, a `viz-root` zoom/pan group holding two
keyed containers (`viz-edges`, `viz-nodes`), `viz-edge-<from>|<to>` lines and
`viz-node-<id>` groups (keyed by stable **id**, with a `data-node` id), and a
hidden tooltip. The client chunk mutates attributes/classes via `setRefAttr` /
`setRefClass`. The bridge adds six delegated events — `wheel`, `pointerdown`,
`pointermove`, `pointerup`, `pointerover`, `pointerout` — plus `eventDeltaY()` /
`eventButton()` accessors and `Node.onWheel` / `onPointer*` stamps, reusable by
any island.

### Live-data streaming (pull / polling)

The graph can be **data-driven**: poll a server-fn for a full `{nodes, edges}`
snapshot on an interval and reconcile to it. A `vizGraph` server-fn (`api.zig`)
returns the current graph; the island registers a response handler
(`registerResponseHandler("vizGraph", &onGraph)`), polls via `serverFnPost` on a
`setInterval` behind a "● live" toggle, parses the snapshot (`parseJson` →
`mapSnapshotEdges` id→slot), and calls the same `reconcile`. **No new bridge
primitives** — it reuses the IPC reply path + the reconciler. Zoom/pan + selection
persist across every tick.

Limitations: **polling** (interval-bounded, not push); a **full snapshot** per
tick (no deltas); single instance; one shared server-side demo graph. WebSocket
push is the next phase.

### Runtime mutation (add / remove nodes)

The graph can change at runtime. The island exposes an imperative API
(`viz_add_node` / `viz_remove_node` exports in the demo; a `reconcile` core that
takes a new node/edge set) that:

1. diffs the new graph vs current (keyed by node id / `from|to` edge key);
2. keeps survivors' positions, seeds new nodes near the centroid, and relaxes
   with a few force steps (existing nodes barely move);
3. drives the framework's **keyed list reconciler** (`listDiff`) on the
   `viz-nodes` / `viz-edges` containers to create / move / remove SVG elements.

**Zoom/pan and selection are never touched during reconcile → preserved.** The
one framework-core enabler: `create_keyed_child` parses fragments in the **SVG
namespace** (so created `<g>`/`<line>` render as SVG, not HTML) — reusable by any
SVG keyed list, not just viz.

**Limitations (this phase):** one interactive graph per page (module-static
state); **force layout only** (tree/radial/dag mutation deferred); a full-snapshot
diff per update; drag/pan bounded to pointer-over-svg; the client→svg mapping
assumes the svg isn't CSS-scaled. See [Not yet](#not-yet-phase-2).

---

## Performance & limits

- **Render path is SVG-as-DOM.** Crisp, accessible, trivially styleable with
  CSS, and free hit-testing via the DOM. The practical ceiling is ~low-thousands
  of elements before per-node attribute mutation cost bites.
- **Layout is O(V+E)** for tree/radial, **O(V²) per iteration** for force.
  `force_iterations` is the main server-side cost knob.
- **Static by default.** `renderGraph` / `*Chart` produce a complete drawing
  with no JavaScript — ideal for SSR, email, print, and SEO. Add an island only
  where you want motion or interaction.

### Not yet (phase 2+)

- **WebSocket push + expand/collapse** — runtime add/remove and pull-based
  live-data streaming ship (above); true push (WS/SSE), granular wire deltas, and
  subtree expand/collapse are the next layer.
- **Mutation for non-force layouts** — runtime mutation is force-only so far.
- **Pointer capture** — drag/pan are bounded to pointer-over-svg; dragging past
  the svg edge ends the gesture. Document-level capture is a later refinement.
- **Orthogonal / curved edge routing** — routed DAG edges bend through virtual
  nodes as straight polyline segments; smooth splines or orthogonal routing
  aren't done.
- **Canvas draw-command path** for thousands-of-elements scale and smooth
  high-frequency animation.
- **Sankey / treemap / chord** chart types — buildable today from the
  [scene model](#the-scene-model); first-class helpers may follow.
