//! Dashboard widget gallery — pages, cards, tables, forms, badges, sliders.

const std = @import("std");
const verve = @import("verve");
const api = @import("api.zig");
const external = api.external;

// ============================================================================
// Shared widgets
// ============================================================================

/// Small uppercase label/value chip used for KPIs, stats, badges.
fn kpiCard(
    ctx: *const verve.Context,
    label_text: []const u8,
    value: []const u8,
    delta: ?[]const u8,
    accent: []const u8,
) *verve.Node {
    const card = ctx.div().class("kpi").attr("data-accent", accent).children(.{
        ctx.div().class("kpi-label").text(label_text),
        ctx.div().class("kpi-value").text(value),
    });
    if (delta) |d| _ = card.children(.{ ctx.div().class("kpi-delta").text(d) });
    return card;
}

fn badge(ctx: *const verve.Context, kind: []const u8, label_text: []const u8) *verve.Node {
    return ctx.span().class("badge").attr("data-kind", kind).text(label_text);
}

fn progressBar(ctx: *const verve.Context, pct: u32, color: []const u8) *verve.Node {
    return ctx.div().class("progress").children(.{
        ctx.div().class("progress-fill")
            .attrFmt("style", "width:{d}%;background:{s}", .{ pct, color }),
    });
}

fn avatar(ctx: *const verve.Context, member: *const api.Member) *verve.Node {
    var buf: [2]u8 = undefined;
    const ini = member.initials(&buf);
    return ctx.div().class("avatar").attr("data-status", member.statusSlug()).children(.{
        ctx.span().class("avatar-initials").text(ini),
    });
}

fn breadcrumb(ctx: *const verve.Context, parts: []const []const u8) *verve.Node {
    const bc = ctx.nav().class("breadcrumb");
    for (parts, 0..) |part, i| {
        if (i > 0) _ = bc.children(.{ ctx.span().class("breadcrumb-sep").text("›") });
        _ = bc.children(.{ ctx.span().class("breadcrumb-part").text(part) });
    }
    return bc;
}

fn alertBanner(
    ctx: *const verve.Context,
    kind: []const u8,
    title_text: []const u8,
    body_text: []const u8,
) *verve.Node {
    return ctx.div().class("alert").attr("data-kind", kind).children(.{
        ctx.div().class("alert-icon").text(alertIcon(kind)),
        ctx.div().class("alert-body").children(.{
            ctx.div().class("alert-title").text(title_text),
            ctx.div().class("alert-text").text(body_text),
        }),
    });
}

fn alertIcon(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "warn")) return "!";
    if (std.mem.eql(u8, kind, "error")) return "×";
    if (std.mem.eql(u8, kind, "ok")) return "✓";
    return "i";
}

fn statTile(
    ctx: *const verve.Context,
    label_text: []const u8,
    value: anytype,
    icon: []const u8,
) *verve.Node {
    return ctx.div().class("stat-tile").children(.{
        ctx.div().class("stat-icon").text(icon),
        ctx.div().class("stat-meta").children(.{
            ctx.div().class("stat-label").text(label_text),
            ctx.div().class("stat-value").textInt(value),
        }),
    });
}

fn taskCard(ctx: *const verve.Context, t: *const api.Task, members: []const api.Member) *verve.Node {
    const card = ctx.div().class("task-card")
        .attr("data-priority", t.priority.label())
        .attrFmt("data-task-id", "{d}", .{t.id})
        .attr("data-filterable", "true")
        .attrFmt("data-filter-text", "task {s} {s}", .{ t.titleSlice(), t.priority.label() })
        .attr("draggable", "true")
        .attr("tabindex", "0")
        .role("group")
        .ariaLabel(t.titleSlice())
        .children(.{
            ctx.div().class("task-head").children(.{
                ctx.span().class("task-title").text(t.titleSlice()),
                badge(ctx, t.priority.label(), t.priority.label()),
            }),
        });

    if (t.assignee_idx >= 0) {
        const idx: usize = @intCast(t.assignee_idx);
        if (idx < members.len) {
            _ = card.children(.{
                ctx.div().class("task-assignee").children(.{
                    avatar(ctx, &members[idx]),
                    ctx.span().class("task-assignee-name").text(members[idx].nameSlice()),
                }),
            });
        }
    }

    const actions = ctx.div().class("task-actions");
    for ([_]api.Column{ .backlog, .doing, .done }) |col| {
        if (col == t.column) continue;
        _ = actions.children(.{
            ctx.form(.{ .post = "/api/moveTask" }).children(.{
                ctx.input().type_("hidden").name("id").attrFmt("value", "{d}", .{t.id}),
                ctx.input().type_("hidden").name("column").value(col.slug()),
                ctx.button(col.label()).type_("submit").class("ghost"),
            }),
        });
    }
    _ = actions.children(.{
        ctx.form(.{ .post = "/api/removeTask" }).children(.{
            ctx.input().type_("hidden").name("id").attrFmt("value", "{d}", .{t.id}),
            ctx.button("Delete").type_("submit").class("danger ghost"),
        }),
    });

    return card.children(.{actions});
}

fn memberCard(ctx: *const verve.Context, m: *const api.Member) *verve.Node {
    return ctx.div().class("member-card")
        .attr("data-filterable", "true")
        .attrFmt("data-filter-text", "member {s} {s} {s}", .{ m.nameSlice(), m.roleSlice(), m.statusSlug() })
        .children(.{
        ctx.div().class("member-head").children(.{
            avatar(ctx, m),
            ctx.div().class("member-meta").children(.{
                ctx.div().class("member-name").text(m.nameSlice()),
                ctx.div().class("member-role").text(m.roleSlice()),
            }),
        }),
        ctx.div().class("member-foot").children(.{
            badge(ctx, m.statusSlug(), m.statusLabel()),
            ctx.form(.{ .post = "/api/removeMember" }).children(.{
                ctx.input().type_("hidden").name("id").attrFmt("value", "{d}", .{m.id}),
                ctx.button("Remove").type_("submit").class("danger ghost small"),
            }),
        }),
    });
}

fn activityRow(ctx: *const verve.Context, a: *const api.Activity) *verve.Node {
    return ctx.li().class("activity-row").attr("data-kind", a.kindSlice()).children(.{
        ctx.span().class("activity-pill").text(a.kindSlice()),
        ctx.span().class("activity-text").text(a.textSlice()),
    });
}

// ============================================================================
// Overview page — KPIs, mini chart, activity feed, alerts
// ============================================================================

pub fn overview(
    ctx: *const verve.Context,
    tasks: []const api.Task,
    members: []const api.Member,
    activity: []const api.Activity,
) !*verve.Node {
    var done_count: u32 = 0;
    var doing_count: u32 = 0;
    var backlog_count: u32 = 0;
    for (tasks) |*t| switch (t.column) {
        .done => done_count += 1,
        .doing => doing_count += 1,
        .backlog => backlog_count += 1,
    };

    var active_members: u32 = 0;
    for (members) |*m| if (m.status == .active) {
        active_members += 1;
    };

    const total_tasks: u32 = @intCast(tasks.len);
    const pct_done: u32 = if (total_tasks == 0) 0 else (done_count * 100) / total_tasks;
    const pct_doing: u32 = if (total_tasks == 0) 0 else (doing_count * 100) / total_tasks;
    const pct_backlog: u32 = if (total_tasks == 0) 0 else (backlog_count * 100) / total_tasks;

    const root = ctx.div().class("page page-overview").children(.{
        ctx.div().class("page-head").children(.{
            breadcrumb(ctx, &.{ "Home", "Overview" }),
            ctx.div().class("page-head-row").children(.{
                ctx.h1("Overview"),
                ctx.div().class("page-head-actions").children(.{
                    ctx.a("/tasks", "Open tasks →").class("button primary"),
                    ctx.a("/team", "Manage team").class("button ghost"),
                }),
            }),
        }),
        alertBanner(
            ctx,
            "ok",
            "All systems nominal",
            "No incidents in the last 24h. Rolling deploy completed cleanly at 14:02 UTC.",
        ),
        ctx.div().class("grid grid-4").children(.{
            kpiCard(ctx, "Active tasks", labelInt(ctx, total_tasks), "+3 this week", "#1f6feb"),
            kpiCard(ctx, "In progress", labelInt(ctx, doing_count), null, "#d29922"),
            kpiCard(ctx, "Shipped", labelInt(ctx, done_count), "+1 today", "#2ea043"),
            kpiCard(ctx, "Teammates", labelInt(ctx, @as(u32, @intCast(members.len))), null, "#a371f7"),
        }),
        ctx.div().class("grid grid-2-1").children(.{
            ctx.div().class("card").children(.{
                ctx.div().class("card-head").children(.{
                    ctx.h2("Pipeline"),
                    badge(ctx, "info", "Live"),
                }),
                ctx.div().class("card-body").children(.{
                    ctx.div().class("chart").children(.{
                        ctx.div().class("chart-row").children(.{
                            ctx.span().class("chart-label").text("Backlog"),
                            progressBar(ctx, pct_backlog, "#6e7681"),
                            ctx.span().class("chart-value").textFmt("{d} · {d}%", .{ backlog_count, pct_backlog }),
                        }),
                        ctx.div().class("chart-row").children(.{
                            ctx.span().class("chart-label").text("In progress"),
                            progressBar(ctx, pct_doing, "#d29922"),
                            ctx.span().class("chart-value").textFmt("{d} · {d}%", .{ doing_count, pct_doing }),
                        }),
                        ctx.div().class("chart-row").children(.{
                            ctx.span().class("chart-label").text("Done"),
                            progressBar(ctx, pct_done, "#2ea043"),
                            ctx.span().class("chart-value").textFmt("{d} · {d}%", .{ done_count, pct_done }),
                        }),
                    }),
                }),
            }),
            ctx.div().class("card").children(.{
                ctx.div().class("card-head").children(.{ ctx.h2("Status") }),
                ctx.div().class("card-body stats-grid").children(.{
                    statTile(ctx, "Online now", active_members, "●"),
                    statTile(ctx, "Open PRs", @as(u32, 7), "↑"),
                    statTile(ctx, "p95 latency", @as(u32, 82), "ms"),
                    statTile(ctx, "Uptime", @as(u32, 99), "%"),
                }),
            }),
        }),
    });

    // Activity feed card.
    const activity_card = ctx.div().class("card").children(.{
        ctx.div().class("card-head").children(.{
            ctx.h2("Recent activity"),
            ctx.a("/tasks", "View all →").class("link"),
        }),
    });

    if (activity.len == 0) {
        _ = activity_card.children(.{
            ctx.div().class("card-body empty")
                .text("Nothing yet — every action across tasks, team, and settings appears here."),
        });
    } else {
        const list = ctx.ul().class("activity-list");
        for (activity) |*item| {
            _ = list.children(.{activityRow(ctx, item)});
        }
        _ = activity_card.children(.{ ctx.div().class("card-body").children(.{list}) });
    }
    _ = root.children(.{activity_card});

    return root.build();
}

fn labelInt(ctx: *const verve.Context, n: u32) []const u8 {
    return std.fmt.allocPrint(ctx.alloc(), "{d}", .{n}) catch "?";
}

// ============================================================================
// Tasks page — kanban + add form
// ============================================================================

