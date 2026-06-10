//! Timeline builder. Position arithmetic (GSAP's `"+=0.2"` / `"<"` /
//! labels) is resolved eagerly at `.add()` time — the wire format carries
//! only absolute start seconds, so the JS interpreter never parses
//! position grammar and the math is unit-testable here.

const std = @import("std");
const types = @import("types.zig");
const tween_mod = @import("tween.zig");

pub const Timeline = struct {
    alloc: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    labels: std.ArrayList(Label) = .empty,
    id_name: ?[]const u8 = null,
    /// -1 = infinite.
    repeat_n: i32 = 0,
    yoyo_on: bool = false,
    delay_s: f64 = 0,
    reduced: types.ReducedMotion = .jump_to_end,
    autoplay: bool = true,
    on_complete_slot: ?u32 = null,
    cb_island: ?[]const u8 = null,
    cb_complete_export: ?[]const u8 = null,
    err: ?anyerror = null,

    pub const Entry = struct {
        tween: *tween_mod.Tween,
        /// Resolved absolute start, seconds from timeline start.
        start_s: f64,
    };
    pub const Label = struct {
        name: []const u8,
        time_s: f64,
    };

    /// Append a tween at `at`. Absorbs the tween's deferred error.
    pub fn add(self: *Timeline, t: *tween_mod.Tween, at: types.Position) *Timeline {
        if (self.err != null) return self;
        if (t.err) |e| {
            self.err = e;
            return self;
        }
        const start = self.resolve(at) catch |e| {
            self.err = e;
            return self;
        };
        self.entries.append(self.alloc, .{ .tween = t, .start_s = start }) catch |e| {
            self.err = e;
        };
        return self;
    }

    /// Place a named label for later `add(..., .{ .label = name })` and
    /// runtime `seekLabel`.
    pub fn addLabel(self: *Timeline, label_name: []const u8, at: types.Position) *Timeline {
        if (self.err != null) return self;
        const time = self.resolve(at) catch |e| {
            self.err = e;
            return self;
        };
        self.labels.append(self.alloc, .{ .name = label_name, .time_s = time }) catch |e| {
            self.err = e;
        };
        return self;
    }

    pub fn repeat(self: *Timeline, n: i32) *Timeline {
        if (self.err != null) return self;
        self.repeat_n = n;
        return self;
    }

    pub fn yoyo(self: *Timeline, on: bool) *Timeline {
        if (self.err != null) return self;
        self.yoyo_on = on;
        return self;
    }

    pub fn delay(self: *Timeline, s: f64) *Timeline {
        if (self.err != null) return self;
        self.delay_s = s;
        return self;
    }

    pub fn reducedMotion(self: *Timeline, rm: types.ReducedMotion) *Timeline {
        if (self.err != null) return self;
        self.reduced = rm;
        return self;
    }

    pub fn named(self: *Timeline, n: []const u8) *Timeline {
        if (self.err != null) return self;
        self.id_name = n;
        return self;
    }

    pub fn paused(self: *Timeline) *Timeline {
        if (self.err != null) return self;
        self.autoplay = false;
        return self;
    }

    pub fn onCompleteSlot(self: *Timeline, slot_id: u32) *Timeline {
        if (self.err != null) return self;
        self.on_complete_slot = slot_id;
        return self;
    }

    pub fn onCompleteExport(self: *Timeline, island_name: []const u8, export_name: []const u8) *Timeline {
        if (self.err != null) return self;
        self.cb_island = island_name;
        self.cb_complete_export = export_name;
        return self;
    }

    fn resolve(self: *const Timeline, at: types.Position) !f64 {
        return switch (at) {
            .end => self.contentEnd(),
            .with_prev => if (self.entries.items.len > 0)
                self.entries.items[self.entries.items.len - 1].start_s
            else
                0,
            .abs => |t| t,
            .rel => |o| @max(0, self.contentEnd() + o),
            .label => |n| self.labelTime(n) orelse error.UnknownLabel,
        };
    }

    fn labelTime(self: *const Timeline, label_name: []const u8) ?f64 {
        for (self.labels.items) |l| {
            if (std.mem.eql(u8, l.name, label_name)) return l.time_s;
        }
        return null;
    }

    /// End of the last-finishing child (one forward cycle, no timeline
    /// repeat/delay applied).
    pub fn contentEnd(self: *const Timeline) f64 {
        var end: f64 = 0;
        for (self.entries.items) |e| {
            end = @max(end, e.start_s + e.tween.totalDuration());
        }
        return end;
    }

    /// Total seconds including the timeline's own delay and repeats.
    /// Infinite repeat (or any infinite child) returns +inf.
    pub fn totalDuration(self: *const Timeline) f64 {
        const content = self.contentEnd();
        if (self.repeat_n < 0 or std.math.isInf(content)) return std.math.inf(f64);
        const cycles: f64 = @floatFromInt(self.repeat_n + 1);
        return self.delay_s + content * cycles;
    }

    /// SSR-strict JSON (rejects dynamic values). Duck-typed contract used
    /// by `Node.animate`.
    pub fn toJson(self: *const Timeline, alloc: std.mem.Allocator) ![]const u8 {
        return @import("serialize.zig").timelineToJson(alloc, self, .ssr);
    }
};

pub var poison: Timeline = .{
    .alloc = undefined,
    .err = error.OutOfMemory,
};

pub fn timeline(alloc: std.mem.Allocator) *Timeline {
    const tl = alloc.create(Timeline) catch return &poison;
    tl.* = .{ .alloc = alloc };
    return tl;
}

fn testTween(a: std.mem.Allocator, dur: f64) *tween_mod.Tween {
    return tween_mod.to(a, ".x").duration(dur);
}

test "position resolution: end / with_prev / abs / rel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tl = timeline(a)
        .add(testTween(a, 1.0), .end) // start 0
        .add(testTween(a, 0.5), .with_prev) // start 0 (aligned with prev start)
        .add(testTween(a, 0.5), .end) // start 1.0 (after longest end)
        .add(testTween(a, 0.5), .{ .rel = -0.2 }) // start 1.3
        .add(testTween(a, 0.1), .{ .abs = 9.0 }); // start 9.0
    try std.testing.expect(tl.err == null);
    const e = tl.entries.items;
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), e[0].start_s, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), e[1].start_s, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), e[2].start_s, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.3), e[3].start_s, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 9.0), e[4].start_s, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 9.1), tl.contentEnd(), 1e-12);
}

test "labels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tl = timeline(a)
        .add(testTween(a, 1.0), .end)
        .addLabel("mid", .{ .abs = 0.8 })
        .add(testTween(a, 0.5), .{ .label = "mid" });
    try std.testing.expect(tl.err == null);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), tl.entries.items[1].start_s, 1e-12);
}

test "unknown label is a deferred error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tl = timeline(a).add(testTween(a, 1.0), .{ .label = "nope" });
    try std.testing.expectEqual(@as(?anyerror, error.UnknownLabel), tl.err);
}

test "tween error propagates through add" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad = tween_mod.to(a, ".x").opacity(1).step(0); // StepAfterProps
    const tl = timeline(a).add(bad, .end);
    try std.testing.expectEqual(@as(?anyerror, error.StepAfterProps), tl.err);
}

test "totalDuration with repeat and infinite child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tl = timeline(a).add(testTween(a, 1.0), .end).delay(0.5).repeat(1);
    // 0.5 + 1.0 * 2 = 2.5
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), tl.totalDuration(), 1e-12);

    const inf_child = timeline(a).add(tween_mod.to(a, ".x").repeat(-1), .end);
    try std.testing.expect(std.math.isInf(inf_child.totalDuration()));
}
