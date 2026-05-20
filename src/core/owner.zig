//! Reactive ownership scope. The Owner tree mirrors a component subtree
//! (server-side: per render request; client-side: per island/route). It
//! holds:
//!
//!   - A bumpable arena for signals, effects, and per-scope storage.
//!   - A LIFO list of cleanup hooks the scope runs on `dispose`.
//!   - A children list — `dispose` recursively disposes children first.
//!
//! When an Effect is created under an Owner it registers an
//! `onCleanup(unsubscribe)` so that disposing the owner unhooks the
//! effect from every signal it had subscribed to. Same pattern lets
//! `provide_context`, `Resource`, and other primitives in later phases
//! attach disposable state to the scope without explicit teardown
//! plumbing.

const std = @import("std");

pub const Owner = struct {
    parent: ?*Owner,
    children: std.ArrayListUnmanaged(*Owner),
    cleanups: std.ArrayListUnmanaged(Cleanup),
    arena: std.heap.ArenaAllocator,
    /// True after `dispose` has been called; guards against double
    /// dispose and against new cleanups being registered post-mortem.
    disposed: bool,

    const Cleanup = struct {
        ctx: *anyopaque,
        run: *const fn (*anyopaque) void,
    };

    /// Build a root owner backed by `gpa`. The arena lifetime tracks the
    /// owner; dispose calls `arena.deinit()` after running cleanups.
    pub fn init(gpa: std.mem.Allocator) Owner {
        return .{
            .parent = null,
            .children = .empty,
            .cleanups = .empty,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .disposed = false,
        };
    }

    pub fn allocator(self: *Owner) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Create a child scope whose disposal happens before its parent's
    /// (per LIFO). The child shares the gpa underlying the parent's
    /// arena — callers can mix children freely without per-child
    /// allocator plumbing.
    pub fn createChild(self: *Owner) !*Owner {
        const child = try self.arena.allocator().create(Owner);
        child.* = .{
            .parent = self,
            .children = .empty,
            .cleanups = .empty,
            .arena = std.heap.ArenaAllocator.init(self.arena.child_allocator),
            .disposed = false,
        };
        try self.children.append(self.allocator(), child);
        return child;
    }

    /// Register a cleanup. The signature mirrors `on_cleanup` from
    /// SolidJS/Leptos: when this owner disposes, every cleanup runs in
    /// LIFO order (most-recent first).
    ///
    /// `ctx_ptr` must be a pointer (the cleanup typically wants to walk
    /// some state the caller already owns).
    pub fn onCleanup(self: *Owner, ctx_ptr: anytype, comptime f: fn (@TypeOf(ctx_ptr)) void) !void {
        std.debug.assert(!self.disposed);
        const CtxT = @TypeOf(ctx_ptr);
        comptime std.debug.assert(@typeInfo(CtxT) == .pointer);

        const opaque_ptr: *anyopaque = @ptrCast(@constCast(ctx_ptr));
        try self.cleanups.append(self.allocator(), .{
            .ctx = opaque_ptr,
            .run = CleanupWrap(CtxT, f).invoke,
        });
    }

    /// Recursively dispose children (LIFO), then run own cleanups (also
    /// LIFO), then deinit the arena. Idempotent — calling twice is a
    /// no-op.
    pub fn dispose(self: *Owner) void {
        if (self.disposed) return;
        self.disposed = true;
        // Children first — depth-first, last-created first.
        while (self.children.pop()) |child| {
            child.dispose();
        }
        // Then own cleanups in LIFO order.
        while (self.cleanups.pop()) |c| {
            c.run(c.ctx);
        }
        self.arena.deinit();
    }
};

/// Generic cleanup trampoline factory. Pulled out of `onCleanup` so the
/// instantiation is unambiguous to the compiler — anonymous structs
/// declared inside a function can in some Zig versions share fn-pointer
/// addresses across instantiations, producing wrong-cast crashes at
/// runtime.
pub fn CleanupWrap(comptime CtxT: type, comptime f: fn (CtxT) void) type {
    return struct {
        pub fn invoke(raw: *anyopaque) void {
            const typed: CtxT = @ptrCast(@alignCast(raw));
            f(typed);
        }
    };
}

// ---- tests ------------------------------------------------------------

const testing = std.testing;

test "Owner runs cleanups in LIFO order" {
    var calls: std.ArrayListUnmanaged(u32) = .empty;
    defer calls.deinit(testing.allocator);

    var owner = Owner.init(testing.allocator);
    const Ctx = struct { list: *std.ArrayListUnmanaged(u32), id: u32 };
    var c1 = Ctx{ .list = &calls, .id = 1 };
    var c2 = Ctx{ .list = &calls, .id = 2 };
    var c3 = Ctx{ .list = &calls, .id = 3 };

    const Add = struct {
        fn add(ctx: *Ctx) void {
            ctx.list.append(testing.allocator, ctx.id) catch {};
        }
    };
    try owner.onCleanup(&c1, Add.add);
    try owner.onCleanup(&c2, Add.add);
    try owner.onCleanup(&c3, Add.add);
    owner.dispose();

    try testing.expectEqual(@as(usize, 3), calls.items.len);
    try testing.expectEqual(@as(u32, 3), calls.items[0]);
    try testing.expectEqual(@as(u32, 2), calls.items[1]);
    try testing.expectEqual(@as(u32, 1), calls.items[2]);
}

test "Owner disposes children before its own cleanups" {
    var calls: std.ArrayListUnmanaged([]const u8) = .empty;
    defer calls.deinit(testing.allocator);

    var owner = Owner.init(testing.allocator);
    const child = try owner.createChild();
    const grand = try child.createChild();

    const Ctx = struct { list: *std.ArrayListUnmanaged([]const u8), tag: []const u8 };
    var c_root = Ctx{ .list = &calls, .tag = "root" };
    var c_child = Ctx{ .list = &calls, .tag = "child" };
    var c_grand = Ctx{ .list = &calls, .tag = "grand" };

    const Add = struct {
        fn add(ctx: *Ctx) void {
            ctx.list.append(testing.allocator, ctx.tag) catch {};
        }
    };
    try owner.onCleanup(&c_root, Add.add);
    try child.onCleanup(&c_child, Add.add);
    try grand.onCleanup(&c_grand, Add.add);

    owner.dispose();
    try testing.expectEqualStrings("grand", calls.items[0]);
    try testing.expectEqualStrings("child", calls.items[1]);
    try testing.expectEqualStrings("root", calls.items[2]);
}

test "Owner.dispose is idempotent" {
    var counter: u32 = 0;
    var owner = Owner.init(testing.allocator);
    const Inc = struct {
        fn inc(c: *u32) void {
            c.* += 1;
        }
    };
    try owner.onCleanup(&counter, Inc.inc);
    owner.dispose();
    owner.dispose();
    try testing.expectEqual(@as(u32, 1), counter);
}
