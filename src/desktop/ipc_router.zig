//! Comptime-typed IPC router.
//!
//! `IpcRouter(Routes)` takes a struct whose public declarations are
//! route handlers and emits a `dispatch` function suitable for use as
//! a raw `MessageHandler`. Each route declaration is itself a struct
//! exposing three items:
//!
//! ```zig
//! pub const my_route = struct {
//!     pub const Args  = struct { x: i32, y: i32 };
//!     pub const Reply = struct { sum: i32 };
//!     pub fn handle(ctx: *Ctx, alloc: std.mem.Allocator, args: Args) !Reply {
//!         _ = alloc;
//!         return .{ .sum = args.x + args.y };
//!     }
//! };
//! ```
//!
//! `alloc` is a per-dispatch arena allocator — Reply fields that hold
//! slices may point at memory allocated through it; everything is
//! freed automatically after the reply is JSON-encoded.
//!
//! Frontend usage (auto-correlated via Promise):
//!
//! ```js
//! const reply = await window.verve.request({ type: 'my_route', x: 1, y: 2 });
//! console.log(reply.sum);
//! ```
//!
//! Dispatch contract:
//! - Parses incoming JSON, reads `type` (route name) + optional
//!   `__verve_id` (correlation id from the shim's `request()`).
//! - Looks up the matching route by name at comptime — unknown routes
//!   fall through to the optional `fallback` field on the router
//!   (when set) or log a warning and drop.
//! - Decodes `Args` via `std.json.parseFromValue` against the incoming
//!   object so route handlers see typed parameters.
//! - On success, encodes the returned `Reply` and `evalJs`s back
//!   `{__verve_id, result}` so the awaiting Promise resolves.
//! - On error, encodes `{__verve_id, __verve_error}` so the Promise
//!   rejects.
//!
//! Existing raw `onMessage` listeners on the frontend keep working —
//! the shim only intercepts payloads with a matching `__verve_id`.

const std = @import("std");
const window_mod = @import("window.zig");

pub fn Router(comptime Ctx: type, comptime Routes: type) type {
    return struct {
        const Self = @This();

        /// `MessageHandler` adapter — pass this to `WindowOptions.on_message`
        /// (and the matching `on_message_ctx`). Args are validated at
        /// runtime against each route's declared `Args` type.
        pub fn dispatch(handler_ctx: ?*anyopaque, payload: []const u8) void {
            const ctx: *Ctx = @ptrCast(@alignCast(handler_ctx orelse return));
            dispatchTyped(ctx, payload) catch |err| {
                std.log.warn("verve.ipc_router: dispatch failed: {s}", .{@errorName(err)});
            };
        }

        fn dispatchTyped(ctx: *Ctx, payload: []const u8) !void {
            // Per-dispatch arena — handler may stash owned strings in
            // Reply fields without worrying about ownership; the
            // arena is freed once the JSON reply is emitted.
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
            defer parsed.deinit();
            const root = parsed.value;
            if (root != .object) return error.NotAnObject;

            const type_v = root.object.get("type") orelse return error.MissingType;
            if (type_v != .string) return error.TypeNotString;
            const route_name = type_v.string;

            const id: ?[]const u8 = blk: {
                const id_v = root.object.get("__verve_id") orelse break :blk null;
                if (id_v != .string) break :blk null;
                break :blk id_v.string;
            };

            // Comptime route table — unrolled match on declared names.
            const decls = comptime std.meta.declarations(Routes);
            inline for (decls) |d| {
                if (std.mem.eql(u8, d.name, route_name)) {
                    const Route = @field(Routes, d.name);
                    return invokeRoute(Ctx, Route, ctx, root, id, alloc);
                }
            }

            // Unknown route — reply with structured error if correlated.
            if (id) |i| {
                try replyError(ctx, alloc, i, "unknown route");
            } else {
                std.log.info("verve.ipc_router: unhandled route='{s}'", .{route_name});
            }
        }
    };
}

fn invokeRoute(
    comptime Ctx: type,
    comptime Route: type,
    ctx: *Ctx,
    root: std.json.Value,
    id: ?[]const u8,
    alloc: std.mem.Allocator,
) !void {
    const Args = Route.Args;

    // Parse the same root object as the typed Args. Extra fields
    // (`type`, `__verve_id`) are ignored when ignore_unknown_fields
    // is set.
    const args_parsed = std.json.parseFromValue(Args, alloc, root, .{ .ignore_unknown_fields = true }) catch |err| {
        if (id) |i| try replyError(ctx, alloc, i, @errorName(err));
        return;
    };
    defer args_parsed.deinit();

    const result = Route.handle(ctx, alloc, args_parsed.value) catch |err| {
        if (id) |i| try replyError(ctx, alloc, i, @errorName(err));
        return;
    };

    if (id) |i| try replyOk(ctx, alloc, i, result);
}

fn replyOk(
    ctx: anytype,
    alloc: std.mem.Allocator,
    id: []const u8,
    result: anytype,
) !void {
    const json = try std.json.Stringify.valueAlloc(alloc, .{
        .__verve_id = id,
        .result = result,
    }, .{});
    defer alloc.free(json);
    evalDispatch(ctx, alloc, json);
}

fn replyError(
    ctx: anytype,
    alloc: std.mem.Allocator,
    id: []const u8,
    msg: []const u8,
) !void {
    const json = try std.json.Stringify.valueAlloc(alloc, .{
        .__verve_id = id,
        .__verve_error = msg,
    }, .{});
    defer alloc.free(json);
    evalDispatch(ctx, alloc, json);
}

fn evalDispatch(ctx: anytype, alloc: std.mem.Allocator, json: []const u8) void {
    // Routes can store the *Window pointer on whatever shape they
    // like; convention is `ctx.window: *Window`. If the field is
    // missing we silently skip the reply — raw send/onMessage still
    // works.
    if (!@hasField(@TypeOf(ctx.*), "window")) return;
    const win = ctx.window;
    const script = std.fmt.allocPrint(alloc, "window.verve._dispatch({s})", .{json}) catch return;
    defer alloc.free(script);
    win.evalJs(script);
}
