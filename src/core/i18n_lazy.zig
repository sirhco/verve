//! Opt-in lazy i18n catalog. Each locale ships as a separate raw-JSON blob
//! (`{ "key": "value", … }`); the active locale (and the default, for fallback)
//! is parsed + cached on first lookup. Single-binary preserved — the build
//! `@embedFile`s each blob. The comptime `Catalog` in `i18n.zig` stays for
//! small sets (zero runtime cost); this is for large multi-locale sets.

const std = @import("std");

/// A locale's tag paired with its raw JSON `{ "key": "value", … }` bytes.
/// Produced by the build walker, or supplied inline (tests).
pub const Locale = struct { tag: []const u8, json: []const u8 };

pub const LazyCatalog = struct {
    locales: []const Locale,
    default_locale: []const u8,
    gpa: std.mem.Allocator,
    /// tag -> parsed object (process-lifetime). A `null` value marks a tag
    /// whose blob is unknown / failed to parse / isn't an object, so it isn't
    /// retried. Back `gpa` with a process-lifetime or arena allocator —
    /// parsed data is never individually freed.
    cache: std.StringHashMapUnmanaged(?std.json.Value) = .{},
    // Zig 0.16's std.Thread has no Mutex; the codebase uses std.atomic.Mutex
    // (spin via tryLock), same as `src/app/api.zig` / `src/server/main.zig`.
    mutex: std.atomic.Mutex = .unlocked,

    pub fn init(locales: []const Locale, default_locale: []const u8, gpa: std.mem.Allocator) LazyCatalog {
        return .{ .locales = locales, .default_locale = default_locale, .gpa = gpa };
    }

    /// True when `locale` has a blob in the manifest. No parse — scans tags.
    pub fn isSupported(self: *const LazyCatalog, locale: []const u8) bool {
        for (self.locales) |l| if (std.mem.eql(u8, l.tag, locale)) return true;
        return false;
    }

    /// Look up `key` in `locale`, falling back to the default locale, then to
    /// `key` itself. Lazily parses + caches `locale` (and, on a miss, the
    /// default) on first use. The returned slice points into process-lifetime
    /// parsed data — safe to hold without copying.
    pub fn lookup(self: *LazyCatalog, locale: []const u8, key: []const u8) []const u8 {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        if (self.value(locale, key)) |v| return v;
        if (!std.mem.eql(u8, locale, self.default_locale)) {
            if (self.value(self.default_locale, key)) |v| return v;
        }
        return key;
    }

    // Caller holds the mutex.
    fn value(self: *LazyCatalog, tag: []const u8, key: []const u8) ?[]const u8 {
        const obj = self.ensure(tag) orelse return null;
        const v = obj.object.get(key) orelse return null;
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }

    // Caller holds the mutex. Returns the cached parsed object for `tag`,
    // parsing its blob on first request. Returns null when the tag is unknown
    // or its blob isn't a JSON object (and caches that null).
    fn ensure(self: *LazyCatalog, tag: []const u8) ?std.json.Value {
        if (self.cache.get(tag)) |cached| return cached;
        var parsed: ?std.json.Value = null;
        for (self.locales) |l| {
            if (std.mem.eql(u8, l.tag, tag)) {
                if (std.json.parseFromSliceLeaky(std.json.Value, self.gpa, l.json, .{})) |val| {
                    if (val == .object) parsed = val;
                } else |_| {}
                break;
            }
        }
        // Own the cache key: callers may pass a request-scoped (arena) locale
        // slice (resolveLocale returns cookie/query/Accept-Language values), so
        // dupe into the process-lifetime allocator before storing — otherwise
        // the stored key dangles once the request arena is freed and the next
        // lookup's key comparison reads freed memory.
        const key_owned = self.gpa.dupe(u8, tag) catch return parsed;
        self.cache.put(self.gpa, key_owned, parsed) catch {};
        return parsed;
    }
};

