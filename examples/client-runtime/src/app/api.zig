//! client-runtime — runnable demo of the v0.1.30 wasm client-runtime
//! primitives (docs/20-client-runtime.md), driven by the `JsonProbe` island.
//!
//! The page mounts one island whose chunk exercises every phase: typed IPC
//! replies, events-with-data, timers/storage/clipboard, forms/measurement,
//! the JS-interop hatch, and the chunk arena + drag-drop. The single server
//! function below is the typed-IPC endpoint the island POSTs to.

const std = @import("std");

pub const components = @import("components.zig");
const routes_mod = @import("routes.zig");
pub const Route = routes_mod.Route;
pub const routes = routes_mod.routes;

/// Read by the framework's /metrics endpoint.
pub var last_count: std.atomic.Value(i32) = .init(0);

/// Server-incremented counter behind the typed-IPC endpoint.
var probe_count: std.atomic.Value(i32) = .init(0);

pub const Actions = struct {
    /// Typed-IPC endpoint. The island fires `serverFnPost("json_probe", "{}")`
    /// and reads this struct back as JSON, both via accessor and via
    /// `readStruct(Reply, …)`. Returns a fresh count each call so the bound
    /// `[z-bind=json_probe_count]` element visibly updates on refresh.
    pub fn json_probe(_: struct {}) !struct { count: i32, title: []const u8, pinned: bool } {
        const c = probe_count.fetchAdd(1, .monotonic) + 1;
        last_count.store(c, .monotonic);
        return .{ .count = c, .title = "reply from server", .pinned = true };
    }
};
