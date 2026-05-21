//! Phase 13B — verify the build-time island manifest reflects
//! `app.islands` declarations end-to-end.

const std = @import("std");
const manifest = @import("client_manifest");
const testing = std.testing;

test "manifest carries the Counter island declared in app.islands" {
    const entry = manifest.lookup("Counter") orelse return error.MissingCounter;
    try testing.expectEqualStrings("Counter", entry.name);
    try testing.expectEqualStrings("{\"initial\":\"i32\"}", entry.props_schema);
    try testing.expectEqualStrings("/islands/Counter.wasm", entry.chunk_url);
}

test "manifest lookup returns null for unknown names" {
    try testing.expect(manifest.lookup("DoesNotExist") == null);
}
