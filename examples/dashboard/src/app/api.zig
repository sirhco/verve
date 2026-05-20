//! Dashboard demo state + actions.
//!
//! Stress-tests the fluent component API across four pages worth of
//! widgets. All persistence is in-process (slot arrays + atomics) so
//! the demo restarts clean. Every mutation bumps `last_count` so the
//! SSE stream nudges open browsers to refresh.

const std = @import("std");

pub const components = @import("components.zig");
pub const routes_mod = @import("routes.zig");
pub const Route = routes_mod.Route;
pub const routes = routes_mod.routes;
pub const external = @import("external.zig");
pub const analytics = @import("analytics.zig");

comptime {
    // Force semantic analysis of the fetcher symbols so build errors
    // surface even before a route references them.
    _ = external.ensureFetcher;
    _ = external.snapshot;
    _ = external.fetchChuck;
    _ = external.fetchCarbon;
    _ = external.fetchDisney;
}

/// Approximate "now" in unix seconds. Stashed by the server before each
/// render so non-rendering paths (action handlers) can compute time
/// without needing an Io handle. Not monotonic across servers, fine for
/// sample bucketing.
pub var clock_unix: std.atomic.Value(i64) = .init(0);

pub fn stampClock(unix: i64) void {
    clock_unix.store(unix, .monotonic);
}

fn nowApprox() i64 {
    return clock_unix.load(.monotonic);
}

/// Bumped by the external fetcher after each successful refresh.
fn onExternalRefresh() void {
    _ = last_count.fetchAdd(1, .monotonic);
    const snap = external.snapshot();
    const total = snap.chuck.latency_ms + snap.carbon.latency_ms + snap.disney.list_latency_ms + snap.disney.detail_latency_ms_total;
    analytics.refresh_latency.push(total);
    analytics.recordMutation(nowApprox());
}

fn recordAppMutation() void {
    analytics.recordMutation(nowApprox());
}

/// Install the refresh callback exactly once. Idempotent.
pub fn wireExternalRefresh() void {
    external.on_refresh = &onExternalRefresh;
}

const log = std.log.scoped(.verve);

/// SSE "something changed" tick. Bumped on every mutation.
pub var last_count: std.atomic.Value(i32) = .init(0);

// ---- Tasks ---------------------------------------------------------------

pub const Column = enum(u2) {
    backlog = 0,
    doing = 1,
    done = 2,

    pub fn label(self: Column) []const u8 {
        return switch (self) {
            .backlog => "Backlog",
            .doing => "In progress",
            .done => "Done",
        };
    }

    pub fn slug(self: Column) []const u8 {
        return switch (self) {
            .backlog => "backlog",
            .doing => "doing",
            .done => "done",
        };
    }
};

pub const Priority = enum(u2) {
    low = 0,
    med = 1,
    high = 2,

    pub fn label(self: Priority) []const u8 {
        return switch (self) {
            .low => "Low",
            .med => "Med",
            .high => "High",
        };
    }
};

pub const TASK_MAX = 32;
pub const TASK_TITLE_MAX = 80;

pub const Task = struct {
    id: u32,
    title_buf: [TASK_TITLE_MAX]u8 = undefined,
    title_len: u32 = 0,
    column: Column = .backlog,
    priority: Priority = .med,
    assignee_idx: i16 = -1,

    pub fn titleSlice(self: *const Task) []const u8 {
        return self.title_buf[0..self.title_len];
    }
};

var task_slots: [TASK_MAX]Task = undefined;
var task_used: [TASK_MAX]bool = .{false} ** TASK_MAX;
var task_count: usize = 0;
var task_next_id: u32 = 1;
var task_mu: std.atomic.Mutex = .unlocked;

fn lockTasks() void {
    while (!task_mu.tryLock()) std.atomic.spinLoopHint();
}

var tasks_seeded: bool = false;

fn seedTasks() void {
    if (tasks_seeded) return;
    tasks_seeded = true;
    appendTaskUnlocked("Design new onboarding flow", .backlog, .high, 0) catch {};
    appendTaskUnlocked("Add S3 multipart uploads", .backlog, .med, 1) catch {};
    appendTaskUnlocked("Migrate auth to OIDC", .doing, .high, 0) catch {};
    appendTaskUnlocked("Rewrite billing webhook handler", .doing, .med, 2) catch {};
    appendTaskUnlocked("Add audit log export", .doing, .low, 3) catch {};
    appendTaskUnlocked("Document the metrics endpoint", .done, .low, 1) catch {};
    appendTaskUnlocked("Ship the dashboard example", .done, .med, 0) catch {};
}

