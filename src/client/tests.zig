//! Aggregator for client-side unit tests. Compiled against the native
//! target — every module here must be platform-agnostic enough to run
//! outside wasm32. Anything truly wasm-only (raw `@import("std").wasm`
//! intrinsics, JS-extern stubs) belongs elsewhere.

test {
    _ = @import("allocator.zig");
    _ = @import("scratch.zig");
    _ = @import("render.zig");
    _ = @import("runtime.zig");
    _ = @import("island.zig");
    _ = @import("reconciler.zig");
    _ = @import("verve_client.zig");
    _ = @import("runtime_exports.zig");
}
