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
//! - **macOS** — currently returns null / false. IOKit
//!   integration is deferred (needs `linkFramework("IOKit")` +
//!   `IOPSCopyPowerSourcesInfo` + `IOPSCopyPowerSourcesList`
//!   plumbing). Apps that need macOS battery status today shell
//!   out to `pmset -g batt` via `std.process.Child.run`.

const std = @import("std");
const builtin = @import("builtin");

/// Battery charge in percent (0..100). Returns null when:
/// - host has no battery (most desktops);
/// - platform isn't implemented (macOS for now);
/// - the OS returned "unknown" (Win value 255).
pub fn batteryPercent() ?u32 {
    return switch (builtin.os.tag) {
        .windows => batteryPercentWindows(),
        .linux => batteryPercentLinux(),
        else => null,
    };
}

/// True when AC power is connected. False when running on
/// battery or the platform isn't implemented.
pub fn isCharging() bool {
    return switch (builtin.os.tag) {
        .windows => isChargingWindows(),
        .linux => isChargingLinux(),
        else => false,
    };
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
    // Sentinel NUL so we can hand `open(2)` a cstr without a
    // separate dupeZ allocation.
    if (path_len >= path_buf.len) return null;
    path_buf[path_len] = 0;
    const cstr: [*:0]const u8 = @ptrCast(path_buf);
    const fd = std.posix.open(cstr, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer std.posix.close(fd);
    var out: SysfsReadResult = .{};
    out.len = std.posix.read(fd, &out.buf) catch return null;
    if (out.len == 0) return null;
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
