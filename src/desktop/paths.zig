//! Cross-platform standard directories.
//!
//! Apps need stable filesystem locations for persistent data,
//! disposable caches, user config, etc. Each OS has its own
//! convention; this module normalizes the lookup so app code
//! writes `paths.dataDir(allocator, environ, "myapp")` once and
//! gets the right location on every platform.
//!
//! Conventions:
//!
//! | API           | macOS                                | Windows                 | Linux (XDG)               |
//! | ------------- | ------------------------------------ | ----------------------- | ------------------------- |
//! | `dataDir`     | ~/Library/Application Support/<app>  | %APPDATA%\<app>         | $XDG_DATA_HOME/<app>      |
//! | `cacheDir`    | ~/Library/Caches/<app>               | %LOCALAPPDATA%\<app>    | $XDG_CACHE_HOME/<app>     |
//! | `configDir`   | ~/Library/Application Support/<app>  | %APPDATA%\<app>         | $XDG_CONFIG_HOME/<app>    |
//! | `homeDir`     | $HOME                                | %USERPROFILE%           | $HOME                     |
//! | `tempDir`     | $TMPDIR or /tmp                      | %TEMP% or %TMP%         | $TMPDIR or /tmp           |
//!
//! On Linux, XDG vars fall back to `$HOME/.local/share`, `$HOME/.cache`,
//! `$HOME/.config` when unset — matches the freedesktop Base Directory
//! Specification.
//!
//! All returned strings are caller-owned UTF-8; free via the same
//! allocator. No directory is created — callers do that with
//! `std.fs.makeDirAbsolute` or similar.
//!
//! `environ` comes from your `main` entry's `init.minimal.environ`;
//! threading it through gives us testable cross-platform env-var
//! lookup without touching process globals.

const std = @import("std");
const builtin = @import("builtin");

pub const Environ = std.process.Environ;

pub const Error = error{
    Unsupported,
    OutOfMemory,
    /// HOME / USERPROFILE / TMPDIR was missing and no fallback applied.
    NotFound,
};

pub fn dataDir(allocator: std.mem.Allocator, environ: Environ, app_name: []const u8) Error![]u8 {
    return joinApp(allocator, try dataBase(allocator, environ), app_name);
}

pub fn cacheDir(allocator: std.mem.Allocator, environ: Environ, app_name: []const u8) Error![]u8 {
    return joinApp(allocator, try cacheBase(allocator, environ), app_name);
}

pub fn configDir(allocator: std.mem.Allocator, environ: Environ, app_name: []const u8) Error![]u8 {
    return joinApp(allocator, try configBase(allocator, environ), app_name);
}

pub fn homeDir(allocator: std.mem.Allocator, environ: Environ) Error![]u8 {
    return switch (builtin.os.tag) {
        .macos, .linux => readEnv(allocator, environ, "HOME"),
        .windows => readEnv(allocator, environ, "USERPROFILE"),
        else => error.Unsupported,
    };
}

pub fn tempDir(allocator: std.mem.Allocator, environ: Environ) Error![]u8 {
    switch (builtin.os.tag) {
        .macos, .linux => {
            if (readEnvOpt(allocator, environ, "TMPDIR")) |t| return t;
            return allocator.dupe(u8, "/tmp") catch error.OutOfMemory;
        },
        .windows => {
            if (readEnvOpt(allocator, environ, "TEMP")) |t| return t;
            if (readEnvOpt(allocator, environ, "TMP")) |t| return t;
            return error.NotFound;
        },
        else => return error.Unsupported,
    }
}

// ---- platform-specific bases ------------------------------------------------

fn dataBase(allocator: std.mem.Allocator, environ: Environ) Error![]u8 {
    return switch (builtin.os.tag) {
        .macos => libraryDir(allocator, environ, "Application Support"),
        .windows => readEnv(allocator, environ, "APPDATA"),
        .linux => xdgDir(allocator, environ, "XDG_DATA_HOME", ".local/share"),
        else => error.Unsupported,
    };
}

fn cacheBase(allocator: std.mem.Allocator, environ: Environ) Error![]u8 {
    return switch (builtin.os.tag) {
        .macos => libraryDir(allocator, environ, "Caches"),
        .windows => readEnv(allocator, environ, "LOCALAPPDATA"),
        .linux => xdgDir(allocator, environ, "XDG_CACHE_HOME", ".cache"),
        else => error.Unsupported,
    };
}

fn configBase(allocator: std.mem.Allocator, environ: Environ) Error![]u8 {
    return switch (builtin.os.tag) {
        // macOS + Windows have no distinct "config" dir convention;
        // collapse onto the data base.
        .macos => libraryDir(allocator, environ, "Application Support"),
        .windows => readEnv(allocator, environ, "APPDATA"),
        .linux => xdgDir(allocator, environ, "XDG_CONFIG_HOME", ".config"),
        else => error.Unsupported,
    };
}

fn libraryDir(allocator: std.mem.Allocator, environ: Environ, sub: []const u8) Error![]u8 {
    const home = try readEnv(allocator, environ, "HOME");
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/Library/{s}", .{ home, sub }) catch error.OutOfMemory;
}

fn xdgDir(allocator: std.mem.Allocator, environ: Environ, env_var: []const u8, fallback_rel: []const u8) Error![]u8 {
    if (readEnvOpt(allocator, environ, env_var)) |v| return v;
    const home = try readEnv(allocator, environ, "HOME");
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, fallback_rel }) catch error.OutOfMemory;
}

fn joinApp(allocator: std.mem.Allocator, base: []u8, app_name: []const u8) Error![]u8 {
    defer allocator.free(base);
    if (app_name.len == 0) return allocator.dupe(u8, base) catch error.OutOfMemory;
    const sep: u8 = if (builtin.os.tag == .windows) '\\' else '/';
    return std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ base, sep, app_name }) catch error.OutOfMemory;
}

fn readEnv(allocator: std.mem.Allocator, environ: Environ, name: []const u8) Error![]u8 {
    return environ.getAlloc(allocator, name) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.EnvironmentVariableMissing => error.NotFound,
        error.InvalidWtf8 => error.NotFound,
    };
}

fn readEnvOpt(allocator: std.mem.Allocator, environ: Environ, name: []const u8) ?[]u8 {
    return environ.getAlloc(allocator, name) catch null;
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "empty environ returns NotFound" {
    // `Environ.empty` exposes no env vars at all, so every base
    // lookup returns NotFound. Verifies the error path without
    // depending on the test host's actual env.
    const env: Environ = .empty;
    try testing.expectError(error.NotFound, homeDir(testing.allocator, env));
    try testing.expectError(error.NotFound, dataDir(testing.allocator, env, "verve_test"));
}
