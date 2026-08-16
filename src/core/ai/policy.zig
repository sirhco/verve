//! Runtime gate for model-chosen tool calls.
//!
//! The comptime allowlist is the primary boundary — everything here is defence
//! in depth on top of it. All of it runs in Zig: on desktop the JS shim is
//! injected into a webview the page controls, so nothing about the policy can
//! be enforced there.

const std = @import("std");
const tool = @import("tool.zig");

pub const Policy = struct {
    /// Maximum agent turns before the loop gives up.
    max_steps: u8 = 8,
    /// Tool replies longer than this are truncated before the model sees them.
    max_tool_result_bytes: usize = 16 * 1024,
    /// Model-supplied argument JSON longer than this is rejected unparsed.
    max_args_bytes: usize = 8 * 1024,
    /// Highest risk tier this policy will run at all.
    allow_risk: tool.Risk = .mutating,
    /// Risk tier at and above which a human must confirm before execution.
    confirm_at: tool.Risk = .dangerous,
};

pub const Decision = union(enum) {
    allow,
    deny: []const u8,
    /// Carries a single-use token the host echoes back once a human approves.
    needs_confirmation: u64,
};

pub fn check(p: Policy, decl: tool.ToolDecl, args_json: []const u8) Decision {
    if (args_json.len > p.max_args_bytes) return .{ .deny = "arguments too large" };
    if (@intFromEnum(decl.risk) > @intFromEnum(p.allow_risk)) return .{ .deny = "risk above policy threshold" };
    if (@intFromEnum(decl.risk) >= @intFromEnum(p.confirm_at)) return .{ .needs_confirmation = issueToken(decl.fn_name, args_json) };
    return .allow;
}

// Fixed-size, allocator-free token table. Styled after `src/server/push.zig`'s
// static channel array: bounded memory, no growth under adversarial load.
//
// Single-use bounds *how many times* a token redeems; it says nothing about
// *what* it redeems. Each slot also carries a hash of the tool name and exact
// argument bytes the token was issued for, so a human's approval of one call
// can never be spent on a different tool or a different set of arguments —
// only on the exact call it was minted for. Hashing (not storing the strings)
// keeps the table fixed-size: no unbounded name/args buffers to size for
// adversarial input.
const token_cap = 16;

const Slot = struct {
    token: u64 = 0,
    binding: u64 = 0,
};

var tokens: [token_cap]Slot = @splat(.{});
var token_seq: u64 = 1;
var mu: std.atomic.Mutex = .unlocked;

fn lock() void {
    while (!mu.tryLock()) std.atomic.spinLoopHint();
}

fn bindingOf(name: []const u8, args_json: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(name);
    h.update(args_json);
    return h.final();
}

fn issueToken(name: []const u8, args_json: []const u8) u64 {
    lock();
    defer mu.unlock();
    const t = token_seq;
    token_seq +%= 1;
    const slot = @as(usize, @intCast(t % token_cap));
    tokens[slot] = .{ .token = t, .binding = bindingOf(name, args_json) };
    return t;
}

/// Consume a confirmation token, but only against the exact call it was
/// issued for. Returns false if the token is unknown, already spent, or
/// bound to a different tool name or argument payload than the one being
/// attempted here.
///
/// A mismatch never consumes the token — a wrong-call attempt (a model
/// retrying with different arguments, or trying to redeem one tool's
/// approval against another) must not be able to burn a legitimate pending
/// approval out from under the call it actually belongs to. That would be a
/// denial-of-service against the human who is about to approve it correctly.
pub fn claimToken(token: u64, name: []const u8, args_json: []const u8) bool {
    if (token == 0) return false;
    lock();
    defer mu.unlock();
    const slot = @as(usize, @intCast(token % token_cap));
    if (tokens[slot].token != token) return false;
    if (tokens[slot].binding != bindingOf(name, args_json)) return false;
    tokens[slot] = .{};
    return true;
}

/// Test-only: clear the token table so tests don't interfere.
pub fn resetTokens() void {
    lock();
    defer mu.unlock();
    tokens = @splat(.{});
    token_seq = 1;
}

