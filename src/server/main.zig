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

const log = std.log.scoped(.verve);

pub const std_options: std.Options = .{ .log_level = .info };

const READ_BUF_SIZE = 64 * 1024;
const WRITE_BUF_SIZE = 64 * 1024;
const DEFAULT_BODY_LIMIT: usize = 1 * 1024 * 1024;
const PUBLIC_PREFIX = "/public/";
const STATIC_MAX_SIZE: usize = 4 * 1024 * 1024;

var request_count: std.atomic.Value(u64) = .init(0);
var start_timestamp: ?std.Io.Timestamp = null;
var body_limit: usize = DEFAULT_BODY_LIMIT;
var public_dir: ?std.Io.Dir = null;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const cli = parseCli(init) catch |err| switch (err) {
        error.HelpRequested => return,
        else => return err,
    };

    var server = try openListenSocket(init, io, cli);
    defer server.deinit(io);

    installShutdownHandlers();
    start_timestamp = std.Io.Clock.now(.awake, io);
    body_limit = cli.body_limit;
    if (cli.public_dir) |path| {
        public_dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = false }) catch |err| {
            log.err("failed to open --public-dir {s}: {s}", .{ path, @errorName(err) });
            return err;
        };
    }
    defer if (public_dir) |*d| d.close(io);
    printStartupBanner(cli);

    while (true) {
        const stream = server.accept(io) catch |err| {
            log.err("accept error: {s}", .{@errorName(err)});
            continue;
        };

        const ctx = gpa.create(ConnCtx) catch |err| {
            log.err("alloc conn ctx: {s}", .{@errorName(err)});
            stream.close(io);
            continue;
        };
        ctx.* = .{ .gpa = gpa, .io = io, .stream = stream };

        const thread = std.Thread.spawn(.{}, runConnection, .{ctx}) catch |err| {
            log.err("thread spawn: {s}", .{@errorName(err)});
            gpa.destroy(ctx);
            stream.close(io);
            continue;
        };
        thread.detach();
    }
}

const ConnCtx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
};

fn runConnection(ctx: *ConnCtx) void {
    defer ctx.gpa.destroy(ctx);
    handleConnection(ctx.gpa, ctx.io, ctx.stream) catch |err| {
        log.err("connection error: {s}", .{@errorName(err)});
    };
}

/// Returns a listening Server, either by binding to `cli.address` or by
/// adopting a pre-opened socket via the systemd-style LISTEN_FDS protocol.
/// LISTEN_FDS=N means file descriptors 3..3+N-1 are already bound listening
/// sockets; we take fd 3 only.
fn openListenSocket(
    init: std.process.Init,
    io: std.Io,
    cli: CliOptions,
) !std.Io.net.Server {
    if (init.environ_map.get("LISTEN_FDS")) |raw| {
        const count = std.fmt.parseInt(u32, raw, 10) catch {
            log.err("LISTEN_FDS value not an integer: {s}", .{raw});
            return error.InvalidListenFds;
        };
        if (count >= 1) {
            log.info("adopting fd 3 as listening socket (LISTEN_FDS={d})", .{count});
            return .{
                .socket = .{
                    .handle = 3,
                    .address = .{ .ip4 = std.Io.net.Ip4Address.unspecified(0) },
                },
                .options = {},
            };
        }
    }

    var addr = cli.address;
    return addr.listen(io, .{ .reuse_address = true });
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
        _ = request_count.fetchAdd(1, .monotonic);
        handleRequest(gpa, io, &request) catch |err| {
            log.err("{s} {s} → error: {s}", .{ method_name, target_copy, @errorName(err) });
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
        log.info("{s} {s} {d}µs", .{ method, target, us });
        return;
    }
    const ms_whole: i64 = @divTrunc(us, 1000);
    const ms_frac: i64 = @divTrunc(@rem(us, 1000), 100);
    log.info("{s} {s} {d}.{d}ms", .{ method, target, ms_whole, ms_frac });
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

    if (std.mem.startsWith(u8, path, PUBLIC_PREFIX)) {
        try serveStatic(gpa, io, request, path[PUBLIC_PREFIX.len..]);
        return;
    }

    if (std.mem.eql(u8, path, "/events")) {
        try streamEvents(io, request);
        return;
    }

    if (api_handler.isApiPath(path)) {
        if (request.head.method != .POST) {
            try request.respond("method not allowed", .{ .status = .method_not_allowed });
            return;
        }

        // Inspect request headers BEFORE reading the body. After the body
        // reader is initialized std.http.Server transitions out of the
        // received_head state and iterateHeaders asserts.
        const meta = api_handler.RequestMeta.fromRequest(request);

        var body_buf: [16 * 1024]u8 = undefined;
        const body_reader = request.readerExpectContinue(&body_buf) catch {
            try request.respond("bad request", .{ .status = .bad_request });
            return;
        };
        const body = body_reader.allocRemaining(gpa, .limited(body_limit)) catch |err| {
            log.err("body read error: {s}", .{@errorName(err)});
            try request.respond("body read failed", .{ .status = .bad_request });
            return;
        };
        defer gpa.free(body);

        try api_handler.dispatch(gpa, request, path, body, meta);
        return;
    }

    if (router.match(path)) |route| {
        if (request.head.method != .GET and request.head.method != .HEAD) {
            try renderError(gpa, request, .method_not_allowed, "This page only accepts GET requests.");
            return;
        }
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
                log.err("render error: {s}", .{@errorName(err)});
                try renderError(gpa, request, .internal_server_error, "The page failed to render.");
                return;
            };
        }
        const body = try components.notFound(&ctx, not_found_path orelse "");
        break :blk try components.page(&ctx, body);
    };

    var stream_buf: [16 * 1024]u8 = undefined;
    var body_writer = try request.respondStreaming(&stream_buf, .{
        .respond_options = .{
            .status = status,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            },
        },
    });
    try body_writer.writer.writeAll("<!DOCTYPE html>");
    try verve.Renderer.render(&body_writer.writer, node);
    try body_writer.end();
}

