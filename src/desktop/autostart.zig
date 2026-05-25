//! Launch-at-login registration.
//!
//! Apps that should start when the user logs in (background
//! sync clients, tray-only apps, menu-bar utilities) call
//! `enable(opts)` once during setup. `disable(opts.name)` removes
//! the registration; `isEnabled(opts.name)` checks state without
//! mutating.
//!
//! All three operations are user-scoped — no admin / root prompt,
//! no impact on other users on the machine. The implementation
//! writes to:
//!
//! - **macOS** — `~/Library/LaunchAgents/<name>.plist`. `launchd`
//!   picks up new plists on next login + restart-on-demand.
//! - **Windows** — `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`
//!   registry value. The user's Explorer reads this at login.
//! - **Linux** — `~/.config/autostart/<name>.desktop`. Honored by
//!   every freedesktop-compliant session (GNOME, KDE, XFCE).
//!
//! Naming: `name` is a short identifier — no spaces, no path
//! separators. The Linux + macOS file names are derived from it
//! verbatim; on Windows it becomes the registry-value name. Apps
//! commonly use their bundle / package id (e.g. `dev.verve.myapp`).
//!
//! `exe_path` should be an absolute path to the launcher binary.
//! Callers usually pull this from `std.process.executablePathAlloc`
//! at app startup.

const std = @import("std");
const builtin = @import("builtin");

pub const Environ = std.process.Environ;

pub const Error = error{
    Unsupported,
    OutOfMemory,
    NotFound,
    Backend,
    /// Required `HOME` / `USERPROFILE` env var was missing.
    NoUserHome,
};

pub const Options = struct {
    /// Stable identifier. Used as the file/registry-value name. No
    /// spaces, no path separators.
    name: []const u8,
    /// Absolute path to the launcher binary.
    exe_path: []const u8,
    /// Optional display name shown in the OS's "startup apps" UI.
    /// macOS ignores it (the plist `Label` field carries the
    /// identifier instead); Linux uses it for `.desktop` `Name=`;
    /// Windows ignores it (Task Manager shows the exe metadata).
    display_name: []const u8 = "",
    /// Extra CLI args appended to `exe_path` on launch.
    args: []const []const u8 = &.{},
};

pub fn enable(allocator: std.mem.Allocator, io: std.Io, environ: Environ, opts: Options) Error!void {
    return switch (builtin.os.tag) {
        .macos => enableMacos(allocator, io, environ, opts),
        .windows => enableWindows(allocator, opts),
        .linux => enableLinux(allocator, io, environ, opts),
        else => error.Unsupported,
    };
}

pub fn disable(allocator: std.mem.Allocator, io: std.Io, environ: Environ, name: []const u8) Error!void {
    return switch (builtin.os.tag) {
        .macos => disableFile(allocator, io, environ, "Library/LaunchAgents", name, ".plist"),
        .windows => disableWindows(allocator, name),
        .linux => disableFile(allocator, io, environ, ".config/autostart", name, ".desktop"),
        else => error.Unsupported,
    };
}

pub fn isEnabled(allocator: std.mem.Allocator, io: std.Io, environ: Environ, name: []const u8) Error!bool {
    return switch (builtin.os.tag) {
        .macos => fileExists(allocator, io, environ, "Library/LaunchAgents", name, ".plist"),
        .windows => isEnabledWindows(allocator, name),
        .linux => fileExists(allocator, io, environ, ".config/autostart", name, ".desktop"),
        else => error.Unsupported,
    };
}

// ---- shared filesystem helpers ----------------------------------------------

fn homePath(allocator: std.mem.Allocator, environ: Environ) Error![]u8 {
    const var_name = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    return environ.getAlloc(allocator, var_name) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.NoUserHome,
    };
}

fn joinFile(allocator: std.mem.Allocator, environ: Environ, subdir: []const u8, name: []const u8, ext: []const u8) Error![]u8 {
    const home = try homePath(allocator, environ);
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}{s}", .{ home, subdir, name, ext }) catch error.OutOfMemory;
}