pub fn tasksPage(
    ctx: *const verve.Context,
    tasks: []const api.Task,
    members: []const api.Member,
) !*verve.Node {
    const root = ctx.div().class("page page-tasks").children(.{
        ctx.div().class("page-head").children(.{
            breadcrumb(ctx, &.{ "Home", "Tasks" }),
            ctx.div().class("page-head-row").children(.{
                ctx.h1("Tasks"),
                ctx.div().class("page-head-actions").children(.{
                    badge(ctx, "info", "Kanban"),
                    badge(ctx, "warn", "Live SSE"),
                }),
            }),
        }),
        ctx.div().class("card").children(.{
            ctx.div().class("card-head").children(.{ ctx.h2("Add a task") }),
            ctx.div().class("card-body").children(.{
                ctx.form(.{ .post = "/api/addTask", .class = "form-row" }).ariaLabel("Add a new task").children(.{
                    ctx.input().name("title").type_("text").placeholder("New task title")
                        .ariaLabel("Task title").required().attr("maxlength", "80"),
                    ctx.select().name("column").ariaLabel("Initial column").children(.{
                        ctx.option("backlog", "Backlog"),
                        ctx.option("doing", "In progress"),
                        ctx.option("done", "Done"),
                    }),
                    ctx.select().name("priority").ariaLabel("Priority").children(.{
                        ctx.option("low", "Low priority"),
                        ctx.option("med", "Medium").attr("selected", "true"),
                        ctx.option("high", "High priority"),
                    }),
                    ctx.button("Add task").type_("submit").class("primary"),
                }),
            }),
        }),
    });

    // Kanban columns.
    const board = ctx.div().class("kanban");
    for ([_]api.Column{ .backlog, .doing, .done }) |col| {
        const col_node = ctx.div().class("kanban-col").attr("data-col", col.slug()).children(.{
            ctx.div().class("kanban-head").children(.{
                ctx.h3(col.label()),
                badge(ctx, col.slug(), labelInt(ctx, countInColumn(tasks, col))),
            }),
        });

        const stack = ctx.div().class("kanban-stack")
            .attr("data-drop-column", col.slug())
            .ariaLabel(col.label());
        var any = false;
        for (tasks) |*t| {
            if (t.column != col) continue;
            _ = stack.children(.{taskCard(ctx, t, members)});
            any = true;
        }
        if (!any) _ = stack.children(.{ ctx.div().class("kanban-empty").text("Drop a task here.") });
        _ = col_node.children(.{stack});
        _ = board.children(.{col_node});
    }
    _ = root.children(.{board});

    return root.build();
}

fn countInColumn(tasks: []const api.Task, col: api.Column) u32 {
    var n: u32 = 0;
    for (tasks) |*t| if (t.column == col) {
        n += 1;
    };
    return n;
}

// ============================================================================
// Team page — member cards + add form
// ============================================================================

pub fn teamPage(ctx: *const verve.Context, members: []const api.Member) !*verve.Node {
    const root = ctx.div().class("page page-team").children(.{
        ctx.div().class("page-head").children(.{
            breadcrumb(ctx, &.{ "Home", "Team" }),
            ctx.div().class("page-head-row").children(.{
                ctx.h1("Team"),
                ctx.div().class("page-head-actions").children(.{
                    badge(ctx, "ok", labelStatusCount(ctx, members, .active)),
                    badge(ctx, "warn", labelStatusCount(ctx, members, .away)),
                    badge(ctx, "off", labelStatusCount(ctx, members, .off)),
                }),
            }),
        }),
        ctx.div().class("card").children(.{
            ctx.div().class("card-head").children(.{ ctx.h2("Add a teammate") }),
            ctx.div().class("card-body").children(.{
                ctx.form(.{ .post = "/api/addMember", .class = "form-row" }).ariaLabel("Add a teammate").children(.{
                    ctx.input().name("name").type_("text").placeholder("Full name")
                        .ariaLabel("Full name").required().attr("maxlength", "48"),
                    ctx.input().name("role").type_("text").placeholder("Role (default: Engineer)")
                        .ariaLabel("Role").attr("maxlength", "32"),
                    ctx.button("Add teammate").type_("submit").class("primary"),
                }),
            }),
        }),
    });

    if (members.len == 0) {
        _ = root.children(.{
            ctx.div().class("card empty-card")
                .text("Nobody on the roster yet. Add the first teammate above."),
        });
    } else {
        const grid = ctx.div().class("grid grid-3");
        for (members) |*m| {
            _ = grid.children(.{memberCard(ctx, m)});
        }
        _ = root.children(.{grid});
    }

    // Roster table — same data, different view to exercise table widgets.
    if (members.len > 0) {
        const table = ctx.el("table").class("roster-table").children(.{
            ctx.el("caption").text("Team roster"),
            ctx.el("thead").children(.{
                ctx.el("tr").children(.{
                    ctx.el("th").attr("scope", "col").text("Name"),
                    ctx.el("th").attr("scope", "col").text("Role"),
                    ctx.el("th").attr("scope", "col").text("Status"),
                    ctx.el("th").attr("scope", "col").text("ID"),
                }),
            }),
        });
        const tbody = ctx.el("tbody");
        for (members) |*m| {
            _ = tbody.children(.{
                ctx.el("tr").children(.{
                    ctx.el("td").text(m.nameSlice()),
                    ctx.el("td").text(m.roleSlice()),
                    ctx.el("td").children(.{badge(ctx, m.statusSlug(), m.statusLabel())}),
                    ctx.el("td").class("mono").textFmt("#{d}", .{m.id}),
                }),
            });
        }
        _ = table.children(.{tbody});

        _ = root.children(.{
            ctx.div().class("card").children(.{
                ctx.div().class("card-head").children(.{ ctx.h2("Roster table") }),
                ctx.div().class("card-body").children(.{table}),
            }),
        });
    }

    return root.build();
}

fn labelStatusCount(
    ctx: *const verve.Context,
    members: []const api.Member,
    status: api.Member.Status,
) []const u8 {
    var n: u32 = 0;
    for (members) |*m| if (m.status == status) {
        n += 1;
    };
    const status_label: []const u8 = switch (status) {
        .active => "active",
        .away => "away",
        .off => "off",
    };
    return std.fmt.allocPrint(ctx.alloc(), "{d} {s}", .{ n, status_label }) catch status_label;
}

// ============================================================================
// Settings page — toggles, sliders, color, radio groups
// ============================================================================

pub fn settingsPage(ctx: *const verve.Context) !*verve.Node {
    // Use a pointer to the global so the slice returned by
    // `accentSlice()` stays valid through render. A by-value copy here
    // would put `s` on the stack of this fn and the slice would
    // dangle after the chain returns.
    const s = &api.settings;

    return ctx.div().class("page page-settings").children(.{
        ctx.div().class("page-head").children(.{
            breadcrumb(ctx, &.{ "Home", "Settings" }),
            ctx.div().class("page-head-row").children(.{
                ctx.h1("Settings"),
                badge(ctx, "info", "All changes save instantly"),
            }),
        }),
        ctx.form(.{ .post = "/api/saveSettings", .class = "settings-form" }).children(.{
            // Section: appearance
            ctx.div().class("card").children(.{
                ctx.div().class("card-head").children(.{ ctx.h2("Appearance") }),
                ctx.div().class("card-body settings-grid").children(.{
                    settingLabel(ctx, "Theme", "Choose the color palette used across the dashboard."),
                    ctx.div().class("radio-group").children(.{
                        radioOption(ctx, "theme", "dark", "Dark", s.theme == .dark),
                        radioOption(ctx, "theme", "light", "Light", s.theme == .light),
                        radioOption(ctx, "theme", "auto", "Auto", s.theme == .auto),
                    }),
                    settingLabel(ctx, "Density", "How tight the layouts pack content."),
                    ctx.div().class("radio-group").children(.{
                        radioOption(ctx, "density", "compact", "Compact", s.density == .compact),
                        radioOption(ctx, "density", "cozy", "Cozy", s.density == .cozy),
                        radioOption(ctx, "density", "comfy", "Comfy", s.density == .comfy),
                    }),
                    settingLabel(ctx, "Accent color", "Primary highlight color for buttons and active states."),
                    ctx.div().class("inline-row").children(.{
                        ctx.input().name("accent").type_("color").value(s.accentSlice()).ariaLabel("Accent color"),
                        ctx.span().class("color-readout").text(s.accentSlice()),
                    }),
                }),
            }),
            // Section: notifications
            ctx.div().class("card").children(.{
                ctx.div().class("card-head").children(.{ ctx.h2("Notifications") }),
                ctx.div().class("card-body settings-grid").children(.{
                    settingLabel(ctx, "Push notifications", "Browser-level alerts for new tasks and mentions."),
                    toggleSwitch(ctx, "notifications", s.notifications),
                    settingLabel(ctx, "Weekly digest", "Email summary of activity every Monday."),
                    toggleSwitch(ctx, "digest_weekly", s.digest_weekly),
                }),
            }),
            // Section: performance
            ctx.div().class("card").children(.{
                ctx.div().class("card-head").children(.{ ctx.h2("Performance") }),
                ctx.div().class("card-body settings-grid").children(.{
                    settingLabel(ctx, "Refresh cadence", "How often (in seconds) the dashboard polls for updates."),
                    ctx.div().class("inline-row").children(.{
                        ctx.input().name("refresh_seconds").type_("range").attr("min", "1").attr("max", "60").attrFmt("value", "{d}", .{s.refresh_seconds})
                            .ariaLabel("Refresh cadence in seconds"),
                        ctx.span().class("range-readout").textFmt("{d}s", .{s.refresh_seconds}),
                    }),
                }),
            }),
            // Save row.
            ctx.div().class("settings-actions").children(.{
                ctx.button("Save preferences").type_("submit").class("primary"),
                ctx.a("/", "Cancel").class("button ghost"),
            }),
        }),
        // Help accordion.
        ctx.div().class("card").children(.{
            ctx.div().class("card-head").children(.{ ctx.h2("Help & tips") }),
            ctx.div().class("card-body").children(.{
                accordionItem(ctx, "Where is data stored?", "All state lives in-process arrays. Restart the server to reset."),
                accordionItem(ctx, "Can I export it?", "Not yet. The `/metrics` endpoint exposes per-route latency; app state is intentionally ephemeral."),
                accordionItem(ctx, "How does live refresh work?", "The server pushes a `count` event over SSE on every mutation. Any open tab reloads its current route."),
            }),
        }),
    }).build();
}

fn settingLabel(ctx: *const verve.Context, name: []const u8, helper: []const u8) *verve.Node {
    return ctx.div().class("setting-label").children(.{
        ctx.div().class("setting-name").text(name),
        ctx.div().class("setting-help").text(helper),
    });
}

fn radioOption(
    ctx: *const verve.Context,
    group: []const u8,
    val: []const u8,
    label_text: []const u8,
    checked: bool,
) *verve.Node {
    const lab = ctx.label("", label_text);
    const input_el = ctx.input().type_("radio").name(group).value(val);
    if (checked) _ = input_el.attr("checked", "true");
    return ctx.el("label").class("radio").children(.{
        input_el,
        ctx.span().text(label_text),
        // suppress unused label.
        lab.class("visually-hidden"),
    });
}

fn toggleSwitch(ctx: *const verve.Context, name: []const u8, on: bool) *verve.Node {
    const input_el = ctx.input().type_("checkbox").name(name).value("1");
    if (on) _ = input_el.attr("checked", "true");
    return ctx.el("label").class("toggle").children(.{
        input_el,
        ctx.span().class("toggle-track").children(.{ ctx.span().class("toggle-thumb") }),
        ctx.span().class("toggle-label").text(if (on) "On" else "Off"),
    });
}

