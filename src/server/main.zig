//! Verve native server. Uses std.http.Server over std.Io.net TCP.
//! Embeds the wasm client and JS bridge via the `assets` module.

const std = @import("std");
const Writer = std.Io.Writer;
const verve = @import("verve");
const assets = @import("assets");
const public_assets = @import("public_assets");
const app = @import("app");
const router = @import("router.zig");
const api_handler = @import("api_handler.zig");
const pool_mod = @import("pool.zig");
const metrics = @import("metrics.zig");
const gzip = @import("gzip.zig");
const components = app.components;

const log = std.log.scoped(.verve);

pub const std_options: std.Options = .{ .log_level = .info };

const READ_BUF_SIZE = 64 * 1024;
const WRITE_BUF_SIZE = 64 * 1024;
const DEFAULT_BODY_LIMIT: usize = 1 * 1024 * 1024;
const PUBLIC_PREFIX = "/public/";
const STATIC_MAX_SIZE: usize = 4 * 1024 * 1024;

var request_count: std.atomic.Value(u64) = .init(0);
var rejected_count: std.atomic.Value(u64) = .init(0);
var start_timestamp: ?std.Io.Timestamp = null;
var body_limit: usize = DEFAULT_BODY_LIMIT;
var public_dir: ?std.Io.Dir = null;
var admit: pool_mod.Admit = .init(0);

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
    admit = .init(cli.workers);
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

        if (!admit.tryAdmit()) {
            _ = rejected_count.fetchAdd(1, .monotonic);
            rejectBusy(io, stream);
            continue;
        }

        const ctx = gpa.create(ConnCtx) catch |err| {
            log.err("alloc conn ctx: {s}", .{@errorName(err)});
            admit.release();
            stream.close(io);
            continue;
        };
        ctx.* = .{ .gpa = gpa, .io = io, .stream = stream };

        const thread = std.Thread.spawn(.{}, runConnection, .{ctx}) catch |err| {
            log.err("thread spawn: {s}", .{@errorName(err)});
            gpa.destroy(ctx);
            admit.release();
            stream.close(io);
            continue;
        };
        thread.detach();
    }
}

/// Send a minimal HTTP/1.1 503 to a connection that arrived while the
/// admission counter was saturated. Best-effort — we ignore write errors
/// because the client may already be gone.
fn rejectBusy(io: std.Io, stream: std.Io.net.Stream) void {
    const body = "Server busy. Please retry.\n";
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    w.print(
        "HTTP/1.1 503 Service Unavailable\r\n" ++
            "Content-Type: text/plain; charset=utf-8\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "Retry-After: 1\r\n\r\n{s}",
        .{ body.len, body },
    ) catch {};
    w.flush() catch {};
    stream.close(io);
}

const ConnCtx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
};

