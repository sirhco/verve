//! Axis generation: given a `scale.Linear` and an orientation, emit the scene
//! shapes for an axis — the domain line, tick marks, and tick labels. Charts
//! compose these into their scene.

const std = @import("std");
const scale = @import("scale.zig");
const scene = @import("scene.zig");

pub const Orient = enum { bottom, left };

pub const Opts = struct {
    orient: Orient,
    /// For `.bottom` the scale maps the domain to x; for `.left`, to y.
    scale: scale.Linear,
    /// The fixed cross-axis coordinate: y for a bottom axis, x for a left axis.
    cross: f64,
    tick_count: usize = 5,
    tick_len: f64 = 6,
    color: []const u8 = "#888",
    label_size: f64 = 10,
    label_gap: f64 = 4,
};

/// Build the axis shapes. Caller owns the returned slice.
pub fn build(alloc: std.mem.Allocator, opts: Opts) ![]scene.Shape {
    const ticks = try opts.scale.ticks(alloc, opts.tick_count);
    defer alloc.free(ticks);

    var shapes: std.ArrayList(scene.Shape) = .empty;
    errdefer shapes.deinit(alloc);

    const line_style = scene.Style{ .stroke = opts.color, .stroke_width = 1 };
    const r0 = opts.scale.range[0];
    const r1 = opts.scale.range[1];

    switch (opts.orient) {
        .bottom => {
            try shapes.append(alloc, .{ .line = .{ .x1 = r0, .y1 = opts.cross, .x2 = r1, .y2 = opts.cross, .style = line_style } });
            for (ticks) |t| {
                try shapes.append(alloc, .{ .line = .{
                    .x1 = t.pos,
                    .y1 = opts.cross,
                    .x2 = t.pos,
                    .y2 = opts.cross + opts.tick_len,
                    .style = line_style,
                } });
                try shapes.append(alloc, .{ .text = .{
                    .x = t.pos,
                    .y = opts.cross + opts.tick_len + opts.label_size + opts.label_gap,
                    .content = try label(alloc, t.value),
                    .anchor = .middle,
                    .font_size = opts.label_size,
                    .style = .{ .fill = opts.color },
                } });
            }
        },
        .left => {
            try shapes.append(alloc, .{ .line = .{ .x1 = opts.cross, .y1 = r0, .x2 = opts.cross, .y2 = r1, .style = line_style } });
            for (ticks) |t| {
                try shapes.append(alloc, .{ .line = .{
                    .x1 = opts.cross - opts.tick_len,
                    .y1 = t.pos,
                    .x2 = opts.cross,
                    .y2 = t.pos,
                    .style = line_style,
                } });
                try shapes.append(alloc, .{ .text = .{
                    .x = opts.cross - opts.tick_len - opts.label_gap,
                    .y = t.pos + opts.label_size / 3.0,
                    .content = try label(alloc, t.value),
                    .anchor = .end,
                    .font_size = opts.label_size,
                    .style = .{ .fill = opts.color },
                } });
            }
        },
    }
    return shapes.toOwnedSlice(alloc);
}

fn label(alloc: std.mem.Allocator, v: f64) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{d}", .{v});
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

test "bottom axis emits domain line, ticks, and labels" {
    const s = scale.Linear{ .domain = .{ 0, 100 }, .range = .{ 0, 200 } };
    const shapes = try build(testing.allocator, .{ .orient = .bottom, .scale = s, .cross = 150, .tick_count = 5 });
    defer {
        for (shapes) |sh| if (sh == .text) testing.allocator.free(sh.text.content);
        testing.allocator.free(shapes);
    }
    // 1 domain line + 6 ticks * (1 line + 1 label) = 13 shapes.
    try testing.expectEqual(@as(usize, 13), shapes.len);
    try testing.expect(shapes[0] == .line);
    // First tick label is "0".
    var saw_zero = false;
    for (shapes) |sh| {
        if (sh == .text and std.mem.eql(u8, sh.text.content, "0")) saw_zero = true;
    }
    try testing.expect(saw_zero);
}
