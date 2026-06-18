//! mission-control desktop entry point.
//!
//! Starts the Verve HTTP server on a background thread (same binary, same
//! port as the web build — default 8080, override with --port), then opens a
//! native OS window (WKWebView / WebView2 / WebKitGTK) that navigates to
//! http://127.0.0.1:<port>/. SSE, WebSockets, the GL asset pipeline, and the
//! metrics sim all run inside the embedded server — no custom URL scheme or
//! IPC wiring needed.

const std = @import("std");
const builtin = @import("builtin");
const desktop = @import("desktop");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // Sniff --port from argv so we can navigate the webview to the right
    // address. The server thread parses argv independently via parseCli.
    const DEFAULT_PORT: u16 = 8080;
    var port: u16 = DEFAULT_PORT;
    {
        const args = try init.minimal.args.toSlice(gpa);
        defer gpa.free(args);
        var i: usize = 1;
        while (i + 1 < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--port")) {
                port = std.fmt.parseInt(u16, args[i + 1], 10) catch DEFAULT_PORT;
            }
        }
    }

    // Spawn the full Verve HTTP server on a background thread. The server
    // loops forever accepting connections; the process exits when the window
    // is closed (window.run() returns → main returns → OS tears down threads).
    const server_thread = try std.Thread.spawn(.{}, runServer, .{init});
    server_thread.detach();

    // Give the server a moment to bind its socket before we navigate.
    // 300 ms is ample; openListenSocket runs synchronously inside server main.
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(300), .awake) catch {};

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/", .{port});
    defer gpa.free(url);
    std.log.info("mission-control desktop: opening window → {s}", .{url});

    // Open the native window. No embedded assets — the webview talks HTTP to
    // the local server, which handles all routes, SSE, WS, GL assets, etc.
    var window = try desktop.Window.init(gpa, .{
        .title = "Mission Control — Verve",
        .width = 1280,
        .height = 800,
        .devtools = builtin.mode == .Debug,
        .initial_path = "", // navigate below via loadUrl; no verve:// scheme
        .assets = &.{},
    });
    defer window.deinit();

    try window.loadUrl(url);

    // Blocks until the window is closed. Returning from run() exits main()
    // and the OS tears down the detached server thread.
    window.run();
}

/// Thread body: runs the Verve HTTP server. `server_main.main` is the same
/// entry point the web build uses; it reads --port / --host from argv.
const server_main = @import("server_main");

fn runServer(init: std.process.Init) void {
    server_main.main(init) catch |err| {
        std.log.err("mission-control server thread: {s}", .{@errorName(err)});
    };
}
