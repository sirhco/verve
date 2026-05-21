//! Phase 12B — keyed-list reconciler.
//!
//! Given the previous and new key order for a `forEach` parent, plan
//! the minimum sequence of DOM operations (`insert`, `move`, `remove`)
//! that turns the live DOM into the new order. The plan is then applied
//! by the JS bridge against `[data-vkey="<key>"]` children of the
//! parent element. Insertion is anchored against the *next* surviving
//! key so the bridge can call `insertBefore(node, anchor)` and keep
//! reactive state on surrounding nodes intact.
//!
//! Strategy: walk the old list to spot removals, walk the new list to
//! spot inserts, and use the Longest-Increasing-Subsequence over the
//! shared keys' positions to pick the largest stable subset — every
//! key not in that subset becomes a `move`. This is the same algorithm
//! Vue 3 / Solid / Inferno settle on for keyed reconciliation; LIS
//! minimizes the number of moves, which dominates cost in real lists.

const std = @import("std");

pub const OpKind = enum(u8) {
    insert = 0,
    move = 1,
    remove = 2,
};

pub const Op = struct {
    kind: OpKind,
    /// The key being acted on.
    key: []const u8,
    /// For `insert` / `move`: the key of the surviving sibling that
    /// should follow the inserted/moved node. `null` means "append to
    /// the end of the parent".
    anchor: ?[]const u8 = null,
};

/// Plan the reconcile. Caller owns the returned slice (allocated from
/// `arena`). The plan is stable: applying it in order against the live
/// DOM transforms `old_keys` into `new_keys`.
pub fn plan(
    arena: std.mem.Allocator,
    old_keys: []const []const u8,
    new_keys: []const []const u8,
) ![]Op {
    var ops: std.ArrayListUnmanaged(Op) = .empty;

    // ---- removals: every old key not in new_keys -------------------------
    for (old_keys) |k| {
        if (indexOf(new_keys, k) == null) {
            try ops.append(arena, .{ .kind = .remove, .key = k });
        }
    }

    // For each new key, record where it lived in the old order (or -1
    // when it's new). The LIS over the non-negative entries identifies
    // the largest set of survivors that already appear in order — those
    // keys don't need to be moved.
    const idx_in_old = try arena.alloc(i32, new_keys.len);
    for (new_keys, 0..) |k, i| {
        idx_in_old[i] = if (indexOf(old_keys, k)) |p| @intCast(p) else -1;
    }

    const lis_mask = try computeLisMask(arena, idx_in_old);

    // ---- inserts + moves in new-list order -------------------------------
    var i: usize = new_keys.len;
    while (i > 0) {
        i -= 1;
        const key = new_keys[i];
        const anchor: ?[]const u8 = if (i + 1 < new_keys.len) new_keys[i + 1] else null;
        if (idx_in_old[i] < 0) {
            try ops.append(arena, .{ .kind = .insert, .key = key, .anchor = anchor });
        } else if (!lis_mask[i]) {
            try ops.append(arena, .{ .kind = .move, .key = key, .anchor = anchor });
        }
    }

    return ops.toOwnedSlice(arena);
}

fn indexOf(haystack: []const []const u8, needle: []const u8) ?usize {
    for (haystack, 0..) |k, i| {
        if (std.mem.eql(u8, k, needle)) return i;
    }
    return null;
}

/// Compute a boolean mask over `idx_in_old`: true where the entry
/// participates in the longest strictly-increasing subsequence of
/// non-negative values. Entries holding -1 (new inserts) are always
/// false. O(n log n).
fn computeLisMask(arena: std.mem.Allocator, idx_in_old: []const i32) ![]bool {
    const n = idx_in_old.len;
    const mask = try arena.alloc(bool, n);
    @memset(mask, false);
    if (n == 0) return mask;

    // tails[k] = smallest possible tail value of any LIS of length k+1
    // tail_idx[k] = position in idx_in_old of that tail
    // prev[i] = previous-position-in-LIS for backtracking from i
    var tails: std.ArrayListUnmanaged(i32) = .empty;
    defer tails.deinit(arena);
    var tail_idx: std.ArrayListUnmanaged(usize) = .empty;
    defer tail_idx.deinit(arena);
    const prev = try arena.alloc(?usize, n);
    @memset(prev, null);

    for (idx_in_old, 0..) |v, i| {
        if (v < 0) continue;
        // Binary search for the first tail >= v; if all are smaller,
        // append a new length tier.
        var lo: usize = 0;
        var hi: usize = tails.items.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (tails.items[mid] < v) lo = mid + 1 else hi = mid;
        }
        if (lo > 0) prev[i] = tail_idx.items[lo - 1];
        if (lo == tails.items.len) {
            try tails.append(arena, v);
            try tail_idx.append(arena, i);
        } else {
            tails.items[lo] = v;
            tail_idx.items[lo] = i;
        }
    }

    // Backtrack from the last tail to mark every position on the LIS.
    if (tail_idx.items.len == 0) return mask;
    var cursor: ?usize = tail_idx.items[tail_idx.items.len - 1];
    while (cursor) |c| {
        mask[c] = true;
        cursor = prev[c];
    }
    return mask;
}

