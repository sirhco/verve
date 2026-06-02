//! Headless surface tests for shared types (`WindowOptions`,
//! `AssetEntry`) and the document-start IPC shim. Method-surface
//! conformance on the backend Window is asserted at framework-build
//! time via a `comptime` block in `window.zig` — that check runs
//! without linking against Cocoa/WebKit, so it stays out of this
//! headless test entry which compiles on every host.

const std = @import("std");
const options = @import("options.zig");
const ipc = @import("ipc.zig");

test "WindowOptions defaults match documented contract" {
    const o: options.WindowOptions = .{};
    try std.testing.expectEqualStrings("Verve", o.title);
    try std.testing.expectEqual(@as(u32, 1024), o.width);
    try std.testing.expectEqual(@as(u32, 768), o.height);
    try std.testing.expectEqual(false, o.devtools);
    try std.testing.expectEqualStrings("verve", o.scheme);
    try std.testing.expectEqualStrings("index.html", o.initial_path);
    try std.testing.expectEqual(@as(usize, 0), o.assets.len);
    try std.testing.expect(o.on_message == null);
    try std.testing.expect(o.on_message_ctx == null);
    try std.testing.expectEqual(true, o.install_default_menu);
}

test "ipc.shim_js exposes the verve bridge contract" {
    // Backends inject this exact string at document-start. Smoke check
    // that the well-known surface markers are present so the frontend
    // contract stays bound at compile time.
    try std.testing.expect(std.mem.indexOf(u8, ipc.shim_js, "window.verve") != null);
    try std.testing.expect(std.mem.indexOf(u8, ipc.shim_js, "send") != null);
    try std.testing.expect(std.mem.indexOf(u8, ipc.shim_js, "onMessage") != null);
    try std.testing.expect(std.mem.indexOf(u8, ipc.shim_js, "_dispatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, ipc.shim_js, "verve:ready") != null);
}

test "PrintOptions defaults to kind=default" {
    const o: options.PrintOptions = .{};
    try std.testing.expectEqual(options.PrintDialogKind.default, o.kind);
}

test "PrintDialogKind enumerates default/browser/system" {
    // ABI guard: downstream apps switch on these tags.
    _ = options.PrintDialogKind.default;
    _ = options.PrintDialogKind.browser;
    _ = options.PrintDialogKind.system;
}

test "AccessibilitySubrole enumerates standard/dialog/system_dialog/floating" {
    // ABI guard: macOS maps these tags to AX subrole strings; downstream
    // apps switch on them.
    const S = options.AccessibilitySubrole;
    try std.testing.expectEqual(4, @typeInfo(S).@"enum".fields.len);
    _ = S.standard;
    _ = S.dialog;
    _ = S.system_dialog;
    _ = S.floating;
}

test "PrintError set is stable" {
    // ABI guard: downstream catch-prongs depend on these names.
    const e: options.PrintError = error.Unsupported;
    try std.testing.expect(e == error.Unsupported);
    try std.testing.expect(@as(options.PrintError, error.Backend) == error.Backend);
    try std.testing.expect(@as(options.PrintError, error.Cancelled) == error.Cancelled);
    try std.testing.expect(@as(options.PrintError, error.OutOfMemory) == error.OutOfMemory);
}

test "AssetEntry shape matches public_assets.Entry contract" {
    // The desktop app casts `public_assets.entries` directly to
    // `[]const desktop.AssetEntry`; identical field order/types are a
    // hard ABI requirement.
    const E = options.AssetEntry;
    try std.testing.expectEqual(3, @typeInfo(E).@"struct".fields.len);
    const fields = @typeInfo(E).@"struct".fields;
    try std.testing.expectEqualStrings("path", fields[0].name);
    try std.testing.expectEqualStrings("bytes", fields[1].name);
    try std.testing.expectEqualStrings("content_type", fields[2].name);
}
