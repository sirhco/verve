//! SVG path math core for MotionPath + MorphSVG. Pure, target-agnostic,
//! freestanding-safe: own minimal Vec2 (no viz dependency — anim_core and
//! viz_core are separate chunk modules), allocator always a parameter,
//! arena semantics, Writer.fixed only (no Writer.Allocating — chunk
//! fn-table hazard).
//!
//! Everything normalizes to cubic Bézier segments at parse time. The JS
//! interpreter receives only pre-computed data: MotionPath ships a
//! uniform-arc-length polyline [x, y, angle°] and MorphSVG ships two
//! equal-length control-point arrays — no SVG parsing or Bézier math
//! crosses the wire.
//!
//! Frozen contracts (goldened in serialize.zig, mirrored by verve.js):
//! - line -> cubic places controls at exactly 1/3 and 2/3
//! - motionSamples angles are UNWRAPPED: each successive angle is within
//!   180° of its predecessor (a 359°->1° tangent crossing emits 361)

const std = @import("std");

pub const Vec2 = struct {
    x: f64 = 0,
    y: f64 = 0,

    fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
    fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }
    fn scale(a: Vec2, k: f64) Vec2 {
        return .{ .x = a.x * k, .y = a.y * k };
    }
    fn dist(a: Vec2, b: Vec2) f64 {
        return @sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
    }
    fn mid(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2 };
    }
};

/// One cubic Bézier segment.
pub const Segment = struct {
    p0: Vec2,
    c1: Vec2,
    c2: Vec2,
    p1: Vec2,
};

pub const Subpath = struct {
    segments: []Segment,
    closed: bool,
};

pub const PathData = struct {
    subpaths: []Subpath,
};

pub const ParseError = error{
    PathMustStartWithMove,
    UnexpectedCommand,
    ExpectedNumber,
    ExpectedFlag,
    OutOfMemory,
};

// ---- normalization ---------------------------------------------------------

/// Exact degree elevation of a line: controls at 1/3 and 2/3 (frozen
/// contract — morph goldens depend on it).
fn lineToCubic(p: Vec2, q: Vec2) Segment {
    const d = q.sub(p);
    return .{
        .p0 = p,
        .c1 = p.add(d.scale(1.0 / 3.0)),
        .c2 = p.add(d.scale(2.0 / 3.0)),
        .p1 = q,
    };
}

/// Exact quadratic -> cubic elevation.
fn quadToCubic(p0: Vec2, q1: Vec2, p1: Vec2) Segment {
    return .{
        .p0 = p0,
        .c1 = p0.add(q1.sub(p0).scale(2.0 / 3.0)),
        .c2 = p1.add(q1.sub(p1).scale(2.0 / 3.0)),
        .p1 = p1,
    };
}

// ---- parser ----------------------------------------------------------------

const Parser = struct {
    alloc: std.mem.Allocator,
    d: []const u8,
    i: usize = 0,
    cur: Vec2 = .{},
    start: Vec2 = .{},
    last_cmd: u8 = 0,
    last_c2: Vec2 = .{},
    last_q1: Vec2 = .{},
    segs: std.ArrayList(Segment) = .empty,
    subs: std.ArrayList(Subpath) = .empty,
    closed: bool = false,

    fn skipSep(self: *Parser) void {
        while (self.i < self.d.len) : (self.i += 1) {
            const c = self.d[self.i];
            if (c != ' ' and c != '\t' and c != '\n' and c != '\r' and c != ',') break;
        }
    }

    fn atNumberStart(self: *Parser) bool {
        if (self.i >= self.d.len) return false;
        const c = self.d[self.i];
        return (c >= '0' and c <= '9') or c == '-' or c == '+' or c == '.';
    }

    /// SVG number grammar: sign, digits, at most one dot, optional
    /// exponent. Stops before a second dot so "1.5.5" yields 1.5 then .5.
    fn readNumber(self: *Parser) ParseError!f64 {
        self.skipSep();
        const s = self.i;
        var j = self.i;
        if (j < self.d.len and (self.d[j] == '-' or self.d[j] == '+')) j += 1;
        var seen_dot = false;
        var seen_digit = false;
        while (j < self.d.len) : (j += 1) {
            const c = self.d[j];
            if (c >= '0' and c <= '9') {
                seen_digit = true;
            } else if (c == '.' and !seen_dot) {
                seen_dot = true;
            } else {
                break;
            }
        }
        if (!seen_digit) return error.ExpectedNumber;
        if (j < self.d.len and (self.d[j] == 'e' or self.d[j] == 'E')) {
            var k = j + 1;
            if (k < self.d.len and (self.d[k] == '-' or self.d[k] == '+')) k += 1;
            var exp_digit = false;
            while (k < self.d.len and self.d[k] >= '0' and self.d[k] <= '9') : (k += 1) {
                exp_digit = true;
            }
            if (exp_digit) j = k;
        }
        const v = std.fmt.parseFloat(f64, self.d[s..j]) catch return error.ExpectedNumber;
        self.i = j;
        return v;
    }

    /// Arc flags consume exactly one '0'/'1' char — handles the
    /// compressed form "a1 1 0 011 1".
    fn readFlag(self: *Parser) ParseError!bool {
        self.skipSep();
        if (self.i >= self.d.len) return error.ExpectedFlag;
        const c = self.d[self.i];
        if (c != '0' and c != '1') return error.ExpectedFlag;
        self.i += 1;
        return c == '1';
    }

    fn readPoint(self: *Parser, relative: bool) ParseError!Vec2 {
        const x = try self.readNumber();
        const y = try self.readNumber();
        if (relative) return .{ .x = self.cur.x + x, .y = self.cur.y + y };
        return .{ .x = x, .y = y };
    }

    fn push(self: *Parser, seg: Segment) ParseError!void {
        try self.segs.append(self.alloc, seg);
    }

    fn flush(self: *Parser) ParseError!void {
        if (self.segs.items.len > 0) {
            try self.subs.append(self.alloc, .{
                .segments = try self.segs.toOwnedSlice(self.alloc),
                .closed = self.closed,
            });
        } else {
            self.segs.clearRetainingCapacity();
        }
        self.closed = false;
    }
};

