//! "Zerver" actions — functions that run on the server and are callable from
//! the client. Server's api_handler walks `Actions` at comptime to generate
//! `/api/<fn_name>` routes.

const std = @import("std");

pub const components = @import("components.zig");
pub const routes_mod = @import("routes.zig");
pub const Route = routes_mod.Route;
pub const routes = routes_mod.routes;

pub const Actions = struct {
    pub fn updateDatabase(args: struct { new_count: i32 }) !void {
        std.debug.print("[verve] updateDatabase: new_count={d}\n", .{args.new_count});
    }

    pub fn logMessage(args: struct { text: []const u8 }) !void {
        std.debug.print("[verve] logMessage: {s}\n", .{args.text});
    }
};
