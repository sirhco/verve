//! Comptime-generated /api/<fn> dispatcher for app.Actions.
//!
//! Convention: each Action is `fn(args: struct { ... }) Ret` where Ret is
//! one of: `void`, `!void`, a serializable value, or an error union of one.
//! The arg struct's fields are JSON-deserialized from the POST body; void
//! returns produce `{"ok":true}`, value returns produce `{"value":<v>}`.

const std = @import("std");
const Writer = std.Io.Writer;
const app = @import("app");
const verve = @import("verve");
const http = std.http;
const action_invoke = @import("verve").action_invoke;

pub const RequestMeta = verve.RequestMeta;

const API_PREFIX = "/api/";

/// When false, the form-CSRF check is skipped. Defaults to enforce.
/// Set via `verve-server --csrf=disable` for local dev / integration
/// tests that don't yet thread tokens through their form posts.
pub var enforce_csrf: bool = true;

pub fn isApiPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, API_PREFIX);
}

pub fn dispatch(
    gpa: std.mem.Allocator,
    request: *http.Server.Request,
    path: []const u8,
    body: []const u8,
    meta: RequestMeta,
) !void {
    if (!isApiPath(path)) {
        try request.respond("not found", .{ .status = .not_found });
        return;
    }
    const fn_name = path[API_PREFIX.len..];

    // CSRF check for form posts. We require the request to carry a
    // `__csrf` field whose value matches the `__verve_csrf` cookie.
    // JSON posts (which originate from the same-origin WASM bridge that
    // can read the cookie) are skipped here; a future phase will fold
    // them in via a custom header check.
    if (enforce_csrf and meta.is_form) {
        const form_token = findFormField(body, "__csrf");
        const cookie_token = meta.cookie(verve.csrf.COOKIE_NAME) orelse "";
        if (form_token.len == 0 or cookie_token.len == 0 or !std.mem.eql(u8, form_token, cookie_token)) {
            try request.respond("CSRF token missing or invalid", .{ .status = .forbidden });
            return;
        }
        // Origin pinning (when present): the Origin header must match the
        // request Host. Skips the check when Origin is absent (older
        // browsers or same-origin form posts).
        if (meta.origin) |origin| if (meta.host) |host| {
            if (!originMatchesHost(origin, host)) {
                try request.respond("Origin mismatch", .{ .status = .forbidden });
                return;
            }
        };
    }

    const redirect_target = if (meta.is_form) meta.referer orelse "/" else "";

    // Read x-verve-rid for request-id correlation. Parse to ?u32;
    // absent or non-numeric header → null (fire-and-forget back-compat).
    const rid: ?u32 = if (meta.rid_raw) |raw|
        std.fmt.parseInt(u32, raw, 10) catch null
    else
        null;

    const Actions = app.Actions;
    const decls = comptime std.meta.declarations(Actions);

    inline for (decls) |decl| {
        if (std.mem.eql(u8, decl.name, fn_name)) {
            try invoke(gpa, request, @field(Actions, decl.name), body, meta.is_form, redirect_target, rid);
            return;
        }
    }

    try request.respond("unknown action", .{ .status = .not_found });
}