// ---- tests ---------------------------------------------------------------

const testing = std.testing;

test "plan: identical lists produce no ops" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const keys = [_][]const u8{ "a", "b", "c" };
    const ops = try plan(a, &keys, &keys);
    try testing.expectEqual(@as(usize, 0), ops.len);
}

test "plan: pure inserts at end" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = [_][]const u8{"a"};
    const new = [_][]const u8{ "a", "b", "c" };
    const ops = try plan(a, &old, &new);

    // Two insert ops, no moves, no removes.
    try testing.expectEqual(@as(usize, 2), ops.len);
    for (ops) |op| try testing.expectEqual(OpKind.insert, op.kind);
}

test "plan: pure remove" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = [_][]const u8{ "a", "b", "c" };
    const new = [_][]const u8{ "a", "c" };
    const ops = try plan(a, &old, &new);

    try testing.expectEqual(@as(usize, 1), ops.len);
    try testing.expectEqual(OpKind.remove, ops[0].kind);
    try testing.expectEqualStrings("b", ops[0].key);
}

test "plan: swap two adjacent keys → single move" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = [_][]const u8{ "a", "b" };
    const new = [_][]const u8{ "b", "a" };
    const ops = try plan(a, &old, &new);

    // LIS picks one of {a, b} as stable; the other moves.
    var moves: usize = 0;
    for (ops) |op| {
        if (op.kind == .move) moves += 1;
    }
    try testing.expectEqual(@as(usize, 1), moves);
}

test "plan: reverse list maximizes moves except one anchor" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = [_][]const u8{ "a", "b", "c", "d" };
    const new = [_][]const u8{ "d", "c", "b", "a" };
    const ops = try plan(a, &old, &new);

    // LIS over reverse is length 1 → 3 keys move, 1 stable, 0 inserts.
    var moves: usize = 0;
    var inserts: usize = 0;
    for (ops) |op| switch (op.kind) {
        .move => moves += 1,
        .insert => inserts += 1,
        .remove => {},
    };
    try testing.expectEqual(@as(usize, 3), moves);
    try testing.expectEqual(@as(usize, 0), inserts);
}

test "plan: mixed insert + remove + move" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = [_][]const u8{ "a", "b", "c", "d" };
    const new = [_][]const u8{ "x", "c", "a", "b" };
    const ops = try plan(a, &old, &new);

    var removes: usize = 0;
    var inserts: usize = 0;
    var moves: usize = 0;
    var saw_remove_d = false;
    var saw_insert_x = false;
    for (ops) |op| switch (op.kind) {
        .remove => {
            removes += 1;
            if (std.mem.eql(u8, op.key, "d")) saw_remove_d = true;
        },
        .insert => {
            inserts += 1;
            if (std.mem.eql(u8, op.key, "x")) saw_insert_x = true;
        },
        .move => moves += 1,
    };
    try testing.expectEqual(@as(usize, 1), removes);
    try testing.expectEqual(@as(usize, 1), inserts);
    try testing.expect(saw_remove_d);
    try testing.expect(saw_insert_x);
    // a, b, c — exactly one of {a,b} pair plus c stays put via LIS.
    try testing.expect(moves >= 1);
}

test "plan: anchor is the next surviving key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = [_][]const u8{ "a", "b" };
    const new = [_][]const u8{ "a", "x", "b" };
    const ops = try plan(a, &old, &new);

    // Only "x" is inserted; its anchor must be "b" so insertBefore lands
    // it between a and b.
    try testing.expectEqual(@as(usize, 1), ops.len);
    try testing.expectEqual(OpKind.insert, ops[0].kind);
    try testing.expectEqualStrings("x", ops[0].key);
    try testing.expect(ops[0].anchor != null);
    try testing.expectEqualStrings("b", ops[0].anchor.?);
}

test "plan: trailing insert has null anchor" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = [_][]const u8{"a"};
    const new = [_][]const u8{ "a", "b" };
    const ops = try plan(a, &old, &new);

    try testing.expectEqual(@as(usize, 1), ops.len);
    try testing.expectEqual(OpKind.insert, ops[0].kind);
    try testing.expect(ops[0].anchor == null);
}
