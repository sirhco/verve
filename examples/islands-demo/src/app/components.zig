//! Barrel module re-exporting everything `routes.zig` + the framework's
//! `app.components` hook need.

pub const shell = @import("components/shell.zig");
pub const not_found = @import("components/notFound.zig");

// Hooks the framework's main.zig expects on the `app.components`
// namespace.
pub const page = shell.page;
pub const notFound = not_found.notFound;
pub const errorPage = not_found.errorPage;
