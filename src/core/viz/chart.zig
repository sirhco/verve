//! Declarative statistical charts. Each entry point takes data + options and
//! returns an SVG `*Node` tree (via the scene model) ready to drop into a
//! route. Built on `scale`, `axis`, and `scene`. Allocation uses the request
//! arena (`ctx.allocator`), so there is nothing to free.

const std = @import("std");
const Node = @import("../node.zig").Node;
const Context = @import("../context.zig").Context;
const scale = @import("scale.zig");
const axis = @import("axis.zig");
const scene = @import("scene.zig");
const geom = @import("geom.zig");

const Vec2 = geom.Vec2;

pub const Datum = struct { label: []const u8, value: f64 };
pub const Point = struct { x: f64, y: f64 };

pub const Margin = struct {
    top: f64 = 20,
    right: f64 = 20,
    bottom: f64 = 40,
    left: f64 = 48,
};

pub const Opts = struct {
    width: f64 = 600,
    height: f64 = 400,
    margin: Margin = .{},
    color: []const u8 = "#4f46e5",
    axis_color: []const u8 = "#888",
    tick_count: usize = 5,
};

const Plot = struct {
    x0: f64, // left edge of plot area (abs)
    x1: f64, // right edge
    y0: f64, // bottom edge (abs, larger y)
    y1: f64, // top edge (abs, smaller y)

    fn of(opts: Opts) Plot {
        return .{
            .x0 = opts.margin.left,
            .x1 = opts.width - opts.margin.right,
            .y0 = opts.height - opts.margin.bottom,
            .y1 = opts.margin.top,
        };
    }
};

fn maxValue(values: []const f64) f64 {
    var m: f64 = 0;
    for (values) |v| m = @max(m, v);
    return if (m == 0) 1 else m;
}

/// Vertical bar chart over labeled categories.
pub fn bar(ctx: *const Context, data: []const Datum, opts: Opts) *Node {
    const a = ctx.allocator;
    const plot = Plot.of(opts);
    var shapes: std.ArrayList(scene.Shape) = .empty;

    var top: f64 = 0;
    for (data) |d| top = @max(top, d.value);
    if (top == 0) top = 1;

    const y = scale.Linear{ .domain = .{ 0, top }, .range = .{ plot.y0, plot.y1 } };
    const band = scale.Band{ .count = data.len, .range = .{ plot.x0, plot.x1 }, .padding = 0.2 };

    appendAxis(&shapes, a, .{ .orient = .left, .scale = y, .cross = plot.x0, .tick_count = opts.tick_count, .color = opts.axis_color });

    for (data, 0..) |d, i| {
        const bx = band.map(i);
        const by = y.map(d.value);
        shapes.append(a, .{ .rect = .{
            .x = bx,
            .y = by,
            .w = band.bandwidth(),
            .h = plot.y0 - by,
            .style = .{ .fill = opts.color },
        } }) catch return errNode(ctx);
        // Category label under the band.
        shapes.append(a, .{ .text = .{
            .x = band.center(i),
            .y = plot.y0 + 16,
            .content = d.label,
            .anchor = .middle,
            .font_size = 10,
            .style = .{ .fill = opts.axis_color },
        } }) catch return errNode(ctx);
    }

    return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = shapes.items });
}

/// One series in a stacked bar chart. `values[c]` is this series' contribution
/// to category `c` (so `values.len` should equal `categories.len`). `color`
/// defaults to the palette entry for the series' index.
pub const StackSeries = struct {
    name: []const u8,
    values: []const f64,
    color: ?[]const u8 = null,
};

/// Stacked bar chart: each category band stacks the series bottom-to-top. A
/// small legend (swatch + name) is drawn along the top of the plot.
pub fn stackedBar(ctx: *const Context, categories: []const []const u8, series: []const StackSeries, opts: Opts) *Node {
    const a = ctx.allocator;
    const plot = Plot.of(opts);
    var shapes: std.ArrayList(scene.Shape) = .empty;

    // Tallest stack sets the y domain.
    var top: f64 = 0;
    for (categories, 0..) |_, c| {
        var sum: f64 = 0;
        for (series) |s| if (c < s.values.len) {
            sum += s.values[c];
        };
        top = @max(top, sum);
    }
    if (top == 0) top = 1;

    const y = scale.Linear{ .domain = .{ 0, top }, .range = .{ plot.y0, plot.y1 } };
    const band = scale.Band{ .count = categories.len, .range = .{ plot.x0, plot.x1 }, .padding = 0.2 };

    appendAxis(&shapes, a, .{ .orient = .left, .scale = y, .cross = plot.x0, .tick_count = opts.tick_count, .color = opts.axis_color });

    for (categories, 0..) |label, c| {
        const bx = band.map(c);
        var cum: f64 = 0;
        for (series, 0..) |s, si| {
            const v = if (c < s.values.len) s.values[c] else 0;
            if (v <= 0) continue;
            const y_top = y.map(cum + v);
            const y_bot = y.map(cum);
            shapes.append(a, .{ .rect = .{
                .x = bx,
                .y = y_top,
                .w = band.bandwidth(),
                .h = y_bot - y_top,
                .style = .{ .fill = s.color orelse palette[si % palette.len] },
            } }) catch return errNode(ctx);
            cum += v;
        }
        shapes.append(a, .{ .text = .{
            .x = band.center(c),
            .y = plot.y0 + 16,
            .content = label,
            .anchor = .middle,
            .font_size = 10,
            .style = .{ .fill = opts.axis_color },
        } }) catch return errNode(ctx);
    }

    appendLegend(&shapes, a, series, opts, plot) catch return errNode(ctx);
    return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = shapes.items });
}

