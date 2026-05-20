//! Showcase components — one render fn per Phase 0-10 surface.

const std = @import("std");
const verve = @import("verve");
const api = @import("api.zig");

// ---- shell ------------------------------------------------------------

pub fn page(ctx: *const verve.Context, body: *verve.Node) !*verve.Node {
    try ctx.setTitleIfUnset("Verve Showcase");

    var aw: std.Io.Writer.Allocating = .init(ctx.alloc());
    try ctx.head.?.render(&aw.writer);
    const head_html = aw.written();

    return ctx.el("html").children(.{
        ctx.el("head").children(.{
            ctx.raw(head_html),
            ctx.style(
                \\body{font:16px system-ui;margin:2rem;background:#0e0e10;color:#f5f5f5;line-height:1.5}
                \\main{max-width:48rem}
                \\h1,h2,h3{line-height:1.2}
                \\a{color:#58a6ff;text-decoration:none}
                \\a:hover{text-decoration:underline}
                \\a[aria-current=page]{color:#fff;font-weight:600}
                \\nav{display:flex;gap:.75rem;flex-wrap:wrap;padding:.5rem 0;border-bottom:1px solid #2a2a2e;margin-bottom:1.5rem}
                \\code{background:#1a1a1d;padding:0 .25rem;border-radius:3px;font-size:.95em}
                \\pre{background:#1a1a1d;padding:1rem;border-radius:6px;overflow:auto}
                \\.card{border:1px solid #2a2a2e;border-radius:8px;padding:1rem;margin:1rem 0}
                \\.tag{font-size:.7em;text-transform:uppercase;letter-spacing:.06em;color:#8b949e;padding:.1rem .35rem;border:1px solid #2a2a2e;border-radius:3px;margin-right:.4rem}
                \\button{font:inherit;padding:.4rem .9rem;background:#1f6feb;color:#fff;border:0;border-radius:4px;cursor:pointer}
                \\button:hover{background:#388bfd}
                \\.muted{color:#8b949e}
                \\form{margin:.5rem 0}
                \\input[type=text]{padding:.4rem;background:#1c1c1f;color:inherit;border:1px solid #333;border-radius:4px;font:inherit}
                \\ul{padding-left:1.25rem}
            ),
        }),
        ctx.el("body").children(.{
            navBar(ctx),
            body,
            ctx.script("/verve.js"),
        }),
    }).build();
}

fn navBar(ctx: *const verve.Context) *verve.Node {
    return ctx.nav().children(.{
        verve.link(ctx, "/",                 "Home",      .{}),
        verve.link(ctx, "/counter-reactive", "Counter",   .{ .prefetch_on_hover = true }),
        verve.link(ctx, "/store-demo",       "Store",     .{}),
        verve.link(ctx, "/resource-demo",    "Resource",  .{}),
        verve.link(ctx, "/suspense-demo",    "Suspense",  .{}),
        verve.link(ctx, "/error-boundary",   "Errors",    .{}),
        verve.link(ctx, "/forms-demo",       "Forms",     .{}),
        verve.link(ctx, "/i18n/es",          "i18n",      .{}),
        verve.link(ctx, "/app/dashboard",    "Nested",    .{}),
        verve.link(ctx, "/work/hello-world", "Path-param",.{}),
        verve.link(ctx, "/spa-tour",         "SPA tour",  .{}),
        verve.link(ctx, "/island-demo",      "Islands",   .{}),
    });
}

fn tag(ctx: *const verve.Context, label: []const u8) *verve.Node {
    return ctx.span().class("tag").text(label);
}

// ---- home -------------------------------------------------------------

pub fn home(ctx: *verve.Context) !*verve.Node {
    const body = ctx.main_().children(.{
        ctx.h1("Verve Showcase"),
        ctx.p().text("Live tour of every Phase 0-10 surface. Click through the nav above; each page is a focused demo with code references."),
        ctx.h2("What's covered"),
        ctx.ul().children(.{
            ctx.li().children(.{ tag(ctx, "Phase 0"), ctx.span().text("path params + Location + asset hashing + RequestMeta") }),
            ctx.li().children(.{ tag(ctx, "Phase 1"), ctx.span().text("Owner / Signal / Effect / NodeRef / StoredValue") }),
            ctx.li().children(.{ tag(ctx, "Phase 2"), ctx.span().text("provide/use DI + head slots (title, meta, link, json-ld)") }),
            ctx.li().children(.{ tag(ctx, "Phase 3"), ctx.span().text("ctx.fetch + Resource + Action + ctx.serverFn") }),
            ctx.li().children(.{ tag(ctx, "Phase 4"), ctx.span().text("Suspense + Transition + binary SSR codec") }),
            ctx.li().children(.{ tag(ctx, "Phase 5"), ctx.span().text("CSRF + actionForm + CSP nonce") }),
            ctx.li().children(.{ tag(ctx, "Phase 6"), ctx.span().text("show / forEach / portal / Slot") }),
            ctx.li().children(.{ tag(ctx, "Phase 7"), ctx.span().text("SPA Link + nested routes + Outlet + Redirect + ProtectedRoute") }),
            ctx.li().children(.{ tag(ctx, "Phase 8"), ctx.span().text("Islands marker (hydration loader deferred)") }),
            ctx.li().children(.{ tag(ctx, "Phase 9"), ctx.span().text("Store + i18n + reactive ErrorBoundary") }),
            ctx.li().children(.{ tag(ctx, "Phase 10"), ctx.span().text("--dev auto-reload") }),
        }),
        ctx.p().class("muted").children(.{
            ctx.span().text("Try: "),
            ctx.code("zig build --watch run -- --dev"),
            ctx.span().text(" then edit any component for instant browser refresh."),
        }),
    }).build() catch unreachable;
    return page(ctx, body);
}

// ---- /work/:slug (path param + head slots + JSON-LD) -----------------

pub fn workDetail(ctx: *verve.Context, slug: []const u8) !*verve.Node {
    try ctx.setTitle(try std.fmt.allocPrint(ctx.alloc(), "Work — {s}", .{slug}));
    try ctx.metaTag(.{ .name = "description", .content = "Path-param + per-page head demo." });
    try ctx.linkTag(.{
        .rel = "canonical",
        .href = try std.fmt.allocPrint(ctx.alloc(), "https://example.com/work/{s}", .{slug}),
    });
    try ctx.metaTag(.{
        .name = "og:title",
        .content = slug,
        .is_property = true,
        .priority = 40,
    });
    try ctx.jsonLd(try std.fmt.allocPrint(
        ctx.alloc(),
        "{{\"@context\":\"https://schema.org\",\"@type\":\"CreativeWork\",\"name\":\"{s}\"}}",
        .{slug},
    ));

    const body = ctx.main_().children(.{
        ctx.h1("Path-param + head slots"),
        ctx.p().children(.{
            tag(ctx, "Phase 0"), tag(ctx, "Phase 2"),
            ctx.span().text("Slug captured into "),
            ctx.code("ctx.params[\"slug\"]"),
            ctx.span().text(": "),
            ctx.code(slug),
        }),
        ctx.p().text("View source — the <head> contains a per-page title, canonical link, og:title, and JSON-LD block, all contributed by this component via ctx.setTitle / metaTag / linkTag / jsonLd."),
        ctx.p().children(.{
            ctx.span().text("Try another slug: "),
            verve.link(ctx, "/work/zig-on-the-server", "/work/zig-on-the-server", .{}),
        }),
    }).build() catch unreachable;
    return page(ctx, body);
}

// ---- /files/*rest (wildcard) -----------------------------------------

pub fn filePath(ctx: *verve.Context, rest: []const u8) !*verve.Node {
    const body = ctx.main_().children(.{
        ctx.h1("Wildcard path"),
        ctx.p().children(.{
            tag(ctx, "Phase 0"),
            ctx.span().text("Wildcard "),
            ctx.code("*rest"),
            ctx.span().text(" greedily captures the remainder:"),
        }),
        ctx.pre().children(.{ ctx.code(rest) }),
        ctx.p().children(.{
            verve.link(ctx, "/files/a/b/c.txt",          "/files/a/b/c.txt",          .{}),
            ctx.span().text(" · "),
            verve.link(ctx, "/files/docs/2026/q1.pdf",   "/files/docs/2026/q1.pdf",   .{}),
        }),
    }).build() catch unreachable;
    return page(ctx, body);
}

// ---- /counter-reactive (Signal + Effect on the server side) ----------

pub fn counterReactive(ctx: *verve.Context) !*verve.Node {
    // Signals + effects work server-side too — useful for computed
    // values that need to be tracked across helper functions during a
    // single render pass.
    const a = try ctx.useSignal(i32, 7);
    const b = try ctx.useSignal(i32, 3);

    // An effect that logs whenever either signal changes.
    var trace_msg: []const u8 = "";
    var trace_ctx = struct {
        a: *verve.Signal(i32),
        b: *verve.Signal(i32),
        msg: *[]const u8,
        arena: std.mem.Allocator,
        fn run(self: *@This()) void {
            const txt = std.fmt.allocPrint(self.arena, "sum tracked: {d}", .{ self.a.get() + self.b.get() }) catch return;
            self.msg.* = txt;
        }
    }{ .a = a, .b = b, .msg = &trace_msg, .arena = ctx.alloc() };
    _ = try ctx.useEffect(&trace_ctx, @TypeOf(trace_ctx).run);

    // Trigger a write to demonstrate that the effect re-runs.
    verve.batch(&trace_ctx, struct {
        fn run(s: *@TypeOf(trace_ctx)) void {
            s.a.set(10);
            s.b.set(15);
        }
    }.run);

    const body = ctx.main_().children(.{
        ctx.h1("Reactive Signal + Effect (server-side)"),
        ctx.p().children(.{
            tag(ctx, "Phase 1"),
            ctx.span().text("Two signals tracked by an effect that re-runs once on the batched write below."),
        }),
        ctx.ul().children(.{
            ctx.li().children(.{ ctx.span().text("a = "), ctx.code(try std.fmt.allocPrint(ctx.alloc(), "{d}", .{a.peek()})) }),
            ctx.li().children(.{ ctx.span().text("b = "), ctx.code(try std.fmt.allocPrint(ctx.alloc(), "{d}", .{b.peek()})) }),
            ctx.li().children(.{ ctx.span().text("effect last said: "), ctx.code(trace_msg) }),
        }),
        ctx.h2("Legacy client signals + form fallback"),
        ctx.p().children(.{
            tag(ctx, "Phase 5"),
            ctx.span().text("The classic /counter wire still works — server-rendered <span z-bind=\"count\"> + CSRF-protected form increments:"),
        }),
        ctx.span().class("count").bind("count").textInt(api.last_count.load(.monotonic)),
        ctx.actionForm(.{ .post = "/api/incrementCount" }).children(.{
            ctx.button("+").type_("submit").onClick("increment_counter"),
        }),
        ctx.actionForm(.{ .post = "/api/decrementCount" }).children(.{
            ctx.button("-").type_("submit").onClick("decrement_counter"),
        }),
    }).build() catch unreachable;
    return page(ctx, body);
}

// ---- /store-demo (field-grained Store) -------------------------------

pub fn storeDemo(ctx: *verve.Context) !*verve.Node {
    const owner = ctx.owner orelse unreachable;
    const Profile = struct { name: []const u8, age: u32 };
    const store = try verve.createStore(Profile, owner, .{ .name = "alice", .age = 30 });

    var name_hits: u32 = 0;
    var age_hits: u32 = 0;

    var name_ctx = struct { s: *verve.Store(Profile), hits: *u32, fn run(self: *@This()) void {
        _ = self.s.get(.name);
        self.hits.* += 1;
    } }{ .s = store, .hits = &name_hits };
    _ = try ctx.useEffect(&name_ctx, @TypeOf(name_ctx).run);

    var age_ctx = struct { s: *verve.Store(Profile), hits: *u32, fn run(self: *@This()) void {
        _ = self.s.get(.age);
        self.hits.* += 1;
    } }{ .s = store, .hits = &age_hits };
    _ = try ctx.useEffect(&age_ctx, @TypeOf(age_ctx).run);

    // Mutate one field — only that field's effect re-runs.
    store.set(.age, 31);

    const body = ctx.main_().children(.{
        ctx.h1("Store — field-grained signals"),
        ctx.p().children(.{
            tag(ctx, "Phase 9"),
            ctx.span().text("Two effects subscribe to one field each. Mutating "),
            ctx.code(".age"),
            ctx.span().text(" should NOT re-run the "),
            ctx.code(".name"),
            ctx.span().text(" effect."),
        }),
        ctx.ul().children(.{
            ctx.li().children(.{ ctx.code(".name effect runs: "), ctx.code(try std.fmt.allocPrint(ctx.alloc(), "{d}", .{name_hits})) }),
            ctx.li().children(.{ ctx.code(".age  effect runs: "), ctx.code(try std.fmt.allocPrint(ctx.alloc(), "{d}", .{age_hits})) }),
        }),
        ctx.p().class("muted").text("Exact tallies: name=1 (just the eager first run), age=2 (eager + the set)."),
    }).build() catch unreachable;
    return page(ctx, body);
}

// ---- /resource-demo (synchronous Resource) ---------------------------

pub fn resourceDemo(ctx: *verve.Context) !*verve.Node {
    const owner = ctx.owner orelse unreachable;
    const Quote = struct { author: []const u8, text: []const u8 };
    const Fetcher = struct {
        fn run(_: *@This()) anyerror!Quote {
            return .{ .author = "Linus", .text = "Talk is cheap. Show me the code." };
        }
    };
    var f: Fetcher = .{};
    const res = try verve.createResource(Quote, owner, &f, Fetcher.run);

    const body = ctx.main_().children(.{
        ctx.h1("Resource (sync SSR)"),
        ctx.p().children(.{
            tag(ctx, "Phase 3"),
            ctx.span().text("On the server, a Resource's fetcher runs synchronously during render — the resolved value is in the SSR HTML."),
        }),
        switch (res.state.get()) {
            .loading => ctx.p().class("muted").text("Loading… (you should never see this on a sync server fetcher)"),
            .err => |e| ctx.p().textFmt("Error: {s}", .{@errorName(e)}),
            .ready => |q| ctx.section().class("card").children(.{
                ctx.p().children(.{ ctx.em(q.text) }),
                ctx.p().class("muted").children(.{ ctx.span().text("— "), ctx.strong(q.author) }),
            }),
        },
    }).build() catch unreachable;
    return page(ctx, body);
}

// ---- /suspense-demo (suspended Resource → fallback) ------------------

pub fn suspenseDemo(ctx: *verve.Context) !*verve.Node {
    const owner = ctx.owner orelse unreachable;
    const SlowFetcher = struct {
        fn run(_: *@This()) anyerror!u32 {
            // Pretend we'd block on a slow upstream — but DON'T resolve,
            // so Resource.get returns .loading and the Suspense
            // boundary emits its fallback.
            return error.NotReadyYet;
        }
    };
    var sf: SlowFetcher = .{};
    const slow = try verve.createResource(u32, owner, &sf, SlowFetcher.run);

    const fallback = ctx.section().class("card").class("muted").text("⏳ Loading slow widget…");

    const InnerCtx = struct {
        slow: *verve.Resource(u32),
        ctx_ptr: *const verve.Context,
        fn render(self: *@This()) anyerror!*verve.Node {
            return switch (self.slow.state.get()) {
                .err => |e| self.ctx_ptr.p().textFmt("error: {s}", .{@errorName(e)}),
                .loading => self.ctx_ptr.p().text("(unreachable — markSuspended fired)"),
                .ready => |v| self.ctx_ptr.p().textFmt("got {d}", .{v}),
            };
        }
    };
    var ic: InnerCtx = .{ .slow = slow, .ctx_ptr = ctx };
    const child = try verve.suspense(ctx, .{ .fallback = fallback }, &ic, InnerCtx.render);

    const body = ctx.main_().children(.{
        ctx.h1("Suspense fallback"),
        ctx.p().children(.{
            tag(ctx, "Phase 4"),
            ctx.span().text("The widget below reads a Resource in `.err` state, which triggers `markSuspended()` — the boundary emits its fallback in place of the partial render."),
        }),
        child,
        ctx.p().class("muted").text("Phase 8 turns the fallback into an out-of-order chunk swap once async Resources land in the client runtime."),
    }).build() catch unreachable;
    return page(ctx, body);
}

// ---- /error-boundary -------------------------------------------------

pub fn errorBoundaryDemo(ctx: *verve.Context) !*verve.Node {
    const owner = ctx.owner orelse unreachable;
    const eb = try verve.createErrorBoundary(owner);
    eb.captureError(error.SimulatedFailure);

    const captured_label = if (eb.captured()) |e|
        try std.fmt.allocPrint(ctx.alloc(), "captured: {s}", .{@errorName(e)})
    else
        "ok";

    const body = ctx.main_().children(.{
        ctx.h1("ErrorBoundary"),
        ctx.p().children(.{
            tag(ctx, "Phase 9"),
            ctx.span().text("Reactive Signal(?anyerror) — a widget catches its own failure and stores it on the boundary; siblings keep rendering."),
        }),
        ctx.section().class("card").children(.{
            ctx.p().children(.{
                ctx.strong("Boundary state: "),
                ctx.code(captured_label),
            }),
            ctx.p().class("muted").text("In a real app, a 'Try again' button calls eb.reset() to clear the captured state — effects observing eb.captured() re-run."),
        }),
    }).build() catch unreachable;
    return page(ctx, body);
}

// ---- /forms-demo (actionForm + CSRF + todos) -------------------------

pub fn formsDemo(ctx: *verve.Context, items: []const []const u8) !*verve.Node {
    const list = ctx.ul();
    for (items, 0..) |item_text, i| {
        _ = list.children(.{
            ctx.li().children(.{
                ctx.span().text(item_text),
                ctx.span().text("  "),
                ctx.actionForm(.{ .post = "/api/removeTodo" }).children(.{
                    ctx.input().type_("hidden").name("index").attrFmt("value", "{d}", .{i}),
                    ctx.button("✕").type_("submit"),
                }),
            }),
        });
    }

    const body = ctx.main_().children(.{
        ctx.h1("ActionForm + CSRF"),
        ctx.p().children(.{
            tag(ctx, "Phase 5"),
            ctx.span().text("Every form below carries an auto-injected hidden __csrf field; the server rejects POSTs whose token doesn't match the cookie. Try removing the field with devtools and resubmitting → 403."),
        }),
        ctx.actionForm(.{ .post = "/api/addTodo" }).children(.{
            ctx.input().name("text").type_("text").placeholder("Add a todo…").required().autofocus(),
            ctx.button("Add").type_("submit"),
        }),
        list,
        ctx.p().class("muted").children(.{
            ctx.span().text("CSP nonce header: "),
            ctx.code(if (ctx.csp_nonce.len > 0) ctx.csp_nonce else "(none)"),
        }),
    }).build() catch unreachable;
    return page(ctx, body);
}

// ---- /i18n/:locale (locale resolution + catalog) ---------------------

pub fn i18nDemo(ctx: *verve.Context, path_locale: []const u8) !*verve.Node {
    const resolved = try verve.resolveLocale(api.catalog, ctx.request_meta, ctx.location, ctx.alloc());
    // Path-locale override: when the URL explicitly carries a locale
    // segment, prefer it (a real app would put this in a guard).
    const active = if (api.catalog.isSupported(path_locale)) path_locale else resolved;

    const greeting = api.catalog.lookup(active, "greeting");
    const tour = api.catalog.lookup(active, "tour");

    const body = ctx.main_().children(.{
        ctx.h1(tour),
        ctx.p().children(.{
            tag(ctx, "Phase 9"),
            ctx.span().text("Resolved locale: "),
            ctx.code(active),
            ctx.span().text(" (URL: /:locale, fallback chain: cookie > query > Accept-Language > default)"),
        }),
        ctx.h2(greeting),
        ctx.p().children(.{
            verve.link(ctx, "/i18n/en", "EN", .{}),
            ctx.span().text(" · "),
            verve.link(ctx, "/i18n/es", "ES", .{}),
            ctx.span().text(" · "),
            verve.link(ctx, "/i18n/fr", "FR", .{}),
        }),
    }).build() catch unreachable;
    return page(ctx, body);
}

// ---- /app/* (nested layout + outlet) ---------------------------------

pub fn appShell(ctx: *verve.Context, outlet: *verve.Node) !*verve.Node {
    const body = ctx.main_().children(.{
        ctx.h1("Nested layout"),
        ctx.p().children(.{
            tag(ctx, "Phase 7"),
            ctx.span().text("/app is a layout route; the matched child renders into ctx.outlet() below."),
        }),
        ctx.nav().children(.{
            verve.link(ctx, "/app/dashboard",         "Dashboard",      .{}),
            verve.link(ctx, "/app/settings/general",  "Settings · general", .{}),
            verve.link(ctx, "/app/settings/profile",  "Settings · profile", .{}),
        }),
        ctx.section().class("card").children(.{ outlet }),
    }).build() catch unreachable;
    return page(ctx, body);
}

pub fn appDashboard(ctx: *const verve.Context) !*verve.Node {
    return ctx.div().children(.{
        ctx.h2("Dashboard"),
        ctx.p().text("Outlet-rendered child."),
    }).build();
}

pub fn appSettings(ctx: *const verve.Context, section: []const u8) !*verve.Node {
    return ctx.div().children(.{
        ctx.h2("Settings"),
        ctx.p().children(.{ ctx.span().text("Section: "), ctx.code(section) }),
    }).build();
}

// ---- /private (ProtectedRoute) ---------------------------------------

pub fn privatePage(ctx: *verve.Context) !*verve.Node {
    const body = ctx.main_().children(.{
        ctx.h1("Protected route"),
        ctx.p().children(.{
            tag(ctx, "Phase 7"),
            ctx.span().text("This page only renders when ?token=... is in the URL. The guard fn runs before render and returns a Redirect on miss."),
        }),
        ctx.p().children(.{
            verve.link(ctx, "/private", "Without token (redirects)", .{}),
            ctx.span().text(" · "),
            verve.link(ctx, "/private?token=ok", "With token", .{}),
        }),
    }).build() catch unreachable;
    return page(ctx, body);
}

// ---- /spa-tour -------------------------------------------------------

pub fn spaTour(ctx: *verve.Context) !*verve.Node {
    const body = ctx.main_().children(.{
        ctx.h1("SPA navigation"),
        ctx.p().children(.{
            tag(ctx, "Phase 7"),
            ctx.span().text("Every link above is a "),
            ctx.code("verve.link"),
            ctx.span().text(" — the client router intercepts the click, fetches the new page, merges <head>, and swaps the body. No full page reload."),
        }),
        ctx.h2("Head merge"),
        ctx.p().text("Navigate between this page and /work/something — the document title updates instantly without losing scripts loaded on this page."),
        ctx.h2("Prefetch on hover"),
        ctx.p().children(.{
            ctx.span().text("The "),
            verve.link(ctx, "/counter-reactive", "Counter", .{ .prefetch_on_hover = true }),
            ctx.span().text(" link in the nav prefetches on hover; the browser cache absorbs the response so the next click is instant."),
        }),
        ctx.h2("Back/forward"),
        ctx.p().text("popstate is wired — back/forward buttons re-fetch and swap the same way."),
    }).build() catch unreachable;
    return page(ctx, body);
}

// ---- /island-demo (islands marker) -----------------------------------

pub fn islandDemo(ctx: *verve.Context) !*verve.Node {
    const inline_widget = ctx.div().children(.{
        ctx.span().class("count").bind("count").textInt(api.last_count.load(.monotonic)),
    });

    const wrapped = verve.island(ctx, .{
        .name = "Counter",
        .props = "{\"initial\":0}",
    }, inline_widget);

    const body = ctx.main_().children(.{
        ctx.h1("Islands marker"),
        ctx.p().children(.{
            tag(ctx, "Phase 8"),
            ctx.span().text("The widget below is wrapped in "),
            ctx.code("<verve-island>"),
            ctx.span().text(" with the component name + JSON-encoded props. Phase 8 will fetch a per-island WASM chunk and hydrate this subtree in place."),
        }),
        ctx.section().class("card").children(.{ wrapped }),
        ctx.p().class("muted").text("Inspect the DOM — the <verve-island data-name=… data-props=…> element wraps the inline SSR content. View source to see the data-* attrs."),
    }).build() catch unreachable;
    return page(ctx, body);
}

// ---- /sitemap.xml (fragment + contentType override) ------------------

pub fn sitemap(ctx: *verve.Context) !*verve.Node {
    const xml =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        \\  <url><loc>https://example.com/</loc></url>
        \\  <url><loc>https://example.com/work/hello-world</loc></url>
        \\  <url><loc>https://example.com/i18n/es</loc></url>
        \\</urlset>
    ;
    return ctx.raw(xml).contentType("application/xml").build();
}

// ---- notFound + errorPage (framework hooks) --------------------------

pub fn notFound(ctx: *const verve.Context, path: []const u8) !*verve.Node {
    return ctx.main_().class("home").children(.{
        ctx.h1("404 — Not Found"),
        ctx.p().children(.{
            ctx.span().text("No route for "),
            ctx.code(path),
        }),
        ctx.p().children(.{ ctx.a("/", "← Home") }),
    }).build();
}

pub fn errorPage(
    ctx: *const verve.Context,
    status_code: u16,
    status_text: []const u8,
    message: []const u8,
) !*verve.Node {
    return ctx.main_().class("home").children(.{
        ctx.el("h1").textFmt("{d} — {s}", .{ status_code, status_text }),
        ctx.p().text(message),
        ctx.p().children(.{ ctx.a("/", "← Home") }),
    }).build();
}
