//! FLIP (First-Last-Invert-Play) options for verve.anim phase 5. The JS
//! engine owns capture (visual rects), matching (element identity, then
//! data-vkey for reconciler-recreated nodes), invert math, and the ticker
//! integrator; this file owns the play-options encoding. Ops-only
//! crossing — NOT a "v":1 wire root.
//!
//! Freestanding-safe: bufPrint into a caller buffer (chunk stack).

const std = @import("std");
const types = @import("types.zig");

pub const FlipOpts = struct {
    duration: f64 = 0.4,
    ease: types.Ease = .out_cubic,
    /// Animate width/height ratios as scaleX/scaleY. Distorts children
    /// (no nested counter-scale v1) — off by default.
    scale: bool = false,
    /// Seconds per element index (play-time DOM order).
    stagger: f64 = 0,
    /// Elements present at play but absent at capture fade in 0 -> 1.
    fade_in: bool = true,
};

/// Lifecycle callback slot ids (registerEvent — chunk-table-translated).
/// enter/leave fire synchronously INSIDE the play op, before flipPlay
/// returns; complete fires from the ticker when everything settles.
pub const FlipSlots = struct {
    complete: ?u32 = null,
    /// Fires once per play when >= 1 element exists that wasn't captured.
    enter: ?u32 = null,
    /// Fires once per play when >= 1 captured element is gone.
    leave: ?u32 = null,

    fn any(self: FlipSlots) bool {
        return self.complete != null or self.enter != null or self.leave != null;
    }
};

/// `{"d":0.4,"e":"outCubic","sc":0,"st":0,"fade":1[,"cb":{"sC":N,"sE":N,"sL":N}]}`
pub fn optsToJson(buf: []u8, o: FlipOpts, slots: FlipSlots) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.print("{{\"d\":{d},\"e\":\"{s}\",\"sc\":{d},\"st\":{d},\"fade\":{d}", .{
        o.duration,
        o.ease.wireName(),
        @intFromBool(o.scale),
        o.stagger,
        @intFromBool(o.fade_in),
    });
    if (slots.any()) {
        try w.writeAll(",\"cb\":{");
        var first = true;
        if (slots.complete) |s| {
            try w.print("\"sC\":{d}", .{s});
            first = false;
        }
        if (slots.enter) |s| {
            if (!first) try w.writeAll(",");
            try w.print("\"sE\":{d}", .{s});
            first = false;
        }
        if (slots.leave) |s| {
            if (!first) try w.writeAll(",");
            try w.print("\"sL\":{d}", .{s});
        }
        try w.writeAll("}");
    }
    try w.writeAll("}");
    return w.buffered();
}

test "optsToJson goldens" {
    var buf: [192]u8 = undefined;

    // frozen strings from phase 5 — byte-identical under the new signature
    try std.testing.expectEqualStrings(
        "{\"d\":0.4,\"e\":\"outCubic\",\"sc\":0,\"st\":0,\"fade\":1}",
        try optsToJson(&buf, .{}, .{}),
    );
    try std.testing.expectEqualStrings(
        "{\"d\":0.45,\"e\":\"inOutSine\",\"sc\":1,\"st\":0.015,\"fade\":0,\"cb\":{\"sC\":12}}",
        try optsToJson(&buf, .{
            .duration = 0.45,
            .ease = .in_out_sine,
            .scale = true,
            .stagger = 0.015,
            .fade_in = false,
        }, .{ .complete = 12 }),
    );

    // new: all three slots, fixed key order sC,sE,sL
    try std.testing.expectEqualStrings(
        "{\"d\":0.4,\"e\":\"outCubic\",\"sc\":0,\"st\":0,\"fade\":1,\"cb\":{\"sC\":1,\"sE\":2,\"sL\":3}}",
        try optsToJson(&buf, .{}, .{ .complete = 1, .enter = 2, .leave = 3 }),
    );
    // new: enter-only
    try std.testing.expectEqualStrings(
        "{\"d\":0.4,\"e\":\"outCubic\",\"sc\":0,\"st\":0,\"fade\":1,\"cb\":{\"sE\":7}}",
        try optsToJson(&buf, .{}, .{ .enter = 7 }),
    );
}