pub fn parse(alloc: std.mem.Allocator, d: []const u8) ParseError!PathData {
    var p: Parser = .{ .alloc = alloc, .d = d };
    p.skipSep();
    if (p.i >= p.d.len) return error.PathMustStartWithMove;
    if (p.d[p.i] != 'M' and p.d[p.i] != 'm') return error.PathMustStartWithMove;

    while (true) {
        p.skipSep();
        if (p.i >= p.d.len) break;

        var cmd = p.d[p.i];
        if ((cmd >= 'A' and cmd <= 'Z') or (cmd >= 'a' and cmd <= 'z')) {
            p.i += 1;
        } else if (p.atNumberStart() and p.last_cmd != 0) {
            // implicit repeat; a repeated M becomes L (m -> l) per spec
            cmd = switch (p.last_cmd) {
                'M' => 'L',
                'm' => 'l',
                else => p.last_cmd,
            };
        } else {
            return error.UnexpectedCommand;
        }

        const rel = cmd >= 'a';
        const prev_cmd = p.last_cmd;
        switch (cmd) {
            'M', 'm' => {
                try p.flush();
                const pt = try p.readPoint(rel);
                p.cur = pt;
                p.start = pt;
            },
            'L', 'l' => {
                const q = try p.readPoint(rel);
                try p.push(lineToCubic(p.cur, q));
                p.cur = q;
            },
            'H', 'h' => {
                const x = try p.readNumber();
                const q: Vec2 = .{ .x = if (rel) p.cur.x + x else x, .y = p.cur.y };
                try p.push(lineToCubic(p.cur, q));
                p.cur = q;
            },
            'V', 'v' => {
                const y = try p.readNumber();
                const q: Vec2 = .{ .x = p.cur.x, .y = if (rel) p.cur.y + y else y };
                try p.push(lineToCubic(p.cur, q));
                p.cur = q;
            },
            'C', 'c' => {
                const c1 = try p.readPoint(rel);
                const c2 = try p.readPoint(rel);
                const p1 = try p.readPoint(rel);
                try p.push(.{ .p0 = p.cur, .c1 = c1, .c2 = c2, .p1 = p1 });
                p.last_c2 = c2;
                p.cur = p1;
            },
            'S', 's' => {
                const reflect = prev_cmd == 'C' or prev_cmd == 'c' or prev_cmd == 'S' or prev_cmd == 's';
                const c1: Vec2 = if (reflect)
                    .{ .x = 2 * p.cur.x - p.last_c2.x, .y = 2 * p.cur.y - p.last_c2.y }
                else
                    p.cur;
                const c2 = try p.readPoint(rel);
                const p1 = try p.readPoint(rel);
                try p.push(.{ .p0 = p.cur, .c1 = c1, .c2 = c2, .p1 = p1 });
                p.last_c2 = c2;
                p.cur = p1;
            },
            'Q', 'q' => {
                const q1 = try p.readPoint(rel);
                const p1 = try p.readPoint(rel);
                try p.push(quadToCubic(p.cur, q1, p1));
                p.last_q1 = q1;
                p.cur = p1;
            },
            'T', 't' => {
                const reflect = prev_cmd == 'Q' or prev_cmd == 'q' or prev_cmd == 'T' or prev_cmd == 't';
                const q1: Vec2 = if (reflect)
                    .{ .x = 2 * p.cur.x - p.last_q1.x, .y = 2 * p.cur.y - p.last_q1.y }
                else
                    p.cur;
                const p1 = try p.readPoint(rel);
                try p.push(quadToCubic(p.cur, q1, p1));
                p.last_q1 = q1;
                p.cur = p1;
            },
            'A', 'a' => {
                const rx = try p.readNumber();
                const ry = try p.readNumber();
                const rot_deg = try p.readNumber();
                const large = try p.readFlag();
                const sweep = try p.readFlag();
                const p1 = try p.readPoint(rel);
                try arcToCubics(&p, p.cur, p1, rx, ry, rot_deg, large, sweep);
                p.cur = p1;
            },
            'Z', 'z' => {
                if (p.cur.x != p.start.x or p.cur.y != p.start.y) {
                    try p.push(lineToCubic(p.cur, p.start));
                }
                p.closed = true;
                p.cur = p.start;
                try p.flush();
            },
            else => return error.UnexpectedCommand,
        }
        p.last_cmd = cmd;
    }
    try p.flush();
    return .{ .subpaths = try p.subs.toOwnedSlice(p.alloc) };
}

