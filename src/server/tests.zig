//! Aggregator for all server-side unit tests. Single root means one
//! addTest in build.zig regardless of how many server modules ship tests.

test {
    _ = @import("api_handler.zig");
    _ = @import("pool.zig");
    _ = @import("metrics.zig");
    _ = @import("gzip.zig");
    _ = @import("server_fn_codegen_test.zig");
    _ = @import("island_manifest_test.zig");
}