fn accordionItem(ctx: *const verve.Context, question: []const u8, answer: []const u8) *verve.Node {
    return ctx.el("details").class("accordion").children(.{
        ctx.el("summary").class("accordion-q").text(question),
        ctx.div().class("accordion-a").text(answer),
    });
}

// ============================================================================
// External APIs page
// ============================================================================

pub fn externalPage(ctx: *const verve.Context, snap: *const external.Snapshot) !*verve.Node {
    const has_any_data = snap.refresh_count > 0;

    const root = ctx.div().class("page page-external").children(.{
        ctx.div().class("page-head").children(.{
            breadcrumb(ctx, &.{ "Home", "External APIs" }),
            ctx.div().class("page-head-row").children(.{
                ctx.h1("External APIs"),
                ctx.div().class("page-head-actions").children(.{
                    badge(ctx, "info", "wasm clock"),
                    ctx.span().class("badge").attr("data-kind", "ok")
                        .text("refresh #").children(.{
                            ctx.span().bind("refresh_count").textInt(snap.refresh_count),
                        }),
                    ctx.span().class("badge").attr("data-kind", "warn")
                        .text("server data ").children(.{
                            ctx.span().bind("freshness").text(if (has_any_data) "0s ago" else "loading…"),
                        }),
                    ctx.button("Refresh").onClick("reload").class("ghost"),
                }),
            }),
        }),
    });

    if (!has_any_data) {
        _ = root.children(.{
            alertBanner(
                ctx,
                "warn",
                "Warming up",
                "The fetcher thread is hitting Chuck Norris, Website Carbon, and Disney APIs. Reload in a few seconds.",
            ),
        });
    }

    // Three-up grid.
    const grid = ctx.div().class("grid grid-3-eq").children(.{
        chuckCard(ctx, &snap.chuck),
        carbonCard(ctx, &snap.carbon),
        disneyCard(ctx, &snap.disney),
    });
    _ = root.children(.{grid});

    // Disney carousel (separate larger card).
    _ = root.children(.{disneyCarouselCard(ctx, &snap.disney)});

    // Wasm-driven SSE control panel.
    _ = root.children(.{sseControlCard(ctx)});

    // Explanation footer card.
    _ = root.children(.{
        ctx.div().class("card").children(.{
            ctx.div().class("card-head").children(.{ ctx.h2("How this works") }),
            ctx.div().class("card-body").children(.{
                ctx.ul().class("plain-list").children(.{
                    ctx.li().children(.{
                        ctx.strong("Background fetcher: "),
                        ctx.span().text("a Zig thread refreshes all three APIs every 90 seconds via "),
                        ctx.code("std.http.Client"),
                        ctx.span().text(" — the snapshot is mutex-guarded and copied per render."),
                    }),
                    ctx.li().children(.{
                        ctx.strong("Disney iteration: "),
                        ctx.span().text("after fetching the character list, the fetcher fans out to each character's detail URL and pulls film names. Per-character latency is shown below."),
                    }),
                    ctx.li().children(.{
                        ctx.strong("Live freshness clock: "),
                        ctx.span().text("the wasm client ticks once per second and updates the "),
                        ctx.code("z-bind"),
                        ctx.span().text(" elements above. Server-Sent Events reset the clock whenever the snapshot turns over."),
                    }),
                    ctx.li().children(.{
                        ctx.strong("Carousel: "),
                        ctx.span().text("the prev/next buttons invoke wasm exports that track a client-side cursor; JS hides and shows the matching slide."),
                    }),
                }),
            }),
        }),
    });

    return root.build();
}

fn chuckCard(ctx: *const verve.Context, c: *const external.ChuckSnap) *verve.Node {
    const body = ctx.div().class("card-body");
    if (c.err_len > 0) {
        _ = body.children(.{
            ctx.div().class("api-error").children(.{
                ctx.strong("error: "),
                ctx.span().text(c.errSlice()),
            }),
        });
    } else if (c.value_len == 0) {
        _ = body.children(.{ ctx.div().class("empty").text("Awaiting first fetch…") });
    } else {
        _ = body.children(.{
            ctx.el("blockquote").class("joke").text(c.valueSlice()),
        });
    }
    _ = body.children(.{
        ctx.div().class("api-meta").children(.{
            ctx.span().text("updated "),
            ctx.span().bind("chuck_age").text(initialAge(c.fetched_unix, c.value_len > 0)),
            ctx.span().class("dot").text(" · "),
            ctx.span().textFmt("{d}ms", .{c.latency_ms}),
        }),
    });

    return ctx.div().class("card api-card chuck-card").children(.{
        ctx.div().class("card-head").children(.{
            ctx.h2("Chuck Norris"),
            badge(ctx, "info", "GET /jokes/random"),
        }),
        body,
    });
}

fn carbonCard(ctx: *const verve.Context, c: *const external.CarbonSnap) *verve.Node {
    const body = ctx.div().class("card-body");
    if (c.err_len > 0) {
        _ = body.children(.{
            ctx.div().class("api-error").children(.{
                ctx.strong("error: "),
                ctx.span().text(c.errSlice()),
            }),
        });
    } else if (c.rating_len == 0) {
        _ = body.children(.{ ctx.div().class("empty").text("Awaiting first fetch…") });
    } else {
        const gco2e_grams: f64 = @as(f64, @floatFromInt(c.gco2e_milli)) / 1000.0;
        const energy_kwh_micro: f64 = @as(f64, @floatFromInt(c.energy_micro)) / 1_000_000.0;
        const cleaner_pct: f64 = @as(f64, @floatFromInt(c.cleaner_centi)) / 100.0;

        _ = body.children(.{
            ctx.div().class("carbon-grid").children(.{
                ctx.div().class("carbon-rating").children(.{
                    ctx.div().class("carbon-rating-letter").text(c.ratingSlice()),
                    ctx.div().class("carbon-rating-label").text("rating"),
                }),
                ctx.div().class("carbon-stats").children(.{
                    carbonStat(ctx, "gCO₂", ctx.span().textFmt("{d:.3} g", .{gco2e_grams})),
                    carbonStat(ctx, "energy", ctx.span().textFmt("{d:.6} kWh", .{energy_kwh_micro})),
                    carbonStat(ctx, "cleaner than", ctx.span().textFmt("{d:.2}% of pages", .{cleaner_pct})),
                    carbonStat(ctx, "grid", ctx.span().text(if (c.green) "renewable ✓" else "grid mix")),
                    carbonStat(ctx, "bytes", ctx.span().textFmt("{d}", .{c.bytes})),
                }),
            }),
        });
    }
    _ = body.children(.{
        ctx.div().class("api-meta").children(.{
            ctx.span().text("updated "),
            ctx.span().bind("carbon_age").text(initialAge(c.fetched_unix, c.rating_len > 0)),
            ctx.span().class("dot").text(" · "),
            ctx.span().textFmt("{d}ms", .{c.latency_ms}),
        }),
    });

    return ctx.div().class("card api-card carbon-card").children(.{
        ctx.div().class("card-head").children(.{
            ctx.h2("Website Carbon"),
            badge(ctx, "info", "GET /data"),
        }),
        body,
    });
}

fn carbonStat(ctx: *const verve.Context, label_text: []const u8, val: *verve.Node) *verve.Node {
    return ctx.div().class("carbon-stat").children(.{
        ctx.div().class("carbon-stat-label").text(label_text),
        ctx.div().class("carbon-stat-value").children(.{val}),
    });
}

fn disneyCard(ctx: *const verve.Context, d: *const external.DisneySnap) *verve.Node {
    const body = ctx.div().class("card-body");
    if (d.err_len > 0) {
        _ = body.children(.{
            ctx.div().class("api-error").children(.{
                ctx.strong("error: "),
                ctx.span().text(d.errSlice()),
            }),
        });
    } else if (d.char_count == 0) {
        _ = body.children(.{ ctx.div().class("empty").text("Awaiting first fetch…") });
    } else {
        _ = body.children(.{
            ctx.div().class("disney-meta").children(.{
                ctx.div().class("disney-summary").children(.{
                    ctx.span().class("metric").textFmt("{d}", .{d.char_count}),
                    ctx.span().class("metric-label").text("listed"),
                }),
                ctx.div().class("disney-summary").children(.{
                    ctx.span().class("metric").textFmt("{d}", .{d.detail_fetched}),
                    ctx.span().class("metric-label").text("detail fetches"),
                }),
                ctx.div().class("disney-summary").children(.{
                    ctx.span().class("metric").textFmt("{d}", .{d.total_available}),
                    ctx.span().class("metric-label").text("in catalog"),
                }),
            }),
            ctx.p().class("api-help").text("Fetcher pulled the list, then iterated and called each character's detail URL for film lists."),
        });
    }
    _ = body.children(.{
        ctx.div().class("api-meta").children(.{
            ctx.span().text("updated "),
            ctx.span().bind("disney_age").text(initialAge(d.fetched_unix, d.char_count > 0)),
            ctx.span().class("dot").text(" · "),
            ctx.span().textFmt("list {d}ms + detail {d}ms", .{ d.list_latency_ms, d.detail_latency_ms_total }),
        }),
    });

    return ctx.div().class("card api-card disney-card").children(.{
        ctx.div().class("card-head").children(.{
            ctx.h2("Disney"),
            badge(ctx, "info", "GET /character + N detail calls"),
        }),
        body,
    });
}

fn disneyCarouselCard(ctx: *const verve.Context, d: *const external.DisneySnap) *verve.Node {
    if (d.char_count == 0) {
        return ctx.div().class("card").children(.{
            ctx.div().class("card-head").children(.{ ctx.h2("Character carousel") }),
            ctx.div().class("card-body").children(.{
                ctx.div().class("empty").text("Waiting for Disney data…"),
            }),
        });
    }

    const carousel = ctx.div().class("carousel").attr("data-carousel", "true");
    for (d.chars[0..d.char_count], 0..) |*c, i| {
        const slide = ctx.div().class("carousel-slide")
            .attrFmt("data-slide", "{d}", .{i})
            .attr("data-filterable", "true")
            .attrFmt("data-filter-text", "character {s} films {d}", .{ c.nameSlice(), c.films_total })
            .role("group")
            .ariaLabel(c.nameSlice())
            .children(.{
            ctx.div().class("carousel-portrait").children(.{
                ctx.el("img").src(c.imageSlice()).alt(c.nameSlice()).attr("loading", "lazy"),
            }),
            ctx.div().class("carousel-info").children(.{
                ctx.h3(c.nameSlice()),
                ctx.div().class("carousel-id").textFmt("#{d}", .{c.id}),
                ctx.div().class("carousel-detail-row").children(.{
                    badge(ctx, if (c.detail_ok) "ok" else "warn", if (c.detail_ok) "detail ok" else "detail miss"),
                    ctx.span().class("muted").textFmt("{d}ms · {d} films total", .{ c.detail_latency_ms, c.films_total }),
                }),
                filmList(ctx, c),
                ctx.div().class("carousel-source").children(.{
                    ctx.span().class("muted").text("source url "),
                    ctx.code(c.detailSlice()),
                }),
            }),
        });
        _ = carousel.children(.{slide});
    }

    return ctx.div().class("card carousel-card").children(.{
        ctx.div().class("card-head").children(.{
            ctx.h2("Character carousel"),
            ctx.nav().class("carousel-controls").ariaLabel("Character pagination").children(.{
                ctx.button("«").onClick("prev_page").class("ghost").ariaLabel("Previous page"),
                ctx.button("←").onClick("prev_char").class("ghost").ariaLabel("Previous character"),
                ctx.span()
                    .attr("data-carousel-counter", "true")
                    .class("carousel-counter")
                    .ariaLive("polite")
                    .text("1 of 1"),
                ctx.button("→").onClick("next_char").class("ghost").ariaLabel("Next character"),
                ctx.button("»").onClick("next_page").class("ghost").ariaLabel("Next page"),
            }),
        }),
        ctx.div().class("card-body carousel-body").children(.{carousel}),
    });
}