fn appendTaskUnlocked(title: []const u8, col: Column, prio: Priority, assignee: i16) !void {
    if (task_count >= TASK_MAX) return error.Full;
    var slot: usize = 0;
    while (slot < TASK_MAX and task_used[slot]) : (slot += 1) {}
    if (slot == TASK_MAX) return error.Full;
    const t = &task_slots[slot];
    const len = @min(title.len, TASK_TITLE_MAX);
    @memcpy(t.title_buf[0..len], title[0..len]);
    t.title_len = @intCast(len);
    t.column = col;
    t.priority = prio;
    t.assignee_idx = assignee;
    t.id = task_next_id;
    task_next_id += 1;
    task_used[slot] = true;
    task_count += 1;
}

pub fn copyTasksInto(arena: std.mem.Allocator) ![]Task {
    lockTasks();
    defer task_mu.unlock();
    seedTasks();
    const out = try arena.alloc(Task, task_count);
    var w: usize = 0;
    for (0..TASK_MAX) |i| {
        if (!task_used[i]) continue;
        out[w] = task_slots[i];
        w += 1;
    }
    return out[0..w];
}

pub fn tasksByColumn(col: Column) u32 {
    lockTasks();
    defer task_mu.unlock();
    seedTasks();
    var n: u32 = 0;
    for (0..TASK_MAX) |i| {
        if (task_used[i] and task_slots[i].column == col) n += 1;
    }
    return n;
}

// ---- Members -------------------------------------------------------------

pub const MEMBER_MAX = 12;
pub const NAME_MAX = 48;
pub const ROLE_MAX = 32;

pub const Member = struct {
    id: u32,
    name_buf: [NAME_MAX]u8 = undefined,
    name_len: u32 = 0,
    role_buf: [ROLE_MAX]u8 = undefined,
    role_len: u32 = 0,
    status: Status = .active,

    pub const Status = enum { active, away, off };

    pub fn nameSlice(self: *const Member) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    pub fn roleSlice(self: *const Member) []const u8 {
        return self.role_buf[0..self.role_len];
    }

    pub fn statusLabel(self: *const Member) []const u8 {
        return switch (self.status) {
            .active => "Active",
            .away => "Away",
            .off => "Offline",
        };
    }

    pub fn statusSlug(self: *const Member) []const u8 {
        return switch (self.status) {
            .active => "active",
            .away => "away",
            .off => "off",
        };
    }

    pub fn initials(self: *const Member, out: []u8) []u8 {
        const name = self.nameSlice();
        var w: usize = 0;
        var at_start = true;
        for (name) |c| {
            if (c == ' ' or c == '\t') {
                at_start = true;
                continue;
            }
            if (at_start and w < out.len) {
                out[w] = std.ascii.toUpper(c);
                w += 1;
                if (w == 2) break;
                at_start = false;
            }
        }
        return out[0..w];
    }
};

var member_slots: [MEMBER_MAX]Member = undefined;
var member_used: [MEMBER_MAX]bool = .{false} ** MEMBER_MAX;
var member_count: usize = 0;
var member_next_id: u32 = 1;
var member_mu: std.atomic.Mutex = .unlocked;

fn lockMembers() void {
    while (!member_mu.tryLock()) std.atomic.spinLoopHint();
}

var members_seeded: bool = false;

fn seedMembers() void {
    if (members_seeded) return;
    members_seeded = true;
    appendMemberUnlocked("Ada Lovelace", "Tech Lead", .active) catch {};
    appendMemberUnlocked("Grace Hopper", "Compiler nerd", .active) catch {};
    appendMemberUnlocked("Linus Torvalds", "Kernel grump", .away) catch {};
    appendMemberUnlocked("Margaret Hamilton", "Reliability", .off) catch {};
}

fn appendMemberUnlocked(name: []const u8, role: []const u8, status: Member.Status) !void {
    if (member_count >= MEMBER_MAX) return error.Full;
    var slot: usize = 0;
    while (slot < MEMBER_MAX and member_used[slot]) : (slot += 1) {}
    if (slot == MEMBER_MAX) return error.Full;
    const m = &member_slots[slot];
    const nl = @min(name.len, NAME_MAX);
    @memcpy(m.name_buf[0..nl], name[0..nl]);
    m.name_len = @intCast(nl);
    const rl = @min(role.len, ROLE_MAX);
    @memcpy(m.role_buf[0..rl], role[0..rl]);
    m.role_len = @intCast(rl);
    m.status = status;
    m.id = member_next_id;
    member_next_id += 1;
    member_used[slot] = true;
    member_count += 1;
}