// ---- tests ---------------------------------------------------------------

const testing = std.testing;

const fixture = [_]Locale{
    .{ .tag = "en", .json = "{\"greeting\":\"Hello\",\"bye\":\"Goodbye\"}" },
    .{ .tag = "fr", .json = "{\"greeting\":\"Bonjour\"}" },
    .{ .tag = "broken", .json = "{ not json" },
};

test "lookup returns the locale value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cat = LazyCatalog.init(&fixture, "en", arena.allocator());
    try testing.expectEqualStrings("Bonjour", cat.lookup("fr", "greeting"));
}

test "lookup falls back to the default locale then the key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cat = LazyCatalog.init(&fixture, "en", arena.allocator());
    // "bye" missing in fr → default (en) → "Goodbye".
    try testing.expectEqualStrings("Goodbye", cat.lookup("fr", "bye"));
    // missing everywhere → the key itself.
    try testing.expectEqualStrings("nope", cat.lookup("fr", "nope"));
}

test "locales are parsed lazily and cached once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cat = LazyCatalog.init(&fixture, "en", arena.allocator());
    try testing.expectEqual(@as(usize, 0), cat.cache.count()); // nothing parsed yet

    _ = cat.lookup("fr", "greeting"); // hits in fr, present → default NOT loaded
    try testing.expectEqual(@as(usize, 1), cat.cache.count());
    try testing.expect(cat.cache.contains("fr"));

    _ = cat.lookup("fr", "greeting"); // second lookup: no new parse
    try testing.expectEqual(@as(usize, 1), cat.cache.count());

    _ = cat.lookup("fr", "bye"); // misses fr → loads default (en)
    try testing.expectEqual(@as(usize, 2), cat.cache.count());
}

test "malformed or non-object blob contributes nothing and is cached" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cat = LazyCatalog.init(&fixture, "en", arena.allocator());
    // "broken" doesn't parse → falls back to default (en) for a key en has.
    try testing.expectEqualStrings("Hello", cat.lookup("broken", "greeting"));
    try testing.expect(cat.cache.contains("broken"));
    try testing.expectEqual(@as(?std.json.Value, null), cat.cache.get("broken").?);
}

test "isSupported reflects manifest tags without parsing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cat = LazyCatalog.init(&fixture, "en", arena.allocator());
    try testing.expect(cat.isSupported("fr"));
    try testing.expect(!cat.isSupported("de"));
    try testing.expectEqual(@as(usize, 0), cat.cache.count()); // no parse triggered
}

test "cache key survives a freed caller locale slice" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cat = LazyCatalog.init(&fixture, "en", arena.allocator());

    // The caller passes a locale slice from a separate, short-lived arena —
    // mirrors resolveLocale returning a request-scoped cookie/query value.
    var req = std.heap.ArenaAllocator.init(testing.allocator);
    const loc1 = try req.allocator().dupe(u8, "fr");
    _ = cat.lookup(loc1, "greeting"); // caches "fr" — the key must be owned
    req.deinit(); // free the caller's slice

    // A later lookup whose key compares against the cached key. If the cache
    // stored the freed `loc1` pointer, this comparison reads freed memory.
    try testing.expectEqualStrings("Bonjour", cat.lookup("fr", "greeting"));
}

test "concurrent lookups are race-free" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cat = LazyCatalog.init(&fixture, "en", arena.allocator());

    const Worker = struct {
        fn run(c: *LazyCatalog) void {
            var i: usize = 0;
            while (i < 200) : (i += 1) {
                std.debug.assert(std.mem.eql(u8, c.lookup("fr", "greeting"), "Bonjour"));
                std.debug.assert(std.mem.eql(u8, c.lookup("fr", "bye"), "Goodbye"));
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{&cat});
    for (threads) |t| t.join();
    try testing.expectEqualStrings("Bonjour", cat.lookup("fr", "greeting"));
}
