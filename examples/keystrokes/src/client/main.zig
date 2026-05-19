//! Keystrokes wasm client. Demonstrates JS → wasm string passing via
//! a shared memory buffer.
//!
//! Flow:
//! - JS reads `key_buffer_ptr` / `key_buffer_len` once at boot.
//! - On every `keydown`, JS writes the UTF-8 encoding of `e.key` into
//!   the shared buffer, then calls `record_key(len)`.
//! - Wasm increments counters and re-emits the two bound elements.

const std = @import("std");
const dom = @import("dom.zig");

const KEY_BUF_LEN: usize = 32;
var key_buf: [KEY_BUF_LEN]u8 = .{0} ** KEY_BUF_LEN;
var last_key_len: usize = 0;

var total_keys: u32 = 0;

const TOTAL_BIND: []const u8 = "total";
const LAST_BIND: []const u8 = "last";

fn emit() void {
    dom.set_text_by_bind_i32(TOTAL_BIND.ptr, TOTAL_BIND.len, @intCast(total_keys));
    if (last_key_len == 0) {
        const placeholder = "(none)";
        dom.set_text_by_bind(LAST_BIND.ptr, LAST_BIND.len, placeholder.ptr, placeholder.len);
    } else {
        dom.set_text_by_bind(LAST_BIND.ptr, LAST_BIND.len, &key_buf, last_key_len);
    }
}

export fn verve_hydrate() void {
    emit();
}

export fn key_buffer_ptr() [*]u8 {
    return &key_buf;
}

export fn key_buffer_len() usize {
    return KEY_BUF_LEN;
}

/// Called from JS after it writes the UTF-8 encoding of the latest key
/// into the buffer. `len` is the number of bytes written; everything
/// beyond is ignored.
export fn record_key(len: usize) void {
    last_key_len = @min(len, KEY_BUF_LEN);
    total_keys +%= 1;
    emit();
}

export fn reset_count() void {
    total_keys = 0;
    last_key_len = 0;
    emit();
}
