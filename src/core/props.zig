//! Typed island props codec. Server: `encodeProps(ctx, P{...})` → binary
//! (serialize.zig) → base64 string for `IslandOpts.props` / `data-props`.
//! Client chunk: the bridge base64-decodes `data-props`; `decodeProps(P, bytes,
//! alloc)` reconstructs the typed value.

const std = @import("std");
const testing = std.testing;
const serialize = @import("serialize.zig");
const Context = @import("context.zig").Context;

/// Encode a typed props value and base64 it for the `data-props` attribute.
/// Returned slice lives on the render arena (`ctx.allocator`).
pub fn encodeProps(ctx: *const Context, value: anytype) ![]const u8 {
    const bytes = try serialize.encodeToBytes(value, ctx.allocator);
    const enc = std.base64.standard.Encoder;
    const out = try ctx.allocator.alloc(u8, enc.calcSize(bytes.len));
    _ = enc.encode(out, bytes);
    return out;
}

/// Decode raw (already base64-decoded) props bytes into `T`. Allocations live
/// on `alloc`. Panic-free on arbitrary bytes (see serialize.decode).
pub fn decodeProps(comptime T: type, bytes: []const u8, alloc: std.mem.Allocator) !T {
    return serialize.decode(T, bytes, alloc);
}

// --- tests ---

const Props = struct { initial: i32, label: []const u8, open: bool };

test "encodeProps base64 round-trips through decodeProps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const b64 = try encodeProps(&ctx, Props{ .initial = 5, .label = "hi", .open = true });
    const dec = std.base64.standard.Decoder;
    const raw_len = try dec.calcSizeForSlice(b64);
    const raw = try arena.allocator().alloc(u8, raw_len);
    try dec.decode(raw, b64);

    const got = try decodeProps(Props, raw, arena.allocator());
    try testing.expectEqual(@as(i32, 5), got.initial);
    try testing.expectEqualStrings("hi", got.label);
    try testing.expectEqual(true, got.open);
}

test "decodeProps errors on a mismatched type, no crash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    const b64 = try encodeProps(&ctx, Props{ .initial = 1, .label = "x", .open = false });
    const dec = std.base64.standard.Decoder;
    const raw_len = try dec.calcSizeForSlice(b64);
    const raw = try arena.allocator().alloc(u8, raw_len);
    try dec.decode(raw, b64);
    try testing.expectError(error.TypeMismatch, decodeProps(u32, raw, arena.allocator()));
}
