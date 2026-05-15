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

    const cli = try parseCli(init);

    var addr = cli.address;
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    printStartupBanner(cli);

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

fn printStartupBanner(cli: CliOptions) void {
    std.debug.print("[verve] listening on http://{s}:{d}\n", .{ cli.host_text, cli.port });
    std.debug.print("[verve] pages:\n", .{});
    for (app.routes) |r| {
        std.debug.print("  GET  {s}\n", .{r.path});
    }
    std.debug.print("[verve] actions:\n", .{});
    inline for (comptime std.meta.declarations(app.Actions)) |decl| {
        std.debug.print("  POST /api/{s}\n", .{decl.name});
    }
    std.debug.print("[verve] assets:\n  GET  /client.wasm ({d} B)\n  GET  /verve.js ({d} B)\n", .{
        assets.wasm.len,
        assets.js.len,
    });
}

const DEFAULT_PORT: u16 = 8080;
const DEFAULT_HOST: []const u8 = "127.0.0.1";

const CliOptions = struct {
    address: std.Io.net.IpAddress,
    host_text: []const u8,
    port: u16,
};

fn parseCli(init: std.process.Init) !CliOptions {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var port: u16 = DEFAULT_PORT;
    var host_text: []const u8 = DEFAULT_HOST;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (try optionValue(args, &i, a, "--port")) |v| {
            port = std.fmt.parseInt(u16, v, 10) catch {
                std.debug.print("[verve] invalid --port value: {s}\n", .{v});
                return error.InvalidPort;
            };
            continue;
        }
        if (try optionValue(args, &i, a, "--host")) |v| {
            host_text = v;
            continue;
        }
        std.debug.print("[verve] unknown argument: {s}\n", .{a});
        return error.UnknownArgument;
    }

    var address = std.Io.net.IpAddress.parseLiteral(host_text) catch {
        std.debug.print("[verve] invalid --host value: {s}\n", .{host_text});
        return error.InvalidHost;
    };
    address.setPort(port);

    return .{
        .address = address,
        .host_text = host_text,
        .port = port,
    };
}

fn optionValue(
    args: []const []const u8,
    i: *usize,
    arg: []const u8,
    comptime name: []const u8,
) !?[]const u8 {
    const eq_prefix = name ++ "=";
    if (std.mem.startsWith(u8, arg, eq_prefix)) return arg[eq_prefix.len..];
    if (std.mem.eql(u8, arg, name)) {
        i.* += 1;
        if (i.* >= args.len) {
            std.debug.print("[verve] {s} requires a value\n", .{name});
            return error.MissingValue;
        }
        return args[i.*];
    }
    return null;
}
