//! Current-URL snapshot exposed on Context. Populated by the server before
//! invoking the route's `render`. Components read `ctx.location` for active
//! link state, query parameters, and anchor fragments without needing the
//! shell to thread it through as a prop.
//!
//! Query parsing happens lazily on first access via `query()` so routes
//! that never inspect the query string don't pay the parse cost.

const std = @import("std");

pub const QueryPair = struct {
    key: []const u8,
    value: []const u8,
};

pub const Location = struct {
    /// Path portion of the URL (no query string, no fragment).
    path: []const u8 = "/",
    /// Raw query string (without the leading `?`). Empty when absent.
    raw_query: []const u8 = "",
    /// Raw fragment (without the leading `#`). Null when absent.
    fragment: ?[]const u8 = null,
    /// Cached, lazily-parsed query pairs. Populated on first `query()` call.
    cached_pairs: ?[]const QueryPair = null,

    /// Parse a raw HTTP request target into path / raw_query / fragment.
    /// Fragments rarely arrive at the server (browsers strip them), but the
    /// parser handles them anyway so internal callers can construct
    /// Location values uniformly from any URL string.
    pub fn parse(target: []const u8) Location {
        var rest = target;
        var fragment: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, rest, '#')) |hash| {
            fragment = rest[hash + 1 ..];
            rest = rest[0..hash];
        }
        var raw_query: []const u8 = "";
        if (std.mem.indexOfScalar(u8, rest, '?')) |q| {
            raw_query = rest[q + 1 ..];
            rest = rest[0..q];
        }
        return .{ .path = rest, .raw_query = raw_query, .fragment = fragment };
    }

    /// Parse the query string into key/value pairs. Subsequent calls reuse
    /// the cached slice. Empty query produces an empty slice.
    pub fn query(self: *Location, arena: std.mem.Allocator) ![]const QueryPair {
        if (self.cached_pairs) |p| return p;
        const pairs = try parseQuery(arena, self.raw_query);
        self.cached_pairs = pairs;
        return pairs;
    }

    /// Lookup a single value by key. Returns the first match; later values
    /// are visible only via `query()`. Returns null when the key is missing.
    pub fn queryGet(self: *Location, arena: std.mem.Allocator, key: []const u8) !?[]const u8 {
        const pairs = try self.query(arena);
        for (pairs) |p| {
            if (std.mem.eql(u8, p.key, key)) return p.value;
        }
        return null;
    }

    /// True when `href` matches the current path. The trailing-slash form
    /// of either side is normalized (both `/foo` and `/foo/` match each
    /// other) so layouts can render highlighted nav items uniformly.
    pub fn isActive(self: Location, href: []const u8) bool {
        return pathsMatch(self.path, href);
    }

    /// True when the current path starts with `prefix`, useful for nav
    /// items that cover a section (`/work` matches `/work/abc`). The root
    /// path `/` only matches itself.
    pub fn isActivePrefix(self: Location, prefix: []const u8) bool {
        if (std.mem.eql(u8, prefix, "/")) return std.mem.eql(u8, self.path, "/");
        if (!std.mem.startsWith(u8, self.path, prefix)) return false;
        if (self.path.len == prefix.len) return true;
        return self.path[prefix.len] == '/';
    }
};

fn pathsMatch(a: []const u8, b: []const u8) bool {
    const an = trimTrailingSlash(a);
    const bn = trimTrailingSlash(b);
    return std.mem.eql(u8, an, bn);
}

fn trimTrailingSlash(p: []const u8) []const u8 {
    if (p.len > 1 and p[p.len - 1] == '/') return p[0 .. p.len - 1];
    return p;
}

