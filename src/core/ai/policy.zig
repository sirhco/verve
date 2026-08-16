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
// A full table refuses to issue instead — fail-closed — *unless* the
// occupant is old enough to be presumed abandoned; see `findIssuableSlot`.
pub const token_cap = 16;

const Slot = struct {
    in_use: bool = false,
    token: u64 = 0,
    binding: u64 = 0,
    /// Logical-clock value (`clock`, not wall time) when this slot was
    /// minted. Used only to find "the oldest occupied slot" for reclaiming
    /// abandoned confirmations — see `stale_after`.
    generation: u64 = 0,
};

var tokens: [token_cap]Slot = @splat(.{});
var mu: std.atomic.Mutex = .unlocked;

fn lock() void {
    while (!mu.tryLock()) std.atomic.spinLoopHint();
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
///
/// Unlike `initRandom`, this is *not* idempotent: it overwrites whatever key
/// is already in place. Because `key` also derives every slot's `binding`
/// (see `bindingOf`), rekeying silently invalidates every token currently in
/// the table — each outstanding `binding` was computed under the old key, so
/// no pending approval can ever be claimed again and each slot sits until
/// reclaimed as stale. That fails closed, and calling this mid-flight is a
/// host/test decision rather than something production code does, but it is
/// not a no-op on existing state: seed once, at startup, before any tool
/// call.
pub fn setKey(new_key: [KEY_LEN]u8) void {
    key = new_key;
    key_initialized = true;
}

/// Draw a fresh key from real OS-backed randomness via `io.random`.
/// Idempotent — a second call is a no-op, same as `csrf.initFromEnvOrRandom`,
/// so unlike `setKey` it can never invalidate pending confirmations.
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
    /// The pending-confirmation table is at capacity, and no occupied slot
    /// is old enough to be presumed abandoned — see `findIssuableSlot`.
    TableFull,
};

/// HMAC-SHA256(key, name ++ args_json), truncated to a u64. Keyed (unlike
/// the Wyhash this replaces) because this is the check that stops an
/// approval for one call being spent on another: an unkeyed hash under a
/// publicly known seed is guessable by anyone who can compute it, which
/// defeats the point once `key` exists anyway to key something else.
fn bindingOf(name: []const u8, args_json: []const u8) u64 {
    var hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(&key);
    hmac.update(name);
    hmac.update(args_json);
    var mac: [32]u8 = undefined;
    hmac.final(&mac);
    return std.mem.readInt(u64, mac[0..8], .little);
}

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

// ---- Reclaiming abandoned slots -----------------------------------------
//
// A slot is only ever freed by a *successful* claim (or a test's
// `resetTokens`). Left at that, every un-approved ask — a human who
// declines, one who never answers, a replayed or foreign token — leaks a
// slot permanently: after `token_cap` of them, over the whole process
// lifetime, every later dangerous call hits `TableFull` until restart. That
// fails closed, not open, so it isn't a bypass, but it permanently kills
// the mechanism this module exists to provide, which is its own kind of
// failure.
//
// The fix has two parts. First, `issueToken` dedupes: a repeated ask for
// the exact same `(name, args_json)` returns the slot's existing token
// instead of minting a second one, which is the common case (a model
// retrying one call) and costs nothing extra. Second, for asks that are
// genuinely abandoned — different calls that pile up over time — the
// oldest occupied slot becomes reclaimable once enough *other* activity has
// happened since it was minted. `core/` has no `Io` handle on this path (see
// the token-secret note above), so there is no wall clock to measure real
// elapsed time; `clock` is a logical tick, incremented once per
// `issueToken` call regardless of outcome (so that a table stuck at
// capacity keeps advancing even while every attempt fails — otherwise
// nothing would ever count as "old enough," and the table would stay wedged
// forever, right back where this started). That means an attacker who can
// also drive new asks can advance this clock arbitrarily fast: this bounds
// the worst case (the table cannot stay wedged past `stale_after` further
// asks) rather than proving a slot has truly sat idle for any real amount
// of time. A wall-clock TTL would be the stronger mechanism if this code
// ever gains access to one.
var clock: u64 = 0;

/// Generation-distance beyond which an unclaimed slot may be reclaimed.
/// `token_cap * 4`: headroom so a *short* burst of unrelated activity doesn't
/// threaten a confirmation a human might still be about to act on. That's the
/// whole guarantee — it holds for the first `stale_after` ticks after a slot
/// is minted, and no longer. Once the table has been full that long, every
/// further ask reclaims the oldest slot, so the scheme degrades to plain LRU
/// eviction rather than staying fail-closed: a slot minted 64+ ticks ago is
/// evictable however recently a human looked at it. `clock` counts asks, not
/// time (see the block comment above), and it ticks in `issueToken` before
/// the dedupe early-return, so even a repeated ask that consumes no slot
/// still ages every occupant. Accepted: the alternative is a table that
/// wedges permanently, and the exposure is denial-of-service on pending
/// confirmations, never an unapproved execution.
const stale_after: u64 = token_cap * 4;

/// A free slot if one exists; otherwise the single oldest occupied slot, if
/// it's old enough (`stale_after` ticks of `clock`) to be presumed
/// abandoned. Returns null only when every slot is occupied and none is
/// stale — the fail-closed case, preserved for slots that are plausibly
/// still live.
fn findIssuableSlot() ?usize {
    for (&tokens, 0..) |*slot, i| {
        if (!slot.in_use) return i;
    }
    var oldest_idx: usize = 0;
    var oldest_gen: u64 = std.math.maxInt(u64);
    for (&tokens, 0..) |*slot, i| {
        if (slot.generation < oldest_gen) {
            oldest_gen = slot.generation;
            oldest_idx = i;
        }
    }
    if (clock -% oldest_gen >= stale_after) return oldest_idx;
    return null;
}

