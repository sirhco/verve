//! Phase 22 — chunk-local arena + drag-drop staging.
//!
//! Per-island chunks had no allocator, so they pre-sized worst-case
//! static buffers. This is a bump region in the main client that chunks
//! allocate from via the `verve_chunk_*` externs (wrapped as a
//! `std.mem.Allocator` in `island_runtime.zig`). Chunks `mark()` at the
//! top of a dispatch and `reset(mark)` at the end, so the region recycles
//! instead of growing per call.
//!
//! Drag-drop reuses the same region: the bridge writes the dropped
//! file's bytes into an arena allocation, stages its name, and fires the
//! chunk's handler, which reads both back through `drop*`.

const std = @import("std");

/// 256 KB bump region shared by every chunk. Lives in the main client's
/// static data; chunks address into it through the returned pointers.
var arena_buf: [256 * 1024]u8 align(16) = undefined;
var arena_top: usize = 0;

/// Bump-allocate `len` bytes aligned to `alignment`. Returns the memory
/// address or 0 when the region is exhausted. The wasm export truncates
/// the address to u32 (valid on wasm32); the value stays `usize` here so
/// native unit tests don't overflow on 64-bit static addresses.
pub fn alloc(len: usize, alignment: usize) usize {
    const a: usize = @max(alignment, 1);
    const base = @intFromPtr(&arena_buf);
    const start = std.mem.alignForward(usize, base + arena_top, a);
    const new_top = (start - base) + len;
    if (new_top > arena_buf.len) return 0;
    arena_top = new_top;
    return start;
}

/// Current high-water mark — save it, then `reset` back to it to free
/// everything allocated in between.
pub fn mark() usize {
    return arena_top;
}

pub fn reset(m: usize) void {
    if (m <= arena_buf.len) arena_top = m;
}

pub fn capacity() usize {
    return arena_buf.len;
}

// ---- drag-drop staging ---------------------------------------------------

var drop_name: [512]u8 = undefined;
var drop_name_len: usize = 0;
var drop_ptr: u32 = 0;
var drop_len: u32 = 0;

pub fn setDrop(name: []const u8, ptr: u32, len: u32) void {
    const n = @min(name.len, drop_name.len);
    @memcpy(drop_name[0..n], name[0..n]);
    drop_name_len = n;
    drop_ptr = ptr;
    drop_len = len;
}

pub fn dropNameLen() u32 {
    return @intCast(drop_name_len);
}

pub fn dropName(buf: [*]u8, cap: u32) u32 {
    const n: u32 = @min(@as(u32, @intCast(drop_name_len)), cap);
    @memcpy(buf[0..n], drop_name[0..n]);
    return n;
}

pub fn dropPtr() u32 {
    return drop_ptr;
}

pub fn dropLen() u32 {
    return drop_len;
}

// ---- tests ---------------------------------------------------------------

const testing = std.testing;

test "bump alloc advances + aligns; reset rewinds" {
    arena_top = 0;
    const p1 = alloc(10, 1);
    try testing.expect(p1 != 0);
    const saved = mark();
    const p2 = alloc(64, 16);
    try testing.expect(p2 != 0);
    try testing.expectEqual(@as(usize, 0), p2 % 16); // aligned
    try testing.expect(p2 >= p1 + 10);
    reset(saved);
    const p3 = alloc(64, 16);
    try testing.expectEqual(p2, p3); // reused the freed span
    arena_top = 0;
}

test "alloc fails past capacity" {
    arena_top = 0;
    try testing.expectEqual(@as(usize, 0), alloc(capacity() + 1, 1));
    arena_top = 0;
}

test "drop staging round-trip" {
    setDrop("notes.md", 4096, 128);
    try testing.expectEqual(@as(u32, 8), dropNameLen());
    var buf: [16]u8 = undefined;
    const n = dropName(&buf, buf.len);
    try testing.expectEqualStrings("notes.md", buf[0..n]);
    try testing.expectEqual(@as(u32, 4096), dropPtr());
    try testing.expectEqual(@as(u32, 128), dropLen());
}