fn parseQuery(arena: std.mem.Allocator, raw: []const u8) ![]const QueryPair {
    if (raw.len == 0) return &.{};

    var list: std.ArrayList(QueryPair) = .empty;
    var it = std.mem.tokenizeScalar(u8, raw, '&');
    while (it.next()) |segment| {
        const eq = std.mem.indexOfScalar(u8, segment, '=');
        const key_raw = if (eq) |i| segment[0..i] else segment;
        const val_raw = if (eq) |i| segment[i + 1 ..] else "";
        const key = try percentDecode(arena, key_raw);
        const val = try percentDecode(arena, val_raw);
        try list.append(arena, .{ .key = key, .value = val });
    }
    return list.toOwnedSlice(arena);
}

fn percentDecode(arena: std.mem.Allocator, input: []const u8) ![]const u8 {
    // Common case — no escapes — avoids the allocation entirely.
    if (std.mem.indexOfAny(u8, input, "%+") == null) return input;

    var out = try arena.alloc(u8, input.len);
    var w: usize = 0;
    var r: usize = 0;
    while (r < input.len) {
        const c = input[r];
        if (c == '+') {
            out[w] = ' ';
            r += 1;
            w += 1;
        } else if (c == '%' and r + 2 < input.len) {
            const byte = std.fmt.parseInt(u8, input[r + 1 .. r + 3], 16) catch {
                out[w] = c;
                r += 1;
                w += 1;
                continue;
            };
            out[w] = byte;
            r += 3;
            w += 1;
        } else {
            out[w] = c;
            r += 1;
            w += 1;
        }
    }
    return out[0..w];
}

test "Location.parse splits path, query, fragment" {
    const loc = Location.parse("/work/hello?a=1&b=2#frag");
    try std.testing.expectEqualStrings("/work/hello", loc.path);
    try std.testing.expectEqualStrings("a=1&b=2", loc.raw_query);
    try std.testing.expectEqualStrings("frag", loc.fragment.?);
}

test "Location.parse handles bare path" {
    const loc = Location.parse("/");
    try std.testing.expectEqualStrings("/", loc.path);
    try std.testing.expectEqualStrings("", loc.raw_query);
    try std.testing.expect(loc.fragment == null);
}

test "Location.query decodes percent and plus" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var loc = Location.parse("/x?name=alice+bob&path=%2Fwork%2F%E2%9C%93");
    const pairs = try loc.query(arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), pairs.len);
    try std.testing.expectEqualStrings("name", pairs[0].key);
    try std.testing.expectEqualStrings("alice bob", pairs[0].value);
    try std.testing.expectEqualStrings("path", pairs[1].key);
    try std.testing.expectEqualStrings("/work/\u{2713}", pairs[1].value);
}

test "Location.query handles empty values and repeated keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var loc = Location.parse("/x?a&b=&c=1&c=2");
    const pairs = try loc.query(arena.allocator());
    try std.testing.expectEqual(@as(usize, 4), pairs.len);
    try std.testing.expectEqualStrings("a", pairs[0].key);
    try std.testing.expectEqualStrings("", pairs[0].value);
    try std.testing.expectEqualStrings("b", pairs[1].key);
    try std.testing.expectEqualStrings("", pairs[1].value);
    try std.testing.expectEqualStrings("c", pairs[2].key);
    try std.testing.expectEqualStrings("1", pairs[2].value);
    try std.testing.expectEqualStrings("2", pairs[3].value);
}

test "Location.isActive matches trailing-slash normalized" {
    const loc = Location.parse("/work/");
    try std.testing.expect(loc.isActive("/work"));
    try std.testing.expect(loc.isActive("/work/"));
    try std.testing.expect(!loc.isActive("/wor"));
}

test "Location.isActivePrefix" {
    const loc = Location.parse("/work/abc");
    try std.testing.expect(loc.isActivePrefix("/work"));
    try std.testing.expect(!loc.isActivePrefix("/wo"));
    try std.testing.expect(!loc.isActivePrefix("/"));

    const root = Location.parse("/");
    try std.testing.expect(root.isActivePrefix("/"));
    try std.testing.expect(!root.isActivePrefix("/work"));
}