/// Mint (or, for a repeated identical ask, return the existing) confirmation
/// token for the exact `(name, args_json)` call. Fails closed on either of
/// two conditions, never silently degrading: `IssueError.Unseeded` if no key
/// has been set yet, or `IssueError.TableFull` if every slot is occupied and
/// none is stale — an attacker who keeps dangerous calls pending can only
/// ever hit "too many pending confirmations," never silently evict someone
/// else's pending approval before it's had a fair chance to be acted on.
pub fn issueToken(name: []const u8, args_json: []const u8) IssueError!u64 {
    if (!key_initialized) return IssueError.Unseeded;
    const binding = bindingOf(name, args_json);

    lock();
    defer mu.unlock();
    clock +%= 1;

    // A repeated ask for the exact same call returns its existing token
    // instead of minting a second one and leaking a slot — this is also
    // what keeps a human's in-progress approval alive instead of
    // invalidating it just because the model (or a retry) asked again.
    for (&tokens) |*slot| {
        if (slot.in_use and slot.binding == binding) return slot.token;
    }

    const idx = findIssuableSlot() orelse return IssueError.TableFull;
    const t = nextTokenValue();
    tokens[idx] = .{ .in_use = true, .token = t, .binding = binding, .generation = clock };
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

/// Test-only: clear the token table (and its logical clock) so tests don't
/// interfere with each other. Deliberately does not touch `key` — production
/// code has no path back to "unseeded" once initialized. A host must never
/// call this: besides discarding every pending confirmation outright, it
/// also rewinds `issued_count`, which would replay the identical HMAC
/// counter sequence against the still-live key. Harmless for a throwaway
/// test process; not something a long-running server should ever do.
pub fn resetTokens() void {
    lock();
    defer mu.unlock();
    tokens = @splat(.{});
    issued_count = 0;
    clock = 0;
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

/// Distinct argument JSON per call, for tests that need to fill several
/// slots with genuinely different bindings (dedupe would otherwise collapse
/// repeated identical args onto a single slot).
fn fmtArgs(buf: []u8, n: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"n\":{d}}}", .{n}) catch unreachable;
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
    // already have an occupied slot here. Fill every slot with distinct
    // calls and confirm the table has its full capacity available, not
    // `token_cap - 1`.
    var i: usize = 0;
    while (i < token_cap) : (i += 1) {
        var buf: [24]u8 = undefined;
        _ = try issueToken("filler", fmtArgs(&buf, i));
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
        var buf: [24]u8 = undefined;
        const t = try issueToken("wipe", fmtArgs(&buf, i));
        if (i == 0) first_token = t;
    }
    // Table is now full of distinct, recent slots; a further issuance must
    // be refused, not silently evict the oldest pending approval.
    try std.testing.expectError(IssueError.TableFull, issueToken("wipe", "{\"n\":999}"));
    // The very first token issued must still be live and claimable.
    try std.testing.expect(claimToken(first_token.?, "wipe", "{\"n\":0}"));
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

test "policy: a repeated ask for the same call returns the existing token, not a second slot" {
    resetTokens();
    seedTestKey();
    const first = try issueToken("wipe", "{}");
    const second = try issueToken("wipe", "{}");
    try std.testing.expectEqual(first, second);

    // Only one slot should have been consumed by the two asks above — fill
    // the rest of the table with distinct calls and confirm we get exactly
    // `token_cap - 1` more successful issuances, not `token_cap - 2` (which
    // would mean the repeated ask had consumed a second slot).
    var i: usize = 0;
    while (i < token_cap - 1) : (i += 1) {
        var buf: [24]u8 = undefined;
        _ = try issueToken("filler", fmtArgs(&buf, i));
    }
    try std.testing.expectError(IssueError.TableFull, issueToken("last", "{}"));
    resetTokens();
}

test "policy: abandoned asks do not permanently brick the confirmation table" {
    resetTokens();
    seedTestKey();

    // Fill every slot with a distinct, never-claimed ask — simulates 16
    // declined or ignored confirmations piling up over the process
    // lifetime.
    var i: usize = 0;
    while (i < token_cap) : (i += 1) {
        var buf: [24]u8 = undefined;
        _ = try issueToken("wipe", fmtArgs(&buf, i));
    }

    // Immediately after, the table is genuinely full of "recent" slots —
    // still refuses. This is the fail-closed guarantee from the previous
    // fix, unchanged: a burst of activity can't instantly evict something
    // that might still be live.
    try std.testing.expectError(IssueError.TableFull, issueToken("wipe", "{\"n\":999}"));

    // Enough further distinct asks pass for the oldest slot to be presumed
    // abandoned; issuance must eventually recover, not stay wedged forever.
    var reclaimed = false;
    var j: usize = 0;
    while (j < stale_after) : (j += 1) {
        var buf: [24]u8 = undefined;
        if (issueToken("nuke", fmtArgs(&buf, j))) |_| {
            reclaimed = true;
            break;
        } else |_| {}
    }
    try std.testing.expect(reclaimed);
    resetTokens();
}
