//! External API integrations for the dashboard demo.
//!
//! Fetches three live endpoints on a background thread and exposes the
//! latest snapshot via mutex-guarded module variables:
//!
//!   - https://api.chucknorris.io/jokes/random        (random joke)
//!   - https://api.websitecarbon.com/data?bytes=...   (CO2 estimate)
//!   - https://api.disneyapi.dev/character            (character list)
//!     plus per-character follow-ups for the first few items, demonstrating
//!     the "iterate then fan out to more URLs" pattern.
//!
//! Refresh cadence is 90 seconds. On startup the fetcher runs immediately
//! so the first page load sees something within ~2 seconds.

const std = @import("std");

// ============================================================================
// Snapshot types — fixed-size buffers, copied under `mu` so renders don't
// race the fetcher.
// ============================================================================

const VALUE_MAX = 512;
const URL_MAX = 256;
const ERR_MAX = 128;
const RATING_MAX = 4;
const NAME_MAX = 80;
pub const DISNEY_LIST_MAX = 24; // 4 pages of 6
pub const DISNEY_PAGE_SIZE = 6;
const DISNEY_FILMS_MAX = 4;
const FILM_NAME_MAX = 64;

pub const ChuckSnap = struct {
    value: [VALUE_MAX]u8 = undefined,
    value_len: u32 = 0,
    icon_url: [URL_MAX]u8 = undefined,
    icon_url_len: u32 = 0,
    err: [ERR_MAX]u8 = undefined,
    err_len: u32 = 0,
    fetched_unix: i64 = 0,
    latency_ms: u32 = 0,

    pub fn valueSlice(self: *const ChuckSnap) []const u8 {
        return self.value[0..self.value_len];
    }
    pub fn errSlice(self: *const ChuckSnap) []const u8 {
        return self.err[0..self.err_len];
    }
};

pub const CarbonSnap = struct {
    rating: [RATING_MAX]u8 = undefined,
    rating_len: u32 = 0,
    bytes: u64 = 0,
    green: bool = false,
    /// grams of CO2, ×1000 (millis).
    gco2e_milli: i64 = 0,
    /// % of pages cleaner than this one, scaled ×100.
    cleaner_centi: i32 = 0,
    /// energy in kWh, ×1e6 (micros).
    energy_micro: i64 = 0,
    err: [ERR_MAX]u8 = undefined,
    err_len: u32 = 0,
    fetched_unix: i64 = 0,
    latency_ms: u32 = 0,

    pub fn ratingSlice(self: *const CarbonSnap) []const u8 {
        return self.rating[0..self.rating_len];
    }
    pub fn errSlice(self: *const CarbonSnap) []const u8 {
        return self.err[0..self.err_len];
    }
};

pub const DisneyFilm = struct {
    name: [FILM_NAME_MAX]u8 = undefined,
    name_len: u32 = 0,
    pub fn slice(self: *const DisneyFilm) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const DisneyChar = struct {
    id: u32 = 0,
    name: [NAME_MAX]u8 = undefined,
    name_len: u32 = 0,
    image_url: [URL_MAX]u8 = undefined,
    image_url_len: u32 = 0,
    detail_url: [URL_MAX]u8 = undefined,
    detail_url_len: u32 = 0,
    detail_ok: bool = false,
    detail_latency_ms: u32 = 0,
    films_total: u32 = 0,
    films: [DISNEY_FILMS_MAX]DisneyFilm = @splat(.{}),
    films_shown: u32 = 0,

    pub fn nameSlice(self: *const DisneyChar) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn imageSlice(self: *const DisneyChar) []const u8 {
        return self.image_url[0..self.image_url_len];
    }
    pub fn detailSlice(self: *const DisneyChar) []const u8 {
        return self.detail_url[0..self.detail_url_len];
    }
};

pub const DisneySnap = struct {
    chars: [DISNEY_LIST_MAX]DisneyChar = @splat(.{}),
    char_count: u32 = 0,
    total_available: u32 = 0,
    err: [ERR_MAX]u8 = undefined,
    err_len: u32 = 0,
    fetched_unix: i64 = 0,
    list_latency_ms: u32 = 0,
    detail_latency_ms_total: u32 = 0,
    detail_fetched: u32 = 0,

    pub fn errSlice(self: *const DisneySnap) []const u8 {
        return self.err[0..self.err_len];
    }
};

pub const Snapshot = struct {
    chuck: ChuckSnap = .{},
    carbon: CarbonSnap = .{},
    disney: DisneySnap = .{},
    last_refresh_unix: i64 = 0,
    refresh_count: u32 = 0,
};

var current: Snapshot = .{};
var mu: std.atomic.Mutex = .unlocked;

fn lockSnap() void {
    while (!mu.tryLock()) std.atomic.spinLoopHint();
}

/// Copy the current snapshot for safe rendering. The caller owns the copy.
pub fn snapshot() Snapshot {
    lockSnap();
    defer mu.unlock();
    return current;
}

// ============================================================================
// Fetcher thread
// ============================================================================

var fetcher_started = std.atomic.Value(bool).init(false);
const REFRESH_INTERVAL = std.Io.Duration.fromMilliseconds(20_000);
const FIRST_RUN_DELAY = std.Io.Duration.fromMilliseconds(250);
const PER_CALL_TIMEOUT_MS: u32 = 10_000;

const log = std.log.scoped(.verve);

/// Called after each successful refresh so the framework SSE stream
/// can broadcast a fresh tick. External does NOT import api directly
/// to keep the dependency tree one-way; instead app code sets this
/// callback at startup (or via comptime ref) before any refresh.
pub var on_refresh: ?*const fn () void = null;

const FetcherCtx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
};

