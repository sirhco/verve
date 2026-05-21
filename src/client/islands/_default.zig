//! Phase 13D — default per-island chunk source.
//!
//! Build.zig picks this up for every island declared under
//! `app.islands` that doesn't ship a dedicated
//! `src/client/islands/<Name>.zig` source file. The default chunk
//! exports the same hydrate + scratch surface as a hand-written
//! island so the JS bridge can treat them uniformly — the actual
//! reactive wiring still flows through the main client.wasm's
//! `data-vh` walker. Components that need custom per-island logic
//! drop in a same-named file alongside this one.

const std = @import("std");

var props_scratch: [4096]u8 align(@alignOf(usize)) = undefined;
var hydrate_hits: u32 = 0;

export fn props_buf_ptr() u32 {
    return @intFromPtr(&props_scratch);
}

export fn props_buf_capacity() u32 {
    return props_scratch.len;
}

export fn hydrate_count() u32 {
    return hydrate_hits;
}

export fn hydrate(props_len: u32, root_id: u32) void {
    _ = props_len;
    _ = root_id;
    hydrate_hits += 1;
}