fn filmList(ctx: *const verve.Context, c: *const external.DisneyChar) *verve.Node {
    if (c.films_shown == 0) {
        return ctx.div().class("film-list empty").text("no films in detail payload");
    }
    const list = ctx.ul().class("film-list");
    for (c.films[0..c.films_shown]) |*f| {
        _ = list.children(.{ ctx.li().text(f.slice()) });
    }
    if (c.films_total > c.films_shown) {
        _ = list.children(.{
            ctx.li().class("muted").textFmt("+ {d} more", .{c.films_total - c.films_shown}),
        });
    }
    return list;
}

fn initialAge(fetched_unix: i64, have_data: bool) []const u8 {
    if (!have_data or fetched_unix == 0) return "loading…";
    return "0s ago";
}

fn sseControlCard(ctx: *const verve.Context) *verve.Node {
    return ctx.div().class("card sse-card").children(.{
        ctx.div().class("card-head").children(.{
            ctx.h2("Server-Sent Events (wasm orchestration)"),
            ctx.span().class("badge").attr("data-kind", "info")
                .text("status: ").children(.{
                    ctx.span().bind("sse_status").text("…"),
                }),
        }),
        ctx.div().class("card-body").children(.{
            ctx.div().class("sse-metrics").children(.{
                sseStat(ctx, "events received", ctx.span().bind("sse_events").text("0")),
                sseStat(ctx, "last seq", ctx.span().bind("sse_last_seq").text("—")),
                sseStat(ctx, "mutations seen", ctx.span().bind("sse_mutations").text("0")),
            }),
            ctx.div().class("sse-actions").children(.{
                ctx.button("Connect").onClick("connect_sse").class("primary"),
                ctx.button("Disconnect").onClick("disconnect_sse").class("ghost"),
                ctx.button("Force reload").onClick("reload").class("ghost"),
            }),
            ctx.p().class("api-help").children(.{
                ctx.span().text("Connect/Disconnect call wasm exports "),
                ctx.code("connect_sse"),
                ctx.span().text(" / "),
                ctx.code("disconnect_sse"),
                ctx.span().text(", which invoke JS env imports ("),
                ctx.code("sse_open"),
                ctx.span().text(", "),
                ctx.code("sse_close"),
                ctx.span().text(") to manage the EventSource. Each /events message comes back into wasm via "),
                ctx.code("on_sse_event(seq)"),
                ctx.span().text(" — when the server's tick value changes (any mutation including the background fetcher's 20-second refresh), wasm triggers a full page reload."),
            }),
        }),
    });
}

fn sseStat(ctx: *const verve.Context, label_text: []const u8, val: *verve.Node) *verve.Node {
    return ctx.div().class("sse-stat").children(.{
        ctx.div().class("sse-stat-label").text(label_text),
        ctx.div().class("sse-stat-value").children(.{val}),
    });
}

// ============================================================================
// Fallbacks the server expects
// ============================================================================

pub fn notFound(ctx: *const verve.Context, path: []const u8) !*verve.Node {
    return ctx.div().class("page").children(.{
        ctx.div().class("page-head").children(.{
            breadcrumb(ctx, &.{ "Home", "404" }),
            ctx.h1("404 — Not Found"),
        }),
        ctx.div().class("card").children(.{
            ctx.div().class("card-body").children(.{
                ctx.p().children(.{
                    ctx.span().text("No route for "),
                    ctx.code(path),
                }),
                ctx.p().children(.{ ctx.a("/", "← Back to overview").class("button primary") }),
            }),
        }),
    }).build();
}

pub fn errorPage(
    ctx: *const verve.Context,
    status_code: u16,
    status_text: []const u8,
    message: []const u8,
) !*verve.Node {
    return ctx.div().class("page").children(.{
        ctx.div().class("page-head").children(.{ ctx.h1("Something went wrong") }),
        alertBanner(ctx, "error", "Error", message),
        ctx.div().class("card").children(.{
            ctx.div().class("card-body").children(.{
                ctx.el("code").class("mono").textFmt("HTTP {d} — {s}", .{ status_code, status_text }),
                ctx.p().children(.{ ctx.a("/", "← Back to overview").class("button primary") }),
            }),
        }),
    }).build();
}

// ============================================================================
// Page shell — nav + footer + CSS + SSE refresh
// ============================================================================

pub fn page(ctx: *const verve.Context, body: *verve.Node) !*verve.Node {
    // Server fallback (notFound, errorPage) path — minimal shell, no nav.
    return shell(ctx, "Verve Dashboard", "/", body);
}

pub fn shell(
    ctx: *const verve.Context,
    page_title: []const u8,
    current_path: []const u8,
    body: *verve.Node,
) !*verve.Node {
    const snap = external.snapshot();
    const now = nowUnix(ctx);
    if (now != 0) api.stampClock(now);
    const server_age = ageSecs(now, snap.last_refresh_unix);
    const chuck_age = ageSecs(now, snap.chuck.fetched_unix);
    const carbon_age = ageSecs(now, snap.carbon.fetched_unix);
    const disney_age = ageSecs(now, snap.disney.fetched_unix);

    return ctx.el("html").attr("lang", "en").attr("data-theme", "dark").children(.{
        ctx.el("head").children(.{
            ctx.meta("charset", "utf-8"),
            ctx.el("meta").attr("name", "viewport").attr("content", "width=device-width,initial-scale=1"),
            ctx.title(page_title),
            ctx.style(STYLES),
        }),
        ctx.el("body").attr("data-route", current_path)
            .attrFmt("data-server-age", "{d}", .{server_age})
            .attrFmt("data-chuck-age", "{d}", .{chuck_age})
            .attrFmt("data-carbon-age", "{d}", .{carbon_age})
            .attrFmt("data-disney-age", "{d}", .{disney_age})
            .attrFmt("data-refresh-count", "{d}", .{snap.refresh_count})
            .children(.{
            ctx.a("#main", "Skip to main content").class("skip-link"),
            siteHeader(ctx, current_path),
            ctx.el("main").id("main").class("layout").attr("tabindex", "-1").role("main").children(.{body}),
            siteFooter(ctx),
            commandPalette(ctx),
            toastRegion(ctx),
            srAnnouncer(ctx),
            ctx.el("script").src("/verve.js"),
        }),
    }).build();
}

fn nowUnix(ctx: *const verve.Context) i64 {
    if (ctx.io) |io| {
        return std.Io.Clock.now(.real, io).toSeconds();
    }
    return 0;
}

fn ageSecs(now: i64, then: i64) i64 {
    if (then <= 0) return 0;
    const d = now - then;
    return if (d < 0) 0 else d;
}

fn siteHeader(ctx: *const verve.Context, current: []const u8) *verve.Node {
    return ctx.el("header").class("topbar").role("banner").children(.{
        ctx.div().class("brand").children(.{
            ctx.span().class("brand-mark").ariaHidden(true).text("◆"),
            ctx.span().class("brand-name").text("Verve Dashboard"),
        }),
        navLinks(ctx, current),
        searchBar(ctx),
        ctx.div().class("topbar-right").children(.{
            themeSwitcher(ctx),
            ctx.button("⌘K")
                .ariaLabel("Open command palette (Cmd+K)")
                .onClick("palette_open")
                .class("button ghost small palette-trigger"),
            badge(ctx, "info", "v0.1"),
            ctx.a("/metrics", "Metrics").class("link"),
        }),
    });
}

fn searchBar(ctx: *const verve.Context) *verve.Node {
    return ctx.div().class("search-bar").role("search").children(.{
        ctx.el("label").class("visually-hidden").attr("for", "global-search").text("Search"),
        ctx.el("span").class("search-icon").ariaHidden(true).text("⌕"),
        ctx.input()
            .id("global-search")
            .type_("search")
            .name("q")
            .placeholder("Filter tasks, teammates, characters…  ( / )")
            .attr("autocomplete", "off")
            .attr("aria-describedby", "search-result-count")
            .attr("data-global-search", "true"),
        ctx.span()
            .id("search-result-count")
            .class("search-count")
            .ariaLive("polite")
            .bind("search_count")
            .text(""),
    });
}

fn themeSwitcher(ctx: *const verve.Context) *verve.Node {
    return ctx.button("◐")
        .ariaLabel("Cycle color theme")
        .onClick("theme_cycle")
        .class("button ghost small theme-toggle")
        .attr("data-theme-toggle", "true")
        .children(.{
            ctx.span().class("visually-hidden").bind("theme_label").text("theme: dark"),
        });
}

fn commandPalette(ctx: *const verve.Context) *verve.Node {
    return ctx.div()
        .class("palette-overlay")
        .id("palette")
        .role("dialog")
        .attr("aria-modal", "true")
        .attr("aria-labelledby", "palette-title")
        .ariaHidden(true)
        .attr("data-modal", "palette")
        .children(.{
            ctx.div().class("palette-card").children(.{
                ctx.h2("Command palette").id("palette-title").class("visually-hidden"),
                ctx.div().class("palette-input-row").children(.{
                    ctx.el("label").class("visually-hidden").attr("for", "palette-input").text("Search commands"),
                    ctx.el("span").class("palette-icon").ariaHidden(true).text("⌘"),
                    ctx.input()
                        .id("palette-input")
                        .type_("text")
                        .attr("role", "combobox")
                        .attr("aria-controls", "palette-list")
                        .attr("aria-expanded", "true")
                        .attr("aria-autocomplete", "list")
                        .attr("autocomplete", "off")
                        .placeholder("Jump to page or run a command…"),
                    ctx.span().class("palette-hint").ariaHidden(true).text("ESC"),
                }),
                paletteList(ctx),
                ctx.div().class("palette-foot").children(.{
                    ctx.span().class("muted").text("↑↓ navigate · Enter activate · ESC close"),
                    ctx.span().class("muted").bind("palette_count").text(""),
                }),
            }),
        });
}