fn fileExists(allocator: std.mem.Allocator, io: std.Io, environ: Environ, subdir: []const u8, name: []const u8, ext: []const u8) Error!bool {
    const path = try joinFile(allocator, environ, subdir, name, ext);
    defer allocator.free(path);
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn disableFile(allocator: std.mem.Allocator, io: std.Io, environ: Environ, subdir: []const u8, name: []const u8, ext: []const u8) Error!void {
    const path = try joinFile(allocator, environ, subdir, name, ext);
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return error.Backend,
    };
}

// ---- macOS — LaunchAgents plist --------------------------------------------

fn enableMacos(allocator: std.mem.Allocator, io: std.Io, environ: Environ, opts: Options) Error!void {
    if (builtin.os.tag != .macos) return error.Unsupported;
    const path = try joinFile(allocator, environ, "Library/LaunchAgents", opts.name, ".plist");
    defer allocator.free(path);

    if (std.fs.path.dirname(path)) |parent| {
        std.Io.Dir.cwd().createDirPath(io, parent) catch return error.Backend;
    }

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    try appendStr(allocator, &body,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>Label</key>
        \\    <string>
    );
    try appendXmlEscaped(allocator, &body, opts.name);
    try appendStr(allocator, &body,
        \\</string>
        \\    <key>ProgramArguments</key>
        \\    <array>
        \\        <string>
    );
    try appendXmlEscaped(allocator, &body, opts.exe_path);
    try appendStr(allocator, &body, "</string>\n");
    for (opts.args) |arg| {
        try appendStr(allocator, &body, "        <string>");
        try appendXmlEscaped(allocator, &body, arg);
        try appendStr(allocator, &body, "</string>\n");
    }
    try appendStr(allocator, &body,
        \\    </array>
        \\    <key>RunAtLoad</key>
        \\    <true/>
        \\</dict>
        \\</plist>
        \\
    );

    writeFileAtomic(io, path, body.items) catch return error.Backend;
}

// ---- Linux — ~/.config/autostart/<name>.desktop ----------------------------

fn enableLinux(allocator: std.mem.Allocator, io: std.Io, environ: Environ, opts: Options) Error!void {
    if (builtin.os.tag != .linux) return error.Unsupported;
    const path = try joinFile(allocator, environ, ".config/autostart", opts.name, ".desktop");
    defer allocator.free(path);

    if (std.fs.path.dirname(path)) |parent| {
        std.Io.Dir.cwd().createDirPath(io, parent) catch return error.Backend;
    }

    var exec_line: std.ArrayList(u8) = .empty;
    defer exec_line.deinit(allocator);
    try exec_line.appendSlice(allocator, opts.exe_path);
    for (opts.args) |arg| {
        try exec_line.append(allocator, ' ');
        try exec_line.appendSlice(allocator, arg);
    }

    const display = if (opts.display_name.len > 0) opts.display_name else opts.name;
    const body = std.fmt.allocPrint(allocator,
        \\[Desktop Entry]
        \\Type=Application
        \\Name={s}
        \\Exec={s}
        \\Terminal=false
        \\X-GNOME-Autostart-enabled=true
        \\StartupNotify=false
        \\
    , .{ display, exec_line.items }) catch return error.OutOfMemory;
    defer allocator.free(body);

    writeFileAtomic(io, path, body) catch return error.Backend;
}

// ---- Windows — HKCU Run registry value -------------------------------------

const HKEY = ?*opaque {};
const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
const KEY_SET_VALUE: u32 = 0x0002;
const KEY_QUERY_VALUE: u32 = 0x0001;
const REG_SZ: u32 = 1;
const ERROR_SUCCESS: c_long = 0;
const ERROR_FILE_NOT_FOUND: c_long = 2;
const RUN_SUBKEY = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Run");

extern "advapi32" fn RegOpenKeyExW(hkey: HKEY, sub: ?[*:0]const u16, options: u32, access: u32, out: *HKEY) callconv(.winapi) c_long;
extern "advapi32" fn RegSetValueExW(hkey: HKEY, name: ?[*:0]const u16, reserved: u32, ty: u32, data: ?[*]const u8, size: u32) callconv(.winapi) c_long;
extern "advapi32" fn RegDeleteValueW(hkey: HKEY, name: ?[*:0]const u16) callconv(.winapi) c_long;
extern "advapi32" fn RegQueryValueExW(hkey: HKEY, name: ?[*:0]const u16, reserved: ?*u32, ty: ?*u32, data: ?[*]u8, size: ?*u32) callconv(.winapi) c_long;
extern "advapi32" fn RegCloseKey(hkey: HKEY) callconv(.winapi) c_long;

