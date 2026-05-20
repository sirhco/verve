//! mtime-aware LRU for `--public-dir` static asset reads. Caches the
//! file bytes + content-type + an ETag derived from inode/mtime/size so
//! repeat hits skip both the `open` and the `read` syscalls. On every
//! hit the file is `stat`-ed cheaply; if mtime / size changed the entry
//! is evicted and refilled.
//!
//! Thread-safety: a single mutex guards the whole map. The expected
//! traffic pattern (a few dozen hot files, many concurrent reads) is
//! cheap enough that lock contention isn't measurable; if it ever
//! becomes a problem a per-shard mutex is the obvious upgrade.

const std = @import("std");

pub const Stat = struct {
    mtime_ns: i128,
    size: u64,
    inode: u64,
};

pub const Entry = struct {
    path: []u8,
    bytes: []u8,
    content_type: []const u8,
    stat: Stat,
    etag: [16]u8,
    /// LRU bookkeeping — index of the prev/next entry in the doubly-
    /// linked list, or `tombstone` for unlinked.
    prev: u32,
    next: u32,
};

const tombstone: u32 = std.math.maxInt(u32);

pub const Config = struct {
    max_entries: u32 = 256,
    max_bytes: usize = 32 * 1024 * 1024,
    /// Skip caching files larger than this — they'd evict the whole
    /// cache for one request. Defaults to a quarter of `max_bytes`.
    per_file_cap: usize = 8 * 1024 * 1024,
};