/// SVG spec F.6.5 / F.6.6: endpoint -> center parameterization, radii
/// correction, then split into <=90° slices each approximated by one
/// cubic with control distance k = 4/3 * tan(delta/4). Max radial error
/// of the 90° approximation is ~2.7e-4 * r.
fn arcToCubics(p: *Parser, p0: Vec2, p1: Vec2, rx_in: f64, ry_in: f64, rot_deg: f64, large: bool, sweep: bool) ParseError!void {
    if (p0.x == p1.x and p0.y == p1.y) return;
    var rx = @abs(rx_in);
    var ry = @abs(ry_in);
    if (rx == 0 or ry == 0) {
        try p.push(lineToCubic(p0, p1));
        return;
    }
    const phi = rot_deg * std.math.pi / 180.0;
    const cos_phi = @cos(phi);
    const sin_phi = @sin(phi);

    const dx = (p0.x - p1.x) / 2;
    const dy = (p0.y - p1.y) / 2;
    const x1p = cos_phi * dx + sin_phi * dy;
    const y1p = -sin_phi * dx + cos_phi * dy;

    // F.6.6 radii correction
    const lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if (lam > 1) {
        const s = @sqrt(lam);
        rx *= s;
        ry *= s;
    }

    const num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
    const den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
    // clamp radicand at 0 — float noise after radii correction
    var coef = @sqrt(@max(num, 0) / den);
    if (large == sweep) coef = -coef;
    const cxp = coef * (rx * y1p / ry);
    const cyp = coef * (-ry * x1p / rx);

    const cx = cos_phi * cxp - sin_phi * cyp + (p0.x + p1.x) / 2;
    const cy = sin_phi * cxp + cos_phi * cyp + (p0.y + p1.y) / 2;

    const th1 = std.math.atan2((y1p - cyp) / ry, (x1p - cxp) / rx);
    const th2 = std.math.atan2((-y1p - cyp) / ry, (-x1p - cxp) / rx);
    var dth = th2 - th1;
    if (!sweep and dth > 0) dth -= 2 * std.math.pi;
    if (sweep and dth < 0) dth += 2 * std.math.pi;

    const n: usize = @intFromFloat(@ceil(@abs(dth) / (std.math.pi / 2.0)));
    const slices = @max(n, 1);
    const step = dth / @as(f64, @floatFromInt(slices));
    const k = (4.0 / 3.0) * @tan(step / 4.0);

    const point = struct {
        fn at(cx_: f64, cy_: f64, rx_: f64, ry_: f64, cp: f64, sp: f64, th: f64) Vec2 {
            const ex = rx_ * @cos(th);
            const ey = ry_ * @sin(th);
            return .{ .x = cx_ + cp * ex - sp * ey, .y = cy_ + sp * ex + cp * ey };
        }
        fn deriv(rx_: f64, ry_: f64, cp: f64, sp: f64, th: f64) Vec2 {
            const ex = -rx_ * @sin(th);
            const ey = ry_ * @cos(th);
            return .{ .x = cp * ex - sp * ey, .y = sp * ex + cp * ey };
        }
    };

    var s: usize = 0;
    while (s < slices) : (s += 1) {
        const th_a = th1 + step * @as(f64, @floatFromInt(s));
        const th_b = th_a + step;
        const pa = point.at(cx, cy, rx, ry, cos_phi, sin_phi, th_a);
        const pb = point.at(cx, cy, rx, ry, cos_phi, sin_phi, th_b);
        const da = point.deriv(rx, ry, cos_phi, sin_phi, th_a);
        const db = point.deriv(rx, ry, cos_phi, sin_phi, th_b);
        try p.push(.{
            .p0 = pa,
            .c1 = pa.add(da.scale(k)),
            .c2 = pb.sub(db.scale(k)),
            .p1 = pb,
        });
    }
}

// ---- evaluation + arc-length LUT -------------------------------------------

fn evalCubic(s: Segment, t: f64) Vec2 {
    const it = 1 - t;
    const a = it * it * it;
    const b = 3 * it * it * t;
    const c = 3 * it * t * t;
    const d = t * t * t;
    return .{
        .x = a * s.p0.x + b * s.c1.x + c * s.c2.x + d * s.p1.x,
        .y = a * s.p0.y + b * s.c1.y + c * s.c2.y + d * s.p1.y,
    };
}

fn evalDeriv(s: Segment, t: f64) Vec2 {
    const it = 1 - t;
    return .{
        .x = 3 * it * it * (s.c1.x - s.p0.x) + 6 * it * t * (s.c2.x - s.c1.x) + 3 * t * t * (s.p1.x - s.c2.x),
        .y = 3 * it * it * (s.c1.y - s.p0.y) + 6 * it * t * (s.c2.y - s.c1.y) + 3 * t * t * (s.p1.y - s.c2.y),
    };
}

pub const Sample = struct {
    x: f64,
    y: f64,
    angle_deg: f64,
};

const steps_per_seg = 16;

pub const ArcLut = struct {
    /// Flattened across subpaths in parse order.
    segs: []const Segment,
    /// Cumulative chord lengths; len = segs.len * steps_per_seg + 1.
    cum: []f64,
    total: f64,
};

fn flattenSegments(alloc: std.mem.Allocator, path: *const PathData) ![]Segment {
    var n: usize = 0;
    for (path.subpaths) |sp| n += sp.segments.len;
    const out = try alloc.alloc(Segment, n);
    var i: usize = 0;
    for (path.subpaths) |sp| {
        @memcpy(out[i .. i + sp.segments.len], sp.segments);
        i += sp.segments.len;
    }
    return out;
}

pub fn buildLut(alloc: std.mem.Allocator, path: *const PathData) error{ EmptyPath, OutOfMemory }!ArcLut {
    const segs = try flattenSegments(alloc, path);
    if (segs.len == 0) return error.EmptyPath;
    const cum = try alloc.alloc(f64, segs.len * steps_per_seg + 1);
    cum[0] = 0;
    var acc: f64 = 0;
    for (segs, 0..) |s, si| {
        var prev = s.p0;
        var i: usize = 1;
        while (i <= steps_per_seg) : (i += 1) {
            const t = @as(f64, @floatFromInt(i)) / steps_per_seg;
            const pt = evalCubic(s, t);
            acc += prev.dist(pt);
            cum[si * steps_per_seg + i] = acc;
            prev = pt;
        }
    }
    return .{ .segs = segs, .cum = cum, .total = acc };
}

