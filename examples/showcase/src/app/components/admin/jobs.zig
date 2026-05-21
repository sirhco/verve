//! Demonstrates:
//!   - verve.batch (coalesces effect re-runs across multiple sets)
//!   - verve.untrack (read a signal without subscribing)
//!   - StoredValue alternative (just plain Signals here)

const std = @import("std");
const verve = @import("verve");
const ui = @import("../ui.zig");
const shell = @import("../shell.zig");

pub fn jobsPage(ctx: *verve.Context) !*verve.Node {
    const queued = try ctx.useSignal(u32, 0);
    const running = try ctx.useSignal(u32, 0);
    const finished = try ctx.useSignal(u32, 0);

    // Effect that reads ALL three counters → re-runs whenever any one
    // changes. Without batch, three sets = three re-runs.
    var tally: u32 = 0;
    var tally_ctx = struct {
        q: *verve.Signal(u32),
        r: *verve.Signal(u32),
        f: *verve.Signal(u32),
        t: *u32,
        fn run(self: *@This()) void {
            _ = self.q.get();
            _ = self.r.get();
            _ = self.f.get();
            self.t.* += 1;
        }
    }{ .q = queued, .r = running, .f = finished, .t = &tally };
    _ = try ctx.useEffect(&tally_ctx, @TypeOf(tally_ctx).run);

    // batch coalesces three writes → ONE re-run.
    const Updater = struct {
        q: *verve.Signal(u32),
        r: *verve.Signal(u32),
        f: *verve.Signal(u32),
        fn run(self: *@This()) void {
            self.q.set(7);
            self.r.set(3);
            self.f.set(120);
        }
    };
    var u: Updater = .{ .q = queued, .r = running, .f = finished };
    verve.batch(&u, Updater.run);

    // untrack: peek into a counter without subscribing this effect.
    const Peek = struct {
        q: *verve.Signal(u32),
        fn read(self: *@This()) u32 {
            return self.q.peek();
        }
    };
    var p: Peek = .{ .q = queued };
    const peeked = verve.untrack(u32, &p, Peek.read);

    const body = ctx.div().children(.{
        ctx.div().class("hero").children(.{
            ctx.h1("Jobs"),
            ctx.p().class("lead").text("Reactivity escape hatches at work — batch coalesces multi-field writes into a single re-run; untrack reads without subscribing."),
        }),
        ctx.div().class("grid grid-3").children(.{
            ui.kpi(ctx, .{ .label = "queued",   .value = std.fmt.allocPrint(ctx.alloc(), "{d}", .{queued.peek()}) catch "0" }),
            ui.kpi(ctx, .{ .label = "running",  .value = std.fmt.allocPrint(ctx.alloc(), "{d}", .{running.peek()}) catch "0" }),
            ui.kpi(ctx, .{ .label = "finished", .value = std.fmt.allocPrint(ctx.alloc(), "{d}", .{finished.peek()}) catch "0" }),
        }),
        ctx.div().class("alert info").children(.{
            ctx.strong("Effect tally"),
            ctx.div().textFmt(
                "After eager run + one batched 3-write update: tally = {d}. Without batch this would be 3 (one re-run per write).",
                .{tally},
            ),
        }),
        ctx.div().class("alert info").children(.{
            ctx.strong("untrack"),
            ctx.div().textFmt("Peeked queued without subscribing: {d}", .{peeked}),
        }),
    });
    return shell.page(ctx, body);
}
