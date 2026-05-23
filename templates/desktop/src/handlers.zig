//! Example IPC routes. The window invokes `onMessage` for every JSON
//! payload `window.verve.send(...)` ships from the frontend. The match
//! on `type` is plain string equality — replace with a `std.StaticStringMap`
//! once the route table grows past a handful of entries.

const std = @import("std");
const desktop = @import("desktop");

var window_ref: ?*desktop.Window = null;

pub fn attach(window: *desktop.Window) void {
    window_ref = window;
}

pub fn onMessage(_: ?*anyopaque, payload: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, payload, .{}) catch {
        std.log.warn("ipc: malformed json: {s}", .{payload});
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    const msg_type = root.object.get("type") orelse return;
    if (msg_type != .string) return;

    if (std.mem.eql(u8, msg_type.string, "ping")) {
        reply("{\"type\":\"pong\",\"echo\":true}");
        return;
    }

    if (std.mem.eql(u8, msg_type.string, "log")) {
        const m = root.object.get("message") orelse return;
        if (m == .string) std.log.info("[ui] {s}", .{m.string});
        return;
    }

    std.log.info("ipc: unhandled message type='{s}'", .{msg_type.string});
}

fn reply(json: []const u8) void {
    const w = window_ref orelse return;
    var buf: [4096]u8 = undefined;
    const script = std.fmt.bufPrint(&buf, "window.verve._dispatch({s})", .{json}) catch return;
    w.evalJs(script);
}
