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
const Writer = std.Io.Writer;

pub const ToolOutcome = union(enum) {
    /// JSON encoding of the tool's return value (`"null"` for void actions).
    /// If the encoding is longer than the policy's `max_tool_result_bytes`,
    /// this is instead `{"truncated":true,"partial":"..."}` — always a value
    /// that parses, never a byte-sliced fragment of the original (see
    /// `truncateResult`).
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

            switch (policy.check(p, decl, args_json)) {
                .deny => |reason| {
                    audit.record(name, decl.risk, .denied, args_json.len);
                    return .{ .err = reason };
                },
                .needs_confirmation => {
                    // A token only redeems the exact (name, args) it was
                    // issued for — see policy.claimToken. Minting happens
                    // here, not in `check`, and only when the caller doesn't
                    // already hold a valid token: otherwise an approved call
                    // would leave a second, unclaimed token behind in the
                    // table for no one to ever reap.
                    const approved = if (confirm_token) |t| policy.claimToken(t, name, args_json) else false;
                    if (!approved) {
                        // Distinguish "never asked" from "asked with a token
                        // that didn't match" — the latter is what a model
                        // spending one tool's approval on another looks
                        // like, and it must not be audited identically to a
                        // routine first-time prompt.
                        const outcome: audit.Outcome = if (confirm_token != null) .claim_rejected else .needs_confirmation;
                        const fresh = policy.issueToken(name, args_json) catch |err| {
                            // Fail-closed either way: refuse rather than
                            // evict some other pending approval to make
                            // room, and refuse rather than mint a token from
                            // an unseeded (predictable) generator.
                            audit.record(name, decl.risk, .denied, args_json.len);
                            return .{ .err = switch (err) {
                                error.Unseeded => "confirmation token store is not initialized",
                                error.TableFull => "too many pending confirmations",
                            } };
                        };
                        audit.record(name, decl.risk, outcome, args_json.len);
                        return .{ .needs_confirmation = fresh };
                    }
                    // Approved: fall through to execute. Nothing is minted
                    // on this path, so the token just claimed is the only
                    // authorization this call ever held.
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
                        truncateResult(arena, json, p.max_tool_result_bytes)
                    else
                        json;
                    return .{ .ok = capped };
                }
            }
            unreachable;
        }
    };
}

/// Shrink an oversized JSON result into something shorter that still parses.
/// A raw byte slice of a JSON value can leave a string unterminated and can
/// split a multi-byte UTF-8 sequence — handing the model something it was
/// told was well-formed JSON and isn't. Wraps a UTF-8-safe prefix of the
/// original encoding in a small object instead.
fn truncateResult(arena: std.mem.Allocator, json: []const u8, max_bytes: usize) []const u8 {
    const cut = utf8SafeCut(json, max_bytes);
    var aw: Writer.Allocating = .init(arena);
    std.json.Stringify.value(.{ .truncated = true, .partial = json[0..cut] }, .{}, &aw.writer) catch
        return "{\"truncated\":true,\"partial\":\"\"}";
    return aw.written();
}

/// The largest prefix of `json` no longer than `max_bytes` that is still
/// valid UTF-8 — so truncation never cuts a multi-byte codepoint in half.
fn utf8SafeCut(json: []const u8, max_bytes: usize) usize {
    var cut = @min(json.len, max_bytes);
    while (cut > 0 and !std.unicode.utf8ValidateSlice(json[0..cut])) cut -= 1;
    return cut;
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

/// Seed `policy`'s token key deterministically for tests that exercise the
/// confirmation path. Test files run independently of each other, so this
/// can't assume `policy.zig`'s own tests have already seeded it.
fn seedPolicyKey() void {
    var k: [policy.KEY_LEN]u8 = undefined;
    for (&k, 0..) |*b, i| b.* = @intCast(i);
    policy.setKey(k);
}

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
    seedPolicyKey();
    const DangerActions = struct {
        pub var ran: u32 = 0;
        pub var nuked: u32 = 0;
        pub fn wipe(_: struct {}) void {
            ran += 1;
        }
        pub fn nuke(_: struct {}) void {
            nuked += 1;
        }
    };
    const DR = Registry(DangerActions, &.{
        .{ .fn_name = "wipe", .description = "Delete everything.", .risk = .dangerous },
        .{ .fn_name = "nuke", .description = "Delete everything else.", .risk = .dangerous },
    });
    const p: policy.Policy = .{ .allow_risk = .dangerous };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const first = DR.invoke(arena.allocator(), "wipe", "{}", p, null);
    try std.testing.expect(first == .needs_confirmation);
    try std.testing.expectEqual(@as(u32, 0), DangerActions.ran);

    const token = first.needs_confirmation;

    // A token issued for "wipe" must not authorise a different dangerous
    // tool, even one also awaiting confirmation.
    const wrong_tool = DR.invoke(arena.allocator(), "nuke", "{}", p, token);
    try std.testing.expect(wrong_tool == .needs_confirmation);
    try std.testing.expectEqual(@as(u32, 0), DangerActions.nuked);

    // That mismatched attempt must not have spent the token — "wipe" with
    // the arguments it was actually issued for still runs.
    const second = DR.invoke(arena.allocator(), "wipe", "{}", p, token);
    try std.testing.expect(second == .ok);
    try std.testing.expectEqual(@as(u32, 1), DangerActions.ran);

    // Replaying the same token must not run it again.
    const third = DR.invoke(arena.allocator(), "wipe", "{}", p, token);
    try std.testing.expect(third == .needs_confirmation);
    try std.testing.expectEqual(@as(u32, 1), DangerActions.ran);
}

