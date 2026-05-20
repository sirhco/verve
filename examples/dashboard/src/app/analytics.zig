//! Rolling sample buffers fed by the fetcher and action handlers.
//! Read by the /analytics page for sparkline rendering.

const std = @import("std");

pub const SAMPLES = 60;

pub const Ring = struct {
    samples: [SAMPLES]u32 = @splat(0),
    count: u32 = 0,
    head: u32 = 0,
    mu: std.atomic.Mutex = .unlocked,

    fn lock(self: *Ring) void {
        while (!self.mu.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn push(self: *Ring, value: u32) void {
        self.lock();
        defer self.mu.unlock();
        const slot = (self.head + self.count) % SAMPLES;
        self.samples[slot] = value;
        if (self.count < SAMPLES) {
            self.count += 1;
        } else {
            self.head = (self.head + 1) % SAMPLES;
        }
    }

    /// Returns a copy of the buffer (oldest → newest) into `out`. `out` must
    /// hold at least `SAMPLES` elements. Returns the number of valid samples.
    pub fn snapshot(self: *Ring, out: *[SAMPLES]u32) u32 {
        self.lock();
        defer self.mu.unlock();
        var w: u32 = 0;
        while (w < self.count) : (w += 1) {
            out[w] = self.samples[(self.head + w) % SAMPLES];
        }
        return self.count;
    }

    pub fn last(self: *Ring) ?u32 {
        self.lock();
        defer self.mu.unlock();
        if (self.count == 0) return null;
        const tail = (self.head + self.count - 1) % SAMPLES;
        return self.samples[tail];
    }

    pub fn maxValue(self: *Ring) u32 {
        self.lock();
        defer self.mu.unlock();
        var m: u32 = 0;
        var i: u32 = 0;
        while (i < self.count) : (i += 1) {
            const v = self.samples[(self.head + i) % SAMPLES];
            if (v > m) m = v;
        }
        return m;
    }

    pub fn avg(self: *Ring) u32 {
        self.lock();
        defer self.mu.unlock();
        if (self.count == 0) return 0;
        var sum: u64 = 0;
        var i: u32 = 0;
        while (i < self.count) : (i += 1) {
            sum += self.samples[(self.head + i) % SAMPLES];
        }
        return @intCast(sum / self.count);
    }
};

/// External fetcher latency samples (total ms per refresh).
pub var refresh_latency: Ring = .{};

/// Mutation count buckets — caller increments on every action.
pub var mutations: Ring = .{};

/// Bucketing helper: one minute = one bucket. Caller pushes a fresh
/// bucket whenever wall-clock minute changes; otherwise the latest bucket
/// is incremented in place.
var last_bucket_unix: i64 = 0;

pub fn recordMutation(now_unix: i64) void {
    mutations.lock();
    defer mutations.mu.unlock();

    const minute = @divTrunc(now_unix, 60);
    const last_minute = @divTrunc(last_bucket_unix, 60);

    if (last_bucket_unix == 0 or minute != last_minute) {
        last_bucket_unix = now_unix;
        const slot = (mutations.head + mutations.count) % SAMPLES;
        mutations.samples[slot] = 1;
        if (mutations.count < SAMPLES) {
            mutations.count += 1;
        } else {
            mutations.head = (mutations.head + 1) % SAMPLES;
        }
    } else {
        const tail = (mutations.head + mutations.count - 1) % SAMPLES;
        mutations.samples[tail] +%= 1;
    }
}
