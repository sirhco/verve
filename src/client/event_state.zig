//! Phase 18 — current-event state for the main client.
//!
//! The closure-event delegate (`src/bridge/verve.js`) only carried a
//! slot id into wasm — handlers saw no key, modifiers, pointer
//! coordinates, or target attributes. This module holds the dispatching
//! event's data: JS stages it via the `verve_event_set_*` exports just
//! before `verve_event_dispatch(id)`, the handler reads it through the
//! `verve_event_*` accessors during dispatch, and JS reads back the
//! prevent/stop flags afterward.
//!
//! Target `data-*` attributes are staged as a flat JSON object
//! (`{"key":"value",…}`, always string-valued — they are DOM `data-*`
//! attributes). A tiny hand-rolled scanner reads a key's value on demand
//! (`targetAttr`) instead of building a parse tree. This deliberately
//! avoids `std.json` on this hot path: under `--import-table` (the main
//! client imports its indirect function table) a `std.json.parseFromSlice`
//! over a runtime slice traps with "null function" — an address-taken
//! parser callback whose table slot is unpopulated — which broke every
//! event dispatch on pages whose handler element carries a `data-*`
//! attribute (e.g. the gl canvas's `data-ref`). A flat scanner uses no
//! function pointers and no allocator.

const std = @import("std");

/// Modifier bit layout shared with the JS bridge + the chunk-side
/// `Mods` packed struct: bit0 meta, bit1 ctrl, bit2 shift, bit3 alt.
pub const MOD_META: u32 = 1 << 0;
pub const MOD_CTRL: u32 = 1 << 1;
pub const MOD_SHIFT: u32 = 1 << 2;
pub const MOD_ALT: u32 = 1 << 3;

const FLAG_PREVENT: u32 = 1 << 0;
const FLAG_STOP: u32 = 1 << 1;
const FLAG_CAPTURE: u32 = 1 << 2;

var mods: u32 = 0;
var coord_x: f64 = 0;
var coord_y: f64 = 0;
var delta_y: f64 = 0;
var button: i32 = -1;
var key_buf: [64]u8 = undefined;
var key_len: usize = 0;
/// Raw staged dataset JSON (`{"k":"v",…}`). Scanned on demand by `targetAttr`.
var dataset_buf: [4096]u8 = undefined;
var dataset_len: usize = 0;
var flags: u32 = 0;

/// Reset state for a fresh event. Frees any dataset doc held from the
/// previous dispatch (defensive — `end` normally clears it).
pub fn begin() void {
    dataset_len = 0;
    mods = 0;
    coord_x = 0;
    coord_y = 0;
    delta_y = 0;
    button = -1;
    key_len = 0;
    flags = 0;
}

pub fn setMods(m: u32) void {
    mods = m;
}

pub fn setCoords(x: f64, y: f64) void {
    coord_x = x;
    coord_y = y;
}

pub fn setScroll(d: f64) void {
    delta_y = d;
}

pub fn setButton(b: i32) void {
    button = b;
}

pub fn setKey(s: []const u8) void {
    const n = @min(s.len, key_buf.len);
    @memcpy(key_buf[0..n], s[0..n]);
    key_len = n;
}

/// Parse the target element's `dataset` (a JSON object) for later
/// `targetAttr` lookups. A parse failure leaves no doc — `targetAttr`
/// then returns empty.
pub fn setDataset(json: []const u8) void {
    const n = @min(json.len, dataset_buf.len);
    @memcpy(dataset_buf[0..n], json[0..n]);
    dataset_len = n;
}

pub fn getMods() u32 {
    return mods;
}

pub fn coordX() f64 {
    return coord_x;
}

pub fn coordY() f64 {
    return coord_y;
}

pub fn scrollDeltaY() f64 {
    return delta_y;
}

pub fn buttonId() i32 {
    return button;
}

pub fn keySlice() []const u8 {
    return key_buf[0..key_len];
}

/// Copy `dataset[name]`'s (string) value into `buf`; returns bytes
/// written (truncated to `cap`). 0 when there's no dataset, no such key,
/// or the value isn't a JSON string. Scans the flat staged object
/// directly — no parse tree, no allocator, no function pointers.
pub fn targetAttr(name: []const u8, buf: [*]u8, cap: u32) u32 {
    if (dataset_len == 0) return 0;
    return flatObjectGet(dataset_buf[0..dataset_len], name, buf, cap);
}

