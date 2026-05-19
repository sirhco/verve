const std = @import("std");

pub const components = @import("components.zig");
pub const routes_mod = @import("routes.zig");
pub const Route = routes_mod.Route;
pub const routes = routes_mod.routes;

pub var last_count: std.atomic.Value(i32) = .init(0);

pub const Actions = struct {};