// ---- tests ------------------------------------------------------------

test "policy: safe and mutating tools pass at the default threshold" {
    const p: Policy = .{};
    try std.testing.expect(check(p, .{ .fn_name = "a", .description = "", .risk = .safe }, "0123456789") == .allow);
    try std.testing.expect(check(p, .{ .fn_name = "b", .description = "", .risk = .mutating }, "0123456789") == .allow);
}

test "policy: dangerous tools require confirmation, never run outright" {
    const p: Policy = .{ .allow_risk = .dangerous };
    const d = check(p, .{ .fn_name = "wipe", .description = "", .risk = .dangerous }, "0123456789");
    try std.testing.expect(d == .needs_confirmation);
}

test "policy: risk above the threshold is denied outright" {
    // Default allow_risk is .mutating, so a dangerous tool is denied before
    // the confirmation path is even reached.
    const p: Policy = .{};
    const d = check(p, .{ .fn_name = "wipe", .description = "", .risk = .dangerous }, "0123456789");
    try std.testing.expect(d == .deny);
}

test "policy: oversized arguments are denied" {
    const p: Policy = .{ .max_args_bytes = 8 };
    const d = check(p, .{ .fn_name = "a", .description = "", .risk = .safe }, "123456789");
    try std.testing.expect(d == .deny);
}

test "policy: a confirmation token is single-use" {
    resetTokens();
    const p: Policy = .{ .allow_risk = .dangerous };
    const decl = tool.ToolDecl{ .fn_name = "wipe", .description = "", .risk = .dangerous };
    const d = check(p, decl, "{}");
    const token = d.needs_confirmation;
    try std.testing.expect(claimToken(token, "wipe", "{}"));
    try std.testing.expect(!claimToken(token, "wipe", "{}"));
    try std.testing.expect(!claimToken(token +% 1, "wipe", "{}"));
}

test "policy: a token issued for one tool does not authorise another" {
    resetTokens();
    const p: Policy = .{ .allow_risk = .dangerous };
    const decl = tool.ToolDecl{ .fn_name = "wipe", .description = "", .risk = .dangerous };
    const d = check(p, decl, "{}");
    const token = d.needs_confirmation;

    // A different tool name, same token value and same argument bytes: must
    // not claim.
    try std.testing.expect(!claimToken(token, "deleteAll", "{}"));
    // The mismatch above must not have spent it — the call it was actually
    // issued for still claims successfully.
    try std.testing.expect(claimToken(token, "wipe", "{}"));
}

test "policy: a token issued for one argument payload does not authorise another" {
    resetTokens();
    const p: Policy = .{ .allow_risk = .dangerous };
    const decl = tool.ToolDecl{ .fn_name = "wipe", .description = "", .risk = .dangerous };
    const d = check(p, decl, "{\"id\":5}");
    const token = d.needs_confirmation;

    // Same tool, different argument bytes: must not claim.
    try std.testing.expect(!claimToken(token, "wipe", "{\"id\":999}"));
    // Not spent by the mismatch above — the exact call it was issued for
    // still claims successfully.
    try std.testing.expect(claimToken(token, "wipe", "{\"id\":5}"));
}

test "policy: a failed claim does not consume the token" {
    resetTokens();
    const p: Policy = .{ .allow_risk = .dangerous };
    const decl = tool.ToolDecl{ .fn_name = "wipe", .description = "", .risk = .dangerous };
    const d = check(p, decl, "{}");
    const token = d.needs_confirmation;

    // A pile of wrong attempts: wrong name, wrong args, wrong token value.
    try std.testing.expect(!claimToken(token, "other", "{}"));
    try std.testing.expect(!claimToken(token, "wipe", "{\"x\":1}"));
    try std.testing.expect(!claimToken(token +% 1, "wipe", "{}"));

    // None of them spent the legitimate token — it still claims once...
    try std.testing.expect(claimToken(token, "wipe", "{}"));
    // ...and only once.
    try std.testing.expect(!claimToken(token, "wipe", "{}"));
}
