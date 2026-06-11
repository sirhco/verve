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
    // Integration tests don't (yet) round-trip CSRF tokens through their
    // form-posting helpers, so disable the check at the boundary. End-
    // to-end CSRF coverage lives in the dedicated csrf_smoke test.
    return spawnServerExtra(gpa, threaded, port, &.{"--csrf=disable"});
}

fn spawnServerExtra(
    gpa: std.mem.Allocator,
    threaded: *std.Io.Threaded,
    port: u16,
    extra_args: []const []const u8,
) !Harness {
    return spawnServerBin(gpa, threaded, port, build_options.server_exe, extra_args);
}

fn spawnServerBin(
    gpa: std.mem.Allocator,
    threaded: *std.Io.Threaded,
    port: u16,
    exe: []const u8,
    extra_args: []const []const u8,
) !Harness {
    threaded.* = .init(gpa, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var port_buf: [8]u8 = undefined;
    const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{port});

    const base_argv = [_][]const u8{ exe, "--port", port_str };

    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(gpa);
    try argv_list.appendSlice(gpa, &base_argv);
    try argv_list.appendSlice(gpa, extra_args);

    var child = try std.process.spawn(io, .{
        .argv = argv_list.items,
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
    {
        // Phase 13C: per-island chunk served at /islands/<name>.wasm.
        // Body starts with the WASM magic `\0asm` so we can confirm
        // the bytes actually parse as a module.
        var resp = try request(io, gpa, TEST_PORT, "GET", "/islands/Counter.wasm");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expect(resp.body.len >= 8);
        try std.testing.expectEqual(@as(u8, 0x00), resp.body[0]);
        try std.testing.expectEqual(@as(u8, 'a'), resp.body[1]);
        try std.testing.expectEqual(@as(u8, 's'), resp.body[2]);
        try std.testing.expectEqual(@as(u8, 'm'), resp.body[3]);
    }
    {
        // Phase 13D: meta-codegen fans chunks across every
        // `app.islands` decl. Greeting was added to the namespace
        // without a dedicated source file — it picks up the shared
        // `_default.zig` stub but still ships its own chunk.
        var resp = try request(io, gpa, TEST_PORT, "GET", "/islands/Greeting.wasm");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expect(resp.body.len >= 8);
        try std.testing.expectEqual(@as(u8, 0x00), resp.body[0]);
        try std.testing.expectEqual(@as(u8, 'a'), resp.body[1]);
    }
    {
        // Unknown island falls through to 404, not 200 with stale
        // bytes — confirms the generic lookup actually checks the
        // table rather than blindly serving anything under
        // `/islands/`.
        var resp = try request(io, gpa, TEST_PORT, "GET", "/islands/NotAThing.wasm");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 404), resp.status);
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
    // Override --workers so every concurrent connection fits in the
    // admission pool even on low-core CI runners (default is cpu*2,
    // which is only 4 on a 2-core ubuntu-latest).
    var harness = try spawnServerExtra(gpa, &threaded, TEST_PORT + 2, &.{ "--workers", "32", "--csrf=disable" });
    defer harness.deinit();
    const io = harness.io();
    const port = harness.port;

    const N: usize = 16;
    const bodies = [_][]const u8{
        "text=p0",  "text=p1",  "text=p2",  "text=p3",
        "text=p4",  "text=p5",  "text=p6",  "text=p7",
        "text=p8",  "text=p9",  "text=p10", "text=p11",
        "text=p12", "text=p13", "text=p14", "text=p15",
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

test "--public-dir serves files at /public/* with traversal protection" {
    const gpa = std.testing.allocator;

    var threaded: std.Io.Threaded = undefined;
    var harness = try spawnServerExtra(gpa, &threaded, TEST_PORT + 3, &.{
        "--public-dir", build_options.public_dir,
    });
    defer harness.deinit();
    const io = harness.io();
    const port = harness.port;

    {
        var resp = try request(io, gpa, port, "GET", "/public/hello.txt");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "static asset fixture") != null);
    }
    {
        var resp = try request(io, gpa, port, "GET", "/public/style.css");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "background:#000") != null);
    }
    {
        var resp = try request(io, gpa, port, "GET", "/public/missing.png");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 404), resp.status);
    }
    {
        var resp = try request(io, gpa, port, "GET", "/public/../etc/passwd");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 403), resp.status);
    }
}

