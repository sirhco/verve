//! "Zerver" actions — functions that run on the server and are callable from
//! the client. Server's api_handler walks `Actions` at comptime to generate
//! `/api/<fn_name>` routes.

const std = @import("std");

pub const components = @import("components.zig");
pub const islands = @import("islands.zig");
pub const routes_mod = @import("routes.zig");
pub const Route = routes_mod.Route;
pub const routes = routes_mod.routes;

const log = std.log.scoped(.verve);

/// Shared server-side counter. Atomic — the server may run actions on
/// multiple worker threads.
pub var last_count: std.atomic.Value(i32) = .init(0);

pub fn currentCount() i32 {
    return last_count.load(.monotonic);
}

const TODO_MAX = 32;
const TODO_TEXT_MAX = 200;

// Fixed pool of slots — each holds up to TODO_TEXT_MAX bytes plus the active
// length. Avoids needing a heap allocator inside Action functions while still
// supporting append + remove for the demo.
var todo_slots: [TODO_MAX][TODO_TEXT_MAX]u8 = undefined;
var todo_lens: [TODO_MAX]usize = .{0} ** TODO_MAX;
var todo_count: usize = 0;
var todo_mu: std.atomic.Mutex = .unlocked;

fn lockTodos() void {
    while (!todo_mu.tryLock()) std.atomic.spinLoopHint();
}

/// Caller-owned snapshot of the current todo list into `arena`. Strings are
/// duped so the snapshot stays valid after the mutex is released.
pub fn copyTodosInto(arena: std.mem.Allocator) ![]const []const u8 {
    lockTodos();
    defer todo_mu.unlock();

    const out = try arena.alloc([]const u8, todo_count);
    for (0..todo_count) |i| {
        out[i] = try arena.dupe(u8, todo_slots[i][0..todo_lens[i]]);
    }
    return out;
}

pub const VizNode = struct { id: []const u8, label: []const u8 };
pub const VizEdge = struct { from: []const u8, to: []const u8 };
pub const VizSnapshot = struct { nodes: []const VizNode, edges: []const VizEdge };

var viz_tick: std.atomic.Value(u32) = .init(0);
/// Reset the evolving stream (tests).
pub fn resetVizTick() void {
    viz_tick.store(0, .monotonic);
}

// Per-thread snapshot storage: `vizGraph` returns slices into these, serialized
// on the same thread by the api_handler → no cross-thread race, no allocator.
threadlocal var tl_nodes: [8]VizNode = undefined;
threadlocal var tl_edges: [8]VizEdge = undefined;

pub const Actions = struct {
    /// Evolving graph snapshot for the live-data demo: a stable base plus 0..3
    /// ephemeral nodes selected by a tick counter, so successive polls show
    /// nodes appearing/disappearing.
    pub fn vizGraph(_: struct {}) VizSnapshot {
        const t = viz_tick.fetchAdd(1, .monotonic);
        const extra = t % 4;
        tl_nodes[0] = .{ .id = "core", .label = "core" };
        tl_nodes[1] = .{ .id = "io", .label = "io" };
        tl_nodes[2] = .{ .id = "ui", .label = "ui" };
        tl_edges[0] = .{ .from = "core", .to = "io" };
        tl_edges[1] = .{ .from = "core", .to = "ui" };
        var nc: usize = 3;
        var ec: usize = 2;
        const eph_ids = [_][]const u8{ "e0", "e1", "e2" };
        var i: usize = 0;
        while (i < extra) : (i += 1) {
            tl_nodes[nc] = .{ .id = eph_ids[i], .label = eph_ids[i] };
            tl_edges[ec] = .{ .from = "core", .to = eph_ids[i] };
            nc += 1;
            ec += 1;
        }
        return .{ .nodes = tl_nodes[0..nc], .edges = tl_edges[0..ec] };
    }

    pub fn updateDatabase(args: struct { new_count: i32 }) !void {
        last_count.store(args.new_count, .monotonic);
        log.info("updateDatabase: new_count={d}", .{args.new_count});
    }

    pub fn logMessage(args: struct { text: []const u8 }) !void {
        log.info("logMessage: {s}", .{args.text});
    }

    pub fn getCount(_: struct {}) !i32 {
        return last_count.load(.monotonic);
    }

    /// Value-returning string action — backs the `fetchSignal([]const u8, ...)`
    /// demo in `src/client/islands/JsonProbe.zig`.
    pub fn appName(_: struct {}) []const u8 {
        return "verve";
    }

    pub fn incrementCount(_: struct {}) i32 {
        return last_count.fetchAdd(1, .monotonic) + 1;
    }

    pub fn decrementCount(_: struct {}) i32 {
        return last_count.fetchSub(1, .monotonic) - 1;
    }

    pub fn addTodo(args: struct { text: []const u8 }) !void {
        const trimmed = std.mem.trim(u8, args.text, &std.ascii.whitespace);
        if (trimmed.len == 0) return error.EmptyTodo;

        lockTodos();
        defer todo_mu.unlock();

        if (todo_count >= TODO_MAX) return error.TodoListFull;
        const len = @min(trimmed.len, TODO_TEXT_MAX);
        @memcpy(todo_slots[todo_count][0..len], trimmed[0..len]);
        todo_lens[todo_count] = len;
        todo_count += 1;
        log.info("addTodo: idx={d} text={s}", .{ todo_count - 1, trimmed[0..len] });
    }

    pub fn removeTodo(args: struct { index: usize }) !void {
        lockTodos();
        defer todo_mu.unlock();

        if (args.index >= todo_count) return error.OutOfRange;
        var i = args.index;
        while (i + 1 < todo_count) : (i += 1) {
            const next_len = todo_lens[i + 1];
            @memcpy(todo_slots[i][0..next_len], todo_slots[i + 1][0..next_len]);
            todo_lens[i] = next_len;
        }
        todo_count -= 1;
        todo_lens[todo_count] = 0;
        log.info("removeTodo: idx={d}", .{args.index});
    }
};

test "vizGraph returns a base graph that changes across ticks" {
    resetVizTick();
    const a = Actions.vizGraph(.{});
    try std.testing.expect(a.nodes.len >= 3);
    var has_core = false;
    for (a.nodes) |nd| {
        if (std.mem.eql(u8, nd.id, "core")) has_core = true;
    }
    try std.testing.expect(has_core);
    for (a.edges) |e| {
        var ff = false;
        var tt = false;
        for (a.nodes) |nd| {
            if (std.mem.eql(u8, nd.id, e.from)) ff = true;
            if (std.mem.eql(u8, nd.id, e.to)) tt = true;
        }
        try std.testing.expect(ff and tt);
    }
    const b = Actions.vizGraph(.{});
    const c = Actions.vizGraph(.{});
    try std.testing.expect(a.nodes.len != b.nodes.len or b.nodes.len != c.nodes.len);
}
