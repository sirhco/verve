//! Multi-instance push probe — the regression island for the P7 push-routing
//! fix. Two `<verve-island data-name="PushProbe">` on one page each register a
//! vid-scoped `probe` str signal (bound to their own `[data-vh="probe__v{vid}"]`)
//! and subscribe to the shared "viz" push channel with THEIR vid. Each pushed
//! frame must update EACH instance's own signal — pre-fix the bridge resolved
//! the target by `querySelector` (first DOM match), so only the first instance
//! repainted; with the vid threaded through, both do. Drives the `/push-multi`
//! demo.

const std = @import("std");
const verve = @import("verve");

var seq: u32 = 0; // shared liveness counter (per-page, not per-instance)

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    // registerStr / pushSubscribe are vid-scoped via the runtime's
    // current_island_id (set for this hydrate), so each instance owns its
    // "probe" signal. Pass root_id so the bridge routes pushed frames back here.
    verve.registerStr("probe", "init");
    _ = verve.pushSubscribe("viz", "PushProbe", "probe_apply", root_id);
}

/// Push-channel callback: the bridge selects THIS instance (by the vid stored at
/// subscribe) before calling, so `signalSetStr` resolves this instance's signal.
export fn probe_apply(ptr: u32, len: u32) void {
    _ = ptr;
    _ = len;
    seq += 1;
    var buf: [24]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf, "GOT {d}", .{seq}) catch "GOT";
    verve.signalSetStr("probe", txt);
}
