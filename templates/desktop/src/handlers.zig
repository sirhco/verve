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
    /// Output directory for the smoke harness. Null in normal runs;
    /// the smoke_done route writes shot.png + checksum.txt here when
    /// set, then terminates the app.
    smoke_dir: ?[]const u8 = null,
    /// std.Io handle plumbed from main, used by handlers that touch
    /// the filesystem (smoke_done writes checksum.txt via it).
    io: std.Io,
};

var ctx: RouterCtx = undefined;

const Router = desktop.Router(RouterCtx, Routes);

pub const onMessage = Router.dispatch;

/// Deep-link URL handler. Logs the incoming URL and evalJs's it into
/// the page so the demo UI shows the value. macOS uses
/// `NSAppleEventManager` to deliver both warm-launch and cold-launch
/// URLs; Win/Linux deliver cold-launch URLs through argv (the
/// template's main.zig calls `Window.deliverUrl` for those).
pub fn onUrlOpen(c: ?*anyopaque, url: []const u8) void {
    const r: *RouterCtx = @ptrCast(@alignCast(c orelse return));
    std.log.info("[url-open] {s}", .{url});
    // JSON-escape via a tiny manual pass — only quotes + backslashes
    // matter for a URL string fed into a JS string literal.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.heap.page_allocator);
    buf.appendSlice(std.heap.page_allocator, "window.verve.handleDeepLink && window.verve.handleDeepLink(\"") catch return;
    for (url) |b| switch (b) {
        '"' => buf.appendSlice(std.heap.page_allocator, "\\\"") catch return,
        '\\' => buf.appendSlice(std.heap.page_allocator, "\\\\") catch return,
        '\n' => buf.appendSlice(std.heap.page_allocator, "\\n") catch return,
        else => buf.append(std.heap.page_allocator, b) catch return,
    };
    buf.appendSlice(std.heap.page_allocator, "\");") catch return;
    r.window.evalJs(buf.items);
}

pub fn attach(window: *desktop.Window, assets: []const desktop.AssetEntry, smoke_dir: ?[]const u8, io: std.Io) *RouterCtx {
    ctx = .{ .window = window, .assets = assets, .smoke_dir = smoke_dir, .io = io };
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

    pub const notify = struct {
        pub const Args = struct {
            title: []const u8 = "Verve Desktop",
            body: []const u8 = "Hello from the native side.",
        };
        pub const Reply = struct { ok: bool };
        pub fn handle(_: *RouterCtx, alloc: std.mem.Allocator, args: Args) !Reply {
            // Notifications are best-effort. macOS + Linux fire the
            // native API; Win returns Unsupported (deferred to a
            // future tray-balloon / Toast bundle).
            desktop.notifications.show(alloc, .{
                .title = args.title,
                .body = args.body,
            }) catch |err| switch (err) {
                error.Unsupported => return .{ .ok = false },
                else => return err,
            };
            return .{ .ok = true };
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

    /// Level-3 smoke handler. Fired by the bridge's smoke driver after
    /// the page is fully hydrated. Captures a PNG snapshot + writes
    /// a checksum file, then terminates the app so the build step's
    /// `diff` and `compare` commands can run against the golden.
    pub const smoke_done = struct {
        pub const Args = struct { checksum: i64 = 0 };
        pub const Reply = struct { ok: bool };
        pub fn handle(c: *RouterCtx, alloc: std.mem.Allocator, args: Args) !Reply {
            const dir = c.smoke_dir orelse {
                std.log.warn("smoke_done: no smoke_dir set; ignoring", .{});
                return .{ .ok = false };
            };

            const png_path = try std.fs.path.join(alloc, &.{ dir, "shot.png" });
            defer alloc.free(png_path);
            const cksum_path = try std.fs.path.join(alloc, &.{ dir, "checksum.txt" });
            defer alloc.free(cksum_path);

            c.window.takeSnapshotPng(png_path) catch |err| {
                std.log.err("smoke_done: snapshot failed: {s}", .{@errorName(err)});
                c.window.terminate();
                return .{ .ok = false };
            };

            // Write checksum as a single base-10 line (matches the
            // golden format the build step diffs against).
            const cksum_bytes = try std.fmt.allocPrint(alloc, "{d}\n", .{args.checksum});
            defer alloc.free(cksum_bytes);
            std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = cksum_path, .data = cksum_bytes }) catch |err| {
                std.log.err("smoke_done: checksum write failed: {s}", .{@errorName(err)});
                c.window.terminate();
                return .{ .ok = false };
            };

            std.log.info("smoke_done: shot.png + checksum.txt written to '{s}'", .{dir});
            c.window.terminate();
            return .{ .ok = true };
        }
    };
};