fn paletteList(ctx: *const verve.Context) *verve.Node {
    const rows = [_]PaletteRow{
        .{ .kind = "route", .id = "go-overview", .label = "Go to Overview", .hint = "/" },
        .{ .kind = "route", .id = "go-tasks", .label = "Go to Tasks", .hint = "/tasks" },
        .{ .kind = "route", .id = "go-team", .label = "Go to Team", .hint = "/team" },
        .{ .kind = "route", .id = "go-external", .label = "Go to External APIs", .hint = "/external" },
        .{ .kind = "route", .id = "go-analytics", .label = "Go to Analytics", .hint = "/analytics" },
        .{ .kind = "route", .id = "go-live", .label = "Go to Live chat", .hint = "/live" },
        .{ .kind = "route", .id = "go-settings", .label = "Go to Settings", .hint = "/settings" },
        .{ .kind = "action", .id = "act-reload", .label = "Force reload", .hint = "R" },
        .{ .kind = "action", .id = "act-theme", .label = "Cycle theme", .hint = "T" },
        .{ .kind = "action", .id = "act-disconnect", .label = "Disconnect SSE", .hint = "" },
        .{ .kind = "action", .id = "act-connect", .label = "Connect SSE", .hint = "" },
        .{ .kind = "action", .id = "act-focus-search", .label = "Focus search input", .hint = "/" },
    };
    const list = ctx.ul()
        .id("palette-list")
        .role("listbox")
        .ariaLabel("Available commands")
        .class("palette-list")
        .attr("data-palette-list", "true");
    for (rows) |r| {
        _ = list.children(.{
            ctx.li()
                .role("option")
                .attr("data-palette-item", r.id)
                .attr("data-palette-kind", r.kind)
                .attr("data-palette-hint", r.hint)
                .attr("aria-selected", "false")
                .class("palette-item")
                .children(.{
                    ctx.span().class("palette-item-kind").text(r.kind),
                    ctx.span().class("palette-item-label").text(r.label),
                    ctx.span().class("palette-item-hint").text(r.hint),
                }),
        });
    }
    return list;
}

const PaletteRow = struct {
    kind: []const u8,
    id: []const u8,
    label: []const u8,
    hint: []const u8,
};

fn toastRegion(ctx: *const verve.Context) *verve.Node {
    return ctx.div()
        .class("toast-region")
        .id("toasts")
        .role("status")
        .ariaLive("polite")
        .ariaLabel("Notifications")
        .attr("data-toast-region", "true");
}

fn srAnnouncer(ctx: *const verve.Context) *verve.Node {
    return ctx.div()
        .id("sr-announcer")
        .class("visually-hidden")
        .role("status")
        .ariaLive("polite")
        .attr("data-sr-announce", "true");
}

fn navLinks(ctx: *const verve.Context, current: []const u8) *verve.Node {
    const items = [_]struct { path: []const u8, label: []const u8 }{
        .{ .path = "/", .label = "Overview" },
        .{ .path = "/tasks", .label = "Tasks" },
        .{ .path = "/team", .label = "Team" },
        .{ .path = "/external", .label = "External" },
        .{ .path = "/analytics", .label = "Analytics" },
        .{ .path = "/live", .label = "Live" },
        .{ .path = "/settings", .label = "Settings" },
    };
    const nav = ctx.nav().class("topbar-nav").ariaLabel("Primary navigation");
    for (items) |item| {
        const link = ctx.a(item.path, item.label);
        if (std.mem.eql(u8, item.path, current)) {
            _ = link.class("active").ariaCurrent("page");
        }
        _ = nav.children(.{link});
    }
    return nav;
}

fn siteFooter(ctx: *const verve.Context) *verve.Node {
    return ctx.el("footer").class("site-footer").role("contentinfo").children(.{
        ctx.span().text("Verve · fluent chain widget showcase"),
        ctx.span().class("dot").ariaHidden(true).text("·"),
        ctx.a("https://github.com/sirhco/verve", "github").class("link"),
    });
}

// ============================================================================
// Analytics page (sparklines)
// ============================================================================

pub fn analyticsPage(ctx: *const verve.Context) !*verve.Node {
    var latency_buf: [api.analytics.SAMPLES]u32 = undefined;
    const latency_count = api.analytics.refresh_latency.snapshot(&latency_buf);
    var mut_buf: [api.analytics.SAMPLES]u32 = undefined;
    const mut_count = api.analytics.mutations.snapshot(&mut_buf);

    const latency_max = api.analytics.refresh_latency.maxValue();
    const latency_avg = api.analytics.refresh_latency.avg();
    const mut_max = api.analytics.mutations.maxValue();
    const mut_avg = api.analytics.mutations.avg();
    const last_latency = api.analytics.refresh_latency.last() orelse 0;

    return ctx.div().class("page page-analytics").children(.{
        ctx.div().class("page-head").children(.{
            breadcrumb(ctx, &.{ "Home", "Analytics" }),
            ctx.div().class("page-head-row").children(.{
                ctx.h1("Analytics"),
                ctx.div().class("page-head-actions").children(.{
                    badge(ctx, "info", "wasm-augmented"),
                    badge(ctx, "ok", labelInt(ctx, latency_count)),
                }),
            }),
        }),
        ctx.div().class("grid grid-2").children(.{
            sparklineCard(
                ctx,
                "External refresh latency",
                "Total round-trip ms across all three APIs per refresh cycle.",
                "refresh-latency",
                latency_buf[0..latency_count],
                latency_max,
                latency_avg,
                last_latency,
                "ms",
                "#1f6feb",
            ),
            sparklineCard(
                ctx,
                "Mutations per minute",
                "Server-side action invocations plus external refreshes, bucketed by wall-clock minute.",
                "mutations",
                mut_buf[0..mut_count],
                mut_max,
                mut_avg,
                api.analytics.mutations.last() orelse 0,
                "/min",
                "#2ea043",
            ),
        }),
        ctx.div().class("card").children(.{
            ctx.div().class("card-head").children(.{ ctx.h2("Why this matters") }),
            ctx.div().class("card-body").children(.{
                ctx.p().text("Each chart pulls from a server-side ring buffer fed at the moment each event happens. The sparkline is plain SVG rendered by Zig — no client-side JS needed for the visualisation."),
                ctx.p().text("Every chart includes a hidden screen-reader table with the same data, so the page is just as usable without sight as with."),
            }),
        }),
    }).build();
}

fn sparklineCard(
    ctx: *const verve.Context,
    title_text: []const u8,
    desc: []const u8,
    bind_name: []const u8,
    samples: []const u32,
    max_v: u32,
    avg_v: u32,
    last_v: u32,
    unit: []const u8,
    color: []const u8,
) *verve.Node {
    return ctx.div().class("card sparkline-card").children(.{
        ctx.div().class("card-head").children(.{
            ctx.h2(title_text),
            badge(ctx, "info", unit),
        }),
        ctx.div().class("card-body").children(.{
            ctx.p().class("api-help").text(desc),
            sparklineSvg(ctx, bind_name, samples, max_v, color),
            ctx.div().class("sparkline-stats").children(.{
                sparkStat(ctx, "latest", last_v, unit),
                sparkStat(ctx, "avg", avg_v, unit),
                sparkStat(ctx, "peak", max_v, unit),
                sparkStat(ctx, "samples", @as(u32, @intCast(samples.len)), ""),
            }),
            sparklineTable(ctx, title_text, samples, unit),
        }),
    });
}

fn sparkStat(ctx: *const verve.Context, label_text: []const u8, val: u32, unit: []const u8) *verve.Node {
    return ctx.div().class("spark-stat").children(.{
        ctx.div().class("spark-stat-label").text(label_text),
        ctx.div().class("spark-stat-value").textFmt("{d}{s}", .{ val, unit }),
    });
}

fn sparklineSvg(
    ctx: *const verve.Context,
    bind_name: []const u8,
    samples: []const u32,
    max_v: u32,
    color: []const u8,
) *verve.Node {
    const w: u32 = 360;
    const h: u32 = 80;
    if (samples.len < 2) {
        return ctx.div().class("sparkline-empty").text("Collecting samples…");
    }
    const denom: u32 = if (max_v == 0) 1 else max_v;
    const alloc = ctx.alloc();
    var aw: std.Io.Writer.Allocating = .init(alloc);
    aw.writer.writeAll("M") catch return ctx.div();
    for (samples, 0..) |v, i| {
        const x = if (samples.len == 1) 0 else (i * w) / (samples.len - 1);
        const y = h - ((v * (h - 4)) / denom) - 2;
        if (i == 0) {
            aw.writer.print("{d} {d}", .{ x, y }) catch return ctx.div();
        } else {
            aw.writer.print(" L{d} {d}", .{ x, y }) catch return ctx.div();
        }
    }
    const path = aw.written();

    const svg = ctx.el("svg")
        .attr("viewBox", "0 0 360 80")
        .attr("width", "100%")
        .attr("height", "80")
        .attr("preserveAspectRatio", "none")
        .role("img")
        .attr("aria-labelledby", bind_name)
        .class("sparkline");
    _ = svg.children(.{
        ctx.el("title").id(bind_name).text(bind_name),
        ctx.el("path")
            .attr("d", path)
            .attr("fill", "none")
            .attr("stroke", color)
            .attr("stroke-width", "2")
            .attr("stroke-linejoin", "round")
            .attr("stroke-linecap", "round"),
    });
    return svg;
}

fn sparklineTable(
    ctx: *const verve.Context,
    title_text: []const u8,
    samples: []const u32,
    unit: []const u8,
) *verve.Node {
    const table = ctx.el("table").class("visually-hidden").children(.{
        ctx.el("caption").textFmt("{s} ({s})", .{ title_text, unit }),
        ctx.el("thead").children(.{
            ctx.el("tr").children(.{
                ctx.el("th").attr("scope", "col").text("Sample"),
                ctx.el("th").attr("scope", "col").text("Value"),
            }),
        }),
    });
    const tbody = ctx.el("tbody");
    for (samples, 0..) |v, i| {
        _ = tbody.children(.{
            ctx.el("tr").children(.{
                ctx.el("td").textFmt("{d}", .{i + 1}),
                ctx.el("td").textFmt("{d}", .{v}),
            }),
        });
    }
    _ = table.children(.{tbody});
    return table;
}

// ============================================================================
// Live chat page (/live, WebSocket)
// ============================================================================

pub fn livePage(ctx: *const verve.Context) !*verve.Node {
    return ctx.div().class("page page-live").children(.{
        ctx.div().class("page-head").children(.{
            breadcrumb(ctx, &.{ "Home", "Live chat" }),
            ctx.div().class("page-head-row").children(.{
                ctx.h1("Live chat"),
                ctx.div().class("page-head-actions").children(.{
                    badge(ctx, "info", "WebSocket /ws"),
                    ctx.span().class("badge")
                        .attr("data-kind", "warn")
                        .text("status: ")
                        .children(.{ ctx.span().bind("ws_status").text("connecting…") }),
                }),
            }),
        }),
        ctx.div().class("card").children(.{
            ctx.div().class("card-head").children(.{ ctx.h2("Connected peers see each other's messages") }),
            ctx.div().class("card-body").children(.{
                ctx.p().class("api-help").text("Open this page in two browser windows to see the broadcast. Server keeps a registry of WS connections; any text frame that's not '+' / '-' (the legacy counter commands) gets fanned out to every other peer."),
                ctx.div().class("live-chat").children(.{
                    ctx.div().class("live-input-row").children(.{
                        ctx.el("label").class("live-label").attr("for", "live-nick").text("Nick"),
                        ctx.input()
                            .id("live-nick")
                            .type_("text")
                            .attr("autocomplete", "off")
                            .attr("maxlength", "32")
                            .attr("data-live-nick", "true")
                            .placeholder("alice"),
                        ctx.el("label").class("live-label").attr("for", "live-input").text("Message"),
                        ctx.input()
                            .id("live-input")
                            .type_("text")
                            .attr("autocomplete", "off")
                            .attr("maxlength", "200")
                            .attr("data-live-input", "true")
                            .placeholder("press Enter to send"),
                        ctx.button("Send")
                            .type_("button")
                            .attr("data-live-send", "true")
                            .class("primary"),
                    }),
                    ctx.div()
                        .class("live-log")
                        .id("live-log")
                        .role("log")
                        .ariaLive("polite")
                        .ariaLabel("Chat transcript")
                        .attr("data-live-log", "true")
                        .children(.{
                            ctx.div().class("live-empty muted").text("No messages yet — say hi."),
                        }),
                }),
            }),
        }),
    }).build();
}

