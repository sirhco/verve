//! Verve native server. Uses std.http.Server over std.Io.net TCP.
//! Embeds the wasm client and JS bridge via the `assets` module.

const std = @import("std");
const Writer = std.Io.Writer;
const verve = @import("verve");
const assets = @import("assets");
const app = @import("app");
const router = @import("router.zig");
const api_handler = @import("api_handler.zig");
const components = app.components;

const READ_BUF_SIZE = 64 * 1024;
const WRITE_BUF_SIZE = 64 * 1024;
const BODY_LIMIT: usize = 1 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const port = try parsePort(init);

    var addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    std.debug.print("[verve] listening on http://127.0.0.1:{d}\n", .{port});

    while (true) {
        const stream = server.accept(io) catch |err| {
            std.debug.print("[verve] accept error: {s}\n", .{@errorName(err)});
            continue;
        };
        handleConnection(gpa, io, stream) catch |err| {
            std.debug.print("[verve] connection error: {s}\n", .{@errorName(err)});
        };
    }
}

fn handleConnection(
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
) !void {
    defer stream.close(io);

    var read_buf: [READ_BUF_SIZE]u8 = undefined;
    var write_buf: [WRITE_BUF_SIZE]u8 = undefined;
    var sr = stream.reader(io, &read_buf);
    var sw = stream.writer(io, &write_buf);

    var http_server = std.http.Server.init(&sr.interface, &sw.interface);

    while (true) {
        var request = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            error.HttpRequestTruncated => return,
            else => return err,
        };
        handleRequest(gpa, &request) catch |err| {
            std.debug.print("[verve] request error: {s}\n", .{@errorName(err)});
            return;
        };
        if (!request.head.keep_alive) return;
    }
}

fn handleRequest(gpa: std.mem.Allocator, request: *std.http.Server.Request) !void {
    const target = request.head.target;
    const path = pathOf(target);

    if (std.mem.eql(u8, path, "/client.wasm")) {
        try request.respond(assets.wasm, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/wasm" },
                .{ .name = "cache-control", .value = "public, max-age=300" },
            },
        });
        return;
    }
    if (std.mem.eql(u8, path, "/verve.js")) {
        try request.respond(assets.js, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/javascript" },
                .{ .name = "cache-control", .value = "public, max-age=300" },
            },
        });
        return;
    }

    if (api_handler.isApiPath(path)) {
        if (request.head.method != .POST) {
            try request.respond("method not allowed", .{ .status = .method_not_allowed });
            return;
        }

        var body_buf: [16 * 1024]u8 = undefined;
        const body_reader = request.readerExpectContinue(&body_buf) catch {
            try request.respond("bad request", .{ .status = .bad_request });
            return;
        };
        const body = body_reader.allocRemaining(gpa, .limited(BODY_LIMIT)) catch |err| {
            std.debug.print("[verve] body read error: {s}\n", .{@errorName(err)});
            try request.respond("body read failed", .{ .status = .bad_request });
            return;
        };
        defer gpa.free(body);

        try api_handler.dispatch(gpa, request, path, body);
        return;
    }

    if (router.match(path)) |route| {
        try renderPage(gpa, request, .ok, route.render, null);
        return;
    }

    try renderPage(gpa, request, .not_found, null, path);
}

fn renderPage(
    gpa: std.mem.Allocator,
    request: *std.http.Server.Request,
    status: std.http.Status,
    route_render: ?*const fn (ctx: *const verve.Context) anyerror!verve.Node,
    not_found_path: ?[]const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ctx = verve.Context.init(&arena);

    const node = blk: {
        if (route_render) |render_fn| {
            break :blk render_fn(&ctx) catch |err| {
                std.debug.print("[verve] render error: {s}\n", .{@errorName(err)});
                try request.respond("render failed", .{ .status = .internal_server_error });
                return;
            };
        }
        const body = try components.notFound(&ctx, not_found_path orelse "");
        break :blk try components.page(&ctx, body);
    };

    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try aw.writer.writeAll("<!DOCTYPE html>");
    try verve.Renderer.render(&aw.writer, node);

    try request.respond(aw.written(), .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        },
    });
}

fn pathOf(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |q| return target[0..q];
    return target;
}

const DEFAULT_PORT: u16 = 8080;

fn parsePort(init: std.process.Init) !u16 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.startsWith(u8, a, "--port=")) {
            return std.fmt.parseInt(u16, a["--port=".len..], 10) catch {
                std.debug.print("[verve] invalid --port value: {s}\n", .{a});
                return error.InvalidPort;
            };
        }
        if (std.mem.eql(u8, a, "--port")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("[verve] --port requires a value\n", .{});
                return error.InvalidPort;
            }
            return std.fmt.parseInt(u16, args[i], 10) catch {
                std.debug.print("[verve] invalid --port value: {s}\n", .{args[i]});
                return error.InvalidPort;
            };
        }
    }
    return DEFAULT_PORT;
}