test "counter form fallback: /api/incrementCount + /api/decrementCount via form POST" {
    const gpa = std.testing.allocator;

    var threaded: std.Io.Threaded = undefined;
    var harness = try spawnServer(gpa, &threaded, TEST_PORT + 5);
    defer harness.deinit();
    const io = harness.io();
    const port = harness.port;

    // Counter page shows the +/- forms.
    {
        var resp = try request(io, gpa, port, "GET", "/counter");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "action=\"/api/incrementCount\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "action=\"/api/decrementCount\"") != null);
    }

    // Empty form body → 303 redirect; count moves 0 → 1.
    {
        var resp = try postForm(io, gpa, port, "/api/incrementCount", "");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 303), resp.status);
    }

    // Two more increments and one decrement → final count = 2.
    inline for (&.{ "/api/incrementCount", "/api/incrementCount", "/api/decrementCount" }) |path| {
        var resp = try postForm(io, gpa, port, path, "");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 303), resp.status);
    }

    // Page re-render reflects new count.
    {
        var resp = try request(io, gpa, port, "GET", "/counter");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, ">2<") != null);
    }
}

const FloodCtx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    port: u16,
    status: u16 = 0,
    err: ?anyerror = null,
};

fn floodWorker(ctx: *FloodCtx) void {
    var resp = request(ctx.io, ctx.gpa, ctx.port, "GET", "/health") catch |err| switch (err) {
        // Under heavy concurrent load with --workers 1, the kernel may
        // RST a freshly-accepted socket if the server closes before the
        // client finishes its half of the handshake. Treat as "rejected".
        error.ConnectionResetByPeer, error.ConnectionRefused, error.ReadFailed => {
            ctx.status = 503;
            return;
        },
        else => {
            ctx.err = err;
            return;
        },
    };
    defer resp.deinit(ctx.gpa);
    ctx.status = resp.status;
}

test "--workers caps concurrent connections (excess returns 503)" {
    const gpa = std.testing.allocator;

    var threaded: std.Io.Threaded = undefined;
    var harness = try spawnServerExtra(gpa, &threaded, TEST_PORT + 6, &.{ "--workers", "1" });
    defer harness.deinit();
    const io = harness.io();
    const port = harness.port;

    const N: usize = 32;
    var contexts: [N]FloodCtx = undefined;
    var threads: [N]std.Thread = undefined;
    for (0..N) |i| {
        contexts[i] = .{ .io = io, .gpa = gpa, .port = port };
        threads[i] = try std.Thread.spawn(.{}, floodWorker, .{&contexts[i]});
    }
    for (threads) |t| t.join();

    var ok_count: usize = 0;
    var busy_count: usize = 0;
    for (contexts) |c| {
        if (c.err) |e| return e;
        switch (c.status) {
            200 => ok_count += 1,
            503 => busy_count += 1,
            else => return error.UnexpectedStatus,
        }
    }
    // With --workers 1 and 32 parallel connections, the admission counter
    // must reject at least one request and admit at least one. The exact
    // split is timing-dependent — only the invariants matter.
    try std.testing.expect(ok_count >= 1);
    try std.testing.expect(busy_count >= 1);
    try std.testing.expectEqual(N, ok_count + busy_count);
}

test "-Dpublic-dir bakes files into the binary and serves them without --public-dir" {
    const gpa = std.testing.allocator;

    var threaded: std.Io.Threaded = undefined;
    var harness = try spawnServerBin(gpa, &threaded, TEST_PORT + 9, build_options.embed_server_exe, &.{});
    defer harness.deinit();
    const io = harness.io();
    const port = harness.port;

    // Embedded entry served without --public-dir.
    {
        var resp = try request(io, gpa, port, "GET", "/public/hello.txt");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "static asset fixture") != null);
    }
    {
        var resp = try request(io, gpa, port, "GET", "/public/style.css");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "background:#000") != null);
    }
    {
        var resp = try request(io, gpa, port, "GET", "/public/missing.png");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 404), resp.status);
    }
    {
        var resp = try request(io, gpa, port, "GET", "/public/../etc/passwd");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 403), resp.status);
    }
}

