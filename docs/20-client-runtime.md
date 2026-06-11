# Client runtime

Primitives a frontend/desktop app needs on the wasm side so application
logic lives in Zig instead of a hand-written inline `<script>` blob:
typed IPC replies, events with data, timers, storage, clipboard, forms,
DOM measurement, and a generic JS-interop escape hatch.

This is the **client/web runtime** track. It is distinct from
[19 — Desktop apps](19-desktop.md) (native shell: window, tray, IPC
transport, multi-window) and from `11-desktop-roadmap.md` (shell
roadmap). Features here ship in phases; each is independently usable.

## Phase 1 — Typed IPC replies (shipped)

Server functions already POST from wasm and fan the reply back to a
registered handler as raw bytes (see [15 — Islands](15-islands.md),
`registerResponseHandler`). Phase 1 removes the hand-rolled JSON scanner
each chunk used to crack those bytes open.

### Shared JSON service

The parser lives **once** in the main `client.wasm`
(`src/client/json_service.zig`, backed by `std.json`). Chunks reach it
through `verve_json_*` accessor externs against a numeric handle — so a
chunk never links its own parser and stays small (the demo
`JsonProbe` chunk is ~3.2 KB).

```zig
// inside a chunk's response handler — `bytes` is the reply body
const doc = verve.parseJson(bytes) orelse return;
defer doc.free();

// accessor style — zero chunk allocation
if (doc.get("count")) |c| verve.signalSetI32("count", @intCast(c.int()));
if (doc.get("items")) |items| {
    var i: u32 = 0;
    while (i < items.len()) : (i += 1) {
        const row = items.at(i).?;
        var buf: [128]u8 = undefined;
        const id = row.get("id").?.str(&buf);
        _ = id;
    }
}
```

`JsonDoc` accessors: `get(key)`, `at(index)`, `len()`, `kind()`,
`int()`, `float()`, `boolean()`, `str(buf)`, `strLen()`, `free()`.
Child handles from `get`/`at` are non-owning views into the root's
parse tree — free the root last.

### Typed `readStruct`

For a whole reply, declare the shape and read it in one call. Scalars
read directly; `[]const u8` and slice fields allocate from the passed
allocator; nested structs and optionals recurse.

```zig
const Reply = struct { count: i32, title: []const u8, pinned: bool };

fn onReply(ptr: [*]const u8, len: u32) void {
    const doc = verve.parseJson(ptr[0..len]) orelse return;
    defer doc.free();
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const reply = verve.readStruct(Reply, doc, fba.allocator()) catch return;
    verve.signalSetI32("count", reply.count);
}
```

The allocator is per-dispatch (a `FixedBufferAllocator` over chunk
scratch today; `chunkArena()` in a later phase).

### Request → reply loop

```zig
export fn hydrate(_: u32, _: u32, _: u32) void {
    verve.registerResponseHandler("notes_list", onReply);
}
export fn refresh() void {
    verve.serverFnPost("notes_list", "{}"); // POST /api/notes_list
}
```

`serverFnPost` is the chunk-callable outbound POST (the JS-bridge
`server_fn_post` re-exported through the `verve_runtime` namespace).

See `src/client/islands/JsonProbe.zig` for a complete example.

### Server-side `<name>_call`

The codegen (`tools/server_fn_codegen.zig`) also emits a callback-style
typed entry per action alongside `<name>` / `<name>_post`:

```zig
app_client.foo_call(arena, args, struct {
    fn onReply(result: FooResult) void { /* ... */ }
}.onReply);
```

On native this runs synchronously and skips the callback on error. See
[03 — Actions](03-actions.md).

## Phase 2 — Events with data (shipped)

Closure event handlers used to receive only a slot id. Now the bridge
stages the dispatching event's data before invoking the handler, and the
handler reads it through accessors. Works from chunks (the data is held
in the main client; chunks reach it via `verve_runtime`).

