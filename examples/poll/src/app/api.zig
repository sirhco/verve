//! Live poll — multi-candidate vote tally.
//!
//! Four atomic counters store the votes; the framework's last_count
//! (which the SSE stream broadcasts) doubles as a "something changed"
//! tick so the page reloads whenever any tally moves.

const std = @import("std");

pub const components = @import("components.zig");
pub const routes_mod = @import("routes.zig");
pub const Route = routes_mod.Route;
pub const routes = routes_mod.routes;

const log = std.log.scoped(.verve);

/// Tick incremented on every vote so /events listeners can refresh.
pub var last_count: std.atomic.Value(i32) = .init(0);

pub const CANDIDATES = [_][]const u8{
    "Tabs",
    "Spaces",
    "Hard tabs, soft hearts",
    "Whatever the linter says",
};

pub var tallies: [CANDIDATES.len]std.atomic.Value(u32) = blk: {
    var arr: [CANDIDATES.len]std.atomic.Value(u32) = undefined;
    for (&arr) |*v| v.* = .init(0);
    break :blk arr;
};

pub fn totalVotes() u64 {
    var n: u64 = 0;
    for (&tallies) |*v| n += v.load(.monotonic);
    return n;
}

pub const Actions = struct {
    pub fn vote(args: struct { candidate: usize }) !void {
        if (args.candidate >= CANDIDATES.len) return error.UnknownCandidate;
        _ = tallies[args.candidate].fetchAdd(1, .monotonic);
        _ = last_count.fetchAdd(1, .monotonic);
        log.info("poll: vote for #{d} ({s})", .{ args.candidate, CANDIDATES[args.candidate] });
    }

    pub fn resetTallies(_: struct {}) !void {
        for (&tallies) |*v| v.store(0, .monotonic);
        _ = last_count.fetchAdd(1, .monotonic);
        log.info("poll: tallies reset", .{});
    }
};
