//! Counter island chunk. Exercises the island stack end to end:
//!   - typed props          → `decodeProps` over the bridge-staged bytes
//!   - island resource-state → `islandStateValue(i32, "seed")`
//!   - a reactive signal     → `registerI32` / `signalGet*`/`signalSet*`
//!   - a DOM ref             → `queryRef` + `setRefText`
//!   - a closure event       → `registerEvent` + stamping `z-on-click-id`
//!
//! Built to `island_Counter.wasm` and served at `/islands/Counter.wasm`.
//! `@import("verve")` resolves to `src/client/island_runtime.zig` (the
//! chunk runtime) via the per-island build module.

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

    // Seed the reactive signal the SSR value span binds to.
    verve.registerI32("counter", p.initial + seed);

    // Fill the label from typed props.
    if (verve.queryRef(.{ .id = "counter-label" })) |h| verve.setRefText(h, p.label);

    // Register the chunk-side click handler and wire it to the button.
    // `registerEvent` returns the runtime slot id; stamp it as
    // `z-on-click-id` so the bridge's closure-dispatch path reaches us.
    const slot = verve.registerEvent(counter_bump);
    if (verve.queryRef(.{ .id = "counter-btn" })) |h| {
        var idbuf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&idbuf, "{d}", .{slot}) catch return;
        verve.setRefAttr(h, "z-on-click-id", s);
    }
}

fn counter_bump() void {
    verve.signalSetI32("counter", verve.signalGetI32("counter") + 1);
}
