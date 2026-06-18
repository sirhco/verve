//! Dashboard island — live telemetry for the SELECTED turbine.
//!
//! Subscribes to the `metrics` SSE push channel. Each frame is a JSON object:
//!   {"tick":N,"turbines":[{"id":0,"power_kw":X,"rpm":Y,"wind_ms":Z},...]}
//! — every frame already carries ALL four turbines, so a selection change needs
//! no server round-trip: we just rescope which `"id":N` object we read.
//!
//! Cross-island selection: FarmScene picks a turbine and dispatches a bubbling
//! DOM CustomEvent("mc-select"); the page <script> in components.zig forwards
//! the id by clicking a hidden proxy element inside THIS island that carries
//! `z-on-click="dashboard_on_select"` + `data-turbine="N"`. The named-click
//! delegation runs the export under Dashboard's vid, so it sets ITS OWN signals
//! and repaints — the canonical in-framework cross-island path (no new core
//! reactivity, no signal namespace crossing).
//!
//! Maintains a 60-sample rolling ring buffer of power_kw values and patches:
//!   - `<polyline data-ref="dash-power-line">` — line stroke
//!   - `<polygon  data-ref="dash-power-area">` — area fill
//!   - str signals `power_kw`, `rpm`, `wind_ms` — text readouts
//!   - str signal `selected_label` — "Turbine N" heading
//!
//! Coordinate constants MUST match `components.zig` dashChartSsr layout.

const std = @import("std");
const verve = @import("verve");
const anim = verve.anim;

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

// Currently selected turbine id (0..3); driven by dashboard_on_select.
var selected: u32 = 0;

// Cache of the most recent metrics frame so a selection change can repaint the
// chart/gauge/readout instantly without waiting for the next ~2 Hz frame.
var last_frame: [4096]u8 = undefined;
var last_frame_len: usize = 0;

// Count-up animation: ramp the readout numbers from their previous value to the
// new turbine's value over ~0.5 s on a selection change. Composes the existing
// timer primitive (no new anim-engine surface).
const COUNT_MS: u32 = 500;
const COUNT_STEP_MS: u32 = 25;
var count_timer: u32 = 0;
var count_t: u32 = 0; // elapsed ms
var count_from_power: f32 = 0;
var count_from_rpm: f32 = 0;
var count_from_wind: f32 = 0;
var count_to_power: f32 = 0;
var count_to_rpm: f32 = 0;
var count_to_wind: f32 = 0;

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

/// Append a single ASCII char.  Clamps pos so overflow cannot silently corrupt output.
fn appendChar(buf: []u8, pos: usize, c: u8) usize {
    if (pos < buf.len) {
        buf[pos] = c;
        return pos + 1;
    }
    return pos; // buffer full — stop advancing
}

/// Write the coordinate pairs "x0,y0 x1,y1 …" for n ring samples into buf[pos..].
/// Returns the updated pos.
fn appendCoords(buf: []u8, pos_in: usize, n: usize) usize {
    var pos = pos_in;
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
    return pos;
}

/// Build the SVG `points` attribute string for RING_LEN samples into `buf`.
/// Returns the written slice.
fn buildPoints(buf: []u8, n: usize) []const u8 {
    const pos = appendCoords(buf, 0, n);
    return buf[0..pos];
}

