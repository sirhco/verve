# Animation (`verve.anim`)

GSAP-class core animation engine: tweens, timelines, keyframes, an easing
library (31 curves), stagger with grid/distribution patterns, dynamic
values, per-frame modifiers, a full control API
(pause/play/reverse/restart/seek/timeScale), math utilities, and built-in
`prefers-reduced-motion` handling.

**Architecture — hybrid execution.** Zig builds tween/timeline descriptors
and serializes them to a compact JSON wire format (`"v":1`); a small
interpreter inside `src/bridge/verve.js` owns the requestAnimationFrame
loop and style writes. Wasm is re-entered per frame only for dynamic
values and fn modifiers. The wire format's single source of truth is
`src/core/anim/serialize.zig` — its golden tests are the JS interpreter's
conformance fixtures.

Two authoring surfaces share the same builders and wire format:

| Surface | How | Best for |
|---|---|---|
| **Declarative SSR** | `node.animate(...)` stamps a `data-anim` attribute; the bridge scans and runs it after hydrate | Entrance animations, ambient loops — no island required |
| **Imperative island** | `verve.animPlay(...)` from island wasm returns an `AnimHandle` | Anything needing runtime control or callbacks |

## Declarative SSR surface

`anim.from` is the natural entrance primitive: the rendered HTML *is* the
end state, so reduced-motion and JS-off both degrade to exactly the SSR
page.

```zig
const anim = verve.anim;

pub fn hero(ctx: *verve.Context) !*verve.Node {
    const a = ctx.alloc();
    return ctx.section().class("hero").children(.{
        // null target = this node
        ctx.h1("Verve").animate(anim.from(a, null)
            .opacity(0).y(40)
            .duration(0.6).ease(.out_cubic).delay(0.1)),
        // selector target = this node's descendants, staggered on a grid
        ctx.div().class("cards").animate(anim.from(a, ".card")
            .opacity(0).scale(0.9)
            .duration(0.5).ease(.out_back)
            .stagger(.{ .each = 0.06, .from = .center,
                        .grid = .{ .cols = 4, .rows = 2 } })),
    }).build();
}
```

One animation per node (`error.DuplicateAnimation` otherwise) — compose
with a timeline instead. `animateJson(bytes)` is the escape hatch for
pre-serialized descriptors. New subtrees from Suspense swaps, SPA
navigations, and template clones are scanned automatically; a
`data-anim-done` stamp prevents double registration.

### Keyframes

`.step(pct)` opens a step at a 0–100 offset; subsequent prop calls land in
it. `stepEase` sets the ease *into* that step. Exclusive with the simple
multi-prop mode.

```zig
ctx.div().class("pulse").animate(anim.to(a, null)
    .step(0).scale(1.0)
    .step(50).stepEase(.in_out_sine).scale(1.15)
    .step(100).scale(1.0)
    .duration(1.2).repeat(-1).reducedMotion(.skip))
```

### Timelines

Position arithmetic is resolved eagerly in Zig at `.add()` time; the wire
format carries only absolute start seconds.

```zig
const tl = anim.timeline(a).named("intro")
    .add(title_tween, .end)              // after previous end (default)
    .add(list_tween, .{ .rel = -0.3 })   // overlap: "-=0.3"
    .addLabel("mid", .{ .abs = 0.8 })
    .add(cta_tween, .{ .label = "mid" }) // at a label
    .add(other, .with_prev);             // aligned with previous start
ctx.div().animate(tl)
```

A staggered child's contribution to timeline sequencing includes its
stagger spread only when `stagger.total` is set — with `each`, the target
count isn't known until runtime, so use `total` when later children must
sequence after the stagger finishes.

## Imperative island surface

Builders come from the same module (`verve.anim` inside chunks via the
`anim_core` build module). Build in the chunk arena; the JS side copies
the descriptor at the `animPlay` boundary, so the arena can be reset
immediately after.

```zig
const verve = @import("verve");
const anim = verve.anim;

var intro_id: u32 = 0; // plain u32 — safe in chunk statics

fn onDone() void { verve.signalSetStr("status", "done"); }

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr; _ = props_len; _ = root_id;
    const mark = verve.chunkArenaMark();
    defer verve.chunkArenaReset(mark);
    const a = verve.chunkArena();

    const cards = verve.animOnComplete(
        anim.from(a, ".card").opacity(0).y(30)
            .duration(0.5).ease(.out_back)
            .stagger(.{ .each = 0.06, .from = .edges }),
        &onDone,
    );
    const h = verve.animPlay(anim.timeline(a).add(cards, .end)) orelse return;
    intro_id = h.id;
}

export fn toggle() void {
    const h: verve.AnimHandle = .{ .id = intro_id };
    if (h.isActive()) h.pause() else h.play();
}
```

### Control API

`AnimHandle` methods: `play`, `pause`, `reverse`, `restart`, `seek(t)`,
`seekLabel(name)`, `timeScale(f)`, `kill`, plus getters `time`,
`progress` (0–1), `duration` (−1 when infinite), `isActive`,
`currentTimeScale`, `isReversed`. `verve.animLookup("name")` resolves any
`.named(...)` animation — including SSR-declared ones — to a handle, so
islands can control declarative animations.

`kill` (and the automatic kill when all targets leave the document) is
silent: last-written styles stay, pending callbacks never fire (GSAP
semantics).

### Callbacks, dynamic values, modifiers