/// Idempotent: only the first caller starts the background thread.
/// Render functions only have `Io`; the fetcher allocates from the page
/// allocator so the framework doesn't need to thread gpa into Context.
pub fn ensureFetcher(io: std.Io) void {
    if (fetcher_started.swap(true, .acq_rel)) return;
    const gpa = std.heap.page_allocator;
    const ctx = gpa.create(FetcherCtx) catch {
        fetcher_started.store(false, .release);
        return;
    };
    ctx.* = .{ .gpa = gpa, .io = io };
    const t = std.Thread.spawn(.{}, fetcherLoop, .{ctx}) catch {
        gpa.destroy(ctx);
        fetcher_started.store(false, .release);
        return;
    };
    t.detach();
}

fn fetcherLoop(ctx: *FetcherCtx) void {
    defer ctx.gpa.destroy(ctx);
    log.info("external: fetcher thread started, refreshing every {d}s", .{
        @divTrunc(REFRESH_INTERVAL.nanoseconds, std.time.ns_per_s),
    });
    std.Io.sleep(ctx.io, FIRST_RUN_DELAY, .awake) catch return;
    while (true) {
        refreshAll(ctx.io, ctx.gpa) catch |err| {
            log.err("external: refresh failed: {s}", .{@errorName(err)});
        };
        std.Io.sleep(ctx.io, REFRESH_INTERVAL, .awake) catch return;
    }
}

fn refreshAll(io: std.Io, gpa: std.mem.Allocator) !void {
    var new_snap: Snapshot = blk: {
        lockSnap();
        defer mu.unlock();
        break :blk current;
    };

    new_snap.chuck = fetchChuck(io, gpa) catch |err| blk: {
        log.err("external: chuck error: {s}", .{@errorName(err)});
        break :blk chuckError(err);
    };
    new_snap.carbon = fetchCarbon(io, gpa) catch |err| blk: {
        log.err("external: carbon error: {s}", .{@errorName(err)});
        break :blk carbonError(err);
    };
    new_snap.disney = fetchDisney(io, gpa) catch |err| blk: {
        log.err("external: disney error: {s}", .{@errorName(err)});
        break :blk disneyError(err);
    };

    new_snap.last_refresh_unix = nowUnix(io);
    new_snap.refresh_count += 1;

    {
        lockSnap();
        defer mu.unlock();
        current = new_snap;
    }

    if (on_refresh) |cb| cb();
}

fn chuckError(err: anyerror) ChuckSnap {
    var s = ChuckSnap{};
    writeBuf(&s.err, &s.err_len, ERR_MAX, @errorName(err));
    return s;
}
fn carbonError(err: anyerror) CarbonSnap {
    var s = CarbonSnap{};
    writeBuf(&s.err, &s.err_len, ERR_MAX, @errorName(err));
    return s;
}
fn disneyError(err: anyerror) DisneySnap {
    var s = DisneySnap{};
    writeBuf(&s.err, &s.err_len, ERR_MAX, @errorName(err));
    return s;
}

