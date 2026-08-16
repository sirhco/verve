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

// ---- Token secret -------------------------------------------------------
//
// `needs_confirmation` hands a token to the caller *by design* — that's how
// a host shows a human what to approve. So the value can't be a PRNG output:
// anyone who legitimately triggers one confirmation would see a value they
// could invert or extrapolate from, and a generator whose internal state is
// recoverable from a single output is worse than the sequential counter it
// would replace, not better. Values must be unguessable *even to someone who
// has already seen other tokens* — that needs a real keyed secret, not
// process-local entropy mixed on the dispatch path.
//
// Mirrors `src/core/csrf.zig`'s shape exactly, for the same reason it does:
// entropy has to enter where an `Io` genuinely exists — at process startup —
// not down here on the comptime dispatch path, which `core/` keeps free of
// OS handles (this module also never compiles into the wasm32-freestanding
// client — verified only `src/verve.zig` imports `core/ai/*` — but the
// startup-only entry point is the right shape regardless of that).
pub const KEY_LEN: usize = 32;
var key: [KEY_LEN]u8 = undefined;
var key_initialized: bool = false;
var issued_count: u64 = 0;

/// Test/host seam for a deterministic key. Same role as `csrf.setKey`.
pub fn setKey(new_key: [KEY_LEN]u8) void {
    key = new_key;
    key_initialized = true;
}

/// Draw a fresh key from real OS-backed randomness via `io.random`.
/// Idempotent — a second call is a no-op, same as `csrf.initFromEnvOrRandom`.
/// Call once at server/desktop-host startup, next to the CSRF key init.
pub fn initRandom(io: std.Io) void {
    if (key_initialized) return;
    io.random(&key);
    key_initialized = true;
}

pub const IssueError = error{
    /// No key has been seeded yet — the host hasn't called `initRandom` (or
    /// a test hasn't called `setKey`). Deliberately *not* an assert: island
    /// chunks compile `ReleaseSmall` with asserts stripped, so an assert
    /// here would silently vanish exactly where it matters. A dangerous
    /// tool being unconfirmable until the host wires the key is the safe
    /// failure — never fall back to a weaker, unseeded generator.
    Unseeded,
    /// The pending-confirmation table is at capacity.
    TableFull,
};

/// HMAC-SHA256(key, counter), truncated to a u64. A keyed PRF: unlike a bare
/// PRNG, no output — however many an attacker collects — leaks anything
/// about `key` or predicts the next one. `issued_count` only needs to be
/// unique per call, never secret; the security lives entirely in `key`.
fn nextTokenValue() u64 {
    var t: u64 = 0;
    while (t == 0) {
        issued_count +%= 1;
        var counter_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &counter_bytes, issued_count, .little);
        var mac: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, &counter_bytes, &key);
        t = std.mem.readInt(u64, mac[0..8], .little);
    }
    return t;
}

/// Mint a fresh confirmation token bound to the exact `(name, args_json)`
/// call, in an empty slot. Fails closed on either of two conditions, never
/// silently degrading: `IssueError.Unseeded` if no key has been set yet, or
/// `IssueError.TableFull` if every slot is already occupied — an attacker
/// who keeps dangerous calls pending can only ever hit "too many pending
/// confirmations," never silently evict someone else's pending approval.
pub fn issueToken(name: []const u8, args_json: []const u8) IssueError!u64 {
    if (!key_initialized) return IssueError.Unseeded;
    lock();
    defer mu.unlock();
    var free_idx: ?usize = null;
    for (&tokens, 0..) |*slot, i| {
        if (!slot.in_use) {
            free_idx = i;
            break;
        }
    }
    const idx = free_idx orelse return IssueError.TableFull;
    const t = nextTokenValue();
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

/// Seed a fixed, reproducible key via the public `setKey` seam — same
/// pattern as every `csrf.zig` test, factored out since many tests here
/// need it. Never used outside tests; production seeding goes through
/// `initRandom`.
fn seedTestKey() void {
    var k: [KEY_LEN]u8 = undefined;
    for (&k, 0..) |*b, i| b.* = @intCast(i);
    setKey(k);
}

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
    seedTestKey();
    const token = try issueToken("wipe", "{}");
    try std.testing.expect(claimToken(token, "wipe", "{}"));
    try std.testing.expect(!claimToken(token, "wipe", "{}"));
    try std.testing.expect(!claimToken(token +% 1, "wipe", "{}"));
}

test "policy: a token issued for one tool does not authorise another" {
    resetTokens();
    seedTestKey();
    const token = try issueToken("wipe", "{}");

    // A different tool name, same token value and same argument bytes: must
    // not claim.
    try std.testing.expect(!claimToken(token, "deleteAll", "{}"));
    // The mismatch above must not have spent it — the call it was actually
    // issued for still claims successfully.
    try std.testing.expect(claimToken(token, "wipe", "{}"));
}

test "policy: a token issued for one argument payload does not authorise another" {
    resetTokens();
    seedTestKey();
    const token = try issueToken("wipe", "{\"id\":5}");

    // Same tool, different argument bytes: must not claim.
    try std.testing.expect(!claimToken(token, "wipe", "{\"id\":999}"));
    // Not spent by the mismatch above — the exact call it was issued for
    // still claims successfully.
    try std.testing.expect(claimToken(token, "wipe", "{\"id\":5}"));
}

test "policy: a failed claim does not consume the token" {
    resetTokens();
    seedTestKey();
    const token = try issueToken("wipe", "{}");

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
    seedTestKey();
    const token = try issueToken("wipe", "{}");
    try std.testing.expect(claimToken(token, "wipe", "{}"));

    // If claiming had also left a fresh, unclaimed token sitting in the
    // table (the leftover-authorization bug this fixes), the table would
    // already have an occupied slot here. Fill every slot and confirm the
    // table has its full capacity available, not `token_cap - 1`.
    var i: usize = 0;
    while (i < token_cap) : (i += 1) {
        _ = try issueToken("filler", "{}");
    }
    try std.testing.expectError(IssueError.TableFull, issueToken("filler", "{}"));
    resetTokens();
}

test "policy: a full table refuses to issue rather than evicting a pending approval" {
    resetTokens();
    seedTestKey();
    var first_token: ?u64 = null;
    var i: usize = 0;
    while (i < token_cap) : (i += 1) {
        const t = try issueToken("wipe", "{}");
        if (i == 0) first_token = t;
    }
    // Table is now full; a further issuance must be refused, not silently
    // evict the oldest pending approval.
    try std.testing.expectError(IssueError.TableFull, issueToken("wipe", "{}"));
    // The very first token issued must still be live and claimable.
    try std.testing.expect(claimToken(first_token.?, "wipe", "{}"));
    resetTokens();
}

test "policy: an unseeded token store refuses to issue rather than falling back to a weaker generator" {
    resetTokens();
    // Simulate the host never having called `initRandom` — save and restore
    // the real flag so this doesn't leak an unseeded state to other tests.
    const was_initialized = key_initialized;
    key_initialized = false;
    defer key_initialized = was_initialized;

    try std.testing.expectError(IssueError.Unseeded, issueToken("wipe", "{}"));
}