/// Position + tangent angle at arc-length fraction `u` (clamped 0..1).
pub fn sampleAt(lut: *const ArcLut, u_in: f64) Sample {
    const u = @max(0.0, @min(u_in, 1.0));
    if (lut.total == 0) {
        const p = lut.segs[0].p0;
        return .{ .x = p.x, .y = p.y, .angle_deg = 0 };
    }
    const target = u * lut.total;
    // binary search: first index with cum[idx] >= target
    var lo: usize = 0;
    var hi: usize = lut.cum.len - 1;
    while (lo < hi) {
        const m = (lo + hi) / 2;
        if (lut.cum[m] < target) lo = m + 1 else hi = m;
    }
    const idx = @max(lo, 1);
    const seg_i = @min((idx - 1) / steps_per_seg, lut.segs.len - 1);
    const station = idx - 1 - seg_i * steps_per_seg; // chord index within segment
    const c0 = lut.cum[idx - 1];
    const c1 = lut.cum[idx];
    const frac = if (c1 > c0) (target - c0) / (c1 - c0) else 0;
    const t = (@as(f64, @floatFromInt(station)) + frac) / steps_per_seg;
    const s = lut.segs[seg_i];
    const pos = evalCubic(s, t);
    var d = evalDeriv(s, t);
    if (d.x == 0 and d.y == 0) {
        // cusp / degenerate control layout: secant fallback
        const t0 = @max(0.0, t - 1e-4);
        const t1 = @min(1.0, t + 1e-4);
        d = evalCubic(s, t1).sub(evalCubic(s, t0));
    }
    const angle = if (d.x == 0 and d.y == 0) 0 else std.math.atan2(d.y, d.x) * 180.0 / std.math.pi;
    return .{ .x = pos.x, .y = pos.y, .angle_deg = angle };
}

/// Uniform arc-length polyline over the [start_u, end_u] window
/// (start_u > end_u runs the path backward). Angles are UNWRAPPED: each
/// successive angle shifted by ±360k to land within 180° of its
/// predecessor — the JS interpreter lerps raw values, so 359°->1° must
/// arrive as 359->361. `n` clamped to >= 2.
pub fn motionSamples(
    alloc: std.mem.Allocator,
    path: *const PathData,
    n_in: usize,
    start_u: f64,
    end_u: f64,
) error{ EmptyPath, OutOfMemory }![]Sample {
    var lut = try buildLut(alloc, path);
    const n = @max(n_in, 2);
    const out = try alloc.alloc(Sample, n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const f = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n - 1));
        const u = start_u + (end_u - start_u) * f;
        out[i] = sampleAt(&lut, u);
        if (i > 0) {
            // unwrap relative to predecessor
            var a = out[i].angle_deg;
            const prev = out[i - 1].angle_deg;
            while (a - prev > 180) a -= 360;
            while (a - prev < -180) a += 360;
            out[i].angle_deg = a;
        }
    }
    return out;
}

/// Re-base a sampled polyline on its first sample (MotionPath
/// `.align = .start`): every position shifts by -samples[0], so the
/// motion starts at the element's current spot and follows the path's
/// SHAPE. Works for windowed and reversed sample runs alike — index 0
/// is always the motion's starting point. Angles untouched.
pub fn alignSamplesToStart(samples: []Sample) void {
    if (samples.len == 0) return;
    const ox = samples[0].x;
    const oy = samples[0].y;
    for (samples) |*s| {
        s.x -= ox;
        s.y -= oy;
    }
}

pub fn totalLength(alloc: std.mem.Allocator, path: *const PathData) !f64 {
    const lut = try buildLut(alloc, path);
    return lut.total;
}

// ---- morph preprocessing ----------------------------------------------------

pub const MorphOpts = struct {
    /// Cyclic-offset alignment for closed pairs (min sum of squared p0
    /// distances).
    rotate_align: bool = true,
    /// Flip winding of `to` when signed areas disagree (closed pairs).
    auto_reverse: bool = true,
};

pub const MorphSubpath = struct {
    /// 1 + 3n points: p0, then (c1, c2, p1) per segment. a.len == b.len.
    a: []Vec2,
    b: []Vec2,
    closed: bool,
};

pub const MorphPair = struct {
    subpaths: []MorphSubpath,
};

fn segLength(s: Segment) f64 {
    var prev = s.p0;
    var acc: f64 = 0;
    var i: usize = 1;
    while (i <= steps_per_seg) : (i += 1) {
        const pt = evalCubic(s, @as(f64, @floatFromInt(i)) / steps_per_seg);
        acc += prev.dist(pt);
        prev = pt;
    }
    return acc;
}

/// De Casteljau split at t = 0.5 — left+right exactly reproduce the curve.
fn splitSegment(s: Segment) [2]Segment {
    const m01 = Vec2.mid(s.p0, s.c1);
    const m12 = Vec2.mid(s.c1, s.c2);
    const m23 = Vec2.mid(s.c2, s.p1);
    const m012 = Vec2.mid(m01, m12);
    const m123 = Vec2.mid(m12, m23);
    const m = Vec2.mid(m012, m123);
    return .{
        .{ .p0 = s.p0, .c1 = m01, .c2 = m012, .p1 = m },
        .{ .p0 = m, .c1 = m123, .c2 = m23, .p1 = s.p1 },
    };
}

fn signedArea(segs: []const Segment) f64 {
    var a: f64 = 0;
    for (segs, 0..) |s, i| {
        const p = s.p0;
        const q = segs[(i + 1) % segs.len].p0;
        a += p.x * q.y - q.x * p.y;
    }
    return a / 2;
}

fn reverseSegs(segs: []Segment) void {
    std.mem.reverse(Segment, segs);
    for (segs) |*s| {
        const tmp_p = s.p0;
        s.p0 = s.p1;
        s.p1 = tmp_p;
        const tmp_c = s.c1;
        s.c1 = s.c2;
        s.c2 = tmp_c;
    }
}

fn equalize(alloc: std.mem.Allocator, short: []Segment, target: usize) ![]Segment {
    var list: std.ArrayList(Segment) = .empty;
    try list.appendSlice(alloc, short);
    while (list.items.len < target) {
        var best: usize = 0;
        var best_len: f64 = -1;
        for (list.items, 0..) |s, i| {
            const l = segLength(s);
            if (l > best_len) {
                best_len = l;
                best = i;
            }
        }
        // zero-length guard: split index 0 anyway — count still increases
        const halves = splitSegment(list.items[best]);
        list.items[best] = halves[0];
        try list.insert(alloc, best + 1, halves[1]);
    }
    return list.toOwnedSlice(alloc);
}