pub const Cache = struct {
    gpa: std.mem.Allocator,
    cfg: Config,
    mu: std.atomic.Mutex = .unlocked,
    /// Path → index into `entries`. The map keys reference `entries[i].path`,
    /// so the cache owns its key memory and rehashes are cheap.
    map: std.StringHashMapUnmanaged(u32) = .empty,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    free_list: std.ArrayListUnmanaged(u32) = .empty,
    head: u32 = tombstone,
    tail: u32 = tombstone,
    bytes_in_cache: usize = 0,

    pub fn init(gpa: std.mem.Allocator, cfg: Config) Cache {
        return .{ .gpa = gpa, .cfg = cfg };
    }

    pub fn deinit(self: *Cache) void {
        for (self.entries.items) |*e| self.freeEntry(e);
        self.entries.deinit(self.gpa);
        self.free_list.deinit(self.gpa);
        self.map.deinit(self.gpa);
    }

    fn freeEntry(self: *Cache, e: *Entry) void {
        if (e.path.len > 0) self.gpa.free(e.path);
        if (e.bytes.len > 0) self.gpa.free(e.bytes);
        e.path = &.{};
        e.bytes = &.{};
    }

    fn lock(self: *Cache) void {
        while (!self.mu.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Cache) void {
        self.mu.unlock();
    }

    /// Result of a get(). `Hit` carries cached bytes that the caller can
    /// stream to the response; `Miss` carries the fresh stat the caller
    /// should use to read the file off disk and pass back to `put()`.
    pub const Get = union(enum) {
        hit: struct {
            bytes: []const u8,
            content_type: []const u8,
            etag: []const u8,
        },
        miss: void,
    };

    /// Look up `path`. If a cached entry exists and the on-disk stat
    /// matches, returns a Hit; otherwise evicts the stale entry and
    /// returns Miss.
    pub fn get(self: *Cache, path: []const u8, stat: Stat) Get {
        self.lock();
        defer self.unlock();
        const idx_opt = self.map.get(path);
        if (idx_opt) |idx| {
            const e = &self.entries.items[idx];
            if (e.stat.mtime_ns == stat.mtime_ns and e.stat.size == stat.size and e.stat.inode == stat.inode) {
                self.moveToFront(idx);
                return .{ .hit = .{
                    .bytes = e.bytes,
                    .content_type = e.content_type,
                    .etag = &e.etag,
                } };
            }
            self.evictAt(idx);
        }
        return .miss;
    }

    /// Insert (or refresh) an entry. Caller has already read `bytes` from
    /// disk and computed the content type. Caller hands ownership of the
    /// allocated slice; the cache will free it on eviction.
    pub fn put(
        self: *Cache,
        path: []const u8,
        bytes: []u8,
        content_type: []const u8,
        stat: Stat,
    ) !void {
        if (bytes.len > self.cfg.per_file_cap) {
            self.gpa.free(bytes);
            return;
        }
        self.lock();
        defer self.unlock();

        // Evict until the new entry fits.
        while (self.bytes_in_cache + bytes.len > self.cfg.max_bytes and self.tail != tombstone) {
            self.evictAt(self.tail);
        }
        while (self.entries.items.len - self.free_list.items.len >= self.cfg.max_entries and self.tail != tombstone) {
            self.evictAt(self.tail);
        }

        const path_copy = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(path_copy);

        const etag = computeEtag(stat);

        const slot = blk: {
            if (self.free_list.pop()) |i| break :blk i;
            const idx: u32 = @intCast(self.entries.items.len);
            try self.entries.append(self.gpa, undefined);
            break :blk idx;
        };
        const e = &self.entries.items[slot];
        e.* = .{
            .path = path_copy,
            .bytes = bytes,
            .content_type = content_type,
            .stat = stat,
            .etag = etag,
            .prev = tombstone,
            .next = tombstone,
        };
        try self.map.put(self.gpa, e.path, slot);
        self.bytes_in_cache += bytes.len;
        self.linkFront(slot);
    }

    fn evictAt(self: *Cache, idx: u32) void {
        const e = &self.entries.items[idx];
        self.unlink(idx);
        self.bytes_in_cache -= e.bytes.len;
        _ = self.map.remove(e.path);
        self.freeEntry(e);
        self.free_list.append(self.gpa, idx) catch {};
    }

    fn linkFront(self: *Cache, idx: u32) void {
        const e = &self.entries.items[idx];
        e.prev = tombstone;
        e.next = self.head;
        if (self.head != tombstone) self.entries.items[self.head].prev = idx;
        self.head = idx;
        if (self.tail == tombstone) self.tail = idx;
    }

    fn unlink(self: *Cache, idx: u32) void {
        const e = &self.entries.items[idx];
        if (e.prev != tombstone) self.entries.items[e.prev].next = e.next;
        if (e.next != tombstone) self.entries.items[e.next].prev = e.prev;
        if (self.head == idx) self.head = e.next;
        if (self.tail == idx) self.tail = e.prev;
        e.prev = tombstone;
        e.next = tombstone;
    }

    fn moveToFront(self: *Cache, idx: u32) void {
        if (self.head == idx) return;
        self.unlink(idx);
        self.linkFront(idx);
    }
};

/// Hex-format `inode:mtime:size` into a 16-byte buffer for use as an
/// ETag header. Stable across processes for unchanged files, changes
/// on any of size / mtime / inode (atomic-write replace).
fn computeEtag(stat: Stat) [16]u8 {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // 8 hex chars of mtime-low + 4 of size + 4 of inode-low. Truncation
    // is fine — the ETag is opportunistic, not authoritative.
    const mtime_low: u32 = @truncate(@as(u128, @bitCast(stat.mtime_ns)));
    const size_low: u16 = @truncate(stat.size);
    const inode_low: u16 = @truncate(stat.inode);
    _ = w.print("{x:0>8}{x:0>4}{x:0>4}", .{ mtime_low, size_low, inode_low }) catch {};
    return buf;
}

// ---- tests ------------------------------------------------------------

test "Cache get returns miss when empty" {
    var cache = Cache.init(std.testing.allocator, .{});
    defer cache.deinit();
    const result = cache.get("a.css", .{ .mtime_ns = 0, .size = 0, .inode = 0 });
    try std.testing.expect(result == .miss);
}

test "Cache put then get returns hit" {
    var cache = Cache.init(std.testing.allocator, .{});
    defer cache.deinit();

    const bytes = try std.testing.allocator.dupe(u8, "body { color: red; }");
    const stat: Stat = .{ .mtime_ns = 1000, .size = bytes.len, .inode = 42 };
    try cache.put("style.css", bytes, "text/css", stat);

    const result = cache.get("style.css", stat);
    try std.testing.expect(result == .hit);
    try std.testing.expectEqualStrings("body { color: red; }", result.hit.bytes);
    try std.testing.expectEqualStrings("text/css", result.hit.content_type);
}

test "Cache get returns miss when mtime differs" {
    var cache = Cache.init(std.testing.allocator, .{});
    defer cache.deinit();

    const bytes = try std.testing.allocator.dupe(u8, "x");
    try cache.put("a", bytes, "text/plain", .{ .mtime_ns = 1, .size = 1, .inode = 1 });

    const result = cache.get("a", .{ .mtime_ns = 2, .size = 1, .inode = 1 });
    try std.testing.expect(result == .miss);
    // Stale entry should have been evicted.
    const result2 = cache.get("a", .{ .mtime_ns = 1, .size = 1, .inode = 1 });
    try std.testing.expect(result2 == .miss);
}

test "Cache evicts LRU when over byte budget" {
    var cache = Cache.init(std.testing.allocator, .{ .max_bytes = 16, .per_file_cap = 16 });
    defer cache.deinit();

    const b1 = try std.testing.allocator.dupe(u8, "1234567890");
    try cache.put("a", b1, "text/plain", .{ .mtime_ns = 1, .size = 10, .inode = 1 });
    const b2 = try std.testing.allocator.dupe(u8, "abcdefghij");
    try cache.put("b", b2, "text/plain", .{ .mtime_ns = 2, .size = 10, .inode = 2 });

    // `a` should be evicted (oldest) — only `b` survives.
    try std.testing.expect(cache.get("a", .{ .mtime_ns = 1, .size = 10, .inode = 1 }) == .miss);
    try std.testing.expect(cache.get("b", .{ .mtime_ns = 2, .size = 10, .inode = 2 }) == .hit);
}
