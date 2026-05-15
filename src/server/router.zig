//! Page route lookup. Walks the app's static route table.

const std = @import("std");
const verve = @import("verve");
const app = @import("app");

pub fn match(path: []const u8) ?app.Route {
    for (app.routes) |r| {
        if (std.mem.eql(u8, r.path, path)) return r;
    }
    return null;
}