fn bestRotation(a: []const Segment, b: []const Segment) usize {
    var best_k: usize = 0;
    var best_cost = std.math.inf(f64);
    var k: usize = 0;
    while (k < b.len) : (k += 1) {
        var cost: f64 = 0;
        for (a, 0..) |s, i| {
            const t = b[(i + k) % b.len];
            const dx = s.p0.x - t.p0.x;
            const dy = s.p0.y - t.p0.y;
            cost += dx * dx + dy * dy;
        }
        if (cost < best_cost) {
            best_cost = cost;
            best_k = k;
        }
    }
    return best_k;
}

fn flatten(alloc: std.mem.Allocator, segs: []const Segment) ![]Vec2 {
    const out = try alloc.alloc(Vec2, 1 + 3 * segs.len);
    out[0] = segs[0].p0;
    for (segs, 0..) |s, i| {
        out[1 + 3 * i] = s.c1;
        out[2 + 3 * i] = s.c2;
        out[3 + 3 * i] = s.p1;
    }
    return out;
}

/// Match `from` and `to` for morphing: subpaths paired by index, winding
/// auto-reversed, segment counts equalized by splitting, closed pairs
/// rotation-aligned, flattened to equal-length point arrays.
pub fn prepareMorph(
    alloc: std.mem.Allocator,
    from_path: *const PathData,
    to_path: *const PathData,
    opts: MorphOpts,
) error{ SubpathCountMismatch, EmptyPath, OutOfMemory }!MorphPair {
    if (from_path.subpaths.len == 0 or to_path.subpaths.len == 0) return error.EmptyPath;
    if (from_path.subpaths.len != to_path.subpaths.len) return error.SubpathCountMismatch;

    const out = try alloc.alloc(MorphSubpath, from_path.subpaths.len);
    for (from_path.subpaths, to_path.subpaths, 0..) |sa, sb, i| {
        var a = try alloc.dupe(Segment, sa.segments);
        var b = try alloc.dupe(Segment, sb.segments);
        const closed = sa.closed;

        if (opts.auto_reverse and sa.closed and sb.closed) {
            const wa = signedArea(a);
            const wb = signedArea(b);
            if (wa != 0 and wb != 0 and (wa > 0) != (wb > 0)) reverseSegs(b);
        }
        if (a.len < b.len) a = try equalize(alloc, a, b.len);
        if (b.len < a.len) b = try equalize(alloc, b, a.len);
        if (opts.rotate_align and sa.closed and sb.closed and a.len > 1) {
            const k = bestRotation(a, b);
            if (k != 0) {
                const rotated = try alloc.alloc(Segment, b.len);
                for (0..b.len) |j| rotated[j] = b[(j + k) % b.len];
                b = rotated;
            }
        }
        out[i] = .{
            .a = try flatten(alloc, a),
            .b = try flatten(alloc, b),
            .closed = closed,
        };
    }
    return .{ .subpaths = out };
}

// ---- wire writers ------------------------------------------------------------

fn r2(v: f64) f64 {
    return @round(v * 100) / 100;
}

/// `,"mp":{"pts":[...],"rot":1,"ro":15}` fragment (caller mid-object).
/// Stride 3 (x,y,angle) when rotate, stride 2 otherwise.
pub fn writeMotionPath(
    w: *std.Io.Writer,
    samples: []const Sample,
    rotate: bool,
    rotate_offset_deg: f64,
) anyerror!void {
    try w.writeAll(",\"mp\":{\"pts\":[");
    for (samples, 0..) |s, i| {
        if (i != 0) try w.writeAll(",");
        if (rotate) {
            try w.print("{d},{d},{d}", .{ r2(s.x), r2(s.y), r2(s.angle_deg) });
        } else {
            try w.print("{d},{d}", .{ r2(s.x), r2(s.y) });
        }
    }
    try w.writeAll("]");
    if (rotate) {
        try w.writeAll(",\"rot\":1");
        if (rotate_offset_deg != 0) try w.print(",\"ro\":{d}", .{rotate_offset_deg});
    }
    try w.writeAll("}");
}

/// `,"mo":{"a":[...],"b":[...],"sp":[...],"z":[...]}` fragment. Flat
/// per-subpath runs of 2+6k floats; `z` emitted only when any subpath
/// is closed.
pub fn writeMorph(w: *std.Io.Writer, m: *const MorphPair) anyerror!void {
    try w.writeAll(",\"mo\":{");
    inline for (.{ "a", "b" }, 0..) |key, which| {
        if (which != 0) try w.writeAll(",");
        try w.print("\"{s}\":[", .{key});
        var first = true;
        for (m.subpaths) |sp| {
            const pts = if (which == 0) sp.a else sp.b;
            for (pts) |pt| {
                if (!first) try w.writeAll(",");
                first = false;
                try w.print("{d},{d}", .{ r2(pt.x), r2(pt.y) });
            }
        }
        try w.writeAll("]");
    }
    try w.writeAll(",\"sp\":[");
    for (m.subpaths, 0..) |sp, i| {
        if (i != 0) try w.writeAll(",");
        try w.print("{d}", .{(sp.a.len - 1) / 3});
    }
    try w.writeAll("]");
    var any_closed = false;
    for (m.subpaths) |sp| any_closed = any_closed or sp.closed;
    if (any_closed) {
        try w.writeAll(",\"z\":[");
        for (m.subpaths, 0..) |sp, i| {
            if (i != 0) try w.writeAll(",");
            try w.writeAll(if (sp.closed) "1" else "0");
        }
        try w.writeAll("]");
    }
    try w.writeAll("}");
}

// ---- tests --------------------------------------------------------------------

