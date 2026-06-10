//! Server-push hub — a transport-agnostic broadcast registry behind the
//! `/push?channel=<name>` SSE endpoint. Any server code publishes bytes into
//! a named channel (`publish`); every connected subscriber's stream loop
//! drains the channel's ring and emits SSE frames (`id:` = the message seq,
//! `event:` = the channel name). Clients resume after a drop via the standard
//! `Last-Event-ID` header; a subscriber that falls out of the ring window is
//! told to resync (`{"resync":true,...}`) and jumped to the head.
//!
//! Fixed capacity, zero allocation on the hot path: channels auto-register on
//! first publish/subscribe and live for the process. A WebSocket binding can
//! reuse the same hub later — nothing here is SSE-specific except
//! `streamChannel`.

const std = @import("std");

pub const MAX_CHANNELS = 8;
/// Retained messages per channel — the resume window.
pub const RING = 32;
/// Per-message payload cap. `publish` rejects anything larger.
pub const MSG_MAX = 4096;
pub const NAME_MAX = 32;

const PUSH_TICK = std.Io.Duration.fromMilliseconds(100);

const Slot = struct {
    seq: u64 = 0,
    len: usize = 0,
    buf: [MSG_MAX]u8 = undefined,
};

const Channel = struct {
    name_buf: [NAME_MAX]u8 = undefined,
    name_len: usize = 0,
    /// Last published seq (0 = nothing yet). Written under `mu`, read lock-free
    /// by subscriber poll loops.
    head: std.atomic.Value(u64) = .init(0),
    subs: std.atomic.Value(u32) = .init(0),
    mu: std.atomic.Mutex = .unlocked,
    ring: [RING]Slot = @splat(.{}),

    fn name(self: *const Channel) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

var registry_mu: std.atomic.Mutex = .unlocked;
var channels: [MAX_CHANNELS]Channel = @splat(.{});
var channel_count: usize = 0;

fn lock(mu: *std.atomic.Mutex) void {
    while (!mu.tryLock()) std.atomic.spinLoopHint();
}

/// Channel names ride in a URL query and an SSE `event:` line — keep them to
/// a conservative token alphabet.
pub fn validName(s: []const u8) bool {
    if (s.len == 0 or s.len > NAME_MAX) return false;
    for (s) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => {},
        else => return false,
    };
    return true;
}

/// Find or create the channel. Null when the name is invalid or the table is
/// full.
fn channelFor(channel_name: []const u8) ?*Channel {
    if (!validName(channel_name)) return null;
    lock(&registry_mu);
    defer registry_mu.unlock();
    for (channels[0..channel_count]) |*c| {
        if (std.mem.eql(u8, c.name(), channel_name)) return c;
    }
    if (channel_count == MAX_CHANNELS) return null;
    const c = &channels[channel_count];
    @memcpy(c.name_buf[0..channel_name.len], channel_name);
    c.name_len = channel_name.len;
    channel_count += 1;
    return c;
}

/// Publish one message to `channel_name` (auto-registering it). Returns the
/// assigned seq, or null when the payload is oversized, the name is invalid,
/// or the channel table is full.
pub fn publish(channel_name: []const u8, payload: []const u8) ?u64 {
    if (payload.len > MSG_MAX) return null;
    const c = channelFor(channel_name) orelse return null;
    lock(&c.mu);
    defer c.mu.unlock();
    const seq = c.head.load(.monotonic) + 1;
    const slot = &c.ring[@intCast((seq - 1) % RING)];
    slot.seq = seq;
    slot.len = payload.len;
    @memcpy(slot.buf[0..payload.len], payload);
    c.head.store(seq, .release);
    return seq;
}

/// Live subscriber count — lets publishers skip work when nobody listens.
pub fn subscriberCount(channel_name: []const u8) u32 {
    lock(&registry_mu);
    defer registry_mu.unlock();
    for (channels[0..channel_count]) |*c| {
        if (std.mem.eql(u8, c.name(), channel_name)) return c.subs.load(.monotonic);
    }
    return 0;
}

/// What a subscriber should send next, given the published head and the last
/// seq it delivered. Pure — the unit-testable core of the stream loop.
pub const Batch = struct {
    /// Subscriber fell out of the ring window: tell it to resync, then jump
    /// `last_sent` to `head`.
    resync: bool,
    /// Inclusive seq range to deliver (`first > last` = nothing to send).
    first: u64,
    last: u64,
};

pub fn nextBatch(head: u64, last_sent: u64) Batch {
    if (head <= last_sent) return .{ .resync = false, .first = 1, .last = 0 };
    if (head - last_sent > RING) return .{ .resync = true, .first = 1, .last = 0 };
    return .{ .resync = false, .first = last_sent + 1, .last = head };
}

/// Copy message `seq` out of the ring into `buf`. Null when the slot has been
/// overwritten since `nextBatch` computed the range (raced publisher) — the
/// caller should resync.
fn copyMessage(c: *Channel, seq: u64, buf: *[MSG_MAX]u8) ?usize {
    lock(&c.mu);
    defer c.mu.unlock();
    const slot = &c.ring[@intCast((seq - 1) % RING)];
    if (slot.seq != seq) return null;
    @memcpy(buf[0..slot.len], slot.buf[0..slot.len]);
    return slot.len;
}

