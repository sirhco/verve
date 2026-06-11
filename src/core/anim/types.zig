//! Shared data types for the verve.anim descriptor builders. Pure data,
//! target-agnostic: compiles native (SSR) and wasm32-freestanding (island
//! chunks via the `anim_core` module).

const std = @import("std");

/// Easing curve, identified by name on the wire. The JS interpreter in
/// verve.js owns the runtime math; `ease.zig` ships matching pure-Zig
/// implementations as the parity reference (and for future native use).
pub const Ease = enum {
    linear,
    in_sine,
    out_sine,
    in_out_sine,
    in_quad,
    out_quad,
    in_out_quad,
    in_cubic,
    out_cubic,
    in_out_cubic,
    in_quart,
    out_quart,
    in_out_quart,
    in_quint,
    out_quint,
    in_out_quint,
    in_expo,
    out_expo,
    in_out_expo,
    in_circ,
    out_circ,
    in_out_circ,
    in_back,
    out_back,
    in_out_back,
    in_elastic,
    out_elastic,
    in_out_elastic,
    in_bounce,
    out_bounce,
    in_out_bounce,

    /// Wire name, e.g. `.in_out_sine` -> "inOutSine". Single source of
    /// truth for the JS-side EASE table keys.
    pub fn wireName(self: Ease) []const u8 {
        return switch (self) {
            inline else => |t| comptime camelName(@tagName(t)),
        };
    }
};

fn camelName(comptime snake: []const u8) []const u8 {
    comptime {
        var buf: [snake.len]u8 = undefined;
        var len: usize = 0;
        var up = false;
        for (snake) |c| {
            if (c == '_') {
                up = true;
                continue;
            }
            buf[len] = if (up) std.ascii.toUpper(c) else c;
            up = false;
            len += 1;
        }
        const out = buf[0..len].*;
        return &out;
    }
}

/// Tween direction. `.to` animates from the element's current state to the
/// authored values; `.from` animates from the authored values to the
/// element's current (SSR-rendered) state — the natural primitive for
/// entrance animations, since reduced-motion and JS-off both degrade to
/// exactly the rendered page.
pub const Kind = enum { to, from };

/// What the JS interpreter does for this animation when
/// `prefers-reduced-motion: reduce` matches.
pub const ReducedMotion = enum {
    /// Default: seek to the end state instantly and fire callbacks in order.
    jump_to_end,
    /// Run the animation anyway (e.g. opacity-only fades). Wire: "allow".
    play,
    /// Leave the SSR state untouched; the animation never registers.
    skip,
};

/// A property end-state (start-state for `.from` tweens / `propFrom`).
pub const Value = union(enum) {
    /// Unitless, or the property's default unit (px for lengths, deg for
    /// rotate/skew) applied by the JS interpreter.
    num: f64,
    px: f64,
    pct: f64,
    deg: f64,
    rem: f64,
    /// Raw CSS value emitted verbatim: "50vw", "#ff8800", "blur(4px)".
    /// Hex/rgb colors are normalized to rgba components at serialize time.
    str: []const u8,
    /// Island-only: dynamic-value slot id from `verve.animDyn(...)`.
    /// Rejected at serialize time on the SSR surface
    /// (`error.DynRequiresIsland`).
    dyn: u32,
};

/// Coerce ints, floats, string literals, and `Value` literals uniformly so
/// prop methods accept `t.x(120)`, `t.x(.{ .pct = 50 })`, and
/// `t.prop("filter", "blur(4px)")` alike.
pub fn value(v: anytype) Value {
    const T = @TypeOf(v);
    if (T == Value) return v;
    return switch (@typeInfo(T)) {
        .int, .comptime_int => .{ .num = @as(f64, @floatFromInt(v)) },
        .float, .comptime_float => .{ .num = @as(f64, @floatCast(v)) },
        .pointer => .{ .str = v },
        .@"union" => @as(Value, v),
        .enum_literal, .@"struct" => @as(Value, v),
        else => @compileError("anim value: expected number, string, or anim.Value, got " ++ @typeName(T)),
    };
}

