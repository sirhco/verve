//! Dashboard island — live telemetry for turbine 0.
//!
//! Subscribes to the `metrics` SSE push channel. Each frame is a JSON object:
//!   {"tick":N,"turbines":[{"id":0,"power_kw":X,"rpm":Y,"wind_ms":Z},...]}
//!
//! Updates three str signals (`power_kw`, `rpm`, `wind_ms`) bound to the SSR
//! placeholder spans, and updates the `data-ref="dash-power-fill"` bar width.

const std = @import("std");
const verve = @import("verve");

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    // Register display signals (bound via z-bind in the SSR tree).
    verve.registerStr("power_kw", "—");
    verve.registerStr("rpm", "—");
    verve.registerStr("wind_ms", "—");
    // Subscribe to the metrics push channel.
    _ = verve.pushSubscribe("metrics", "Dashboard", "metrics_apply", root_id);
}

/// Called by the bridge when a metrics frame arrives.
/// Parses turbine 0 fields and updates signals + the power bar.
export fn metrics_apply(ptr: u32, len: u32) void {
    if (len == 0) return;
    const data: []const u8 = @as([*]const u8, @ptrFromInt(@as(usize, ptr)))[0..len];

    // Extract turbine 0's fields from the JSON payload.
    // Frame format: {"tick":N,"turbines":[{"id":0,"power_kw":X,"rpm":Y,"wind_ms":Z},...]}
    // We scan for the first turbine object (after "turbines":[).
    const power = extractF32Field(data, "power_kw") orelse return;
    const rpm_val = extractF32Field(data, "rpm") orelse return;
    const wind_val = extractF32Field(data, "wind_ms") orelse return;

    // Format and update signals.
    var buf: [32]u8 = undefined;

    const pw_str = std.fmt.bufPrint(&buf, "{d:.0}", .{power}) catch return;
    verve.signalSetStr("power_kw", pw_str);

    var buf2: [32]u8 = undefined;
    const rpm_str = std.fmt.bufPrint(&buf2, "{d:.1}", .{rpm_val}) catch return;
    verve.signalSetStr("rpm", rpm_str);

    var buf3: [32]u8 = undefined;
    const wind_str = std.fmt.bufPrint(&buf3, "{d:.1}", .{wind_val}) catch return;
    verve.signalSetStr("wind_ms", wind_str);

    // Update the power-bar fill width.
    const pct: f32 = @min(power / 5000.0 * 100.0, 100.0);
    var pct_buf: [24]u8 = undefined;
    const pct_str = std.fmt.bufPrint(&pct_buf, "height:100%;width:{d:.1}%;background:linear-gradient(90deg,#2563eb,#7c3aed);border-radius:3px;transition:width .4s", .{pct}) catch return;
    const fill_ref: []const u8 = "dash-power-fill";
    if (verve.queryRef(fill_ref)) |handle| {
        verve.setRefAttr(handle, "style", pct_str);
    }
}

/// Scan `json` for the first occurrence of `"key":` and return the numeric
/// value that follows. Returns null if not found or not parseable.
fn extractF32Field(json: []const u8, key: []const u8) ?f32 {
    // Build the search needle: `"key":`
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;

    const pos = std.mem.indexOf(u8, json, needle) orelse return null;
    var rest = json[pos + needle.len ..];

    // Skip whitespace.
    var i: usize = 0;
    while (i < rest.len and rest[i] == ' ') i += 1;
    rest = rest[i..];

    // Collect digits, '.', '-', '+', 'e', 'E'.
    var end: usize = 0;
    while (end < rest.len) : (end += 1) {
        const c = rest[end];
        if (c == '-' or c == '+' or c == '.' or c == 'e' or c == 'E' or
            (c >= '0' and c <= '9')) continue;
        break;
    }
    if (end == 0) return null;

    return std.fmt.parseFloat(f32, rest[0..end]) catch null;
}