test "dispatch: oversized results are truncated into a still-valid JSON value" {
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
    try std.testing.expect(out == .ok);

    // The model must be handed something it can actually parse, not a raw
    // byte-sliced fragment (a naive slice of `"0123456789"` to 4 bytes would
    // be the unterminated `"01`).
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), out.ok, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expect(parsed.value.object.get("truncated").?.bool);
}

test "dispatch: an approved confirmation leaves no live token behind" {
    policy.resetTokens();
    seedPolicyKey();
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
    const token = first.needs_confirmation;
    const approved = DR.invoke(arena.allocator(), "wipe", "{}", p, token);
    try std.testing.expect(approved == .ok);
    try std.testing.expectEqual(@as(u32, 1), DangerActions.ran);

    // The approved claim must not have left a second, still-live token
    // bound to this call sitting in the table (the leftover-authorization
    // bug this fixes) — fill every remaining slot and confirm the table has
    // its full capacity available, not `token_cap - 1`.
    var i: usize = 0;
    while (i < policy.token_cap) : (i += 1) {
        _ = try policy.issueToken("filler", "{}");
    }
    try std.testing.expectError(policy.IssueError.TableFull, policy.issueToken("filler", "{}"));
    policy.resetTokens();
}

test "dispatch: a full confirmation table is refused, not silently evicted" {
    policy.resetTokens();
    seedPolicyKey();
    const DangerActions = struct {
        pub fn wipe(_: struct {}) void {}
    };
    const DR = Registry(DangerActions, &.{
        .{ .fn_name = "wipe", .description = "Delete everything.", .risk = .dangerous },
    });
    const p: policy.Policy = .{ .allow_risk = .dangerous };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var i: usize = 0;
    while (i < policy.token_cap) : (i += 1) {
        _ = try policy.issueToken("other", "{}");
    }
    const out = DR.invoke(arena.allocator(), "wipe", "{}", p, null);
    try std.testing.expect(out == .err);
    try std.testing.expectEqualStrings("too many pending confirmations", out.err);
    policy.resetTokens();
}

test "dispatch: a rejected confirmation token is audited distinctly from a first-time ask" {
    policy.resetTokens();
    seedPolicyKey();
    audit.reset();
    const DangerActions = struct {
        pub fn wipe(_: struct {}) void {}
        pub fn nuke(_: struct {}) void {}
    };
    const DR = Registry(DangerActions, &.{
        .{ .fn_name = "wipe", .description = "Delete everything.", .risk = .dangerous },
        .{ .fn_name = "nuke", .description = "Delete everything else.", .risk = .dangerous },
    });
    const p: policy.Policy = .{ .allow_risk = .dangerous };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // A routine first-time ask.
    const first = DR.invoke(arena.allocator(), "wipe", "{}", p, null);
    try std.testing.expect(first == .needs_confirmation);
    const token = first.needs_confirmation;

    // The same token, redeemed against a different tool — this is the
    // attack the (tool, args) binding exists to stop, and it must not read
    // the same in the audit trail as the routine ask above.
    const wrong = DR.invoke(arena.allocator(), "nuke", "{}", p, token);
    try std.testing.expect(wrong == .needs_confirmation);

    var buf: [4]audit.Record = undefined;
    const got = audit.recent(&buf);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqual(audit.Outcome.needs_confirmation, got[0].outcome);
    try std.testing.expectEqual(audit.Outcome.claim_rejected, got[1].outcome);

    policy.resetTokens();
    audit.reset();
}
