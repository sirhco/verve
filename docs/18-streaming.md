# 18 — Streaming SSR

Out-of-order Suspense streaming. The server flushes the page
shell as soon as it's ready, parks any boundary that calls
`markSuspended`, then streams `<template>` chunks for each
parked boundary as their upstream resolves. The client unwraps
each template in place of its placeholder via the
`window.verveSwap(id)` helper.

## Wire format

For every Suspense boundary that marks itself suspended during
the initial render, the server emits a placeholder inline:

```html
<div data-vs="0">
  <!-- fallback HTML -->
</div>
```

After the main body, the server drains the parked-slot registry
and emits one swap chunk per slot:

```html
<template id="verve-vs-0">
  <!-- real content -->
</template>
<script nonce="…">verveSwap(0)</script>
```

`verveSwap(id)` finds the matching `[data-vs="<id>"]` placeholder,
clones the template's content, and `replaceWith`s. Reactive
state on surrounding nodes survives — the swap only touches the
placeholder element. The bridge then calls `verve_hydrate` once
so any new `data-vh` markers brought in by the swap are picked
up by the reactive runtime.

## API

### Server-side

```zig
const reg = verve.StreamRegistry.init(ctx.alloc());
defer reg.deinit();

// Build the tree under the active registry — suspense() reads
// the threadlocal during render and parks continuations onto
// `reg` instead of emitting fallback inline.
const root = try verve.withStreamRegistry(&reg, ctx, buildPage);

// Walk + drain. `streamRender` flushes the shell first then
// emits each `<template>` + `verveSwap()` chunk in registration
// order.
try verve.Renderer.streamRender(writer, root, &reg);
```

`withStreamRegistry(reg, ctx_ptr, f)` is the safe activator: it
sets the thread-local for the duration of `f` and restores the
previous pointer on return. Use it instead of writing to
`stream_context.current` directly.

### Suspense behavior

```zig
return try verve.suspense(ctx, .{ .fallback = fallback }, &state, render_child);
```

- If `render_child` returns successfully and no descendant called
  `markSuspended()`, the child renders inline.
- If `markSuspended()` was called and **no** stream registry is
  active, the fallback renders inline (legacy single-shot mode).
- If `markSuspended()` was called and a stream registry **is**
  active, the boundary registers `render_child` as a continuation,
  reserves a slot id, and emits
  `<div data-vs="<id>">{fallback}</div>` in place of the child.

After the main render, `streamRender` calls each parked slot's
continuation a second time — by that point the upstream that
triggered `markSuspended` is meant to have resolved (async
Resource integration arrives with Phase 14C).

## Async caveat

Today's Resource fetcher is synchronous. The streaming wire
format works end-to-end but a parked boundary's continuation
runs synchronously in the drain loop — the practical benefit
right now is **shell-first delivery** (faster TTFB / FCP for
pages that have above-the-fold content + below-the-fold blocks
that take a few extra ms to compute).

Truly out-of-order delivery, where chunk N can race chunk N+1
on the wire, lands when `ctx.fetch` migrates to `std.Io.async`.
The wire format won't change — the wiring inside
`StreamRegistry.pending()` will.

## CSP nonces

`streamRender` reads `renderer.current_nonce` and stamps it on
every emitted `<script>verveSwap(N)</script>` tag. Set the nonce
before the request handler runs and strict-dynamic CSP keeps
working:

```zig
verve.setRendererNonce(per_request_nonce);
defer verve.setRendererNonce("");
```

When the threadlocal is empty the swap script is emitted
without a nonce attribute — fine for development, fails CSP in
production if a script-src policy is enforced.

## Wiring a route

The server's stock response path uses `Renderer.render` for a
single-shot HTML body. Streaming routes need the chunked path —
`request.respondStreaming(...)` + `streamRender`:

```zig
fn streamingHandler(io: std.Io, request: *http.Server.Request, ctx: *verve.Context) !void {
    var resp = try request.respondStreaming(.{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            .{ .name = "x-accel-buffering", .value = "no" },
        },
    });
    var reg = verve.StreamRegistry.init(ctx.alloc());
    defer reg.deinit();

    const root = try verve.withStreamRegistry(&reg, ctx, renderPage);
    try verve.Renderer.streamRender(&resp.writer, root, &reg);
    try resp.end();
}
```

The route doesn't have to opt in upfront — any route that may
have suspended children benefits from the chunked path. Routes
with no Suspense boundaries pay no cost: the registry stays
empty, `streamRender` produces the same output as `render`
would.

## Verification

`zig build test` covers:

- Suspense without a registry emits the legacy inline fallback
  (compatibility).
- Suspense under an active registry emits the
  `<div data-vs="0">` placeholder + registers a continuation.
- `streamRender` produces the placeholder, a matching
  `<template id="verve-vs-0">{real content}</template>`, and a
  `verveSwap(0)` script tag.
- Drain order matches registration order.

## Next

- [05 — Reactivity](05-reactivity.md) — Resource + Suspense
  primitives.
- [02 — Components](02-components.md) — `markSuspended` is the
  bridge between component-level fetching and the streaming
  wire.
- [11 — Deployment](11-deployment.md) — CSP nonce wiring and
  reverse-proxy buffering settings (`x-accel-buffering: no`).