fn renderError(
    gpa: std.mem.Allocator,
    request: *std.http.Server.Request,
    status: std.http.Status,
    message: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ctx = verve.Context.init(&arena);

    const status_code: u16 = @intFromEnum(status);
    const status_text = status.phrase() orelse "Error";

    // Error responses close the connection rather than drain the request body.
    // std.http.Server's respond() asserts the body is consumable if keep_alive
    // is true; on a 4xx/5xx for an unread POST that assertion panics.
    const fallback_opts: std.http.Server.Request.RespondOptions = .{
        .status = status,
        .keep_alive = false,
    };

    const body = components.errorPage(&ctx, status_code, status_text, message) catch {
        try request.respond(message, fallback_opts);
        return;
    };
    const node = components.page(&ctx, body) catch {
        try request.respond(message, fallback_opts);
        return;
    };

    var stream_buf: [4 * 1024]u8 = undefined;
    var body_writer = try request.respondStreaming(&stream_buf, .{
        .respond_options = .{
            .status = status,
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            },
        },
    });
    try body_writer.writer.writeAll("<!DOCTYPE html>");
    try verve.Renderer.render(&body_writer.writer, node);
    try body_writer.end();
}

const SSE_TICK = std.Io.Duration.fromMilliseconds(1000);

/// Long-lived Server-Sent Events stream. Pushes the current `last_count`
/// once per second as `event: count` until the client disconnects (any
/// write returns an error) or the thread is cancelled.
fn streamEvents(io: std.Io, request: *std.http.Server.Request) !void {
    var stream_buf: [1024]u8 = undefined;
    var body_writer = try request.respondStreaming(&stream_buf, .{
        .respond_options = .{
            .status = .ok,
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/event-stream" },
                .{ .name = "cache-control", .value = "no-cache" },
                .{ .name = "x-accel-buffering", .value = "no" },
            },
        },
    });

    try body_writer.writer.writeAll("retry: 2000\n\n");
    try flushBodyWriter(&body_writer);

    while (true) {
        const count = app.last_count.load(.monotonic);
        body_writer.writer.print("event: count\ndata: {d}\n\n", .{count}) catch break;
        flushBodyWriter(&body_writer) catch break;
        std.Io.sleep(io, SSE_TICK, .awake) catch break;
    }
    body_writer.end() catch {};
}