```zig
// registered via registerEvent + a `z-on-keydown-id` stamp
fn onKeydown() void {
    const mods = verve.eventMods(); // .meta .ctrl .shift .alt
    var buf: [16]u8 = undefined;
    const key = verve.eventKey(&buf); // "k", "Enter", "ArrowDown", …
    if ((mods.meta or mods.ctrl) and key.len == 1 and key[0] == 'k') {
        verve.eventPreventDefault();
        openPalette();
    }
}

// delegated row click — read the row's data-* without a per-row handler
fn onRowClick() void {
    var buf: [64]u8 = undefined;
    const id = verve.eventTargetAttr("id", &buf); // data-id (camelCased like JS dataset)
    selectRow(id);
}
```

Accessors (valid only inside a handler): `eventMods() Mods`,
`eventKey(buf)`, `eventCoordX()` / `eventCoordY()`,
`eventTargetAttr(name, buf)`, `eventPreventDefault()`,
`eventStopPropagation()`. The target attribute reads the `dataset` of the
element the handler was stamped on, parsed once through the shared JSON
service. See `src/client/islands/JsonProbe.zig`.

## Phase 3 — Timers, storage, clipboard (shipped)

Pure browser capabilities, wired into the chunk import object. Timer
handlers are `*const fn () void` (same shared-table ABI as
`registerEvent`); each scheduling call returns a cancel id.

```zig
const id = verve.setTimeout(250, &onTick);   // also setInterval / requestAnimationFrame
verve.clearTimer(id);
verve.queueMicrotask(&deferred);

verve.storage.set("theme", "dark");
var buf: [32]u8 = undefined;
const theme = verve.storage.get("theme", &buf); // "" when absent; storage.len() probes size
verve.storage.remove("theme");

verve.clipboardWrite("copied!"); // async, with execCommand fallback
```

## Phase 4 — Forms & DOM measurement (shipped)

Ref ops take a `queryRef` handle. `formCollect` serializes a form's
named fields to JSON for the shared parser to read back.

```zig
const h = verve.queryRef(field_id).?;
var buf: [128]u8 = undefined;
const value = verve.refValueStr(h, &buf); // string .value (numeric: refValueI32/F32)
verve.refSelect(h);
verve.refRequestSubmit(h);               // el.form.requestSubmit() — fires validation
const r = verve.refRect(h);              // .x .y .w .h (getBoundingClientRect)
const vp = verve.viewport();             // .w .h (innerWidth/Height)
if (verve.matchMedia("(prefers-color-scheme: dark)")) applyDark();

// whole-form → typed struct, via the shared JSON service
var jbuf: [512]u8 = undefined;
const json = verve.formCollect("note-form", &jbuf);
const doc = verve.parseJson(json).?;
defer doc.free();
const form = try verve.readStruct(NoteForm, doc, gpa);
```

Accessors: `refValueStr`, `refAttrLen` / `refGetAttr` /
`refGetAttrArena` (read any live attribute; the arena variant
probes-then-copies at exact size — feeds `verve.anim`
morph-from-current), `refRequestSubmit`, `refSelect`, `refBlur`,
`refScrollIntoView`, `refRect() Rect`, `viewport() Viewport`,
`matchMedia(query)`, `formCollect(bind, buf)`.

## Phase 5 — Generic JS interop (shipped)

The escape hatch for browser APIs verve doesn't type natively (Intl
date/number formatting, markdown, syntax highlight, canvas). The app
registers JS functions; the chunk calls them by name with a JSON arg
payload and reads a JSON result.

```js
// app boot
window.verveHost.fmtDate = (a) => new Date(a.ms).toLocaleString();
window.verveHost.renderMd = (a) => window.marked.parse(a.text); // returns a Promise → use hostAsync
```

```zig
// sync — host fn returns a value
var out: [256]u8 = undefined;
const json = verve.host("fmtDate", "{\"ms\":1700000000000}", &out);
const doc = verve.parseJson(json).?;
defer doc.free();

// async — host fn returns a Promise; result fans back to a response handler
verve.registerResponseHandler("md_done", onMarkdown);
verve.hostAsync("renderMd", "{\"text\":\"# hi\"}", "md_done");
```

Canvas, markdown, and Intl are intentionally interop — not bespoke
upstream surface.

## Phase 6 — Chunk arena + drag-drop (shipped)