fn invoke(
    gpa: std.mem.Allocator,
    request: *http.Server.Request,
    comptime func: anytype,
    body: []const u8,
    is_form: bool,
    redirect_target: []const u8,
    rid: ?u32,
) !void {
    const ArgsStruct = action_invoke.ArgsOf(func);

    var arg_arena = std.heap.ArenaAllocator.init(gpa);
    defer arg_arena.deinit();

    var args: ArgsStruct = undefined;
    if (@typeInfo(ArgsStruct).@"struct".fields.len == 0) {
        args = .{};
    } else if (is_form) {
        args = parseFormBody(ArgsStruct, arg_arena.allocator(), body) catch {
            try request.respond("bad form body", .{ .status = .bad_request });
            return;
        };
    } else {
        // Parse into `arg_arena` (freed at function end, AFTER func(args)). A
        // block-scoped `Parsed.deinit()` would free the parse arena here — before
        // func(args) runs — leaving string fields dangling (UAF: any string arg
        // with a JSON escape gets a heap-allocated unescaped copy). Leaky parse
        // ties every allocation to the longer-lived arg_arena instead.
        //
        // ignore_unknown_fields = true: the HTTP path's historical tolerance for
        // extra keys. The AI tool path (action_invoke's other caller) parses
        // strict instead — an unknown key there means a hallucinated field name,
        // which should surface as a retryable error, not get silently dropped.
        args = action_invoke.parseJsonArgs(ArgsStruct, arg_arena.allocator(), body, false) catch {
            try request.respond("bad json", .{ .status = .bad_request });
            return;
        };
    }

    if (is_form) {
        // A form post redirects on completion regardless of what the action
        // returned — the return value is never observed, so it must never
        // be serialized either (a value-encode failure has no business
        // 500-ing a request whose response doesn't depend on the value).
        action_invoke.call(func, args) catch |err| switch (err) {
            error.ActionFailed => {
                try request.respond("internal error", .{ .status = .internal_server_error });
                return;
            },
            error.BadArgs => {
                try request.respond("bad json", .{ .status = .bad_request });
                return;
            },
        };
        try respondRedirect(request, redirect_target);
        return;
    }

    const result = action_invoke.callAndSerialize(func, arg_arena.allocator(), args) catch |err| switch (err) {
        error.ActionFailed => {
            try request.respond("internal error", .{ .status = .internal_server_error });
            return;
        },
        error.BadArgs => {
            try request.respond("bad json", .{ .status = .bad_request });
            return;
        },
    };
    switch (result) {
        .ok => try respondOk(request, rid),
        .value_json => |json| try respondValueJson(gpa, request, rid, json),
    }
}

/// Look up a single form-encoded field by name. Returns the raw
/// (still percent-encoded) value, or an empty slice when missing.
fn findFormField(body: []const u8, name: []const u8) []const u8 {
    var it = std.mem.tokenizeScalar(u8, body, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return &.{};
}

/// Loose Origin/Host comparison. `Origin` is `<scheme>://<host>[:port]`
/// while `Host` is `<host>[:port]`. We strip the scheme prefix and
/// compare the rest verbatim.
fn originMatchesHost(origin: []const u8, host: []const u8) bool {
    var rest = origin;
    if (std.mem.indexOf(u8, rest, "://")) |i| rest = rest[i + 3 ..];
    return std.mem.eql(u8, rest, host);
}

fn parseFormBody(
    comptime ArgsStruct: type,
    arena: std.mem.Allocator,
    body: []const u8,
) !ArgsStruct {
    const fields = @typeInfo(ArgsStruct).@"struct".fields;

    var args: ArgsStruct = undefined;
    inline for (fields) |f| {
        if (f.default_value_ptr) |dv| {
            @field(args, f.name) = @as(*const f.type, @ptrCast(@alignCast(dv))).*;
        }
    }

    var it = std.mem.tokenizeScalar(u8, body, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const raw_key = pair[0..eq];
        const raw_val = pair[eq + 1 ..];

        inline for (fields) |f| {
            if (std.mem.eql(u8, raw_key, f.name)) {
                const decoded = try urlDecode(arena, raw_val);
                @field(args, f.name) = try coerce(f.type, decoded);
            }
        }
    }
    return args;
}

fn urlDecode(arena: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = try arena.alloc(u8, input.len);
    var w: usize = 0;
    var r: usize = 0;
    while (r < input.len) {
        const c = input[r];
        if (c == '+') {
            out[w] = ' ';
            r += 1;
            w += 1;
        } else if (c == '%' and r + 2 < input.len) {
            const byte = std.fmt.parseInt(u8, input[r + 1 .. r + 3], 16) catch return error.BadEscape;
            out[w] = byte;
            r += 3;
            w += 1;
        } else {
            out[w] = c;
            r += 1;
            w += 1;
        }
    }
    return out[0..w];
}

fn coerce(comptime T: type, value: []const u8) !T {
    switch (@typeInfo(T)) {
        .int => return std.fmt.parseInt(T, value, 10),
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) return value;
            @compileError("Form field type not supported: " ++ @typeName(T));
        },
        else => @compileError("Form field type not supported: " ++ @typeName(T)),
    }
}

