//! Verve islands-demo — minimal app module.
//!
//! Re-exports the `routes`, `components`, `Actions`, `islands`, and
//! `last_count` declarations the framework's `app` module hook resolves
//! from a single entry point (see `src/server/main.zig` +
//! `tools/*_gen.zig`).

const std = @import("std");

pub const components = @import("components.zig");
pub const islands = @import("islands.zig");
pub const routes_mod = @import("routes.zig");
pub const routes = routes_mod.routes;

/// Required by the framework's WebSocket / SSE counter hooks. Unused by
/// this demo's UI but part of the app-module contract.
pub var last_count: std.atomic.Value(i32) = .init(0);

/// Server-fn table. Empty for this demo — the codegen tools still need
/// the decl to exist (they walk `std.meta.declarations(app.Actions)`).
pub const Actions = struct {};
