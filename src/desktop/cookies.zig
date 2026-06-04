//! Uniform cookie-store API surfaced via `Window.cookies()`.
//!
//! Each platform backend implements `cookieGet`, `cookieSet`,
//! `cookieDelete`, `cookieClear` against its native cookie manager
//! (WKHTTPCookieStore, ICoreWebView2CookieManager, WebKitCookieManager).
//! The functions are blocking — async backends (Windows, Linux) wrap
//! the async API in a sync wait so consumers never see callbacks.
//!
//! Backends that have not implemented cookie support yet return
//! `error.Unsupported` for every method; callers can probe by calling
//! `get` on a known name.

const std = @import("std");
const opts_mod = @import("options.zig");

pub const Cookie = opts_mod.Cookie;
pub const CookieError = opts_mod.CookieError;
pub const SameSite = opts_mod.SameSite;

// Single-sourced so this store's dispatch always matches the Window's backend
// (a native WV2Host* must not be handed to the legacy COM backend). See backend.zig.
const backend = @import("backend.zig").impl;

/// Per-window cookie store handle. Callers obtain it via
/// `Window.cookies()`. Lifetime is tied to the parent Window.
pub const CookieStore = struct {
    window: *anyopaque,

    /// Read the first cookie matching `name`. Returns null if no
    /// matching cookie exists. The returned slices are owned by
    /// `allocator` — caller frees `result.name`, `result.value`,
    /// `result.domain`, `result.path` after use.
    pub fn get(self: CookieStore, allocator: std.mem.Allocator, name: []const u8) CookieError!?Cookie {
        return backend.cookieGet(self.window, allocator, name);
    }

    /// Write a cookie, replacing any existing record with the same
    /// (name, domain, path) tuple. Defaults documented on the Cookie
    /// type apply.
    pub fn set(self: CookieStore, cookie: Cookie) CookieError!void {
        return backend.cookieSet(self.window, cookie);
    }

    /// Remove the first cookie matching `name`. No-op if no match.
    pub fn delete(self: CookieStore, name: []const u8) CookieError!void {
        return backend.cookieDelete(self.window, name);
    }

    /// Remove every cookie in the per-window store. Useful for
    /// logout flows and tests; does not touch other windows' stores.
    pub fn clear(self: CookieStore) CookieError!void {
        return backend.cookieClear(self.window);
    }
};