pub fn copyMembersInto(arena: std.mem.Allocator) ![]Member {
    lockMembers();
    defer member_mu.unlock();
    seedMembers();
    const out = try arena.alloc(Member, member_count);
    var w: usize = 0;
    for (0..MEMBER_MAX) |i| {
        if (!member_used[i]) continue;
        out[w] = member_slots[i];
        w += 1;
    }
    return out[0..w];
}

pub fn memberCount() usize {
    lockMembers();
    defer member_mu.unlock();
    seedMembers();
    return member_count;
}

pub fn memberByIdx(idx: i16, arena: std.mem.Allocator) !?[]const u8 {
    if (idx < 0) return null;
    lockMembers();
    defer member_mu.unlock();
    seedMembers();
    var seen: i16 = 0;
    for (0..MEMBER_MAX) |i| {
        if (!member_used[i]) continue;
        if (seen == idx) return try arena.dupe(u8, member_slots[i].nameSlice());
        seen += 1;
    }
    return null;
}

// ---- Settings ------------------------------------------------------------

pub const Theme = enum { dark, light, auto };
pub const Density = enum { compact, cozy, comfy };

pub const Settings = struct {
    theme: Theme = .dark,
    density: Density = .cozy,
    notifications: bool = true,
    digest_weekly: bool = false,
    accent: [16]u8 = ("#1f6feb" ++ ("\x00" ** 9)).*,
    accent_len: u8 = 7,
    refresh_seconds: u8 = 5,

    pub fn accentSlice(self: *const Settings) []const u8 {
        return self.accent[0..self.accent_len];
    }
};

pub var settings: Settings = .{};
var settings_mu: std.atomic.Mutex = .unlocked;

fn lockSettings() void {
    while (!settings_mu.tryLock()) std.atomic.spinLoopHint();
}

// ---- Activity log --------------------------------------------------------

pub const ACTIVITY_MAX = 16;
pub const ACTIVITY_TEXT_MAX = 160;

pub const Activity = struct {
    text_buf: [ACTIVITY_TEXT_MAX]u8 = undefined,
    text_len: u32 = 0,
    kind_buf: [16]u8 = undefined,
    kind_len: u32 = 0,

    pub fn textSlice(self: *const Activity) []const u8 {
        return self.text_buf[0..self.text_len];
    }
    pub fn kindSlice(self: *const Activity) []const u8 {
        return self.kind_buf[0..self.kind_len];
    }
};

var activity_ring: [ACTIVITY_MAX]Activity = undefined;
var activity_head: usize = 0;
var activity_count: usize = 0;
var activity_mu: std.atomic.Mutex = .unlocked;

fn pushActivity(kind: []const u8, text: []const u8) void {
    while (!activity_mu.tryLock()) std.atomic.spinLoopHint();
    defer activity_mu.unlock();
    const slot = (activity_head + activity_count) % ACTIVITY_MAX;
    var dst: *Activity = &activity_ring[slot];
    const tl = @min(text.len, ACTIVITY_TEXT_MAX);
    @memcpy(dst.text_buf[0..tl], text[0..tl]);
    dst.text_len = @intCast(tl);
    const kl = @min(kind.len, 16);
    @memcpy(dst.kind_buf[0..kl], kind[0..kl]);
    dst.kind_len = @intCast(kl);
    if (activity_count < ACTIVITY_MAX) {
        activity_count += 1;
    } else {
        activity_head = (activity_head + 1) % ACTIVITY_MAX;
    }
}

pub fn copyActivityInto(arena: std.mem.Allocator) ![]Activity {
    while (!activity_mu.tryLock()) std.atomic.spinLoopHint();
    defer activity_mu.unlock();
    const out = try arena.alloc(Activity, activity_count);
    var w: usize = 0;
    var i: usize = 0;
    while (i < activity_count) : (i += 1) {
        const idx = (activity_head + activity_count - 1 - i) % ACTIVITY_MAX;
        out[w] = activity_ring[idx];
        w += 1;
    }
    return out[0..w];
}

// ---- Actions -------------------------------------------------------------

