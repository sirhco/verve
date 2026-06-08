//! Power / battery state.
//!
//! `batteryPercent()` and `isCharging()` give apps the user's
//! current battery status — useful for "low battery" warnings,
//! pausing background work on battery, dimming intensive UI.
//!
//! Per-platform strategy:
//!
//! - **Windows** — `GetSystemPowerStatus(SYSTEM_POWER_STATUS)`
//!   from kernel32. `BatteryLifePercent` (0-100, 255 = unknown)
//!   + `ACLineStatus` (0 = offline / on battery, 1 = online /
//!   plugged in).
//! - **Linux** — `/sys/class/power_supply/BAT0/capacity` for the
//!   percent, `/sys/class/power_supply/BAT0/status` for charging
//!   state ("Charging" / "Discharging" / "Full" / "Not charging").
//!   Iterates `BAT0`..`BAT9` since some laptops use higher
//!   indices.
//! - **macOS** — IOKit via `IOPSCopyPowerSourcesInfo` +
//!   `IOPSCopyPowerSourcesList`. Reads `kIOPSCurrentCapacityKey` /
//!   `kIOPSMaxCapacityKey` from the first power source for the
//!   percentage; `kIOPSIsChargingKey` (CFBoolean) for charging
//!   state. Scaffold must link the `IOKit` framework — the bundled
//!   template `build.zig` does so on `target.result.os.tag == .macos`.

const std = @import("std");
const builtin = @import("builtin");

/// Battery charge in percent (0..100). Returns null when:
/// - host has no battery (most desktops);
/// - platform isn't implemented (macOS for now);
/// - the OS returned "unknown" (Win value 255).
pub fn batteryPercent() ?u32 {
    return switch (builtin.os.tag) {
        .macos => batteryPercentMacos(),
        .windows => batteryPercentWindows(),
        .linux => batteryPercentLinux(),
        else => null,
    };
}

/// True when AC power is connected. False when running on
/// battery or the platform isn't implemented.
pub fn isCharging() bool {
    return switch (builtin.os.tag) {
        .macos => isChargingMacos(),
        .windows => isChargingWindows(),
        .linux => isChargingLinux(),
        else => false,
    };
}

// ---- macOS — IOKit IOPSCopyPowerSourcesInfo --------------------------------

// CoreFoundation opaque types. We never dereference; we just hand them
// back through CF / IOPS calls.
const CFTypeRef = *anyopaque;
const CFArrayRef = *anyopaque;
const CFDictionaryRef = *anyopaque;
const CFNumberRef = *anyopaque;
const CFBooleanRef = *anyopaque;
const CFStringRef = *anyopaque;
const CFIndex = isize;
const kCFNumberSInt32Type: CFIndex = 3;

extern "CoreFoundation" fn CFRelease(cf: CFTypeRef) void;
extern "CoreFoundation" fn CFArrayGetCount(arr: CFArrayRef) CFIndex;
extern "CoreFoundation" fn CFArrayGetValueAtIndex(arr: CFArrayRef, idx: CFIndex) ?*anyopaque;
extern "CoreFoundation" fn CFDictionaryGetValue(d: CFDictionaryRef, key: ?*const anyopaque) ?*anyopaque;
extern "CoreFoundation" fn CFNumberGetValue(num: CFNumberRef, ty: CFIndex, out: *anyopaque) bool;
extern "CoreFoundation" fn CFBooleanGetValue(b: CFBooleanRef) bool;

extern "IOKit" fn IOPSCopyPowerSourcesInfo() ?CFTypeRef;
extern "IOKit" fn IOPSCopyPowerSourcesList(snapshot: CFTypeRef) ?CFArrayRef;
extern "IOKit" fn IOPSGetPowerSourceDescription(snapshot: CFTypeRef, source: *anyopaque) ?CFDictionaryRef;

// The IOPS keys are `#define`d in IOPSKeys.h as C string literals
// (not extern CFString symbols), so we build CFString equivalents
// at runtime via CFStringCreateWithCString. Cached after first use.
const kCFStringEncodingUTF8: u32 = 0x08000100;
extern "CoreFoundation" fn CFStringCreateWithCString(
    allocator: ?*anyopaque,
    cstr: [*:0]const u8,
    encoding: u32,
) ?CFStringRef;

var key_current_capacity: ?CFStringRef = null;
var key_max_capacity: ?CFStringRef = null;
var key_is_charging: ?CFStringRef = null;

fn ensureIopsKeys() bool {
    if (builtin.os.tag != .macos) return false;
    if (key_current_capacity == null) {
        key_current_capacity = CFStringCreateWithCString(null, "Current Capacity", kCFStringEncodingUTF8);
    }
    if (key_max_capacity == null) {
        key_max_capacity = CFStringCreateWithCString(null, "Max Capacity", kCFStringEncodingUTF8);
    }
    if (key_is_charging == null) {
        key_is_charging = CFStringCreateWithCString(null, "Is Charging", kCFStringEncodingUTF8);
    }
    return key_current_capacity != null and key_max_capacity != null and key_is_charging != null;
}

const MacosBattery = struct {
    percent: ?u32 = null,
    charging: bool = false,
};