// ============================================================================
// HTTP helpers
// ============================================================================

const FetchResult = struct {
    body: []u8,
    latency_ms: u32,
};

fn httpGet(io: std.Io, gpa: std.mem.Allocator, url: []const u8, _: usize) !FetchResult {
    const t0 = std.Io.Clock.now(.awake, io);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &aw.writer,
    });

    if (result.status != .ok) return error.HttpNotOk;

    const body = try gpa.dupe(u8, aw.written());

    const t1 = std.Io.Clock.now(.awake, io);
    const ns = t0.durationTo(t1).nanoseconds;
    const ms: u32 = @intCast(@max(@divTrunc(ns, std.time.ns_per_ms), 0));

    return .{ .body = body, .latency_ms = ms };
}

fn nowUnix(io: std.Io) i64 {
    const now = std.Io.Clock.now(.real, io);
    return now.toSeconds();
}

fn writeBuf(buf: anytype, len: *u32, comptime max: usize, src: []const u8) void {
    const n = @min(src.len, max);
    @memcpy(buf[0..n], src[0..n]);
    len.* = @intCast(n);
}

// ============================================================================
// Chuck Norris API
// ============================================================================

const ChuckResp = struct {
    value: []const u8,
    icon_url: []const u8 = "",
};

pub fn fetchChuck(io: std.Io, gpa: std.mem.Allocator) !ChuckSnap {
    const r = try httpGet(io, gpa, "https://api.chucknorris.io/jokes/random", 32 * 1024);
    defer gpa.free(r.body);

    const parsed = std.json.parseFromSlice(ChuckResp, gpa, r.body, .{ .ignore_unknown_fields = true }) catch |err| return err;
    defer parsed.deinit();

    var snap: ChuckSnap = .{};
    writeBuf(&snap.value, &snap.value_len, VALUE_MAX, parsed.value.value);
    writeBuf(&snap.icon_url, &snap.icon_url_len, URL_MAX, parsed.value.icon_url);
    snap.fetched_unix = nowUnix(io);
    snap.latency_ms = r.latency_ms;
    return snap;
}

// ============================================================================
// Website Carbon API
// ============================================================================

const CarbonGrid = struct {
    grams: f64 = 0,
    litres: f64 = 0,
};
const CarbonCo2 = struct {
    grid: CarbonGrid = .{},
    renewable: CarbonGrid = .{},
};
const CarbonStats = struct {
    adjustedBytes: f64 = 0,
    energy: f64 = 0,
    co2: CarbonCo2 = .{},
};
const CarbonResp = struct {
    bytes: u64 = 0,
    green: bool = false,
    gco2e: f64 = 0,
    rating: []const u8 = "",
    statistics: CarbonStats = .{},
    cleanerThan: f64 = 0,
};

pub fn fetchCarbon(io: std.Io, gpa: std.mem.Allocator) !CarbonSnap {
    const r = try httpGet(io, gpa, "https://api.websitecarbon.com/data?bytes=12345678&green=1", 32 * 1024);
    defer gpa.free(r.body);

    const parsed = std.json.parseFromSlice(CarbonResp, gpa, r.body, .{ .ignore_unknown_fields = true }) catch |err| return err;
    defer parsed.deinit();

    var snap: CarbonSnap = .{};
    writeBuf(&snap.rating, &snap.rating_len, RATING_MAX, parsed.value.rating);
    snap.bytes = parsed.value.bytes;
    snap.green = parsed.value.green;
    snap.gco2e_milli = @intFromFloat(parsed.value.gco2e * 1000.0);
    snap.cleaner_centi = @intFromFloat(parsed.value.cleanerThan * 10000.0);
    snap.energy_micro = @intFromFloat(parsed.value.statistics.energy * 1_000_000.0);
    snap.fetched_unix = nowUnix(io);
    snap.latency_ms = r.latency_ms;
    return snap;
}

// ============================================================================
// Disney API — list + per-character iteration
// ============================================================================

const DisneyInfo = struct {
    count: u32 = 0,
    totalPages: u32 = 0,
};

const DisneyListItem = struct {
    _id: u32 = 0,
    name: []const u8 = "",
    imageUrl: []const u8 = "",
    url: []const u8 = "",
    films: []const []const u8 = &.{},
};

