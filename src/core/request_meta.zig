//! Snapshot of incoming request headers captured BEFORE the body is read.
//! `std.http.Server` requires header iteration while the reader is in the
//! `received_head` state, which transitions out as soon as the body reader
//! is acquired — so the server populates this struct once at the top of
//! the request and threads it into both the API dispatcher and the page
//! renderer.

const std = @import("std");
const http = std.http;

pub const Method = enum {
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,
    HEAD,
    OPTIONS,
    OTHER,

    pub fn fromStdMethod(m: http.Method) Method {
        return switch (m) {
            .GET => .GET,
            .POST => .POST,
            .PUT => .PUT,
            .PATCH => .PATCH,
            .DELETE => .DELETE,
            .HEAD => .HEAD,
            .OPTIONS => .OPTIONS,
            else => .OTHER,
        };
    }
};

pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

const FORM_CT = "application/x-www-form-urlencoded";

/// Maximum cookies parsed from the Cookie header. Keeps the snapshot
/// allocation-free during request setup; extra cookies are silently
/// dropped (browsers cap at ~50 cookies/domain so the limit is generous).
pub const MAX_COOKIES: usize = 32;

pub const RequestMeta = struct {
    method: Method = .OTHER,
    is_form: bool = false,
    referer: ?[]const u8 = null,
    accept_gzip: bool = false,
    accept_brotli: bool = false,
    accept_language: ?[]const u8 = null,
    user_agent: ?[]const u8 = null,
    origin: ?[]const u8 = null,
    host: ?[]const u8 = null,
    /// Raw Cookie header — split into name/value pairs by `parseCookies`.
    cookie_header: ?[]const u8 = null,

    /// Look up a cookie by name. Returns null when the cookie is absent or
    /// the Cookie header was not present on the request.
    pub fn cookie(self: RequestMeta, name: []const u8) ?[]const u8 {
        const raw = self.cookie_header orelse return null;
        var it = std.mem.tokenizeScalar(u8, raw, ';');
        while (it.next()) |pair_raw| {
            const pair = std.mem.trim(u8, pair_raw, " \t");
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (std.mem.eql(u8, pair[0..eq], name)) {
                return pair[eq + 1 ..];
            }
        }
        return null;
    }

    /// Parse the Cookie header into a caller-provided buffer. Stops at
    /// `out.len` cookies. Returns the populated prefix.
    pub fn parseCookies(self: RequestMeta, out: []Cookie) []const Cookie {
        const raw = self.cookie_header orelse return out[0..0];
        var n: usize = 0;
        var it = std.mem.tokenizeScalar(u8, raw, ';');
        while (it.next()) |pair_raw| {
            if (n == out.len) break;
            const pair = std.mem.trim(u8, pair_raw, " \t");
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            out[n] = .{ .name = pair[0..eq], .value = pair[eq + 1 ..] };
            n += 1;
        }
        return out[0..n];
    }

    pub fn fromRequest(request: *http.Server.Request) RequestMeta {
        var result: RequestMeta = .{
            .method = Method.fromStdMethod(request.head.method),
        };
        var iter = request.iterateHeaders();
        while (iter.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "content-type")) {
                result.is_form = std.mem.startsWith(u8, h.value, FORM_CT);
            } else if (std.ascii.eqlIgnoreCase(h.name, "referer")) {
                result.referer = h.value;
            } else if (std.ascii.eqlIgnoreCase(h.name, "accept-encoding")) {
                result.accept_gzip = containsToken(h.value, "gzip");
                result.accept_brotli = containsToken(h.value, "br");
            } else if (std.ascii.eqlIgnoreCase(h.name, "accept-language")) {
                result.accept_language = h.value;
            } else if (std.ascii.eqlIgnoreCase(h.name, "user-agent")) {
                result.user_agent = h.value;
            } else if (std.ascii.eqlIgnoreCase(h.name, "origin")) {
                result.origin = h.value;
            } else if (std.ascii.eqlIgnoreCase(h.name, "host")) {
                result.host = h.value;
            } else if (std.ascii.eqlIgnoreCase(h.name, "cookie")) {
                result.cookie_header = h.value;
            }
        }
        return result;
    }
};

fn containsToken(header: []const u8, token: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, header, ", \t");
    while (it.next()) |raw| {
        const tok = if (std.mem.indexOfScalar(u8, raw, ';')) |p| raw[0..p] else raw;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, tok, " \t"), token)) return true;
    }
    return false;
}

test "RequestMeta.cookie returns value when header set" {
    const meta: RequestMeta = .{ .cookie_header = "sid=abc; theme=dark; lang=en" };
    try std.testing.expectEqualStrings("abc", meta.cookie("sid").?);
    try std.testing.expectEqualStrings("dark", meta.cookie("theme").?);
    try std.testing.expectEqualStrings("en", meta.cookie("lang").?);
    try std.testing.expect(meta.cookie("missing") == null);
}

test "RequestMeta.parseCookies splits header into pairs" {
    const meta: RequestMeta = .{ .cookie_header = "a=1; b=2; c=3" };
    var buf: [4]Cookie = undefined;
    const parsed = meta.parseCookies(&buf);
    try std.testing.expectEqual(@as(usize, 3), parsed.len);
    try std.testing.expectEqualStrings("a", parsed[0].name);
    try std.testing.expectEqualStrings("1", parsed[0].value);
    try std.testing.expectEqualStrings("c", parsed[2].name);
}

test "containsToken matches whole token only" {
    try std.testing.expect(containsToken("gzip, br", "br"));
    try std.testing.expect(containsToken("br, gzip", "br"));
    try std.testing.expect(containsToken("br;q=1.0, gzip", "br"));
    try std.testing.expect(!containsToken("brotli, gzip", "br"));
}