/// Long-lived SSE loop for one subscriber. `resume_after` is the client's
/// `Last-Event-ID` (0 = start at the live tail). Runs until the client
/// disconnects (any write fails).
pub fn streamChannel(
    io: std.Io,
    request: *std.http.Server.Request,
    channel_name: []const u8,
    resume_after: u64,
) !void {
    const c = channelFor(channel_name) orelse return error.BadChannel;

    var stream_buf: [MSG_MAX + 256]u8 = undefined;
    var body_writer = try request.respondStreaming(&stream_buf, .{
        .respond_options = .{
            .status = .ok,
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/event-stream" },
                .{ .name = "cache-control", .value = "no-cache" },
                .{ .name = "x-accel-buffering", .value = "no" },
            },
        },
    });

    _ = c.subs.fetchAdd(1, .monotonic);
    defer _ = c.subs.fetchSub(1, .monotonic);

    try body_writer.writer.writeAll("retry: 2000\n\n");
    try flush(&body_writer);

    // 0 = live tail: skip history, deliver only what's published from now on.
    var last_sent: u64 = if (resume_after == 0) c.head.load(.acquire) else resume_after;

    var msg_buf: [MSG_MAX]u8 = undefined;
    outer: while (true) {
        const head = c.head.load(.acquire);
        const batch = nextBatch(head, last_sent);
        if (batch.resync) {
            body_writer.writer.print(
                "id: {d}\nevent: {s}\ndata: {{\"resync\":true,\"seq\":{d}}}\n\n",
                .{ head, c.name(), head },
            ) catch break;
            flush(&body_writer) catch break;
            last_sent = head;
        } else {
            var seq = batch.first;
            while (seq <= batch.last) : (seq += 1) {
                const len = copyMessage(c, seq, &msg_buf) orelse {
                    // Overwritten under us — force a resync pass next round.
                    last_sent = if (head > RING) head - RING - 1 else 0;
                    continue :outer;
                };
                body_writer.writer.print(
                    "id: {d}\nevent: {s}\ndata: {s}\n\n",
                    .{ seq, c.name(), msg_buf[0..len] },
                ) catch break :outer;
                flush(&body_writer) catch break :outer;
                last_sent = seq;
            }
        }
        std.Io.sleep(io, PUSH_TICK, .awake) catch break;
    }
    body_writer.end() catch {};
}

fn flush(w: *std.http.BodyWriter) !void {
    try w.writer.flush();
    try w.flush();
}

/// Reset the hub between tests (single-threaded test context only).
pub fn resetForTests() void {
    channel_count = 0;
    for (&channels) |*c| {
        c.* = .{};
    }
}

// ---- tests ---------------------------------------------------------------

const testing = std.testing;

test "publish assigns monotonic seqs per channel" {
    resetForTests();
    try testing.expectEqual(@as(?u64, 1), publish("a", "one"));
    try testing.expectEqual(@as(?u64, 2), publish("a", "two"));
    try testing.expectEqual(@as(?u64, 1), publish("b", "other"));
    try testing.expectEqual(@as(?u64, 3), publish("a", "three"));
}

test "ring retains the last RING messages and overwrites older ones" {
    resetForTests();
    var i: usize = 0;
    while (i < RING + 5) : (i += 1) {
        var buf: [16]u8 = undefined;
        const payload = std.fmt.bufPrint(&buf, "m{d}", .{i}) catch unreachable;
        _ = publish("ring", payload).?;
    }
    const c = channelFor("ring").?;
    var out: [MSG_MAX]u8 = undefined;
    // seq 5 (the oldest surviving slot was overwritten) is gone…
    try testing.expectEqual(@as(?usize, null), copyMessage(c, 5, &out));
    // …but the head and the start of the window survive.
    const head = c.head.load(.monotonic);
    try testing.expectEqual(@as(u64, RING + 5), head);
    const n = copyMessage(c, head, &out).?;
    try testing.expect(std.mem.startsWith(u8, out[0..n], "m"));
    try testing.expect(copyMessage(c, head - RING + 1, &out) != null);
}

test "nextBatch: nothing, in-window range, out-of-window resync" {
    const none = nextBatch(7, 7);
    try testing.expect(!none.resync and none.first > none.last);

    const range = nextBatch(10, 7);
    try testing.expect(!range.resync);
    try testing.expectEqual(@as(u64, 8), range.first);
    try testing.expectEqual(@as(u64, 10), range.last);

    const behind = nextBatch(100, 10);
    try testing.expect(behind.resync);

    // exactly RING behind is still deliverable
    const edge = nextBatch(RING + 3, 3);
    try testing.expect(!edge.resync);
    try testing.expectEqual(@as(u64, 4), edge.first);
}

test "channel name validation" {
    try testing.expect(validName("viz"));
    try testing.expect(validName("a-b_C9"));
    try testing.expect(!validName(""));
    try testing.expect(!validName("has space"));
    try testing.expect(!validName("x" ** (NAME_MAX + 1)));
    try testing.expect(!validName("q?ery"));
}

test "oversized payload and invalid names are rejected" {
    resetForTests();
    const big: [MSG_MAX + 1]u8 = @splat('x');
    try testing.expectEqual(@as(?u64, null), publish("a", &big));
    try testing.expectEqual(@as(?u64, null), publish("bad name", "p"));
}

test "subscriberCount is zero for unknown channels" {
    resetForTests();
    try testing.expectEqual(@as(u32, 0), subscriberCount("nope"));
    _ = publish("known", "x");
    try testing.expectEqual(@as(u32, 0), subscriberCount("known"));
}