/// Grouped (clustered) bar chart: within each category band the series sit
/// side-by-side rather than stacked. Shares `StackSeries` + the legend.
pub fn groupedBar(ctx: *const Context, categories: []const []const u8, series: []const StackSeries, opts: Opts) *Node {
    const a = ctx.allocator;
    const plot = Plot.of(opts);
    var shapes: std.ArrayList(scene.Shape) = .empty;

    // Tallest single bar sets the y domain.
    var top: f64 = 0;
    for (series) |s| for (s.values) |v| {
        top = @max(top, v);
    };
    if (top == 0) top = 1;

    const y = scale.Linear{ .domain = .{ 0, top }, .range = .{ plot.y0, plot.y1 } };
    const band = scale.Band{ .count = categories.len, .range = .{ plot.x0, plot.x1 }, .padding = 0.2 };
    appendAxis(&shapes, a, .{ .orient = .left, .scale = y, .cross = plot.x0, .tick_count = opts.tick_count, .color = opts.axis_color });

    const ns = series.len;
    for (categories, 0..) |label, c| {
        const bw = band.bandwidth();
        const sub = if (ns == 0) bw else bw / @as(f64, @floatFromInt(ns));
        const bx = band.map(c);
        for (series, 0..) |s, si| {
            const v = if (c < s.values.len) s.values[c] else 0;
            if (v <= 0) continue;
            const yv = y.map(v);
            shapes.append(a, .{
                .rect = .{
                    .x = bx + @as(f64, @floatFromInt(si)) * sub,
                    .y = yv,
                    .w = sub * 0.9, // small gap between clustered bars
                    .h = plot.y0 - yv,
                    .style = .{ .fill = s.color orelse palette[si % palette.len] },
                },
            }) catch return errNode(ctx);
        }
        shapes.append(a, .{ .text = .{
            .x = band.center(c),
            .y = plot.y0 + 16,
            .content = label,
            .anchor = .middle,
            .font_size = 10,
            .style = .{ .fill = opts.axis_color },
        } }) catch return errNode(ctx);
    }

    appendLegend(&shapes, a, series, opts, plot) catch return errNode(ctx);
    return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = shapes.items });
}

/// Swatch + name legend along the top of the plot, shared by the multi-series
/// charts. Text width is approximated (~6px/char) for spacing.
fn appendLegend(shapes: *std.ArrayList(scene.Shape), a: std.mem.Allocator, series: []const StackSeries, opts: Opts, plot: Plot) !void {
    var lx: f64 = plot.x0;
    const ly = opts.margin.top - 12;
    for (series, 0..) |s, si| {
        const color = s.color orelse palette[si % palette.len];
        try shapes.append(a, .{ .rect = .{ .x = lx, .y = ly, .w = 10, .h = 10, .rx = 2, .style = .{ .fill = color } } });
        try shapes.append(a, .{ .text = .{ .x = lx + 14, .y = ly + 9, .content = s.name, .font_size = 10, .style = .{ .fill = opts.axis_color } } });
        lx += 24 + @as(f64, @floatFromInt(s.name.len)) * 6.0 + 16;
    }
}

/// One OHLC bar for a candlestick chart.
pub const Candle = struct {
    label: []const u8,
    open: f64,
    high: f64,
    low: f64,
    close: f64,
};

pub const CandleOpts = struct {
    width: f64 = 600,
    height: f64 = 400,
    margin: Margin = .{},
    up_color: []const u8 = "#10b981", // close ≥ open
    down_color: []const u8 = "#ef4444", // close < open
    axis_color: []const u8 = "#888",
    tick_count: usize = 5,
};

/// Candlestick (OHLC) chart: a thin high–low wick with a thick open–close body
/// per period, colored up/down by direction. The price axis spans [min low,
/// max high] (not anchored at zero).
pub fn candlestick(ctx: *const Context, data: []const Candle, opts: CandleOpts) *Node {
    const a = ctx.allocator;
    const plot = Plot{
        .x0 = opts.margin.left,
        .x1 = opts.width - opts.margin.right,
        .y0 = opts.height - opts.margin.bottom,
        .y1 = opts.margin.top,
    };
    var shapes: std.ArrayList(scene.Shape) = .empty;
    if (data.len == 0) return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = shapes.items });

    var lo = data[0].low;
    var hi = data[0].high;
    for (data) |d| {
        lo = @min(lo, d.low);
        hi = @max(hi, d.high);
    }
    if (hi == lo) hi = lo + 1;

    const y = scale.Linear{ .domain = .{ lo, hi }, .range = .{ plot.y0, plot.y1 } };
    const band = scale.Band{ .count = data.len, .range = .{ plot.x0, plot.x1 }, .padding = 0.2 };
    appendAxis(&shapes, a, .{ .orient = .left, .scale = y, .cross = plot.x0, .tick_count = opts.tick_count, .color = opts.axis_color });

    for (data, 0..) |d, i| {
        const cx = band.center(i);
        const bw = band.bandwidth();
        const up = d.close >= d.open;
        const color = if (up) opts.up_color else opts.down_color;
        // Wick: high → low.
        shapes.append(a, .{ .line = .{
            .x1 = cx,
            .y1 = y.map(d.high),
            .x2 = cx,
            .y2 = y.map(d.low),
            .style = .{ .stroke = color, .stroke_width = 1.5 },
        } }) catch return errNode(ctx);
        // Body: open ↔ close (min 1px tall so dojis still show).
        const y_hi = y.map(@max(d.open, d.close));
        const y_lo = y.map(@min(d.open, d.close));
        shapes.append(a, .{ .rect = .{
            .x = cx - bw * 0.3,
            .y = y_hi,
            .w = bw * 0.6,
            .h = @max(y_lo - y_hi, 1),
            .style = .{ .fill = color },
        } }) catch return errNode(ctx);
        shapes.append(a, .{ .text = .{
            .x = cx,
            .y = plot.y0 + 16,
            .content = d.label,
            .anchor = .middle,
            .font_size = 10,
            .style = .{ .fill = opts.axis_color },
        } }) catch return errNode(ctx);
    }

    return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = shapes.items });
}

