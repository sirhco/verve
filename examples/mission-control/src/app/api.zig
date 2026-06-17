//! mission-control — wind farm dashboard.
//!
//! This module is the `app` import the framework server, codegen tools, and
//! manifest generator all resolve against.

const std = @import("std");

pub const components = @import("components.zig");
pub const islands = @import("islands.zig");
const routes_mod = @import("routes.zig");
pub const Route = routes_mod.Route;
pub const routes = routes_mod.routes;

/// Read by the framework's built-in /metrics + counter endpoints.
pub var last_count: std.atomic.Value(i32) = .init(0);

/// No server functions needed for this example.
pub const Actions = struct {};