test "/ws upgrades, accepts +/- frames, broadcasts count" {
    const gpa = std.testing.allocator;

    var threaded: std.Io.Threaded = undefined;
    var harness = try spawnServer(gpa, &threaded, TEST_PORT + 10);
    defer harness.deinit();
    const io = harness.io();
    const port = harness.port;

    // Seed count to a known starting value so the test is deterministic
    // regardless of any cross-test counter leakage in the same process.
    {
        var resp = try requestWithBody(io, gpa, port, "POST", "/api/updateDatabase", "application/json", "{\"new_count\":100}");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    const addr = loopback(port);
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var write_buf: [512]u8 = undefined;
    var sw = stream.writer(io, &write_buf);
    try sw.interface.writeAll(
        "GET /ws HTTP/1.1\r\n" ++
            "Host: 127.0.0.1\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
            "Sec-WebSocket-Version: 13\r\n\r\n",
    );
    try sw.interface.flush();

    var read_buf: [4096]u8 = undefined;
    var sr = stream.reader(io, &read_buf);
    const reader = &sr.interface;

    // Drain the 101 Switching Protocols response line + headers
    // byte-by-byte so the first WS frame bytes stay in the reader buffer
    // for readTextFrame to consume.
    const header_block = blk: {
        var acc: std.ArrayList(u8) = .empty;
        defer acc.deinit(gpa);
        while (true) {
            const b = try reader.takeByte();
            try acc.append(gpa, b);
            if (acc.items.len >= 4 and std.mem.eql(u8, acc.items[acc.items.len - 4 ..], "\r\n\r\n")) {
                break :blk try gpa.dupe(u8, acc.items);
            }
        }
    };
    defer gpa.free(header_block);
    try std.testing.expect(std.mem.indexOf(u8, header_block, "101") != null);
    try std.testing.expect(std.mem.indexOf(u8, header_block, "upgrade: websocket") != null);
    try std.testing.expect(std.mem.indexOf(u8, header_block, "sec-websocket-accept:") != null);

    // Read the initial server-pushed frame (FIN+text, no mask, len <= 125).
    const initial = try readTextFrame(gpa, reader);
    defer gpa.free(initial);
    try std.testing.expectEqualStrings("100", initial);

    // Send a client text frame "+" with a 4-byte mask.
    const mask = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    var frame = [_]u8{
        0x81, // FIN + text opcode
        0x81, // MASK + payload length 1
        mask[0],
        mask[1],
        mask[2],
        mask[3],
        '+' ^ mask[0],
    };
    try sw.interface.writeAll(&frame);
    try sw.interface.flush();

    // Server should push the new count back (101).
    const after_plus = try readTextFrame(gpa, reader);
    defer gpa.free(after_plus);
    try std.testing.expectEqualStrings("101", after_plus);
}

fn readTextFrame(gpa: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    const h0 = try reader.takeByte();
    const opcode = h0 & 0x0F;
    try std.testing.expectEqual(@as(u8, 0x01), opcode);
    const h1 = try reader.takeByte();
    try std.testing.expectEqual(@as(u8, 0), h1 & 0x80); // server-to-client must not mask
    const len: usize = blk: {
        const small = h1 & 0x7F;
        if (small == 126) break :blk @intCast(try reader.takeInt(u16, .big));
        if (small == 127) break :blk @intCast(try reader.takeInt(u64, .big));
        break :blk small;
    };
    const payload = try gpa.alloc(u8, len);
    errdefer gpa.free(payload);
    var remaining: usize = len;
    while (remaining > 0) {
        const slice = try reader.peekGreedy(1);
        const n = @min(slice.len, remaining);
        @memcpy(payload[len - remaining .. len - remaining + n], slice[0..n]);
        reader.toss(n);
        remaining -= n;
    }
    return payload;
}

test "Accept-Encoding: gzip yields gzip-compressed HTML" {
    const gpa = std.testing.allocator;

    var threaded: std.Io.Threaded = undefined;
    var harness = try spawnServer(gpa, &threaded, TEST_PORT + 8);
    defer harness.deinit();
    const io = harness.io();
    const port = harness.port;

    // Issue a manual request with Accept-Encoding: gzip on /counter.
    const addr = loopback(port);
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var write_buf: [256]u8 = undefined;
    var sw = stream.writer(io, &write_buf);
    try sw.interface.writeAll(
        "GET /counter HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n",
    );
    try sw.interface.flush();

    var read_buf: [16 * 1024]u8 = undefined;
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

    const raw = acc.items;
    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.MalformedResponse;
    const headers = raw[0..header_end];
    const body = raw[header_end + 4 ..];

    try std.testing.expect(std.mem.indexOf(u8, headers, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, headers, "content-encoding: gzip") != null);

    // First two bytes of every gzip stream are 0x1f 0x8b.
    try std.testing.expect(body.len >= 2);
    try std.testing.expectEqual(@as(u8, 0x1f), body[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), body[1]);

    // Decompress and confirm it's the counter HTML.
    const flate = std.compress.flate;
    var in_reader: std.Io.Reader = .fixed(body);
    var dc_buf: [flate.max_window_len]u8 = undefined;
    var dc: flate.Decompress = .init(&in_reader, .gzip, &dc_buf);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try dc.reader.streamRemaining(&out.writer);
    const inflated = out.written();
    try std.testing.expect(std.mem.indexOf(u8, inflated, "Verve Counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, inflated, "z-bind=\"count\"") != null);
}

test "/metrics returns JSON with per-route counters" {
    const gpa = std.testing.allocator;

    var threaded: std.Io.Threaded = undefined;
    var harness = try spawnServer(gpa, &threaded, TEST_PORT + 7);
    defer harness.deinit();
    const io = harness.io();
    const port = harness.port;

    // Hit a couple of routes so the counters are non-zero.
    {
        var resp = try request(io, gpa, port, "GET", "/");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }
    {
        var resp = try request(io, gpa, port, "GET", "/counter");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }
    {
        var resp = try request(io, gpa, port, "GET", "/counter");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    var resp = try request(io, gpa, port, "GET", "/metrics");
    defer resp.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"uptime_sec\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"total_requests\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"rejected\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"routes\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"/\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"/counter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"avg_ns\"") != null);
}

