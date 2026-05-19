//! Stopwatch wasm client. State lives entirely in the wasm module;
//! the page is just chrome with z-on-click buttons and one
//! z-bind="display" target. The JS bridge calls `tick(dt_ms)` from
//! a setInterval loop; everything else flows through wasm exports.

const std = @import("std");
const dom = @import("dom.zig");

const HEAP_BYTES: usize = 4096;
var heap: [HEAP_BYTES]u8 = undefined;
var fba: std.heap.FixedBufferAllocator = .init(&heap);

var elapsed_ms: u32 = 0;
var running: bool = false;

const DISPLAY_BIND: []const u8 = "display";

fn emitDisplay() void {
    fba.reset();
    const alloc = fba.allocator();

    const total_ms = elapsed_ms;
    const minutes = total_ms / 60_000;
    const seconds = (total_ms / 1_000) % 60;
    const millis = total_ms % 1_000;

    const text = std.fmt.allocPrint(alloc, "{d:0>2}:{d:0>2}.{d:0>3}", .{ minutes, seconds, millis }) catch return;
    dom.set_text_by_bind(DISPLAY_BIND.ptr, DISPLAY_BIND.len, text.ptr, text.len);
}

export fn verve_hydrate() void {
    emitDisplay();
}

/// Bridge calls this from setInterval. dt_ms is the elapsed time since
/// the previous call (or 0 on the first call after a reset).
export fn tick(dt_ms: u32) void {
    if (!running) return;
    elapsed_ms +%= dt_ms;
    emitDisplay();
}

export fn start_stopwatch() void {
    running = true;
}

export fn stop_stopwatch() void {
    running = false;
}

export fn reset_stopwatch() void {
    running = false;
    elapsed_ms = 0;
    emitDisplay();
}

export fn is_running() i32 {
    return if (running) 1 else 0;
}
