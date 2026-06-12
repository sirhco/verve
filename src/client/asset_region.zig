//! Dedicated region for fetched GPU assets (.vmesh/.venv). The 256KB chunk
//! arena recycles per-dispatch; GPU assets must instead live for the whole
//! page (context-restore re-upload reads them back). Ownership: page-scoped —
//! the page's single stateful gl island calls reset() in hydrate(); the next
//! page's island reclaims everything. No per-allocation free (bump-only).
//!
//! Memory note: this is a static region — it raises the main client wasm
//! memory floor by `region_capacity`. Single tuning knob; demo peak ~1.2 MB.

const std = @import("std");

/// 4 MB bump region for GPU assets. Lives in the main client's static data;
/// callers address into it through the returned pointers (wasm linear-memory
/// address). The value stays `usize` here so native unit tests don't overflow
/// on 64-bit static addresses.
pub const region_capacity: usize = 4 * 1024 * 1024;

var region_buf: [region_capacity]u8 align(16) = undefined;
var region_top: usize = 0;

/// Bump-allocate `len` bytes aligned to `alignment`. Returns the wasm
/// linear-memory address of the allocation, or 0 when the region is exhausted.
/// alignment=0 is treated as 1 (no alignment requirement).
/// Non-power-of-2 alignments are forwarded to alignForward as-is (mirrors
/// chunk_arena behaviour).
pub fn alloc(len: usize, alignment: usize) usize {
    const a: usize = @max(alignment, 1);
    const base = @intFromPtr(&region_buf);
    const start = std.mem.alignForward(usize, base + region_top, a);
    const new_top = (start - base) + len;
    if (new_top > region_buf.len) return 0;
    region_top = new_top;
    return start;
}

/// Reset the region to empty — frees all GPU asset allocations.
/// Call ONLY from the page's single stateful gl island's hydrate().
pub fn reset() void {
    region_top = 0;
}

pub fn used() usize {
    return region_top;
}

pub fn capacity() usize {
    return region_buf.len;
}

// ---- tests ---------------------------------------------------------------

const testing = std.testing;

test "bump alloc advances + aligns; reset reclaims all" {
    region_top = 0;
    const p1 = alloc(100, 1);
    try testing.expect(p1 != 0);
    try testing.expectEqual(@as(usize, 100), used());
    const p2 = alloc(64, 16);
    try testing.expect(p2 != 0);
    try testing.expectEqual(@as(usize, 0), p2 % 16); // aligned to 16
    try testing.expect(p2 >= p1 + 100);
    reset();
    try testing.expectEqual(@as(usize, 0), used());
    // after reset the region gives back the same address as the first alloc
    const p3 = alloc(64, 16);
    try testing.expectEqual(p1 & ~@as(usize, 15), p3 & ~@as(usize, 15));
    region_top = 0;
}

test "alloc alignment=0 treated as 1" {
    region_top = 0;
    const p = alloc(8, 0);
    try testing.expect(p != 0);
    region_top = 0;
}

test "alloc fails when exhausted; returns 0" {
    region_top = 0;
    try testing.expectEqual(@as(usize, 0), alloc(capacity() + 1, 1));
    region_top = 0;
}

test "capacity is 4 MB" {
    try testing.expectEqual(@as(usize, 4 * 1024 * 1024), capacity());
}

test "reset is all-or-nothing — no partial reset" {
    region_top = 0;
    _ = alloc(1024, 1);
    _ = alloc(2048, 4);
    reset();
    try testing.expectEqual(@as(usize, 0), used());
    region_top = 0;
}