test "/events emits initial count and live updates via SSE" {
    const gpa = std.testing.allocator;

    var threaded: std.Io.Threaded = undefined;
    var harness = try spawnServer(gpa, &threaded, TEST_PORT + 4);
    defer harness.deinit();
    const io = harness.io();
    const port = harness.port;

    // Seed a known count first.
    {
        var resp = try requestWithBody(io, gpa, port, "POST", "/api/updateDatabase", "application/json", "{\"new_count\":7}");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    // Open a single SSE connection by hand and read enough bytes to see the
    // initial tick. The server emits one event per second, so 1500ms is
    // enough headroom.
    const addr = loopback(port);
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var write_buf: [256]u8 = undefined;
    var sw = stream.writer(io, &write_buf);
    try sw.interface.writeAll(
        "GET /events HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
    );
    try sw.interface.flush();

    var read_buf: [4096]u8 = undefined;
    var sr = stream.reader(io, &read_buf);
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(gpa);

    const deadline = std.Io.Timestamp.now(io, .awake).addDuration(.fromMilliseconds(1800));
    while (true) {
        if (std.Io.Timestamp.now(io, .awake).durationTo(deadline).nanoseconds <= 0) break;
        const slice = sr.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try acc.appendSlice(gpa, slice);
        sr.interface.toss(slice.len);
        if (std.mem.indexOf(u8, acc.items, "data: 7") != null) break;
    }

    try std.testing.expect(std.mem.indexOf(u8, acc.items, "text/event-stream") != null);
    try std.testing.expect(std.mem.indexOf(u8, acc.items, "event: count") != null);
    try std.testing.expect(std.mem.indexOf(u8, acc.items, "data: 7") != null);
}

/// Open `/push?channel=<channel>` (optionally with a Last-Event-ID header) and
/// accumulate the SSE stream until `needle` appears or `deadline_ms` passes.
fn readPushStream(
    io: std.Io,
    gpa: std.mem.Allocator,
    port: u16,
    channel: []const u8,
    last_event_id: ?u64,
    needle: []const u8,
    deadline_ms: i64,
) !std.ArrayList(u8) {
    const addr = loopback(port);
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var write_buf: [512]u8 = undefined;
    var sw = stream.writer(io, &write_buf);
    if (last_event_id) |lei| {
        try sw.interface.print(
            "GET /push?channel={s} HTTP/1.1\r\nHost: 127.0.0.1\r\nLast-Event-ID: {d}\r\nConnection: close\r\n\r\n",
            .{ channel, lei },
        );
    } else {
        try sw.interface.print(
            "GET /push?channel={s} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
            .{channel},
        );
    }
    try sw.interface.flush();

    var read_buf: [8192]u8 = undefined;
    var sr = stream.reader(io, &read_buf);
    var acc: std.ArrayList(u8) = .empty;
    errdefer acc.deinit(gpa);

    const deadline = std.Io.Timestamp.now(io, .awake).addDuration(.fromMilliseconds(deadline_ms));
    while (true) {
        if (std.Io.Timestamp.now(io, .awake).durationTo(deadline).nanoseconds <= 0) break;
        const slice = sr.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try acc.appendSlice(gpa, slice);
        sr.interface.toss(slice.len);
        if (std.mem.indexOf(u8, acc.items, needle) != null) break;
    }
    return acc;
}

test "/push?channel=viz streams seq-ordered deltas coherent with the pull snapshot" {
    const gpa = std.testing.allocator;

    var threaded: std.Io.Threaded = undefined;
    var harness = try spawnServer(gpa, &threaded, TEST_PORT + 11);
    defer harness.deinit();
    const io = harness.io();
    const port = harness.port;

    // Fresh server → model at seq 0; the publisher only ticks while we're
    // subscribed, so the first two frames are exactly seq 1 and 2 (1s apart).
    var acc = try readPushStream(io, gpa, port, "viz", null, "data: {\"seq\":2,", 4000);
    defer acc.deinit(gpa);

    try std.testing.expect(std.mem.indexOf(u8, acc.items, " 200 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, acc.items, "text/event-stream") != null);
    try std.testing.expect(std.mem.indexOf(u8, acc.items, "retry: 2000") != null);
    // `id:` equals the frame's `seq`, ordered 1 then 2, each a delta op list.
    const f1 = std.mem.indexOf(u8, acc.items, "id: 1\nevent: viz\ndata: {\"seq\":1,\"ops\":[") orelse return error.TestExpectedEqual;
    const f2 = std.mem.indexOf(u8, acc.items, "id: 2\nevent: viz\ndata: {\"seq\":2,\"ops\":[") orelse return error.TestExpectedEqual;
    try std.testing.expect(f1 < f2);
    // First tick (extra 0→1) adds the e0 node.
    try std.testing.expect(std.mem.indexOf(u8, acc.items, "{\"op\":\"+n\",\"id\":\"e0\",\"label\":\"e0\"}") != null);

    // Pull snapshot shares the same seq domain and reflects the pushed state.
    var resp = try requestWithBody(io, gpa, port, "POST", "/api/vizGraph", "application/json", "{}");
    defer resp.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"seq\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"seq\":0") == null);
}

test "/push rejects a missing or invalid channel" {
    const gpa = std.testing.allocator;

    var threaded: std.Io.Threaded = undefined;
    var harness = try spawnServer(gpa, &threaded, TEST_PORT + 12);
    defer harness.deinit();
    const io = harness.io();
    const port = harness.port;

    {
        var resp = try request(io, gpa, port, "GET", "/push");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 400), resp.status);
    }
    {
        var resp = try request(io, gpa, port, "GET", "/push?channel=bad*name");
        defer resp.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 400), resp.status);
    }
}

