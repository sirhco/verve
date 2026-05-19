//! Comptime-generated /api/<fn> dispatcher for app.Actions.
//!
//! Convention: each Action is `fn(args: struct { ... }) Ret` where Ret is
//! one of: `void`, `!void`, a serializable value, or an error union of one.
//! The arg struct's fields are JSON-deserialized from the POST body; void
//! returns produce `{"ok":true}`, value returns produce `{"value":<v>}`.

const std = @import("std");
const Writer = std.Io.Writer;
const app = @import("app");
const http = std.http;

const API_PREFIX = "/api/";

pub fn isApiPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, API_PREFIX);
}

const FORM_CT = "application/x-www-form-urlencoded";

/// Snapshot of headers a dispatch needs taken BEFORE the body is read.
/// std.http.Server requires header iteration while the reader is in
/// the `received_head` state, which the body reader consumes.
pub const RequestMeta = struct {
    is_form: bool,
    referer: ?[]const u8,
    accept_gzip: bool,

    pub fn fromRequest(request: *http.Server.Request) RequestMeta {
        var result: RequestMeta = .{ .is_form = false, .referer = null, .accept_gzip = false };
        var iter = request.iterateHeaders();
        while (iter.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "content-type")) {
                result.is_form = std.mem.startsWith(u8, h.value, FORM_CT);
            } else if (std.ascii.eqlIgnoreCase(h.name, "referer")) {
                result.referer = h.value;
            } else if (std.ascii.eqlIgnoreCase(h.name, "accept-encoding")) {
                result.accept_gzip = std.mem.indexOf(u8, h.value, "gzip") != null;
            }
        }
        return result;
    }
};

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

    const redirect_target = if (meta.is_form) meta.referer orelse "/" else "";

    const Actions = app.Actions;
    const decls = comptime std.meta.declarations(Actions);

    inline for (decls) |decl| {
        if (std.mem.eql(u8, decl.name, fn_name)) {
            try invoke(gpa, request, @field(Actions, decl.name), body, meta.is_form, redirect_target);
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
) !void {
    const fn_info = @typeInfo(@TypeOf(func)).@"fn";
    if (fn_info.params.len != 1) {
        @compileError("Action functions must take exactly one struct argument");
    }
    const ArgsStruct = fn_info.params[0].type.?;
    if (@typeInfo(ArgsStruct) != .@"struct") {
        @compileError("Action argument must be a struct");
    }

    const Ret = fn_info.return_type.?;
    const ret_info = @typeInfo(Ret);
    const returns_error = ret_info == .error_union;
    const Payload = if (returns_error) ret_info.error_union.payload else Ret;
    const returns_value = Payload != void;

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
        const parsed = std.json.parseFromSlice(ArgsStruct, gpa, body, .{
            .ignore_unknown_fields = true,
        }) catch {
            try request.respond("bad json", .{ .status = .bad_request });
            return;
        };
        defer parsed.deinit();
        args = parsed.value;
    }

    if (returns_error and returns_value) {
        const value = func(args) catch {
            try request.respond("internal error", .{ .status = .internal_server_error });
            return;
        };
        if (is_form) {
            try respondRedirect(request, redirect_target);
        } else {
            try respondValue(gpa, request, value);
        }
    } else if (returns_error and !returns_value) {
        func(args) catch {
            try request.respond("internal error", .{ .status = .internal_server_error });
            return;
        };
        if (is_form) try respondRedirect(request, redirect_target) else try respondOk(request);
    } else if (!returns_error and returns_value) {
        const value = func(args);
        if (is_form) {
            try respondRedirect(request, redirect_target);
        } else {
            try respondValue(gpa, request, value);
        }
    } else {
        func(args);
        if (is_form) try respondRedirect(request, redirect_target) else try respondOk(request);
    }
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

fn respondOk(request: *http.Server.Request) !void {
    try request.respond("{\"ok\":true}", .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
}

fn respondValue(
    gpa: std.mem.Allocator,
    request: *http.Server.Request,
    value: anytype,
) !void {
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try aw.writer.writeAll("{\"value\":");
    try std.json.Stringify.value(value, .{}, &aw.writer);
    try aw.writer.writeAll("}");
    try request.respond(aw.written(), .{
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
