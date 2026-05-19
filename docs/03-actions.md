# 03 — Actions (Zerver)

An action is a server-side function the framework exposes as
`POST /api/<fn_name>`. No router config — Verve walks the `Actions`
struct at compile time and generates the dispatcher.

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
`api_handler.RequestMeta.fromRequest` — see
[`06-realtime.md`](06-realtime.md) for why header iteration must
precede body reads.

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

# Form
curl -X POST http://127.0.0.1:8080/api/addTodo \
  -H 'content-type: application/x-www-form-urlencoded' \
  -d 'text=buy+milk' \
  -H 'Referer: /todos'
# → 303 See Other, Location: /todos

# Value-returning action
curl -X POST http://127.0.0.1:8080/api/getCount \
  -H 'content-type: application/json' -d '{}'
# → {"value":7}
```

The wasm client invokes JSON actions via the `post_json_i32` extern
declared in `src/client/dom.zig`. See [`05-reactivity.md`](05-reactivity.md).

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

## A no-state action

Actions that take no input parameters use the empty struct:

```zig
pub fn ping(_: struct {}) []const u8 {
    return "pong";
}
```

Form mode: `POST /api/ping` with an empty body → 303 to Referer.
JSON mode: `POST /api/ping` with `{}` → `{"value":"pong"}`.

## Reading raw headers in an action

The dispatcher pre-parses `Content-Type`, `Referer`, and
`Accept-Encoding` into a `RequestMeta` struct, but the action itself
doesn't get the request handle. If you need other headers (e.g.
`Authorization`), the cleanest path right now is to extend
`RequestMeta` in `src/server/api_handler.zig:20-40` and add the field
you need.

(See [`11-deployment.md`](11-deployment.md) for why this layer is
strict about header iteration order.)

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
in `src/server/main.zig:706-710`. Adding a `pub fn` to `Actions`
automatically registers it — no other config required.

## Next

- [04 — Routing](04-routing.md) — page route table + how the action
  dispatcher hangs off the same `app` module.
- [05 — Reactivity](05-reactivity.md) — wiring actions to wasm signals.
