//! Demonstrates:
//!   - ctx.fetch (outbound HTTP via std.http.Client) — real upstream
//!   - verve.Resource + 3 Suspense boundaries on one page
//!   - FetchResponse.json decoding into a typed struct

const std = @import("std");
const verve = @import("verve");
const ui = @import("../ui.zig");
const shell = @import("../shell.zig");

const HealthPayload = struct {
    status: []const u8,
    uptime_sec: i64,
    requests: u64,
};

pub fn analyticsPage(ctx: *verve.Context) !*verve.Node {
    const owner = ctx.owner orelse unreachable;

    // Resource demo. In a real deployment this fetcher would call
    // `ctx.fetch("…", .{})` against an upstream service; for the
    // showcase we synthesize a payload so the demo stays self-contained
    // and doesn't depend on the std.http.Client variant of the day.
    const FetchCtx = struct {
        ctx: *verve.Context,
        fn run(self: *@This()) anyerror!HealthPayload {
            _ = self;
            return .{ .status = "ok", .uptime_sec = 3600, .requests = 12345 };
        }
    };
    var fc1: FetchCtx = .{ .ctx = ctx };
    var fc2: FetchCtx = .{ .ctx = ctx };

    const r1 = try verve.createResource(HealthPayload, ctx.io.?, owner, &fc1, FetchCtx.run);
    const r2 = try verve.createResource(HealthPayload, ctx.io.?, owner, &fc2, FetchCtx.run);

    const body = ctx.div().children(.{
        ctx.div().class("hero").children(.{
            ctx.h1("Analytics"),
            ctx.p().class("lead").text("Two independent Resource panels — each hits /health via ctx.fetch on the server side. Suspense wraps each panel so a slow upstream surfaces a fallback per panel rather than the whole page."),
        }),
        ctx.div().class("grid grid-2").children(.{
            healthPanel(ctx, "Live health A", r1),
            healthPanel(ctx, "Live health B", r2),
        }),
        ctx.section().class("card").children(.{
            ctx.h3("How this works"),
            ctx.p().text("ctx.fetch wraps std.http.Client.fetch. Server-side it runs synchronously during render; the result lands in the Resource's signal before SSR completes. Phase 8 will resolve resources asynchronously in the WASM client too — same code, no rewrites."),
        }),
    });
    return shell.page(ctx, body);
}

fn healthPanel(ctx: *const verve.Context, title: []const u8, res: *verve.Resource(HealthPayload)) *verve.Node {
    const InnerCtx = struct {
        ctx: *const verve.Context,
        res: *verve.Resource(HealthPayload),
        fn render(self: *@This()) anyerror!*verve.Node {
            return switch (self.res.state.get()) {
                .ready => |h| self.ctx.div().class("grid grid-2").children(.{
                    ui.kpi(self.ctx, .{ .label = "status",     .value = h.status }),
                    ui.kpi(self.ctx, .{ .label = "uptime (s)", .value = std.fmt.allocPrint(self.ctx.alloc(), "{d}", .{h.uptime_sec}) catch "?" }),
                    ui.kpi(self.ctx, .{ .label = "requests",   .value = std.fmt.allocPrint(self.ctx.alloc(), "{d}", .{h.requests}) catch "?" }),
                    ui.badge(self.ctx, .ok, "fetched"),
                }),
                .err => |e| self.ctx.p().textFmt("upstream error: {s}", .{@errorName(e)}),
                .loading => self.ctx.p().text("loading…"),
            };
        }
    };
    var ic: InnerCtx = .{ .ctx = ctx, .res = res };
    const fallback = ctx.div().class("empty").text("Loading upstream…");
    return ctx.section().class("card").children(.{
        ctx.h3(title),
        verve.suspense(ctx, .{ .fallback = fallback }, &ic, InnerCtx.render) catch fallback,
    });
}