fn respondRedirect(request: *http.Server.Request, target: []const u8) !void {
    try request.respond("", .{
        .status = .see_other,
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "location", .value = target },
        },
    });
}

/// Reply payload for `replyBody`.
const ReplyPayload = union(enum) {
    ok,
    value_json: []const u8,
};

/// Build a server-fn reply body. `rid` echoes the correlation id when present.
/// Writes into `buf` and returns the populated slice.
fn replyBody(buf: []u8, rid: ?u32, payload: ReplyPayload) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.writeByte('{');
    if (rid) |r| {
        try w.print("\"rid\":{d},", .{r});
    }
    switch (payload) {
        .ok => try w.writeAll("\"ok\":true"),
        .value_json => |v| {
            try w.writeAll("\"value\":");
            try w.writeAll(v);
        },
    }
    try w.writeByte('}');
    return w.buffered();
}

fn respondOk(request: *http.Server.Request, rid: ?u32) !void {
    var buf: [64]u8 = undefined;
    const body = try replyBody(&buf, rid, .ok);
    try request.respond(body, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
}

fn respondValueJson(
    gpa: std.mem.Allocator,
    request: *http.Server.Request,
    rid: ?u32,
    value_json: []const u8,
) !void {
    // Wrap the already-encoded value with the optional rid prefix.
    var wrap_aw: Writer.Allocating = .init(gpa);
    defer wrap_aw.deinit();
    const wrap_w = &wrap_aw.writer;
    try wrap_w.writeByte('{');
    if (rid) |r| try wrap_w.print("\"rid\":{d},", .{r});
    try wrap_w.writeAll("\"value\":");
    try wrap_w.writeAll(value_json);
    try wrap_w.writeByte('}');

    try request.respond(wrap_aw.written(), .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
}

test "isApiPath matches /api/ prefix only" {
    const testing = std.testing;
    try testing.expect(isApiPath("/api/foo"));
    try testing.expect(isApiPath("/api/"));
    try testing.expect(!isApiPath("/foo/api/bar"));
    try testing.expect(!isApiPath("/foo"));
    try testing.expect(!isApiPath(""));
}

test "Actions struct has expected decl signature" {
    const Actions = app.Actions;
    const decls = comptime std.meta.declarations(Actions);
    var found = false;
    inline for (decls) |decl| {
        if (std.mem.eql(u8, decl.name, "updateDatabase")) {
            found = true;
            const fn_info = @typeInfo(@TypeOf(@field(Actions, decl.name))).@"fn";
            try std.testing.expectEqual(@as(usize, 1), fn_info.params.len);
            const ArgsStruct = fn_info.params[0].type.?;
            try std.testing.expect(@typeInfo(ArgsStruct) == .@"struct");
        }
    }
    try std.testing.expect(found);
}

test "JSON body parses into single-struct argument" {
    const Args = struct { new_count: i32 };
    const body = "{\"new_count\":7}";
    const parsed = try std.json.parseFromSlice(Args, std.testing.allocator, body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i32, 7), parsed.value.new_count);
}

test "JSON parse rejects malformed body" {
    const Args = struct { new_count: i32 };
    const result = std.json.parseFromSlice(Args, std.testing.allocator, "not json", .{});
    try std.testing.expectError(error.SyntaxError, result);
}

test "Stringify produces JSON for primitives" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try std.json.Stringify.value(@as(i32, 42), .{}, &aw.writer);
    try std.testing.expectEqualStrings("42", aw.written());
}

test "replyBody echoes rid when present, omits when absent" {
    const testing = std.testing;
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("{\"ok\":true}", try replyBody(&buf, null, .ok));
    try testing.expectEqualStrings("{\"rid\":5,\"ok\":true}", try replyBody(&buf, 5, .ok));
    try testing.expectEqualStrings("{\"value\":42}", try replyBody(&buf, null, .{ .value_json = "42" }));
    try testing.expectEqualStrings("{\"rid\":7,\"value\":42}", try replyBody(&buf, 7, .{ .value_json = "42" }));
}