Chunks had no allocator, so they pre-sized worst-case static buffers.
`chunkArena()` is a real `std.mem.Allocator` over a bump region in the
main client; mark/reset recycles it per dispatch.

```zig
const m = verve.chunkArenaMark();
defer verve.chunkArenaReset(m);
const reply = try verve.readStruct(Reply, doc, verve.chunkArena());
```

Drag-drop writes the dropped file's bytes straight into the arena and
fires a handler:

```zig
verve.registerDrop("drop-zone", &onDrop);
fn onDrop() void {
    var name_buf: [256]u8 = undefined;
    const f = verve.currentDrop(&name_buf); // f.name, f.bytes (arena-backed)
    importFile(f.name, f.bytes);
}
```

## Phase 7 — Server push, pointer capture, named-export loops (shipped)

Three additions that came out of the interactive-viz work, all reusable by
any island.

**Server push to a named export.** Subscribe a chunk export to a server push
channel (see the `/push` hub in [06 — Realtime](06-realtime.md)): every SSE
frame is staged in the island scratch buffer and delivered to
`export fn <name>(ptr: u32, len: u32) void` — payload valid only for the
call. `fetchToExport` is the matching one-shot POST→export, typically used to
fetch a fresh snapshot when a stream gap is detected.

```zig
// returns false when the host has no EventSource — fall back to polling
_ = verve.pushSubscribe("prices", "Ticker", "apply_frame");
verve.pushUnsubscribe("prices", "Ticker");
verve.fetchToExport("priceSnapshot", "Ticker", "apply_snapshot");
```

Both are host-call based: the handler is reached **by export name**, so the
chunk takes no function pointer.

**Pointer capture + the extended event set.** A pointer handler that calls
`eventCapturePointer()` gets the pointer captured to its element after it
returns — the gesture keeps receiving `pointermove` / `pointerup` after the
pointer leaves the element (released implicitly on pointerup). The delegated
event set covers `wheel`, `pointerdown/move/up/over/out/cancel`, and
`dblclick`, each with a fluent stamp (`Node.onWheel`, `onPointer*`,
`onPointerCancel`, `onDblClick`) and data accessors (`eventDeltaY()`,
`eventButton()`). End gestures on `pointerup` / `pointercancel` — not
`pointerout`, which still fires on child-element crossings.

```zig
export fn grab_start() void {
    dragging = true;
    verve.eventCapturePointer(); // drag survives leaving the element
}
```

**Named-export animation loop.** The `verveRafNamed` host fn runs a JS
`requestAnimationFrame` loop against a named chunk export returning `i32` —
nonzero continues, zero stops; one loop per island|export key, `{"on":0}`
cancels. Chunk animation with zero indirect-function-table entries (compare
`requestAnimationFrame(&tick)`, which takes a pointer).

```zig
var out: [16]u8 = undefined;
_ = verve.host("verveRafNamed", "{\"island\":\"Ticker\",\"export\":\"tick\",\"on\":1}", &out);

export fn tick() i32 {
    step();
    return if (done()) 0 else 1;
}
```

Chunks that recompute viz layouts client-side also get `verve.viz_core` —
the pure math slice of `verve.viz` (geometry, `fitBox`/`applyFit`, the
tree/radial/force/dag layout algorithms, interaction helpers, edge paths) —
so a client relayout reproduces SSR positions exactly. See
[22 — Visualization](22-visualization.md).

## Runnable demo

`examples/client-runtime/` mounts the `JsonProbe` island and exercises phases
1–6 from a single page — typed IPC (visible count round-trip),
events-with-data, timers/storage/clipboard, forms/measurement, JS interop, and
the chunk arena + drag-drop. `cd examples/client-runtime && zig build run`.

Phase 7 is exercised by the `/viz` route in the main demo app
(`zig build run`, then <http://127.0.0.1:8080/viz>): "● live" drives
`pushSubscribe` + `fetchToExport` resync, node/background drags exercise
pointer capture, and "⟳ layout" runs a `verveRafNamed` tween.

## Next

- [12 — WASM client](12-wasm-client.md) — main runtime architecture.
- [15 — Islands](15-islands.md) — per-island chunks + response handlers.
- [Index](README.md) — full doc tree.
