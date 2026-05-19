//! Stopwatch is entirely client-side — the server just delivers the
//! page and the wasm. No actions, no shared state.

const std = @import("std");

pub const components = @import("components.zig");
pub const routes_mod = @import("routes.zig");
pub const Route = routes_mod.Route;
pub const routes = routes_mod.routes;

/// Required by the framework's /events and /ws handlers even though
/// this app never mutates it.
pub var last_count: std.atomic.Value(i32) = .init(0);

pub const Actions = struct {};