/// Five-number summary for one box in a box plot.
pub const BoxStats = struct {
    label: []const u8,
    min: f64,
    q1: f64,
    median: f64,
    q3: f64,
    max: f64,
};

/// Compute a `BoxStats` (sans label) from raw samples via linear-interpolation
/// quartiles. Sorts a copy on `alloc`; caller fills `.label`. Empty input → all
/// zeros.
pub fn boxStats(alloc: std.mem.Allocator, samples: []const f64) !BoxStats {
    if (samples.len == 0) return .{ .label = "", .min = 0, .q1 = 0, .median = 0, .q3 = 0, .max = 0 };
    const sorted = try alloc.dupe(f64, samples);
    defer alloc.free(sorted);
    std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
    const quantile = struct {
        fn at(s: []const f64, q: f64) f64 {
            const h = q * @as(f64, @floatFromInt(s.len - 1));
            const lo: usize = @intFromFloat(@floor(h));
            const hi: usize = @intFromFloat(@ceil(h));
            const frac = h - @floor(h);
            return s[lo] + (s[hi] - s[lo]) * frac;
        }
    }.at;
    return .{
        .label = "",
        .min = sorted[0],
        .q1 = quantile(sorted, 0.25),
        .median = quantile(sorted, 0.5),
        .q3 = quantile(sorted, 0.75),
        .max = sorted[sorted.len - 1],
    };
}

/// Box-and-whisker plot: a Q1–Q3 box with a median line and min/max whiskers per
/// category. The y axis spans [min of mins, max of maxes].
pub fn boxPlot(ctx: *const Context, data: []const BoxStats, opts: Opts) *Node {
    const a = ctx.allocator;
    const plot = Plot.of(opts);
    var shapes: std.ArrayList(scene.Shape) = .empty;
    if (data.len == 0) return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = shapes.items });

    var lo = data[0].min;
    var hi = data[0].max;
    for (data) |d| {
        lo = @min(lo, d.min);
        hi = @max(hi, d.max);
    }
    if (hi == lo) hi = lo + 1;

    const y = scale.Linear{ .domain = .{ lo, hi }, .range = .{ plot.y0, plot.y1 } };
    const band = scale.Band{ .count = data.len, .range = .{ plot.x0, plot.x1 }, .padding = 0.2 };
    appendAxis(&shapes, a, .{ .orient = .left, .scale = y, .cross = plot.x0, .tick_count = opts.tick_count, .color = opts.axis_color });

    const line_style = scene.Style{ .stroke = opts.color, .stroke_width = 1.5 };
    for (data, 0..) |d, i| {
        const cx = band.center(i);
        const bw = band.bandwidth();
        const half = bw * 0.3;
        // Whiskers: q3→max (top) and q1→min (bottom), with caps.
        shapes.append(a, .{ .line = .{ .x1 = cx, .y1 = y.map(d.q3), .x2 = cx, .y2 = y.map(d.max), .style = line_style } }) catch return errNode(ctx);
        shapes.append(a, .{ .line = .{ .x1 = cx, .y1 = y.map(d.q1), .x2 = cx, .y2 = y.map(d.min), .style = line_style } }) catch return errNode(ctx);
        shapes.append(a, .{ .line = .{ .x1 = cx - half * 0.6, .y1 = y.map(d.max), .x2 = cx + half * 0.6, .y2 = y.map(d.max), .style = line_style } }) catch return errNode(ctx);
        shapes.append(a, .{ .line = .{ .x1 = cx - half * 0.6, .y1 = y.map(d.min), .x2 = cx + half * 0.6, .y2 = y.map(d.min), .style = line_style } }) catch return errNode(ctx);
        // Box: q1→q3, translucent fill + outline.
        const y_q3 = y.map(d.q3);
        shapes.append(a, .{ .rect = .{
            .x = cx - half,
            .y = y_q3,
            .w = half * 2,
            .h = y.map(d.q1) - y_q3,
            .style = .{ .fill = opts.color, .opacity = 0.3, .stroke = opts.color, .stroke_width = 1.5 },
        } }) catch return errNode(ctx);
        // Median line across the box.
        shapes.append(a, .{ .line = .{ .x1 = cx - half, .y1 = y.map(d.median), .x2 = cx + half, .y2 = y.map(d.median), .style = .{ .stroke = opts.color, .stroke_width = 2 } } }) catch return errNode(ctx);
        shapes.append(a, .{ .text = .{ .x = cx, .y = plot.y0 + 16, .content = d.label, .anchor = .middle, .font_size = 10, .style = .{ .fill = opts.axis_color } } }) catch return errNode(ctx);
    }

    return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = shapes.items });
}

pub const Rgb = struct { r: u8, g: u8, b: u8 };

pub const HeatOpts = struct {
    width: f64 = 480,
    height: f64 = 360,
    margin: Margin = .{ .top = 20, .right = 20, .bottom = 36, .left = 72 },
    low: Rgb = .{ .r = 15, .g = 23, .b = 42 }, // cold
    high: Rgb = .{ .r = 31, .g = 111, .b = 235 }, // hot
    axis_color: []const u8 = "#8b949e",
    cell_gap: f64 = 2,
    show_values: bool = false,
};

