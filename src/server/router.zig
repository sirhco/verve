//! Runtime page-route matcher. Walks the comptime-parsed Segment slice of
//! each Route in `app.routes` against the request path; the first Route
//! whose segments all match wins. Parameter / wildcard captures are
//! recorded into the caller-provided StringHashMap, which lives in the
//! per-request arena.
//!
//! The matcher is linear over the route table (O(routes * segments)).
//! For the < ~20 routes typical of an SSR app this is faster than a trie
//! after pattern parsing is amortized at comptime. Phase 7 swaps in a
//! trie when nested layouts arrive.

const std = @import("std");
const verve = @import("verve");
const app = @import("app");

const Segment = verve.RouteSegment;

pub const Match = struct {
    route: verve.Route,
    params: std.StringHashMapUnmanaged([]const u8),
};

/// Find the first Route in `routes` matching `path`. Captured `:slug`
/// segments and any `*rest` wildcard are written into `params_out`. The
/// matched value slices reference bytes inside `path`; the caller must
/// keep that backing buffer alive for as long as `params_out` is read.
/// `params_out` is reset on each call (to avoid leaking captures from a
/// failed earlier attempt).
pub fn match(
    path: []const u8,
    routes: []const verve.Route,
    params_out: *std.StringHashMapUnmanaged([]const u8),
    gpa: std.mem.Allocator,
) !?verve.Route {
    for (routes) |r| {
        params_out.clearRetainingCapacity();
        if (try tryMatchSegments(path, r.segments, params_out, gpa)) return r;
    }
    params_out.clearRetainingCapacity();
    return null;
}

fn tryMatchSegments(
    path: []const u8,
    segments: []const Segment,
    params_out: *std.StringHashMapUnmanaged([]const u8),
    gpa: std.mem.Allocator,
) !bool {
    var path_idx: usize = 0;
    if (path.len > 0 and path[0] == '/') path_idx = 1;

    for (segments, 0..) |seg, seg_i| {
        switch (seg) {
            .wildcard => |name| {
                // Greedy: capture the remainder including embedded slashes.
                // Trims one trailing slash so /files/foo/ captures "foo".
                var rest = path[path_idx..];
                if (rest.len > 0 and rest[rest.len - 1] == '/') rest = rest[0 .. rest.len - 1];
                try params_out.put(gpa, name, rest);
                return true;
            },
            .literal, .param => {
                if (path_idx >= path.len) return false;
                const slash_pos = std.mem.indexOfScalarPos(u8, path, path_idx, '/');
                const end = slash_pos orelse path.len;
                const part = path[path_idx..end];
                if (part.len == 0) return false;

                switch (seg) {
                    .literal => |lit| if (!std.mem.eql(u8, lit, part)) return false,
                    .param => |name| try params_out.put(gpa, name, part),
                    .wildcard => unreachable,
                }

                path_idx = end;
                if (path_idx < path.len and path[path_idx] == '/') path_idx += 1;

                // If we just consumed the final segment but the path keeps
                // going, only succeed when the leftover is empty (trailing
                // slash).
                _ = seg_i;
            },
        }
    }

    // Remaining path must be empty (or a trailing slash that we already
    // consumed) for the match to succeed.
    if (path_idx < path.len) {
        const rem = path[path_idx..];
        for (rem) |c| if (c != '/') return false;
    }
    return true;
}

// ---- tests ------------------------------------------------------------

const testing = std.testing;
const Context = verve.Context;
const Node = verve.Node;
const Route = verve.Route;

fn stubRender(ctx: *Context) anyerror!*Node {
    _ = ctx;
    return error.NotImplemented;
}

test "match literal /" {
    const routes = comptime [_]Route{
        Route.init("/", stubRender),
    };
    var params: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer params.deinit(testing.allocator);

    const r = try match("/", &routes, &params, testing.allocator);
    try testing.expect(r != null);
    try testing.expectEqualStrings("/", r.?.pattern);
}

test "match literal segments" {
    const routes = comptime [_]Route{
        Route.init("/work/list", stubRender),
    };
    var params: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer params.deinit(testing.allocator);

    try testing.expect((try match("/work/list", &routes, &params, testing.allocator)) != null);
    try testing.expect((try match("/work/list/", &routes, &params, testing.allocator)) != null);
    try testing.expect((try match("/work/listy", &routes, &params, testing.allocator)) == null);
    try testing.expect((try match("/work", &routes, &params, testing.allocator)) == null);
}

test "match captures :slug" {
    const routes = comptime [_]Route{
        Route.init("/work/:slug", stubRender),
    };
    var params: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer params.deinit(testing.allocator);

    const r = try match("/work/hello-world", &routes, &params, testing.allocator);
    try testing.expect(r != null);
    try testing.expectEqualStrings("hello-world", params.get("slug").?);
}

test "match captures multi params" {
    const routes = comptime [_]Route{
        Route.init("/org/:org/repo/:repo", stubRender),
    };
    var params: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer params.deinit(testing.allocator);

    const r = try match("/org/anthropic/repo/claude", &routes, &params, testing.allocator);
    try testing.expect(r != null);
    try testing.expectEqualStrings("anthropic", params.get("org").?);
    try testing.expectEqualStrings("claude", params.get("repo").?);
}

test "match wildcard captures remainder" {
    const routes = comptime [_]Route{
        Route.init("/files/*rest", stubRender),
    };
    var params: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer params.deinit(testing.allocator);

    const r = try match("/files/a/b/c.txt", &routes, &params, testing.allocator);
    try testing.expect(r != null);
    try testing.expectEqualStrings("a/b/c.txt", params.get("rest").?);
}

test "match selects more specific route first" {
    const routes = comptime [_]Route{
        Route.init("/work/list", stubRender),
        Route.init("/work/:slug", stubRender),
    };
    var params: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer params.deinit(testing.allocator);

    const list_match = try match("/work/list", &routes, &params, testing.allocator);
    try testing.expectEqualStrings("/work/list", list_match.?.pattern);

    const slug_match = try match("/work/hello", &routes, &params, testing.allocator);
    try testing.expectEqualStrings("/work/:slug", slug_match.?.pattern);
    try testing.expectEqualStrings("hello", params.get("slug").?);
}

test "match rejects path too short for pattern" {
    const routes = comptime [_]Route{
        Route.init("/work/:slug", stubRender),
    };
    var params: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer params.deinit(testing.allocator);

    try testing.expect((try match("/work", &routes, &params, testing.allocator)) == null);
    try testing.expect((try match("/", &routes, &params, testing.allocator)) == null);
}

test "match rejects unmatched leftover segments" {
    const routes = comptime [_]Route{
        Route.init("/work/:slug", stubRender),
    };
    var params: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer params.deinit(testing.allocator);

    try testing.expect((try match("/work/a/b", &routes, &params, testing.allocator)) == null);
}