const testing = std.testing;

fn ta() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

fn approxVec(p: Vec2, x: f64, y: f64, eps: f64) !void {
    try testing.expectApproxEqAbs(x, p.x, eps);
    try testing.expectApproxEqAbs(y, p.y, eps);
}

test "parse: absolute commands and segment counts" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();

    const pd = try parse(a, "M 0 0 L 10 0 H 20 V 10 C 20 20 10 20 10 10 Q 5 5 0 10 Z");
    try testing.expectEqual(@as(usize, 1), pd.subpaths.len);
    const sp = pd.subpaths[0];
    try testing.expect(sp.closed);
    // L + H + V + C + Q + closing line = 6 segments
    try testing.expectEqual(@as(usize, 6), sp.segments.len);
    try approxVec(sp.segments[0].p0, 0, 0, 0);
    try approxVec(sp.segments[5].p1, 0, 0, 0); // closes back to start
}

test "parse: relative forms accumulate" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    const pd = try parse(a, "m 10 10 l 10 0 v 5 h -10");
    const segs = pd.subpaths[0].segments;
    try approxVec(segs[0].p0, 10, 10, 0);
    try approxVec(segs[0].p1, 20, 10, 0);
    try approxVec(segs[1].p1, 20, 15, 0);
    try approxVec(segs[2].p1, 10, 15, 0);
}

test "parse: S reflection and eligibility" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();

    const pd = try parse(a, "M 0 0 C 10 0 20 10 30 10 S 50 20 60 10");
    const s = pd.subpaths[0].segments[1];
    // reflected c1 = 2*cur - last_c2 = 2*(30,10) - (20,10) = (40,10)
    try approxVec(s.c1, 40, 10, 0);

    // S with no preceding C/S: c1 == current point
    const pd2 = try parse(a, "M 5 5 S 10 0 20 0");
    try approxVec(pd2.subpaths[0].segments[0].c1, 5, 5, 0);
}

test "parse: T reflection" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    const pd = try parse(a, "M 0 0 Q 5 10 10 0 T 20 0");
    // reflected q1 = 2*(10,0) - (5,10) = (15,-10); cubic c1 = p0 + 2/3(q1-p0)
    const s = pd.subpaths[0].segments[1];
    try approxVec(s.c1, 10 + (2.0 / 3.0) * 5, 0 + (2.0 / 3.0) * -10, 1e-12);
}

test "parse: implicit repeats and implicit M->L" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();

    const two_l = try parse(a, "M 0 0 L 10 0 20 0");
    try testing.expectEqual(@as(usize, 2), two_l.subpaths[0].segments.len);

    const m_l = try parse(a, "M 0 0 10 10");
    try testing.expectEqual(@as(usize, 1), m_l.subpaths[0].segments.len);
    try approxVec(m_l.subpaths[0].segments[0].p1, 10, 10, 0);

    const rel = try parse(a, "m 0 0 10 10 10 0");
    try approxVec(rel.subpaths[0].segments[1].p1, 20, 10, 0);
}

test "parse: number grammar" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();

    const exp_pd = try parse(a, "M 1e2 -1.5e-1 L .5 2");
    try approxVec(exp_pd.subpaths[0].segments[0].p0, 100, -0.15, 1e-12);
    try approxVec(exp_pd.subpaths[0].segments[0].p1, 0.5, 2, 0);

    // "1.5.5" = 1.5 then .5
    const adj = try parse(a, "M 1.5.5 L 3 3");
    try approxVec(adj.subpaths[0].segments[0].p0, 1.5, 0.5, 0);
}

test "parse: compressed arc flags" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    const pd = try parse(a, "M 0 0 a1 1 0 011 1");
    try testing.expect(pd.subpaths[0].segments.len >= 1);
    const last = pd.subpaths[0].segments[pd.subpaths[0].segments.len - 1];
    try approxVec(last.p1, 1, 1, 1e-9);
}

test "parse: errors" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.PathMustStartWithMove, parse(a, "L 10 10"));
    try testing.expectError(error.PathMustStartWithMove, parse(a, "   "));
    try testing.expectError(error.ExpectedNumber, parse(a, "M 10"));
    try testing.expectError(error.UnexpectedCommand, parse(a, "M 0 0 X 1"));
    try testing.expectError(error.ExpectedFlag, parse(a, "M 0 0 A 1 1 0 2 0 5 5"));
}

test "parse: multi-subpath, m after Z, lone trailing M dropped" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    const pd = try parse(a, "M 0 0 L 10 0 Z m 5 5 l 1 0 M 99 99");
    try testing.expectEqual(@as(usize, 2), pd.subpaths.len);
    try testing.expect(pd.subpaths[0].closed);
    try testing.expect(!pd.subpaths[1].closed);
    // m after Z is relative to the post-Z current point (= subpath start 0,0)
    try approxVec(pd.subpaths[1].segments[0].p0, 5, 5, 0);
}

test "line and quad conversion exactness" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();

    const l = try parse(a, "M 0 0 L 30 0");
    const ls = l.subpaths[0].segments[0];
    try approxVec(ls.c1, 10, 0, 0);
    try approxVec(ls.c2, 20, 0, 0);

    // quad sampled vs elevated cubic
    const q = try parse(a, "M 0 0 Q 10 20 20 0");
    const qs = q.subpaths[0].segments[0];
    const quad = struct {
        fn at(t: f64) Vec2 {
            const it = 1 - t;
            return .{
                .x = it * it * 0 + 2 * it * t * 10 + t * t * 20,
                .y = it * it * 0 + 2 * it * t * 20 + t * t * 0,
            };
        }
    };
    for ([_]f64{ 0, 0.25, 0.5, 0.75, 1 }) |t| {
        const expect = quad.at(t);
        const got = evalCubic(qs, t);
        try testing.expectApproxEqAbs(expect.x, got.x, 1e-12);
        try testing.expectApproxEqAbs(expect.y, got.y, 1e-12);
    }
}