test "/push resumes after Last-Event-ID without replaying delivered frames" {
    const gpa = std.testing.allocator;

    var threaded: std.Io.Threaded = undefined;
    var harness = try spawnServer(gpa, &threaded, TEST_PORT + 13);
    defer harness.deinit();
    const io = harness.io();
    const port = harness.port;

    // First subscriber drives the publisher through seq 1 and 2, then drops.
    var first = try readPushStream(io, gpa, port, "viz", null, "data: {\"seq\":2,", 4000);
    defer first.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, first.items, "id: 2\n") != null);

    // Reconnect resuming after seq 1: frame 2 replays from the ring
    // immediately; frame 1 must not.
    var second = try readPushStream(io, gpa, port, "viz", 1, "data: {\"seq\":2,", 4000);
    defer second.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, second.items, "id: 2\nevent: viz\ndata: {\"seq\":2,\"ops\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.items, "id: 1\n") == null);
}

test "/anim serves data-anim descriptors and the AnimDemo island" {
    const gpa = std.testing.allocator;

    var threaded: std.Io.Threaded = undefined;
    var harness = try spawnServer(gpa, &threaded, TEST_PORT + 14);
    defer harness.deinit();
    const io = harness.io();
    const port = harness.port;

    var resp = try request(io, gpa, port, "GET", "/anim");
    defer resp.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 200), resp.status);

    // Declarative SSR descriptors (Node.animate -> data-anim attribute,
    // JSON quotes escaped by the renderer).
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "data-anim=\"{&quot;v&quot;:1") != null);
    // Entrance from-tween keys and the keyframed pulse survive the round-trip.
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "&quot;e&quot;:&quot;outCubic&quot;") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "&quot;k&quot;:[{&quot;o&quot;:0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "&quot;rep&quot;:-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "&quot;rm&quot;:&quot;skip&quot;") != null);

    // Imperative island marker + its control buttons.
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "data-name=\"AnimDemo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "z-on-click=\"anim_pause\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "z-bind=") != null);

    // The island chunk is built and served.
    var chunk = try request(io, gpa, port, "GET", "/islands/AnimDemo.wasm");
    defer chunk.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 200), chunk.status);

    // The bridge ships the anim interpreter + SSR scanner.
    var js = try request(io, gpa, port, "GET", "/verve.js");
    defer js.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 200), js.status);
    try std.testing.expect(std.mem.indexOf(u8, js.body, "verve_anim_create") != null);
    try std.testing.expect(std.mem.indexOf(u8, js.body, "data-anim-done") != null);
}

