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

pub fn check(p: Policy, decl: tool.ToolDecl, args_len: usize) Decision {
    if (args_len > p.max_args_bytes) return .{ .deny = "arguments too large" };
    if (@intFromEnum(decl.risk) > @intFromEnum(p.allow_risk)) return .{ .deny = "risk above policy threshold" };
    if (@intFromEnum(decl.risk) >= @intFromEnum(p.confirm_at)) return .{ .needs_confirmation = issueToken() };
    return .allow;
}

// Fixed-size, allocator-free token table. Styled after `src/server/push.zig`'s
// static channel array: bounded memory, no growth under adversarial load.
const token_cap = 16;
var tokens: [token_cap]std.atomic.Value(u64) = @splat(std.atomic.Value(u64).init(0));
var token_seq: std.atomic.Value(u64) = .init(1);

fn issueToken() u64 {
    const t = token_seq.fetchAdd(1, .monotonic);
    const slot = @as(usize, @intCast(t % token_cap));
    tokens[slot].store(t, .release);
    return t;
}

/// Consume a confirmation token. Returns false if it is unknown or already
/// spent — one approval authorises exactly one execution.
pub fn claimToken(token: u64) bool {
    if (token == 0) return false;
    const slot = @as(usize, @intCast(token % token_cap));
    return tokens[slot].cmpxchgStrong(token, 0, .acq_rel, .acquire) == null;
}

/// Test-only: clear the token table so tests don't interfere.
pub fn resetTokens() void {
    for (&tokens) |*t| t.store(0, .release);
    token_seq.store(1, .release);
}

// ---- tests ------------------------------------------------------------

test "policy: safe and mutating tools pass at the default threshold" {
    const p: Policy = .{};
    try std.testing.expect(check(p, .{ .fn_name = "a", .description = "", .risk = .safe }, 10) == .allow);
    try std.testing.expect(check(p, .{ .fn_name = "b", .description = "", .risk = .mutating }, 10) == .allow);
}

test "policy: dangerous tools require confirmation, never run outright" {
    const p: Policy = .{ .allow_risk = .dangerous };
    const d = check(p, .{ .fn_name = "wipe", .description = "", .risk = .dangerous }, 10);
    try std.testing.expect(d == .needs_confirmation);
}

test "policy: risk above the threshold is denied outright" {
    // Default allow_risk is .mutating, so a dangerous tool is denied before
    // the confirmation path is even reached.
    const p: Policy = .{};
    const d = check(p, .{ .fn_name = "wipe", .description = "", .risk = .dangerous }, 10);
    try std.testing.expect(d == .deny);
}

test "policy: oversized arguments are denied" {
    const p: Policy = .{ .max_args_bytes = 8 };
    const d = check(p, .{ .fn_name = "a", .description = "", .risk = .safe }, 9);
    try std.testing.expect(d == .deny);
}

test "policy: a confirmation token is single-use" {
    const p: Policy = .{ .allow_risk = .dangerous };
    const d = check(p, .{ .fn_name = "wipe", .description = "", .risk = .dangerous }, 10);
    const token = d.needs_confirmation;
    try std.testing.expect(claimToken(token));
    try std.testing.expect(!claimToken(token));
    try std.testing.expect(!claimToken(token +% 1));
}
