//! Markdown — server-side GFM rendering + syntax highlighting demo.
//!
//! A single read-only page that renders a markdown document through
//! `ctx.markdown(...)`, replacing the usual third-party `marked` +
//! `highlight.js` dependencies with pure-Zig framework features. No
//! actions, no client wasm logic — everything happens at SSR time.

const std = @import("std");

pub const components = @import("components.zig");
const routes_mod = @import("routes.zig");
pub const Route = routes_mod.Route;
pub const routes = routes_mod.routes;

/// No server functions in this demo; the dispatcher still expects the decl.
pub const Actions = struct {};

/// Read by the framework's /metrics endpoint.
pub var last_count: std.atomic.Value(i32) = .init(0);
