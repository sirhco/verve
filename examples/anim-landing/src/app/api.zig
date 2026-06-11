//! anim-landing — a product-landing-page composition of `verve.anim`.
//!
//! No server state and no actions: everything on the page is either
//! declarative SSR animation (data-anim / data-drag attributes the
//! bridge interprets) or the one Gallery island. The interesting code
//! lives in `components.zig` (the page) and
//! `src/client/islands/Gallery.zig` (the FLIP chunk).

const std = @import("std");

pub const components = @import("components.zig");
pub const islands = @import("islands.zig");
const routes_mod = @import("routes.zig");
pub const Route = routes_mod.Route;
pub const routes = routes_mod.routes;

/// Read by the framework's /metrics + counter endpoints.
pub var last_count: std.atomic.Value(i32) = .init(0);

pub const Actions = struct {};
