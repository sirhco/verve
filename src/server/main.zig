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

var request_count: u64 = 0;
var start_timestamp: ?std.Io.Timestamp = null;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const cli = parseCli(init) catch |err| switch (err) {
        error.HelpRequested => return,
        else => return err,
    };

    var addr = cli.address;
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    installShutdownHandlers();
    start_timestamp = std.Io.Clock.now(.awake, io);
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
        const start = std.Io.Clock.now(.awake, io);
        const method_name = @tagName(request.head.method);
        const target_copy = request.head.target;
        request_count += 1;
        handleRequest(gpa, io, &request) catch |err| {
            std.debug.print("[verve] {s} {s} → error: {s}\n", .{ method_name, target_copy, @errorName(err) });
            return;
        };
        const end = std.Io.Clock.now(.awake, io);
        const ns = start.durationTo(end).nanoseconds;
        logRequest(method_name, target_copy, ns);
        if (!request.head.keep_alive) return;
    }
}

fn logRequest(method: []const u8, target: []const u8, ns: i96) void {
    const us: i64 = @intCast(@divTrunc(ns, std.time.ns_per_us));
    if (us < 1000) {
        std.debug.print("[verve] {s} {s} {d}µs\n", .{ method, target, us });
        return;
    }
    const ms_whole: i64 = @divTrunc(us, 1000);
    const ms_frac: i64 = @divTrunc(@rem(us, 1000), 100);
    std.debug.print("[verve] {s} {s} {d}.{d}ms\n", .{ method, target, ms_whole, ms_frac });
}

fn handleRequest(gpa: std.mem.Allocator, io: std.Io, request: *std.http.Server.Request) !void {
    const target = request.head.target;
    const path = pathOf(target);

    if (std.mem.eql(u8, path, "/health")) {
        try respondHealth(gpa, io, request);
        return;
    }

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

fn respondHealth(
    gpa: std.mem.Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
) !void {
    const uptime_sec: i64 = if (start_timestamp) |s| blk: {
        const now = std.Io.Clock.now(.awake, io);
        const ns_i96 = s.durationTo(now).nanoseconds;
        break :blk @intCast(@divTrunc(ns_i96, std.time.ns_per_s));
    } else 0;

    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try aw.writer.print(
        "{{\"status\":\"ok\",\"uptime_sec\":{d},\"requests\":{d}}}",
        .{ uptime_sec, request_count },
    );

    try request.respond(aw.written(), .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "cache-control", .value = "no-store" },
        },
    });
}

fn installShutdownHandlers() void {
    const sa: std.posix.Sigaction = .{
        .handler = .{ .handler = &onShutdownSignal },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &sa, null);
    std.posix.sigaction(.TERM, &sa, null);
}

fn onShutdownSignal(sig: std.posix.SIG) callconv(.c) void {
    const name: []const u8 = switch (sig) {
        .INT => "SIGINT",
        .TERM => "SIGTERM",
        else => "signal",
    };
    std.debug.print("\n[verve] received {s}, shutting down (served {d} requests)\n", .{ name, request_count });
    std.process.exit(0);
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
    std.debug.print("[verve] ops:\n  GET  /health\n", .{});
}

const DEFAULT_PORT: u16 = 8080;
const DEFAULT_HOST: []const u8 = "127.0.0.1";

const CliOptions = struct {
    address: std.Io.net.IpAddress,
    host_text: []const u8,
    port: u16,
};

pub const CliExit = error{HelpRequested};

fn parseCli(init: std.process.Init) !CliOptions {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const program = if (args.len > 0) args[0] else "verve-server";

    var port: u16 = DEFAULT_PORT;
    var host_text: []const u8 = DEFAULT_HOST;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            printUsage(program);
            return error.HelpRequested;
        }
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
        std.debug.print("[verve] unknown argument: {s}\n  (run with --help for usage)\n", .{a});
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

fn printUsage(program: []const u8) void {
    std.debug.print(
        \\Usage: {s} [--host HOST] [--port PORT] [--help]
        \\
        \\Verve full-stack web server. Serves SSR pages, embedded WASM client,
        \\and auto-generated /api/<fn> endpoints from app.Actions.
        \\
        \\Options:
        \\  --host HOST     Bind interface. IP literal (default: {s}).
        \\                  Use 0.0.0.0 to accept connections on any interface.
        \\  --port PORT     TCP port (default: {d}).
        \\  -h, --help      Show this message and exit.
        \\
        \\Pages and actions are listed at startup; visit / once the server is up.
        \\
    , .{ program, DEFAULT_HOST, DEFAULT_PORT });
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
