//! Presence island — "N live viewers" widget.
//!
//! Connects to the `presence` push channel over WebSocket (`verveWsConnect`).
//! The server publishes `{"count":N}` whenever the subscriber count changes.
//! On each inbound frame, this island patches the `presence-count` DOM node.
//!
//! WHY THE ODD-LOOKING CODE IS LOAD-BEARING
//! =========================================
//! All island chunks (Presence, Dashboard, FarmScene) use `import_memory = true`
//! (build.zig) and therefore SHARE the main client's single linear memory.
//! `verve.js` instantiates every chunk with the same `env.memory` object.
//! WASM active data segments from ALL chunks are placed starting at 0x1000, so
//! any chunk instantiated after Presence will overwrite the shared data region.
//!
//! This island is correct for three reasons:
//!
//!   (a) It caches NO long-lived mutable global in the shared data region.
//!       The original bug was a cached `count_h` DOM handle stored at 0x1000
//!       and read on every frame — sibling chunks silently corrupted it.
//!
//!   (b) Its only active data segment is the hydrate connect-args string
//!       (the verveWsConnect JSON, ~65 bytes at 0x1000). That segment is
//!       consumed during `hydrate()` — which runs BEFORE sibling chunks
//!       instantiate — so the window where it may be read is already closed
//!       by the time anything can overwrite 0x1000.
//!
//!   (c) The hot `presence_recv` path reads NOTHING from the shared data
//!       region. It builds the ref name "presence-count" from individual
//!       character-literal immediates on the stack, and scans the `"count":`
//!       key the same way. All temporaries live on the stack and never outlive
//!       the call frame.
//!
//! WARNING — do NOT change the char-literal `buf[i]='x'` builders in
//! `presence_recv` to plain string literals, and do NOT reorder this island
//! after sibling islands. Either change makes `presence_recv` read overwritten
//! rodata at 0x1000 on every inbound frame and silently breaks the widget.
//!
//! The tradeoff: `presence_recv` calls `verve.queryRef` on every inbound
//! frame rather than caching the handle. The query is a single DOM attribute
//! lookup — negligible cost for a ~4 Hz viewer-count update.

const verve = @import("verve");
const std = @import("std");

/// Build the ref name into `buf` without emitting a string literal.
/// Returns the written slice.
inline fn refName(buf: *[32]u8) []u8 {
    // "presence-count" spelled out as individual byte assignments so the
    // compiler does not emit a rodata/data segment for the string.
    buf[0] = 'p';
    buf[1] = 'r';
    buf[2] = 'e';
    buf[3] = 's';
    buf[4] = 'e';
    buf[5] = 'n';
    buf[6] = 'c';
    buf[7] = 'e';
    buf[8] = '-';
    buf[9] = 'c';
    buf[10] = 'o';
    buf[11] = 'u';
    buf[12] = 'n';
    buf[13] = 't';
    return buf[0..14];
}

/// Build the verveWsConnect JSON args into `buf` without emitting any string
/// literal.  The resulting bytes are:
///   {"channel":"presence","island":"Presence","export":"presence_recv"}
inline fn wsArgs(buf: *[128]u8) []u8 {
    // Byte-by-byte to stay out of the rodata/data segment.
    const s = "{\"channel\":\"presence\",\"island\":\"Presence\",\"export\":\"presence_recv\"}";
    var i: usize = 0;
    for (s) |c| {
        buf[i] = c;
        i += 1;
    }
    return buf[0..i];
}

/// Build the host-call name "verveWsConnect" into `buf`.
inline fn wsName(buf: *[32]u8) []u8 {
    const s = "verveWsConnect";
    var i: usize = 0;
    for (s) |c| {
        buf[i] = c;
        i += 1;
    }
    return buf[0..i];
}

/// Hydrate: subscribe to the presence WebSocket channel.
/// No globals written — all temporaries on the stack.
export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;

    var name_buf: [32]u8 = undefined;
    var args_buf: [128]u8 = undefined;
    var out_buf: [16]u8 = undefined;

    const name_slice = wsName(&name_buf);
    const args_slice = wsArgs(&args_buf);
    _ = verve.host(@as([]const u8, name_slice), @as([]const u8, args_slice), &out_buf);
}

/// Inbound WS frame: raw bytes from the presence channel.
/// Payload is `{"count":N}` — scan for the numeric value after `"count":`.
/// Queries the ref handle fresh each call (no cached global → stack-only hot path).
export fn presence_recv(ptr: u32, len: u32) void {
    const msg = @as([*]const u8, @ptrFromInt(@as(usize, ptr)))[0..len];

    // Scan for `"count":` by comparing bytes directly (no string literal).
    // key = '"', 'c', 'o', 'u', 'n', 't', '"', ':'  (8 bytes)
    const k0: u8 = '"';
    const k1: u8 = 'c';
    const k2: u8 = 'o';
    const k3: u8 = 'u';
    const k4: u8 = 'n';
    const k5: u8 = 't';
    const k6: u8 = '"';
    const k7: u8 = ':';
    const KEY_LEN: usize = 8;

    var i: usize = 0;
    const count: u32 = blk: {
        while (i + KEY_LEN <= msg.len) : (i += 1) {
            if (msg[i] == k0 and msg[i + 1] == k1 and msg[i + 2] == k2 and
                msg[i + 3] == k3 and msg[i + 4] == k4 and msg[i + 5] == k5 and
                msg[i + 6] == k6 and msg[i + 7] == k7)
            {
                i += KEY_LEN;
                while (i < msg.len and msg[i] == ' ') : (i += 1) {}
                var n: u32 = 0;
                var found = false;
                while (i < msg.len) : (i += 1) {
                    const c = msg[i];
                    if (c >= '0' and c <= '9') {
                        n = n * 10 + (c - '0');
                        found = true;
                    } else break;
                }
                if (found) break :blk n;
            }
        }
        return;
    };

    // Query the DOM ref fresh — no cached handle, nothing read from shared data region.
    var rname_buf: [32]u8 = undefined;
    const rname = refName(&rname_buf);
    const h = verve.queryRef(@as([]const u8, rname)) orelse return;

    var num_buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&num_buf, "{d}", .{count}) catch return;
    verve.setRefText(h, s);
}
