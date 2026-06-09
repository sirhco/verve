//! Force-directed layout: a small physics sim with pairwise node repulsion,
//! spring attraction along edges, and a gentle pull toward the center. The
//! cytoscape/d3 default for general networks.
//!
//! Two entry points:
//!   * `run` — initialize + iterate to a settled layout server-side (static SSR
//!     render).
//!   * `State.step` — advance one frame; the client island calls this per
//!     `requestAnimationFrame` to animate node groups to rest by mutating their
//!     `transform` attribute (no new bridge primitives, fixed element set).
//!
//! Initial positions are deterministic (nodes seeded on a ring by index), so
//! the same input always yields the same layout — no RNG, fully testable.

const std = @import("std");
const geom = @import("../geom.zig");
const common = @import("common.zig");

const Vec2 = geom.Vec2;

pub const Opts = struct {
    iterations: usize = 300,
    center: Vec2 = .{ .x = 0, .y = 0 },
    /// Initial seeding ring radius.
    seed_radius: f64 = 120,
    /// Repulsion strength (Coulomb-like, ~1/d²).
    repulsion: f64 = 3000,
    /// Spring stiffness for edges (Hooke-like).
    spring: f64 = 0.04,
    /// Natural edge length.
    rest_length: f64 = 90,
    /// Pull toward `center` per step.
    gravity: f64 = 0.02,
    /// Velocity retained each step (0..1).
    damping: f64 = 0.85,
    dt: f64 = 0.6,
    /// Distances below this are clamped to avoid singular repulsion.
    min_dist: f64 = 1.0,
};

/// Mutable simulation state. `positions` is what callers read; `velocities` is
/// scratch carried between steps. Both owned by the caller (see `init`/`deinit`).
pub const State = struct {
    positions: []Vec2,
    velocities: []Vec2,
    edges: []const common.Edge,
    opts: Opts,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *State) void {
        self.alloc.free(self.positions);
        self.alloc.free(self.velocities);
    }

    /// Advance the simulation by one frame.
    pub fn step(self: *State) void {
        const n = self.positions.len;
        if (n == 0) return;
        const o = self.opts;

        // Repulsion between every pair (O(n²) — fine for phase-1 sizes).
        var i: usize = 0;
        while (i < n) : (i += 1) {
            var j: usize = i + 1;
            while (j < n) : (j += 1) {
                var delta = self.positions[i].sub(self.positions[j]);
                var d = delta.len();
                if (d < o.min_dist) {
                    // Deterministic nudge apart along x when coincident.
                    delta = .{ .x = o.min_dist, .y = 0 };
                    d = o.min_dist;
                }
                const f = o.repulsion / (d * d);
                const push = delta.normalize().scale(f * o.dt);
                self.velocities[i] = self.velocities[i].add(push);
                self.velocities[j] = self.velocities[j].sub(push);
            }
        }

        // Spring attraction along edges.
        for (self.edges) |e| {
            if (e[0] >= n or e[1] >= n or e[0] == e[1]) continue;
            const delta = self.positions[e[1]].sub(self.positions[e[0]]);
            const d = @max(delta.len(), o.min_dist);
            const f = o.spring * (d - o.rest_length);
            const pull = delta.normalize().scale(f * o.dt);
            self.velocities[e[0]] = self.velocities[e[0]].add(pull);
            self.velocities[e[1]] = self.velocities[e[1]].sub(pull);
        }

        // Gravity + integration.
        i = 0;
        while (i < n) : (i += 1) {
            const to_center = self.opts.center.sub(self.positions[i]).scale(o.gravity * o.dt);
            self.velocities[i] = self.velocities[i].add(to_center).scale(o.damping);
            self.positions[i] = self.positions[i].add(self.velocities[i].scale(o.dt));
        }
    }
};

/// Allocate state and seed deterministic initial positions on a ring. Caller
/// frees via `State.deinit`.
pub fn init(alloc: std.mem.Allocator, n: usize, edges: []const common.Edge, opts: Opts) !State {
    const positions = try alloc.alloc(Vec2, n);
    errdefer alloc.free(positions);
    const velocities = try alloc.alloc(Vec2, n);
    errdefer alloc.free(velocities);
    for (0..n) |i| {
        const a = if (n == 0) 0 else (2.0 * std.math.pi) * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
        positions[i] = .{
            .x = opts.center.x + opts.seed_radius * @cos(a),
            .y = opts.center.y + opts.seed_radius * @sin(a),
        };
        velocities[i] = .{ .x = 0, .y = 0 };
    }
    return .{ .positions = positions, .velocities = velocities, .edges = edges, .opts = opts, .alloc = alloc };
}

/// Run the simulation to convergence and return the final positions. Caller
/// owns the returned slice; the velocity scratch is freed internally.
pub fn run(alloc: std.mem.Allocator, n: usize, edges: []const common.Edge, opts: Opts) ![]Vec2 {
    var state = try init(alloc, n, edges, opts);
    for (0..opts.iterations) |_| state.step();
    alloc.free(state.velocities);
    return state.positions;
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

test "converged layout is finite and bounded" {
    const edges = [_]common.Edge{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 0 } };
    const pos = try run(testing.allocator, 4, &edges, .{ .iterations = 200, .center = .{ .x = 0, .y = 0 } });
    defer testing.allocator.free(pos);
    for (pos) |p| {
        try testing.expect(!std.math.isNan(p.x) and !std.math.isNan(p.y));
        try testing.expect(@abs(p.x) < 1e4 and @abs(p.y) < 1e4);
    }
}

test "connected nodes settle, all nodes separated" {
    const edges = [_]common.Edge{ .{ 0, 1 }, .{ 1, 2 } };
    const pos = try run(testing.allocator, 3, &edges, .{ .iterations = 400, .rest_length = 80 });
    defer testing.allocator.free(pos);
    // No two nodes collapse onto each other.
    for (0..3) |a| {
        for (a + 1..3) |b| {
            try testing.expect(Vec2.dist(pos[a], pos[b]) > 1.0);
        }
    }
    // Spring brings adjacent nodes within a few rest-lengths.
    try testing.expect(Vec2.dist(pos[0], pos[1]) < 300);
}

test "deterministic: same input yields same output" {
    const edges = [_]common.Edge{ .{ 0, 1 }, .{ 0, 2 } };
    const a = try run(testing.allocator, 3, &edges, .{ .iterations = 50 });
    defer testing.allocator.free(a);
    const b = try run(testing.allocator, 3, &edges, .{ .iterations = 50 });
    defer testing.allocator.free(b);
    for (a, b) |pa, pb| {
        try testing.expectEqual(pa.x, pb.x);
        try testing.expectEqual(pa.y, pb.y);
    }
}