fn lerpU8(lo: u8, hi: u8, t: f64) u8 {
    const v = @as(f64, @floatFromInt(lo)) + (@as(f64, @floatFromInt(hi)) - @as(f64, @floatFromInt(lo))) * t;
    return @intFromFloat(@round(geom.clamp(v, 0, 255)));
}

/// Heatmap: a grid of cells colored by value, interpolated from `opts.low` to
/// `opts.high`. `values` is row-major (`values[r*cols + c]`). Row labels run
/// down the left, column labels along the bottom.
pub fn heatmap(ctx: *const Context, row_labels: []const []const u8, col_labels: []const []const u8, values: []const f64, opts: HeatOpts) *Node {
    const a = ctx.allocator;
    const rows = row_labels.len;
    const cols = col_labels.len;
    var shapes: std.ArrayList(scene.Shape) = .empty;
    if (rows == 0 or cols == 0) return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = shapes.items });

    var lo = values[0];
    var hi = values[0];
    for (values) |v| {
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    const span = if (hi == lo) 1 else hi - lo;

    const x0 = opts.margin.left;
    const y0 = opts.margin.top;
    const cw = (opts.width - opts.margin.left - opts.margin.right) / @as(f64, @floatFromInt(cols));
    const ch = (opts.height - opts.margin.top - opts.margin.bottom) / @as(f64, @floatFromInt(rows));

    for (0..rows) |r| {
        for (0..cols) |c| {
            const idx = r * cols + c;
            const v = if (idx < values.len) values[idx] else lo;
            const t = (v - lo) / span;
            const fill = std.fmt.allocPrint(a, "rgb({d},{d},{d})", .{
                lerpU8(opts.low.r, opts.high.r, t),
                lerpU8(opts.low.g, opts.high.g, t),
                lerpU8(opts.low.b, opts.high.b, t),
            }) catch return errNode(ctx);
            const cx = x0 + @as(f64, @floatFromInt(c)) * cw;
            const cy = y0 + @as(f64, @floatFromInt(r)) * ch;
            shapes.append(a, .{ .rect = .{
                .x = cx,
                .y = cy,
                .w = cw - opts.cell_gap,
                .h = ch - opts.cell_gap,
                .rx = 2,
                .style = .{ .fill = fill },
            } }) catch return errNode(ctx);
            if (opts.show_values) {
                shapes.append(a, .{ .text = .{
                    .x = cx + (cw - opts.cell_gap) / 2,
                    .y = cy + (ch - opts.cell_gap) / 2 + 3,
                    .content = std.fmt.allocPrint(a, "{d}", .{v}) catch return errNode(ctx),
                    .anchor = .middle,
                    .font_size = 9,
                    .style = .{ .fill = "#fff" },
                } }) catch return errNode(ctx);
            }
        }
    }
    // Column labels (bottom) + row labels (left).
    for (col_labels, 0..) |label, c| {
        shapes.append(a, .{ .text = .{
            .x = x0 + (@as(f64, @floatFromInt(c)) + 0.5) * cw,
            .y = opts.height - opts.margin.bottom + 16,
            .content = label,
            .anchor = .middle,
            .font_size = 10,
            .style = .{ .fill = opts.axis_color },
        } }) catch return errNode(ctx);
    }
    for (row_labels, 0..) |label, r| {
        shapes.append(a, .{ .text = .{
            .x = x0 - 8,
            .y = y0 + (@as(f64, @floatFromInt(r)) + 0.5) * ch + 3,
            .content = label,
            .anchor = .end,
            .font_size = 10,
            .style = .{ .fill = opts.axis_color },
        } }) catch return errNode(ctx);
    }

    return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = shapes.items });
}

/// Radar (spider) chart: one axis per dimension radiating from the center, a
/// closed polygon per series. Reuses `StackSeries` (one value per axis). Needs
/// at least 3 axes. Grid rings + spokes use `opts.axis_color`; series cycle the
/// palette.
pub fn radar(ctx: *const Context, axes: []const []const u8, series: []const StackSeries, opts: Opts) *Node {
    const a = ctx.allocator;
    const n = axes.len;
    var shapes: std.ArrayList(scene.Shape) = .empty;
    if (n < 3) return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = shapes.items });

    const cx = opts.width / 2.0;
    const cy = opts.height / 2.0;
    const radius = @min(opts.width, opts.height) / 2.0 - 48;

    var max: f64 = 0;
    for (series) |s| for (s.values) |v| {
        max = @max(max, v);
    };
    if (max == 0) max = 1;

    const ang = struct {
        fn at(i: usize, total: usize) f64 {
            return -std.math.pi / 2.0 + @as(f64, @floatFromInt(i)) * 2.0 * std.math.pi / @as(f64, @floatFromInt(total));
        }
    }.at;

    // Concentric grid rings.
    const fracs = [_]f64{ 0.25, 0.5, 0.75, 1.0 };
    for (fracs) |frac| {
        const pts = a.alloc(Vec2, n) catch return errNode(ctx);
        for (0..n) |i| {
            const t = ang(i, n);
            pts[i] = .{ .x = cx + @cos(t) * radius * frac, .y = cy + @sin(t) * radius * frac };
        }
        shapes.append(a, .{ .polyline = .{ .points = pts, .closed = true, .style = .{ .stroke = opts.axis_color, .stroke_width = 1, .opacity = 0.3, .fill = "none" } } }) catch return errNode(ctx);
    }
    // Spokes + axis labels.
    for (0..n) |i| {
        const t = ang(i, n);
        shapes.append(a, .{ .line = .{ .x1 = cx, .y1 = cy, .x2 = cx + @cos(t) * radius, .y2 = cy + @sin(t) * radius, .style = .{ .stroke = opts.axis_color, .stroke_width = 1, .opacity = 0.4 } } }) catch return errNode(ctx);
        shapes.append(a, .{ .text = .{ .x = cx + @cos(t) * (radius + 16), .y = cy + @sin(t) * (radius + 16) + 3, .content = axes[i], .anchor = .middle, .font_size = 10, .style = .{ .fill = opts.axis_color } } }) catch return errNode(ctx);
    }
    // Series polygons.
    for (series, 0..) |s, si| {
        const color = s.color orelse palette[si % palette.len];
        const pts = a.alloc(Vec2, n) catch return errNode(ctx);
        for (0..n) |i| {
            const v = if (i < s.values.len) s.values[i] else 0;
            const rr = v / max * radius;
            const t = ang(i, n);
            pts[i] = .{ .x = cx + @cos(t) * rr, .y = cy + @sin(t) * rr };
        }
        shapes.append(a, .{ .polyline = .{ .points = pts, .closed = true, .style = .{ .fill = color, .opacity = 0.25, .stroke = color, .stroke_width = 2 } } }) catch return errNode(ctx);
    }

    appendLegend(&shapes, a, series, opts, Plot.of(opts)) catch return errNode(ctx);
    return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = shapes.items });
}