fn runConnection(ctx: *ConnCtx) void {
    defer ctx.gpa.destroy(ctx);
    defer admit.release();
    handleConnection(ctx.gpa, ctx.io, ctx.stream) catch |err| {
        // Client closed the socket mid-stream (e.g. SSE tab navigated away,
        // browser refresh dropped the long-lived /events connection).
        // Not a server fault — keep the log clean.
        if (err == error.ReadFailed) return;
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
        const path = pathOf(target_copy);
        const route_label = metrics.routeLabel(path);
        // Capture request headers ONCE before any response or body read.
        // std.http.Server invalidates iterateHeaders after the body reader
        // transitions out of received_head.
        const req_meta = api_handler.RequestMeta.fromRequest(&request);
        _ = request_count.fetchAdd(1, .monotonic);
        handleRequest(gpa, io, &request, path, req_meta) catch |err| {
            log.err("{s} {s} → error: {s}", .{ method_name, target_copy, @errorName(err) });
            return;
        };
        const end = std.Io.Clock.now(.awake, io);
        const ns = start.durationTo(end).nanoseconds;
        metrics.record(route_label, @intCast(@max(ns, 0)));
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

fn handleRequest(
    gpa: std.mem.Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
    path: []const u8,
    meta: api_handler.RequestMeta,
) !void {
    if (std.mem.eql(u8, path, "/health")) {
        try respondHealth(gpa, io, request, meta);
        return;
    }

    if (std.mem.eql(u8, path, "/metrics")) {
        try respondMetrics(gpa, io, request, meta);
        return;
    }

    if (std.mem.eql(u8, path, "/client.wasm")) {
        try respondBuffered(gpa, request, .ok, "application/wasm", "public, max-age=300", meta.accept_gzip, assets.wasm);
        return;
    }
    if (std.mem.eql(u8, path, "/verve.js")) {
        try respondBuffered(gpa, request, .ok, "application/javascript", "public, max-age=300", meta.accept_gzip, assets.js);
        return;
    }

    if (std.mem.startsWith(u8, path, PUBLIC_PREFIX)) {
        try serveStatic(gpa, io, request, path[PUBLIC_PREFIX.len..], meta.accept_gzip);
        return;
    }

    if (std.mem.eql(u8, path, "/events")) {
        try streamEvents(io, request);
        return;
    }

    if (std.mem.eql(u8, path, "/ws")) {
        const upgrade = request.upgradeRequested();
        if (upgrade != .websocket or upgrade.websocket == null) {
            try renderError(gpa, io, request, .bad_request, "WebSocket upgrade required.");
            return;
        }
        try streamWebSocket(io, request, upgrade.websocket.?);
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
            try renderError(gpa, io, request, .method_not_allowed, "This page only accepts GET requests.");
            return;
        }
        try renderPage(gpa, io, request, .ok, route.render, null, meta.accept_gzip);
        return;
    }

    try renderPage(gpa, io, request, .not_found, null, path, meta.accept_gzip);
}

fn renderPage(
    gpa: std.mem.Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
    status: std.http.Status,
    route_render: ?*const fn (ctx: *const verve.Context) anyerror!*verve.Node,
    not_found_path: ?[]const u8,
    accept_gzip: bool,
) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ctx = verve.Context.initWithIo(&arena, io);

    const node: *verve.Node = blk: {
        if (route_render) |render_fn| {
            break :blk render_fn(&ctx) catch |err| {
                log.err("render error: {s}", .{@errorName(err)});
                try renderError(gpa, io, request, .internal_server_error, "The page failed to render.");
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

    try respondBuffered(gpa, request, status, "text/html; charset=utf-8", null, accept_gzip, aw.written());
}

fn renderError(
    gpa: std.mem.Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
    status: std.http.Status,
    message: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ctx = verve.Context.initWithIo(&arena, io);

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

const WS_TICK = std.Io.Duration.fromMilliseconds(250);

const WsBroadcastCtx = struct {
    io: std.Io,
    ws: *std.http.Server.WebSocket,
    write_mu: *std.atomic.Mutex,
    shutdown: *std.atomic.Value(bool),
    last_seen: i32,
};

// ---- WS chat broadcast registry ------------------------------------------
//
// Any text frame that is not "+"/"-" gets relayed to all other open WS
// peers. Apps can wire a chat-like UI on top of `/ws` without touching the
// framework. The registry uses a fixed-size slot array protected by a
// spinlock-style mutex; allocations on the connection hot-path are avoided.

const CHAT_PEER_MAX = 64;
const CHAT_FRAME_MAX = 1024;

const ChatPeer = struct {
    ws: *std.http.Server.WebSocket,
    write_mu: *std.atomic.Mutex,
};

var chat_peer_slots: [CHAT_PEER_MAX]?*ChatPeer = .{null} ** CHAT_PEER_MAX;
var chat_peer_mu: std.atomic.Mutex = .unlocked;

fn lockPeers() void {
    while (!chat_peer_mu.tryLock()) std.atomic.spinLoopHint();
}

/// Insert the peer in the first free slot. Returns the slot index or null
/// when the registry is full.
fn registerPeer(peer: *ChatPeer) ?usize {
    lockPeers();
    defer chat_peer_mu.unlock();
    for (&chat_peer_slots, 0..) |*s, i| {
        if (s.* == null) {
            s.* = peer;
            return i;
        }
    }
    return null;
}

fn unregisterPeer(slot: usize) void {
    lockPeers();
    defer chat_peer_mu.unlock();
    chat_peer_slots[slot] = null;
}

fn broadcastChat(except_slot: usize, payload: []const u8) void {
    // Snapshot peers under lock; write outside lock so a slow peer doesn't
    // stall the broadcaster's other writes.
    var snapshot: [CHAT_PEER_MAX]?*ChatPeer = undefined;
    {
        lockPeers();
        defer chat_peer_mu.unlock();
        snapshot = chat_peer_slots;
    }
    for (snapshot, 0..) |maybe, i| {
        if (i == except_slot) continue;
        const peer = maybe orelse continue;
        while (!peer.write_mu.tryLock()) std.atomic.spinLoopHint();
        defer peer.write_mu.unlock();
        peer.ws.writeMessage(payload, .text) catch {};
    }
}

/// Bidirectional WebSocket counter mirror. The reader half consumes "+"
/// / "-" frames and applies them to `last_count`; the writer half (a
/// helper thread) polls last_count every WS_TICK and pushes the current
/// value to the client whenever it changes. The mutex serializes writes
/// from both halves; the shutdown flag lets the broadcaster exit
/// promptly when the reader loop terminates.
fn streamWebSocket(
    io: std.Io,
    request: *std.http.Server.Request,
    key: []const u8,
) !void {
    var ws = try request.respondWebSocket(.{ .key = key });
    try ws.flush();

    var write_mu: std.atomic.Mutex = .unlocked;
    var shutdown: std.atomic.Value(bool) = .init(false);

    var peer = ChatPeer{ .ws = &ws, .write_mu = &write_mu };
    const peer_slot = registerPeer(&peer);
    defer if (peer_slot) |s| unregisterPeer(s);

    // Initial state push.
    writeCount(&ws, &write_mu);

    var ctx = WsBroadcastCtx{
        .io = io,
        .ws = &ws,
        .write_mu = &write_mu,
        .shutdown = &shutdown,
        .last_seen = app.last_count.load(.monotonic),
    };
    const broadcaster = try std.Thread.spawn(.{}, wsBroadcastLoop, .{&ctx});
    defer {
        shutdown.store(true, .release);
        broadcaster.join();
    }

    while (true) {
        const msg = ws.readSmallMessage() catch break;
        if (msg.opcode != .text and msg.opcode != .binary) continue;

        if (std.mem.eql(u8, msg.data, "+")) {
            _ = app.last_count.fetchAdd(1, .monotonic);
            writeCount(&ws, &write_mu);
        } else if (std.mem.eql(u8, msg.data, "-")) {
            _ = app.last_count.fetchSub(1, .monotonic);
            writeCount(&ws, &write_mu);
        } else {
            // Treat as chat: fan out to every other connected peer, plus
            // echo back to the sender so their UI confirms receipt.
            const len = @min(msg.data.len, CHAT_FRAME_MAX);
            const payload = msg.data[0..len];
            if (peer_slot) |s| broadcastChat(s, payload);
            {
                while (!write_mu.tryLock()) std.atomic.spinLoopHint();
                defer write_mu.unlock();
                ws.writeMessage(payload, .text) catch {};
            }
        }
    }
}

fn wsBroadcastLoop(ctx: *WsBroadcastCtx) void {
    while (!ctx.shutdown.load(.acquire)) {
        const cur = app.last_count.load(.monotonic);
        if (cur != ctx.last_seen) {
            writeCount(ctx.ws, ctx.write_mu);
            ctx.last_seen = cur;
        }
        std.Io.sleep(ctx.io, WS_TICK, .awake) catch break;
    }
}

fn writeCount(ws: *std.http.Server.WebSocket, mu: *std.atomic.Mutex) void {
    while (!mu.tryLock()) std.atomic.spinLoopHint();
    defer mu.unlock();
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("{d}", .{app.last_count.load(.monotonic)}) catch return;
    ws.writeMessage(w.buffered(), .text) catch {};
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
    accept_gzip: bool,
) !void {
    if (rel_path.len == 0 or rel_path[0] == '/' or std.mem.indexOf(u8, rel_path, "..") != null) {
        try renderError(gpa, io, request, .forbidden, "Invalid static asset path.");
        return;
    }

    // --public-dir is checked first so it acts as a dev-time overlay over
    // the comptime-embedded set; embedded entries are the fallback when no
    // runtime dir is configured or the file isn't on disk.
    if (public_dir) |dir| {
        if (try tryServeFromDisk(gpa, io, request, dir, rel_path, accept_gzip)) return;
    }

    for (public_assets.entries) |entry| {
        if (std.mem.eql(u8, entry.path, rel_path)) {
            try respondBuffered(
                gpa,
                request,
                .ok,
                entry.content_type,
                "public, max-age=300",
                accept_gzip,
                entry.bytes,
            );
            return;
        }
    }

    try renderError(gpa, io, request, .not_found, "Static asset not found.");
}

/// Returns true when the request was answered (either with the file or
/// with an error response for an unexpected open/read failure). Returns
/// false for FileNotFound etc. so the caller can try the embedded fallback.
fn tryServeFromDisk(
    gpa: std.mem.Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
    dir: std.Io.Dir,
    rel_path: []const u8,
    accept_gzip: bool,
) !bool {
    var file = dir.openFile(io, rel_path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.IsDir => return false,
        else => {
            log.err("static open {s}: {s}", .{ rel_path, @errorName(err) });
            try renderError(gpa, io, request, .internal_server_error, "Static asset open failed.");
            return true;
        },
    };
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.size > STATIC_MAX_SIZE) {
        try renderError(gpa, io, request, .payload_too_large, "Static asset exceeds the per-file size limit.");
        return true;
    }

    const data = try gpa.alloc(u8, @intCast(stat.size));
    defer gpa.free(data);
    _ = try file.readPositionalAll(io, data, 0);

    try respondBuffered(gpa, request, .ok, contentTypeFor(rel_path), "public, max-age=300", accept_gzip, data);
    return true;
}

/// Single-shot response with optional gzip. Falls back to the raw body if
/// gzip fails (allocation, compressor error) so the request always returns
/// something — clients tolerant of `content-encoding: identity` will still
/// see the page.
fn respondBuffered(
    gpa: std.mem.Allocator,
    request: *std.http.Server.Request,
    status: std.http.Status,
    content_type: []const u8,
    cache_control: ?[]const u8,
    accept_gzip: bool,
    body: []const u8,
) !void {
    const GZIP_MIN: usize = 256;

    if (accept_gzip and body.len >= GZIP_MIN and gzip.shouldCompress(content_type)) {
        const compressed = gzip.compress(gpa, body) catch null;
        if (compressed) |c| {
            defer gpa.free(c);
            try respondRaw(request, status, content_type, cache_control, "gzip", c);
            return;
        }
    }
    try respondRaw(request, status, content_type, cache_control, null, body);
}

fn respondRaw(
    request: *std.http.Server.Request,
    status: std.http.Status,
    content_type: []const u8,
    cache_control: ?[]const u8,
    encoding: ?[]const u8,
    body: []const u8,
) !void {
    var headers: [4]std.http.Header = undefined;
    var n: usize = 0;
    headers[n] = .{ .name = "content-type", .value = content_type };
    n += 1;
    if (cache_control) |cc| {
        headers[n] = .{ .name = "cache-control", .value = cc };
        n += 1;
    }
    if (encoding) |enc| {
        headers[n] = .{ .name = "content-encoding", .value = enc };
        n += 1;
    }
    try request.respond(body, .{
        .status = status,
        .extra_headers = headers[0..n],
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
    meta: api_handler.RequestMeta,
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

    try respondBuffered(gpa, request, .ok, "application/json", "no-store", meta.accept_gzip, aw.written());
}

fn respondMetrics(
    gpa: std.mem.Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
    meta: api_handler.RequestMeta,
) !void {
    const uptime_sec: i64 = if (start_timestamp) |s| blk: {
        const now = std.Io.Clock.now(.awake, io);
        const ns_i96 = s.durationTo(now).nanoseconds;
        break :blk @intCast(@divTrunc(ns_i96, std.time.ns_per_s));
    } else 0;

    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try metrics.writeJson(
        &aw.writer,
        uptime_sec,
        request_count.load(.monotonic),
        rejected_count.load(.monotonic),
    );

    try respondBuffered(gpa, request, .ok, "application/json", "no-store", meta.accept_gzip, aw.written());
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
    log.info("max concurrent connections: {d}", .{cli.workers});
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
    log.info("  GET  /metrics", .{});
    log.info("  GET  /events (SSE, 1s tick)", .{});
    log.info("  GET  /ws (WebSocket, bidirectional)", .{});
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
    workers: u32,
};

pub const CliExit = error{HelpRequested};

fn parseCli(init: std.process.Init) !CliOptions {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const program = if (args.len > 0) args[0] else "verve-server";

    var port: u16 = DEFAULT_PORT;
    var host_text: []const u8 = DEFAULT_HOST;
    var bl: usize = DEFAULT_BODY_LIMIT;
    var public: ?[]const u8 = null;
    var workers: u32 = defaultWorkers();

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
        if (try optionValue(args, &i, a, "--workers")) |v| {
            workers = std.fmt.parseInt(u32, v, 10) catch {
                log.err("invalid --workers value: {s}", .{v});
                return error.InvalidWorkers;
            };
            if (workers == 0) {
                log.err("--workers must be >= 1", .{});
                return error.InvalidWorkers;
            }
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
        .workers = workers,
    };
}

fn defaultWorkers() u32 {
    const cpu = std.Thread.getCpuCount() catch 4;
    const doubled = std.math.mul(usize, cpu, 2) catch return 8;
    return @intCast(std.math.clamp(doubled, 4, 1024));
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
        \\Usage: {s} [--host HOST] [--port PORT] [--body-limit SIZE]
        \\                    [--public-dir DIR] [--workers N] [--help]
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
        \\  --workers N          Max concurrent in-flight connections. Excess
        \\                       requests get an immediate 503 with Retry-After: 1.
        \\                       Default: clamp(cpu*2, 4, 1024).
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
