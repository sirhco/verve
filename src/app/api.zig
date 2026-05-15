//! "Zerver" actions — functions that run on the server and are callable from
//! the client. Server's api_handler walks `Actions` at comptime to generate
//! `/api/<fn_name>` routes.

const std = @import("std");

pub const components = @import("components.zig");
pub const routes_mod = @import("routes.zig");
pub const Route = routes_mod.Route;
pub const routes = routes_mod.routes;

const log = std.log.scoped(.verve);

/// Shared server-side counter state. Single-threaded std.http.Server, so
/// no atomics or locking needed at MVP scope.
pub var last_count: i32 = 0;

const TODO_MAX = 32;
const TODO_TEXT_MAX = 200;

// Fixed pool of slots — each holds up to TODO_TEXT_MAX bytes plus the active
// length. Avoids needing a heap allocator inside Action functions while still
// supporting append + remove for the demo.
var todo_slots: [TODO_MAX][TODO_TEXT_MAX]u8 = undefined;
var todo_lens: [TODO_MAX]usize = .{0} ** TODO_MAX;
var todo_count: usize = 0;

pub fn todos() []const []const u8 {
    const Storage = struct {
        var views: [TODO_MAX][]const u8 = undefined;
    };
    for (0..todo_count) |i| {
        Storage.views[i] = todo_slots[i][0..todo_lens[i]];
    }
    return Storage.views[0..todo_count];
}

pub const Actions = struct {
    pub fn updateDatabase(args: struct { new_count: i32 }) !void {
        last_count = args.new_count;
        log.info("updateDatabase: new_count={d}", .{args.new_count});
    }

    pub fn logMessage(args: struct { text: []const u8 }) !void {
        log.info("logMessage: {s}", .{args.text});
    }

    pub fn getCount(_: struct {}) !i32 {
        return last_count;
    }

    pub fn addTodo(args: struct { text: []const u8 }) !void {
        const trimmed = std.mem.trim(u8, args.text, &std.ascii.whitespace);
        if (trimmed.len == 0) return error.EmptyTodo;
        if (todo_count >= TODO_MAX) return error.TodoListFull;
        const len = @min(trimmed.len, TODO_TEXT_MAX);
        @memcpy(todo_slots[todo_count][0..len], trimmed[0..len]);
        todo_lens[todo_count] = len;
        todo_count += 1;
        log.info("addTodo: idx={d} text={s}", .{ todo_count - 1, trimmed[0..len] });
    }

    pub fn removeTodo(args: struct { index: usize }) !void {
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