/// One distribution for a violin plot: a label + raw samples.
pub const ViolinSeries = struct { label: []const u8, samples: []const f64 };

/// Violin plot: a mirrored kernel-density shape per category (width ∝ sample
/// density at each y) with a median tick. The y axis spans [min, max] across all
/// samples. Densities use a Gaussian kernel.
pub fn violin(ctx: *const Context, data: []const ViolinSeries, opts: Opts) *Node {
    const a = ctx.allocator;
    const plot = Plot.of(opts);
    var shapes: std.ArrayList(scene.Shape) = .empty;
    if (data.len == 0) return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = shapes.items });

    var lo: f64 = std.math.inf(f64);
    var hi: f64 = -std.math.inf(f64);
    var any = false;
    for (data) |d| for (d.samples) |s| {
        lo = @min(lo, s);
        hi = @max(hi, s);
        any = true;
    };
    if (!any) return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = shapes.items });
    if (hi == lo) hi = lo + 1;

    const y = scale.Linear{ .domain = .{ lo, hi }, .range = .{ plot.y0, plot.y1 } };
    const band = scale.Band{ .count = data.len, .range = .{ plot.x0, plot.x1 }, .padding = 0.3 };
    appendAxis(&shapes, a, .{ .orient = .left, .scale = y, .cross = plot.x0, .tick_count = opts.tick_count, .color = opts.axis_color });

    const grid = 40;
    const bw = (hi - lo) / 12.0; // kernel bandwidth
    const max_half = band.bandwidth() / 2.0 * 0.95;

    for (data, 0..) |d, ci| {
        if (d.samples.len == 0) continue;
        const cx = band.center(ci);
        const color = palette[ci % palette.len];

        // Gaussian-kernel density on a y grid; track the peak to normalize width.
        const dens = a.alloc(f64, grid) catch return errNode(ctx);
        var maxd: f64 = 0;
        for (0..grid) |g| {
            const yg = lo + (hi - lo) * @as(f64, @floatFromInt(g)) / @as(f64, @floatFromInt(grid - 1));
            var sum: f64 = 0;
            for (d.samples) |s| {
                const z = (yg - s) / bw;
                sum += @exp(-0.5 * z * z);
            }
            dens[g] = sum;
            maxd = @max(maxd, sum);
        }
        if (maxd == 0) maxd = 1;

        // Symmetric polygon: left edge up, right edge back down.
        const pts = a.alloc(Vec2, grid * 2) catch return errNode(ctx);
        for (0..grid) |g| {
            const yg = lo + (hi - lo) * @as(f64, @floatFromInt(g)) / @as(f64, @floatFromInt(grid - 1));
            const hw = dens[g] / maxd * max_half;
            const py = y.map(yg);
            pts[g] = .{ .x = cx - hw, .y = py };
            pts[grid * 2 - 1 - g] = .{ .x = cx + hw, .y = py };
        }
        shapes.append(a, .{ .polyline = .{ .points = pts, .closed = true, .style = .{ .fill = color, .opacity = 0.3, .stroke = color, .stroke_width = 1.5 } } }) catch return errNode(ctx);

        // Median tick.
        const stats = boxStats(a, d.samples) catch return errNode(ctx);
        const my = y.map(stats.median);
        shapes.append(a, .{ .line = .{ .x1 = cx - max_half * 0.4, .y1 = my, .x2 = cx + max_half * 0.4, .y2 = my, .style = .{ .stroke = color, .stroke_width = 2 } } }) catch return errNode(ctx);
        shapes.append(a, .{ .text = .{ .x = cx, .y = plot.y0 + 16, .content = d.label, .anchor = .middle, .font_size = 10, .style = .{ .fill = opts.axis_color } } }) catch return errNode(ctx);
    }

    return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = shapes.items });
}

/// Line chart over continuous (x, y) points (drawn in given order).
pub fn line(ctx: *const Context, data: []const Point, opts: Opts) *Node {
    const a = ctx.allocator;
    const plot = Plot.of(opts);
    var shapes: std.ArrayList(scene.Shape) = .empty;

    const sx, const sy = continuousScales(data, plot);
    appendAxis(&shapes, a, .{ .orient = .bottom, .scale = sx, .cross = plot.y0, .tick_count = opts.tick_count, .color = opts.axis_color });
    appendAxis(&shapes, a, .{ .orient = .left, .scale = sy, .cross = plot.x0, .tick_count = opts.tick_count, .color = opts.axis_color });

    const pts = a.alloc(Vec2, data.len) catch return errNode(ctx);
    for (data, 0..) |d, i| pts[i] = .{ .x = sx.map(d.x), .y = sy.map(d.y) };
    shapes.append(a, .{ .polyline = .{
        .points = pts,
        .style = .{ .stroke = opts.color, .stroke_width = 2, .fill = "none" },
    } }) catch return errNode(ctx);

    return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = shapes.items });
}

