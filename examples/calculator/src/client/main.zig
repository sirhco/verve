//! Calculator wasm client. Single-line display, two registers, one
//! pending op. The bridge maps z-on-click="digit_5" to exp.digit_5
//! (etc.); each export updates state and re-emits the display via
//! `set_text_by_bind`.
//!
//! Supports add / subtract / multiply / divide and rejects division
//! by zero with an "Err" display.

const std = @import("std");
const dom = @import("dom.zig");

const HEAP_BYTES: usize = 4096;
var heap: [HEAP_BYTES]u8 = undefined;
var fba: std.heap.FixedBufferAllocator = .init(&heap);

const Op = enum { none, add, sub, mul, div };

var lhs: f64 = 0;
var current: f64 = 0;
var pending: Op = .none;
var entering_new: bool = true;
var error_state: bool = false;

const DISPLAY_BIND: []const u8 = "display";

fn emitDisplay() void {
    fba.reset();
    const alloc = fba.allocator();

    if (error_state) {
        const msg = "Err";
        dom.set_text_by_bind(DISPLAY_BIND.ptr, DISPLAY_BIND.len, msg.ptr, msg.len);
        return;
    }

    // Render with up to 10 decimals, trim trailing zeros.
    const text = std.fmt.allocPrint(alloc, "{d}", .{current}) catch return;
    dom.set_text_by_bind(DISPLAY_BIND.ptr, DISPLAY_BIND.len, text.ptr, text.len);
}

fn pushDigit(d: u8) void {
    if (error_state) clearAll();
    if (entering_new) {
        current = @floatFromInt(d);
        entering_new = false;
    } else {
        // Treat current as integer-ish until a decimal is pressed (kept
        // simple — no fractional digits in this demo).
        current = current * 10 + @as(f64, @floatFromInt(d));
    }
    emitDisplay();
}

fn applyPending() void {
    switch (pending) {
        .none => {},
        .add => current = lhs + current,
        .sub => current = lhs - current,
        .mul => current = lhs * current,
        .div => {
            if (current == 0) {
                error_state = true;
                return;
            }
            current = lhs / current;
        },
    }
}

fn pressOp(op: Op) void {
    if (error_state) clearAll();
    if (pending != .none and !entering_new) {
        applyPending();
        if (error_state) {
            emitDisplay();
            return;
        }
    }
    lhs = current;
    pending = op;
    entering_new = true;
    emitDisplay();
}

fn clearAll() void {
    lhs = 0;
    current = 0;
    pending = .none;
    entering_new = true;
    error_state = false;
}

export fn verve_hydrate() void {
    emitDisplay();
}

export fn digit_0() void {
    pushDigit(0);
}
export fn digit_1() void {
    pushDigit(1);
}
export fn digit_2() void {
    pushDigit(2);
}
export fn digit_3() void {
    pushDigit(3);
}
export fn digit_4() void {
    pushDigit(4);
}
export fn digit_5() void {
    pushDigit(5);
}
export fn digit_6() void {
    pushDigit(6);
}
export fn digit_7() void {
    pushDigit(7);
}
export fn digit_8() void {
    pushDigit(8);
}
export fn digit_9() void {
    pushDigit(9);
}

export fn op_add() void {
    pressOp(.add);
}
export fn op_sub() void {
    pressOp(.sub);
}
export fn op_mul() void {
    pressOp(.mul);
}
export fn op_div() void {
    pressOp(.div);
}

export fn op_equals() void {
    if (error_state) return;
    if (pending == .none) return;
    applyPending();
    lhs = 0;
    pending = .none;
    entering_new = true;
    emitDisplay();
}

export fn clear() void {
    clearAll();
    emitDisplay();
}