test "arc: quarter circle accuracy and slice counts" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();

    // quarter circle r=10 from (10,0) to (0,10), center origin
    const pd = try parse(a, "M 10 0 A 10 10 0 0 1 0 10");
    const sp = pd.subpaths[0];
    try testing.expectEqual(@as(usize, 1), sp.segments.len);
    const s = sp.segments[0];
    try approxVec(s.p0, 10, 0, 1e-9);
    try approxVec(s.p1, 0, 10, 1e-9);
    // sampled radius stays within ~3e-3 * r of the true circle
    for ([_]f64{ 0.25, 0.5, 0.75 }) |t| {
        const pt = evalCubic(s, t);
        const r = @sqrt(pt.x * pt.x + pt.y * pt.y);
        try testing.expectApproxEqAbs(@as(f64, 10), r, 0.03);
    }

    // half circle -> 2 slices
    const half = try parse(a, "M 10 0 A 10 10 0 0 1 -10 0");
    try testing.expectEqual(@as(usize, 2), half.subpaths[0].segments.len);
    // large arc (270°) -> 3 slices
    const large = try parse(a, "M 10 0 A 10 10 0 1 1 0 -10");
    try testing.expectEqual(@as(usize, 3), large.subpaths[0].segments.len);
}

test "arc: radii correction and rx==0 degenerate" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();

    // impossible radii (rx too small) — endpoints must still land exactly
    const pd = try parse(a, "M 0 0 A 1 1 0 0 1 10 0");
    const segs = pd.subpaths[0].segments;
    try approxVec(segs[0].p0, 0, 0, 1e-9);
    try approxVec(segs[segs.len - 1].p1, 10, 0, 1e-9);

    const line = try parse(a, "M 0 0 A 0 5 0 0 1 10 0");
    const ls = line.subpaths[0].segments[0];
    try approxVec(ls.c1, 10.0 / 3.0, 0, 1e-12);
}

test "sampling: straight line midpoint, angle, uniform spacing" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();

    var pd = try parse(a, "M 0 0 L 100 0");
    var lut = try buildLut(a, &pd);
    const mid_s = sampleAt(&lut, 0.5);
    try testing.expectApproxEqAbs(@as(f64, 50), mid_s.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), mid_s.y, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), mid_s.angle_deg, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), sampleAt(&lut, 0).x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 100), sampleAt(&lut, 1).x, 1e-9);

    var diag = try parse(a, "M 0 0 L 10 10");
    var dlut = try buildLut(a, &diag);
    try testing.expectApproxEqAbs(@as(f64, 45), sampleAt(&dlut, 0.5).angle_deg, 1e-9);

    // LUT monotonic
    var prev: f64 = -1;
    for (lut.cum) |c| {
        try testing.expect(c >= prev);
        prev = c;
    }
    try testing.expectApproxEqAbs(lut.total, lut.cum[lut.cum.len - 1], 1e-12);

    const samples = try motionSamples(a, &pd, 5, 0, 1);
    try testing.expectEqual(@as(usize, 5), samples.len);
    for (samples, 0..) |s, i| {
        try testing.expectApproxEqAbs(@as(f64, @floatFromInt(i)) * 25.0, s.x, 1e-9);
    }
}

test "sampling: window and reverse" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    var pd = try parse(a, "M 0 0 L 100 0");
    const win = try motionSamples(a, &pd, 3, 0.25, 0.75);
    try testing.expectApproxEqAbs(@as(f64, 25), win[0].x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 75), win[2].x, 1e-9);
    const rev = try motionSamples(a, &pd, 3, 1, 0);
    try testing.expectApproxEqAbs(@as(f64, 100), rev[0].x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), rev[2].x, 1e-9);
}

test "sampling: angle unwrap on a full circle" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    // full circle via two half arcs, CW sweep in y-down SVG space
    var pd = try parse(a, "M 10 0 A 10 10 0 0 1 -10 0 A 10 10 0 0 1 10 0");
    const samples = try motionSamples(a, &pd, 33, 0, 1);
    // monotonic increasing angles, total sweep ~360 with no wrap dips
    var prev = samples[0].angle_deg;
    for (samples[1..]) |s| {
        try testing.expect(s.angle_deg >= prev - 1e-6);
        prev = s.angle_deg;
    }
    try testing.expectApproxEqAbs(samples[0].angle_deg + 360.0, samples[32].angle_deg, 1.0);
}

test "sampling: degenerates" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    var pd = try parse(a, "M 5 5 L 5 5");
    const samples = try motionSamples(a, &pd, 4, 0, 1);
    for (samples) |s| {
        try testing.expectApproxEqAbs(@as(f64, 5), s.x, 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 5), s.y, 1e-12);
    }
    var empty = PathData{ .subpaths = &.{} };
    try testing.expectError(error.EmptyPath, motionSamples(a, &empty, 4, 0, 1));
}

test "alignSamplesToStart: plain, windowed, reversed" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();

    var pd = try parse(a, "M 100 50 L 200 50");
    const plain = try motionSamples(a, &pd, 3, 0, 1);
    alignSamplesToStart(plain);
    try testing.expectApproxEqAbs(@as(f64, 0), plain[0].x, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), plain[0].y, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 100), plain[2].x, 1e-12);

    const windowed = try motionSamples(a, &pd, 3, 0.25, 0.75);
    alignSamplesToStart(windowed);
    try testing.expectApproxEqAbs(@as(f64, 0), windowed[0].x, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 50), windowed[2].x, 1e-12);

    const reversed = try motionSamples(a, &pd, 3, 1, 0);
    alignSamplesToStart(reversed);
    try testing.expectApproxEqAbs(@as(f64, 0), reversed[0].x, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -100), reversed[2].x, 1e-12);

    var empty: [0]Sample = .{};
    alignSamplesToStart(&empty); // empty: no crash
}

