//! Chat board — server state + actions.
//!
//! Messages are kept in a fixed-size ring buffer guarded by a spin-lock.
//! Posting an item bumps `last_count`, which the framework's
//! Server-Sent Events stream at /events broadcasts to every connected
//! browser. The chat page subscribes to that stream and reloads itself
//! whenever the counter changes, so all visitors see new messages in
//! near-real-time without polling.

const std = @import("std");

pub const components = @import("components.zig");
pub const routes_mod = @import("routes.zig");
pub const Route = routes_mod.Route;
pub const routes = routes_mod.routes;

const log = std.log.scoped(.verve);

/// Generic "something changed" counter consumed by the framework's
/// /events SSE stream and /ws WebSocket. Every postMessage /
/// clearMessages call bumps it; the bridge.js on the page treats a
/// change as a reload trigger.
pub var last_count: std.atomic.Value(i32) = .init(0);

const MSG_MAX: usize = 64;
const FIELD_MAX: usize = 240;

pub const Message = struct {
    author: [FIELD_MAX]u8 = undefined,
    author_len: usize = 0,
    body: [FIELD_MAX]u8 = undefined,
    body_len: usize = 0,
    seq: u64 = 0,

    pub fn authorSlice(self: *const Message) []const u8 {
        return self.author[0..self.author_len];
    }
    pub fn bodySlice(self: *const Message) []const u8 {
        return self.body[0..self.body_len];
    }
};

var seq_counter: std.atomic.Value(u64) = .init(0);

var slots: [MSG_MAX]Message = .{Message{}} ** MSG_MAX;
var slot_count: usize = 0;
var mu: std.atomic.Mutex = .unlocked;

fn lock() void {
    while (!mu.tryLock()) std.atomic.spinLoopHint();
}

/// Snapshot the message list into `arena`. Strings remain valid for
/// the lifetime of the arena even though the writer pool keeps
/// mutating; we copy under the lock and release before returning.
pub fn snapshot(arena: std.mem.Allocator) ![]Message {
    lock();
    defer mu.unlock();
    const out = try arena.alloc(Message, slot_count);
    @memcpy(out, slots[0..slot_count]);
    return out;
}

pub fn messageCount() usize {
    lock();
    defer mu.unlock();
    return slot_count;
}

pub const Actions = struct {
    pub fn postMessage(args: struct { author: []const u8, body: []const u8 }) !void {
        const author = std.mem.trim(u8, args.author, &std.ascii.whitespace);
        const body = std.mem.trim(u8, args.body, &std.ascii.whitespace);
        if (author.len == 0 or body.len == 0) return error.EmptyField;

        lock();
        defer mu.unlock();

        // Ring buffer: when full, drop the oldest message so the most
        // recent MSG_MAX entries are always visible.
        if (slot_count >= MSG_MAX) {
            var i: usize = 1;
            while (i < MSG_MAX) : (i += 1) {
                slots[i - 1] = slots[i];
            }
            slot_count -= 1;
        }

        const m = &slots[slot_count];
        const al = @min(author.len, FIELD_MAX);
        @memcpy(m.author[0..al], author[0..al]);
        m.author_len = al;
        const bl = @min(body.len, FIELD_MAX);
        @memcpy(m.body[0..bl], body[0..bl]);
        m.body_len = bl;
        m.seq = seq_counter.fetchAdd(1, .monotonic) + 1;
        slot_count += 1;

        _ = last_count.fetchAdd(1, .monotonic);
        log.info("chat: post idx={d} author={s}", .{ slot_count - 1, m.authorSlice() });
    }

    pub fn clearMessages(_: struct {}) !void {
        lock();
        defer mu.unlock();
        slot_count = 0;
        _ = last_count.fetchAdd(1, .monotonic);
        log.info("chat: cleared", .{});
    }
};
