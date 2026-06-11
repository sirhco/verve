# Animation (`verve.anim`)

GSAP-class animation engine: tweens, timelines, keyframes, an easing
library (31 curves), stagger with grid/distribution patterns, dynamic
values, per-frame modifiers, a full control API
(pause/play/reverse/restart/seek/timeScale), math utilities, and built-in
`prefers-reduced-motion` handling — plus the plugin set documented below:
ScrollTrigger (with snap), Observer, ScrollSmoother, MotionPath,
MorphSVG, Draggable (with drop zones), SplitText, and FLIP.

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

## ScrollTrigger

Gate, scrub, or pin any tween/timeline by scroll position. v1 scope:
vertical window scroll. Config rides the same descriptor (wire key
`"sc"`); the bridge caches trigger ranges as document-space pixels (no
IntersectionObserver — exact and cheap) and re-measures on resize, load,
and font-ready.

```zig
// Scroll-gated entrance: play at 80% viewport, reverse scrolling back up
ctx.div().class("cards").animate(anim.from(a, ".card")
    .opacity(0).y(40).duration(0.5).ease(.out_back)
    .stagger(.{ .each = 0.07 })
    .scrollTrigger(.{
        .start = .{ .viewport = .{ .pct = 80 } },   // "top 80%"
        .actions = .{ .on_enter = .play, .on_leave_back = .reverse },
    }))

// Scrubbed + pinned: progress locked to the scrollbar (smoothed 0.3s),
// panel pinned for 1.5 viewport-heights; markers = debug lines
.animate(anim.to(a, ".bar").scaleX(1).propFrom("scaleX", 0).duration(1)
    .scrollTrigger(.{
        .start = .{ .trigger = .top, .viewport = .{ .pct = 20 } },
        .end = .{ .rel_vh = 1.5 },
        .scrub = .{ .smooth = 0.3 },   // or .exact, hard-bound
        .pin = .self,                  // or .{ .selector = ".panel" }
        .markers = true,
    }))

// Zero-wasm reveal: class toggle only, no tween, no rAF — pair with CSS
ctx.h2("Pricing").animate(anim.reveal(a, "in-view", .{
    .start = .{ .viewport = .{ .pct = 85 } },
    .once = true,
}))
```

- **Position specs** are Zig-native, GSAP-readable: `.{ .trigger = .top,
  .viewport = .{ .pct = 80 } }` is "top 80%". `Frac` accepts
  `.top/.center/.bottom/.pct/.frac`; specs take an `offset_px`. End:
  absolute spec, `.{ .rel_px = 500 }` ("+=500"), or `.{ .rel_vh = 1.5 }`.
  Defaults match GSAP: start "top bottom", end "bottom top".
- **Toggle actions** (4 slots: enter/leave/enterBack/leaveBack, each
  `none|play|pause|@"resume"|reverse|restart|complete|reset`) gate
  playback. Mutually exclusive with **scrub**
  (`error.ScrubWithToggleActions`). Infinite-repeat tweens can't scrub
  (warn + fallback to toggle-play).
- **Pin** wraps the element in a spacer (`data-verve-pin-spacer`) so the
  page doesn't collapse; pinned elements shouldn't also be x/y tween
  targets. One trigger per tween/timeline; timeline children can't carry
  their own (`error.NestedScrollTrigger`).
- **`toggle_class`** (`class_target` to redirect it) is SSR-legal and
  needs no wasm. Careful: CSS that hides content pending the class blanks
  no-JS users — prefer `.from` tweens for essential content.
- **Reduced motion**: anim-bearing triggers jump to their end state on
  registration (scrub included — content stays readable); pins are
  disabled; class toggles and callback triggers still run.
- **Snap**: `.snap = .{ .step = 0.25 }` (progress multiples; `1` =
  start/end — full-section snapping) or `.{ .points = &.{ 0, 0.5, 1 } }`
  (sorted, 0..1), plus `.snap_duration` (default 0.4s, outCubic). When
  input goes idle (~120ms under 20px/s) inside the trigger's span ±25%,
  the NATIVE scroll glides to the nearest point — nearest candidate wins
  across snap-enabled triggers, exact ties break in the last scroll
  direction, and any user input cancels the glide. Legal on any trigger
  (not just scrubbed). Disabled under reduced motion.