test "morph: de Casteljau split preserves shape" {
    const s = Segment{
        .p0 = .{ .x = 0, .y = 0 },
        .c1 = .{ .x = 10, .y = 20 },
        .c2 = .{ .x = 30, .y = -10 },
        .p1 = .{ .x = 40, .y = 5 },
    };
    const halves = splitSegment(s);
    var i: usize = 0;
    while (i <= 8) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / 8.0;
        const orig = evalCubic(s, t);
        const got = if (t <= 0.5)
            evalCubic(halves[0], t * 2)
        else
            evalCubic(halves[1], (t - 0.5) * 2);
        try testing.expectApproxEqAbs(orig.x, got.x, 1e-9);
        try testing.expectApproxEqAbs(orig.y, got.y, 1e-9);
    }
}

test "morph: count equalization and flatten invariant" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();

    var from = try parse(a, "M 0 0 L 10 0 L 20 0"); // 2 segments
    var to = try parse(a, "M 0 0 L 0 2 L 0 4 L 0 6 L 0 8 L 0 10"); // 5 segments
    const pre_len = try totalLength(a, &from);
    const pair = try prepareMorph(a, &from, &to, .{});
    try testing.expectEqual(@as(usize, 1), pair.subpaths.len);
    const sp = pair.subpaths[0];
    try testing.expectEqual(@as(usize, 1 + 3 * 5), sp.a.len);
    try testing.expectEqual(sp.a.len, sp.b.len);
    // splitting must not change total length
    var post_segs: std.ArrayList(Segment) = .empty;
    var j: usize = 0;
    while (j < 5) : (j += 1) {
        try post_segs.append(a, .{
            .p0 = sp.a[3 * j],
            .c1 = sp.a[1 + 3 * j],
            .c2 = sp.a[2 + 3 * j],
            .p1 = sp.a[3 + 3 * j],
        });
    }
    var post_total: f64 = 0;
    for (post_segs.items) |s| post_total += segLength(s);
    try testing.expectApproxEqAbs(pre_len, post_total, 1e-6);
}

test "morph: rotation alignment on squares" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    // same square, second authored starting at the opposite corner
    var sq1 = try parse(a, "M 0 0 L 10 0 L 10 10 L 0 10 Z");
    var sq2 = try parse(a, "M 10 10 L 0 10 L 0 0 L 10 0 Z");
    const pair = try prepareMorph(a, &sq1, &sq2, .{});
    const sp = pair.subpaths[0];
    // after alignment, b's first point should coincide with a's
    try testing.expectApproxEqAbs(sp.a[0].x, sp.b[0].x, 1e-9);
    try testing.expectApproxEqAbs(sp.a[0].y, sp.b[0].y, 1e-9);
}

test "morph: auto reverse on opposite windings" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    var ccw = try parse(a, "M 0 0 L 10 0 L 5 10 Z");
    var cw = try parse(a, "M 0 0 L 5 10 L 10 0 Z");
    const pair = try prepareMorph(a, &ccw, &cw, .{});
    const sp = pair.subpaths[0];
    // rebuild b's segments and check winding now matches a's
    const n = (sp.b.len - 1) / 3;
    var segs = try a.alloc(Segment, n);
    for (0..n) |j| {
        segs[j] = .{
            .p0 = sp.b[3 * j],
            .c1 = sp.b[1 + 3 * j],
            .c2 = sp.b[2 + 3 * j],
            .p1 = sp.b[3 + 3 * j],
        };
    }
    var asegs = try a.alloc(Segment, n);
    for (0..n) |j| {
        asegs[j] = .{
            .p0 = sp.a[3 * j],
            .c1 = sp.a[1 + 3 * j],
            .c2 = sp.a[2 + 3 * j],
            .p1 = sp.a[3 + 3 * j],
        };
    }
    try testing.expect((signedArea(asegs) > 0) == (signedArea(segs) > 0));
}

test "morph: subpath count mismatch" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    var one = try parse(a, "M 0 0 L 10 0");
    var two = try parse(a, "M 0 0 L 10 0 M 20 0 L 30 0");
    try testing.expectError(error.SubpathCountMismatch, prepareMorph(a, &one, &two, .{}));
}

test "wire golden: motion path fragment" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    const samples = [_]Sample{
        .{ .x = 0, .y = 0, .angle_deg = 0 },
        .{ .x = 5, .y = 0, .angle_deg = 0 },
        .{ .x = 10, .y = 0, .angle_deg = 0 },
    };
    const buf = try a.alloc(u8, 256);
    var w: std.Io.Writer = .fixed(buf);
    try writeMotionPath(&w, &samples, false, 0);
    try testing.expectEqualStrings(",\"mp\":{\"pts\":[0,0,5,0,10,0]}", w.buffered());

    var w2: std.Io.Writer = .fixed(buf);
    try writeMotionPath(&w2, &samples, true, 15);
    try testing.expectEqualStrings(
        ",\"mp\":{\"pts\":[0,0,0,5,0,0,10,0,0],\"rot\":1,\"ro\":15}",
        w2.buffered(),
    );
}

test "wire golden: morph fragment with z" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    var pa = [_]Vec2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 3, .y = 0 } };
    var pb = [_]Vec2{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 }, .{ .x = 0, .y = 2 }, .{ .x = 0, .y = 3 } };
    var sps = [_]MorphSubpath{.{ .a = &pa, .b = &pb, .closed = true }};
    const m = MorphPair{ .subpaths = &sps };
    const buf = try a.alloc(u8, 512);
    var w: std.Io.Writer = .fixed(buf);
    try writeMorph(&w, &m);
    try testing.expectEqualStrings(
        ",\"mo\":{\"a\":[0,0,1,0,2,0,3,0],\"b\":[0,0,0,1,0,2,0,3],\"sp\":[1],\"z\":[1]}",
        w.buffered(),
    );
}
