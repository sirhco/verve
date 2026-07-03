//! Verve-native geometry compression codec for `.vmesh` index buffers.
//!
//! Lossless delta + zigzag + LEB128-varint encoding of a u16 index stream.
//! Meshopt-*style* (delta of consecutive indices), but Verve owns both ends
//! (build-time encode in `vmesh.compressGeometry`, runtime decode in
//! `vmesh.Reader.initAlloc`) so it is NOT bit-compatible with upstream
//! meshoptimizer and needs no interop guarantee. Cache-optimized meshes have
//! small consecutive index deltas, which zigzag+varint pack into 1 byte each.
//!
//! Lossless => a native round-trip golden is the definitive correctness gate;
//! no GPU-output verification required (decoded bytes are byte-identical to the
//! raw index buffer, so every downstream draw is unchanged).

const std = @import("std");

/// ZigZag-encode a signed delta into an unsigned magnitude (small |x| => small).
fn zigzag(n: i32) u32 {
    return @bitCast((n << 1) ^ (n >> 31));
}

fn unzigzag(u: u32) i32 {
    const s: i32 = @bitCast(u);
    return (s >> 1) ^ -(s & 1);
}

/// Append `v` as an unsigned LEB128 varint (7 bits/byte, high bit = continue).
fn putVarint(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u32) !void {
    var x = v;
    while (true) {
        const byte: u8 = @intCast(x & 0x7f);
        x >>= 7;
        if (x != 0) {
            try buf.append(alloc, byte | 0x80);
        } else {
            try buf.append(alloc, byte);
            break;
        }
    }
}

/// Read one unsigned LEB128 varint from `blob` at `*pos`, advancing `*pos`.
fn getVarint(blob: []const u8, pos: *usize) !u32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    while (true) {
        if (pos.* >= blob.len) return error.Truncated;
        const byte = blob[pos.*];
        pos.* += 1;
        result |= @as(u32, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) break;
        shift = std.math.add(u5, shift, 7) catch return error.Corrupt;
    }
    return result;
}

/// Encode a u16 index slice to a compressed byte blob. Caller owns the result.
pub fn encodeIndices(alloc: std.mem.Allocator, indices: []const u16) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    var prev: i32 = 0;
    for (indices) |idx| {
        const cur: i32 = idx;
        try putVarint(&buf, alloc, zigzag(cur - prev));
        prev = cur;
    }
    return buf.toOwnedSlice(alloc);
}

/// Decode a compressed blob back to `count` u16 indices. Caller owns the result.
pub fn decodeIndices(alloc: std.mem.Allocator, blob: []const u8, count: usize) ![]u16 {
    const out = try alloc.alloc(u16, count);
    errdefer alloc.free(out);
    var pos: usize = 0;
    var prev: i32 = 0;
    for (out) |*slot| {
        const cur = prev + unzigzag(try getVarint(blob, &pos));
        if (cur < 0 or cur > 65535) return error.Corrupt;
        slot.* = @intCast(cur);
        prev = cur;
    }
    return out;
}

fn expectRoundTrip(indices: []const u16) !void {
    const a = std.testing.allocator;
    const blob = try encodeIndices(a, indices);
    defer a.free(blob);
    const out = try decodeIndices(a, blob, indices.len);
    defer a.free(out);
    try std.testing.expectEqualSlices(u16, indices, out);
}

test "round-trip: empty" {
    try expectRoundTrip(&[_]u16{});
}

test "round-trip: single" {
    try expectRoundTrip(&[_]u16{7});
}

test "round-trip: sequential" {
    try expectRoundTrip(&[_]u16{ 0, 1, 2, 3, 4, 5 });
}

test "round-trip: repeated" {
    try expectRoundTrip(&[_]u16{ 5, 5, 5, 5 });
}

test "round-trip: random permutation" {
    try expectRoundTrip(&[_]u16{ 3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5 });
}

test "round-trip: u16 boundaries" {
    try expectRoundTrip(&[_]u16{ 0, 65535, 0, 65535, 32768, 1 });
}

test "round-trip: descending" {
    try expectRoundTrip(&[_]u16{ 100, 90, 80, 0, 65535 });
}
