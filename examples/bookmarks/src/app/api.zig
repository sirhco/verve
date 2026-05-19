//! Bookmarks — a starred-links list with URL validation.
//!
//! Demonstrates richer action input (two string fields), per-field
//! validation with custom error returns, atomic counters for /metrics
//! observability, and a mixed page surface (form + list + filter).

const std = @import("std");

pub const components = @import("components.zig");
pub const routes_mod = @import("routes.zig");
pub const Route = routes_mod.Route;
pub const routes = routes_mod.routes;

const log = std.log.scoped(.verve);

pub var last_count: std.atomic.Value(i32) = .init(0);

const MAX_LINKS: usize = 128;
const TITLE_MAX: usize = 120;
const URL_MAX: usize = 500;

pub const Bookmark = struct {
    title: [TITLE_MAX]u8 = undefined,
    title_len: usize = 0,
    url: [URL_MAX]u8 = undefined,
    url_len: usize = 0,
    visits: std.atomic.Value(u64) = .init(0),

    pub fn titleSlice(self: *const Bookmark) []const u8 {
        return self.title[0..self.title_len];
    }
    pub fn urlSlice(self: *const Bookmark) []const u8 {
        return self.url[0..self.url_len];
    }
};

var slots: [MAX_LINKS]Bookmark = .{Bookmark{}} ** MAX_LINKS;
var count: usize = 0;
var mu: std.atomic.Mutex = .unlocked;

fn lock() void {
    while (!mu.tryLock()) std.atomic.spinLoopHint();
}

pub const SnapshotEntry = struct {
    title: []const u8,
    url: []const u8,
    visits: u64,
    index: usize,
};

/// Snapshot — copies title/url into the arena so the renderer can
/// dangle pointers freely after the mutex is released.
pub fn snapshot(arena: std.mem.Allocator) ![]SnapshotEntry {
    lock();
    defer mu.unlock();
    const out = try arena.alloc(SnapshotEntry, count);
    for (0..count) |i| {
        out[i] = .{
            .title = try arena.dupe(u8, slots[i].titleSlice()),
            .url = try arena.dupe(u8, slots[i].urlSlice()),
            .visits = slots[i].visits.load(.monotonic),
            .index = i,
        };
    }
    return out;
}

/// Total number of bookmarks. Used by the metrics route.
pub fn totalBookmarks() usize {
    lock();
    defer mu.unlock();
    return count;
}

/// Sum of visit counters. Demonstrates that arbitrary state can be
/// surfaced through actions and rendered alongside framework metrics.
pub fn totalVisits() u64 {
    lock();
    defer mu.unlock();
    var n: u64 = 0;
    for (slots[0..count]) |b| n += b.visits.load(.monotonic);
    return n;
}

pub const Actions = struct {
    pub fn addBookmark(args: struct { title: []const u8, url: []const u8 }) !void {
        const title = std.mem.trim(u8, args.title, &std.ascii.whitespace);
        const url = std.mem.trim(u8, args.url, &std.ascii.whitespace);
        if (title.len == 0) return error.MissingTitle;
        if (url.len == 0) return error.MissingUrl;
        if (!isHttpUrl(url)) return error.InvalidScheme;

        lock();
        defer mu.unlock();
        if (count >= MAX_LINKS) return error.Full;

        const b = &slots[count];
        const tl = @min(title.len, TITLE_MAX);
        @memcpy(b.title[0..tl], title[0..tl]);
        b.title_len = tl;
        const ul = @min(url.len, URL_MAX);
        @memcpy(b.url[0..ul], url[0..ul]);
        b.url_len = ul;
        b.visits = .init(0);
        count += 1;
        _ = last_count.fetchAdd(1, .monotonic);
        log.info("bookmark added: {s} -> {s}", .{ title[0..tl], url[0..ul] });
    }

    pub fn removeBookmark(args: struct { index: usize }) !void {
        lock();
        defer mu.unlock();
        if (args.index >= count) return error.OutOfRange;
        var i = args.index;
        while (i + 1 < count) : (i += 1) {
            slots[i] = slots[i + 1];
        }
        count -= 1;
        _ = last_count.fetchAdd(1, .monotonic);
        log.info("bookmark removed: index={d}", .{args.index});
    }

    pub fn recordVisit(args: struct { index: usize }) !void {
        lock();
        defer mu.unlock();
        if (args.index >= count) return error.OutOfRange;
        _ = slots[args.index].visits.fetchAdd(1, .monotonic);
        log.info("bookmark visited: index={d}", .{args.index});
    }
};

/// Cheap URL validation: must start with http:// or https://. Keeps
/// the action surface honest without pulling in a full URL parser.
fn isHttpUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://");
}
