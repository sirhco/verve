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
    /// the filesystem (smoke_done writes checksum.txt via it) or
    /// open network sockets (fetch_url).
    io: std.Io,
    /// Process environment block plumbed from main. Required by
    /// `desktop.system.locale` + `desktop.paths.*` which read XDG /
    /// HOME / LANG variables.
    environ: std.process.Environ,
};

var ctx: RouterCtx = undefined;

const Router = desktop.Router(RouterCtx, Routes);

pub const onMessage = Router.dispatch;

/// Tray-menu item click. Ids match the menu spec wired in `main.zig`
/// (1 = focus window, 2 = fire the same `notify` route as the IPC
/// button, 99 = quit). Unknown ids log + ignore.
pub fn onTrayItem(c: ?*anyopaque, item_id: u32) void {
    const r: *RouterCtx = @ptrCast(@alignCast(c orelse return));
    switch (item_id) {
        1 => {
            std.log.info("[tray] show window", .{});
            r.window.show();
            r.window.focus();
        },
        2 => {
            std.log.info("[tray] notify", .{});
            desktop.notifications.show(std.heap.page_allocator, .{
                .title = "Verve Desktop",
                .body = "Notification from the tray menu.",
            }) catch {};
        },
        99 => {
            std.log.info("[tray] quit", .{});
            r.window.terminate();
        },
        else => std.log.warn("[tray] unknown id {d}", .{item_id}),
    }
}

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

/// Drag-and-drop handler. Called when the user drops files onto the window.
/// Logs each path; evalJs broadcasts to the page for demo purposes.
pub fn onDragDrop(c: ?*anyopaque, paths: []const []const u8) void {
    const r: *RouterCtx = @ptrCast(@alignCast(c orelse return));
    for (paths) |path| {
        std.log.info("[drag-drop] {s}", .{path});
        var buf: [4096]u8 = undefined;
        const js = std.fmt.bufPrint(&buf,
            "window.verve.handleDragDrop && window.verve.handleDragDrop(\"{s}\");",
            .{path},
        ) catch continue;
        r.window.evalJs(js);
    }
}

