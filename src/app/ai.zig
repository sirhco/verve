//! This app's AI tool allowlist. Nothing here is exposed to a model unless
//! it is listed below — and nothing outside `Actions` can be listed at all.
//! See `docs/25-ai.md` for what each `Risk` tier means, why `.mutating` is
//! the default, and the security model this allowlist is the boundary of.

const std = @import("std");
const verve = @import("verve");

pub const tools: []const verve.ai.ToolDecl = &.{
    .{
        .fn_name = "getCount",
        .description = "Read the current value of the shared counter.",
        .risk = .safe,
    },
    .{
        .fn_name = "appName",
        .description = "Return the name of this application.",
        .risk = .safe,
    },
    .{
        .fn_name = "addTodo",
        .description = "Append an item to the shared todo list.",
        .risk = .mutating,
        .arg_docs = &.{.{ .field = "text", .description = "Item text, trimmed, max 200 characters." }},
    },
    .{
        .fn_name = "removeTodo",
        .description = "Remove the todo item at a zero-based index.",
        .risk = .mutating,
        .arg_docs = &.{.{ .field = "index", .description = "Zero-based index of the item to remove." }},
    },
};

/// The real process environment, captured once at server startup (see
/// `src/server/main.zig`, right next to `verve.ai.anthropic.initEnviron`) —
/// Zig 0.16 has no ambient getenv, so the one live capture of it has to be
/// handed in from the true process entry point. `null` in every test in
/// this file/binary unless a test calls `initEnviron` itself, mirroring
/// `anthropic.zig`'s identical `process_environ_map`.
var process_environ_map: ?*const std.process.Environ.Map = null;

/// Call once at process startup with the real environment.
pub fn initEnviron(map: *const std.process.Environ.Map) void {
    process_environ_map = map;
}

/// True when `VERVE_AI_MOCK` is set in the captured environment. Selects
/// the scripted `MockProvider` in `Actions.aiChat` instead of a live
/// Anthropic call, so the integration suite can exercise `/api/aiChat`
/// with no API key and no network.
pub fn mockEnabled() bool {
    const m = process_environ_map orelse return false;
    return m.get("VERVE_AI_MOCK") != null;
}

test "mockEnabled is false with no environ captured" {
    process_environ_map = null;
    try std.testing.expect(!mockEnabled());
}

test "mockEnabled reflects the captured VERVE_AI_MOCK var" {
    var map: std.process.Environ.Map = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("VERVE_AI_MOCK", "1");

    initEnviron(&map);
    // The global is process-wide (shared across every test in this
    // binary) — reset it afterward so later tests still see "unset".
    defer process_environ_map = null;

    try std.testing.expect(mockEnabled());
}
