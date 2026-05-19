# 04 — Routing

Two route tables, both walked at compile time:

1. **Page routes** — `app.routes`, a `[]const Route` of static paths.
2. **API routes** — derived from `app.Actions` declarations,
   exposed at `POST /api/<fn_name>`.

Plus a handful of framework-owned endpoints that every app gets for
free: `/health`, `/metrics`, `/events`, `/ws`, `/client.wasm`,
`/verve.js`, `/public/*`.

## Page routes

```zig
// src/app/routes.zig
pub const Route = struct {
    path: []const u8,
    render: *const fn (ctx: *const verve.Context) anyerror!verve.Node,
};

pub const routes: []const Route = &.{
    .{ .path = "/",         .render = renderHome },
    .{ .path = "/counter",  .render = renderCounter },
    .{ .path = "/todos",    .render = renderTodos },
};
```

The matcher is exact-string:

```zig
// src/server/router.zig
pub fn match(path: []const u8) ?app.Route {
    for (app.routes) |r| {
        if (std.mem.eql(u8, r.path, path)) return r;
    }
    return null;
}
```

No prefix matching, no path parameters. Trailing slashes are literal:
`/counter` and `/counter/` are different routes. Pick one and stick to
it.

If the matcher misses, the framework renders the 404 page via
`components.notFound(ctx, path)` so app code can include the requested
path in the error template.

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

The framework strips query strings before route matching:

```zig
// src/server/main.zig
fn pathOf(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |q| return target[0..q];
    return target;
}
```

So `/search?q=foo` matches the route `/search`. The full target
(including the query string) is still visible if you read
`request.head.target` directly inside a handler — but render functions
only get the `Context`, not the request. Add a field to `RequestMeta`
if your action needs the raw query.

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

## Framework-owned routes

These are always present, regardless of what `app.routes` declares:

| Method | Path | Handler in `src/server/main.zig` |
|---|---|---|
| GET    | `/health`           | `respondHealth` |
| GET    | `/metrics`          | `respondMetrics` |
| GET    | `/events`           | `streamEvents` (SSE) |
| GET    | `/ws`               | `streamWebSocket` |
| GET    | `/client.wasm`      | embedded asset |
| GET    | `/verve.js`         | embedded asset |
| GET    | `/public/<rel>`     | `serveStatic` (embed + disk overlay) |

If an app declares a colliding page route — say
`.{ .path = "/health", .render = ... }` — the framework's branch wins
because it's checked first in `handleRequest`. Pick a different path.

## Adding a route, end-to-end

```zig
// 1. src/app/routes.zig — add the entry
pub const routes: []const Route = &.{
    // ...
    .{ .path = "/about", .render = renderAbout },
};

fn renderAbout(ctx: *const verve.Context) !verve.Node {
    return components.page(ctx, .{ .tag = "h1", .text = "About" });
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

## When the static table isn't enough

If you need path parameters (`/user/<id>`) or prefix matches
(`/blog/<slug>`), today you have to either:

- Generate the route table at comptime (works for finite sets known
  at build time).
- Add a "catch-all" branch in `src/server/main.zig:handleRequest` that
  runs before the router for a known prefix and parses out the
  parameter manually.

The current `router.zig` is intentionally small. Extending it to
support patterns is a one-evening change if you need it — let the
maintainer know what shape you'd want.

## Next

- [05 — Reactivity](05-reactivity.md) — `z-bind` + signals so a single
  page can update without a full route swap.
- [06 — Realtime](06-realtime.md) — `/events` and `/ws` for push.
