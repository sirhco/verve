//! Fixed-buffer allocator for the wasm32-freestanding client.
//!
//! There is no `malloc` on wasm32-freestanding, so a static heap
//! backs a `std.heap.FixedBufferAllocator`. Allocation is monotonic:
//! call `reset()` after a complete UI update cycle to reclaim the
//! buffer in one shot. Keeps the wasm binary tiny — no free list,
//! no page growth, no syscalls.

const std = @import("std");

/// 16 KB is enough for several seconds' worth of formatted strings
/// and a few small node trees. Bump if a consumer needs more; each
/// extra byte ships in every wasm binary built against this client.
pub const HEAP_SIZE: usize = 16 * 1024;

var heap: [HEAP_SIZE]u8 = undefined;
var fba: std.heap.FixedBufferAllocator = .init(&heap);

/// Returns the wasm client's owned allocator. Memory is valid until
/// the next `reset()`.
pub fn allocator() std.mem.Allocator {
    return fba.allocator();
}

/// Drop every live allocation in one O(1) operation. Call between
/// rendering passes when the previous frame's buffers are no longer
/// reachable.
pub fn reset() void {
    fba.reset();
}

pub fn bytesUsed() usize {
    return fba.end_index;
}

pub fn capacity() usize {
    return HEAP_SIZE;
}

test "allocator returns a usable std.mem.Allocator" {
    reset();
    const gpa = allocator();
    const buf = try gpa.alloc(u8, 128);
    @memset(buf, 0xab);
    try std.testing.expect(bytesUsed() >= 128);
    try std.testing.expectEqual(@as(usize, HEAP_SIZE), capacity());
    reset();
    try std.testing.expectEqual(@as(usize, 0), bytesUsed());
}

test "allocator returns OutOfMemory when the heap is exhausted" {
    reset();
    const gpa = allocator();
    // One allocation strictly larger than the heap must fail.
    try std.testing.expectError(error.OutOfMemory, gpa.alloc(u8, HEAP_SIZE + 1));
    reset();
}
