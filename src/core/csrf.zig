//! Cookie + form-field CSRF tokens. The server generates a per-process
//! key at startup (or reads `VERVE_CSRF_KEY` from the environment for
//! deterministic tokens across restarts), and stamps each rendered
//! page with a fresh token via:
//!
//!   - `Set-Cookie: __verve_csrf=<token>; HttpOnly; SameSite=Strict`
//!   - `<input type=hidden name=__csrf value=<token>>` inside any form
//!     that posts to an Action.
//!
//! Non-GET requests reaching the API dispatcher must echo back the
//! token in BOTH the cookie and the form field; mismatches return 403.
//! Origin headers, when present, are checked against `Host`.
//!
//! The token is `base64url(timestamp || hmac_sha256(key, timestamp))`
//! truncated to 16 bytes of MAC for compactness. 64-bit timestamps in
//! seconds give a usable lifetime for the cookie; the validator
//! rejects tokens older than `MAX_AGE_SEC`.

const std = @import("std");

pub const COOKIE_NAME = "__verve_csrf";
pub const FIELD_NAME = "__csrf";
pub const MAX_AGE_SEC: i64 = 60 * 60 * 24; // 24h

pub const KEY_LEN: usize = 32;
pub const MAC_LEN: usize = 16;
const TOKEN_BIN_LEN: usize = 8 + MAC_LEN;
pub const TOKEN_TEXT_LEN: usize = std.base64.url_safe_no_pad.Encoder.calcSize(TOKEN_BIN_LEN);

/// Process-wide HMAC key. Initialized once at server startup via
/// `initFromEnvOrRandom`. Tests that need deterministic tokens can call
/// `setKey` directly.
var key: [KEY_LEN]u8 = undefined;
var key_initialized: bool = false;

pub fn setKey(new_key: [KEY_LEN]u8) void {
    key = new_key;
    key_initialized = true;
}

/// Initialize the key from the `VERVE_CSRF_KEY` environment variable
/// (hex-encoded 32 bytes) or by drawing fresh randomness via `io`.
/// Idempotent.
pub fn initFromEnvOrRandom(env_value: ?[]const u8, io: std.Io) void {
    if (key_initialized) return;
    if (env_value) |raw| if (raw.len == KEY_LEN * 2) {
        if (std.fmt.hexToBytes(&key, raw)) |_| {
            key_initialized = true;
            return;
        } else |_| {}
    };
    io.random(&key);
    key_initialized = true;
}

/// Generate a fresh token for `now_secs`. Writes into `out` which must
/// be at least `TOKEN_TEXT_LEN` bytes; returns the populated prefix.
pub fn generate(out: []u8, now_secs: i64) ![]const u8 {
    std.debug.assert(key_initialized);
    std.debug.assert(out.len >= TOKEN_TEXT_LEN);

    var bin: [TOKEN_BIN_LEN]u8 = undefined;
    std.mem.writeInt(i64, bin[0..8], now_secs, .little);

    var mac_full: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac_full, bin[0..8], &key);
    @memcpy(bin[8..], mac_full[0..MAC_LEN]);

    return std.base64.url_safe_no_pad.Encoder.encode(out[0..TOKEN_TEXT_LEN], &bin);
}

/// Validate `token` against the current key, the form field, and the
/// max-age. Returns true only when all three checks pass. Constant-
/// time comparison on the MAC.
pub fn validate(token: []const u8, cookie_value: []const u8, now_secs: i64) bool {
    if (!key_initialized) return false;
    if (token.len == 0 or token.len != cookie_value.len) return false;
    if (!constantTimeEqual(token, cookie_value)) return false;

    var bin: [TOKEN_BIN_LEN]u8 = undefined;
    std.base64.url_safe_no_pad.Decoder.decode(&bin, token) catch return false;

    const ts = std.mem.readInt(i64, bin[0..8], .little);
    if (now_secs - ts > MAX_AGE_SEC) return false;
    if (ts - now_secs > 60) return false; // small clock skew tolerance

    var mac_expected: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac_expected, bin[0..8], &key);
    return constantTimeEqual(bin[8..], mac_expected[0..MAC_LEN]);
}

fn constantTimeEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

/// Format the `Set-Cookie` value the server emits for the CSRF cookie.
/// Caller supplies the buffer.
pub fn cookieHeaderValue(out: []u8, token: []const u8) ![]const u8 {
    return std.fmt.bufPrint(out, "{s}={s}; HttpOnly; SameSite=Strict; Path=/", .{ COOKIE_NAME, token });
}

// ---- tests ------------------------------------------------------------

const testing = std.testing;

test "generate + validate roundtrip" {
    var k: [KEY_LEN]u8 = .{0} ** KEY_LEN;
    for (&k, 0..) |*b, i| b.* = @intCast(i);
    setKey(k);

    var buf: [TOKEN_TEXT_LEN]u8 = undefined;
    const tok = try generate(&buf, 1_000_000);
    try testing.expect(validate(tok, tok, 1_000_001));
}

test "validate rejects expired token" {
    var k: [KEY_LEN]u8 = .{0} ** KEY_LEN;
    for (&k, 0..) |*b, i| b.* = @intCast(i);
    setKey(k);

    var buf: [TOKEN_TEXT_LEN]u8 = undefined;
    const tok = try generate(&buf, 1_000_000);
    try testing.expect(!validate(tok, tok, 1_000_000 + MAX_AGE_SEC + 10));
}

test "validate rejects mismatched cookie vs field" {
    var k: [KEY_LEN]u8 = .{0} ** KEY_LEN;
    for (&k, 0..) |*b, i| b.* = @intCast(i);
    setKey(k);

    var buf_a: [TOKEN_TEXT_LEN]u8 = undefined;
    var buf_b: [TOKEN_TEXT_LEN]u8 = undefined;
    const tok_a = try generate(&buf_a, 1_000_000);
    const tok_b = try generate(&buf_b, 1_000_005);
    try testing.expect(!validate(tok_a, tok_b, 1_000_010));
}

test "validate rejects garbled token" {
    var k: [KEY_LEN]u8 = .{0} ** KEY_LEN;
    for (&k, 0..) |*b, i| b.* = @intCast(i);
    setKey(k);

    try testing.expect(!validate("not-a-token", "not-a-token", 1_000_000));
}
