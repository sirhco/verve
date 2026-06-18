//! mission-control — wind farm dashboard.
//!
//! This module is the `app` import the framework server, codegen tools, and
//! manifest generator all resolve against.

const std = @import("std");
const sim = @import("sim.zig");

pub const components = @import("components.zig");
pub const islands = @import("islands.zig");
const routes_mod = @import("routes.zig");
pub const Route = routes_mod.Route;
pub const routes = routes_mod.routes;

/// Read by the framework's built-in /metrics + counter endpoints.
pub var last_count: std.atomic.Value(i32) = .init(0);

/// No server functions needed for this example.
pub const Actions = struct {};

// ---- Presence publisher --------------------------------------------------

/// Opt-in for the framework's presence publisher loop (presencePublisherLoop
/// in src/server/main.zig). When true, the server polls subscriber count on
/// the `presence` WS push channel every 250 ms and broadcasts `{"count":N}`
/// on every change — covering both connect and disconnect events.
pub const presenceEnabled = true;

// ---- Metrics publisher ---------------------------------------------------

/// Monotonically increasing tick counter; incremented each time
/// metricsAdvanceTick is called by the framework's publisher loop.
var metrics_tick: std.atomic.Value(u64) = .init(0);

/// Called by the framework's metrics publisher loop at ~2 Hz (every 500 ms).
/// Builds a JSON frame for all 4 turbines and returns a slice into `buf`.
/// Returns null only on buffer overflow (won't happen with MSG_MAX = 4096).
pub fn metricsAdvanceTick(buf: []u8) ?[]const u8 {
    const tick = metrics_tick.fetchAdd(1, .monotonic);
    var pos: usize = 0;

    const header = std.fmt.bufPrint(buf, "{{\"tick\":{d},\"turbines\":[", .{tick}) catch return null;
    pos += header.len;

    var i: u8 = 0;
    while (i < 4) : (i += 1) {
        const t = sim.sample(i, tick);
        const sep: []const u8 = if (i > 0) "," else "";
        const entry = std.fmt.bufPrint(buf[pos..], "{s}{{\"id\":{d},\"power_kw\":{d:.1},\"rpm\":{d:.2},\"wind_ms\":{d:.2}}}", .{
            sep,
            i,
            t.power_kw,
            t.rpm,
            t.wind_ms,
        }) catch return null;
        pos += entry.len;
    }

    const tail = "]}";
    if (pos + tail.len > buf.len) return null;
    @memcpy(buf[pos..][0..tail.len], tail);
    pos += tail.len;

    return buf[0..pos];
}
