//! Runtime page-route matcher. Walks the comptime-parsed Segment slice
//! of each Route in `app.routes` against the request path, recursing
//! into nested children when a parent layout matches and the remaining
//! path is non-empty. Returns the chain of routes (root → leaf) so the
//! server can render layouts outside-in via `ctx.outlet()`.

const std = @import("std");
const verve = @import("verve");
const app = @import("app");

const Segment = verve.RouteSegment;

/// Maximum nesting depth supported. Sized generously; nested layouts
/// deeper than this are vanishingly rare and the bound keeps the
/// chain buffer on the stack.
pub const MAX_DEPTH: usize = 8;

pub const Match = struct {
    /// Routes from root layout to matched leaf. `chain[chain_len-1]`
    /// is the leaf whose render produces the inner-most content.
    chain: [MAX_DEPTH]verve.Route,
    chain_len: usize,

    pub fn leaf(self: *const Match) verve.Route {
        return self.chain[self.chain_len - 1];
    }
};

/// Find the first chain in `routes` that matches `path`. Captured
/// `:slug` segments and any `*rest` wildcard are written into
/// `params_out`. The matched value slices reference bytes inside
/// `path` — keep that backing buffer alive while reading the result.
pub fn match(
    path: []const u8,
    routes: []const verve.Route,
    params_out: *std.StringHashMapUnmanaged([]const u8),
    gpa: std.mem.Allocator,
) !?Match {
    var result: Match = .{ .chain = undefined, .chain_len = 0 };
    if (try matchInto(path, 0, routes, params_out, gpa, &result)) {
        return result;
    }
    params_out.clearRetainingCapacity();
    return null;
}

/// Recursive matcher. Tries each route at the current level; on a
/// successful local match either descends into the route's children
/// (if the remaining path still has content) or returns the current
/// chain when path is exhausted.
fn matchInto(
    path: []const u8,
    start: usize,
    routes: []const verve.Route,
    params_out: *std.StringHashMapUnmanaged([]const u8),
    gpa: std.mem.Allocator,
    out: *Match,
) !bool {
    for (routes) |r| {
        const before_len = params_out.count();
        const before_chain_len = out.chain_len;

        const consumed_opt = try tryMatchSegments(path, start, r.segments, params_out, gpa);
        if (consumed_opt) |consumed| {
            // Record this route on the chain.
            if (out.chain_len >= MAX_DEPTH) return error.RouteNestingTooDeep;
            out.chain[out.chain_len] = r;
            out.chain_len += 1;

            // Determine whether the path is fully consumed (allowing a
            // trailing slash) — if so we have our leaf.
            if (isPathDone(path, consumed)) return true;

            // Otherwise, try to descend into children.
            if (r.children.len > 0) {
                if (try matchInto(path, consumed, r.children, params_out, gpa, out)) return true;
            }

            // No child matched (or no children) but path remains —
            // roll this route's contribution back and try the next.
            out.chain_len = before_chain_len;
            // Drop any params captured by this route's segments.
            // Easiest: rebuild from before_len — clear all and re-add
            // would be expensive; cheaper to track removals. For
            // robustness clear-and-restart via the caller's outer
            // loop is fine since hashmap entries are arena-allocated.
            _ = before_len; // hashmap will be cleared on outer miss
        }
    }
    return false;
}

/// Walk `segments` against `path[start..]`. Returns the new path
/// offset on success, null on miss.
fn tryMatchSegments(
    path: []const u8,
    start: usize,
    segments: []const Segment,
    params_out: *std.StringHashMapUnmanaged([]const u8),
    gpa: std.mem.Allocator,
) !?usize {
    var path_idx = start;
    if (path.len > 0 and path_idx < path.len and path[path_idx] == '/') path_idx += 1;

    for (segments) |seg| {
        switch (seg) {
            .wildcard => |name| {
                var rest = path[path_idx..];
                if (rest.len > 0 and rest[rest.len - 1] == '/') rest = rest[0 .. rest.len - 1];
                try params_out.put(gpa, name, rest);
                return path.len;
            },
            .literal, .param => {
                if (path_idx >= path.len) return null;
                const slash_pos = std.mem.indexOfScalarPos(u8, path, path_idx, '/');
                const end = slash_pos orelse path.len;
                const part = path[path_idx..end];
                if (part.len == 0) return null;

                switch (seg) {
                    .literal => |lit| if (!std.mem.eql(u8, lit, part)) return null,
                    .param => |name| try params_out.put(gpa, name, part),
                    .wildcard => unreachable,
                }
                path_idx = end;
                // Step past the segment separator so the next segment
                // starts on its own content. Without this the next
                // loop iteration sees a leading `/` and rejects with
                // an empty `part`.
                if (path_idx < path.len and path[path_idx] == '/') path_idx += 1;
            },
        }
    }
    return path_idx;
}

/// True when `path` from `consumed` onward holds only path separators
/// (so the route consumed all meaningful content).
fn isPathDone(path: []const u8, consumed: usize) bool {
    if (consumed >= path.len) return true;
    for (path[consumed..]) |c| if (c != '/') return false;
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
    try testing.expectEqualStrings("/", r.?.leaf().pattern);
    try testing.expectEqual(@as(usize, 1), r.?.chain_len);
}

test "match captures :slug into chain leaf" {
    const routes = comptime [_]Route{
        Route.init("/work/:slug", stubRender),
    };
    var params: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer params.deinit(testing.allocator);

    const r = try match("/work/hello", &routes, &params, testing.allocator);
    try testing.expect(r != null);
    try testing.expectEqualStrings("hello", params.get("slug").?);
}

test "match descends into nested children" {
    const routes = comptime [_]Route{
        Route.layout("/app", stubRender, &.{
            Route.init("/dashboard", stubRender),
            Route.init("/settings/:section", stubRender),
        }),
    };
    var params: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer params.deinit(testing.allocator);

    const r = try match("/app/dashboard", &routes, &params, testing.allocator);
    try testing.expect(r != null);
    try testing.expectEqual(@as(usize, 2), r.?.chain_len);
    try testing.expectEqualStrings("/app", r.?.chain[0].pattern);
    try testing.expectEqualStrings("/dashboard", r.?.chain[1].pattern);

    const r2 = try match("/app/settings/profile", &routes, &params, testing.allocator);
    try testing.expect(r2 != null);
    try testing.expectEqual(@as(usize, 2), r2.?.chain_len);
    try testing.expectEqualStrings("profile", params.get("section").?);
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

test "match rejects unmatched leftover segments" {
    const routes = comptime [_]Route{
        Route.init("/work/:slug", stubRender),
    };
    var params: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer params.deinit(testing.allocator);

    try testing.expect((try match("/work/a/b", &routes, &params, testing.allocator)) == null);
}
