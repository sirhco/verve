//! Minimal IPC route table.
//!
//! Each route in `Routes` declares an `Args` type, a `Reply` type, and
//! a `handle(ctx, alloc, args)` fn. The router parses incoming JSON
//! against `Args`, calls the handler, JSON-encodes `Reply`, and ships
//! it back so `await window.verve.request(...)` resolves.

const std = @import("std");
const desktop = @import("desktop");

const RouterCtx = struct {
    window: *desktop.Window,
};

var ctx: RouterCtx = undefined;

const Router = desktop.Router(RouterCtx, Routes);

pub const onMessage = Router.dispatch;

pub fn attach(window: *desktop.Window) *RouterCtx {
    ctx = .{ .window = window };
    return &ctx;
}

const Routes = struct {
    pub const greet = struct {
        pub const Args = struct {
            name: []const u8 = "world",
        };
        pub const Reply = struct {
            message: []const u8,
        };
        pub fn handle(_: *RouterCtx, alloc: std.mem.Allocator, args: Args) !Reply {
            const trimmed = std.mem.trim(u8, args.name, &std.ascii.whitespace);
            const who = if (trimmed.len == 0) "world" else trimmed;
            const message = try std.fmt.allocPrint(alloc, "Hello, {s}!", .{who});
            return .{ .message = message };
        }
    };
};
