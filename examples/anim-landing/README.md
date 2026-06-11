# anim-landing

A product-landing-page composition of **`verve.anim`** — one
smooth-scrolled, server-rendered page that uses the whole plugin set the
way a real site would (the framework's `/anim` route is the
kitchen-sink reference; this is the "what it's for" version).

```sh
zig build run          # → http://127.0.0.1:8080
```

## What's on the page

| Section | Feature |
|---|---|
| Hero | **SplitText** chars entrance, **parallax** layers (`data-speed`) + lag badge (`data-lag`), all under a **ScrollSmoother** |
| Features | zero-wasm **class reveals**, line-split copy, scroll-gated card **stagger** (reverses on scroll-back) |
| Fly the curve | **MotionPath** with tangent rotation, **scrubbed** by scroll |
| Shape-shift | **MorphSVG** star → blob, scrubbed |
| Pin + snap | transform-**pinned** panel (the smoother makes `position:fixed` pins impossible — pins counter-translate), scrubbed bar, **points snap** (0 / ½ / 1) |
| Drag, flick, drop | zero-wasm **Draggable**: bounds, analytic **inertia**, grid snap, **drop zones** with hover class — pure `data-drag`, no island |
| Gallery | the one island: **FLIP** shuffle through the keyed reconciler + remove/restore (enter/leave callbacks, fade-in) |

Everything except the gallery is **declarative SSR** — `data-anim` /
`data-drag` attributes the bridge interprets, no wasm involved. Set OS
reduced-motion and reload: entrances land instantly, loops and scrub
effects skip, the smoother turns off, and the page is still complete.

## Where to look

- `src/app/components.zig` — the page; every section is a few chained
  builder calls (`.splitText`, `.animate`, `.draggable`,
  `.smoothScroll`, `.parallaxSpeed`).
- `src/client/islands/Gallery.zig` — the FLIP chunk:
  `flipCapture` → `listDiff` (note the `__v{vid}` bind suffix —
  the keyed reconciler does NOT auto-scope island binds) → `flipPlay`
  with `on_complete` / `on_enter` / `on_leave`.
- `build.zig` — mirrors the framework build; island chunk sources
  resolve example-local first, so `Gallery.zig` lives here.

Guide: [`docs/23-animation.md`](../../docs/23-animation.md).
