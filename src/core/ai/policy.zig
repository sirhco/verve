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
    /// This call needs a human to confirm before it may run. Carries no
    /// token: minting one is `issueToken`'s job, called by the dispatcher
    /// only once it knows the caller doesn't already hold a valid token for
    /// this exact call. Keeping `check` itself non-minting means a call that
    /// arrives with a good token never causes a second, unclaimed token to
    /// be issued and then silently dropped.
    needs_confirmation,
};

pub fn check(p: Policy, decl: tool.ToolDecl, args_json: []const u8) Decision {
    if (args_json.len > p.max_args_bytes) return .{ .deny = "arguments too large" };
    if (@intFromEnum(decl.risk) > @intFromEnum(p.allow_risk)) return .{ .deny = "risk above policy threshold" };
    if (@intFromEnum(decl.risk) >= @intFromEnum(p.confirm_at)) return .needs_confirmation;
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
//
// Slots are found by linear scan, not `token % token_cap`: a modulo-derived
// slot meant a 17th pending dangerous call silently evicted an unrelated,
// still-pending human approval (and, in the worst case, a call's own
// eventual claim could be evicted by 16 *other* calls issued in between).
// A full table now refuses to issue instead — fail-closed, and the pending
// set is explicitly capped rather than silently rotated.
pub const token_cap = 16;

const Slot = struct {
    in_use: bool = false,
    token: u64 = 0,
    binding: u64 = 0,
};

var tokens: [token_cap]Slot = @splat(.{});
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

// `core/` has no `std.Io` handle to reach OS randomness — csrf.zig's
// `io.random(...)` isn't reachable this deep in a comptime dispatch call
// (and this module only ever links into host targets, never the
// wasm32-freestanding client, so address-space layout is a real per-process
// property here, not a wasm illusion). `std.crypto.random` does not exist in
// this Zig version either (verified against the compiler, not assumed).
//
// So: seed a SplitMix64 generator once, from the runtime address of this
// module's own static state (randomized per-process by ASLR on every real
// deployment target this policy runs on) folded with an issuance counter.
// This is not a substitute for an HMAC-signed capability token — it exists
// to turn "guess the next small integer" into "guess an unexported
// address-space offset", which is the specific weakness this fixes: a
// sequential `token_seq` counted up from 1 was trivially enumerable.
var prng_state: u64 = 0;
var prng_seeded: bool = false;
var issued_count: u64 = 0;

fn nextTokenValue() u64 {
    if (!prng_seeded) {
        prng_state = @intFromPtr(&tokens) ^ (@intFromPtr(&prng_state) *% 0x2545F4914F6CDD1D) ^ issued_count;
        prng_seeded = true;
    }
    // SplitMix64 step: fast, well-distributed, avalanches so consecutive
    // issuances don't differ by a guessable delta.
    prng_state +%= 0x9E3779B97F4A7C15;
    var z = prng_state;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    z = z ^ (z >> 31);
    return z;
}

/// Mint a fresh confirmation token bound to the exact `(name, args_json)`
/// call, in an empty slot. Returns `null` — refusing to issue — if the table
/// is already full: fail-closed, so an attacker who keeps dangerous calls
/// pending can only ever hit "too many pending confirmations," never
/// silently evict someone else's pending approval.
pub fn issueToken(name: []const u8, args_json: []const u8) ?u64 {
    lock();
    defer mu.unlock();
    var free_idx: ?usize = null;
    for (&tokens, 0..) |*slot, i| {
        if (!slot.in_use) {
            free_idx = i;
            break;
        }
    }
    const idx = free_idx orelse return null;
    issued_count +%= 1;
    var t: u64 = 0;
    while (t == 0) t = nextTokenValue();
    tokens[idx] = .{ .in_use = true, .token = t, .binding = bindingOf(name, args_json) };
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
    for (&tokens) |*slot| {
        if (slot.in_use and slot.token == token) {
            if (slot.binding != bindingOf(name, args_json)) return false;
            slot.* = .{};
            return true;
        }
    }
    return false;
}

/// Test-only: clear the token table so tests don't interfere.
pub fn resetTokens() void {
    lock();
    defer mu.unlock();
    tokens = @splat(.{});
    issued_count = 0;
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
    const token = issueToken("wipe", "{}").?;
    try std.testing.expect(claimToken(token, "wipe", "{}"));
    try std.testing.expect(!claimToken(token, "wipe", "{}"));
    try std.testing.expect(!claimToken(token +% 1, "wipe", "{}"));
}

test "policy: a token issued for one tool does not authorise another" {
    resetTokens();
    const token = issueToken("wipe", "{}").?;

    // A different tool name, same token value and same argument bytes: must
    // not claim.
    try std.testing.expect(!claimToken(token, "deleteAll", "{}"));
    // The mismatch above must not have spent it — the call it was actually
    // issued for still claims successfully.
    try std.testing.expect(claimToken(token, "wipe", "{}"));
}

test "policy: a token issued for one argument payload does not authorise another" {
    resetTokens();
    const token = issueToken("wipe", "{\"id\":5}").?;

    // Same tool, different argument bytes: must not claim.
    try std.testing.expect(!claimToken(token, "wipe", "{\"id\":999}"));
    // Not spent by the mismatch above — the exact call it was issued for
    // still claims successfully.
    try std.testing.expect(claimToken(token, "wipe", "{\"id\":5}"));
}

test "policy: a failed claim does not consume the token" {
    resetTokens();
    const token = issueToken("wipe", "{}").?;

    // A pile of wrong attempts: wrong name, wrong args, wrong token value.
    try std.testing.expect(!claimToken(token, "other", "{}"));
    try std.testing.expect(!claimToken(token, "wipe", "{\"x\":1}"));
    try std.testing.expect(!claimToken(token +% 1, "wipe", "{}"));

    // None of them spent the legitimate token — it still claims once...
    try std.testing.expect(claimToken(token, "wipe", "{}"));
    // ...and only once.
    try std.testing.expect(!claimToken(token, "wipe", "{}"));
}

test "policy: an approved claim does not leave a second live token behind" {
    resetTokens();
    const token = issueToken("wipe", "{}").?;
    try std.testing.expect(claimToken(token, "wipe", "{}"));

    // If claiming had also left a fresh, unclaimed token sitting in the
    // table (the leftover-authorization bug this fixes), the table would
    // already have an occupied slot here. Fill every slot and confirm the
    // table has its full capacity available, not `token_cap - 1`.
    var i: usize = 0;
    while (i < token_cap) : (i += 1) {
        try std.testing.expect(issueToken("filler", "{}") != null);
    }
    try std.testing.expect(issueToken("filler", "{}") == null);
    resetTokens();
}

test "policy: a full table refuses to issue rather than evicting a pending approval" {
    resetTokens();
    var first_token: ?u64 = null;
    var i: usize = 0;
    while (i < token_cap) : (i += 1) {
        const t = issueToken("wipe", "{}").?;
        if (i == 0) first_token = t;
    }
    // Table is now full; a further issuance must be refused, not silently
    // evict the oldest pending approval.
    try std.testing.expect(issueToken("wipe", "{}") == null);
    // The very first token issued must still be live and claimable.
    try std.testing.expect(claimToken(first_token.?, "wipe", "{}"));
    resetTokens();
}
