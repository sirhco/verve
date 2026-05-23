//! Example IPC routes. The window invokes `onMessage` for every JSON
//! payload `window.verve.send(...)` ships from the frontend. The match
//! on `type` is plain string equality — replace with a `std.StaticStringMap`
//! once the route table grows past a handful of entries.

const std = @import("std");
const desktop = @import("desktop");

var window_ref: ?*desktop.Window = null;
var asset_ref: []const desktop.AssetEntry = &.{};
var child_window: ?desktop.Window = null;

pub fn attach(window: *desktop.Window, assets: []const desktop.AssetEntry) void {
    window_ref = window;
    asset_ref = assets;
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

    if (std.mem.eql(u8, msg_type.string, "cookie_set")) {
        handleCookieSet(root) catch |err| std.log.warn("cookie_set: {s}", .{@errorName(err)});
        return;
    }

    if (std.mem.eql(u8, msg_type.string, "cookie_get")) {
        handleCookieGet(root) catch |err| std.log.warn("cookie_get: {s}", .{@errorName(err)});
        return;
    }

    if (std.mem.eql(u8, msg_type.string, "cookie_clear")) {
        const w = window_ref orelse return;
        w.cookies().clear() catch |err| {
            std.log.warn("cookie_clear: {s}", .{@errorName(err)});
            return;
        };
        reply("{\"type\":\"cookie_cleared\"}");
        return;
    }

    if (std.mem.eql(u8, msg_type.string, "open_child")) {
        openChild() catch |err| std.log.warn("open_child: {s}", .{@errorName(err)});
        return;
    }

    std.log.info("ipc: unhandled message type='{s}'", .{msg_type.string});
}

fn handleCookieSet(root: std.json.Value) !void {
    const w = window_ref orelse return;
    const name_v = root.object.get("name") orelse return;
    const value_v = root.object.get("value") orelse return;
    if (name_v != .string or value_v != .string) return;

    try w.cookies().set(.{
        .name = name_v.string,
        .value = value_v.string,
        .domain = "localhost",
        .path = "/",
    });
    reply("{\"type\":\"cookie_set_ok\"}");
}

fn handleCookieGet(root: std.json.Value) !void {
    const w = window_ref orelse return;
    const name_v = root.object.get("name") orelse return;
    if (name_v != .string) return;

    const alloc = std.heap.page_allocator;
    const got = try w.cookies().get(alloc, name_v.string);
    if (got) |c| {
        defer alloc.free(c.name);
        defer alloc.free(c.value);
        defer alloc.free(c.domain);
        defer alloc.free(c.path);

        const json = try std.json.Stringify.valueAlloc(alloc, .{
            .type = "cookie_value",
            .name = c.name,
            .value = c.value,
            .domain = c.domain,
            .path = c.path,
        }, .{});
        defer alloc.free(json);
        reply(json);
    } else {
        reply("{\"type\":\"cookie_value\",\"value\":null}");
    }
}

fn openChild() !void {
    const w = window_ref orelse return;
    if (child_window != null) {
        std.log.info("open_child: already open — ignoring", .{});
        return;
    }
    child_window = try w.openChildWindow(.{
        .title = "Verve Desktop — child",
        .width = 640,
        .height = 400,
        .assets = asset_ref,
        .initial_path = "index.html",
        .scheme = "verve",
    });
}

fn reply(json: []const u8) void {
    const w = window_ref orelse return;
    var buf: [4096]u8 = undefined;
    const script = std.fmt.bufPrint(&buf, "window.verve._dispatch({s})", .{json}) catch return;
    w.evalJs(script);
}