fn enableWindows(allocator: std.mem.Allocator, opts: Options) Error!void {
    if (builtin.os.tag != .windows) return error.Unsupported;

    var cmd: std.ArrayList(u8) = .empty;
    defer cmd.deinit(allocator);
    try cmd.append(allocator, '"');
    try cmd.appendSlice(allocator, opts.exe_path);
    try cmd.append(allocator, '"');
    for (opts.args) |arg| {
        try cmd.append(allocator, ' ');
        if (std.mem.indexOfScalar(u8, arg, ' ') != null) {
            try cmd.append(allocator, '"');
            try cmd.appendSlice(allocator, arg);
            try cmd.append(allocator, '"');
        } else try cmd.appendSlice(allocator, arg);
    }

    const w_cmd = std.unicode.utf8ToUtf16LeAllocZ(allocator, cmd.items) catch return error.OutOfMemory;
    defer allocator.free(w_cmd);
    const w_name = std.unicode.utf8ToUtf16LeAllocZ(allocator, opts.name) catch return error.OutOfMemory;
    defer allocator.free(w_name);

    var key: HKEY = null;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, RUN_SUBKEY, 0, KEY_SET_VALUE, &key) != ERROR_SUCCESS) return error.Backend;
    defer _ = RegCloseKey(key);

    const bytes = (w_cmd.len + 1) * @sizeOf(u16);
    if (RegSetValueExW(key, w_name.ptr, 0, REG_SZ, @ptrCast(w_cmd.ptr), @intCast(bytes)) != ERROR_SUCCESS) return error.Backend;
}

fn disableWindows(allocator: std.mem.Allocator, name: []const u8) Error!void {
    if (builtin.os.tag != .windows) return error.Unsupported;
    const w_name = std.unicode.utf8ToUtf16LeAllocZ(allocator, name) catch return error.OutOfMemory;
    defer allocator.free(w_name);
    var key: HKEY = null;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, RUN_SUBKEY, 0, KEY_SET_VALUE, &key) != ERROR_SUCCESS) return error.Backend;
    defer _ = RegCloseKey(key);
    const r = RegDeleteValueW(key, w_name.ptr);
    if (r != ERROR_SUCCESS and r != ERROR_FILE_NOT_FOUND) return error.Backend;
}

fn isEnabledWindows(allocator: std.mem.Allocator, name: []const u8) Error!bool {
    if (builtin.os.tag != .windows) return error.Unsupported;
    const w_name = std.unicode.utf8ToUtf16LeAllocZ(allocator, name) catch return error.OutOfMemory;
    defer allocator.free(w_name);
    var key: HKEY = null;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, RUN_SUBKEY, 0, KEY_QUERY_VALUE, &key) != ERROR_SUCCESS) return false;
    defer _ = RegCloseKey(key);
    var size: u32 = 0;
    return RegQueryValueExW(key, w_name.ptr, null, null, null, &size) == ERROR_SUCCESS;
}

// ---- helpers ----------------------------------------------------------------

fn appendStr(allocator: std.mem.Allocator, list: *std.ArrayList(u8), s: []const u8) Error!void {
    list.appendSlice(allocator, s) catch return error.OutOfMemory;
}

fn appendXmlEscaped(allocator: std.mem.Allocator, list: *std.ArrayList(u8), s: []const u8) Error!void {
    for (s) |c| switch (c) {
        '<' => list.appendSlice(allocator, "&lt;") catch return error.OutOfMemory,
        '>' => list.appendSlice(allocator, "&gt;") catch return error.OutOfMemory,
        '&' => list.appendSlice(allocator, "&amp;") catch return error.OutOfMemory,
        '"' => list.appendSlice(allocator, "&quot;") catch return error.OutOfMemory,
        else => list.append(allocator, c) catch return error.OutOfMemory,
    };
}

fn writeFileAtomic(io: std.Io, path: []const u8, body: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body });
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "appendXmlEscaped handles all five entities" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try appendXmlEscaped(testing.allocator, &list, "<a href=\"x&y\">z</a>");
    try testing.expectEqualStrings("&lt;a href=&quot;x&amp;y&quot;&gt;z&lt;/a&gt;", list.items);
}
