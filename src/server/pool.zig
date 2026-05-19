//! Bounded admission for per-connection worker threads.
//!
//! Zig 0.16's std.Thread exposes only spawn/detach/join — no Mutex, no
//! Condition — so a classic N-workers-pulling-from-a-queue pool is awkward
//! to build without busy-waiting. Instead, the accept loop spawns a fresh
//! detached thread per connection (cheap on modern OSes), but admits a
//! request only when an atomic counter is below `max`. Excess connections
//! get a 503 directly from the accept thread and are closed.
//!
//! This caps concurrent work (DoS resilience) without spinning idle workers
//! or fighting std primitives that 0.16 does not provide.

const std = @import("std");

pub const Admit = struct {
    in_flight: std.atomic.Value(u32),
    max: u32,

    pub fn init(max: u32) Admit {
        return .{ .in_flight = .init(0), .max = max };
    }

    /// Returns true if a slot was reserved and the caller may proceed.
    /// On true, the caller MUST eventually call `release`.
    pub fn tryAdmit(self: *Admit) bool {
        var current = self.in_flight.load(.monotonic);
        while (true) {
            if (current >= self.max) return false;
            const result = self.in_flight.cmpxchgWeak(current, current + 1, .acquire, .monotonic);
            if (result) |new_current| {
                current = new_current;
                continue;
            }
            return true;
        }
    }

    pub fn release(self: *Admit) void {
        _ = self.in_flight.fetchSub(1, .release);
    }

    pub fn snapshot(self: *const Admit) u32 {
        return self.in_flight.load(.monotonic);
    }
};

test "tryAdmit caps at max" {
    var a: Admit = .init(3);
    try std.testing.expect(a.tryAdmit());
    try std.testing.expect(a.tryAdmit());
    try std.testing.expect(a.tryAdmit());
    try std.testing.expect(!a.tryAdmit());
    a.release();
    try std.testing.expect(a.tryAdmit());
}

test "concurrent tryAdmit never exceeds max" {
    const Ctx = struct {
        admit: *Admit,
        admitted: std.atomic.Value(u32) = .init(0),
    };
    var admit: Admit = .init(8);
    var ctx: Ctx = .{ .admit = &admit };

    const worker = struct {
        fn run(c: *Ctx) void {
            var i: usize = 0;
            while (i < 100) : (i += 1) {
                if (c.admit.tryAdmit()) {
                    _ = c.admitted.fetchAdd(1, .monotonic);
                    c.admit.release();
                }
            }
        }
    }.run;

    var threads: [16]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, worker, .{&ctx});
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(u32, 0), admit.snapshot());
}
