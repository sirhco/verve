//! End-to-end tests for the verve-server binary. Each test spawns the
//! built server as a child process on a chosen port, talks to it over
//! a TCP stream via std.Io.net, and tears it down with SIGTERM.

const std = @import("std");
const build_options = @import("build_options");

const TEST_PORT: u16 = 18765;
const READY_RETRIES: u32 = 60;
const READY_DELAY = std.Io.Duration.fromMilliseconds(50);

const Response = struct {
    status: u16,
    body: []const u8,
    raw: []u8,

    fn deinit(self: *Response, gpa: std.mem.Allocator) void {
        gpa.free(self.raw);
    }
};

fn parseResponse(gpa: std.mem.Allocator, raw_in: []const u8) !Response {
    const raw = try gpa.dupe(u8, raw_in);
    errdefer gpa.free(raw);

    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.MalformedResponse;
    const status_line_end = std.mem.indexOf(u8, raw, "\r\n") orelse return error.MalformedResponse;
    const status_line = raw[0..status_line_end];

    var it = std.mem.tokenizeScalar(u8, status_line, ' ');
    _ = it.next(); // HTTP/1.1
    const code_str = it.next() orelse return error.MalformedResponse;
    const status = try std.fmt.parseInt(u16, code_str, 10);

    return .{
        .status = status,
        .body = raw[header_end + 4 ..],
        .raw = raw,
    };
}

fn loopback(port: u16) std.Io.net.IpAddress {
    return std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
}

fn waitForReady(io: std.Io, port: u16) !void {
    const addr = loopback(port);
    var attempts: u32 = 0;
    while (attempts < READY_RETRIES) : (attempts += 1) {
        const stream = addr.connect(io, .{ .mode = .stream }) catch |err| switch (err) {
            error.ConnectionRefused => {
                try std.Io.sleep(io, READY_DELAY, .awake);
                continue;
            },
            else => return err,
        };
        stream.close(io);
        return;
    }
    return error.ServerNotReady;
}

fn request(
    io: std.Io,
    gpa: std.mem.Allocator,
    port: u16,
    method: []const u8,
    path: []const u8,
) !Response {
    return requestWithBody(io, gpa, port, method, path, null, null);
}

fn postForm(
    io: std.Io,
    gpa: std.mem.Allocator,
    port: u16,
    path: []const u8,
    body: []const u8,
) !Response {
    return requestWithBody(io, gpa, port, "POST", path, "application/x-www-form-urlencoded", body);
}

fn requestWithBody(
    io: std.Io,
    gpa: std.mem.Allocator,
    port: u16,
    method: []const u8,
    path: []const u8,
    content_type: ?[]const u8,
    body: ?[]const u8,
) !Response {
    const addr = loopback(port);
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var write_buf: [1024]u8 = undefined;
    var sw = stream.writer(io, &write_buf);
    try sw.interface.print(
        "{s} {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n",
        .{ method, path },
    );
    if (content_type) |ct| {
        try sw.interface.print("Content-Type: {s}\r\n", .{ct});
    }
    if (body) |b| {
        try sw.interface.print("Content-Length: {d}\r\n", .{b.len});
    }
    try sw.interface.writeAll("\r\n");
    if (body) |b| try sw.interface.writeAll(b);
    try sw.interface.flush();

    var read_buf: [4096]u8 = undefined;
    var sr = stream.reader(io, &read_buf);
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(gpa);
    while (true) {
        const slice = sr.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try acc.appendSlice(gpa, slice);
        sr.interface.toss(slice.len);
    }
    return parseResponse(gpa, acc.items);
}

const Harness = struct {
    threaded: *std.Io.Threaded,
    child: std.process.Child,
    port: u16,

    fn io(self: *Harness) std.Io {
        return self.threaded.io();
    }

    fn deinit(self: *Harness) void {
        self.child.kill(self.io());
        self.threaded.deinit();
    }
};

fn spawnServer(gpa: std.mem.Allocator, threaded: *std.Io.Threaded, port: u16) !Harness {
    threaded.* = .init(gpa, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var port_buf: [8]u8 = undefined;
    const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{port});

    const argv = [_][]const u8{ build_options.server_exe, "--port", port_str };
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    errdefer child.kill(io);

    try waitForReady(io, port);
    return .{ .threaded = threaded, .child = child, .port = port };
}