/// Scatter plot of (x, y) points.
pub fn scatter(ctx: *const Context, data: []const Point, opts: Opts) *Node {
    const a = ctx.allocator;
    const plot = Plot.of(opts);
    var shapes: std.ArrayList(scene.Shape) = .empty;

    const sx, const sy = continuousScales(data, plot);
    appendAxis(&shapes, a, .{ .orient = .bottom, .scale = sx, .cross = plot.y0, .tick_count = opts.tick_count, .color = opts.axis_color });
    appendAxis(&shapes, a, .{ .orient = .left, .scale = sy, .cross = plot.x0, .tick_count = opts.tick_count, .color = opts.axis_color });

    for (data) |d| {
        shapes.append(a, .{ .circle = .{
            .cx = sx.map(d.x),
            .cy = sy.map(d.y),
            .r = 4,
            .style = .{ .fill = opts.color },
        } }) catch return errNode(ctx);
    }

    return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = shapes.items });
}

/// Filled area chart: a line with the region down to the y=0 baseline filled.
pub fn area(ctx: *const Context, data: []const Point, opts: Opts) *Node {
    const a = ctx.allocator;
    const plot = Plot.of(opts);
    var shapes: std.ArrayList(scene.Shape) = .empty;

    const sx, const sy = continuousScales(data, plot);
    appendAxis(&shapes, a, .{ .orient = .bottom, .scale = sx, .cross = plot.y0, .tick_count = opts.tick_count, .color = opts.axis_color });
    appendAxis(&shapes, a, .{ .orient = .left, .scale = sy, .cross = plot.x0, .tick_count = opts.tick_count, .color = opts.axis_color });

    if (data.len != 0) {
        // Polygon: the curve, then back along the baseline to close.
        const poly = a.alloc(Vec2, data.len + 2) catch return errNode(ctx);
        for (data, 0..) |d, i| poly[i] = .{ .x = sx.map(d.x), .y = sy.map(d.y) };
        poly[data.len] = .{ .x = sx.map(data[data.len - 1].x), .y = plot.y0 };
        poly[data.len + 1] = .{ .x = sx.map(data[0].x), .y = plot.y0 };
        shapes.append(a, .{ .polyline = .{
            .points = poly,
            .closed = true,
            .style = .{ .fill = opts.color, .opacity = 0.25, .stroke = opts.color, .stroke_width = 2 },
        } }) catch return errNode(ctx);
    }

    return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = shapes.items });
}

/// Default categorical palette for pie/donut slices.
pub const palette = [_][]const u8{
    "#1f6feb", "#10b981", "#f59e0b", "#ef4444", "#8b5cf6",
    "#06b6d4", "#ec4899", "#84cc16", "#f97316", "#14b8a6",
};

pub const PieOpts = struct {
    width: f64 = 360,
    height: f64 = 360,
    /// Inner radius as a fraction of the outer radius (0 = full pie, 0.5 = donut).
    inner_ratio: f64 = 0,
    pad: f64 = 8,
    colors: []const []const u8 = &palette,
    stroke: []const u8 = "#0e0e10",
};

/// Pie or donut chart. Slice angle is proportional to each datum's value.
pub fn pie(ctx: *const Context, data: []const Datum, opts: PieOpts) *Node {
    const a = ctx.allocator;
    var shapes: std.ArrayList(scene.Shape) = .empty;

    const cx = opts.width / 2.0;
    const cy = opts.height / 2.0;
    const r = @min(cx, cy) - opts.pad;
    const ir = r * opts.inner_ratio;

    var total: f64 = 0;
    for (data) |d| total += d.value;
    if (total <= 0) return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = shapes.items });

    var ang0: f64 = -std.math.pi / 2.0; // start at 12 o'clock
    for (data, 0..) |d, i| {
        const frac = d.value / total;
        const ang1 = ang0 + frac * 2.0 * std.math.pi;
        const color = opts.colors[i % opts.colors.len];
        const d_str = slicePath(a, cx, cy, r, ir, ang0, ang1) catch return errNode(ctx);
        shapes.append(a, .{ .path = .{ .d = d_str, .style = .{ .fill = color, .stroke = opts.stroke, .stroke_width = 1 } } }) catch return errNode(ctx);
        ang0 = ang1;
    }

    return scene.toNode(ctx, .{ .width = opts.width, .height = opts.height, .shapes = shapes.items });
}

/// SVG path data for one wedge (pie when `ir == 0`) or ring segment (donut).
fn slicePath(a: std.mem.Allocator, cx: f64, cy: f64, r: f64, ir: f64, a0: f64, a1: f64) ![]const u8 {
    const large: u8 = if (a1 - a0 > std.math.pi) 1 else 0;
    const ox0 = cx + r * @cos(a0);
    const oy0 = cy + r * @sin(a0);
    const ox1 = cx + r * @cos(a1);
    const oy1 = cy + r * @sin(a1);
    if (ir <= 0) {
        return std.fmt.allocPrint(a, "M {d},{d} L {d},{d} A {d},{d} 0 {d} 1 {d},{d} Z", .{ cx, cy, ox0, oy0, r, r, large, ox1, oy1 });
    }
    const ix0 = cx + ir * @cos(a0);
    const iy0 = cy + ir * @sin(a0);
    const ix1 = cx + ir * @cos(a1);
    const iy1 = cy + ir * @sin(a1);
    return std.fmt.allocPrint(
        a,
        "M {d},{d} A {d},{d} 0 {d} 1 {d},{d} L {d},{d} A {d},{d} 0 {d} 0 {d},{d} Z",
        .{ ox0, oy0, r, r, large, ox1, oy1, ix1, iy1, ir, ir, large, ix0, iy0 },
    );
}