pub fn attach(window: *desktop.Window, assets: []const desktop.AssetEntry, smoke_dir: ?[]const u8, io: std.Io, environ: std.process.Environ) *RouterCtx {
    ctx = .{ .window = window, .assets = assets, .smoke_dir = smoke_dir, .io = io, .environ = environ };
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

    /// Fire `Window.deliverUrl` with a synthetic verve://app URL so
    /// the demo deep-link card lights up without leaving the app.
    /// Real cold-launch URLs arrive via NSAppleEventManager (macOS)
    /// or argv (Win/Linux) — see main.zig for the production path.
    pub const deep_link_test = struct {
        pub const Args = struct {
            url: []const u8 = "verve://app/demo?from=ipc",
        };
        pub const Reply = struct { ok: bool };
        pub fn handle(c: *RouterCtx, _: std.mem.Allocator, args: Args) !Reply {
            c.window.deliverUrl(args.url);
            return .{ .ok = true };
        }
    };

    /// System / runtime info. Wraps the per-platform `desktop.system`
    /// readouts so the UI can render them as a `dl.kv` table. All
    /// fields best-effort: failures collapse to defaults rather than
    /// failing the whole route.
    pub const system_info = struct {
        pub const Args = struct {};
        pub const Reply = struct {
            os_version: []const u8 = "",
            locale: []const u8 = "",
            cpu_count: usize = 0,
            total_memory_bytes: u64 = 0,
            uptime_seconds: u64 = 0,
        };
        pub fn handle(c: *RouterCtx, alloc: std.mem.Allocator, _: Args) !Reply {
            const osv = desktop.system.osVersion(alloc) catch try alloc.dupe(u8, "unknown");
            const loc = desktop.system.locale(alloc, c.environ) catch try alloc.dupe(u8, "unknown");
            return .{
                .os_version = osv,
                .locale = loc,
                .cpu_count = desktop.system.cpuCount(),
                .total_memory_bytes = desktop.system.totalMemory(),
                .uptime_seconds = desktop.system.uptime(),
            };
        }
    };

    /// Disk space at the user's home directory.
    pub const disk_space = struct {
        pub const Args = struct {};
        pub const Reply = struct {
            ok: bool,
            path: []const u8 = "",
            total_bytes: u64 = 0,
            available_bytes: u64 = 0,
        };
        pub fn handle(c: *RouterCtx, alloc: std.mem.Allocator, _: Args) !Reply {
            const home = desktop.paths.homeDir(alloc, c.environ) catch return .{ .ok = false };
            const space = desktop.disk.spaceAt(alloc, home) catch return .{ .ok = false, .path = home };
            return .{
                .ok = true,
                .path = home,
                .total_bytes = space.total,
                .available_bytes = space.available,
            };
        }
    };

    /// Native file-open dialog. Returns the chosen path + file size
    /// in bytes. Cancellation maps to ok:false with status="cancelled".
    pub const open_file = struct {
        pub const Args = struct {};
        pub const Reply = struct {
            ok: bool,
            status: []const u8 = "",
            path: []const u8 = "",
            size_bytes: u64 = 0,
        };
        pub fn handle(c: *RouterCtx, alloc: std.mem.Allocator, _: Args) !Reply {
            const path = c.window.openFileDialog(alloc, .{
                .title = "Pick any file",
            }) catch |err| switch (err) {
                error.Cancelled => return .{ .ok = false, .status = "cancelled" },
                error.Unsupported => return .{ .ok = false, .status = "unsupported" },
                else => return .{ .ok = false, .status = "backend_error" },
            };
            const st = std.Io.Dir.cwd().statFile(c.io, path, .{}) catch {
                return .{ .ok = true, .status = "ok", .path = path, .size_bytes = 0 };
            };
            return .{ .ok = true, .status = "ok", .path = path, .size_bytes = st.size };
        }
    };

    /// Window controls. `action` selects which Window method to fire.
    /// Useful as a manual sanity check for the lifecycle methods.
    pub const window_action = struct {
        pub const Args = struct {
            action: []const u8, // "minimize" | "maximize" | "restore" | "center" | "fullscreen_on" | "fullscreen_off"
        };
        pub const Reply = struct { ok: bool };
        pub fn handle(c: *RouterCtx, _: std.mem.Allocator, args: Args) !Reply {
            const w = c.window;
            if (std.mem.eql(u8, args.action, "minimize")) w.minimize()
            else if (std.mem.eql(u8, args.action, "maximize")) w.maximize()
            else if (std.mem.eql(u8, args.action, "restore")) w.restore()
            else if (std.mem.eql(u8, args.action, "center")) w.center()
            else if (std.mem.eql(u8, args.action, "fullscreen_on")) w.setFullscreen(true)
            else if (std.mem.eql(u8, args.action, "fullscreen_off")) w.setFullscreen(false)
            else return .{ .ok = false };
            return .{ .ok = true };
        }
    };

    /// HTTP fetch demo. Hits the GitHub public REST API for the Zig
    /// repo and surfaces a few headline fields. Demonstrates real
    /// outbound HTTP from a Zig IPC handler with JSON parsing +
    /// per-route error mapping. The dispatcher arena is the
    /// allocator threaded in as `_alloc` — replies that reference
    /// allocator-owned strings stay valid through the JSON-encode
    /// step.
    pub const fetch_url = struct {
        pub const Args = struct {
            /// Defaults to a known stable public endpoint. Override
            /// from JS to exercise other GETs.
            url: []const u8 = "https://api.github.com/repos/ziglang/zig",
        };
        pub const Reply = struct {
            ok: bool,
            status: []const u8 = "",
            full_name: []const u8 = "",
            description: []const u8 = "",
            stars: u64 = 0,
            forks: u64 = 0,
        };
        pub fn handle(c: *RouterCtx, alloc: std.mem.Allocator, args: Args) !Reply {
            var client: std.http.Client = .{ .allocator = alloc, .io = c.io };
            defer client.deinit();

            var aw: std.Io.Writer.Allocating = .init(alloc);
            defer aw.deinit();

            const headers = [_]std.http.Header{
                .{ .name = "User-Agent", .value = "verve-desktop-demo" },
                .{ .name = "Accept", .value = "application/vnd.github+json" },
            };

            const result = client.fetch(.{
                .location = .{ .url = args.url },
                .method = .GET,
                .extra_headers = &headers,
                .response_writer = &aw.writer,
            }) catch {
                return .{ .ok = false, .status = "network_error" };
            };
            const code = @intFromEnum(result.status);
            if (code < 200 or code >= 300) {
                return .{ .ok = false, .status = "http_error" };
            }

            // GitHub returns ~30+ fields. Pull only the ones we render.
            const Repo = struct {
                full_name: []const u8 = "",
                description: ?[]const u8 = null,
                stargazers_count: u64 = 0,
                forks_count: u64 = 0,
            };
            const parsed = std.json.parseFromSlice(Repo, alloc, aw.written(), .{
                .ignore_unknown_fields = true,
            }) catch {
                return .{ .ok = false, .status = "parse_error" };
            };
            defer parsed.deinit();
            return .{
                .ok = true,
                .status = "ok",
                .full_name = try alloc.dupe(u8, parsed.value.full_name),
                .description = try alloc.dupe(u8, parsed.value.description orelse ""),
                .stars = parsed.value.stargazers_count,
                .forks = parsed.value.forks_count,
            };
        }
    };

    pub const print_page = struct {
        pub const Args = struct {
            /// "default" | "browser" | "system"
            kind: []const u8 = "default",
        };
        pub const Reply = struct { ok: bool, status: []const u8 };
        pub fn handle(c: *RouterCtx, _: std.mem.Allocator, args: Args) !Reply {
            const kind: desktop.PrintDialogKind =
                if (std.mem.eql(u8, args.kind, "system")) .system
                else if (std.mem.eql(u8, args.kind, "browser")) .browser
                else .default;
            c.window.printWithOptions(.{ .kind = kind }) catch |err| switch (err) {
                error.Cancelled => return .{ .ok = false, .status = "cancelled" },
                error.Unsupported => return .{ .ok = false, .status = "unsupported" },
                else => return .{ .ok = false, .status = "backend_error" },
            };
            return .{ .ok = true, .status = "ok" };
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