/// Push everything buffered in the BodyWriter's chunk encoder *and* the
/// underlying TCP stream writer out to the kernel. `BodyWriter.flush`
/// alone only flushes the outer writer; the in-flight chunk stays cached
/// in the inner writer's buffer until it fills.
fn flushBodyWriter(w: *std.http.BodyWriter) !void {
    try w.writer.flush();
    try w.flush();
}

fn serveStatic(
    gpa: std.mem.Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
    rel_path: []const u8,
) !void {
    const dir = public_dir orelse {
        try renderError(gpa, request, .not_found, "No --public-dir is configured.");
        return;
    };

    if (rel_path.len == 0 or rel_path[0] == '/' or std.mem.indexOf(u8, rel_path, "..") != null) {
        try renderError(gpa, request, .forbidden, "Invalid static asset path.");
        return;
    }

    var file = dir.openFile(io, rel_path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.IsDir => {
            try renderError(gpa, request, .not_found, "Static asset not found.");
            return;
        },
        else => {
            log.err("static open {s}: {s}", .{ rel_path, @errorName(err) });
            try renderError(gpa, request, .internal_server_error, "Static asset open failed.");
            return;
        },
    };
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.size > STATIC_MAX_SIZE) {
        try renderError(gpa, request, .payload_too_large, "Static asset exceeds the per-file size limit.");
        return;
    }

    const data = try gpa.alloc(u8, @intCast(stat.size));
    defer gpa.free(data);
    _ = try file.readPositionalAll(io, data, 0);

    try request.respond(data, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = contentTypeFor(rel_path) },
            .{ .name = "cache-control", .value = "public, max-age=300" },
        },
    });
}

fn contentTypeFor(path: []const u8) []const u8 {
    const ext_pos = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "application/octet-stream";
    const ext = path[ext_pos + 1 ..];
    const table = .{
        .{ "css", "text/css; charset=utf-8" },
        .{ "html", "text/html; charset=utf-8" },
        .{ "ico", "image/x-icon" },
        .{ "js", "application/javascript" },
        .{ "json", "application/json" },
        .{ "png", "image/png" },
        .{ "svg", "image/svg+xml" },
        .{ "txt", "text/plain; charset=utf-8" },
        .{ "wasm", "application/wasm" },
        .{ "webp", "image/webp" },
    };
    inline for (table) |row| {
        if (std.ascii.eqlIgnoreCase(ext, row[0])) return row[1];
    }
    return "application/octet-stream";
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
        .{ uptime_sec, request_count.load(.monotonic) },
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
    std.debug.print("\n[verve] received {s}, shutting down (served {d} requests)\n", .{ name, request_count.load(.monotonic) });
    std.process.exit(0);
}

fn pathOf(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |q| return target[0..q];
    return target;
}

fn printStartupBanner(cli: CliOptions) void {
    if (cli.listen_fd_inherited) {
        log.info("listening on inherited fd 3 (LISTEN_FDS)", .{});
    } else {
        log.info("listening on http://{s}:{d}", .{ cli.host_text, cli.port });
    }
    log.info("pages:", .{});
    for (app.routes) |r| {
        log.info("  GET  {s}", .{r.path});
    }
    log.info("actions:", .{});
    inline for (comptime std.meta.declarations(app.Actions)) |decl| {
        log.info("  POST /api/{s}", .{decl.name});
    }
    log.info("assets:", .{});
    log.info("  GET  /client.wasm ({d} B)", .{assets.wasm.len});
    log.info("  GET  /verve.js ({d} B)", .{assets.js.len});
    if (cli.public_dir) |p| log.info("  GET  /public/* (from {s})", .{p});
    log.info("ops:", .{});
    log.info("  GET  /health", .{});
    log.info("  GET  /events (SSE, 1s tick)", .{});
}

const DEFAULT_PORT: u16 = 8080;
const DEFAULT_HOST: []const u8 = "127.0.0.1";

const CliOptions = struct {
    address: std.Io.net.IpAddress,
    host_text: []const u8,
    port: u16,
    body_limit: usize,
    public_dir: ?[]const u8,
    listen_fd_inherited: bool,
};

pub const CliExit = error{HelpRequested};

