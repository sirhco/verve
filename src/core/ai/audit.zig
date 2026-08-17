//! Fixed-size ring of recent tool invocations. Every attempt is recorded —
//! `.allowed`, `.denied`, `.needs_confirmation`, `.claim_rejected`, or
//! `.failed` (see `Outcome` below; a confirmed-and-executed call records
//! `.allowed`, same as any other successful run — there is no separate
//! "confirmed" outcome) — so a host can show what a model actually did, not
//! just what it said it did. The ring holds only the most recent `cap` (64)
//! entries: a flood of calls evicts older ones, so this is a recency window
//! for display, not a durable audit log a host can rely on to retain
//! everything.

const std = @import("std");
const tool = @import("tool.zig");

pub const Outcome = enum { allowed, denied, needs_confirmation, claim_rejected, failed };

pub const Record = struct {
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,
    risk: tool.Risk = .safe,
    outcome: Outcome = .allowed,
    args_bytes: usize = 0,
    /// Monotonic call counter, assigned before the ring wraps. Lets a reader
    /// see that entries were evicted — a gap in `seq` across `recent` — where
    /// the ring alone always looks like a full, complete window.
    seq: u64 = 0,
    /// Hash of the exact argument payload. Records *which* arguments ran
    /// without storing unbounded, attacker-controlled bytes, so the ring stays
    /// fixed-size and allocator-free. Two calls to the same tool with the same
    /// `args_bytes` are otherwise indistinguishable in this record, and
    /// "which arguments were executed" is the question a reader most needs
    /// answered.
    ///
    /// A correlation aid, deliberately NOT a security commitment: unkeyed and
    /// therefore forgeable by anyone who can compute it. `policy.bindingOf` is
    /// the keyed hash, because that one gates execution; this one only labels
    /// a log line.
    args_hash: u64 = 0,

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

/// Record a call, deriving both `args_bytes` and `args_hash` from the payload.
/// Preferred over `record` wherever the argument JSON is in hand — which is
/// every dispatch path through `registry.gate` / `registry.finish`.
pub fn recordArgs(name: []const u8, risk: tool.Risk, outcome: Outcome, args_json: []const u8) void {
    recordFull(name, risk, outcome, args_json.len, std.hash.Wyhash.hash(0, args_json));
}

/// Record a call whose argument payload isn't available — only its length.
/// Leaves `args_hash` zero. Retained for callers outside the dispatch paths;
/// prefer `recordArgs`.
pub fn record(name: []const u8, risk: tool.Risk, outcome: Outcome, args_bytes: usize) void {
    recordFull(name, risk, outcome, args_bytes, 0);
}

fn recordFull(name: []const u8, risk: tool.Risk, outcome: Outcome, args_bytes: usize, args_hash: u64) void {
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
    slot.args_hash = args_hash;
    // Assigned before the bump, so the first call is seq 0 and `seq` indexes
    // calls rather than counting them.
    slot.seq = count;
    count += 1;
    // Log the sanitized, length-capped copy — never the raw `name` — so a
    // single refusal can't write unbounded or forged content to the host log.
    std.log.scoped(.verve_ai).info("tool {s} risk={s} outcome={s} args={d}B hash={x} seq={d}", .{
        slot.name(), @tagName(risk), @tagName(outcome), args_bytes, args_hash, slot.seq,
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

test "audit: seq is monotonic and exposes ring eviction" {
    // Without a sequence number a reader cannot tell a full window from a
    // window that quietly dropped entries — the ring only ever shows `cap`
    // records either way.
    reset();
    var i: usize = 0;
    while (i < cap + 3) : (i += 1) recordArgs("t", .safe, .allowed, "{}");

    var buf: [cap]Record = undefined;
    const got = recent(&buf);
    // cap+3 calls, cap retained: the oldest surviving entry is the 4th call.
    try std.testing.expectEqual(@as(u64, 3), got[0].seq);
    try std.testing.expectEqual(@as(u64, cap + 2), got[got.len - 1].seq);
}

test "audit: args_hash distinguishes payloads that args_bytes cannot" {
    // "Which arguments ran" is the question args_bytes can't answer: these
    // two calls are the same length and the same tool, and differ only in
    // the value that actually mattered.
    reset();
    recordArgs("removeTodo", .mutating, .allowed, "{\"index\":0}");
    recordArgs("removeTodo", .mutating, .allowed, "{\"index\":1}");

    var buf: [2]Record = undefined;
    const got = recent(&buf);
    try std.testing.expectEqual(got[0].args_bytes, got[1].args_bytes);
    try std.testing.expect(got[0].args_hash != got[1].args_hash);
}

test "audit: identical payloads hash identically" {
    reset();
    recordArgs("t", .safe, .allowed, "{\"a\":1}");
    recordArgs("t", .safe, .allowed, "{\"a\":1}");
    var buf: [2]Record = undefined;
    const got = recent(&buf);
    try std.testing.expectEqual(got[0].args_hash, got[1].args_hash);
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
