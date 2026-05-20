const std = @import("std");
const verve = @import("verve");
const components = @import("components.zig");
const api = @import("api.zig");

pub const Route = struct {
    path: []const u8,
    render: *const fn (ctx: *const verve.Context) anyerror!*verve.Node,
};

pub const routes: []const Route = &.{
    .{ .path = "/", .render = renderOverview },
    .{ .path = "/tasks", .render = renderTasks },
    .{ .path = "/team", .render = renderTeam },
    .{ .path = "/external", .render = renderExternal },
    .{ .path = "/analytics", .render = renderAnalytics },
    .{ .path = "/live", .render = renderLive },
    .{ .path = "/settings", .render = renderSettings },
};

fn renderOverview(ctx: *const verve.Context) !*verve.Node {
    const tasks = try api.copyTasksInto(ctx.alloc());
    const members = try api.copyMembersInto(ctx.alloc());
    const activity = try api.copyActivityInto(ctx.alloc());
    const body = try components.overview(ctx, tasks, members, activity);
    return components.shell(ctx, "Overview", "/", body);
}

fn renderTasks(ctx: *const verve.Context) !*verve.Node {
    const tasks = try api.copyTasksInto(ctx.alloc());
    const members = try api.copyMembersInto(ctx.alloc());
    const body = try components.tasksPage(ctx, tasks, members);
    return components.shell(ctx, "Tasks", "/tasks", body);
}

fn renderTeam(ctx: *const verve.Context) !*verve.Node {
    const members = try api.copyMembersInto(ctx.alloc());
    const body = try components.teamPage(ctx, members);
    return components.shell(ctx, "Team", "/team", body);
}

fn renderSettings(ctx: *const verve.Context) !*verve.Node {
    const body = try components.settingsPage(ctx);
    return components.shell(ctx, "Settings", "/settings", body);
}

fn renderAnalytics(ctx: *const verve.Context) !*verve.Node {
    if (ctx.io) |io| {
        api.wireExternalRefresh();
        api.external.ensureFetcher(io);
    }
    const body = try components.analyticsPage(ctx);
    return components.shell(ctx, "Analytics", "/analytics", body);
}

fn renderLive(ctx: *const verve.Context) !*verve.Node {
    const body = try components.livePage(ctx);
    return components.shell(ctx, "Live chat", "/live", body);
}

fn renderExternal(ctx: *const verve.Context) !*verve.Node {
    // Lazy-start the background fetcher on first visit. Idempotent.
    if (ctx.io) |io| {
        api.wireExternalRefresh();
        api.external.ensureFetcher(io);
    }
    // Snapshot has internal []const u8 slices that point at its own buffers,
    // so the Node tree (which stores those slices by reference) must outlive
    // any local copy. Allocate into the request arena.
    const snap_ptr = try ctx.alloc().create(api.external.Snapshot);
    snap_ptr.* = api.external.snapshot();
    const body = try components.externalPage(ctx, snap_ptr);
    return components.shell(ctx, "External APIs", "/external", body);
}
