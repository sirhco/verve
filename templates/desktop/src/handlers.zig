//! Example IPC routes via the comptime typed router.
//!
//! Each route in `Routes` declares an `Args` type, a `Reply` type, and
//! a `handle(ctx, alloc, args)` fn. The router parses incoming JSON
//! against `Args`, calls the handler, JSON-encodes `Reply`, and ships
//! it back through `window.evalJs` so the JS `await
//! window.verve.request(...)` Promise resolves with the typed value.
//!
//! Fire-and-forget messages from `window.verve.send(payload)` without
//! a `__verve_id` field still flow through here — handlers that
//! return a Reply simply log unobserved.

const std = @import("std");
const desktop = @import("desktop");

const RouterCtx = struct {
    window: *desktop.Window,
    assets: []const desktop.AssetEntry,
    child_window: ?desktop.Window = null,
};

var ctx: RouterCtx = undefined;

const Router = desktop.Router(RouterCtx, Routes);

pub const onMessage = Router.dispatch;

pub fn attach(window: *desktop.Window, assets: []const desktop.AssetEntry) *RouterCtx {
    ctx = .{ .window = window, .assets = assets };
    return &ctx;
}

/// Comptime route table. Each public decl is a route; the router
/// matches incoming `type` against the decl name.
const Routes = struct {
    pub const ping = struct {
        pub const Args = struct { sent_at: i64 = 0 };
        pub const Reply = struct { echo: bool, sent_at: i64 };
        pub fn handle(_: *RouterCtx, _: std.mem.Allocator, args: Args) !Reply {
            return .{ .echo = true, .sent_at = args.sent_at };
        }
    };

    pub const log = struct {
        pub const Args = struct { message: []const u8 };
        pub const Reply = struct { ok: bool };
        pub fn handle(_: *RouterCtx, _: std.mem.Allocator, args: Args) !Reply {
            std.log.info("[ui] {s}", .{args.message});
            return .{ .ok = true };
        }
    };

    pub const cookie_set = struct {
        pub const Args = struct { name: []const u8, value: []const u8 };
        pub const Reply = struct { ok: bool };
        pub fn handle(c: *RouterCtx, _: std.mem.Allocator, args: Args) !Reply {
            try c.window.cookies().set(.{
                .name = args.name,
                .value = args.value,
                .domain = "localhost",
                .path = "/",
            });
            return .{ .ok = true };
        }
    };

    pub const cookie_get = struct {
        pub const Args = struct { name: []const u8 };
        pub const Reply = struct {
            found: bool = false,
            name: []const u8 = "",
            value: []const u8 = "",
            domain: []const u8 = "",
            path: []const u8 = "",
        };
        pub fn handle(c: *RouterCtx, alloc: std.mem.Allocator, args: Args) !Reply {
            // Cookie strings come back allocator-owned; the arena
            // passed in here is the per-dispatch one, so the slices
            // remain valid through the reply JSON-encoding step.
            const got = try c.window.cookies().get(alloc, args.name);
            if (got) |k| return .{
                .found = true,
                .name = k.name,
                .value = k.value,
                .domain = k.domain,
                .path = k.path,
            };
            return .{};
        }
    };

    pub const cookie_clear = struct {
        pub const Args = struct {};
        pub const Reply = struct { ok: bool };
        pub fn handle(c: *RouterCtx, _: std.mem.Allocator, _: Args) !Reply {
            try c.window.cookies().clear();
            return .{ .ok = true };
        }
    };

    pub const open_child = struct {
        pub const Args = struct {};
        pub const Reply = struct { ok: bool };
        pub fn handle(c: *RouterCtx, _: std.mem.Allocator, _: Args) !Reply {
            if (c.child_window != null) return .{ .ok = true };
            c.child_window = try c.window.openChildWindow(.{
                .title = "Verve Desktop — child",
                .width = 640,
                .height = 400,
                .assets = c.assets,
                .initial_path = "index.html",
                .scheme = "verve",
            });
            return .{ .ok = true };
        }
    };
};
