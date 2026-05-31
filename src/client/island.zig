//! Phase 13 — island hydration dispatch.
//!
//! Server-rendered `<verve-island data-name="X" data-props="...">`
//! markers are dual-purpose: the inner HTML is already inert-correct
//! SSR (search engines see content with no JS), and Phase 12's
//! `data-vh` walker hydrates any reactive spans inside automatically.
//!
//! What this module adds is a per-island *custom* hydration callback —
//! the place where a component wires up effects that aren't expressible
//! as plain `bind()` reads. The bridge fires `verve_island_dispatch`
//! once per `<verve-island>` it encounters; the registry below routes
//! the call to the matching component's `hydrate` fn.
//!
//! Per-island WASM chunking (one .wasm per island, fetched on demand)
//! is intentionally deferred: today every island ships in the single
//! shared `client.wasm`. The dispatch entry is the load-bearing API
//! the chunked loader will reuse.

const std = @import("std");

pub const HydrateFn = *const fn (props: []const u8) void;

const Entry = struct {
    name: []const u8,
    hydrate: HydrateFn,
};

const MAX_ISLANDS = 32;
var entries: [MAX_ISLANDS]Entry = undefined;
var entry_count: usize = 0;

/// Register a hydrate callback for an island name. Components call
/// this from module init (or first `verve_hydrate`) so the dispatcher
/// finds them when `<verve-island data-name="X">` shows up.
pub fn register(name: []const u8, hydrate: HydrateFn) void {
    if (entry_count >= MAX_ISLANDS) @panic("verve island: registry capacity exceeded");
    entries[entry_count] = .{ .name = name, .hydrate = hydrate };
    entry_count += 1;
}

/// Look up a registered hydrate fn. Returns null when the name isn't
/// registered — the bridge falls back to leaving the SSR HTML as-is,
/// which is still correct (Phase 12's automatic `data-vh` hydration
/// still runs across the whole document).
pub fn lookup(name: []const u8) ?HydrateFn {
    for (entries[0..entry_count]) |e| {
        if (std.mem.eql(u8, e.name, name)) return e.hydrate;
    }
    return null;
}

/// Reset the registry. ONLY meant for use in unit tests; the WASM
/// runtime registers once at module init and never deregisters.
pub fn resetForTesting() void {
    entry_count = 0;
}

/// The id (`data-vid`) of the island instance currently hydrating, or 0
/// when none/unknown. Set by `dispatch` around the hydrate call so a
/// future per-instance owner scope can read it. Dormant today — recorded
/// but not yet consumed.
pub threadlocal var current_island_id: u32 = 0;

/// Route a hydrate call for `name`, exposing `vid` as `current_island_id`
/// for the duration of the callback. Returns 1 when an island matched and
/// hydrated, 0 otherwise (bridge leaves the SSR HTML as-is).
pub fn dispatch(name: []const u8, props: []const u8, vid: u32) i32 {
    if (lookup(name)) |hydrate_fn| {
        current_island_id = vid;
        defer current_island_id = 0;
        hydrate_fn(props);
        return 1;
    }
    return 0;
}

const testing = std.testing;

test "register + lookup roundtrip" {
    resetForTesting();

    const Sentinel = struct {
        var hits: u32 = 0;
        fn hydrate(_: []const u8) void {
            hits += 1;
        }
    };
    Sentinel.hits = 0;

    register("Counter", Sentinel.hydrate);
    const f = lookup("Counter") orelse return error.NotFound;
    f("{}");
    try testing.expectEqual(@as(u32, 1), Sentinel.hits);
}

test "lookup returns null for unknown island" {
    resetForTesting();
    try testing.expect(lookup("UnknownIsland") == null);
}

test "dispatch exposes the island id during hydrate, clears it after" {
    resetForTesting();

    const Sentinel = struct {
        var seen: u32 = 999;
        fn hydrate(_: []const u8) void {
            seen = current_island_id;
        }
    };
    Sentinel.seen = 999;

    register("Counter", Sentinel.hydrate);

    const ok = dispatch("Counter", "{}", 7);
    try testing.expectEqual(@as(i32, 1), ok);
    try testing.expectEqual(@as(u32, 7), Sentinel.seen);
    try testing.expectEqual(@as(u32, 0), current_island_id);

    try testing.expectEqual(@as(i32, 0), dispatch("Nope", "{}", 3));
    try testing.expectEqual(@as(u32, 0), current_island_id);
}
