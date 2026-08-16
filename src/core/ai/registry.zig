//! Comptime tool table: (namespace of actions) x (explicit allowlist).
//!
//! The allowlist is the security boundary. A function absent from `decls` has
//! no schema, no name the model can reach, and no dispatch path.

const std = @import("std");
const tool = @import("tool.zig");
const schema = @import("schema.zig");
const action_invoke = @import("../action_invoke.zig");
const policy = @import("policy.zig");
const audit = @import("audit.zig");

pub const ToolOutcome = union(enum) {
    /// JSON encoding of the tool's return value (`"null"` for void actions).
    ok: []const u8,
    /// Human- and model-readable reason the call did not run.
    err: []const u8,
    /// A human must approve; echo this token back to execute.
    needs_confirmation: u64,
};

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
                const ArgsT = action_invoke.ArgsOf(@field(Actions, d.fn_name));
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

        /// Execute a model-chosen tool call.
        ///
        /// Order matters: allowlist, then size, then risk, then confirmation,
        /// then execution. Nothing runs until every gate has passed, and every
        /// path — including the refusals — is audited.
        pub fn invoke(
            arena: std.mem.Allocator,
            name: []const u8,
            args_json: []const u8,
            p: policy.Policy,
            confirm_token: ?u64,
        ) ToolOutcome {
            const decl = find(name) orelse {
                audit.record(name, .safe, .denied, args_json.len);
                return .{ .err = "unknown tool" };
            };

            switch (policy.check(p, decl, args_json.len)) {
                .deny => |reason| {
                    audit.record(name, decl.risk, .denied, args_json.len);
                    return .{ .err = reason };
                },
                .needs_confirmation => |fresh| {
                    const approved = if (confirm_token) |t| policy.claimToken(t) else false;
                    if (!approved) {
                        audit.record(name, decl.risk, .needs_confirmation, args_json.len);
                        return .{ .needs_confirmation = fresh };
                    }
                },
                .allow => {},
            }

            inline for (decls) |d| {
                if (std.mem.eql(u8, d.fn_name, name)) {
                    const func = @field(Actions, d.fn_name);
                    const ArgsT = action_invoke.ArgsOf(func);
                    // Strict parsing: an unknown key from a model means a
                    // hallucinated field, and a silently defaulted real one
                    // would run the wrong action with no error anywhere.
                    const args = action_invoke.parseJsonArgs(ArgsT, arena, args_json, true) catch {
                        audit.record(name, d.risk, .failed, args_json.len);
                        return .{ .err = "invalid arguments for tool" };
                    };
                    const res = action_invoke.callAndSerialize(func, arena, args) catch {
                        audit.record(name, d.risk, .failed, args_json.len);
                        return .{ .err = "tool execution failed" };
                    };
                    audit.record(name, d.risk, .allowed, args_json.len);
                    const json = switch (res) {
                        .ok => "null",
                        .value_json => |v| v,
                    };
                    const capped = if (json.len > p.max_tool_result_bytes)
                        json[0..p.max_tool_result_bytes]
                    else
                        json;
                    return .{ .ok = capped };
                }
            }
            unreachable;
        }
    };
}

fn validate(comptime Actions: type, comptime decls: []const tool.ToolDecl) void {
    comptime {
        for (decls) |d| {
            if (!@hasDecl(Actions, d.fn_name)) {
                @compileError("ai tool '" ++ d.fn_name ++ "' is not declared on " ++ @typeName(Actions));
            }
            const ArgsT = action_invoke.ArgsOf(@field(Actions, d.fn_name));
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

test "dispatch: allowed tool executes and returns JSON" {
    policy.resetTokens();
    audit.reset();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const out = R.invoke(arena.allocator(), "getCount", "{}", .{}, null);
    try std.testing.expectEqualStrings("7", out.ok);
    try std.testing.expectEqual(@as(usize, 1), audit.total());
}

test "dispatch: undeclared tool is refused without executing" {
    audit.reset();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const out = R.invoke(arena.allocator(), "secretWipe", "{}", .{}, null);
    try std.testing.expect(out == .err);
    try std.testing.expectEqualStrings("unknown tool", out.err);
}

test "dispatch: hallucinated argument name is an error, not a default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const out = R.invoke(arena.allocator(), "addTodo", "{\"txt\":\"x\"}", .{}, null);
    try std.testing.expect(out == .err);
}

test "dispatch: dangerous tool needs a token, then runs once" {
    policy.resetTokens();
    const DangerActions = struct {
        pub var ran: u32 = 0;
        pub fn wipe(_: struct {}) void {
            ran += 1;
        }
    };
    const DR = Registry(DangerActions, &.{
        .{ .fn_name = "wipe", .description = "Delete everything.", .risk = .dangerous },
    });
    const p: policy.Policy = .{ .allow_risk = .dangerous };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const first = DR.invoke(arena.allocator(), "wipe", "{}", p, null);
    try std.testing.expect(first == .needs_confirmation);
    try std.testing.expectEqual(@as(u32, 0), DangerActions.ran);

    const token = first.needs_confirmation;
    const second = DR.invoke(arena.allocator(), "wipe", "{}", p, token);
    try std.testing.expect(second == .ok);
    try std.testing.expectEqual(@as(u32, 1), DangerActions.ran);

    // Replaying the same token must not run it again.
    const third = DR.invoke(arena.allocator(), "wipe", "{}", p, token);
    try std.testing.expect(third == .needs_confirmation);
    try std.testing.expectEqual(@as(u32, 1), DangerActions.ran);
}

test "dispatch: oversized results are truncated" {
    const BigActions = struct {
        pub fn big(_: struct {}) []const u8 {
            return "0123456789";
        }
    };
    const BR = Registry(BigActions, &.{
        .{ .fn_name = "big", .description = "Big.", .risk = .safe },
    });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = BR.invoke(arena.allocator(), "big", "{}", .{ .max_tool_result_bytes = 4 }, null);
    try std.testing.expectEqual(@as(usize, 4), out.ok.len);
}
