# 04 — Routing

Two route tables, both walked at compile time:

1. **Page routes** — `app.routes`, a `[]const verve.Route` built via
   `Route.init` (leaf) / `Route.layout` (with nested children).
2. **API routes** — derived from `app.Actions` declarations,
   exposed at `POST /api/<fn_name>`.

Plus a handful of framework-owned endpoints that every app gets for
free: `/health`, `/metrics`, `/events`, `/ws`, `/client.wasm`,
`/verve.js`, `/public/*`. With `--dev`, also `/__verve/dev_ws`.

## Page routes

```zig
// src/app/routes.zig
const verve = @import("verve");

pub const routes: []const verve.Route = &.{
    verve.Route.init("/",                renderHome),
    verve.Route.init("/counter",         renderCounter),
    verve.Route.init("/work/:slug",      renderWorkDetail),
    verve.Route.init("/files/*rest",     renderFile),
    verve.Route.layout("/app",           renderAppShell, &.{
        verve.Route.init("/dashboard",         renderDashboard),
        verve.Route.init("/settings/:section", renderSettings),
    }),
    verve.Route.init("/private", renderPrivate).protect(authGuard),
};
```

A pattern is slash-delimited with three kinds of segment:

| Form | Match | Captured |
|---|---|---|
| `/work`     | literal | nothing |
| `/work/:slug` | parameter | `ctx.param("slug")` |
| `/files/*rest` | greedy wildcard (must be last) | `ctx.param("rest")` |

Patterns are parsed at comptime via `verve.Route.init`, so invalid
forms (`:` with no name, `*rest` followed by another segment) fail
the build. The runtime matcher walks the parsed `Segment` slice; per
request the captured values land in `ctx.params` for the renderer to
read.

### Reading params

```zig
fn renderWorkDetail(ctx: *verve.Context) !*verve.Node {
    const slug = ctx.param("slug") orelse "";
    return components.workDetail(ctx, slug);
}
```

`ctx.param("name")` returns `?[]const u8`. The slice references bytes
inside the request path buffer — valid for the lifetime of the
render.

### Path matching rules

- Trailing slashes are normalized away. `/work/list` and `/work/list/`
  match the same route.
- The matcher prefers the route appearing earlier in the table when
  multiple match. Put more specific patterns before more general ones:
  `/work/list` before `/work/:slug`.
- Wildcards capture the entire remainder, including embedded `/`. A
  trailing `/` is trimmed: `/files/a/b/c/` → `rest = "a/b/c"`.

## Nested routes (layouts + outlets)

`Route.layout(pattern, render, children)` declares a layout that owns
nested children. The layout's render must call `ctx.outlet()`
somewhere in its tree — that's the slot where the matched child's
HTML lands.

```zig
verve.Route.layout("/app", renderAppShell, &.{
    verve.Route.init("/dashboard",         renderDashboard),
    verve.Route.init("/settings/:section", renderSettings),
});

fn renderAppShell(ctx: *verve.Context) !*verve.Node {
    return ctx.main_().class("app").children(.{
        ctx.nav().children(.{
            verve.link(ctx, "/app/dashboard",         "Dashboard", .{}),
            verve.link(ctx, "/app/settings/general",  "Settings",  .{}),
        }),
        ctx.el("section").children(.{ ctx.outlet() }),
    }).build();
}
```

For `/app/dashboard` the server matches the chain `[app, dashboard]`,
renders `renderDashboard` first, then runs `renderAppShell` with
`ctx.outlet_node` pointing at the dashboard's tree. The
`__outlet__` placeholder node the layout emits is expanded at
serialization time.

Nesting depth is capped at `MAX_DEPTH = 8` in `src/server/router.zig`.

## Redirects

A render (or guard) returns `ctx.redirect("/login")` to short-circuit
to a 303 See Other:

```zig
fn renderInbox(ctx: *verve.Context) !*verve.Node {
    if (ctx.request_meta) |m| if (m.cookie("session") == null) {
        return ctx.redirect("/login");
    };
    // … render normally
}
```

`ctx.redirectWithStatus(href, 302)` picks a different status code (301
for permanent moves, 307/308 for method-preserving redirects).
Redirect sentinels are detected by the server before serialization;
no HTML is emitted.

## Route guards (ProtectedRoute)

A route can be protected with a guard function that runs **before**
the render. The guard receives the same `*Context` the render would;
returning a `Redirect` short-circuits, returning null lets the render
proceed.