fn readMacosBattery() MacosBattery {
    if (builtin.os.tag != .macos) return .{};
    if (!ensureIopsKeys()) return .{};
    const snapshot = IOPSCopyPowerSourcesInfo() orelse return .{};
    defer CFRelease(snapshot);
    const list = IOPSCopyPowerSourcesList(snapshot) orelse return .{};
    defer CFRelease(list);
    const n = CFArrayGetCount(list);
    if (n <= 0) return .{};

    // First source is typically the internal battery. Apps with
    // multiple sources (USB battery packs, UPS) would need to filter
    // by kIOPSTypeKey == "InternalBattery"; v1 ships the simple path.
    const src = CFArrayGetValueAtIndex(list, 0) orelse return .{};
    const dict = IOPSGetPowerSourceDescription(snapshot, src) orelse return .{};

    var out: MacosBattery = .{};

    if (CFDictionaryGetValue(dict, key_current_capacity.?)) |cur_raw| {
        if (CFDictionaryGetValue(dict, key_max_capacity.?)) |max_raw| {
            var cur: i32 = 0;
            var max: i32 = 0;
            const cur_ok = CFNumberGetValue(@ptrCast(cur_raw), kCFNumberSInt32Type, @ptrCast(&cur));
            const max_ok = CFNumberGetValue(@ptrCast(max_raw), kCFNumberSInt32Type, @ptrCast(&max));
            if (cur_ok and max_ok and max > 0 and cur >= 0) {
                const pct: u32 = @intCast(@divTrunc(cur * 100, max));
                out.percent = if (pct > 100) 100 else pct;
            }
        }
    }

    if (CFDictionaryGetValue(dict, key_is_charging.?)) |chg_raw| {
        out.charging = CFBooleanGetValue(@ptrCast(chg_raw));
    }

    return out;
}

fn batteryPercentMacos() ?u32 {
    if (builtin.os.tag != .macos) return null;
    return readMacosBattery().percent;
}

fn isChargingMacos() bool {
    if (builtin.os.tag != .macos) return false;
    return readMacosBattery().charging;
}

// ---- Windows — GetSystemPowerStatus ----------------------------------------

const SYSTEM_POWER_STATUS = extern struct {
    ACLineStatus: u8 = 0,
    BatteryFlag: u8 = 0,
    BatteryLifePercent: u8 = 0,
    SystemStatusFlag: u8 = 0,
    BatteryLifeTime: u32 = 0,
    BatteryFullLifeTime: u32 = 0,
};

extern "kernel32" fn GetSystemPowerStatus(status: *SYSTEM_POWER_STATUS) callconv(.winapi) c_int;

fn batteryPercentWindows() ?u32 {
    if (builtin.os.tag != .windows) return null;
    var st: SYSTEM_POWER_STATUS = .{};
    if (GetSystemPowerStatus(&st) == 0) return null;
    if (st.BatteryLifePercent == 255) return null;
    return @intCast(st.BatteryLifePercent);
}

fn isChargingWindows() bool {
    if (builtin.os.tag != .windows) return false;
    var st: SYSTEM_POWER_STATUS = .{};
    if (GetSystemPowerStatus(&st) == 0) return false;
    return st.ACLineStatus == 1;
}

// ---- Linux — /sys/class/power_supply ---------------------------------------

fn batteryPercentLinux() ?u32 {
    if (builtin.os.tag != .linux) return null;
    var i: u8 = 0;
    while (i < 10) : (i += 1) {
        var path_buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/sys/class/power_supply/BAT{d}/capacity", .{i}) catch return null;
        if (readSysFile(&path_buf, path.len)) |bytes| {
            const trimmed = std.mem.trim(u8, bytes.slice(), &std.ascii.whitespace);
            const val = std.fmt.parseInt(u32, trimmed, 10) catch return null;
            return val;
        }
    }
    return null;
}

fn isChargingLinux() bool {
    if (builtin.os.tag != .linux) return false;
    var i: u8 = 0;
    while (i < 10) : (i += 1) {
        var path_buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/sys/class/power_supply/BAT{d}/status", .{i}) catch return false;
        if (readSysFile(&path_buf, path.len)) |bytes| {
            const trimmed = std.mem.trim(u8, bytes.slice(), &std.ascii.whitespace);
            return std.mem.eql(u8, trimmed, "Charging") or std.mem.eql(u8, trimmed, "Full");
        }
    }
    return false;
}

/// Bounded read from a sysfs path via posix open/read. Sysfs
/// files report short content (under ~32 bytes for capacity +
/// status), so a stack buffer is plenty.
const SysfsReadResult = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,
    pub fn slice(self: *const SysfsReadResult) []const u8 {
        return self.buf[0..self.len];
    }
};

fn readSysFile(path_buf: *[128]u8, path_len: usize) ?SysfsReadResult {
    if (builtin.os.tag != .linux) return null;
    if (path_len >= path_buf.len) return null;
    // NUL-terminate for the raw open(2) syscall.
    path_buf[path_len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(path_buf);
    const rc = std.os.linux.open(path_z, .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(rc)) < 0) return null;
    const fd: i32 = @intCast(rc);
    defer _ = std.os.linux.close(fd);
    var out: SysfsReadResult = .{};
    const n = std.os.linux.read(fd, &out.buf, out.buf.len);
    if (@as(isize, @bitCast(n)) <= 0) return null;
    out.len = n;
    return out;
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "batteryPercent returns null gracefully without panicking" {
    // We can't assert a specific result (host may or may not have
    // a battery), just that the call doesn't blow up.
    _ = batteryPercent();
}

test "isCharging never panics" {
    _ = isCharging();
}
