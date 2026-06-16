//! Per-route latency counters surfaced at /metrics.
//!
//! The label set is computed at comptime from `app.routes` + `app.Actions`
//! plus a handful of well-known endpoints. Counters are plain atomics — no
//! mutex, no allocator — so recording is wait-free and can happen on any
//! worker thread.

const std = @import("std");
const app = @import("app");

pub const Stats = struct {
    label: []const u8,
    count: std.atomic.Value(u64),
    total_ns: std.atomic.Value(u64),
    max_ns: std.atomic.Value(u64),
};

pub const labels = collectLabels();

var entries: [labels.len]Stats = blk: {
    var arr: [labels.len]Stats = undefined;
    for (&arr, labels) |*e, label| {
        e.* = .{
            .label = label,
            .count = .init(0),
            .total_ns = .init(0),
            .max_ns = .init(0),
        };
    }
    break :blk arr;
};

fn collectLabels() []const []const u8 {
    @setEvalBranchQuota(10_000);
    var list: []const []const u8 = &.{};
    for (app.routes) |r| {
        list = list ++ &[_][]const u8{r.pattern};
    }
    for (std.meta.declarations(app.Actions)) |d| {
        list = list ++ &[_][]const u8{"/api/" ++ d.name};
    }
    list = list ++ &[_][]const u8{
        "/health",
        "/metrics",
        "/events",
        "/ws",
        "/client.wasm",
        "/verve.js",
        "/verve-worker.js",
        "/public/*",
        "__not_found__",
    };
    return list;
}

/// Map a raw request path to its canonical metrics label. /public/* is
/// collapsed into a single bucket so the dimensionality stays bounded;
/// unknown paths land in `__not_found__`.
pub fn routeLabel(path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, "/public/")) return "/public/*";
    if (std.mem.startsWith(u8, path, "/api/")) {
        inline for (comptime std.meta.declarations(app.Actions)) |d| {
            const full = "/api/" ++ d.name;
            if (std.mem.eql(u8, path, full)) return full;
        }
        return "__not_found__";
    }
    inline for (app.routes) |r| {
        if (std.mem.eql(u8, path, r.pattern)) return r.pattern;
    }
    const fixed = .{
        "/health", "/metrics", "/events", "/ws", "/client.wasm", "/verve.js", "/verve-worker.js",
    };
    inline for (fixed) |f| {
        if (std.mem.eql(u8, path, f)) return f;
    }
    return "__not_found__";
}

pub fn record(label: []const u8, ns: u64) void {
    for (&entries) |*e| {
        if (e.label.ptr == label.ptr or std.mem.eql(u8, e.label, label)) {
            _ = e.count.fetchAdd(1, .monotonic);
            _ = e.total_ns.fetchAdd(ns, .monotonic);
            updateMax(&e.max_ns, ns);
            return;
        }
    }
}

fn updateMax(slot: *std.atomic.Value(u64), ns: u64) void {
    var cur = slot.load(.monotonic);
    while (ns > cur) {
        const seen = slot.cmpxchgWeak(cur, ns, .monotonic, .monotonic) orelse return;
        cur = seen;
    }
}

pub fn writeJson(
    writer: *std.Io.Writer,
    uptime_sec: i64,
    total_requests: u64,
    rejected: u64,
) !void {
    try writer.print(
        "{{\"uptime_sec\":{d},\"total_requests\":{d},\"rejected\":{d},\"routes\":{{",
        .{ uptime_sec, total_requests, rejected },
    );
    var first = true;
    for (&entries) |*e| {
        const count = e.count.load(.monotonic);
        if (count == 0) continue;
        if (!first) try writer.writeAll(",");
        first = false;
        const total = e.total_ns.load(.monotonic);
        const max = e.max_ns.load(.monotonic);
        const avg = total / count;
        try writer.print(
            "\"{s}\":{{\"count\":{d},\"avg_ns\":{d},\"max_ns\":{d}}}",
            .{ e.label, count, avg, max },
        );
    }
    try writer.writeAll("}}");
}

test "routeLabel maps known paths" {
    try std.testing.expectEqualStrings("/", routeLabel("/"));
    try std.testing.expectEqualStrings("/counter", routeLabel("/counter"));
    try std.testing.expectEqualStrings("/health", routeLabel("/health"));
    try std.testing.expectEqualStrings("/public/*", routeLabel("/public/hello.txt"));
    try std.testing.expectEqualStrings("/api/getCount", routeLabel("/api/getCount"));
    try std.testing.expectEqualStrings("__not_found__", routeLabel("/nope"));
    try std.testing.expectEqualStrings("__not_found__", routeLabel("/api/nope"));
}

test "record + writeJson roundtrip" {
    record("/counter", 1000);
    record("/counter", 3000);
    record("/health", 500);

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeJson(&aw.writer, 0, 3, 0);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"/counter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"max_ns\":3000") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"/health\"") != null);
}
