//! Client-side rendering helpers. Wraps `verve.escapeHtml` against
//! the wasm client's `FixedBufferAllocator` so consumer code that
//! assembles HTML strings (for an `innerHTML`-style DOM update) can
//! reach for an XSS-safe primitive without each call site allocating
//! its own buffer.

const std = @import("std");
const verve = @import("verve");
const client_alloc = @import("allocator.zig");

/// Allocate an escaped copy of `unsafe` from the wasm client's FBA.
/// Memory is owned by the FBA — valid until the next `allocator.reset()`
/// or until the buffer fills up. Callers building innerHTML fragments
/// should reset between render passes.
pub fn escapeHtmlAlloc(unsafe: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(client_alloc.allocator());
    errdefer aw.deinit();
    try verve.escapeHtml(&aw.writer, unsafe);
    return aw.toOwnedSlice();
}

/// Allocate an escaped copy of `unsafe` from the caller-supplied
/// allocator. Useful when the wasm consumer wants ownership semantics
/// independent of the shared FBA.
pub fn escapeHtmlAllocWith(gpa: std.mem.Allocator, unsafe: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try verve.escapeHtml(&aw.writer, unsafe);
    return aw.toOwnedSlice();
}

test "escapeHtmlAllocWith escapes & < > entities" {
    const gpa = std.testing.allocator;
    const out = try escapeHtmlAllocWith(gpa, "<a>&\"b</a>");
    defer gpa.free(out);
    // escapeHtml is the element-body variant; quotes pass through unchanged.
    try std.testing.expectEqualStrings("&lt;a&gt;&amp;\"b&lt;/a&gt;", out);
}

test "escapeHtmlAllocWith preserves plain ASCII" {
    const gpa = std.testing.allocator;
    const out = try escapeHtmlAllocWith(gpa, "hello world");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("hello world", out);
}