// ============================================================================
// CSS + auto-refresh script
// ============================================================================

const REFRESH_SCRIPT =
    \\(()=>{
    \\const es=new EventSource('/events');
    \\let last=null;
    \\es.addEventListener('count',(e)=>{
    \\  const v=Number(e.data);
    \\  if(last===null){last=v;return;}
    \\  if(v!==last){location.reload();}
    \\});
    \\})();
;

const STYLES =
    \\*{box-sizing:border-box}
    \\:root{--bg:#0b0c10;--surface:#15161c;--surface-2:#1d1e26;--border:#262833;--border-strong:#3a3d4d;--ink:#e8eaf2;--ink-mute:#8b91a8;--ink-soft:#5b6072;--accent:#1f6feb;--accent-hover:#388bfd;--warn:#d29922;--ok:#2ea043;--danger:#5b2727;--purple:#a371f7;--radius:10px;--gap:1rem}
    \\html,body{margin:0;padding:0}
    \\body{font:14px/1.5 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;background:var(--bg);color:var(--ink);min-height:100vh;display:flex;flex-direction:column}
    \\a{color:inherit;text-decoration:none}
    \\h1,h2,h3{margin:0;letter-spacing:-.01em}
    \\h1{font-size:1.75rem;font-weight:700}
    \\h2{font-size:1.05rem;font-weight:600}
    \\h3{font-size:.95rem;font-weight:600;color:var(--ink-mute)}
    \\
    \\/* topbar */
    \\.topbar{display:flex;align-items:center;gap:1.5rem;padding:.75rem 1.5rem;border-bottom:1px solid var(--border);background:var(--surface);position:sticky;top:0;z-index:10}
    \\.brand{display:flex;align-items:center;gap:.5rem;font-weight:700;letter-spacing:.02em}
    \\.brand-mark{color:var(--accent);font-size:1.2rem}
    \\.topbar-nav{display:flex;gap:.25rem;flex:1}
    \\.topbar-nav a{padding:.45rem .8rem;border-radius:6px;color:var(--ink-mute);font-weight:500;font-size:.9rem;transition:background .15s,color .15s}
    \\.topbar-nav a:hover{background:var(--surface-2);color:var(--ink)}
    \\.topbar-nav a.active{background:var(--accent);color:#fff}
    \\.topbar-right{display:flex;align-items:center;gap:.75rem}
    \\
    \\/* layout */
    \\.layout{padding:2rem 1.5rem;max-width:1200px;width:100%;margin:0 auto;flex:1}
    \\.page{display:flex;flex-direction:column;gap:1.25rem}
    \\.page-head{display:flex;flex-direction:column;gap:.5rem}
    \\.page-head-row{display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:.5rem}
    \\.page-head-actions{display:flex;gap:.5rem;align-items:center;flex-wrap:wrap}
    \\
    \\/* breadcrumb */
    \\.breadcrumb{display:flex;gap:.4rem;font-size:.8rem;color:var(--ink-soft)}
    \\.breadcrumb-part{color:var(--ink-mute)}
    \\.breadcrumb-part:last-child{color:var(--ink)}
    \\.breadcrumb-sep{color:var(--border-strong)}
    \\
    \\/* grid helpers */
    \\.grid{display:grid;gap:var(--gap)}
    \\.grid-2-1{grid-template-columns:2fr 1fr}
    \\.grid-3{grid-template-columns:repeat(auto-fill,minmax(260px,1fr))}
    \\.grid-4{grid-template-columns:repeat(auto-fit,minmax(180px,1fr))}
    \\@media (max-width:760px){.grid-2-1,.grid-4{grid-template-columns:1fr}}
    \\
    \\/* card */
    \\.card{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);overflow:hidden;transition:border-color .15s}
    \\.card:hover{border-color:var(--border-strong)}
    \\.card-head{display:flex;align-items:center;justify-content:space-between;padding:.85rem 1.1rem;border-bottom:1px solid var(--border)}
    \\.card-body{padding:1.1rem}
    \\.empty-card,.empty{color:var(--ink-mute);text-align:center;padding:2rem}
    \\
    \\/* kpi */
    \\.kpi{padding:1rem 1.1rem;background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);position:relative;overflow:hidden}
    \\.kpi::before{content:"";position:absolute;left:0;top:0;bottom:0;width:3px;background:var(--accent)}
    \\.kpi-label{font-size:.75rem;text-transform:uppercase;letter-spacing:.06em;color:var(--ink-mute);font-weight:600}
    \\.kpi-value{font-size:2rem;font-weight:700;font-variant-numeric:tabular-nums;margin:.25rem 0}
    \\.kpi-delta{font-size:.8rem;color:var(--ok)}
    \\
    \\/* badge */
    \\.badge{display:inline-flex;align-items:center;padding:.15rem .55rem;border-radius:999px;font-size:.72rem;font-weight:600;letter-spacing:.02em;background:var(--surface-2);color:var(--ink-mute);border:1px solid var(--border)}
    \\.badge[data-kind="ok"],.badge[data-kind="active"]{background:#0e2a17;color:#7ee2a8;border-color:#15532b}
    \\.badge[data-kind="warn"],.badge[data-kind="away"],.badge[data-kind="Med"]{background:#2e2305;color:#f0c674;border-color:#5b4513}
    \\.badge[data-kind="error"],.badge[data-kind="High"]{background:#3a1414;color:#ff9b9b;border-color:#6b1f1f}
    \\.badge[data-kind="info"]{background:#0d2447;color:#7cb7ff;border-color:#1f4d8a}
    \\.badge[data-kind="off"]{background:#1a1c25;color:var(--ink-soft);border-color:var(--border)}
    \\.badge[data-kind="backlog"]{background:#1d1f29;color:var(--ink-mute);border-color:var(--border)}
    \\.badge[data-kind="doing"]{background:#2e2305;color:#f0c674;border-color:#5b4513}
    \\.badge[data-kind="done"]{background:#0e2a17;color:#7ee2a8;border-color:#15532b}
    \\.badge[data-kind="Low"]{background:#1a1c25;color:var(--ink-mute);border-color:var(--border)}
    \\
    \\/* progress */
    \\.progress{flex:1;height:.45rem;background:#1a1c25;border-radius:4px;overflow:hidden;min-width:100px}
    \\.progress-fill{height:100%;transition:width .3s ease}
    \\
    \\/* avatar */
    \\.avatar{width:36px;height:36px;border-radius:50%;background:linear-gradient(135deg,#1f6feb,#a371f7);display:flex;align-items:center;justify-content:center;font-weight:700;font-size:.85rem;color:#fff;flex-shrink:0;position:relative}
    \\.avatar::after{content:"";position:absolute;right:-1px;bottom:-1px;width:10px;height:10px;border-radius:50%;border:2px solid var(--surface);background:#6e7681}
    \\.avatar[data-status="active"]::after{background:var(--ok)}
    \\.avatar[data-status="away"]::after{background:var(--warn)}
    \\.avatar[data-status="off"]::after{background:var(--ink-soft)}
    \\.avatar-initials{user-select:none}
    \\
    \\/* chart rows */
    \\.chart{display:flex;flex-direction:column;gap:.6rem}
    \\.chart-row{display:flex;align-items:center;gap:.75rem}
    \\.chart-label{width:5.5rem;color:var(--ink-mute);font-size:.85rem}
    \\.chart-value{width:7rem;text-align:right;font-variant-numeric:tabular-nums;font-size:.85rem;color:var(--ink-mute)}
    \\
    \\/* stat tiles */
    \\.stats-grid{display:grid;grid-template-columns:1fr 1fr;gap:.6rem;padding:.4rem 0}
    \\.stat-tile{display:flex;gap:.6rem;align-items:center;padding:.6rem .75rem;background:var(--surface-2);border-radius:8px}
    \\.stat-icon{width:32px;height:32px;display:grid;place-items:center;background:var(--bg);border:1px solid var(--border);border-radius:6px;color:var(--accent);font-weight:700}
    \\.stat-label{font-size:.75rem;color:var(--ink-mute);text-transform:uppercase;letter-spacing:.05em}
    \\.stat-value{font-size:1.2rem;font-weight:600;font-variant-numeric:tabular-nums}
    \\
    \\/* alert */
    \\.alert{display:flex;gap:.75rem;padding:.85rem 1rem;border-radius:var(--radius);border:1px solid var(--border);background:var(--surface);align-items:flex-start}
    \\.alert[data-kind="ok"]{border-color:#15532b;background:#0a1d11}
    \\.alert[data-kind="warn"]{border-color:#5b4513;background:#1c1505}
    \\.alert[data-kind="error"]{border-color:#6b1f1f;background:#1c0a0a}
    \\.alert-icon{width:24px;height:24px;border-radius:50%;display:grid;place-items:center;font-weight:700;flex-shrink:0;background:rgba(255,255,255,.06)}
    \\.alert[data-kind="ok"] .alert-icon{color:#7ee2a8}
    \\.alert[data-kind="warn"] .alert-icon{color:#f0c674}
    \\.alert[data-kind="error"] .alert-icon{color:#ff9b9b}
    \\.alert-title{font-weight:600;margin-bottom:.15rem}
    \\.alert-text{color:var(--ink-mute);font-size:.85rem}
    \\
    \\/* kanban */
    \\.kanban{display:grid;grid-template-columns:repeat(3,1fr);gap:1rem}
    \\@media (max-width:900px){.kanban{grid-template-columns:1fr}}
    \\.kanban-col{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);padding:.85rem;min-height:200px}
    \\.kanban-head{display:flex;justify-content:space-between;align-items:center;margin-bottom:.65rem;padding-bottom:.65rem;border-bottom:1px solid var(--border)}
    \\.kanban-stack{display:flex;flex-direction:column;gap:.55rem}
    \\.kanban-empty{padding:1.5rem;text-align:center;color:var(--ink-soft);font-size:.8rem;border:1px dashed var(--border);border-radius:6px}
    \\
    \\/* task card */
    \\.task-card{background:var(--surface-2);border:1px solid var(--border);border-radius:8px;padding:.7rem .8rem;display:flex;flex-direction:column;gap:.5rem;transition:transform .12s,border-color .15s}
    \\.task-card:hover{border-color:var(--border-strong);transform:translateY(-1px)}
    \\.task-head{display:flex;justify-content:space-between;align-items:flex-start;gap:.5rem}
    \\.task-title{font-weight:500;flex:1;line-height:1.35}
    \\.task-assignee{display:flex;align-items:center;gap:.4rem;font-size:.8rem;color:var(--ink-mute)}
    \\.task-assignee .avatar{width:24px;height:24px;font-size:.65rem}
    \\.task-assignee .avatar::after{display:none}
    \\.task-actions{display:flex;flex-wrap:wrap;gap:.3rem;padding-top:.35rem;border-top:1px solid var(--border)}
    \\.task-actions form{display:contents}
    \\.task-card[data-priority="High"]{border-left:3px solid #ff6b6b}
    \\
    \\/* form-row */
    \\.form-row{display:flex;gap:.5rem;flex-wrap:wrap;align-items:center}
    \\.form-row input[type="text"]{flex:1;min-width:180px}
    \\input,select,textarea{font:inherit;background:var(--surface-2);color:var(--ink);border:1px solid var(--border);border-radius:6px;padding:.5rem .65rem;transition:border-color .15s}
    \\input:focus,select:focus,textarea:focus{outline:none;border-color:var(--accent)}
    \\textarea{min-height:5rem;resize:vertical}
    \\input[type="color"]{padding:0;width:44px;height:32px;cursor:pointer}
    \\input[type="range"]{padding:0;height:24px;background:transparent}
    \\
    \\/* button */
    \\button,.button{font:inherit;font-weight:500;padding:.45rem .9rem;background:var(--surface-2);color:var(--ink);border:1px solid var(--border);border-radius:6px;cursor:pointer;transition:background .15s,border-color .15s;display:inline-flex;align-items:center;gap:.4rem}
    \\button:hover,.button:hover{background:var(--surface);border-color:var(--border-strong)}
    \\button.primary,.button.primary{background:var(--accent);color:#fff;border-color:var(--accent)}
    \\button.primary:hover,.button.primary:hover{background:var(--accent-hover);border-color:var(--accent-hover)}
    \\button.ghost,.button.ghost{background:transparent}
    \\button.danger,.button.danger{color:#ff9b9b;border-color:#5b2727}
    \\button.danger:hover{background:#2a1414}
    \\button.small{padding:.25rem .5rem;font-size:.78rem}
    \\
    \\/* member card */
    \\.member-card{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);padding:1rem;display:flex;flex-direction:column;gap:.85rem;transition:border-color .15s}
    \\.member-card:hover{border-color:var(--border-strong)}
    \\.member-head{display:flex;gap:.75rem;align-items:center}
    \\.member-meta{flex:1;min-width:0}
    \\.member-name{font-weight:600}
    \\.member-role{font-size:.8rem;color:var(--ink-mute);margin-top:.1rem}
    \\.member-foot{display:flex;justify-content:space-between;align-items:center}
    \\
    \\/* roster table */
    \\.roster-table{width:100%;border-collapse:collapse;font-size:.88rem}
    \\.roster-table th{text-align:left;text-transform:uppercase;letter-spacing:.05em;font-size:.7rem;color:var(--ink-mute);font-weight:600;padding:.5rem .65rem;border-bottom:1px solid var(--border)}
    \\.roster-table td{padding:.55rem .65rem;border-bottom:1px solid var(--border)}
    \\.roster-table tr:last-child td{border-bottom:0}
    \\.roster-table tr:hover td{background:var(--surface-2)}
    \\.mono{font-family:ui-monospace,monospace;color:var(--ink-mute)}
    \\
    \\/* activity */
    \\.activity-list{list-style:none;padding:0;margin:0;display:flex;flex-direction:column;gap:.45rem}
    \\.activity-row{display:flex;align-items:center;gap:.65rem;padding:.45rem 0}
    \\.activity-pill{font-size:.7rem;text-transform:uppercase;letter-spacing:.06em;font-weight:700;color:var(--accent);min-width:60px}
    \\.activity-row[data-kind="team"] .activity-pill{color:var(--purple)}
    \\.activity-row[data-kind="settings"] .activity-pill{color:var(--warn)}
    \\.activity-text{color:var(--ink-mute);font-size:.88rem}
    \\
    \\/* settings form */
    \\.settings-form{display:flex;flex-direction:column;gap:var(--gap)}
    \\.settings-grid{display:grid;grid-template-columns:280px 1fr;gap:1.25rem 1.5rem;align-items:center}
    \\@media (max-width:680px){.settings-grid{grid-template-columns:1fr}}
    \\.setting-name{font-weight:600}
    \\.setting-help{font-size:.8rem;color:var(--ink-mute);margin-top:.2rem;line-height:1.4}
    \\.radio-group{display:flex;gap:.5rem;flex-wrap:wrap}
    \\.radio{display:inline-flex;align-items:center;gap:.4rem;padding:.4rem .75rem;background:var(--surface-2);border:1px solid var(--border);border-radius:6px;cursor:pointer;font-size:.85rem;transition:border-color .15s,background .15s}
    \\.radio:has(input:checked){border-color:var(--accent);background:#0d2447;color:#7cb7ff}
    \\.radio input{appearance:none;width:.85rem;height:.85rem;border-radius:50%;border:1px solid var(--border);margin:0}
    \\.radio input:checked{background:var(--accent);border-color:var(--accent);box-shadow:inset 0 0 0 3px var(--surface-2)}
    \\.visually-hidden{position:absolute;left:-9999px}
    \\.toggle{display:inline-flex;align-items:center;gap:.55rem;cursor:pointer;user-select:none}
    \\.toggle input{position:absolute;opacity:0;pointer-events:none}
    \\.toggle-track{position:relative;display:inline-block;width:36px;height:20px;background:#1a1c25;border:1px solid var(--border);border-radius:999px;transition:background .15s}
    \\.toggle-thumb{position:absolute;top:1px;left:1px;width:16px;height:16px;background:var(--ink-mute);border-radius:50%;transition:transform .15s,background .15s}
    \\.toggle input:checked + .toggle-track{background:var(--accent);border-color:var(--accent)}
    \\.toggle input:checked + .toggle-track .toggle-thumb{transform:translateX(16px);background:#fff}
    \\.toggle-label{font-size:.85rem;color:var(--ink-mute)}
    \\.inline-row{display:flex;align-items:center;gap:.75rem}
    \\.color-readout,.range-readout{font-family:ui-monospace,monospace;font-size:.85rem;color:var(--ink-mute)}
    \\.settings-actions{display:flex;justify-content:flex-end;gap:.6rem;margin-top:.4rem}
    \\
    \\/* accordion */
    \\.accordion{border-bottom:1px solid var(--border);padding:.65rem 0}
    \\.accordion:last-child{border-bottom:0}
    \\.accordion-q{cursor:pointer;font-weight:500;padding:.25rem 0;list-style:none}
    \\.accordion-q::marker{display:none}
    \\.accordion-q::before{content:"▸";color:var(--ink-mute);margin-right:.5rem;display:inline-block;transition:transform .15s}
    \\details[open] .accordion-q::before{transform:rotate(90deg)}
    \\.accordion-a{padding:.5rem 0 .25rem 1.4rem;color:var(--ink-mute);font-size:.88rem;line-height:1.5}
    \\
    \\/* link */
    \\.link{color:var(--accent);font-size:.85rem}
    \\.link:hover{color:var(--accent-hover);text-decoration:underline}
    \\
    \\/* footer */
    \\.site-footer{padding:1rem 1.5rem;border-top:1px solid var(--border);color:var(--ink-soft);font-size:.8rem;display:flex;gap:.5rem;justify-content:center;align-items:center}
    \\.dot{color:var(--border-strong)}
    \\
    \\/* external page */
    \\.grid-3-eq{display:grid;grid-template-columns:repeat(3,1fr);gap:var(--gap)}
    \\@media (max-width:980px){.grid-3-eq{grid-template-columns:1fr}}
    \\.api-card{display:flex;flex-direction:column}
    \\.api-card .card-body{flex:1;display:flex;flex-direction:column;gap:.85rem}
    \\.api-meta{margin-top:auto;font-size:.78rem;color:var(--ink-soft);display:flex;align-items:center;gap:.35rem;flex-wrap:wrap;padding-top:.6rem;border-top:1px dashed var(--border)}
    \\.api-error{padding:.65rem .8rem;background:#1c0a0a;border:1px solid #6b1f1f;color:#ff9b9b;border-radius:6px;font-size:.88rem}
    \\.api-help{font-size:.82rem;color:var(--ink-mute);margin:0;line-height:1.45}
    \\.joke{margin:0;padding:1rem 1.1rem;background:var(--surface-2);border-left:3px solid var(--accent);border-radius:6px;font-style:italic;line-height:1.5;color:var(--ink)}
    \\.plain-list{list-style:none;padding:0;margin:0;display:flex;flex-direction:column;gap:.55rem}
    \\.plain-list li{font-size:.88rem;line-height:1.55;color:var(--ink-mute)}
    \\.plain-list li strong{color:var(--ink)}
    \\.muted{color:var(--ink-soft);font-size:.82rem}
    \\code{background:var(--surface-2);padding:.05rem .35rem;border-radius:4px;font-family:ui-monospace,monospace;font-size:.85em;color:var(--ink-mute);word-break:break-all}
    \\
    \\/* carbon */
    \\.carbon-grid{display:grid;grid-template-columns:auto 1fr;gap:1rem;align-items:center}
    \\.carbon-rating{display:flex;flex-direction:column;align-items:center;justify-content:center;padding:1rem;background:linear-gradient(135deg,#2e2305,#1c1505);border:1px solid #5b4513;border-radius:8px;min-width:90px}
    \\.carbon-rating-letter{font-size:2.5rem;font-weight:800;color:#f0c674;font-family:ui-serif,serif;line-height:1}
    \\.carbon-rating-label{font-size:.7rem;text-transform:uppercase;letter-spacing:.08em;color:var(--ink-soft);margin-top:.25rem}
    \\.carbon-stats{display:flex;flex-direction:column;gap:.35rem}
    \\.carbon-stat{display:flex;justify-content:space-between;align-items:baseline;font-size:.85rem}
    \\.carbon-stat-label{color:var(--ink-mute);text-transform:uppercase;letter-spacing:.04em;font-size:.7rem}
    \\.carbon-stat-value{font-variant-numeric:tabular-nums}
    \\
    \\/* disney */
    \\.disney-meta{display:grid;grid-template-columns:repeat(3,1fr);gap:.5rem}
    \\.disney-summary{padding:.6rem;background:var(--surface-2);border-radius:6px;text-align:center}
    \\.metric{display:block;font-size:1.5rem;font-weight:700;font-variant-numeric:tabular-nums;color:var(--accent)}
    \\.metric-label{font-size:.7rem;color:var(--ink-mute);text-transform:uppercase;letter-spacing:.05em}
    \\
    \\/* carousel */
    \\.carousel-card .card-body{padding:0}
    \\.carousel-controls{display:flex;align-items:center;gap:.5rem}
    \\.carousel-counter{font-variant-numeric:tabular-nums;font-size:.85rem;color:var(--ink-mute);min-width:3.5rem;text-align:center}
    \\.carousel-body{padding:1.5rem}
    \\.carousel{position:relative}
    \\.carousel-slide{display:grid;grid-template-columns:240px 1fr;gap:1.5rem;align-items:start}
    \\@media (max-width:760px){.carousel-slide{grid-template-columns:1fr}}
    \\.carousel-portrait{background:#0a0b10;border:1px solid var(--border);border-radius:10px;overflow:hidden;aspect-ratio:1/1.2;display:flex;align-items:center;justify-content:center}
    \\.carousel-portrait img{max-width:100%;max-height:100%;object-fit:cover;display:block}
    \\.carousel-info{display:flex;flex-direction:column;gap:.55rem;min-width:0}
    \\.carousel-info h3{font-size:1.35rem;color:var(--ink);font-weight:700;letter-spacing:-.01em;margin:0}
    \\.carousel-id{color:var(--ink-soft);font-family:ui-monospace,monospace;font-size:.85rem}
    \\.carousel-detail-row{display:flex;align-items:center;gap:.5rem;flex-wrap:wrap}
    \\.carousel-source{margin-top:auto;font-size:.78rem;display:flex;flex-wrap:wrap;gap:.25rem;align-items:baseline}
    \\.film-list{list-style:disc;padding:0 0 0 1.25rem;margin:.2rem 0 0;display:flex;flex-direction:column;gap:.2rem;font-size:.88rem;color:var(--ink-mute)}
    \\.film-list.empty{list-style:none;padding:0;color:var(--ink-soft);font-style:italic}
    \\
    \\/* sse control */
    \\.sse-card .card-body{display:flex;flex-direction:column;gap:1rem}
    \\.sse-metrics{display:grid;grid-template-columns:repeat(3,1fr);gap:.75rem}
    \\@media (max-width:680px){.sse-metrics{grid-template-columns:1fr}}
    \\.sse-stat{padding:.85rem 1rem;background:var(--surface-2);border-radius:8px;border:1px solid var(--border)}
    \\.sse-stat-label{font-size:.7rem;color:var(--ink-mute);text-transform:uppercase;letter-spacing:.06em;font-weight:600}
    \\.sse-stat-value{font-size:1.6rem;font-weight:700;font-variant-numeric:tabular-nums;margin-top:.25rem;color:var(--accent)}
    \\.sse-actions{display:flex;gap:.5rem;flex-wrap:wrap}
    \\
    \\/* a11y skip link + focus */
    \\.skip-link{position:absolute;top:-100px;left:1rem;padding:.5rem 1rem;background:var(--accent);color:#fff;z-index:1000;border-radius:0 0 6px 6px;transition:top .15s}
    \\.skip-link:focus{top:0;outline:2px solid #fff;outline-offset:2px}
    \\*:focus{outline:none}
    \\*:focus-visible{outline:2px solid var(--accent);outline-offset:2px;border-radius:4px}
    \\.visually-hidden{position:absolute!important;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}
    \\.is-filtered-out{display:none!important}
    \\
    \\/* search bar */
    \\.search-bar{position:relative;display:flex;align-items:center;flex:0 0 22rem;background:var(--surface-2);border:1px solid var(--border);border-radius:8px;padding:.4rem .65rem .4rem 2rem;transition:border-color .15s}
    \\.search-bar:focus-within{border-color:var(--accent)}
    \\.search-bar input{flex:1;background:transparent;border:0;padding:.1rem .25rem;color:inherit;font:inherit;outline:none}
    \\.search-icon{position:absolute;left:.7rem;color:var(--ink-soft);font-size:1.05rem}
    \\.search-count{font-size:.78rem;color:var(--ink-mute);white-space:nowrap}
    \\@media (max-width:980px){.search-bar{flex:1 1 auto;order:99;width:100%}}
    \\
    \\/* theme + palette trigger */
    \\.theme-toggle,.palette-trigger{padding:.35rem .6rem;font-size:.85rem}
    \\
    \\/* command palette */
    \\.palette-overlay{position:fixed;inset:0;background:rgba(0,0,0,.6);backdrop-filter:blur(4px);display:none;align-items:flex-start;justify-content:center;padding-top:10vh;z-index:500}
    \\.palette-overlay.is-open{display:flex}
    \\.palette-card{background:var(--surface);border:1px solid var(--border-strong);border-radius:12px;width:min(620px,92vw);overflow:hidden;box-shadow:0 24px 56px rgba(0,0,0,.55)}
    \\.palette-input-row{display:flex;align-items:center;gap:.6rem;padding:.85rem 1rem;border-bottom:1px solid var(--border)}
    \\.palette-icon{font-size:1rem;color:var(--ink-mute)}
    \\.palette-input-row input{flex:1;background:transparent;border:0;outline:none;color:var(--ink);font-size:1.05rem;padding:.25rem 0}
    \\.palette-hint{font-size:.7rem;border:1px solid var(--border);padding:.1rem .35rem;border-radius:4px;color:var(--ink-mute)}
    \\.palette-list{list-style:none;padding:.35rem;margin:0;max-height:50vh;overflow:auto}
    \\.palette-item{display:flex;align-items:center;gap:.6rem;padding:.55rem .65rem;border-radius:6px;cursor:pointer}
    \\.palette-item.is-active{background:#0d2447;color:#fff}
    \\.palette-item.is-active .palette-item-kind{color:#7cb7ff}
    \\.palette-item-kind{font-size:.65rem;text-transform:uppercase;letter-spacing:.08em;color:var(--ink-mute);min-width:44px}
    \\.palette-item-label{flex:1}
    \\.palette-item-hint{font-family:ui-monospace,monospace;font-size:.78rem;color:var(--ink-soft)}
    \\.palette-foot{display:flex;justify-content:space-between;padding:.6rem 1rem;border-top:1px solid var(--border);background:var(--surface-2);font-size:.78rem}
    \\body.modal-open{overflow:hidden}
    \\
    \\/* toasts */
    \\.toast-region{position:fixed;right:1.25rem;bottom:1.25rem;display:flex;flex-direction:column;gap:.55rem;z-index:600;pointer-events:none;max-width:min(420px,92vw)}
    \\.toast{display:flex;align-items:center;gap:.65rem;padding:.65rem .85rem;background:var(--surface);border:1px solid var(--border-strong);border-left:3px solid var(--accent);border-radius:8px;box-shadow:0 12px 32px rgba(0,0,0,.45);pointer-events:auto;animation:toast-in .22s ease-out;font-size:.88rem}
    \\.toast.toast-error{border-left-color:#ff6b6b}
    \\.toast.toast-warn{border-left-color:var(--warn)}
    \\.toast.toast-ok{border-left-color:var(--ok)}
    \\.toast.is-leaving{animation:toast-out .22s ease-in forwards}
    \\.toast-body{flex:1}
    \\.toast-close{background:transparent;border:0;color:var(--ink-mute);font-size:1.1rem;cursor:pointer;padding:0 .2rem}
    \\.toast-close:hover{color:var(--ink)}
    \\@keyframes toast-in{from{opacity:0;transform:translateX(20px)}to{opacity:1;transform:translateX(0)}}
    \\@keyframes toast-out{to{opacity:0;transform:translateX(20px)}}
    \\
    \\/* sparklines */
    \\.sparkline-card .card-body{display:flex;flex-direction:column;gap:.8rem}
    \\.sparkline{width:100%;height:80px;display:block}
    \\.sparkline-empty{padding:1.5rem;text-align:center;color:var(--ink-soft);border:1px dashed var(--border);border-radius:8px}
    \\.sparkline-stats{display:grid;grid-template-columns:repeat(4,1fr);gap:.5rem}
    \\.spark-stat{padding:.55rem;background:var(--surface-2);border-radius:6px;border:1px solid var(--border);text-align:center}
    \\.spark-stat-label{font-size:.65rem;text-transform:uppercase;letter-spacing:.05em;color:var(--ink-mute)}
    \\.spark-stat-value{font-size:1.1rem;font-weight:600;font-variant-numeric:tabular-nums;margin-top:.15rem}
    \\.grid-2{display:grid;grid-template-columns:1fr 1fr;gap:var(--gap)}
    \\@media (max-width:760px){.grid-2{grid-template-columns:1fr}}
    \\
    \\/* live chat */
    \\.live-chat{display:grid;gap:1rem}
    \\.live-input-row{display:grid;grid-template-columns:7rem 1fr;gap:.5rem .75rem;align-items:center}
    \\.live-input-row input{padding:.5rem .65rem;background:var(--surface-2);color:var(--ink);border:1px solid var(--border);border-radius:6px}
    \\.live-input-row [data-live-input]{grid-column:2;min-width:0}
    \\.live-input-row [data-live-send]{grid-column:1/-1;justify-self:end}
    \\.live-label{color:var(--ink-mute);font-size:.85rem}
    \\.live-log{max-height:24rem;overflow:auto;padding:.6rem;background:var(--surface-2);border:1px solid var(--border);border-radius:8px;display:flex;flex-direction:column;gap:.35rem;font-size:.9rem}
    \\.live-row{display:grid;grid-template-columns:auto 1fr auto;gap:.5rem;padding:.25rem 0;border-bottom:1px dashed var(--border)}
    \\.live-row:last-child{border-bottom:0}
    \\.live-nick{font-weight:600;color:#7cb7ff}
    \\.live-msg{color:var(--ink)}
    \\.live-ts{color:var(--ink-soft);font-size:.78rem;font-family:ui-monospace,monospace}
    \\.live-empty{padding:.5rem;text-align:center;font-style:italic}
    \\
    \\/* drag and drop */
    \\.task-card.is-dragging{opacity:.4}
    \\.kanban-stack.is-drop-target{outline:2px dashed var(--accent);outline-offset:-2px;background:rgba(31,111,235,.07)}
    \\.task-card[draggable="true"]{cursor:grab}
    \\.task-card[draggable="true"]:active{cursor:grabbing}
    \\
    \\/* light theme overrides */
    \\:root[data-theme="light"]{--bg:#f7f8fa;--surface:#ffffff;--surface-2:#f0f2f6;--border:#dde1e7;--border-strong:#c2c7cf;--ink:#15161c;--ink-mute:#52576a;--ink-soft:#8b91a2;--accent:#0f59c8;--accent-hover:#1d6fde;--warn:#a35a05;--ok:#197d34;--danger:#9a2222;--purple:#6d3ed1}
    \\:root[data-theme="light"] .alert[data-kind="ok"]{background:#dff5e6;border-color:#a8dbb5}
    \\:root[data-theme="light"] .alert[data-kind="warn"]{background:#fdf2cd;border-color:#e3c98a}
    \\:root[data-theme="light"] .alert[data-kind="error"]{background:#fbe1e0;border-color:#e3a4a1}
    \\:root[data-theme="light"] .badge[data-kind="ok"],:root[data-theme="light"] .badge[data-kind="active"]{background:#dff5e6;color:#197d34;border-color:#a8dbb5}
    \\:root[data-theme="light"] .badge[data-kind="warn"],:root[data-theme="light"] .badge[data-kind="away"],:root[data-theme="light"] .badge[data-kind="Med"]{background:#fdf2cd;color:#a35a05;border-color:#e3c98a}
    \\:root[data-theme="light"] .badge[data-kind="error"],:root[data-theme="light"] .badge[data-kind="High"]{background:#fbe1e0;color:#9a2222;border-color:#e3a4a1}
    \\:root[data-theme="light"] .badge[data-kind="info"]{background:#dde9fc;color:#0f59c8;border-color:#9cbcf0}
    \\:root[data-theme="light"] .palette-item.is-active{background:#0f59c8;color:#fff}
    \\:root[data-theme="light"] .palette-item.is-active .palette-item-kind{color:#cfe1ff}
    \\:root[data-theme="light"] .joke{background:#f0f2f6;border-left-color:var(--accent)}
    \\:root[data-theme="auto"]{color-scheme:light dark}
    \\@media (prefers-color-scheme:light){:root[data-theme="auto"]{--bg:#f7f8fa;--surface:#ffffff;--surface-2:#f0f2f6;--border:#dde1e7;--border-strong:#c2c7cf;--ink:#15161c;--ink-mute:#52576a;--ink-soft:#8b91a2;--accent:#0f59c8}}
;
