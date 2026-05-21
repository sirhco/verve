//! Phase 12F — per-frame scratch allocator.
//!
//! Sits alongside the main client bump allocator. Long-lived data
//! (Owner, Signals, ForEachHandle key cache) keeps living on
//! `client/allocator.zig`; ephemeral data inside an effect body —
//! reconciler ops lists, fresh keys + HTML strings — comes from here
//! and is wiped via `reset()` between effect re-runs. The two regions
//! cannot alias, so resetting scratch never disturbs the reactive
//! graph on the main heap.
//!
//! Sized as a fixed 256 KB static buffer. The wasm linear-memory
//! model would let us grow on demand, but a stable upper bound is
//! more useful than a creeping working set — render passes that
//! overflow are a bug we want to see, not silently absorb.

const std = @import("std");

pub const CAPACITY: usize = 256 * 1024;

var buffer: [CAPACITY]u8 align(@alignOf(usize)) = undefined;
var top: usize = 0;

const vtable: std.mem.Allocator.VTable = .{
    .alloc = alloc,
    .resize = std.mem.Allocator.noResize,
    .remap = std.mem.Allocator.noRemap,
    .free = std.mem.Allocator.noFree,
};

pub fn allocator() std.mem.Allocator {
    return .{ .ptr = undefined, .vtable = &vtable };
}

fn alloc(_: *anyopaque, len: usize, ptr_align: std.mem.Alignment, _: usize) ?[*]u8 {
    const align_bytes = ptr_align.toByteUnits();
    const base = @intFromPtr(&buffer);
    const aligned = std.mem.alignForward(usize, base + top, align_bytes);
    const new_top = (aligned - base) + len;
    if (new_top > buffer.len) return null;
    top = new_top;
    return @ptrFromInt(aligned);
}

/// Rewind the bump pointer. Caller asserts every allocation handed
/// out since the last `reset()` is dead.
pub fn reset() void {
    top = 0;
}

pub fn bytesUsed() usize {
    return top;
}

pub fn capacityBytes() usize {
    return buffer.len;
}

// ---- tests ---------------------------------------------------------------

const testing = std.testing;

test "alloc + reset cycles the buffer" {
    reset();
    const a = allocator();

    const slot1 = try a.alloc(u8, 1024);
    @memset(slot1, 0xab);
    try testing.expect(bytesUsed() >= 1024);

    reset();
    try testing.expectEqual(@as(usize, 0), bytesUsed());

    // After reset, the same byte range is handed back out.
    const slot2 = try a.alloc(u8, 1024);
    @memset(slot2, 0xcd);
    try testing.expectEqual(slot1.ptr, slot2.ptr);
}

test "overflow returns OutOfMemory" {
    reset();
    const a = allocator();
    const result = a.alloc(u8, CAPACITY + 1);
    try testing.expectError(error.OutOfMemory, result);
}

test "alignment is honored" {
    reset();
    const a = allocator();
    _ = try a.alloc(u8, 1);
    const wide = try a.alloc(u64, 4);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(wide.ptr) % @alignOf(u64));
}
