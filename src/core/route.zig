//! Page-route declaration. `pattern` is a slash-delimited template with
//! three kinds of segments:
//!
//!   - Literal: `/work` matches only the exact text "work".
//!   - Parameter: `/work/:slug` binds the matched segment to ctx.params["slug"].
//!   - Wildcard: `/files/*rest` captures the remainder (greedy, must be last).
//!
//! Use `Route.init` at module scope so the parser runs at comptime and
//! the segment slice is embedded as static data. The runtime router
//! (src/server/router.zig) walks the segment list per request.

const std = @import("std");
const Context = @import("context.zig").Context;
const Node = @import("node.zig").Node;

pub const Segment = union(enum) {
    literal: []const u8,
    param: []const u8,
    wildcard: []const u8,
};

pub const RenderFn = *const fn (ctx: *Context) anyerror!*Node;

pub const Route = struct {
    pattern: []const u8,
    segments: []const Segment,
    render: RenderFn,

    /// Compile a route at comptime. The pattern is parsed once into the
    /// segment slice that the runtime matcher walks. Invalid patterns
    /// (`:` without a name, `*rest` followed by another segment) produce
    /// a comptime error.
    pub fn init(comptime pattern: []const u8, comptime render: RenderFn) Route {
        comptime {
            const segments = parsePattern(pattern);
            return .{
                .pattern = pattern,
                .segments = segments,
                .render = render,
            };
        }
    }
};

/// Comptime parse a `/foo/:bar/*rest` style pattern into a Segment slice.
/// Empty segments (consecutive slashes, trailing slash) are ignored so
/// `/foo/` and `/foo` produce the same routing tree.
pub fn parsePattern(comptime pattern: []const u8) []const Segment {
    comptime {
        if (pattern.len == 0 or pattern[0] != '/') {
            @compileError("route pattern must start with '/', got: " ++ pattern);
        }

        var segments: []const Segment = &[_]Segment{};
        var saw_wildcard = false;

        var i: usize = 1;
        while (i < pattern.len) {
            const start = i;
            while (i < pattern.len and pattern[i] != '/') : (i += 1) {}
            const part = pattern[start..i];
            if (part.len > 0) {
                if (saw_wildcard) {
                    @compileError("wildcard segment must be last, got pattern: " ++ pattern);
                }
                if (part[0] == ':') {
                    if (part.len == 1) {
                        @compileError("parameter segment missing name in: " ++ pattern);
                    }
                    segments = segments ++ &[_]Segment{.{ .param = part[1..] }};
                } else if (part[0] == '*') {
                    if (part.len == 1) {
                        @compileError("wildcard segment missing name in: " ++ pattern);
                    }
                    saw_wildcard = true;
                    segments = segments ++ &[_]Segment{.{ .wildcard = part[1..] }};
                } else {
                    segments = segments ++ &[_]Segment{.{ .literal = part }};
                }
            }
            i += 1;
        }

        return segments;
    }
}

test "parsePattern root" {
    const segs = comptime parsePattern("/");
    try std.testing.expectEqual(@as(usize, 0), segs.len);
}

test "parsePattern literal segments" {
    const segs = comptime parsePattern("/work/list");
    try std.testing.expectEqual(@as(usize, 2), segs.len);
    try std.testing.expect(segs[0] == .literal);
    try std.testing.expectEqualStrings("work", segs[0].literal);
    try std.testing.expectEqualStrings("list", segs[1].literal);
}

test "parsePattern param segment" {
    const segs = comptime parsePattern("/work/:slug");
    try std.testing.expectEqual(@as(usize, 2), segs.len);
    try std.testing.expect(segs[1] == .param);
    try std.testing.expectEqualStrings("slug", segs[1].param);
}

test "parsePattern wildcard segment" {
    const segs = comptime parsePattern("/files/*rest");
    try std.testing.expectEqual(@as(usize, 2), segs.len);
    try std.testing.expect(segs[1] == .wildcard);
    try std.testing.expectEqualStrings("rest", segs[1].wildcard);
}

test "parsePattern collapses double slashes" {
    const segs = comptime parsePattern("/work//list/");
    try std.testing.expectEqual(@as(usize, 2), segs.len);
    try std.testing.expectEqualStrings("work", segs[0].literal);
    try std.testing.expectEqualStrings("list", segs[1].literal);
}