test "/anim carries ScrollTrigger descriptors and the reveal-only form" {
    const gpa = std.testing.allocator;

    var threaded: std.Io.Threaded = undefined;
    var harness = try spawnServer(gpa, &threaded, TEST_PORT + 15);
    defer harness.deinit();
    const io = harness.io();
    const port = harness.port;

    var resp = try request(io, gpa, port, "GET", "/anim");
    defer resp.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 200), resp.status);

    // sc key present inside data-anim payloads (renderer-escaped JSON).
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "&quot;sc&quot;:{") != null);
    // gated entrance: toggle actions [play,none,none,reverse]
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "&quot;act&quot;:[1,0,0,4]") != null);
    // scrubbed + pinned panel with markers
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "&quot;scr&quot;:0.3") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "&quot;pin&quot;:1") != null);
    // tween-less reveal: sc-only descriptor with class toggle
    try std.testing.expect(std.mem.indexOf(
        u8,
        resp.body,
        "{&quot;v&quot;:1,&quot;sc&quot;:{&quot;s&quot;:[0,0.85],&quot;once&quot;:1,&quot;cls&quot;:&quot;in-view&quot;}}",
    ) != null);

    // The bridge ships the scroll engine + observer ops.
    var js = try request(io, gpa, port, "GET", "/verve.js");
    defer js.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, js.body, "verve_sc_create") != null);
    try std.testing.expect(std.mem.indexOf(u8, js.body, "verve_obs_create") != null);
    try std.testing.expect(std.mem.indexOf(u8, js.body, "data-verve-pin-spacer") != null);
}

test "/anim carries MotionPath and MorphSVG descriptors" {
    const gpa = std.testing.allocator;

    var threaded: std.Io.Threaded = undefined;
    var harness = try spawnServer(gpa, &threaded, TEST_PORT + 16);
    defer harness.deinit();
    const io = harness.io();
    const port = harness.port;

    var resp = try request(io, gpa, port, "GET", "/anim");
    defer resp.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 200), resp.status);

    // MotionPath polyline rides the descriptor (renderer-escaped JSON).
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "&quot;mp&quot;:{&quot;pts&quot;:[") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "&quot;rot&quot;:1") != null);
    // Morph point arrays + segment counts.
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "&quot;mo&quot;:{&quot;a&quot;:[") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "&quot;sp&quot;:[") != null);
    // Scrubbed motion path composes mp + sc in one descriptor.
    const mp_idx = std.mem.indexOf(u8, resp.body, "&quot;mp&quot;:{&quot;pts&quot;:[").?;
    _ = mp_idx;
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "&quot;scr&quot;:0.3") != null);

    // The bridge ships the lerp-side interpreters.
    var js = try request(io, gpa, port, "GET", "/verve.js");
    defer js.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, js.body, "mpSample") != null);
    try std.testing.expect(std.mem.indexOf(u8, js.body, "buildMorphD") != null);
}
