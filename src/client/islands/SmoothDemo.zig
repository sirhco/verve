//! ScrollSmoother probe island (phase 6 demo): streams native vs
//! smoothed scroll position + smoothed velocity into signals via a
//! standalone scroll trigger's on_update callback — visualizes the
//! smoother's lag and exercises `verve_sm_get` end-to-end.

const std = @import("std");
const verve = @import("verve");

fn onTick() void {
    var nbuf: [32]u8 = undefined;
    if (std.fmt.bufPrint(&nbuf, "{d:.0}", .{verve.scrollPos()})) |s| {
        verve.signalSetStr("sm_native", s);
    } else |_| {}
    var sbuf: [32]u8 = undefined;
    if (std.fmt.bufPrint(&sbuf, "{d:.0}", .{verve.smootherY()})) |s| {
        verve.signalSetStr("sm_smooth", s);
    } else |_| {}
    var vbuf: [40]u8 = undefined;
    if (std.fmt.bufPrint(&vbuf, "{d:.0} px/s", .{verve.smootherVelocity()})) |s| {
        verve.signalSetStr("sm_vel", s);
    } else |_| {}
}

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;
    verve.registerStr("sm_native", "0");
    verve.registerStr("sm_smooth", "0");
    verve.registerStr("sm_vel", "0 px/s");
    // a whole-page trigger whose on_update fires every scroll tick
    _ = verve.scrollTrigger(.{
        .trigger = "[data-smooth-content]",
        .start = .{ .trigger = .top, .viewport = .top },
        .end = .{ .at = .{ .trigger = .bottom, .viewport = .bottom } },
    }, .{ .on_update = &onTick });
}
