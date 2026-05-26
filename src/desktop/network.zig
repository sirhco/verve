//! Network reachability — `isOnline()` returns a best-effort
//! "is there any path to the internet right now" bool.
//!
//! Per-platform strategy:
//! - **macOS** — `SCNetworkReachabilityCreateWithName` against
//!   `"apple.com"` + `SCNetworkReachabilityGetFlags`. The default
//!   gateway probe (`SCNetworkReachabilityCreateWithAddress` for
//!   `0.0.0.0`) is more direct but doesn't tell you whether DNS +
//!   the IP path actually work; name-based probing exercises the
//!   resolver too. No DNS lookup happens until the first call.
//!   Needs `linkFramework("SystemConfiguration")` in the scaffold.
//! - **Windows** — `InternetGetConnectedState` from `wininet.dll`.
//!   Returns 1 when any network connection is up; 0 when offline.
//!   Reads cached OS state, not a live probe.
//! - **Linux** — iterates `getifaddrs` looking for any non-loopback
//!   interface in `IFF_UP | IFF_RUNNING` state. Doesn't probe DNS
//!   or upstream; only confirms the host has a live link.
//!
//! Returns conservative `false` on platforms / failures so callers
//! can treat "false" as "assume offline, don't try" without false
//! positives.

const std = @import("std");
const builtin = @import("builtin");

/// True when the host appears to have a working network path,
/// false otherwise (including platform-not-implemented or probe
/// failure). Best-effort — never blocks for more than the platform
/// API's own latency. Apps wanting authoritative answers should
/// pair with their own HEAD request to a known endpoint.
pub fn isOnline() bool {
    return switch (builtin.os.tag) {
        .macos => isOnlineMacos(),
        .windows => isOnlineWindows(),
        .linux => isOnlineLinux(),
        else => false,
    };
}

// ---- macOS — SCNetworkReachability -----------------------------------------

const SCNetworkReachabilityRef = *anyopaque;

// SCNetworkReachabilityFlags bits we care about. From SCNetworkReachability.h.
const kSCNetworkReachabilityFlagsReachable: u32 = 1 << 1;
const kSCNetworkReachabilityFlagsConnectionRequired: u32 = 1 << 2;

extern "SystemConfiguration" fn SCNetworkReachabilityCreateWithName(
    allocator: ?*anyopaque,
    nodename: [*:0]const u8,
) ?SCNetworkReachabilityRef;

extern "SystemConfiguration" fn SCNetworkReachabilityGetFlags(
    target: SCNetworkReachabilityRef,
    flags: *u32,
) bool;

extern "CoreFoundation" fn CFRelease(cf: *anyopaque) void;

fn isOnlineMacos() bool {
    if (builtin.os.tag != .macos) return false;
    // "apple.com" is a stable, always-resolvable probe target.
    // SCNetworkReachability caches the resolver result internally;
    // we don't pay the DNS round trip on the hot path.
    const target = SCNetworkReachabilityCreateWithName(null, "apple.com") orelse return false;
    defer CFRelease(target);
    var flags: u32 = 0;
    if (!SCNetworkReachabilityGetFlags(target, &flags)) return false;
    if ((flags & kSCNetworkReachabilityFlagsReachable) == 0) return false;
    // ConnectionRequired = the path is reachable BUT a connection
    // would need to be established (dial-up / VPN / on-demand).
    // For "is the user actually online right now" treat that as no.
    if ((flags & kSCNetworkReachabilityFlagsConnectionRequired) != 0) return false;
    return true;
}

// ---- Windows — InternetGetConnectedState -----------------------------------

extern "wininet" fn InternetGetConnectedState(
    lp_flags: ?*u32,
    reserved: u32,
) callconv(.winapi) c_int;

fn isOnlineWindows() bool {
    if (builtin.os.tag != .windows) return false;
    var flags: u32 = 0;
    return InternetGetConnectedState(&flags, 0) != 0;
}

// ---- Linux — getifaddrs ----------------------------------------------------

// ifaddrs walking — declared without pulling sys/net headers via @cImport.
const ifaddrs = extern struct {
    ifa_next: ?*ifaddrs,
    ifa_name: ?[*:0]const u8,
    ifa_flags: c_uint,
    // ... rest of struct (addrs / netmask / data) — we don't touch them.
    _opaque: [128]u8 = std.mem.zeroes([128]u8),
};

const IFF_UP: c_uint = 0x1;
const IFF_RUNNING: c_uint = 0x40;
const IFF_LOOPBACK: c_uint = 0x8;

extern fn getifaddrs(out: *?*ifaddrs) c_int;
extern fn freeifaddrs(p: ?*ifaddrs) void;

fn isOnlineLinux() bool {
    if (builtin.os.tag != .linux) return false;
    var head: ?*ifaddrs = null;
    if (getifaddrs(&head) != 0) return false;
    defer freeifaddrs(head);
    var cur = head;
    while (cur) |ifa| {
        // Skip loopback. Look for any non-loopback iface in UP+RUNNING.
        const wanted = IFF_UP | IFF_RUNNING;
        if ((ifa.ifa_flags & wanted) == wanted and (ifa.ifa_flags & IFF_LOOPBACK) == 0) {
            return true;
        }
        cur = ifa.ifa_next;
    }
    return false;
}

const testing = std.testing;

test "isOnline never panics" {
    _ = isOnline();
}