```zig
verve.animOnStart(t, &handler);     // event-slot registration under the hood
verve.animOnComplete(t, &handler);  // works on tweens and timelines
verve.animOnRepeat(t, &handler);

// dynamic end value: evaluated per target at tween start
fn cardX(i: u32, n: u32) f64 { _ = n; return @as(f64, @floatFromInt(i)) * 24.0; }
t.x(verve.animDyn(&cardX));

// per-frame fn modifier (interpolated value in, written value out)
fn snapY(v: f64) f64 { return verve.anim.snap(v, 8.0); }
t.modifier(verve.animModFn("y", &snapY));

// built-in modifiers need no wasm round-trip:
t.modifier(.{ .prop = "rotate", .op = .{ .wrap = .{ .min = 0, .max = 360 } } });
t.modifier(.{ .prop = "x", .op = .{ .clamp = .{ .min = 0, .max = 400 } } });
t.modifier(.{ .prop = "y", .op = .{ .snap_to = 4 } });
```

Dynamic values and callback slots are island-only — the SSR serializer
rejects them (`error.DynRequiresIsland` /
`error.CallbackSlotRequiresIsland`). SSR descriptors can still request a
completion callback as a named island export:
`.onCompleteExport("Hero", "introDone")` dispatches that chunk export
with `{"anim":"<id>"}`.

Lifetime rules: callback handlers must not capture chunk-arena pointers
(they fire after resets); handles and slot ids are plain `u32`s.

## Properties

- **Transform shorthands** `x`, `y`, `scale`, `scaleX/Y`, `rotate`,
  `skewX/Y` compose into **one** `style.transform` write per element per
  frame. The engine owns `style.transform` for any element it touches —
  don't co-mutate it elsewhere. Pre-existing transforms are absorbed by a
  one-time 2D matrix decomposition (`matrix3d` warns and is treated as
  identity).
- **Any CSS property** via `prop("background-color", "#ff8800")` — use
  hyphenated names. Authored hex/rgb colors are normalized at serialize
  time; interpolation is per-channel rgb.
- **SVG attributes** via the `attr:` prefix: `prop("attr:cx", 120)`.
- **Units**: numbers default to `px` for lengths, `deg` for
  rotate/skew, unitless for opacity/scale. Override with `Value`
  literals: `.x(.{ .pct = 50 })`, `.prop("width", .{ .rem = 4 })`, or any
  raw CSS string.

## Easing

31 curves: `linear` plus `in`/`out`/`in_out` ×
sine/quad/cubic/quart/quint/expo/circ/back/elastic/bounce, e.g.
`.ease(.out_back)`. The JS interpreter owns the runtime math;
`verve.anim.ease.apply(e, t)` provides bit-identical Zig implementations
(used for stagger distribution easing and available to native consumers).

## Stagger

```zig
.stagger(.{
    .each = 0.05,            // seconds per distance unit
    // .total = 0.8,         // or: fixed total spread (wins over each)
    .from = .center,         // .start / .end / .center / .edges / .{ .index = n }
    .grid = .{ .cols = 4, .rows = 3 },
    .axis = .x,              // restrict grid distance to one axis
    .ease = .out_quad,       // distribution easing
})
```

## Reduced motion

Checked at bridge init and live via a media-query listener. Defaults per
animation:

- `jump_to_end` (default) — apply the final state instantly; callbacks
  fire in order. Implemented as a seek, so yoyo/repeat end states are
  correct. Infinite repeats land at the end of the first cycle.
- `.reducedMotion(.play)` — run anyway (opacity-only fades, progress UI).
- `.reducedMotion(.skip)` — never registers; the SSR state stands
  (recommended for infinite decorative loops).

When the OS toggle flips to reduce mid-session, live non-`.play`
animations jump to their end.

## Math utilities

`verve.anim` re-exports: `clamp`, `lerp`, `mapRange` (unclamped,
GSAP-compatible), `interpolate`, `snap`, `wrap`, `pipe` (comptime fn
composition), `parseColor` / `interpolateColor` / `Color`, and
`staggerDelay(i, n, spec)`.

## Wire format (reference)

`data-anim` / `verve_anim_create` carry the same JSON:

```json
{"v":1,"id":"card-in","t":{"s":".card"},"d":0.5,"del":0.1,"rep":2,"rd":0.25,
 "yo":1,"e":"outCubic",
 "p":{"y":{"f":24,"to":0},"opacity":{"f":0,"to":1},"left":{"to":10,"u":"%"}},
 "st":{"each":0.06,"from":"center","grid":[4,2],"e":"outQuad"},
 "cb":{"sS":16,"sC":17,"isl":"Hero","nC":"introDone"},
 "rm":"allow","auto":0}
```

Keyframes replace `p` with
`"k":[{"o":0,"p":{...}},{"o":0.5,"e":"inOutSine","p":{...}}]` (`o` =
offset 0..1). Timelines: `"tl":1` with `"ch":[{"pos":<seconds>,...}]` and
`"lab":{"name":<seconds>}`. Targets: `{"s":selector}` (SSR: scoped to the
carrying element), `{"h":refHandle}` (island), omitted = the carrying
element. Colors normalize to `{"c":[r,g,b,a]}`. The serializer's golden
tests (`zig test src/core/anim/serialize.zig`) freeze this contract.

## Demo

`zig build run` → <http://127.0.0.1:8080/anim> exercises both surfaces:
declarative entrance + infinite keyframe pulse (`.skip` under reduced
motion), and the `AnimDemo` island (`src/client/islands/AnimDemo.zig`)
with pause/play/reverse/restart/timeScale buttons, an onComplete signal,
and a dynamic-value + snap-modifier tween.

## Not yet (planned plugins)

ScrollTrigger/Observer, ScrollSmoother, FLIP layout animation, SplitText,
Draggable, MotionPath, MorphSVG — tracked as follow-up phases; the core
engine above is their substrate.
