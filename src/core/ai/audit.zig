//! Fixed-size ring of recent tool invocations. Every attempt is recorded —
//! allowed, denied, confirmed, or failed — so a host can show what a model
//! actually did, not just what it said it did.

const std = @import("std");
const tool = @import("tool.zig");

pub const Outcome = enum { allowed, denied, needs_confirmation, claim_rejected, failed };

pub const Record = struct {
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,
    risk: tool.Risk = .safe,
    outcome: Outcome = .allowed,
    args_bytes: usize = 0,

    pub fn name(self: *const Record) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

const cap = 64;
var ring: [cap]Record = @splat(.{});
var count: usize = 0;
var mu: std.atomic.Mutex = .unlocked;

fn lock() void {
    while (!mu.tryLock()) std.atomic.spinLoopHint();
}

pub fn record(name: []const u8, risk: tool.Risk, outcome: Outcome, args_bytes: usize) void {
    lock();
    defer mu.unlock();
    const slot = &ring[count % cap];
    const n = @min(name.len, slot.name_buf.len);
    // `name` is attacker-controlled on the unknown-tool path (whatever a
    // model sent, unbounded). Capping to `name_buf` already bounds it; also
    // replacing non-printable bytes here means the *only* representation of
    // it that ever reaches storage or the log has no embedded newlines to
    // forge extra log lines with, and no control bytes to bloat the log.
    for (name[0..n], 0..) |c, i| {
        slot.name_buf[i] = if (std.ascii.isPrint(c)) c else '?';
    }
    slot.name_len = n;
    slot.risk = risk;
    slot.outcome = outcome;
    slot.args_bytes = args_bytes;
    count += 1;
    // Log the sanitized, length-capped copy — never the raw `name` — so a
    // single refusal can't write unbounded or forged content to the host log.
    std.log.scoped(.verve_ai).info("tool {s} risk={s} outcome={s} args={d}B", .{
        slot.name(), @tagName(risk), @tagName(outcome), args_bytes,
    });
}

pub fn total() usize {
    lock();
    defer mu.unlock();
    return count;
}

/// Copy the most recent records (oldest first) into `out`, returning the slice
/// actually written.
pub fn recent(out: []Record) []Record {
    lock();
    defer mu.unlock();
    const n = @min(@min(count, cap), out.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        out[i] = ring[(count - n + i) % cap];
    }
    return out[0..n];
}

pub fn reset() void {
    lock();
    defer mu.unlock();
    count = 0;
}

test "audit: records are retrievable in order" {
    reset();
    record("a", .safe, .allowed, 2);
    record("b", .dangerous, .denied, 3);
    var buf: [4]Record = undefined;
    const got = recent(&buf);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("a", got[0].name());
    try std.testing.expectEqualStrings("b", got[1].name());
    try std.testing.expectEqual(Outcome.denied, got[1].outcome);
}

test "audit: ring wraps without growing" {
    reset();
    var i: usize = 0;
    while (i < cap + 5) : (i += 1) record("x", .safe, .allowed, 0);
    try std.testing.expectEqual(cap + 5, total());
    var buf: [cap]Record = undefined;
    try std.testing.expectEqual(cap, recent(&buf).len);
}

test "audit: non-printable bytes in the tool name are sanitized, not just capped" {
    // A model-supplied name (the unknown-tool path passes `name` through
    // unmodified) could carry embedded newlines to forge extra log lines,
    // or other control bytes. Neither storage nor the log line should ever
    // see the raw bytes — std.log output itself isn't capturable from a
    // unit test, but this pins that the value fed into it (the same
    // sanitized buffer `record` logs from) is already safe.
    reset();
    record("evil\nname\x07", .safe, .denied, 0);
    var buf: [1]Record = undefined;
    const got = recent(&buf);
    try std.testing.expectEqualStrings("evil?name?", got[0].name());
}