fn parseCli(init: std.process.Init) !CliOptions {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const program = if (args.len > 0) args[0] else "verve-server";

    var port: u16 = DEFAULT_PORT;
    var host_text: []const u8 = DEFAULT_HOST;
    var bl: usize = DEFAULT_BODY_LIMIT;
    var public: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            printUsage(program);
            return error.HelpRequested;
        }
        if (try optionValue(args, &i, a, "--port")) |v| {
            port = std.fmt.parseInt(u16, v, 10) catch {
                log.err("invalid --port value: {s}", .{v});
                return error.InvalidPort;
            };
            if (port == 0) {
                log.err("--port 0 is not supported (ephemeral binding); pick an explicit port 1-65535", .{});
                return error.InvalidPort;
            }
            continue;
        }
        if (try optionValue(args, &i, a, "--host")) |v| {
            host_text = v;
            continue;
        }
        if (try optionValue(args, &i, a, "--body-limit")) |v| {
            bl = parseByteSize(v) catch {
                log.err("invalid --body-limit value: {s}", .{v});
                return error.InvalidBodyLimit;
            };
            continue;
        }
        if (try optionValue(args, &i, a, "--public-dir")) |v| {
            public = v;
            continue;
        }
        log.err("unknown argument: {s} (run with --help for usage)", .{a});
        return error.UnknownArgument;
    }

    var address = std.Io.net.IpAddress.parseLiteral(host_text) catch {
        log.err("invalid --host value: {s}", .{host_text});
        return error.InvalidHost;
    };
    address.setPort(port);

    const listen_fd_inherited = blk: {
        const raw = init.environ_map.get("LISTEN_FDS") orelse break :blk false;
        const n = std.fmt.parseInt(u32, raw, 10) catch break :blk false;
        break :blk n >= 1;
    };

    return .{
        .address = address,
        .host_text = host_text,
        .port = port,
        .body_limit = bl,
        .public_dir = public,
        .listen_fd_inherited = listen_fd_inherited,
    };
}

/// Parse a byte size — plain digits, optionally followed by k / m / g (KB/MB/GB
/// powers of 1024). Examples: "4096", "64k", "2m", "1g".
fn parseByteSize(text: []const u8) !usize {
    if (text.len == 0) return error.Empty;
    const last = text[text.len - 1];
    const multiplier: usize = switch (last) {
        'k', 'K' => 1024,
        'm', 'M' => 1024 * 1024,
        'g', 'G' => 1024 * 1024 * 1024,
        else => 1,
    };
    const num_text = if (multiplier == 1) text else text[0 .. text.len - 1];
    const n = try std.fmt.parseInt(usize, num_text, 10);
    return std.math.mul(usize, n, multiplier) catch error.Overflow;
}

fn printUsage(program: []const u8) void {
    std.debug.print(
        \\Usage: {s} [--host HOST] [--port PORT] [--body-limit SIZE] [--public-dir DIR] [--help]
        \\
        \\Verve full-stack web server. Serves SSR pages, embedded WASM client,
        \\and auto-generated /api/<fn> endpoints from app.Actions.
        \\
        \\Options:
        \\  --host HOST          Bind interface. IP literal (default: {s}).
        \\                       Use 0.0.0.0 to accept on any interface.
        \\  --port PORT          TCP port (default: {d}).
        \\  --body-limit SIZE    Max POST body bytes (default: {d}).
        \\                       Accepts k/m/g suffixes (e.g. 64k, 2m, 1g).
        \\  --public-dir DIR     Directory served at /public/*. Files up to 4 MB are
        \\                       returned with a guessed content-type and cached
        \\                       for 5 minutes. Paths containing `..` are rejected.
        \\  -h, --help           Show this message and exit.
        \\
        \\Environment:
        \\  LISTEN_FDS=N         If set to a positive integer (systemd socket
        \\                       activation), the server adopts file descriptor
        \\                       3 as its listening socket and ignores --host
        \\                       and --port.
        \\
        \\Pages and actions are listed at startup; visit / once the server is up.
        \\
    , .{ program, DEFAULT_HOST, DEFAULT_PORT, DEFAULT_BODY_LIMIT });
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
            log.err("{s} requires a value", .{name});
            return error.MissingValue;
        }
        return args[i.*];
    }
    return null;
}
