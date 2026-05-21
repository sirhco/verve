//! Demonstrates:
//!   - Node chain composition (card, badge, button, kpi, breadcrumb)
//!   - Node.attrFmt
//!   - verve.show, verve.forEach (re-exported helpers used elsewhere)

const std = @import("std");
const verve = @import("verve");

pub fn card(ctx: *const verve.Context, opts: struct {
    title: ?[]const u8 = null,
    action: ?*verve.Node = null,
    hoverable: bool = false,
}) *verve.Node {
    var n = ctx.section().class("card");
    if (opts.hoverable) n = n.class("card hoverable");
    if (opts.title != null or opts.action != null) {
        var head = ctx.div().class("card-head");
        if (opts.title) |t| _ = head.children(.{ ctx.h2(t) });
        if (opts.action) |a| _ = head.children(.{ a });
        _ = n.children(.{head});
    }
    return n;
}

pub const BadgeKind = enum { info, ok, warn, err, muted };

pub fn badge(ctx: *const verve.Context, kind: BadgeKind, label: []const u8) *verve.Node {
    const class_name = switch (kind) {
        .info => "badge info",
        .ok => "badge ok",
        .warn => "badge warn",
        .err => "badge err",
        .muted => "badge muted",
    };
    return ctx.span().class(class_name).text(label);
}

pub fn kpi(ctx: *const verve.Context, opts: struct {
    label: []const u8,
    value: []const u8,
    delta: ?[]const u8 = null,
}) *verve.Node {
    var n = ctx.div().class("kpi").children(.{
        ctx.span().class("kpi-label").text(opts.label),
        ctx.span().class("kpi-value").text(opts.value),
    });
    if (opts.delta) |d| _ = n.children(.{ ctx.span().class("kpi-delta").text(d) });
    return n;
}

pub fn alert(ctx: *const verve.Context, kind: BadgeKind, label: []const u8, body: []const u8) *verve.Node {
    const cls = switch (kind) {
        .info => "alert info",
        .warn => "alert warn",
        .err => "alert err",
        .ok, .muted => "alert info",
    };
    return ctx.div().class(cls).children(.{
        ctx.div().children(.{
            ctx.strong(label),
            ctx.div().text(body),
        }),
    });
}

pub const CrumbItem = struct { label: []const u8, href: ?[]const u8 = null };

pub fn breadcrumb(ctx: *const verve.Context, items: []const CrumbItem) *verve.Node {
    var nav = ctx.nav().class("crumb").attr("aria-label", "Breadcrumb");
    for (items, 0..) |it, i| {
        if (i > 0) _ = nav.children(.{ ctx.span().class("crumb-sep").text("/") });
        if (it.href) |h| {
            _ = nav.children(.{ verve.link(ctx, h, it.label, .{}) });
        } else {
            _ = nav.children(.{ ctx.span().text(it.label) });
        }
    }
    return nav;
}

pub fn avatar(ctx: *const verve.Context, seed: []const u8) *verve.Node {
    return ctx.span().class("avatar").attr("aria-hidden", "true").text(seed);
}

pub fn divider(ctx: *const verve.Context) *verve.Node {
    return ctx.hr();
}

pub fn tag(ctx: *const verve.Context, label: []const u8) *verve.Node {
    return badge(ctx, .muted, label);
}
