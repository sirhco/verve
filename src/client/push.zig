//! Push-subscription wire helpers — pure (no JS externs) so they're unit-tested
//! on the native target via `src/client/tests.zig`. `island_runtime.pushSubscribe`
//! builds its `vervePush` host-call args here.

const std = @import("std");

/// Build the `vervePush` subscribe host-call args JSON. Carries the subscriber's
/// island `vid` so the bridge routes pushed events to THIS instance — not the
/// first `verve-island[data-name=...]` in the DOM. Without the vid, a page with
/// multiple same-name islands (or one not first in document order) delivers
/// every event to the wrong instance, whose name-keyed signals never match →
/// silent no-repaint. Returns null only if `buf` is too small.
pub fn subscribeArgs(
    buf: []u8,
    channel: []const u8,
    island: []const u8,
    export_name: []const u8,
    vid: u32,
) ?[]const u8 {
    return std.fmt.bufPrint(
        buf,
        "{{\"op\":\"sub\",\"channel\":\"{s}\",\"island\":\"{s}\",\"export\":\"{s}\",\"vid\":{d}}}",
        .{ channel, island, export_name, vid },
    ) catch null;
}

/// Build the `vervePush` unsubscribe args JSON. Carries the same `vid` as
/// `subscribeArgs` — the bridge keys subs by vid, so unsub must match the exact
/// instance's entry (two same-name islands have distinct sub keys).
pub fn unsubscribeArgs(buf: []u8, channel: []const u8, island: []const u8, vid: u32) ?[]const u8 {
    return std.fmt.bufPrint(
        buf,
        "{{\"op\":\"unsub\",\"channel\":\"{s}\",\"island\":\"{s}\",\"vid\":{d}}}",
        .{ channel, island, vid },
    ) catch null;
}

const testing = std.testing;

test "subscribeArgs carries the vid for per-instance routing" {
    var buf: [256]u8 = undefined;
    const a = subscribeArgs(&buf, "viz", "Graph", "apply", 3).?;
    try testing.expect(std.mem.indexOf(u8, a, "\"op\":\"sub\"") != null);
    try testing.expect(std.mem.indexOf(u8, a, "\"channel\":\"viz\"") != null);
    try testing.expect(std.mem.indexOf(u8, a, "\"island\":\"Graph\"") != null);
    try testing.expect(std.mem.indexOf(u8, a, "\"export\":\"apply\"") != null);
    try testing.expect(std.mem.indexOf(u8, a, "\"vid\":3") != null);
}

test "subscribeArgs distinct vids → distinct args (two instances of one island)" {
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    const a1 = subscribeArgs(&b1, "ch", "Probe", "apply", 1).?;
    const a2 = subscribeArgs(&b2, "ch", "Probe", "apply", 2).?;
    try testing.expect(!std.mem.eql(u8, a1, a2));
    try testing.expect(std.mem.indexOf(u8, a1, "\"vid\":1") != null);
    try testing.expect(std.mem.indexOf(u8, a2, "\"vid\":2") != null);
}

test "subscribeArgs returns null when buffer too small" {
    var tiny: [8]u8 = undefined;
    try testing.expect(subscribeArgs(&tiny, "viz", "Graph", "apply", 3) == null);
}

test "unsubscribeArgs carries the vid to match the sub key" {
    var buf: [128]u8 = undefined;
    const a = unsubscribeArgs(&buf, "viz", "Graph", 2).?;
    try testing.expect(std.mem.indexOf(u8, a, "\"op\":\"unsub\"") != null);
    try testing.expect(std.mem.indexOf(u8, a, "\"island\":\"Graph\"") != null);
    try testing.expect(std.mem.indexOf(u8, a, "\"vid\":2") != null);
}
