//! gl-viewer — standalone declarative 3D product viewer.
//!
//! The whole app is two SSR routes that each declare a `verve.gl` scene with
//! `ctx.glScene(.{...})`. The framework server serves the embedded gl assets
//! (`/gl/demo.vmesh`, `/gl/studio.venv`) and the single `GlScene` island
//! chunk; there is no server function and no realtime work — the 3D render
//! loop lives entirely in the client chunk.
//!
//! This module is the `app` import the framework server, codegen tools, and
//! manifest generator all resolve against. It only needs to re-export the
//! route table + components/islands and provide the `last_count` atomic the
//! built-in counter/metrics endpoints read.

const std = @import("std");

pub const components = @import("components.zig");
pub const islands = @import("islands.zig");
const routes_mod = @import("routes.zig");
pub const Route = routes_mod.Route;
pub const routes = routes_mod.routes;

/// Read by the framework's built-in /metrics + counter endpoints. Unused by
/// this app's own routes, but the server expects the symbol to exist.
pub var last_count: std.atomic.Value(i32) = .init(0);

/// No server functions: the scene is fully declarative and the client chunk
/// owns all interaction. An empty `Actions` keeps the codegen + the server's
/// `/api/<fn>` enumeration happy.
pub const Actions = struct {};