/// Read one JSON string starting at `src[i]` (which must be `"`). Unescapes
/// into `out` (up to `out.len`; excess is parsed but dropped so the cursor
/// still lands past the closing quote). Returns the index just past the
/// closing quote and the number of bytes written, or null on malformed
/// input / premature end.
fn readJsonString(src: []const u8, i_in: usize, out: []u8) ?struct { next: usize, len: usize } {
    if (i_in >= src.len or src[i_in] != '"') return null;
    var i = i_in + 1;
    var w: usize = 0;
    const put = struct {
        fn f(o: []u8, n: *usize, c: u8) void {
            if (n.* < o.len) o[n.*] = c;
            n.* += 1;
        }
    }.f;
    while (i < src.len) {
        const c = src[i];
        if (c == '"') return .{ .next = i + 1, .len = w };
        if (c == '\\') {
            i += 1;
            if (i >= src.len) return null;
            switch (src[i]) {
                '"' => put(out, &w, '"'),
                '\\' => put(out, &w, '\\'),
                '/' => put(out, &w, '/'),
                'b' => put(out, &w, 0x08),
                'f' => put(out, &w, 0x0C),
                'n' => put(out, &w, '\n'),
                'r' => put(out, &w, '\r'),
                't' => put(out, &w, '\t'),
                'u' => {
                    if (i + 4 >= src.len) return null;
                    const cp = std.fmt.parseInt(u21, src[i + 1 .. i + 5], 16) catch return null;
                    var ub: [4]u8 = undefined;
                    const ulen = std.unicode.utf8Encode(cp, &ub) catch return null;
                    for (ub[0..ulen]) |b| put(out, &w, b);
                    i += 4;
                },
                else => return null,
            }
            i += 1;
        } else {
            put(out, &w, c);
            i += 1;
        }
    }
    return null; // unterminated
}

/// Skip a JSON string starting at `src[i]` (== `"`); returns the index past
/// the closing quote, or null if unterminated.
fn skipJsonString(src: []const u8, i_in: usize) ?usize {
    if (i_in >= src.len or src[i_in] != '"') return null;
    var i = i_in + 1;
    while (i < src.len) : (i += 1) {
        if (src[i] == '\\') {
            i += 1;
            continue;
        }
        if (src[i] == '"') return i + 1;
    }
    return null;
}

fn skipWs(src: []const u8, i_in: usize) usize {
    var i = i_in;
    while (i < src.len) : (i += 1) {
        switch (src[i]) {
            ' ', '\t', '\n', '\r' => {},
            else => return i,
        }
    }
    return i;
}

/// Find `name` as a key in a flat JSON object and copy its string value
/// into `buf`. Returns bytes written, or 0 when the key is absent or its
/// value is not a string (only string values are supported — `data-*`
/// attributes are always strings).
fn flatObjectGet(src: []const u8, name: []const u8, buf: [*]u8, cap: u32) u32 {
    var i = skipWs(src, 0);
    if (i >= src.len or src[i] != '{') return 0;
    i = skipWs(src, i + 1);
    if (i < src.len and src[i] == '}') return 0; // empty object
    var keybuf: [128]u8 = undefined;
    while (i < src.len) {
        if (src[i] != '"') return 0; // malformed key
        const kr = readJsonString(src, i, &keybuf) orelse return 0;
        const key_matches = kr.len <= keybuf.len and std.mem.eql(u8, keybuf[0..kr.len], name);
        i = skipWs(src, kr.next);
        if (i >= src.len or src[i] != ':') return 0;
        i = skipWs(src, i + 1);
        if (i >= src.len) return 0;
        if (src[i] == '"') {
            // String value.
            if (key_matches) {
                const out = buf[0..cap];
                const vr = readJsonString(src, i, out) orelse return 0;
                return @intCast(@min(vr.len, cap));
            }
            i = skipJsonString(src, i) orelse return 0;
        } else {
            // Non-string value (number/bool/null/object/array). The key, if
            // matched, has no string value → 0. Skip to the next `,`/`}` at
            // depth 0 (string-aware so braces inside strings don't fool us).
            if (key_matches) return 0;
            var depth: i32 = 0;
            while (i < src.len) {
                const c = src[i];
                if (c == '"') {
                    i = skipJsonString(src, i) orelse return 0;
                    continue;
                }
                if (c == '{' or c == '[') depth += 1;
                if (c == '}' or c == ']') {
                    if (depth == 0) break;
                    depth -= 1;
                }
                if (c == ',' and depth == 0) break;
                i += 1;
            }
        }
        i = skipWs(src, i);
        if (i < src.len and src[i] == ',') {
            i = skipWs(src, i + 1);
            continue;
        }
        return 0; // end of object (or malformed) without a match
    }
    return 0;
}

