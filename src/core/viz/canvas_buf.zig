//! Frozen draw-buffer layout for the viz canvas render path (verve.viz phase 3).
//! The chunk packs node/edge/camera data here; `verve.js`'s `viz_canvas_draw`
//! decodes the SAME layout. Header 48B, then node x/y f32 pairs, then edge u32
//! index pairs. All little-endian.
const std = @import("std");

pub const header_size: u32 = 48;

pub const Header = struct {
    cam_x: f32,
    cam_y: f32,
    scale: f32,
    node_count: u32,
    edge_count: u32,
    hover: i32,
    select: i32,
    node_r: f32,
    base_color: u32,
    hover_color: u32,
    select_color: u32,
    edge_color: u32,
};

/// Total bytes for a graph of the given counts.
pub fn sizeFor(node_count: u32, edge_count: u32) u32 {
    return header_size + node_count * 8 + edge_count * 8;
}

/// Pack header + nodes (xs/ys) + edges (ef/et) into `buf`. Returns the byte
/// length written. Caller ensures `buf.len >= sizeFor(...)`.
pub fn pack(buf: []u8, h: Header, xs: []const f32, ys: []const f32, ef: []const u32, et: []const u32) u32 {
    std.debug.assert(xs.len == h.node_count and ys.len == h.node_count);
    std.debug.assert(ef.len == h.edge_count and et.len == h.edge_count);
    std.mem.writeInt(u32, buf[0..4], @bitCast(h.cam_x), .little);
    std.mem.writeInt(u32, buf[4..8], @bitCast(h.cam_y), .little);
    std.mem.writeInt(u32, buf[8..12], @bitCast(h.scale), .little);
    std.mem.writeInt(u32, buf[12..16], h.node_count, .little);
    std.mem.writeInt(u32, buf[16..20], h.edge_count, .little);
    std.mem.writeInt(i32, buf[20..24], h.hover, .little);
    std.mem.writeInt(i32, buf[24..28], h.select, .little);
    std.mem.writeInt(u32, buf[28..32], @bitCast(h.node_r), .little);
    std.mem.writeInt(u32, buf[32..36], h.base_color, .little);
    std.mem.writeInt(u32, buf[36..40], h.hover_color, .little);
    std.mem.writeInt(u32, buf[40..44], h.select_color, .little);
    std.mem.writeInt(u32, buf[44..48], h.edge_color, .little);
    var off: u32 = header_size;
    for (0..h.node_count) |i| {
        std.mem.writeInt(u32, buf[off..][0..4], @bitCast(xs[i]), .little);
        std.mem.writeInt(u32, buf[off + 4 ..][0..4], @bitCast(ys[i]), .little);
        off += 8;
    }
    for (0..h.edge_count) |i| {
        std.mem.writeInt(u32, buf[off..][0..4], ef[i], .little);
        std.mem.writeInt(u32, buf[off + 4 ..][0..4], et[i], .little);
        off += 8;
    }
    return off;
}

/// Allocate and pack a graph into the canvas_buf byte layout with default
/// camera and colour values. The canvas chunk's `fitCamera` recomputes the
/// camera on load; hover/select start at -1 (none). Caller owns returned slice.
pub fn packGraph(alloc: std.mem.Allocator, xs: []const f32, ys: []const f32, ef: []const u32, et: []const u32) ![]u8 {
    std.debug.assert(xs.len == ys.len);
    std.debug.assert(ef.len == et.len);
    const n: u32 = @intCast(xs.len);
    const e: u32 = @intCast(ef.len);
    const buf = try alloc.alloc(u8, sizeFor(n, e));
    const h = Header{
        .cam_x = 0,
        .cam_y = 0,
        .scale = 1.0,
        .node_count = n,
        .edge_count = e,
        .hover = -1,
        .select = -1,
        .node_r = 4.0,
        .base_color = 0x1f6febff,
        .hover_color = 0xffd166ff,
        .select_color = 0xff5577ff,
        .edge_color = 0x30363dff,
    };
    _ = pack(buf, h, xs, ys, ef, et);
    return buf;
}

test "canvas_buf pack round-trip" {
    var buf: [header_size + 3 * 8 + 2 * 8]u8 = undefined;
    const xs = [_]f32{ 1, 2, 3 };
    const ys = [_]f32{ 4, 5, 6 };
    const ef = [_]u32{ 0, 1 };
    const et = [_]u32{ 1, 2 };
    const h = Header{
        .cam_x = 10,
        .cam_y = 20,
        .scale = 1.5,
        .node_count = 3,
        .edge_count = 2,
        .hover = -1,
        .select = 2,
        .node_r = 4.0,
        .base_color = 0x1f6febff,
        .hover_color = 0xffaa00ff,
        .select_color = 0xff0000ff,
        .edge_color = 0x30363dff,
    };
    const n = pack(&buf, h, &xs, &ys, &ef, &et);
    try std.testing.expectEqual(sizeFor(3, 2), n);
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, buf[12..16], .little));
    try std.testing.expectEqual(@as(i32, 2), std.mem.readInt(i32, buf[24..28], .little));
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), @as(f32, @bitCast(std.mem.readInt(u32, buf[8..12], .little))), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3), @as(f32, @bitCast(std.mem.readInt(u32, buf[header_size + 16 ..][0..4], .little))), 1e-6);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, buf[header_size + 24 + 8 ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, buf[header_size + 24 + 12 ..][0..4], .little));
}

test "canvas_buf packGraph allocates correct layout with defaults" {
    const alloc = std.testing.allocator;
    const xs = [_]f32{ 0, 22, 44 };
    const ys = [_]f32{ 0, 0, 22 };
    const ef = [_]u32{ 1, 2 };
    const et = [_]u32{ 0, 1 };
    const buf = try packGraph(alloc, &xs, &ys, &ef, &et);
    defer alloc.free(buf);
    // size matches sizeFor
    try std.testing.expectEqual(sizeFor(3, 2), @as(u32, @intCast(buf.len)));
    // node_count and edge_count written correctly
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, buf[12..16], .little));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, buf[16..20], .little));
    // hover = -1, select = -1 (defaults)
    try std.testing.expectEqual(@as(i32, -1), std.mem.readInt(i32, buf[20..24], .little));
    try std.testing.expectEqual(@as(i32, -1), std.mem.readInt(i32, buf[24..28], .little));
    // first node xs[0] = 0
    const x0: f32 = @bitCast(std.mem.readInt(u32, buf[header_size..][0..4], .little));
    try std.testing.expectApproxEqAbs(@as(f32, 0), x0, 1e-6);
    // first edge ef[0]=1, et[0]=0
    const edge_off = header_size + 3 * 8;
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, buf[edge_off..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[edge_off + 4 ..][0..4], .little));
}
