//! "Zerver" actions — functions that run on the server and are callable from
//! the client. Server's api_handler walks `Actions` at comptime to generate
//! `/api/<fn_name>` routes.

const std = @import("std");

pub const components = @import("components.zig");
pub const routes_mod = @import("routes.zig");
pub const Route = routes_mod.Route;
pub const routes = routes_mod.routes;

const log = std.log.scoped(.verve);

/// Shared server-side counter state. Single-threaded std.http.Server, so
/// no atomics or locking needed at MVP scope.
pub var last_count: i32 = 0;

pub const Actions = struct {
    pub fn updateDatabase(args: struct { new_count: i32 }) !void {
        last_count = args.new_count;
        log.info("updateDatabase: new_count={d}", .{args.new_count});
    }

    pub fn logMessage(args: struct { text: []const u8 }) !void {
        log.info("logMessage: {s}", .{args.text});
    }

    pub fn getCount(_: struct {}) !i32 {
        return last_count;
    }
};
