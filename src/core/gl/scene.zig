//! verve.gl scene graph — flat SoA arrays, fixed capacity, no allocator.
//! Nodes are appended in pre-order (a node's parent index is always
//! lower), so `updateWorld` is one linear pass: every parent's world
//! matrix is final before any child reads it. Node indices are stable
//! for the scene's lifetime and double as animation target ids (P5).

const std = @import("std");
const math = @import("math.zig");

pub fn Scene(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        pub const cap = capacity;

        count: u32 = 0,
        parent: [capacity]i32 = undefined,
        pos: [capacity]math.Vec3 = undefined,
        rot: [capacity]math.Quat = undefined,
        scl: [capacity]math.Vec3 = undefined,
        world: [capacity]math.Mat4 = undefined,
        dirty: [capacity]bool = undefined,
        name_hash: [capacity]u32 = undefined,

        /// `parent_idx` must be -1 (root) or an already-added node —
        /// this is what guarantees pre-order.
        pub fn addNode(self: *Self, parent_idx: i32, name: []const u8) u32 {
            std.debug.assert(self.count < capacity);
            std.debug.assert(parent_idx < @as(i32, @intCast(self.count)));
            const i = self.count;
            self.count += 1;
            self.parent[i] = parent_idx;
            self.pos[i] = math.Vec3.init(0, 0, 0);
            self.rot[i] = math.Quat.identity;
            self.scl[i] = math.Vec3.init(1, 1, 1);
            self.world[i] = math.Mat4.identity;
            self.dirty[i] = true;
            self.name_hash[i] = std.hash.Fnv1a_32.hash(name);
            return i;
        }

        pub fn setPosition(self: *Self, idx: u32, v: math.Vec3) void {
            self.pos[idx] = v;
            self.dirty[idx] = true;
        }
        pub fn setRotation(self: *Self, idx: u32, q: math.Quat) void {
            self.rot[idx] = q;
            self.dirty[idx] = true;
        }
        pub fn setScale(self: *Self, idx: u32, v: math.Vec3) void {
            self.scl[idx] = v;
            self.dirty[idx] = true;
        }

        pub fn find(self: *const Self, name: []const u8) ?u32 {
            const h = std.hash.Fnv1a_32.hash(name);
            for (self.name_hash[0..self.count], 0..) |nh, i| {
                if (nh == h) return @intCast(i);
            }
            return null;
        }

        /// One linear pass. A node recomputes when itself or its parent
        /// recomputed this pass; clean subtrees are untouched.
        pub fn updateWorld(self: *Self) void {
            var recomputed: [capacity]bool = undefined;
            for (0..self.count) |i| {
                const p = self.parent[i];
                const parent_recomputed = p >= 0 and recomputed[@intCast(p)];
                if (self.dirty[i] or parent_recomputed) {
                    const local = math.Mat4.fromTrs(self.pos[i], self.rot[i], self.scl[i]);
                    self.world[i] = if (p >= 0) self.world[@intCast(p)].mul(local) else local;
                    recomputed[i] = true;
                    self.dirty[i] = false;
                } else {
                    recomputed[i] = false;
                }
            }
        }
    };
}

const testing = std.testing;
const eps = 1e-5;

test "parent-child world compose" {
    var s = Scene(8){};
    const root = s.addNode(-1, "root");
    const child = s.addNode(@intCast(root), "child");
    s.setPosition(root, math.Vec3.init(10, 0, 0));
    s.setPosition(child, math.Vec3.init(0, 5, 0));
    s.updateWorld();
    // child world translation = parent + local
    try testing.expectApproxEqAbs(@as(f32, 10), s.world[child].m[12], eps);
    try testing.expectApproxEqAbs(@as(f32, 5), s.world[child].m[13], eps);
}

test "parent mutation re-derives child, dirty flags clear" {
    var s = Scene(8){};
    const root = s.addNode(-1, "root");
    const child = s.addNode(@intCast(root), "child");
    s.setPosition(child, math.Vec3.init(0, 0, 3));
    s.updateWorld();
    // rotate the parent +90deg about Y: child's +Z offset maps to +X
    s.setRotation(root, math.Quat.fromAxisAngle(math.Vec3.init(0, 1, 0), std.math.pi / 2.0));
    s.updateWorld();
    try testing.expectApproxEqAbs(@as(f32, 3), s.world[child].m[12], eps);
    try testing.expectApproxEqAbs(@as(f32, 0), s.world[child].m[14], eps);
    try testing.expect(!s.dirty[root]);
    try testing.expect(!s.dirty[child]);
}

test "find by name" {
    var s = Scene(8){};
    _ = s.addNode(-1, "root");
    const hub = s.addNode(0, "hub");
    try testing.expectEqual(@as(?u32, hub), s.find("hub"));
    try testing.expectEqual(@as(?u32, null), s.find("nope"));
}