pub const Actions = struct {
    pub fn addTask(args: struct {
        title: []const u8,
        column: []const u8 = "backlog",
        priority: []const u8 = "med",
    }) !void {
        const trimmed = std.mem.trim(u8, args.title, &std.ascii.whitespace);
        if (trimmed.len == 0) return error.EmptyTitle;
        const col = parseColumn(args.column);
        const prio = parsePriority(args.priority);
        lockTasks();
        seedTasks();
        appendTaskUnlocked(trimmed, col, prio, -1) catch |e| {
            task_mu.unlock();
            return e;
        };
        task_mu.unlock();
        pushActivity("task", trimmed);
        _ = last_count.fetchAdd(1, .monotonic);
        recordAppMutation();
    }

    pub fn moveTask(args: struct { id: u32, column: []const u8 }) !void {
        const col = parseColumn(args.column);
        lockTasks();
        defer task_mu.unlock();
        for (0..TASK_MAX) |i| {
            if (!task_used[i]) continue;
            if (task_slots[i].id == args.id) {
                task_slots[i].column = col;
                _ = last_count.fetchAdd(1, .monotonic);
                recordAppMutation();
                return;
            }
        }
        return error.NotFound;
    }

    pub fn removeTask(args: struct { id: u32 }) !void {
        lockTasks();
        defer task_mu.unlock();
        for (0..TASK_MAX) |i| {
            if (!task_used[i]) continue;
            if (task_slots[i].id == args.id) {
                task_used[i] = false;
                task_count -= 1;
                _ = last_count.fetchAdd(1, .monotonic);
                recordAppMutation();
                return;
            }
        }
        return error.NotFound;
    }

    pub fn addMember(args: struct { name: []const u8, role: []const u8 = "Engineer" }) !void {
        const trimmed_name = std.mem.trim(u8, args.name, &std.ascii.whitespace);
        if (trimmed_name.len == 0) return error.EmptyName;
        lockMembers();
        seedMembers();
        appendMemberUnlocked(trimmed_name, args.role, .active) catch |e| {
            member_mu.unlock();
            return e;
        };
        member_mu.unlock();
        pushActivity("team", trimmed_name);
        _ = last_count.fetchAdd(1, .monotonic);
        recordAppMutation();
    }

    pub fn removeMember(args: struct { id: u32 }) !void {
        lockMembers();
        defer member_mu.unlock();
        for (0..MEMBER_MAX) |i| {
            if (!member_used[i]) continue;
            if (member_slots[i].id == args.id) {
                member_used[i] = false;
                member_count -= 1;
                _ = last_count.fetchAdd(1, .monotonic);
                recordAppMutation();
                return;
            }
        }
        return error.NotFound;
    }

    pub fn saveSettings(args: struct {
        theme: []const u8 = "dark",
        density: []const u8 = "cozy",
        notifications: []const u8 = "",
        digest_weekly: []const u8 = "",
        accent: []const u8 = "#1f6feb",
        refresh_seconds: u8 = 5,
    }) !void {
        lockSettings();
        defer settings_mu.unlock();
        settings.theme = parseTheme(args.theme);
        settings.density = parseDensity(args.density);
        settings.notifications = checkboxTruthy(args.notifications);
        settings.digest_weekly = checkboxTruthy(args.digest_weekly);
        const al = @min(args.accent.len, 16);
        @memcpy(settings.accent[0..al], args.accent[0..al]);
        settings.accent_len = @intCast(al);
        settings.refresh_seconds = if (args.refresh_seconds < 1) 1 else if (args.refresh_seconds > 60) 60 else args.refresh_seconds;
        pushActivity("settings", "preferences updated");
        _ = last_count.fetchAdd(1, .monotonic);
        recordAppMutation();
    }
};

fn parseColumn(s: []const u8) Column {
    if (std.mem.eql(u8, s, "doing")) return .doing;
    if (std.mem.eql(u8, s, "done")) return .done;
    return .backlog;
}

fn parsePriority(s: []const u8) Priority {
    if (std.mem.eql(u8, s, "low")) return .low;
    if (std.mem.eql(u8, s, "high")) return .high;
    return .med;
}

fn parseTheme(s: []const u8) Theme {
    if (std.mem.eql(u8, s, "light")) return .light;
    if (std.mem.eql(u8, s, "auto")) return .auto;
    return .dark;
}

fn parseDensity(s: []const u8) Density {
    if (std.mem.eql(u8, s, "compact")) return .compact;
    if (std.mem.eql(u8, s, "comfy")) return .comfy;
    return .cozy;
}

fn checkboxTruthy(s: []const u8) bool {
    return s.len > 0 and !std.mem.eql(u8, s, "0") and !std.mem.eql(u8, s, "off");
}
