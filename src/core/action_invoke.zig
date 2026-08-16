//! Shared comptime invoker for single-struct-argument action functions.
//!
//! Both dispatch surfaces run through here — the HTTP `/api/<fn>` handler and
//! the AI tool registry — so a tool's generated schema and its actual
//! execution path can never describe different things.

const std = @import("std");
const Writer = std.Io.Writer;

pub const Error = error{
    /// The JSON body did not match the action's argument struct.
    BadArgs,
    /// The action itself returned an error.
    ActionFailed,
};

pub const InvokeResult = union(enum) {
    /// The action returned `void` / `!void`.
    ok,
    /// The action returned a value; this is its JSON encoding, allocated from
    /// the caller's arena.
    value_json: []const u8,
};

/// The argument struct type of a single-parameter action function.
pub fn ArgsOf(comptime func: anytype) type {
    const fn_info = @typeInfo(@TypeOf(func)).@"fn";
    if (fn_info.params.len != 1) {
        @compileError("action functions must take exactly one struct argument");
    }
    const ArgsStruct = fn_info.params[0].type.?;
    if (@typeInfo(ArgsStruct) != .@"struct") {
        @compileError("action argument must be a struct");
    }
    return ArgsStruct;
}

/// Parse a JSON object into an action's argument struct.
///
/// `arena` must outlive the subsequent call: parsing is leaky by design, so
/// string fields that required unescaping point into arena memory. A scoped
/// `Parsed.deinit()` here would free them before the action ran.
///
/// `strict = false` mirrors the HTTP path's historical tolerance for extra
/// keys. `strict = true` is for model-supplied arguments, where an unknown key
/// almost always means a hallucinated field name and a silently defaulted
/// real one — an error the model can see and retry beats a wrong action.
pub fn parseJsonArgs(
    comptime ArgsStruct: type,
    arena: std.mem.Allocator,
    body: []const u8,
    strict: bool,
) Error!ArgsStruct {
    if (@typeInfo(ArgsStruct).@"struct".fields.len == 0) return .{};
    if (strict) {
        return std.json.parseFromSliceLeaky(ArgsStruct, arena, body, .{
            .ignore_unknown_fields = false,
        }) catch return Error.BadArgs;
    }
    return std.json.parseFromSliceLeaky(ArgsStruct, arena, body, .{
        .ignore_unknown_fields = true,
    }) catch return Error.BadArgs;
}

/// Call `func` and encode whatever it returns.
pub fn callAndSerialize(
    comptime func: anytype,
    arena: std.mem.Allocator,
    args: ArgsOf(func),
) Error!InvokeResult {
    const fn_info = @typeInfo(@TypeOf(func)).@"fn";
    const Ret = fn_info.return_type.?;
    const ret_info = @typeInfo(Ret);
    const returns_error = ret_info == .error_union;
    const Payload = if (returns_error) ret_info.error_union.payload else Ret;
    const returns_value = Payload != void;

    if (returns_error and returns_value) {
        const value = func(args) catch return Error.ActionFailed;
        return .{ .value_json = try encode(arena, value) };
    } else if (returns_error and !returns_value) {
        func(args) catch return Error.ActionFailed;
        return .ok;
    } else if (!returns_error and returns_value) {
        return .{ .value_json = try encode(arena, func(args)) };
    } else {
        func(args);
        return .ok;
    }
}

fn encode(arena: std.mem.Allocator, value: anytype) Error![]const u8 {
    var aw: Writer.Allocating = .init(arena);
    std.json.Stringify.value(value, .{}, &aw.writer) catch return Error.ActionFailed;
    return aw.written();
}

/// Invoke a desktop IPC route struct (`Args` / `Reply` / `handle`).
///
/// Mirrors `parseJsonArgs` + `callAndSerialize` for the other declaration
/// shape, so both dispatch surfaces share one strictness rule and one error
/// vocabulary. `strict` carries the same meaning as elsewhere: true for
/// model-supplied arguments.
pub fn invokeRouteJson(
    comptime Route: type,
    ctx: anytype,
    arena: std.mem.Allocator,
    json_args: []const u8,
    strict: bool,
) Error!InvokeResult {
    const args = try parseJsonArgs(Route.Args, arena, json_args, strict);
    const reply = Route.handle(ctx, arena, args) catch return Error.ActionFailed;
    if (@TypeOf(reply) == void) return .ok;
    return .{ .value_json = try encode(arena, reply) };
}

/// Call `func` for its side effects, discarding any return value.
///
/// For dispatch paths where the action's return value is never observed —
/// an HTTP form post redirects on completion regardless of what the action
/// returned. Unlike `callAndSerialize`, this never encodes: a value-encode
/// failure must not be reachable on a path whose caller was never going to
/// look at the value anyway, and there is no point paying for an encode
/// nobody reads.
pub fn call(
    comptime func: anytype,
    args: ArgsOf(func),
) Error!void {
    const fn_info = @typeInfo(@TypeOf(func)).@"fn";
    const Ret = fn_info.return_type.?;
    const ret_info = @typeInfo(Ret);
    const returns_error = ret_info == .error_union;
    const Payload = if (returns_error) ret_info.error_union.payload else Ret;
    const returns_value = Payload != void;

    if (returns_error and returns_value) {
        _ = func(args) catch return Error.ActionFailed;
    } else if (returns_error and !returns_value) {
        func(args) catch return Error.ActionFailed;
    } else if (!returns_error and returns_value) {
        _ = func(args);
    } else {
        func(args);
    }
}