pub fn setPrevent() void {
    flags |= FLAG_PREVENT;
}

pub fn setStop() void {
    flags |= FLAG_STOP;
}

/// Capture the pointer to the event target so the gesture keeps
/// receiving pointermove/up after the pointer leaves the element.
/// Released implicitly on pointerup per the Pointer Events spec.
pub fn setCapturePointer() void {
    flags |= FLAG_CAPTURE;
}

/// Flag bitmask for JS to honor after dispatch (bit0 preventDefault,
/// bit1 stopPropagation, bit2 setPointerCapture).
pub fn getFlags() u32 {
    return flags;
}

/// Clear the staged dataset after dispatch completes.
pub fn end() void {
    dataset_len = 0;
}

// ---- tests ---------------------------------------------------------------

const testing = std.testing;

test "mods / coords / key round-trip" {
    begin();
    defer end();
    setMods(MOD_META | MOD_SHIFT);
    setCoords(12.5, -3.0);
    setKey("k");

    try testing.expectEqual(MOD_META | MOD_SHIFT, getMods());
    try testing.expectEqual(@as(f64, 12.5), coordX());
    try testing.expectEqual(@as(f64, -3.0), coordY());
    try testing.expectEqualStrings("k", keySlice());
}

test "scroll delta + button round-trip and reset" {
    begin();
    defer end();
    setScroll(-120.0);
    setButton(2);
    try testing.expectEqual(@as(f64, -120.0), scrollDeltaY());
    try testing.expectEqual(@as(i32, 2), buttonId());
    begin();
    try testing.expectEqual(@as(f64, 0), scrollDeltaY());
    try testing.expectEqual(@as(i32, -1), buttonId());
}

test "oversized key truncates to buffer" {
    begin();
    defer end();
    const long = "x" ** 100;
    setKey(long);
    try testing.expectEqual(@as(usize, 64), keySlice().len);
}

test "target dataset attr lookup" {
    begin();
    defer end();
    setDataset(
        \\{"id": "note-42", "pinId": "p7"}
    );
    var buf: [32]u8 = undefined;
    const n = targetAttr("id", &buf, buf.len);
    try testing.expectEqualStrings("note-42", buf[0..n]);
    const n2 = targetAttr("pinId", &buf, buf.len);
    try testing.expectEqualStrings("p7", buf[0..n2]);
    // missing key → 0
    try testing.expectEqual(@as(u32, 0), targetAttr("nope", &buf, buf.len));
}

test "dataset: gl-style single key (the import-table std.json regression case)" {
    begin();
    defer end();
    setDataset(
        \\{"ref":"glscene-canvas__v1"}
    );
    var buf: [64]u8 = undefined;
    const n = targetAttr("ref", &buf, buf.len);
    try testing.expectEqualStrings("glscene-canvas__v1", buf[0..n]);
}

test "dataset: escaped value (quote, backslash, newline, unicode)" {
    begin();
    defer end();
    setDataset(
        \\{"a":"x\"y\\z\n", "b":"é"}
    );
    var buf: [32]u8 = undefined;
    const na = targetAttr("a", &buf, buf.len);
    try testing.expectEqualStrings("x\"y\\z\n", buf[0..na]);
    const nb = targetAttr("b", &buf, buf.len);
    try testing.expectEqualStrings("\u{00e9}", buf[0..nb]); // é → 2-byte UTF-8
}

test "dataset: empty object, non-string value, and truncation" {
    begin();
    defer end();
    setDataset("{}");
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(u32, 0), targetAttr("x", &buf, buf.len));

    setDataset(
        \\{"n": 5, "s": "ok"}
    );
    // non-string value → 0
    try testing.expectEqual(@as(u32, 0), targetAttr("n", &buf, buf.len));
    // string value after a non-string key still found
    const ns = targetAttr("s", &buf, buf.len);
    try testing.expectEqualStrings("ok", buf[0..ns]);

    // value longer than cap truncates to cap
    setDataset(
        \\{"k": "abcdefghijklmnop"}
    );
    const nt = targetAttr("k", &buf, buf.len);
    try testing.expectEqual(@as(u32, 8), nt);
    try testing.expectEqualStrings("abcdefgh", buf[0..nt]);
}

test "prevent / stop / capture flags accumulate then reset on begin" {
    begin();
    setPrevent();
    setStop();
    setCapturePointer();
    try testing.expectEqual(FLAG_PREVENT | FLAG_STOP | FLAG_CAPTURE, getFlags());
    begin();
    try testing.expectEqual(@as(u32, 0), getFlags());
    end();
}
