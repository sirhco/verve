//! FLIP gallery island: shuffle reorders the keyed cards through the
//! reconciler and FLIP-animates the moves; remove/restore drops or
//! re-inserts the last card, exercising the enter/leave callbacks and
//! the entered-element fade-in path.

const std = @import("std");
const verve = @import("verve");

/// Island vid from hydrate — needed to vid-suffix bind names for
/// listDiff (signals auto-scope; the keyed reconciler does NOT).
var island_vid: u32 = 0;

var keys = [8][]const u8{ "g1", "g2", "g3", "g4", "g5", "g6", "g7", "g8" };
/// How many of `keys` are currently in the DOM (the remove/restore
/// toggle drops/re-adds the last one).
var count: usize = 8;
var rng_state: u32 = 0x9e3779b9;

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    island_vid = root_id;
    verve.registerStr("g_status", "ready");
}

fn xorshift() u32 {
    var x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng_state = x;
    return x;
}

/// listDiff bind names are NOT vid-scoped automatically — the SSR
/// rewrote this island's z-bind to "gallery_list__v<vid>", so suffix it
/// ourselves.
fn bindName(buf: []u8) ?[]const u8 {
    if (island_vid == 0) return "gallery_list";
    return std.fmt.bufPrint(buf, "gallery_list__v{d}", .{island_vid}) catch null;
}

fn onSettled() void {
    verve.signalSetStr("g_status", "settled");
}

fn onEntered() void {
    verve.signalSetStr("g_status", "card entered (fading in)");
}

fn onLeft() void {
    verve.signalSetStr("g_status", "card left");
}

export fn gal_shuffle() void {
    const state = verve.flipCapture(".gal-grid .gcard") orelse return;

    var old: [8][]const u8 = undefined;
    @memcpy(old[0..count], keys[0..count]);
    // Fisher-Yates over the present keys — all keys persist, so listDiff
    // plans moves only and the html slices are never read.
    var i: usize = count - 1;
    while (i > 0) : (i -= 1) {
        const j = xorshift() % @as(u32, @intCast(i + 1));
        const tmp = keys[i];
        keys[i] = keys[j];
        keys[j] = tmp;
    }
    const empty_html = [8][]const u8{ "", "", "", "", "", "", "", "" };
    var bind_buf: [48]u8 = undefined;
    const bind = bindName(&bind_buf) orelse return;
    verve.listDiff(bind, old[0..count], keys[0..count], empty_html[0..count]);

    if (verve.flipPlay(state, .{
        .duration = 0.45,
        .ease = .out_cubic,
        .stagger = 0.015,
    }, .{ .on_complete = &onSettled }) == null) return;
    verve.signalSetStr("g_status", "shuffling…");
}

export fn gal_toggle() void {
    const state = verve.flipCapture(".gal-grid .gcard") orelse return;

    var old: [8][]const u8 = undefined;
    @memcpy(old[0..count], keys[0..count]);
    var html = [8][]const u8{ "", "", "", "", "", "", "", "" };

    if (count == 8) {
        count = 7;
    } else {
        // restore: the insert op needs the card's HTML
        count = 8;
        var hbuf: [96]u8 = undefined;
        const k = keys[7];
        html[7] = std.fmt.bufPrint(
            &hbuf,
            "<div class=\"chip gcard\" data-vkey=\"{s}\">{s}</div>",
            .{ k, k[1..] },
        ) catch return;
    }

    var bind_buf: [48]u8 = undefined;
    const bind = bindName(&bind_buf) orelse return;
    const old_count: usize = if (count == 7) 8 else 7;
    verve.listDiff(bind, old[0..old_count], keys[0..count], html[0..count]);

    _ = verve.flipPlay(state, .{
        .duration = 0.4,
        .ease = .out_cubic,
        .stagger = 0.01,
    }, .{ .on_enter = &onEntered, .on_leave = &onLeft });
}