- **Island surface**: `verve.scrollCallbacks(t, .{ .on_enter = &f, ... })`
  stamps wasm callbacks onto a builder's trigger;
  `verve.scrollTrigger(cfg, cbs)` creates a standalone trigger (no
  animation) returning a `ScrollTriggerHandle` with
  `kill/refresh/disable/enable` + `progress/isActive/direction/velocity`.
  `verve.scrollRefresh()` re-measures everything after layout-changing
  DOM work; `verve.scrollPos()` reads the page scroll position. SSR
  named-export callbacks: `cb_island` + `cb_enter_export`/`cb_leave_export`.

## Observer (islands)

Unified wheel / touch / pointer-drag / scroll input detection with
velocity tracking — the substrate for flick/inertia UI (and the future
ScrollSmoother/Draggable plugins). Island-only.

```zig
var obs_id: u32 = 0;

fn onInput() void {
    const ob: verve.ObserverHandle = .{ .id = obs_id };
    // ob.deltaY(), ob.velocityY() (px/s), ob.dirY(), ob.isDragging(), ob.kind()
}

if (verve.observe(.{ .wheel = true, .touch = true, .tolerance = 4 }, &onInput)) |ob|
    obs_id = ob.id;
```

`ObserverConfig`: `target` selector (null = window), input flags
(`wheel/touch/pointer/scroll`), `prevent_default` (suppresses native
scrolling — required for smoothers, but it also suppresses the scroll
that ScrollTriggers depend on), `lock_axis`, `tolerance`. Handle:
`kill/disable/enable` + delta/velocity/direction getters. Touch deltas
use wheel polarity (finger up = positive deltaY).

## ScrollSmoother

Buttery inertia scrolling that keeps native scrolling intact: the
scrollbar, keyboard, anchors, find-in-page, and assistive tech all work —
only the *visual* position eases. A viewport-fixed wrapper holds the
content, which translates by a smoothed copy of the native scroll; a
spacer preserves the body's scroll range.

```zig
pub fn smoothPage(ctx: *verve.Context) !*verve.Node {
    const content = ctx.main_().children(.{
        ctx.div().class("hero-bg").parallaxSpeed(0.5),   // half scroll speed
        ctx.div().class("badge").parallaxLag(0.4),       // 0.4s extra easing
        // ... the whole page ...
    });
    // returns the WRAPPER — render the return value
    return content.smoothScroll(.{
        .smooth = 1.2,    // seconds to catch up (default 1)
        .touch = 0,       // touch smoothing; 0 (default) = native touch
        .parallax = true, // honor data-speed / data-lag
    }).build();
}
```

One smoother per page. ScrollTrigger math automatically switches to the
smoothed position (scrub, reveals, and markers track what the eye sees),
pins switch from `position:fixed` to transform counter-translation
(fixed breaks inside transformed content), and snap keeps driving the
native scroll — the smoother glides after it. `verve.smootherY()` /
`smootherVelocity()` / `smootherActive()` give islands read-only access.
Reduced motion disables the smoother entirely (fully native page).

Caveats: `position:fixed`/`sticky` descendants and CSS scroll-snap are
dead inside the content — portal modals/banners OUTSIDE the wrapper;
zero out body margin on smoothed pages; anchor/keyboard jumps land
natively while the visual eases in.

## SplitText

Break text into animatable spans for typographic reveals — split
server-side (the SSR knows the text), so chars and words cost zero JS.

```zig
ctx.h2("Split, stagger, scroll")
    .splitText(.{ .by = .chars })          // .words / .words_and_chars / .lines
    .animate(anim.from(a, ".st-char")
        .opacity(0).y(18).duration(0.45).ease(.out_cubic)
        .stagger(.{ .each = 0.025 })
        .scrollTrigger(.{ .start = .{ .viewport = .{ .pct = 85 } } }))
```

Output: the original text becomes spans inside ONE
`<span aria-hidden="true" data-split-wrap>`, and the parent gets
`aria-label` with the original text — screen readers hear the sentence,
not the soup. Whitespace runs are preserved verbatim as plain text
between spans, so wrapping and collapsing behave exactly like the
unsplit text. `words_and_chars` nests char spans inside word spans
(chars animate, line wrap stays stable); `index_attr` stamps
`data-st-i` for CSS counters.

