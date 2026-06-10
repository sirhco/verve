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
//! Target `data-*` attributes are staged as a JSON object and parsed by
//! the shared JSON service (`json_service.zig`) — one parser, reachable
//! from chunks, no per-chunk scanner.

const std = @import("std");
const json_service = @import("json_service.zig");

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
var dataset_doc: u32 = 0;
var flags: u32 = 0;

/// Reset state for a fresh event. Frees any dataset doc held from the
/// previous dispatch (defensive — `end` normally clears it).
pub fn begin() void {
    if (dataset_doc != 0) {
        json_service.free(dataset_doc);
        dataset_doc = 0;
    }
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
    if (dataset_doc != 0) json_service.free(dataset_doc);
    dataset_doc = json_service.parse(json);
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

/// Copy `dataset[name]` (string-coerced) into `buf`; returns bytes
/// written. 0 when there's no dataset, no such key, or a non-string.
pub fn targetAttr(name: []const u8, buf: [*]u8, cap: u32) u32 {
    if (dataset_doc == 0) return 0;
    const child = json_service.objGet(dataset_doc, name);
    if (child == 0) return 0;
    return json_service.asStr(child, buf, cap);
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

/// Release the dataset doc after dispatch completes.
pub fn end() void {
    if (dataset_doc != 0) {
        json_service.free(dataset_doc);
        dataset_doc = 0;
    }
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
    // missing key → 0
    try testing.expectEqual(@as(u32, 0), targetAttr("nope", &buf, buf.len));
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