fn continuousScales(data: []const Point, plot: Plot) struct { scale.Linear, scale.Linear } {
    var min_x: f64 = 0;
    var max_x: f64 = 1;
    var max_y: f64 = 1;
    if (data.len != 0) {
        min_x = data[0].x;
        max_x = data[0].x;
        max_y = data[0].y;
        for (data) |d| {
            min_x = @min(min_x, d.x);
            max_x = @max(max_x, d.x);
            max_y = @max(max_y, d.y);
        }
        if (max_x == min_x) max_x = min_x + 1;
        if (max_y == 0) max_y = 1;
    }
    return .{
        scale.Linear{ .domain = .{ min_x, max_x }, .range = .{ plot.x0, plot.x1 } },
        scale.Linear{ .domain = .{ 0, max_y }, .range = .{ plot.y0, plot.y1 } },
    };
}

fn appendAxis(shapes: *std.ArrayList(scene.Shape), a: std.mem.Allocator, opts: axis.Opts) void {
    const ax = axis.build(a, opts) catch return;
    shapes.appendSlice(a, ax) catch return;
}

fn errNode(ctx: *const Context) *Node {
    const n = ctx.el("svg");
    n.err = error.OutOfMemory;
    return n;
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;
const Renderer = @import("../renderer.zig").Renderer;

fn renderToBuf(node: *Node, buf: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try Renderer.render(&w, try node.build());
    return w.buffered();
}

test "bar chart renders rects, y-axis, and category labels" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    var buf: [8192]u8 = undefined;
    const data = [_]Datum{ .{ .label = "Jan", .value = 10 }, .{ .label = "Feb", .value = 14 }, .{ .label = "Mar", .value = 6 } };
    const out = try renderToBuf(bar(&ctx, &data, .{ .width = 600, .height = 400 }), &buf);
    try testing.expect(std.mem.indexOf(u8, out, "<svg") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<rect") != null);
    try testing.expect(std.mem.indexOf(u8, out, ">Jan</text>") != null);
    try testing.expect(std.mem.indexOf(u8, out, ">Mar</text>") != null);
}

test "stacked bar renders a rect per non-zero segment, labels, and legend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    var buf: [16384]u8 = undefined;
    const cats = [_][]const u8{ "Q1", "Q2" };
    const series = [_]StackSeries{
        .{ .name = "web", .values = &.{ 5, 8 }, .color = "#1f6feb" },
        .{ .name = "api", .values = &.{ 3, 0 }, .color = "#10b981" }, // Q2 api = 0 → no rect
    };
    const out = try renderToBuf(stackedBar(&ctx, &cats, &series, .{ .width = 480, .height = 300 }), &buf);
    try testing.expect(std.mem.indexOf(u8, out, "<svg") != null);
    // category labels + legend names
    try testing.expect(std.mem.indexOf(u8, out, ">Q1</text>") != null);
    try testing.expect(std.mem.indexOf(u8, out, ">web</text>") != null);
    try testing.expect(std.mem.indexOf(u8, out, ">api</text>") != null);
    // both series colors present
    try testing.expect(std.mem.indexOf(u8, out, "fill=\"#1f6feb\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "fill=\"#10b981\"") != null);
    // 3 stacked segments (web Q1, web Q2, api Q1) + 2 legend swatches = 5 rects.
    try testing.expectEqual(@as(usize, 5), std.mem.count(u8, out, "<rect"));
}

test "grouped bar renders side-by-side bars per category + legend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    var buf: [16384]u8 = undefined;
    const cats = [_][]const u8{ "Q1", "Q2" };
    const series = [_]StackSeries{
        .{ .name = "web", .values = &.{ 5, 8 }, .color = "#1f6feb" },
        .{ .name = "api", .values = &.{ 3, 6 }, .color = "#10b981" },
    };
    const out = try renderToBuf(groupedBar(&ctx, &cats, &series, .{ .width = 480, .height = 300 }), &buf);
    try testing.expect(std.mem.indexOf(u8, out, ">Q1</text>") != null);
    try testing.expect(std.mem.indexOf(u8, out, ">web</text>") != null);
    // 4 bars (2 cats × 2 series, all non-zero) + 2 legend swatches = 6 rects.
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, out, "<rect"));
}

test "candlestick renders up/down bodies, wicks, and labels" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    var buf: [16384]u8 = undefined;
    const data = [_]Candle{
        .{ .label = "Mon", .open = 10, .high = 14, .low = 9, .close = 13 }, // up
        .{ .label = "Tue", .open = 13, .high = 13, .low = 8, .close = 9 }, // down
    };
    const out = try renderToBuf(candlestick(&ctx, &data, .{ .width = 480, .height = 300 }), &buf);
    try testing.expect(std.mem.indexOf(u8, out, ">Mon</text>") != null);
    try testing.expect(std.mem.indexOf(u8, out, ">Tue</text>") != null);
    // up color (green) + down color (red) both present
    try testing.expect(std.mem.indexOf(u8, out, "#10b981") != null);
    try testing.expect(std.mem.indexOf(u8, out, "#ef4444") != null);
    // two bodies (no other rects on this chart)
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "<rect"));
}