`lines` can't be split on the server (wrap depends on layout): it emits
word spans plus `data-split-lines`, and the bridge groups them into
`.st-line` blocks by offsetTop once at hydrate — before animations
resolve their targets, so `.animate(anim.from(a, ".st-line")...)` just
works. Lines are measured once; late webfonts or resizes can stale them
(prefer chars/words for resize-critical UI).

Requirements + caveats: spans need `display:inline-block` CSS for
transforms (`.st-char,.st-word{display:inline-block}`); kerning and
ligatures break across char spans (prefer `.words` for typographic
fidelity); splitting is per UTF-8 codepoint — grapheme clusters
(emoji/ZWJ/combining marks) and bidi/RTL text are unsupported v1.
Splitting requires a plain leaf text node (no children, no raw HTML, no
reactive bind — deferred errors otherwise).

## FLIP

Animate layout changes — reorders, DOM moves — as transforms
(First-Last-Invert-Play). Island-only: capture, mutate the DOM, play.

```zig
const state = verve.flipCapture(".flip-grid .fcard") orelse return;
verve.listDiff("flip_list", &old_keys, &new_keys, &html);  // or any DOM mutation
_ = verve.flipPlay(state, .{
    .duration = 0.45,
    .ease = .out_cubic,
    .scale = false,      // width/height ratios as scaleX/Y (distorts children)
    .stagger = 0.015,    // per play-time DOM order
    .fade_in = true,     // elements that appeared since capture fade 0->1
}, .{ .on_complete = &onDone });
```

