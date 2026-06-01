//! Counter island chunk. Exercises the island stack end to end:
//!   - typed props          → `decodeProps` over the bridge-staged bytes
//!   - island resource-state → `islandStateValue(i32, "seed")`
//!   - a reactive signal     → `registerI32` (SSR value span binds to it)
//!   - a DOM ref             → `queryRef` + `setRefText` (typed label)
//!
//! Built to `island_Counter.wasm` and served at `/islands/Counter.wasm`.
//! `@import("verve")` resolves to `src/client/island_runtime.zig` (the
//! chunk runtime) via the per-island build module.
//!
//! NOTE: chunk-side CLOSURE event handlers (`registerEvent`) are NOT wired
//! yet — passing a `*const fn()` across the chunk↔main boundary needs the
//! shared indirect function table fully connected (`runtime_exports.zig`
//! flags this as deferred). A chunk that registered a closure handler traps
//! with "function signature mismatch" on dispatch. So this demo verifies the
//! props/state/signal hydration path; interactive chunk handlers are a
//! separate follow-up.

const std = @import("std");
const verve = @import("verve");

const Props = struct { initial: i32, label: []const u8 };

export fn hydrate(props_ptr: u32, props_len: u32, vid: u32) void {
    _ = vid;
    var fbuf: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fbuf);

    const props_bytes = @as([*]const u8, @ptrFromInt(props_ptr))[0..props_len];
    const p = verve.decodeProps(Props, props_bytes, fba.allocator()) catch
        Props{ .initial = 0, .label = "?" };

    // Server-staged island state (`ctx.islandState(.{ .seed = ... })`).
    const seed = verve.islandStateValue(i32, "seed") orelse 0;

    // Seed the reactive signal the SSR value span binds to: shows
    // `initial + seed` = 3 + 100 = 103, proving props + state both hydrated.
    verve.registerI32("counter", p.initial + seed);

    // Fill the label from typed props.
    if (verve.queryRef(.{ .id = "counter-label" })) |h| verve.setRefText(h, p.label);
}
