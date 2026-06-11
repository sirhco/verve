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

/// `{"d":0.4,"e":"outCubic","sc":0,"st":0,"fade":1[,"cb":{"sC":N}]}`
pub fn optsToJson(buf: []u8, o: FlipOpts, complete_slot: ?u32) ![]const u8 {
    if (complete_slot) |s| {
        return std.fmt.bufPrint(
            buf,
            "{{\"d\":{d},\"e\":\"{s}\",\"sc\":{d},\"st\":{d},\"fade\":{d},\"cb\":{{\"sC\":{d}}}}}",
            .{ o.duration, o.ease.wireName(), @intFromBool(o.scale), o.stagger, @intFromBool(o.fade_in), s },
        );
    }
    return std.fmt.bufPrint(
        buf,
        "{{\"d\":{d},\"e\":\"{s}\",\"sc\":{d},\"st\":{d},\"fade\":{d}}}",
        .{ o.duration, o.ease.wireName(), @intFromBool(o.scale), o.stagger, @intFromBool(o.fade_in) },
    );
}

test "optsToJson goldens" {
    var buf: [160]u8 = undefined;

    try std.testing.expectEqualStrings(
        "{\"d\":0.4,\"e\":\"outCubic\",\"sc\":0,\"st\":0,\"fade\":1}",
        try optsToJson(&buf, .{}, null),
    );

    try std.testing.expectEqualStrings(
        "{\"d\":0.45,\"e\":\"inOutSine\",\"sc\":1,\"st\":0.015,\"fade\":0,\"cb\":{\"sC\":12}}",
        try optsToJson(&buf, .{
            .duration = 0.45,
            .ease = .in_out_sine,
            .scale = true,
            .stagger = 0.015,
            .fade_in = false,
        }, 12),
    );
}