/// Offset animations across the tween's matched targets.
pub const Stagger = struct {
    /// Seconds between successive targets (by distance unit).
    each: f64 = 0,
    /// Alternative: total spread in seconds across all targets (wins over
    /// `each` when set).
    total: ?f64 = null,
    from: From = .start,
    /// Treat target indices as a grid and derive delays from cell distance.
    grid: ?Grid = null,
    /// Restrict grid distance to one axis.
    axis: ?Axis = null,
    /// Distribution easing applied to the normalized delay curve.
    ease: ?Ease = null,

    pub const From = union(enum) {
        start,
        end,
        center,
        /// Outermost targets first, sweeping inward.
        edges,
        index: u32,
    };
    pub const Grid = struct { cols: u32, rows: u32 };
    pub const Axis = enum { x, y };
};

/// Per-frame value interception, applied by the JS interpreter after
/// interpolation and before the style write.
pub const Modifier = struct {
    prop: []const u8,
    op: Op,

    pub const Op = union(enum) {
        snap_to: f64,
        clamp: struct { min: f64, max: f64 },
        /// Wrap into [min, max) — e.g. 0..360 rotation.
        wrap: struct { min: f64, max: f64 },
        /// Island-only: modifier fn slot id from `verve.animModFn(...)`.
        dyn: u32,
    };
};

/// Move a tween's targets along an SVG path (wire key "mp"). Zig samples
/// the path into a uniform-arc-length polyline at serialize time; the JS
/// interpreter only lerps. Path coordinates are written verbatim into the
/// x/y translate slots — px offsets in the same space as `.x()`/`.y()`
/// (for SVG children, CSS px == user units, so a viz `pathD` in the same
/// viewBox traces exactly).
pub const MotionPath = struct {
    pub const Align = enum {
        /// Raw path coordinates written into the translate slots — use
        /// when the path is authored relative to the element.
        none,
        /// Re-base the polyline on its first sample so the motion starts
        /// at the element's current rendered position — use for paths
        /// authored in absolute coordinates.
        start,
    };

    /// SVG path data ("M0,0 C ..."). `verve.viz` edge-path output plugs
    /// in directly.
    path: []const u8,
    /// (`align` is a Zig keyword, hence the name.)
    align_to: Align = .none,
    /// Auto-orient along the tangent (drives the rotate xform channel).
    rotate: bool = false,
    /// Added to the tangent angle when `rotate` is on.
    rotate_offset_deg: f64 = 0,
    /// Fraction of the path to traverse. start > end runs backward.
    start: f64 = 0.0,
    end: f64 = 1.0,
    /// Polyline sample count. 0 = auto (128). Clamped to [2, 512].
    samples: u16 = 0,
};

/// Morph a <path> element's `d` between two authored path strings (wire
/// key "mo"). Both strings are required — SSR cannot read a live DOM
/// attribute, and Zig owns the matching math.
pub const Morph = struct {
    from: []const u8,
    to: []const u8,
};

/// Timeline insertion point (GSAP's position parameter, Zig-shaped).
/// Resolved eagerly at `.add()` time — the wire format carries only
/// absolute start seconds.
pub const Position = union(enum) {
    /// Default: after the previous entry's end.
    end,
    /// Aligned with the previous entry's start (GSAP "<").
    with_prev,
    /// Absolute seconds from timeline start.
    abs: f64,
    /// Offset from the running end: `.{ .rel = -0.2 }` == "-=0.2".
    rel: f64,
    /// At a previously added label.
    label: []const u8,
};

test "ease wire names" {
    try std.testing.expectEqualStrings("linear", Ease.linear.wireName());
    try std.testing.expectEqualStrings("outCubic", Ease.out_cubic.wireName());
    try std.testing.expectEqualStrings("inOutSine", Ease.in_out_sine.wireName());
    try std.testing.expectEqualStrings("inOutElastic", Ease.in_out_elastic.wireName());
}

test "value coercion" {
    try std.testing.expectEqual(@as(f64, 120), value(120).num);
    try std.testing.expectEqual(@as(f64, 0.5), value(0.5).num);
    try std.testing.expectEqual(@as(f64, 50), value(Value{ .pct = 50 }).pct);
    try std.testing.expectEqualStrings("blur(4px)", value("blur(4px)").str);
}
