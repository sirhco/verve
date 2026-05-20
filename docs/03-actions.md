# 03 — Actions / Server Functions

An action (Verve's name for a server function) is a server-side fn
the framework exposes as `POST /api/<fn_name>`. No router config —
Verve walks the `Actions` struct at compile time and generates the
dispatcher.

## The convention

```zig
pub const Actions = struct {
    pub fn updateDatabase(args: struct { new_count: i32 }) !void {
        // ...
    }

    pub fn getCount(_: struct {}) !i32 {
        return last_count.load(.monotonic);
    }

    pub fn addTodo(args: struct { text: []const u8 }) !void {
        if (args.text.len == 0) return error.EmptyTodo;
        // ...
    }
};
```

Every action is `pub fn name(args: struct { ... }) Ret`. The single
struct argument is required — the dispatcher reads field names off the
struct's `@typeInfo` at comptime because parameter names aren't
available there.

## Three call paths

The same action surfaces three ways:

1. **POST /api/&lt;name&gt;** — native HTTP endpoint. Form posts and JSON
   posts both work; see [Dual-mode dispatch](#dual-mode-dispatch).
2. **`ctx.serverFn(app.Actions.foo, args)`** — direct invocation from
   server-side render code. Skips the HTTP/JSON roundtrip; returns
   the function's real return type.
3. **`window.verveServerFn("foo", args)`** — JavaScript wrapper that
   POSTs the same endpoint. WASM islands (Phase 8) will get typed
   stubs on top of this generic helper.

## Return types

| Signature | Behaviour |
|---|---|
| `fn(args) void`        | Returns `{"ok":true}` (JSON) or 303 (form) on success. |
| `fn(args) !void`       | Errors → 500 `internal error`. Otherwise same as above. |
| `fn(args) T`           | Returns `{"value":<T>}` (JSON) or 303 (form). |
| `fn(args) !T`          | Errors → 500. Otherwise as above. |

`T` is serialized via `std.json.Stringify.value`. Primitives, slices,
structs all work; opt out by wrapping in your own type if the default
shape isn't right.

## Dual-mode dispatch

The dispatcher inspects `Content-Type` to decide how to parse the body:

- **`application/json`** → `std.json.parseFromSlice` into the args
  struct. Returns JSON on success.
- **`application/x-www-form-urlencoded`** → URL-decoded key=value
  pairs assigned by field name. Returns **303 See Other** to
  `Referer` (or `/` if missing) so a native `<form>` submit lands the
  user back on a sensible page.

The detection happens once, before the body is read, via
`verve.RequestMeta.fromRequest` — see
[`06-realtime.md`](06-realtime.md) for why header iteration must
precede body reads.

## CSRF on form POSTs

Form-encoded POSTs to `/api/<fn>` are CSRF-protected by default. The
server expects:

- A `__verve_csrf=<token>` cookie (auto-issued on the first GET that
  renders a page).
- A `__csrf=<same-token>` field inside the form body.

Render code adds the hidden field with the helper:

```zig
ctx.actionForm(.{ .post = "/api/addTodo", .class = "todo-form" })
    .children(.{
        ctx.input().name("text").type_("text").required(),
        ctx.button("Add").type_("submit"),
    })
```

`actionForm` is `form` + an injected `<input type=hidden
name=__csrf value=…>`. The standalone `ctx.csrfField()` helper is
available if you need to embed the field in a hand-built form.

JSON posts skip the form-CSRF check because they're already
same-origin-only thanks to `SameSite=Strict` on the cookie. The full
threat model lives in [`13-security.md`](13-security.md).

Disable enforcement during integration tests via
`verve-server --csrf=disable`.

## Form body parsing details

Only two field types are supported today:

- `[]const u8` — taken verbatim after URL-decoding
- any integer type (`i32`, `u32`, `usize`, ...) — `std.fmt.parseInt`

Adding a field type means editing `coerce` in
`src/server/api_handler.zig`. Booleans, floats, enums are a one-line
extension when you need them.

Default values declared on the struct survive the parse:

```zig
pub fn search(args: struct {
    q: []const u8,
    limit: usize = 20,    // ← supplied when the form doesn't include `limit`
}) !void { ... }
```

## Calling actions from JS / curl

```sh
# JSON
curl -X POST http://127.0.0.1:8080/api/updateDatabase \
  -H 'content-type: application/json' \
  -d '{"new_count":42}'
# → {"ok":true}

# Form — requires CSRF cookie + field
COOKIE_JAR=$(mktemp)
TOKEN=$(curl -s -c "$COOKIE_JAR" http://127.0.0.1:8080/counter \
  | grep -o 'name="__csrf" value="[^"]*"' \
  | sed 's/.*value="\([^"]*\)".*/\1/')
curl -X POST -b "$COOKIE_JAR" http://127.0.0.1:8080/api/addTodo \
  -H 'content-type: application/x-www-form-urlencoded' \
  -d "__csrf=$TOKEN&text=buy+milk" \
  -H 'Referer: /todos'
# → 303 See Other, Location: /todos

# Value-returning action
curl -X POST http://127.0.0.1:8080/api/getCount \
  -H 'content-type: application/json' -d '{}'
# → {"value":7}
```

The JS bridge invokes JSON actions via `window.verveServerFn(name,
args)`:

```js
const todos = await window.verveServerFn("listTodos", { limit: 20 });
```

The wrapper auto-decodes the `{ value: … }` / `{ ok: true }`
envelope and returns the bare payload.

## Calling from render code

When you're already on the server, the HTTP roundtrip is pure
overhead — call the function directly:

```zig
fn renderTodos(ctx: *verve.Context) !*verve.Node {
    const items = ctx.serverFn(app.Actions.listTodos, .{ .limit = 20 });
    return components.todoList(ctx, items);
}
```

`ctx.serverFn` returns the function's actual return type, so this
composes naturally with `try` for error-returning actions.

## Error handling

Returning a Zig error becomes a 500 with the body `internal error`.
The framework's standard error page is rendered for the user. You can
distinguish error types with named errors:

```zig
pub fn doThing(args: struct { id: usize }) !void {
    if (args.id == 0) return error.MissingId;
    if (args.id > MAX) return error.OutOfRange;
}
```

The error name lands in the framework log (`info(verve): action error:
MissingId`) so you can grep production logs. For richer client-side
error display, return a value-bearing struct with an `ok` discriminator
instead of using Zig errors:

```zig
pub const Result = union(enum) { ok, error_id: []const u8 };

pub fn doThing(args: struct { id: usize }) Result {
    if (args.id == 0) return .{ .error_id = "missing-id" };
    return .ok;
}
```

The matching `verve.ErrorBoundary` pattern lets the render-side catch
+ display these without bubbling to the framework's 500 page; see
[`05-reactivity.md`](05-reactivity.md).

## A no-state action

Actions that take no input parameters use the empty struct:

```zig
pub fn ping(_: struct {}) []const u8 {
    return "pong";
}
```

Form mode: `POST /api/ping` with an empty body (plus CSRF) → 303 to
Referer. JSON mode: `POST /api/ping` with `{}` → `{"value":"pong"}`.

## Reading raw headers in an action

The dispatcher pre-parses headers into `verve.RequestMeta` and the
action itself can read it via the dispatch's `meta` arg. Cookies,
Accept-Language, User-Agent, Origin, and the raw Cookie header are
all available. If you need a header that's not currently broken out,
add the field to `src/core/request_meta.zig` and parse it in
`fromRequest`.

## Discovering registered actions

At startup the framework prints every action it found:

```
info(verve): actions:
  POST /api/updateDatabase
  POST /api/logMessage
  POST /api/getCount
  POST /api/addTodo
  POST /api/removeTodo
```

The walk happens via `inline for (comptime std.meta.declarations(app.Actions))`
in `src/server/main.zig`. Adding a `pub fn` to `Actions` automatically
registers it — no other config required.

## Next

- [04 — Routing](04-routing.md) — page route table + path params.
- [05 — Reactivity](05-reactivity.md) — wiring actions to signals + effects.
- [13 — Security](13-security.md) — CSRF + CSP + Origin pinning.