Matching: element identity first (covers `move_keyed_child` reorders —
the keyed reconciler is the FLIP fast path), then `data-vkey` for
reconciler-recreated nodes. `on_enter` fires once per play when
uncaptured elements exist (they also fade in under `fade_in`);
`on_leave` fires once when captured elements are gone — both run
synchronously BEFORE `flipPlay` returns (don't depend on the handle),
and both still fire under reduced motion (structural facts, fired in
jump-to-end order before `on_complete`). The invert
lands synchronously in the same task as the layout change (no flash),
then everything eases to identity through the shared transform composer.
`flipPlay` always consumes the state (`state.discard()` for abandoned
captures); `FlipHandle.kill()` snaps to identity without callbacks.
Re-flipping mid-flight steals elements cleanly. Under reduced motion,
play is a no-op that fires `on_complete` immediately. Caveats: assumes
translate+scale-only transforms at play (rotate/skew → position-only),
default `transform-origin`, and unpinned elements.

## Draggable

Pointer drag with grip handles, axis lock, bounds, snap, and inertia
throw — verve's drag engine, not the native HTML5 `draggable="true"`
attribute. Position writes go through the shared transform composer, so
rotate/scale/opacity tweens compose with an active drag (don't tween
x/y mid-drag — last writer wins).

```zig
// SSR, zero-wasm: bounded card that coasts onto a 40px grid
ctx.div().class("card")
    .draggable(anim.draggable(a, .{
        .axis = .both,                       // .x / .y lock
        .handle = ".titlebar",               // grip sub-selector
        .bounds = .{ .selector = ".pen" },   // or .{ .rect = .{...} } translate-space px
        .inertia = .on,                      // or .{ .retention = 0.3 } (velocity kept/sec)
        .snap = .{ .grid = .{ .x = 40, .y = 40 } },  // or .{ .points = &.{...} }
        .toggle_class = "dragging",
    }))
```

```zig
// Island: callbacks + live position/velocity through a DragHandle
if (verve.draggable(.{ .target = "#card", .inertia = .on }, .{
    .on_start = &onStart, .on_drag = &onMove,
    .on_end = &onEnd, .on_throw_complete = &onSettle,
})) |dh| drag_id = dh.id;
// dh.x()/.y()/.velocityX()/.isDragging()/.isThrowing()
// dh.kill()/.disable()/.enable()/.setPos(x, y)
```

Drop zones: `.zones = ".drop-zone"` hit-tests the pointer against zone
rects (resolved per gesture, page coordinates); `.zone_class` toggles a
hover class on the zone under the pointer (SSR-legal, zero-wasm);
`on_drop` fires on release over a zone, with the index via
`DragHandle.dropZone()` (`hoverZone()` reads live during the drag; −1 =
none). The drop is decided at the release point, before any throw.

Semantics: a 3px engage threshold keeps clicks inside draggables working
(configurable `threshold_px`); after a real drag the synthetic click is
suppressed. Bounds re-measure at the start of every gesture. Throws
project the rest point analytically from release velocity (exponential
friction), clamp it to bounds, snap it, then decelerate exactly onto it —
no bounce. `touch-action` is set per axis at create so touch drags don't
scroll the page along the drag axis. Reduced motion: dragging itself
stays (direct manipulation), but releases land instantly on the
projected, snapped rest point.

## MotionPath

Animate any element along an SVG path. Zig parses the `d` string,
normalizes everything to cubic Béziers, and samples a uniform-arc-length
polyline at serialize time — the bridge only lerps it into the shared
transform composer (x/y + optional tangent rotation), so motion paths
compose with scale/skew tweens, timelines, stagger, and ScrollTrigger
scrub for free.

```zig
// verve.viz edge-path output plugs straight in
const d = try verve.viz.edgePathD(a, &pts, .curved, .{});
node.animate(anim.to(a, ".marker")
    .motionPath(.{
        .path = d,
        .rotate = true,           // auto-orient along the tangent
        .rotate_offset_deg = 90,  // for glyphs drawn pointing up
        .start = 0.0, .end = 1.0, // path window; start > end runs backward
        .samples = 0,             // 0 = auto (128), clamped [2, 512]
    })
    .duration(4).ease(.linear).repeat(-1))
```

Path coordinates are written verbatim into the x/y translate slots — px
offsets in the same space as `.x()`/`.y()` (for SVG children, CSS px ≡
user units, so a path in the element's own viewBox traces exactly).
`.align_to = .start` re-bases the polyline on its first sample, so the
motion starts at the element's current rendered position and follows the
path's shape — use it for paths authored in absolute coordinates.
Conflicts are deferred errors: explicit `.x()`/`.y()` props
(`MotionPathConflict`), `.rotate()` when `rotate = true`, keyframe steps,
`anim.from`. Parser supports the full SVG grammar (relative commands,
S/T reflection, arcs incl. compressed flags); bad strings surface as
`error.BadPath` at serialize. Overshooting eases (back/elastic)
extrapolate along the end tangent.

## MorphSVG

Morph a `<path>`'s `d` between two authored strings. Zig matches the
shapes at serialize time — winding auto-reverse, segment-count
equalization by de Casteljau splitting, cyclic start-point alignment for
closed pairs — and ships two equal-length control-point arrays; the
bridge lerps points and rebuilds the `d` string per frame.

```zig
node.animate(anim.to(a, "#shape")
    .morph(.{ .from = star_d, .to = circle_d })
    .duration(1.4).ease(.in_out_sine).repeat(-1).yoyo(true))
```

Both `d` strings must be authored on the SSR surface (the server cannot
read live DOM attributes). Islands can morph FROM the current shape:
`verve.refGetAttrArena(handle, "d")` reads the live attribute into the
chunk arena (probe-then-copy — never truncates), so mid-morph clicks
morph from the in-flight shape:

```zig
const h = verve.queryRef(@as([]const u8, "morph-path")) orelse return;
const current = verve.refGetAttrArena(h, "d") orelse return;
_ = verve.animPlay(anim.to(a, "#shape").morph(.{ .from = current, .to = target }));
```
Subpath counts must match (`error.SubpathCountMismatch`) — pre-split
compound paths. Composes with other props on the same tween (fill color,
opacity, transforms). Keep segment counts in the low hundreds — the
bridge builds a fresh `d` string per target per frame. Line segments
normalize with controls at exactly 1/3 and 2/3 (the frozen contract the
goldens and `buildMorphD` share).

Math utilities are exposed under `verve.anim.path`: `parse`,
`motionSamples`, `sampleAt`, `totalLength`, `prepareMorph`.

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
element. Colors normalize to `{"c":[r,g,b,a]}`.

ScrollTrigger rides as a root-level `"sc"` object (all numeric; `"auto"`
is ignored when present — the trigger owns play-state):

```json
"sc":{"t":{"s":"#sec"},"s":[0,0.8],"e":{"rv":1.5},"scr":0.3,"pin":1,
      "act":[1,0,0,4],"once":1,"mk":1,"cls":"in-view","ct":".headline",
      "cb":{"sE":12,"sL":13,"sEB":14,"sLB":15,"sU":16,
            "isl":"Hero","nE":"hero_enter","nL":"hero_leave"}}
```

`s`/`e` = `[triggerFrac, viewportFrac, offsetPx?]` (defaults `[0,1]` /
`[1,0]` omitted); `e` alternatives `{"r":px}` / `{"rv":viewportHeights}`;
`scr` `true` = exact, number = smoothing seconds; action ints: 0 none,
1 play, 2 pause, 3 resume, 4 reverse, 5 restart, 6 complete, 7 reset.
Snap: `"snap":0.25` (step) or `"snap":[0,0.5,1]` (points) +
`"snapd":0.6` (omitted at default 0.4). The smoother config rides its
own attribute: `data-smooth-wrapper='{"sm":1.5,"tch":0.8,"px":0}'`
(defaults omitted) around a `data-smooth-content` child.
A descriptor with `sc` and no `p`/`k`/`ch` is a tween-less trigger
(`anim.reveal`).

MotionPath and MorphSVG ride as root-level keys (pure pre-computed data,
legal on both surfaces; `"p":{}` is suppressed when they carry the
animation):

```json
"mp":{"pts":[x,y,a, x,y,a, ...],"rot":1,"ro":90}
"mo":{"a":[Mx,My, c1x,c1y,c2x,c2y,x,y, ...],"b":[...same length...],
      "sp":[segsPerSubpath],"z":[closedFlags]}
```

`mp.pts` is stride 3 (x, y, unwrapped angle°) with `rot:1`, stride 2
otherwise — uniform arc-length spacing, already windowed to
[start, end]. `mo` is flat per-subpath runs of `2 + 6k` floats; `z` only
when any subpath is closed. Coordinates are rounded to 0.01 Zig-side.

Draggables use their own attribute (`data-drag`) and descriptor root —
not an animation, independent lifecycle:

```json
{"v":1,"dr":{"t":{"s":".card"},"hd":".grip","ax":1,
 "b":{"s":"#pen"} ,"in":1,"sn":{"g":[40,40]},
 "th":6,"cur":0,"cls":"dragging","dis":1,
 "cb":{"sS":21,"sD":22,"sE":23,"sT":24}}}
```

`ax`: 1 x, 2 y (omitted = both). `b`: selector object or
`[minX,maxX,minY,maxY]` translate-space rect. `in`: 1 = default
retention 0.05/s, else retention in (0,1). `sn`: `{"g":[gx,gy]}` grid or
`{"p":[x,y,...]}` nearest point. Ctrl ops: 0 kill, 1 disable, 2 enable,
3 setPos; get fields: 0 x, 1 y, 2 vx, 3 vy, 4 dragging, 5 throwing.
The serializer's golden tests (`zig test src/core/anim/serialize.zig`)
freeze this contract; `node tests/js/anim_conformance.mjs` checks the
bridge's lerp/string-building halves against the same fixtures.

## Demo

`zig build run` →

- <http://127.0.0.1:8080/anim> exercises both surfaces plus most
  plugins: declarative entrance + infinite keyframe pulse, the
  `AnimDemo` island (`src/client/islands/AnimDemo.zig`) with full
  control-API buttons, a scroll-gated SplitText headline and
  line-reveal paragraph, motion-path orbit with scrubbed variant,
  morph-from-current SVG toggle, an inertia draggable card with drop
  zones, scrubbed/pinned scroll sections, and a FLIP grid (shuffle +
  remove/restore card).
- <http://127.0.0.1:8080/smooth> is the ScrollSmoother page: parallax
  hero, snapping section deck, transform-pinned panel, and a probe
  island showing native vs smoothed scroll diverge live.

## Not yet

The original GSAP-class spec is complete. Tracked follow-ups:
horizontal / container scrollers, configurable snap ease +
inertia-aware directional snap, grapheme-aware/RTL splitting + split
revert, FLIP nested counter-scale, drag bounce / sortable lists,
MotionPath `align` to another element (`.align_to = .start`
self-alignment shipped).
