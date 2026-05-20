//! Showcase — exercises every Phase 0-10 surface in a single app.
//! The route table at routes.zig lists what each path demonstrates.

const std = @import("std");
const verve = @import("verve");

pub const components = @import("components.zig");
pub const routes_mod = @import("routes.zig");
pub const routes = routes_mod.routes;

const log = std.log.scoped(.showcase);

/// Required by the framework's WebSocket / SSE counter hooks. We
/// expose a single shared counter and let the existing /counter wire
/// drive it just like the main demo.
pub var last_count: std.atomic.Value(i32) = .init(0);

// ---- in-process state -------------------------------------------------

const MAX_TODOS: usize = 32;
const TODO_LEN: usize = 64;

pub const Todo = struct {
    text: [TODO_LEN]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Todo) []const u8 {
        return self.text[0..self.len];
    }
};

var todos: [MAX_TODOS]Todo = .{Todo{}} ** MAX_TODOS;
var todo_count: usize = 0;
var todos_mu: std.atomic.Mutex = .unlocked;

fn lockTodos() void {
    while (!todos_mu.tryLock()) std.atomic.spinLoopHint();
}

pub fn copyTodos(arena: std.mem.Allocator) ![]const []const u8 {
    lockTodos();
    defer todos_mu.unlock();
    const out = try arena.alloc([]const u8, todo_count);
    for (0..todo_count) |i| out[i] = try arena.dupe(u8, todos[i].slice());
    return out;
}

// ---- Actions / Server Functions --------------------------------------

pub const Actions = struct {
    pub fn incrementCount(_: struct {}) void {
        _ = last_count.fetchAdd(1, .monotonic);
    }

    pub fn decrementCount(_: struct {}) void {
        _ = last_count.fetchSub(1, .monotonic);
    }

    pub fn addTodo(args: struct { text: []const u8 }) !void {
        const t = std.mem.trim(u8, args.text, &std.ascii.whitespace);
        if (t.len == 0) return error.EmptyTodo;
        lockTodos();
        defer todos_mu.unlock();
        if (todo_count >= MAX_TODOS) return error.Full;
        const n = @min(t.len, TODO_LEN);
        @memcpy(todos[todo_count].text[0..n], t[0..n]);
        todos[todo_count].len = n;
        todo_count += 1;
        log.info("todo added: {s}", .{t[0..n]});
    }

    pub fn removeTodo(args: struct { index: usize }) !void {
        lockTodos();
        defer todos_mu.unlock();
        if (args.index >= todo_count) return error.OutOfRange;
        var i = args.index;
        while (i + 1 < todo_count) : (i += 1) todos[i] = todos[i + 1];
        todo_count -= 1;
    }

    /// Returns a JSON `{ "value": <doubled> }` so `ctx.serverFn` and
    /// the JS `verveServerFn` helpers both have something to read.
    pub fn double(args: struct { n: i32 }) i32 {
        return args.n * 2;
    }
};

// ---- i18n catalog -----------------------------------------------------

pub const catalog: verve.I18nCatalog = .{
    .entries = &.{
        .{ .locale = "en", .key = "greeting", .value = "Hello" },
        .{ .locale = "en", .key = "tour", .value = "Verve framework tour" },
        .{ .locale = "es", .key = "greeting", .value = "Hola" },
        .{ .locale = "es", .key = "tour", .value = "Recorrido del marco Verve" },
        .{ .locale = "fr", .key = "greeting", .value = "Bonjour" },
        .{ .locale = "fr", .key = "tour", .value = "Visite du framework Verve" },
    },
    .default_locale = "en",
    .supported = &.{ "en", "es", "fr" },
};

// ---- protected-route guard -------------------------------------------

pub fn privateGuard(ctx: *verve.Context) ?verve.Redirect {
    const loc = ctx.location orelse return .{ .to = "/counter-reactive" };
    var l = loc.*;
    const t = l.queryGet(ctx.alloc(), "token") catch return .{ .to = "/counter-reactive" };
    if (t) |val| if (val.len > 0) return null;
    return .{ .to = "/counter-reactive" };
}