/// Build the SVG `points` attribute string for the filled area polygon.
/// Same as buildPoints but appends the two baseline corners.
fn buildAreaPoints(buf: []u8, n: usize) []const u8 {
    var pos = appendCoords(buf, 0, n);
    if (n > 0) {
        const denom: f32 = @floatFromInt(if (n > 1) n - 1 else 1);
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
    verve.registerStr("selected_label", "Turbine 0");
    // Subscribe to the metrics push channel.
    _ = verve.pushSubscribe("metrics", "Dashboard", "metrics_apply", root_id);
}

// Static buffers for point strings — sized for RING_LEN × ~14 chars + 2 corners.
var pts_buf: [RING_LEN * 16]u8 = undefined;
var area_buf: [(RING_LEN + 2) * 16]u8 = undefined;

// Static backing for the string signals. A string Signal STORES the slice it is
// set with (no copy — core/signal.zig), so the bytes must outlive the call.
// Module-level statics keep them valid across later re-renders; stack buffers
// would dangle and later reads would show garbage.
var label_buf: [16]u8 = undefined;
var pw_buf: [32]u8 = undefined;
var rpm_buf: [32]u8 = undefined;
var wind_buf: [32]u8 = undefined;

/// Called by the bridge when a metrics frame arrives (~2 Hz). Caches the frame
/// then repaints the SELECTED turbine.
export fn metrics_apply(ptr: u32, len: u32) void {
    if (len == 0) return;
    const data: []const u8 = @as([*]const u8, @ptrFromInt(@as(usize, ptr)))[0..len];

    // Cache for instant repaint on a selection change.
    last_frame_len = @min(data.len, last_frame.len);
    @memcpy(last_frame[0..last_frame_len], data[0..last_frame_len]);

    const power = extractF32Field(data, "power_kw") orelse return;
    ringPush(power);
    setSelectedLabel(); // keep the heading in sync with `selected`
    repaintReadout(data, true);
    repaintChart();
}

/// Set the text signals from `data` for the selected turbine. When `live` the
/// values are written directly; on a selection change the caller instead seeds a
/// count-up so the readout ramps to the new turbine's values.
fn repaintReadout(data: []const u8, live: bool) void {
    const power = extractF32Field(data, "power_kw") orelse return;
    const rpm_val = extractF32Field(data, "rpm") orelse return;
    const wind_val = extractF32Field(data, "wind_ms") orelse return;
    if (live) {
        setReadout(power, rpm_val, wind_val);
    }
}

/// Write the `selected_label` heading from the current `selected` id. Driven
/// from the metrics frame path too so the heading always tracks `selected`
/// under the same (working) vid scope the readout signals use.
fn setSelectedLabel() void {
    const lbl_str = std.fmt.bufPrint(&label_buf, "Turbine {d}", .{selected}) catch return;
    verve.signalSetStr("selected_label", lbl_str);
}

/// Write the three readout signals from numeric values. Uses module-level
/// backing buffers because the string Signal stores the slice (see note above).
fn setReadout(power: f32, rpm_val: f32, wind_val: f32) void {
    const pw_str = std.fmt.bufPrint(&pw_buf, "{d:.0}", .{power}) catch return;
    verve.signalSetStr("power_kw", pw_str);

    const rpm_str = std.fmt.bufPrint(&rpm_buf, "{d:.1}", .{rpm_val}) catch return;
    verve.signalSetStr("rpm", rpm_str);

    const wind_str = std.fmt.bufPrint(&wind_buf, "{d:.1}", .{wind_val}) catch return;
    verve.signalSetStr("wind_ms", wind_str);
}

/// Repaint the rolling power chart polyline + area from the ring buffer.
fn repaintChart() void {
    const n = ring_fill;
    const pts = buildPoints(&pts_buf, n);
    if (verve.queryRef(@as([]const u8, "dash-power-line"))) |h|
        verve.setRefAttr(h, "points", pts);
    const area_pts = buildAreaPoints(&area_buf, n);
    if (verve.queryRef(@as([]const u8, "dash-power-area"))) |h|
        verve.setRefAttr(h, "points", area_pts);
}

// ── selection (cross-island) ────────────────────────────────────────────────

/// One count-up tick: lerp the readout values toward the target. Cleared once
/// elapsed ≥ COUNT_MS (final values written exactly).
fn countTick() void {
    count_t += COUNT_STEP_MS;
    if (count_t >= COUNT_MS) {
        setReadout(count_to_power, count_to_rpm, count_to_wind);
        verve.clearTimer(count_timer);
        count_timer = 0;
        return;
    }
    const f: f32 = @as(f32, @floatFromInt(count_t)) / @as(f32, @floatFromInt(COUNT_MS));
    // ease-out cubic for a settled feel
    const e = 1.0 - std.math.pow(f32, 1.0 - f, 3.0);
    setReadout(
        count_from_power + (count_to_power - count_from_power) * e,
        count_from_rpm + (count_to_rpm - count_from_rpm) * e,
        count_from_wind + (count_to_wind - count_from_wind) * e,
    );
}

// Per-turbine select exports. The page glue clicks the hidden proxy whose
// z-on-click names the matching export, so the id rides the EXPORT NAME — no
// reliance on the shared event-dataset scratch buffer (which other dispatches,
// e.g. live metrics frames, can overwrite between stage and read). Each runs
// under THIS island's vid via the named-click delegation in verve.js.
export fn dashboard_select_0() void {
    selectTurbine(0);
}
export fn dashboard_select_1() void {
    selectTurbine(1);
}
export fn dashboard_select_2() void {
    selectTurbine(2);
}
export fn dashboard_select_3() void {
    selectTurbine(3);
}

/// Switch the selected turbine, update the heading, reset the chart history, and
/// animate the swap (FLIP panel + count-up). No-op when re-selecting the same
/// turbine.
fn selectTurbine(id: u32) void {
    if (id > 3 or id == selected) return;

    // FLIP-capture the dashboard panel before its content changes so the swap
    // eases instead of jumping.
    const flip = verve.flipCapture(".mc-dashboard");

    selected = id;

    // Update the heading. The string Signal stores the slice it is set with
    // (no copy — core/signal.zig), so the backing bytes must outlive the call;
    // label_buf is module-level so the value stays valid for later re-renders.
    const lbl_str = std.fmt.bufPrint(&label_buf, "Turbine {d}", .{id}) catch "Turbine ?";
    verve.signalSetStr("selected_label", lbl_str);
    ring_head = 0;
    ring_fill = 0;

    if (flip) |st|
        _ = verve.flipPlay(st, .{ .duration = 0.4, .ease = .out_cubic }, .{});

    // Seed a count-up from 0 to the new turbine's live values, then repaint the
    // chart from the cached frame.
    if (last_frame_len != 0) {
        const data = last_frame[0..last_frame_len];
        const power = extractF32Field(data, "power_kw") orelse return;
        const rpm_val = extractF32Field(data, "rpm") orelse return;
        const wind_val = extractF32Field(data, "wind_ms") orelse return;

        count_from_power = 0;
        count_from_rpm = 0;
        count_from_wind = 0;
        count_to_power = power;
        count_to_rpm = rpm_val;
        count_to_wind = wind_val;
        count_t = 0;
        if (count_timer != 0) verve.clearTimer(count_timer);
        count_timer = verve.setInterval(COUNT_STEP_MS, &countTick);

        // Prime the chart with the new turbine's current sample.
        ringPush(power);
        repaintChart();
    }
}

/// Find the JSON object for the SELECTED turbine in the frame and return a slice
/// covering just that object (from `{` to the matching `}`).
/// Wire format: {"tick":N,"turbines":[{"id":0,...},{"id":1,...},...]}
fn findTurbineSel(json: []const u8) ?[]const u8 {
    // Look for `"id":<selected>` — the selected turbine's marker.
    var mbuf: [16]u8 = undefined;
    const marker = std.fmt.bufPrint(&mbuf, "\"id\":{d}", .{selected}) catch return null;
    const mid = std.mem.indexOf(u8, json, marker) orelse return null;

    // Walk backwards to find the opening `{` of this object.
    var start = mid;
    while (start > 0) : (start -= 1) {
        if (json[start] == '{') break;
    }
    if (json[start] != '{') return null;

    // Walk forward to find the matching `}`.
    var depth: usize = 0;
    var end = start;
    while (end < json.len) : (end += 1) {
        if (json[end] == '{') depth += 1;
        if (json[end] == '}') {
            depth -= 1;
            if (depth == 0) return json[start .. end + 1];
        }
    }
    return null;
}

/// Scan a JSON object slice for `"key":` and return the numeric value that follows.
/// Allocation-free, hand-rolled — consistent with the surrounding code style.
fn extractF32Field(json: []const u8, key: []const u8) ?f32 {
    // Scope to the selected turbine's object to avoid matching other turbines.
    const obj = findTurbineSel(json) orelse return null;

    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;

    const pos = std.mem.indexOf(u8, obj, needle) orelse return null;
    var rest = obj[pos + needle.len ..];

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