// ---- tests ------------------------------------------------------------

const T = struct {
    var last_text: [64]u8 = undefined;
    var last_len: usize = 0;

    pub fn takesText(args: struct { text: []const u8 }) !void {
        const n = @min(args.text.len, last_text.len);
        @memcpy(last_text[0..n], args.text[0..n]);
        last_len = n;
    }
    pub fn returnsInt(_: struct {}) !i32 {
        return 42;
    }
    pub fn returnsPlain(_: struct {}) i32 {
        return 9;
    }
    pub fn alwaysFails(_: struct {}) !void {
        return error.Nope;
    }
    pub fn returnsPoison(_: struct {}) Poison {
        return .{};
    }
};

/// A value whose JSON encoding is instrumented rather than actually poisoned
/// — std.json can serialize almost any ordinary Zig type, so there is no
/// portable way to make `Stringify.value` fail at runtime for a test. This
/// hooks the custom-encoder path instead: `stringified` flips true iff the
/// serializer actually visited this value, which is what `call()` must never
/// cause and `callAndSerialize()` always does.
const Poison = struct {
    var stringified = false;

    pub fn jsonStringify(self: Poison, jws: anytype) !void {
        _ = self;
        stringified = true;
        try jws.write(0);
    }
};

test "invoke: void action returns ok" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const args = try parseJsonArgs(ArgsOf(T.takesText), a, "{\"text\":\"hello\"}", true);
    const res = try callAndSerialize(T.takesText, a, args);
    try std.testing.expect(res == .ok);
    try std.testing.expectEqualStrings("hello", T.last_text[0..T.last_len]);
}

test "invoke: value action serializes its return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const res = try callAndSerialize(T.returnsInt, a, .{});
    try std.testing.expectEqualStrings("42", res.value_json);

    const res2 = try callAndSerialize(T.returnsPlain, a, .{});
    try std.testing.expectEqualStrings("9", res2.value_json);
}

test "invoke: action error maps to ActionFailed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(Error.ActionFailed, callAndSerialize(T.alwaysFails, arena.allocator(), .{}));
}

test "invoke: strict parsing rejects unknown fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A model that hallucinates a field name must get an error it can retry
    // against — not a silently defaulted argument and a wrong action.
    try std.testing.expectError(
        Error.BadArgs,
        parseJsonArgs(ArgsOf(T.takesText), a, "{\"txt\":\"hello\"}", true),
    );
}

test "invoke: lenient parsing ignores unknown fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The HTTP path keeps its historical tolerance for extra keys.
    const args = try parseJsonArgs(ArgsOf(T.takesText), a, "{\"text\":\"hi\",\"extra\":1}", false);
    try std.testing.expectEqualStrings("hi", args.text);
}

test "invoke: malformed JSON is BadArgs under both modes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(Error.BadArgs, parseJsonArgs(ArgsOf(T.takesText), a, "{oops", true));
    try std.testing.expectError(Error.BadArgs, parseJsonArgs(ArgsOf(T.takesText), a, "{oops", false));
}

test "invoke: call() runs a void action for its side effect" {
    const args: ArgsOf(T.takesText) = .{ .text = "form" };
    try call(T.takesText, args);
    try std.testing.expectEqualStrings("form", T.last_text[0..T.last_len]);
}

test "invoke: call() maps action error to ActionFailed" {
    try std.testing.expectError(Error.ActionFailed, call(T.alwaysFails, .{}));
}

test "invoke: call() discards a value return without serializing it — callAndSerialize does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    Poison.stringified = false;
    try call(T.returnsPoison, .{});
    try std.testing.expect(!Poison.stringified);

    // Positive control on the same action: proves `stringified` is a
    // faithful witness of "the serializer ran" and not just dead code.
    const res = try callAndSerialize(T.returnsPoison, arena.allocator(), .{});
    try std.testing.expect(Poison.stringified);
    try std.testing.expectEqualStrings("0", res.value_json);
}

test "invoke: desktop route shape" {
    const Ctx = struct { calls: u32 = 0 };
    const Route = struct {
        pub const Args = struct { name: []const u8 };
        pub const Reply = struct { greeting: []const u8 };
        pub fn handle(ctx: *Ctx, alloc: std.mem.Allocator, args: Args) !Reply {
            ctx.calls += 1;
            return .{ .greeting = try std.fmt.allocPrint(alloc, "hi {s}", .{args.name}) };
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx: Ctx = .{};

    const res = try invokeRouteJson(Route, &ctx, arena.allocator(), "{\"name\":\"ana\"}", true);
    try std.testing.expectEqualStrings("{\"greeting\":\"hi ana\"}", res.value_json);
    try std.testing.expectEqual(@as(u32, 1), ctx.calls);
}

test "invoke: desktop route rejects hallucinated argument names" {
    const Ctx = struct {};
    const Route = struct {
        pub const Args = struct { name: []const u8 };
        pub const Reply = struct {};
        pub fn handle(_: *Ctx, _: std.mem.Allocator, _: Args) !Reply {
            return .{};
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx: Ctx = .{};
    try std.testing.expectError(
        Error.BadArgs,
        invokeRouteJson(Route, &ctx, arena.allocator(), "{\"nme\":\"ana\"}", true),
    );
}