test "boxStats computes quartiles from samples" {
    const s = [_]f64{ 1, 2, 3, 4, 5 };
    const b = try boxStats(testing.allocator, &s);
    try testing.expectEqual(@as(f64, 1), b.min);
    try testing.expectEqual(@as(f64, 5), b.max);
    try testing.expectEqual(@as(f64, 3), b.median);
    try testing.expectEqual(@as(f64, 2), b.q1);
    try testing.expectEqual(@as(f64, 4), b.q3);
}

test "box plot renders a box, median, whiskers, and label per category" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    var buf: [16384]u8 = undefined;
    const data = [_]BoxStats{
        .{ .label = "A", .min = 1, .q1 = 3, .median = 5, .q3 = 7, .max = 9 },
        .{ .label = "B", .min = 2, .q1 = 4, .median = 5, .q3 = 8, .max = 12 },
    };
    const out = try renderToBuf(boxPlot(&ctx, &data, .{ .width = 480, .height = 300, .color = "#1f6feb" }), &buf);
    try testing.expect(std.mem.indexOf(u8, out, ">A</text>") != null);
    try testing.expect(std.mem.indexOf(u8, out, ">B</text>") != null);
    // one box rect per category (translucent fill)
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "<rect"));
    try testing.expect(std.mem.indexOf(u8, out, "opacity=\"0.3\"") != null);
}

test "heatmap renders a cell per value with interpolated colors + labels" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    var buf: [16384]u8 = undefined;
    const rows = [_][]const u8{ "r0", "r1" };
    const cols = [_][]const u8{ "c0", "c1" };
    const vals = [_]f64{ 0, 5, 5, 10 }; // row-major 2x2
    const out = try renderToBuf(heatmap(&ctx, &rows, &cols, &vals, .{ .low = .{ .r = 0, .g = 0, .b = 0 }, .high = .{ .r = 100, .g = 0, .b = 0 } }), &buf);
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, out, "<rect"));
    try testing.expect(std.mem.indexOf(u8, out, ">r0</text>") != null);
    try testing.expect(std.mem.indexOf(u8, out, ">c1</text>") != null);
    // min value → low color (black); max value → high color (rgb(100,0,0)).
    try testing.expect(std.mem.indexOf(u8, out, "rgb(0,0,0)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "rgb(100,0,0)") != null);
}

test "radar renders grid rings, axis labels, and a polygon per series" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    var buf: [16384]u8 = undefined;
    const axes = [_][]const u8{ "speed", "power", "range" };
    const series = [_]StackSeries{
        .{ .name = "A", .values = &.{ 3, 5, 2 }, .color = "#1f6feb" },
        .{ .name = "B", .values = &.{ 5, 2, 4 }, .color = "#10b981" },
    };
    const out = try renderToBuf(radar(&ctx, &axes, &series, .{ .width = 360, .height = 360 }), &buf);
    try testing.expect(std.mem.indexOf(u8, out, ">speed</text>") != null);
    try testing.expect(std.mem.indexOf(u8, out, ">A</text>") != null); // legend
    // 4 grid rings + 2 series = 6 closed polygons.
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, out, "<polygon"));
}

test "violin renders a density polygon + median per category" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    var buf: [32768]u8 = undefined;
    const data = [_]ViolinSeries{
        .{ .label = "A", .samples = &.{ 1, 2, 2, 3, 3, 3, 4, 4, 5 } },
        .{ .label = "B", .samples = &.{ 2, 4, 4, 6, 6, 6, 8, 10 } },
    };
    const out = try renderToBuf(violin(&ctx, &data, .{ .width = 480, .height = 320 }), &buf);
    try testing.expect(std.mem.indexOf(u8, out, ">A</text>") != null);
    try testing.expect(std.mem.indexOf(u8, out, ">B</text>") != null);
    // one mirrored density polygon per category
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "<polygon"));
}

test "line chart renders a polyline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    var buf: [8192]u8 = undefined;
    const data = [_]Point{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 4 }, .{ .x = 2, .y = 2 } };
    const out = try renderToBuf(line(&ctx, &data, .{}), &buf);
    try testing.expect(std.mem.indexOf(u8, out, "<polyline") != null);
    try testing.expect(std.mem.indexOf(u8, out, "fill=\"none\"") != null);
}

test "scatter chart renders circles" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    var buf: [8192]u8 = undefined;
    const data = [_]Point{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 5 } };
    const out = try renderToBuf(scatter(&ctx, &data, .{}), &buf);
    try testing.expect(std.mem.indexOf(u8, out, "<circle") != null);
}

test "area chart renders a filled closed polygon" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    var buf: [8192]u8 = undefined;
    const data = [_]Point{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 4 }, .{ .x = 2, .y = 2 } };
    const out = try renderToBuf(area(&ctx, &data, .{}), &buf);
    try testing.expect(std.mem.indexOf(u8, out, "<polygon") != null);
    try testing.expect(std.mem.indexOf(u8, out, "opacity=\"0.25\"") != null);
}

test "pie chart renders one path per slice" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    var buf: [8192]u8 = undefined;
    const data = [_]Datum{ .{ .label = "a", .value = 1 }, .{ .label = "b", .value = 2 }, .{ .label = "c", .value = 1 } };
    const out = try renderToBuf(pie(&ctx, &data, .{}), &buf);
    try testing.expect(std.mem.indexOf(u8, out, "<path") != null);
    // three slices → three path elements
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, out, "<path"));
}

test "donut chart uses inner radius (two arcs per slice)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    var buf: [8192]u8 = undefined;
    const data = [_]Datum{ .{ .label = "a", .value = 1 }, .{ .label = "b", .value = 1 } };
    const out = try renderToBuf(pie(&ctx, &data, .{ .inner_ratio = 0.5 }), &buf);
    // each donut slice has two arc commands ("A"); 2 slices → ≥4 total.
    try testing.expect(std.mem.count(u8, out, " A ") >= 4);
}