test "server boots, serves pages, returns expected status codes" {
    const gpa = std.testing.allocator;

    var threaded: std.Io.Threaded = undefined;
    var harness = try spawnServer(gpa, &threaded, TEST_PORT);
    defer harness.deinit();
    const io = harness.io();

    {
        var resp = try request(io, gpa, TEST_PORT, "GET", "/");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "<h1>Verve</h1>") != null);
    }
    {
        var resp = try request(io, gpa, TEST_PORT, "GET", "/counter");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "z-bind=\"count\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "z-bind=\"clicks\"") != null);
    }
    {
        var resp = try request(io, gpa, TEST_PORT, "GET", "/missing");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 404), resp.status);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "404") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "/missing") != null);
    }
    {
        var resp = try request(io, gpa, TEST_PORT, "POST", "/counter");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 405), resp.status);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "405") != null);
    }
    {
        var resp = try request(io, gpa, TEST_PORT, "GET", "/health");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"ok\"") != null);
    }
    {
        var resp = try request(io, gpa, TEST_PORT, "GET", "/client.wasm");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expect(resp.body.len > 0);
    }
}

test "form-encoded /api/addTodo + /api/removeTodo updates /todos" {
    const gpa = std.testing.allocator;

    var threaded: std.Io.Threaded = undefined;
    var harness = try spawnServer(gpa, &threaded, TEST_PORT + 1);
    defer harness.deinit();
    const io = harness.io();
    const port = harness.port;

    // Initial: page renders, no list items
    {
        var resp = try request(io, gpa, port, "GET", "/todos");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "<h1>Todos</h1>") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "<li>") == null);
    }

    // Add two items via form-encoded POST
    {
        var resp = try postForm(io, gpa, port, "/api/addTodo", "text=buy+milk");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 303), resp.status);
    }
    {
        var resp = try postForm(io, gpa, port, "/api/addTodo", "text=write%20tests");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 303), resp.status);
    }

    // Page now shows both items
    {
        var resp = try request(io, gpa, port, "GET", "/todos");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "buy milk") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "write tests") != null);
    }

    // Empty text rejected (Action returns error.EmptyTodo → 500)
    {
        var resp = try postForm(io, gpa, port, "/api/addTodo", "text=");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 500), resp.status);
    }

    // Remove first item, second remains
    {
        var resp = try postForm(io, gpa, port, "/api/removeTodo", "index=0");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 303), resp.status);
    }
    {
        var resp = try request(io, gpa, port, "GET", "/todos");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "buy milk") == null);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "write tests") != null);
    }
}

const WorkerCtx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    port: u16,
    body: []const u8,
    status: u16 = 0,
    err: ?anyerror = null,
};

fn concurrentWorker(ctx: *WorkerCtx) void {
    var resp = postForm(ctx.io, ctx.gpa, ctx.port, "/api/addTodo", ctx.body) catch |err| {
        ctx.err = err;
        return;
    };
    defer resp.deinit(ctx.gpa);
    ctx.status = resp.status;
}

test "concurrent addTodo requests are serialized without races" {
    const gpa = std.testing.allocator;

    var threaded: std.Io.Threaded = undefined;
    var harness = try spawnServer(gpa, &threaded, TEST_PORT + 2);
    defer harness.deinit();
    const io = harness.io();
    const port = harness.port;

    const N: usize = 16;
    const bodies = [_][]const u8{
        "text=p0", "text=p1", "text=p2", "text=p3",
        "text=p4", "text=p5", "text=p6", "text=p7",
        "text=p8", "text=p9", "text=p10","text=p11",
        "text=p12","text=p13","text=p14","text=p15",
    };

    var contexts: [N]WorkerCtx = undefined;
    var threads: [N]std.Thread = undefined;
    for (0..N) |i| {
        contexts[i] = .{ .io = io, .gpa = gpa, .port = port, .body = bodies[i] };
        threads[i] = try std.Thread.spawn(.{}, concurrentWorker, .{&contexts[i]});
    }
    for (threads) |t| t.join();

    for (contexts) |c| {
        if (c.err) |e| return e;
        try std.testing.expectEqual(@as(u16, 303), c.status);
    }

    // All N items should appear exactly once in the rendered page.
    var resp = try request(io, gpa, port, "GET", "/todos");
    defer resp.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    for (bodies) |b| {
        // Strip the "text=" prefix from each form body to get the rendered text
        const text = b[5..];
        try std.testing.expect(std.mem.indexOf(u8, resp.body, text) != null);
    }
}
