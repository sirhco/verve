//! Growable bump allocator for the wasm32-freestanding client.
//!
//! Wasm has no `malloc` and no syscalls; the linear-memory model gives
//! us `@wasmMemoryGrow` to add 64 KB pages on demand. This allocator
//! bumps a high-water mark inside the current memory, growing memory
//! when the mark would otherwise overflow. `reset()` rewinds the mark
//! in O(1).
//!
//! Native builds (test runs, server-side wasm-target unit tests) fall
//! back to a static 1 MB buffer since `@wasmMemoryGrow` is wasm-only.

const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.target.cpu.arch.isWasm();

/// 1 page = 64 KB per the wasm spec.
const PAGE_BYTES: usize = 64 * 1024;
/// Hard ceiling, used as both the upper bound for `@wasmMemoryGrow` and
/// the size of the native fallback buffer.
pub const MAX_HEAP: usize = 16 * 1024 * 1024;

/// Wasm: address inside linear memory immediately after the last byte
/// the host has reserved for static data. Bumps grow upward from here.
/// Native: an offset into the static fallback buffer below.
var heap_base: usize = 0;
var heap_top: usize = 0;
var heap_end: usize = 0;

/// Native fallback. Bigger than the wasm initial allocation since the
/// native build doesn't grow on demand.
var native_buf: [MAX_HEAP]u8 align(@alignOf(usize)) = undefined;

/// Lazily initialize the heap on first allocation. On wasm we anchor at
/// the end of statically-reserved memory; on native we point at the
/// fallback buffer.
fn ensureInit() void {
    if (heap_end != 0) return;
    if (is_wasm) {
        const cur_pages = @wasmMemorySize(0);
        heap_base = cur_pages * PAGE_BYTES;
        heap_top = heap_base;
        heap_end = heap_base;
    } else {
        heap_base = @intFromPtr(&native_buf);
        heap_top = heap_base;
        heap_end = heap_base + native_buf.len;
    }
}

const vtable: std.mem.Allocator.VTable = .{
    .alloc = alloc,
    .resize = std.mem.Allocator.noResize,
    .remap = std.mem.Allocator.noRemap,
    .free = std.mem.Allocator.noFree,
};

pub fn allocator() std.mem.Allocator {
    ensureInit();
    return .{ .ptr = undefined, .vtable = &vtable };
}

fn alloc(_: *anyopaque, len: usize, ptr_align: std.mem.Alignment, _: usize) ?[*]u8 {
    ensureInit();
    const align_bytes = ptr_align.toByteUnits();
    const aligned = std.mem.alignForward(usize, heap_top, align_bytes);
    const new_top = aligned + len;

    if (new_top > heap_end) {
        if (!grow(new_top)) return null;
    }
    heap_top = new_top;
    return @ptrFromInt(aligned);
}

/// Grow until `heap_end >= needed`. Returns false when growth fails
/// (wasm host refuses, or native fallback is too small).
fn grow(needed: usize) bool {
    if (is_wasm) {
        if (needed > heap_base + MAX_HEAP) return false;
        const cur_bytes = heap_end - heap_base;
        const additional = needed - heap_base - cur_bytes;
        const pages = (additional + PAGE_BYTES - 1) / PAGE_BYTES;
        const prev = @wasmMemoryGrow(0, @intCast(pages));
        if (prev == -1) return false;
        heap_end += pages * PAGE_BYTES;
        return heap_end >= needed;
    }
    // Native fallback is fixed-size.
    return false;
}

/// Drop every live allocation in O(1) — rewind the bump pointer. Memory
/// is not returned to the wasm host (would require `@wasmMemoryGrow(-N)`
/// which the runtime does not support).
pub fn reset() void {
    heap_top = heap_base;
}

pub fn bytesUsed() usize {
    if (heap_end == 0) return 0;
    return heap_top - heap_base;
}

pub fn capacity() usize {
    if (heap_end == 0) return if (is_wasm) 0 else MAX_HEAP;
    return heap_end - heap_base;
}

test "allocator returns a usable std.mem.Allocator" {
    reset();
    const gpa = allocator();
    const buf = try gpa.alloc(u8, 128);
    @memset(buf, 0xab);
    try std.testing.expect(bytesUsed() >= 128);
    try std.testing.expect(capacity() > 0);
    reset();
    try std.testing.expectEqual(@as(usize, 0), bytesUsed());
}

test "allocator handles allocations > initial-page-size" {
    reset();
    const gpa = allocator();
    // Allocate something larger than the initial 16KB cap to confirm
    // growth (native build uses fallback buffer instead of growing).
    const buf = try gpa.alloc(u8, 64 * 1024);
    @memset(buf, 0xcd);
    try std.testing.expect(bytesUsed() >= 64 * 1024);
    reset();
}
