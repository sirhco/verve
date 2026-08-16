//! Comptime tool table: (namespace of actions) x (explicit allowlist).
//!
//! The allowlist is the security boundary. A function absent from `decls` has
//! no schema, no name the model can reach, and no dispatch path.

const std = @import("std");
const tool = @import("tool.zig");
const schema = @import("schema.zig");

/// Build the tool table for `Actions` restricted to `decls`.
///
/// Every entry is validated at comptime: the function must exist, take exactly
/// one struct argument, and every `arg_docs.field` must name a real field. A
/// typo is a build failure, never a runtime surprise.
pub fn Registry(comptime Actions: type, comptime decls: []const tool.ToolDecl) type {
    comptime validate(Actions, decls);

    return struct {
        pub const actions = Actions;
        pub const tool_decls = decls;

        /// Anthropic-format tool array, built at comptime. Zero runtime cost.
        pub const tools_json: []const u8 = blk: {
            var out: []const u8 = "[";
            for (decls, 0..) |d, i| {
                if (i != 0) out = out ++ ",";
                const ArgsT = ArgsOfLocal(@field(Actions, d.fn_name));
                out = out ++ "{\"name\":\"" ++ d.fn_name ++
                    "\",\"description\":\"" ++ schema.escapeJson(d.description) ++
                    "\",\"input_schema\":" ++ schema.jsonSchema(ArgsT, d.arg_docs) ++ "}";
            }
            break :blk out ++ "]";
        };

        /// Look up a declared tool by the name the model used. Returns null for
        /// anything not on the allowlist — including real functions on
        /// `Actions` that were simply never declared.
        pub fn find(name: []const u8) ?tool.ToolDecl {
            inline for (decls) |d| {
                if (std.mem.eql(u8, d.fn_name, name)) return d;
            }
            return null;
        }
    };
}

fn validate(comptime Actions: type, comptime decls: []const tool.ToolDecl) void {
    comptime {
        for (decls) |d| {
            if (!@hasDecl(Actions, d.fn_name)) {
                @compileError("ai tool '" ++ d.fn_name ++ "' is not declared on " ++ @typeName(Actions));
            }
            const ArgsT = ArgsOfLocal(@field(Actions, d.fn_name));
            const fields = @typeInfo(ArgsT).@"struct".fields;
            for (d.arg_docs) |doc| {
                var found = false;
                for (fields) |f| {
                    if (std.mem.eql(u8, f.name, doc.field)) found = true;
                }
                if (!found) {
                    @compileError("ai tool '" ++ d.fn_name ++ "' has no argument named '" ++ doc.field ++ "'");
                }
            }
        }
    }
}

// TEMPORARY — replaced by action_invoke.ArgsOf in Task 4.
fn ArgsOfLocal(comptime func: anytype) type {
    const fn_info = @typeInfo(@TypeOf(func)).@"fn";
    if (fn_info.params.len != 1) @compileError("action must take exactly one struct argument");
    return fn_info.params[0].type.?;
}

// ---- tests ------------------------------------------------------------

const TestActions = struct {
    pub fn addTodo(args: struct { text: []const u8 }) !void {
        _ = args;
    }
    pub fn getCount(_: struct {}) !i32 {
        return 7;
    }
    pub fn secretWipe(_: struct {}) void {}
};

const test_decls: []const tool.ToolDecl = &.{
    .{
        .fn_name = "addTodo",
        .description = "Append a todo item.",
        .risk = .mutating,
        .arg_docs = &.{.{ .field = "text", .description = "Item text." }},
    },
    .{ .fn_name = "getCount", .description = "Read the counter.", .risk = .safe },
};

const R = Registry(TestActions, test_decls);

test "registry: tools_json golden" {
    try std.testing.expectEqualStrings(
        \\[{"name":"addTodo","description":"Append a todo item.","input_schema":{"type":"object","properties":{"text":{"type":"string","description":"Item text."}},"required":["text"],"additionalProperties":false}},{"name":"getCount","description":"Read the counter.","input_schema":{"type":"object","properties":{},"required":[],"additionalProperties":false}}]
    , R.tools_json);
}

test "registry: find returns declared tools" {
    const d = R.find("addTodo").?;
    try std.testing.expectEqual(tool.Risk.mutating, d.risk);
    try std.testing.expectEqual(tool.Risk.safe, R.find("getCount").?.risk);
}

test "registry: undeclared action is not findable" {
    // `secretWipe` exists on TestActions but is absent from the allowlist.
    // Default-deny means it must be invisible here.
    try std.testing.expect(R.find("secretWipe") == null);
    try std.testing.expect(R.find("nope") == null);
}

test "registry: empty allowlist yields an empty array" {
    const Empty = Registry(TestActions, &.{});
    try std.testing.expectEqualStrings("[]", Empty.tools_json);
}