const DisneyList = struct {
    info: DisneyInfo = .{},
    data: []DisneyListItem = &.{},
};

const DisneyDetailItem = struct {
    _id: u32 = 0,
    name: []const u8 = "",
    imageUrl: []const u8 = "",
    films: []const []const u8 = &.{},
    parkAttractions: []const []const u8 = &.{},
};

const DisneyDetail = struct {
    info: DisneyInfo = .{},
    data: DisneyDetailItem = .{},
};

pub fn fetchDisney(io: std.Io, gpa: std.mem.Allocator) !DisneySnap {
    var snap: DisneySnap = .{};

    // Step 1: walk up to 4 pages of the list endpoint until we hit our cap.
    // Page size 6 ⇒ 4 pages = 24 characters. The Disney API returns
    // ~50 characters per page so this stays well under one page in
    // practice, but the loop lets us tune cap independently of page size.
    var page: u32 = 1;
    var taken: u32 = 0;
    var total_list_ms: u32 = 0;
    while (page <= 4 and taken < DISNEY_LIST_MAX) : (page += 1) {
        const url = std.fmt.allocPrint(
            gpa,
            "https://api.disneyapi.dev/character?pageSize={d}&page={d}",
            .{ DISNEY_LIST_MAX, page },
        ) catch return error.OutOfMemory;
        defer gpa.free(url);

        const list_r = httpGet(io, gpa, url, 512 * 1024) catch |err| {
            if (page == 1) return err; // first page is required
            break; // subsequent pages best-effort
        };
        defer gpa.free(list_r.body);
        total_list_ms += list_r.latency_ms;

        const parsed = std.json.parseFromSlice(DisneyList, gpa, list_r.body, .{ .ignore_unknown_fields = true }) catch |err| {
            if (page == 1) return err;
            break;
        };
        defer parsed.deinit();

        if (page == 1) snap.total_available = parsed.value.info.count;

        for (parsed.value.data) |item| {
            if (taken >= DISNEY_LIST_MAX) break;
            if (item.imageUrl.len == 0 or item.name.len == 0) continue;
            var c: DisneyChar = .{};
            c.id = item._id;
            writeBuf(&c.name, &c.name_len, NAME_MAX, item.name);
            writeBuf(&c.image_url, &c.image_url_len, URL_MAX, item.imageUrl);
            writeBuf(&c.detail_url, &c.detail_url_len, URL_MAX, item.url);
            c.films_total = @intCast(item.films.len);
            snap.chars[taken] = c;
            taken += 1;
        }

        if (parsed.value.data.len == 0) break;
    }
    snap.char_count = taken;
    snap.list_latency_ms = total_list_ms;

    // Step 2: iterate. For each picked character, hit the per-character
    // detail URL to demonstrate the "fan out to per-item URLs" pattern.
    // Each detail fetch refines films list + records its own latency.
    // Capped at DISNEY_PAGE_SIZE so a 24-char pool doesn't take 14 seconds.
    const detail_cap: usize = @min(@as(usize, snap.char_count), @as(usize, DISNEY_PAGE_SIZE));
    var detail_total_ms: u32 = 0;
    var detail_ok_count: u32 = 0;
    for (snap.chars[0..detail_cap]) |*c| {
        const url = c.detailSlice();
        if (url.len == 0) continue;
        const dr = httpGet(io, gpa, url, 64 * 1024) catch continue;
        defer gpa.free(dr.body);

        c.detail_latency_ms = dr.latency_ms;
        detail_total_ms += dr.latency_ms;

        const dp = std.json.parseFromSlice(DisneyDetail, gpa, dr.body, .{ .ignore_unknown_fields = true }) catch continue;
        defer dp.deinit();

        c.films_total = @intCast(dp.value.data.films.len);
        var f: u32 = 0;
        for (dp.value.data.films) |film| {
            if (f >= DISNEY_FILMS_MAX) break;
            writeBuf(&c.films[f].name, &c.films[f].name_len, FILM_NAME_MAX, film);
            f += 1;
        }
        c.films_shown = f;
        c.detail_ok = true;
        detail_ok_count += 1;
    }
    snap.detail_latency_ms_total = detail_total_ms;
    snap.detail_fetched = detail_ok_count;
    snap.fetched_unix = nowUnix(io);
    return snap;
}
