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
// `verve.ai` supplies the tool-declaration vocabulary and the shared
// security gate the `ai_tool_call` route runs through, plus the
// `Message`/`Block` types `ai_delegate`'s worker builds a request from.
const verve = @import("verve");

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
        const js = std.fmt.bufPrint(
            &buf,
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

// ---- AI delegation (`ai_delegate` / `ai_delegate_poll`) -------------------

/// Allocator for state that outlives a single IPC dispatch — the delegation
/// worker's prompt and its result. The dispatcher hands each handler an arena
/// that is freed as soon as that handler's reply is encoded, so neither can
/// live there. Same allocator the tray / deep-link callbacks in this file
/// already use for their off-dispatch scratch.
const ai_alloc = std.heap.page_allocator;

/// Single-slot state for the background `claude -p` run.
///
/// Why the answer is *polled* rather than pushed with `evalJs`: evaluating
/// script in a webview is main-thread-only on all three backends
/// (`evaluateJavaScript:` on WKWebView, `webkit_web_view_evaluate_javascript`
/// on the GTK main loop, `ExecuteScript` on the WebView2 UI thread), and the
/// platform layer exposes no main-thread marshal — `desktop.fswatch`'s module
/// doc says as much and leaves marshalling to the app. IPC dispatch already
/// runs on the thread that owns the webview, so parking the result here and
/// letting the page poll for it keeps every webview call on the right thread,
/// identically on macOS, Windows, and Linux.
///
/// Deliberately one slot: a second delegation while one is in flight is
/// refused, not queued. A queue would need a lifetime story for cancelled
/// work that a template demo shouldn't be teaching.
const AiDelegate = struct {
    const State = enum { idle, running, done };

    /// `std.atomic.Mutex` (there is no `std.Thread.Mutex` in Zig 0.16) has no
    /// blocking `lock` — only `tryLock` — so callers spin, exactly as
    /// `src/server/push.zig` does for its channel registry. Sound here
    /// because every critical section below is a handful of field
    /// assignments with no allocation and no syscall inside it.
    mutex: std.atomic.Mutex = .unlocked,
    state: State = .idle,
    /// Meaningful only in `.done`. Owned by `ai_alloc`, freed when the next
    /// result replaces it. Length zero means "nothing owned" — so the
    /// zero-length literals below are never passed to `free`.
    text: []const u8 = "",
    ok: bool = false,
};

/// File-level rather than a `RouterCtx` field: the worker thread outlives the
/// dispatch that spawned it, and `attach` assigns `ctx` as a whole struct, so
/// state reachable from another thread should not sit inside it.
var ai_state: AiDelegate = .{};

/// Spin until `ai_state.mutex` is held. See the note on the field.
fn aiLock() void {
    while (!ai_state.mutex.tryLock()) std.atomic.spinLoopHint();
}

/// Publish a finished delegation result and wake the poll route.
///
/// `text` is always arena- or stack-owned by the caller, and the poll route
/// reads it on a later turn of the event loop, so it has to be copied into
/// `ai_alloc` first — before taking the lock, so no allocation happens inside
/// the critical section. A failed copy degrades to an empty, not-ok result
/// rather than reporting success with no text.
fn aiPublish(ok: bool, text: []const u8) void {
    const owned = ai_alloc.dupe(u8, text) catch "";

    aiLock();
    defer ai_state.mutex.unlock();
    if (ai_state.text.len > 0) ai_alloc.free(ai_state.text);
    ai_state.text = owned;
    ai_state.ok = ok and owned.len == text.len;
    ai_state.state = .done;
}

/// Return the slot to `.idle` after a start that never produced a worker.
fn aiReset() void {
    aiLock();
    defer ai_state.mutex.unlock();
    ai_state.state = .idle;
}

/// Body of the `ai_delegate` worker thread. Owns `prompt` and frees it.
fn aiDelegateWorker(io: std.Io, prompt: []const u8) void {
    defer ai_alloc.free(prompt);

    var arena = std.heap.ArenaAllocator.init(ai_alloc);
    defer arena.deinit();

    var client: desktop.ai_cli.Client = .{ .io = io };
    const blocks = [_]verve.ai.message.Block{.{ .text = prompt }};
    const messages = [_]verve.ai.message.Message{.{ .role = .user, .blocks = &blocks }};

    const res = client.provider().complete(arena.allocator(), .{
        .system = "You are answering inside a Verve desktop demo. Reply in at most three sentences.",
        // Delegation, not tool-calling: `ai_cli` reports
        // `native_tools == false` and refuses a non-empty tool list outright
        // rather than silently dropping it. The tool-calling surface is
        // `ai_tool_call` below.
        .tools_json = "[]",
        .messages = &messages,
    }) catch |err| {
        // A missing `claude` on PATH lands here as `error.CliSpawnFailed`.
        aiPublish(false, @errorName(err));
        return;
    };

    for (res.blocks) |b| switch (b) {
        .text => |t| {
            aiPublish(true, t);
            return;
        },
        else => {},
    };
    aiPublish(false, "response carried no text block");
}

// ---- AI tool gate over IPC (`ai_tool_call`) -------------------------------

/// This app's AI tool allowlist for its *IPC* surface — the desktop sibling
/// of `src/app/ai.zig` in the web scaffold. A route not named here has no
/// generated schema, no name a caller can reach through the gate, and no
/// dispatch path. The list is validated at comptime, so a typo'd `fn_name` or
/// a stale `arg_docs.field` is a build failure.
///
/// Nothing here is `.dangerous` on purpose: `.dangerous` tools require a
/// human confirmation round-trip, and this template ships no approval UI to
/// perform one. Shipping a dangerous tool without the UI to confirm it would
/// be worse than shipping neither.
const ai_tool_decls: []const verve.ai.ToolDecl = &.{
    .{
        .fn_name = "system_info",
        .description = "Read OS version, locale, CPU count, installed RAM, and uptime.",
        .risk = .safe,
    },
    .{
        .fn_name = "notify",
        .description = "Show a native desktop notification.",
        .risk = .mutating,
        .arg_docs = &.{
            .{ .field = "title", .description = "Notification title line." },
            .{ .field = "body", .description = "Notification body text." },
        },
    },
};

/// The desktop-IPC sibling of `verve.ai.Registry`. Both call the same `gate`
/// and the same `audit`, which is the whole point: a tool call arriving over
/// IPC gets exactly the guarantees one arriving over HTTP gets, from one
/// implementation rather than two that can drift.
const AiTools = verve.ai.RouteRegistry(Routes, RouterCtx, ai_tool_decls);

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
            if (std.mem.eql(u8, args.action, "minimize")) w.minimize() else if (std.mem.eql(u8, args.action, "maximize")) w.maximize() else if (std.mem.eql(u8, args.action, "restore")) w.restore() else if (std.mem.eql(u8, args.action, "center")) w.center() else if (std.mem.eql(u8, args.action, "fullscreen_on")) w.setFullscreen(true) else if (std.mem.eql(u8, args.action, "fullscreen_off")) w.setFullscreen(false) else return .{ .ok = false };
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
                if (std.mem.eql(u8, args.kind, "system")) .system else if (std.mem.eql(u8, args.kind, "browser")) .browser else .default;
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

    /// Hand a whole task to the Claude Code CLI (`claude -p ...
    /// --output-format=json`) as a subprocess, via `desktop.ai_cli`.
    /// Delegation, not tool-calling — Claude Code runs its own tools in its
    /// own sandbox and never sees this app's registry. `ai_tool_call` below
    /// is the surface that does.
    ///
    /// Returns as soon as the worker is spawned. A `claude -p` run takes tens
    /// of seconds and this handler runs on the thread that owns the webview,
    /// so waiting here would freeze the window. Poll `ai_delegate_poll` for
    /// the answer; see `AiDelegate` for why it's a poll and not a push.
    pub const ai_delegate = struct {
        pub const Args = struct { prompt: []const u8 = "" };
        pub const Reply = struct { started: bool, status: []const u8 };
        pub fn handle(c: *RouterCtx, _: std.mem.Allocator, args: Args) !Reply {
            const trimmed = std.mem.trim(u8, args.prompt, " \t\r\n");
            if (trimmed.len == 0) return .{ .started = false, .status = "empty prompt" };

            {
                aiLock();
                defer ai_state.mutex.unlock();
                if (ai_state.state == .running) return .{ .started = false, .status = "already running" };
                ai_state.state = .running;
            }

            // Handed to the worker, which owns and frees it — this handler's
            // arena dies as soon as the reply below is encoded.
            const owned = ai_alloc.dupe(u8, trimmed) catch {
                aiReset();
                return .{ .started = false, .status = "out of memory" };
            };

            const worker = std.Thread.spawn(.{}, aiDelegateWorker, .{ c.io, owned }) catch {
                ai_alloc.free(owned);
                aiReset();
                return .{ .started = false, .status = "spawn failed" };
            };
            // Detached — nothing joins this thread. It touches only
            // `ai_state` (mutex-guarded) and its own allocations, so a run
            // still in flight at shutdown loses its result rather than
            // corrupting anything.
            worker.detach();
            return .{ .started = true, .status = "running" };
        }
    };

    /// Poll for the `ai_delegate` worker's result.
    pub const ai_delegate_poll = struct {
        pub const Args = struct {};
        pub const Reply = struct {
            /// "idle" | "running" | "done"
            state: []const u8,
            ok: bool = false,
            text: []const u8 = "",
        };
        pub fn handle(_: *RouterCtx, alloc: std.mem.Allocator, _: Args) !Reply {
            aiLock();
            defer ai_state.mutex.unlock();
            return switch (ai_state.state) {
                .idle => .{ .state = "idle" },
                .running => .{ .state = "running" },
                // Copied onto the dispatch arena rather than handed out by
                // reference: the reply is JSON-encoded after this function
                // returns, and a later run frees `ai_state.text`.
                //
                // The copy has to happen *inside* the critical section, not
                // after it. Snapshotting the slice and duping once the lock
                // is released reads freed memory if a second delegation
                // publishes in the gap. Allocating under a spinlock is the
                // lesser evil: the only contender is the worker, which holds
                // the lock for a few stores.
                .done => .{
                    .state = "done",
                    .ok = ai_state.ok,
                    .text = try alloc.dupe(u8, ai_state.text),
                },
            };
        }
    };

    /// Run an allowlisted IPC route as an AI *tool*, through the same
    /// security gate a model-issued HTTP tool call passes: allowlist →
    /// argument size → risk tier → human confirmation, with every outcome
    /// — refusals included — audited to stderr.
    ///
    /// Both arms are the demo. `system_info` is on `ai_tool_decls` and runs.
    /// `smoke_done` is a real route on `Routes` that is *not* declared there,
    /// so it comes back "unknown tool" and is audited as denied — the gate
    /// does not care that a caller could reach that route directly over plain
    /// IPC. The JS shim is not a trust boundary; the allowlist is.
    pub const ai_tool_call = struct {
        pub const Args = struct {
            name: []const u8 = "",
            /// A JSON object of arguments, exactly as a model would supply
            /// it. Parsed strictly — an argument name the caller invented is
            /// rejected, not ignored.
            args_json: []const u8 = "{}",
            /// A token this route previously handed back on a
            /// `needs_confirmation` reply, echoed after a human approved the
            /// call. Zero means "no approval held". Single-use, and bound to
            /// this exact `(name, args_json)` pair — an approval for one call
            /// cannot be spent on another (see `policy.claimToken`).
            confirm_token: u64 = 0,
        };
        pub const Reply = struct {
            /// "ok" | "denied" | "needs_confirmation"
            outcome: []const u8,
            value_json: []const u8 = "",
            err: []const u8 = "",
            /// Set only on the `needs_confirmation` arm; echo it back in
            /// `Args.confirm_token` to execute.
            ///
            /// Handing this to the page is safe *here and only here*: the
            /// caller of this route is the app's own human-driven UI, exactly
            /// like a CSRF token issued to a form. It would NOT be safe on any
            /// path where a model is the caller — which is why `ai_tool_call`
            /// must never itself appear in `ai_tool_decls`, and why the agent
            /// loop (`verve.ai.run`) deliberately has no way to surface a
            /// token at all. If a future change routes model output into this
            /// route, delete this field first.
            confirm_token: u64 = 0,
        };
        pub fn handle(c: *RouterCtx, alloc: std.mem.Allocator, args: Args) !Reply {
            const token: ?u64 = if (args.confirm_token == 0) null else args.confirm_token;
            return switch (AiTools.invoke(c, alloc, args.name, args.args_json, .{}, token)) {
                .ok => |v| .{ .outcome = "ok", .value_json = v },
                .err => |e| .{ .outcome = "denied", .err = e },
                .needs_confirmation => |t| .{
                    .outcome = "needs_confirmation",
                    .err = "a human must approve this call",
                    .confirm_token = t,
                },
            };
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
            // [smoke-instr] boundary: the JS driver reached smoke_done → hydration
            // + the click sequence ran. If this line is absent in CI output, the
            // hang is upstream (driver/IPC), not in the snapshot path.
            std.log.info("smoke_done: received (checksum={d})", .{args.checksum});
            const dir = c.smoke_dir orelse {
                std.log.warn("smoke_done: no smoke_dir set; ignoring", .{});
                return .{ .ok = false };
            };

            const png_path = try std.fs.path.join(alloc, &.{ dir, "shot.png" });
            defer alloc.free(png_path);
            const cksum_path = try std.fs.path.join(alloc, &.{ dir, "checksum.txt" });
            defer alloc.free(cksum_path);

            // [smoke-instr] boundary: about to enter the (async, run-loop-pumped)
            // WKWebView snapshot. If "snapshot: completion fired" never follows,
            // the completion handler didn't fire (headless/off-screen) → the pump
            // spins → the app hangs here.
            std.log.info("smoke_done: taking snapshot → '{s}'", .{png_path});
            c.window.takeSnapshotPng(png_path) catch |err| {
                // Best-effort: a headless / off-screen web view (e.g. a CI
                // runner with no display) can't snapshot — the WKWebView
                // completion never fires. Log + CONTINUE so the deterministic
                // checksum is still written and the app still terminates
                // (the harness validates the checksum; the PNG is optional).
                std.log.warn("smoke_done: snapshot unavailable ({s}); continuing with checksum only", .{@errorName(err)});
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

            std.log.info("smoke_done: checksum.txt written to '{s}' (shot.png best-effort)", .{dir});
            c.window.terminate();
            return .{ .ok = true };
        }
    };
};
