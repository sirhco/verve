//! Dashboard island — live telemetry for turbine 0.
//!
//! Subscribes to the `metrics` SSE push channel. Each frame is a JSON object:
//!   {"tick":N,"turbines":[{"id":0,"power_kw":X,"rpm":Y,"wind_ms":Z},...]}
//!
//! Maintains a 60-sample rolling ring buffer of power_kw values and patches:
//!   - `<polyline data-ref="dash-power-line">` — line stroke
//!   - `<polygon  data-ref="dash-power-area">` — area fill
//!   - str signals `power_kw`, `rpm`, `wind_ms` — text readouts
//!
//! Coordinate constants MUST match `components.zig` dashChartSsr layout.

const std = @import("std");
const verve = @import("verve");

// Chart layout — must match SSR constants in components.zig.
const PLOT_X0: f32 = 48;
const PLOT_X1: f32 = 580;
const PLOT_Y0: f32 = 160; // bottom (larger y = lower on screen)
const PLOT_Y1: f32 = 20; // top
const POWER_MAX: f32 = 5000;
const RING_LEN: usize = 60;

// Rolling ring buffer for the last 60 power samples.
var ring: [RING_LEN]f32 = [_]f32{0} ** RING_LEN;
var ring_head: usize = 0; // next write position
var ring_fill: usize = 0; // how many samples are valid (0..RING_LEN)

/// Map power → SVG Y pixel.
fn powerToY(power: f32) f32 {
    const frac = @max(0.0, @min(power / POWER_MAX, 1.0));
    return PLOT_Y0 - frac * (PLOT_Y0 - PLOT_Y1);
}

/// Push a new power sample into the ring buffer.
fn ringPush(v: f32) void {
    ring[ring_head] = v;
    ring_head = (ring_head + 1) % RING_LEN;
    if (ring_fill < RING_LEN) ring_fill += 1;
}

/// Return sample i (0 = oldest, ring_fill-1 = newest).
fn ringSample(i: usize) f32 {
    if (ring_fill < RING_LEN) return ring[i];
    return ring[(ring_head + i) % RING_LEN];
}

/// Append "NNN.N" to buf[pos..], return new pos.  Rounds to 1 decimal place.
fn appendF1(buf: []u8, pos: usize, v: f32) usize {
    const s = std.fmt.bufPrint(buf[pos..], "{d:.1}", .{v}) catch return pos;
    return pos + s.len;
}

/// Append a single ASCII char.
fn appendChar(buf: []u8, pos: usize, c: u8) usize {
    if (pos < buf.len) buf[pos] = c;
    return pos + 1;
}

/// Build the SVG `points` attribute string for RING_LEN samples into `buf`.
/// Returns the written slice.
fn buildPoints(buf: []u8, n: usize) []const u8 {
    var pos: usize = 0;
    const denom: f32 = @floatFromInt(if (n > 1) n - 1 else 1);
    for (0..n) |i| {
        const fi: f32 = @floatFromInt(i);
        const x = PLOT_X0 + fi / denom * (PLOT_X1 - PLOT_X0);
        const y = powerToY(ringSample(i));
        if (i > 0) pos = appendChar(buf, pos, ' ');
        pos = appendF1(buf, pos, x);
        pos = appendChar(buf, pos, ',');
        pos = appendF1(buf, pos, y);
    }
    return buf[0..pos];
}

/// Build the SVG `points` attribute string for the filled area polygon.
/// Same as buildPoints but appends the two baseline corners.
fn buildAreaPoints(buf: []u8, n: usize) []const u8 {
    var pos: usize = 0;
    const denom: f32 = @floatFromInt(if (n > 1) n - 1 else 1);
    for (0..n) |i| {
        const fi: f32 = @floatFromInt(i);
        const x = PLOT_X0 + fi / denom * (PLOT_X1 - PLOT_X0);
        const y = powerToY(ringSample(i));
        if (i > 0) pos = appendChar(buf, pos, ' ');
        pos = appendF1(buf, pos, x);
        pos = appendChar(buf, pos, ',');
        pos = appendF1(buf, pos, y);
    }
    if (n > 0) {
        // right-bottom corner
        const x_last = PLOT_X0 + @as(f32, @floatFromInt(n - 1)) / denom * (PLOT_X1 - PLOT_X0);
        pos = appendChar(buf, pos, ' ');
        pos = appendF1(buf, pos, x_last);
        pos = appendChar(buf, pos, ',');
        pos = appendF1(buf, pos, PLOT_Y0);
        // left-bottom corner
        pos = appendChar(buf, pos, ' ');
        pos = appendF1(buf, pos, PLOT_X0);
        pos = appendChar(buf, pos, ',');
        pos = appendF1(buf, pos, PLOT_Y0);
    }
    return buf[0..pos];
}

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

// Static buffers for point strings — sized for RING_LEN × ~14 chars + 2 corners.
var pts_buf: [RING_LEN * 16]u8 = undefined;
var area_buf: [(RING_LEN + 2) * 16]u8 = undefined;

/// Called by the bridge when a metrics frame arrives (~2 Hz).
export fn metrics_apply(ptr: u32, len: u32) void {
    if (len == 0) return;
    const data: []const u8 = @as([*]const u8, @ptrFromInt(@as(usize, ptr)))[0..len];

    const power = extractF32Field(data, "power_kw") orelse return;
    const rpm_val = extractF32Field(data, "rpm") orelse return;
    const wind_val = extractF32Field(data, "wind_ms") orelse return;

    // Push new sample into ring buffer.
    ringPush(power);

    // Update text signals.
    var buf: [32]u8 = undefined;
    const pw_str = std.fmt.bufPrint(&buf, "{d:.0}", .{power}) catch return;
    verve.signalSetStr("power_kw", pw_str);

    var buf2: [32]u8 = undefined;
    const rpm_str = std.fmt.bufPrint(&buf2, "{d:.1}", .{rpm_val}) catch return;
    verve.signalSetStr("rpm", rpm_str);

    var buf3: [32]u8 = undefined;
    const wind_str = std.fmt.bufPrint(&buf3, "{d:.1}", .{wind_val}) catch return;
    verve.signalSetStr("wind_ms", wind_str);

    const n = ring_fill;

    // Patch the polyline stroke.
    const pts = buildPoints(&pts_buf, n);
    const line_ref: []const u8 = "dash-power-line";
    if (verve.queryRef(line_ref)) |h| {
        verve.setRefAttr(h, "points", pts);
    }

    // Patch the area fill polygon.
    const area_pts = buildAreaPoints(&area_buf, n);
    const area_ref: []const u8 = "dash-power-area";
    if (verve.queryRef(area_ref)) |h| {
        verve.setRefAttr(h, "points", area_pts);
    }
}

/// Scan `json` for the first occurrence of `"key":` and return the numeric
/// value that follows. Returns null if not found or not parseable.
fn extractF32Field(json: []const u8, key: []const u8) ?f32 {
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
