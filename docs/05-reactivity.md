# 05 — Reactivity

Verve's reactive runtime mirrors the SolidJS / Leptos model: signals
are observable values, effects re-run whenever any signal they read
changes, and an Owner tree groups signals + effects so they're
disposed deterministically.

The same primitives ship in the WASM client — see
[12 — WASM client](12-wasm-client.md) for the runtime that hosts
the graph in the browser and [17 — Reconciler](17-reconciler.md)
for the keyed-list machinery `forEach` ties into.

## The core primitives

| Type | What it is |
|---|---|
| `verve.Owner`     | Scope. Disposes its child owners + cleanups in LIFO. |
| `verve.Signal(T)` | Reactive value cell. Reads inside an Effect subscribe. |
| `verve.Effect`    | Closure that re-runs when any tracked Signal changes. |
| `verve.Store(T)`  | Struct wrapper with per-field signals (field-grained). |
| `verve.Resource(T)` | Async-value wrapper: `.loading | .ready(T) | .err`. |
| `verve.ErrorBoundary` | Holds a `Signal(?anyerror)` — components catch + capture. |

The render pipeline allocates a fresh `Owner` per request. When the
response writer is done, the owner disposes — every signal/effect
created during render is freed, every `on_cleanup` hook fires.

## Signal

```zig
const sig = try ctx.useSignal(i32, 0);
const cur = sig.get();        // reactive read (subscribes effect)
const peek = sig.peek();      // non-tracking read
sig.set(7);                   // notify all subscribers, flush queue
sig.increment();              // shorthand for numeric T
```

`Signal(T)` uses thread-local `current_effect` tracking to record
subscribers automatically. There's no manual `.subscribe(fn)` — the
effect IS the subscription.

Writes batch automatically when nested under `verve.batch`:

```zig
verve.batch(ctx, struct {
    fn run(c: *verve.Context) void {
        c.useSignal(...) // ...
    }
}.run);
```

## Effect

```zig
_ = try ctx.useEffect(&state, struct {
    fn run(self: *State) void {
        log.info("count is now {d}", .{self.count.get()});
    }
}.run);
```

The effect runs eagerly once to collect its dependencies, then again
whenever any signal it read changes. Disposing the owner clears it
from every signal's subscriber list automatically.

### Escape hatches

`verve.untrack(R, ctx_ptr, fn)` runs the wrapped read without
subscribing the current effect — useful for "read once, don't react
to changes":

```zig
const initial = verve.untrack(i32, &count, struct {
    fn read(s: *verve.Signal(i32)) i32 {
        return s.peek();
    }
}.read);
```

`verve.batch(ctx_ptr, fn)` defers the effect flush until the closure
returns:

```zig
verve.batch(&store, struct {
    fn updateAll(s: *verve.Store(User)) void {
        s.set(.name, "alice");
        s.set(.age, 31);
    }
}.updateAll);
// → both writes happen, then any effect that reads .name OR .age
//   runs at most once.
```

## Store — field-grained reactivity

A bare `Signal(MyStruct)` notifies every reader on any field change.
`Store(T)` gives each field its own Signal so reads are granular:

```zig
const Profile = struct { name: []const u8, age: u32 };
const profile = try verve.createStore(Profile, owner,
    .{ .name = "alice", .age = 30 });

profile.get(.name);      // subscribes only to the .name signal
profile.set(.age, 31);   // notifies only .age subscribers
```

Implementation: a comptime `std.meta.Tuple` of signal pointers, one
per declared field. The lookup `get(.field)` resolves at comptime to
a tuple index.

## Resource — async data

```zig
const todos = try verve.createResource([]Todo, owner, &deps, fetcher);

switch (todos.state.get()) {
    .loading      => return ctx.span().text("Loading…"),
    .ready  => |list| return components.todoList(ctx, list),
    .err    => |e|    return components.errorPage(ctx, e),
}
```

Server-side the fetcher runs synchronously during render — Phase 3
ships SSR-resolved resources. Reads inside a `verve.suspense(...)`
boundary that see `.loading` mark the render suspended, and the
boundary's `fallback` is emitted instead. Phase 8's client runtime
will resolve resources asynchronously on hydrate.

## NodeRef — typed DOM handle

```zig
const ref = ctx.nodeRef(.input, "email-field");

return ctx.actionForm(.{ .post = "/api/subscribe" })
    .children(.{
        ctx.input().type_("email").ref(ref).required(),
        ctx.button("Subscribe").type_("submit"),
    }).build();
```

The renderer emits `data-ref="email-field"`. Client-side
`verveQueryRef("email-field")` returns the live `Element`. The
generic phantom `Tag` is enforced at compile time but doesn't make
it into the DOM.

## Error boundary

```zig
const eb = try verve.createErrorBoundary(owner);

const widget = renderRiskyWidget(ctx) catch |err| blk: {
    eb.captureError(err);
    break :blk ctx.div().class("widget-fallback").text("(unavailable)");
};

if (eb.captured()) |_| {
    // sibling subtrees keep rendering; a Try-Again button can call
    // eb.reset() to clear the captured state.
}
```

The boundary holds a `Signal(?anyerror)` so effects observing
`captured()` re-run when an error lands or is reset.

## Legacy z-bind / ClientSignal

The previous wire (`<span z-bind="count">` + JS bridge
`set_text_by_bind_i32`) still works for simple counter-style state
without spinning up the full reactive runtime. The `/counter` example
demonstrates it. New code should reach for `Signal` + `Effect`
instead; the JS-bridge path will retire once the WASM client gains
its own reactive runtime (Phase 8).

## SSE-driven binds (no wasm required)

The bridge also listens to `/events` named events:

```js
const es = new EventSource("/events");
es.addEventListener("count", (e) => {
  if (!ws || ws.readyState !== WebSocket.OPEN) setCount(e.data);
});
```

So even without invoking any wasm export, the page can have its
`[z-bind="count"]` elements updated when the server pushes
`event: count\ndata: <n>\n\n`.

This is how a tab open to `/counter` with JS but no WASM
interactions still sees live updates from other browsers.

## Putting it together — pure SSR with reactivity

The reactive runtime works server-side too: a render can create
signals and effects, mutate them inline (synchronously), and rely on
the final state for the HTML it emits. Useful for computed values
that need to be tracked across helper functions:

```zig
const tally = try ctx.useSignal(u32, 0);
const items = try fetchItems(ctx);
for (items) |it| tally.increment();

return ctx.main_().children(.{
    ctx.h1("Items"),
    ctx.p().textFmt("{d} total", .{tally.peek()}),
});
```

Phase 8 will let those same signals participate in client-side
hydration — same code, more behavior.

## Next

- [02 — Components](02-components.md) — head slots, NodeRef, Slot.
- [06 — Realtime](06-realtime.md) — SSE + WebSocket transports.
- [12 — WASM client](12-wasm-client.md) — growable heap, hydration.