```zig
verve.Route.init("/private", renderPrivate).protect(authGuard),

fn authGuard(ctx: *verve.Context) ?verve.Redirect {
    const meta = ctx.request_meta orelse return .{ .to = "/login" };
    if (meta.cookie("session") == null) return .{ .to = "/login" };
    return null;
}
```

Guards run root-first through the route chain: a layout's guard
fires before a child's. The first guard that returns a Redirect wins.

## Method gating

Page routes accept only `GET` and `HEAD`. Other methods get a 405 via
the framework's `errorPage` template:

```
GET    /todos    → 200 (page renders)
POST   /todos    → 405 ("This page only accepts GET requests.")
```

If you want a path to accept both pages and POST actions, give the
action a different URL (e.g. `/todos` for the page and
`/api/addTodo` for the mutation).

## URL components

Query string and fragment are stripped before route matching:

```zig
// src/server/main.zig
fn pathOf(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |q| return target[0..q];
    return target;
}
```

So `/search?q=foo` matches the route `/search`. The render reads the
query through `ctx.location`:

```zig
fn renderSearch(ctx: *verve.Context) !*verve.Node {
    const loc = ctx.location.?;
    const q = try loc.queryGet(ctx.alloc(), "q") orelse "";
    // …
}
```

`ctx.location` is `?*verve.Location { path, raw_query, fragment }`;
`queryGet(arena, key)` lazily parses the raw query string with
percent-decoding into the request arena.

## SPA navigation

`verve.link(ctx, href, label, opts)` emits an anchor tagged with
`data-vlink="1"` that the client router intercepts. On click the
browser stays on the page — `verve.js` fetches the new URL, parses
the response, merges the `<head>` (title + meta + canonical link),
and swaps the body content. `history.pushState` keeps the back/forward
buttons working.

```zig
verve.link(ctx, "/about",  "About",       .{}),
verve.link(ctx, "/work",   "Work",        .{ .prefetch_on_hover = true }),
verve.link(ctx, "/contact","Contact",     .{ .class = "nav-link" }),
```

Links with `target="_blank"`, modified clicks (cmd/ctrl/shift), or
non-same-origin hrefs fall through to native anchor behavior.

See [16 — SPA router](16-spa-router.md) for the full client wire.

## API routes

There's no `apiRoutes` table — the dispatcher walks `Actions`:

```zig
// src/server/api_handler.zig
inline for (comptime std.meta.declarations(Actions)) |decl| {
    if (std.mem.eql(u8, decl.name, fn_name)) {
        try invoke(gpa, request, @field(Actions, decl.name), body, ...);
        return;
    }
}
```

So:

```zig
pub const Actions = struct {
    pub fn createUser(args: ...) ...
};
```

Automatically lands at `POST /api/createUser`. No registration step.
Form posts must include the framework's CSRF field (see
[13 — Security](13-security.md)).

From server-side render code, call the same fn directly via
`ctx.serverFn(app.Actions.createUser, args)` to skip the HTTP
roundtrip.

## Framework-owned routes

These are always present, regardless of what `app.routes` declares:

| Method | Path | Handler in `src/server/main.zig` |
|---|---|---|
| GET    | `/health`              | `respondHealth` |
| GET    | `/metrics`             | `respondMetrics` |
| GET    | `/events`              | `streamEvents` (SSE) |
| GET    | `/ws`                  | `streamWebSocket` |
| GET    | `/client.wasm`         | embedded asset |
| GET    | `/verve.js`            | embedded asset |
| GET    | `/public/<rel>`        | `serveStatic` (hashed + embed + LRU disk) |
| GET    | `/__verve/dev_ws`      | dev reload WS (only with `--dev`) |

If an app declares a colliding page route — say
`.{ .pattern = "/health", … }` — the framework's branch wins
because it's checked first in `handleRequest`. Pick a different path.

## Adding a route, end-to-end

```zig
// 1. src/app/routes.zig — add the entry
pub const routes: []const verve.Route = &.{
    // ...
    verve.Route.init("/about", renderAbout),
};

fn renderAbout(ctx: *verve.Context) !*verve.Node {
    try ctx.setTitle("About — Verve");
    return components.page(ctx, ctx.h1("About"));
}
```

Rebuild — done. The route shows up in the startup banner:

```
info(verve): pages:
  GET  /
  GET  /counter
  GET  /todos
  GET  /about    ← new
```

## Next

- [05 — Reactivity](05-reactivity.md) — Owner/Signal/Effect/Store and
  how pages stay updated without a full route swap.
- [13 — Security](13-security.md) — CSRF tokens + CSP nonce.
- [16 — SPA router](16-spa-router.md) — client-side navigation wire.
