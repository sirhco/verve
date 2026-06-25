# Verve — Roadmap / Remaining Work

Consolidated view of outstanding work. The framework's per-feature guides
each carry their own "Not yet built / Deferred" notes; this file gathers
them so the backlog is discoverable in one place. Desktop has its own
authoritative backlog at [`docs/11-desktop-roadmap.md`](docs/11-desktop-roadmap.md).

**Current:** v0.18.2 (pre-1.0; public APIs unstable, break between minor
versions). Status legend: ✅ done · 🟡 partial · ⏳ remaining · 🔒 host-gated
(needs a real Win/Linux host to verify) · 🍎 macOS-verifiable on a dev machine.

---

## Shipped

### Core framework (original 6-phase web/SSR/island work)

- ✅ **Client hydration + lifecycle** — per-island + route disposal,
  `MutationObserver` hydrate/dispose, per-`vid` owners, keyed reconciler.
- ✅ **Streaming SSR async** — `Resource` via `std.Io.async`; concurrent
  out-of-order Suspense drain (`streamRender`).
- ✅ **Island system** — typed props (`serialize.zig` codec, panic-free
  decoder), resource-state hydration, per-`vid` chunk runtime, multi-instance
  namespacing, keyed-list (`bindForEach`) per-instance binds, cross-component
  handler-name isolation, client-side `fetchSignal` resource round-trips.
- ✅ **Server functions** — typed `_call` wasm round-trip (correlated
  `x-verve-rid` reply), CSRF, server-fn codegen.
- ✅ **i18n** — RTL direction + CLDR cardinal pluralization; opt-in
  `LazyCatalog` (per-locale embedded blobs, single-binary preserved).

### Domain libraries (the bulk of v0.3 → v0.18)

- ✅ **`verve.viz`** — charts + node-link graphs, **SVG and canvas2d** render
  paths; force / sankey / treemap / chord layouts; pan / zoom / hover / select
  hit-testing; live data over the SSE **and WebSocket** push hub
  (`push.publish` / `/push` / `/push-ws`). Guide: `docs/22-visualization.md`.
- ✅ **`verve.anim`** — GSAP-class engine, pure Zig + one JS interpreter:
  tweens, timelines, ScrollTrigger / ScrollSmoother, MotionPath + MorphSVG,
  SplitText (UAX#29 graphemes), FLIP, Draggable, Sortable (single + cross-list
  groups). Frozen wire contract via `serialize.zig` goldens. Guide:
  `docs/23-animation.md`.
- ✅ **`verve.gl`** — three.js-class 3D, pure Zig + **WebGL2 and WebGPU**
  interpreters off one binary command stream. PBR metallic-roughness + IBL;
  multi-light **shadow casters** + **CSM** + **LTC area lights**; **skeletal
  skinning** (all glTF interp modes); **morph targets** (POSITION + NORMAL +
  TANGENT deltas, 32 influences, Hermite easing, **combined skinned + morph**);
  **distance-based LOD**; image quality (G-buffer prepass, SSAO, SSR, DOF,
  **weighted-blended OIT**, 6 tone-mappers, vignette, bloom + FXAA); build-time
  `.glb` → packed `.vmesh` asset pipeline. Guide: `docs/24-gl.md`.

### Desktop

All three backends (macOS / Windows / Linux GTK) verified on real hardware as
of v0.2.0. Windows validated on a real host (custom-scheme assets, WinRT toast,
update-apply). See **Remaining → Desktop** below; authoritative backlog in
[`docs/11-desktop-roadmap.md`](docs/11-desktop-roadmap.md).

---

## Remaining

### `verve.gl` — three.js parity gaps

Rough complexity in (parens). From `docs/24-gl.md` → "Remaining for three.js parity".

- ⏳ **Primitives:** particles / points / sprite material (med); fat lines /
  LineSegments (small/med); decals (med).
- ⏳ **Camera:** orthographic projection (small); user clipping planes (small).
- ⏳ **Assets:** Draco / meshopt compression (med/large — gated by the zero-dep
  rule); KTX2 / basis textures (med).
- ⏳ **Instancing edges:** instanced shadows; per-instance frustum culling;
  multi-mesh instancing; non-uniform-scale instance normals (each small/med).
- ⏳ **Advanced:** user custom shader materials (large); runtime reflection
  probes / cubemap capture (large); wireframe mode (small); water / terrain
  (large, domain-specific).

### `verve.anim` — deferred

- ⏳ **Full UAX#9 bidi reordering across runs** — same-direction runs wrap in
  `<span dir>`; true cross-run interleaved reordering is left to the browser.
- ⏳ **MotionPath `align` to another element** — self-alignment ships; aligning
  to a separate element's position does not.
- ⏳ **Snap + pin with element scrollers** — `snap`/`pin` stay window-scoped;
  neither composes with container scrollers yet.
- ⏳ **Sortable nested / multi-level lists** — single + cross-list ship; deep
  nesting not yet exercised.

### `verve.viz` — deferred

- ⏳ **Multi-parent-aware collapse visibility** — a hidden node with a second
  visible parent should stay visible; v1 hides it.
- ⏳ **Multiple interactive graphs per page** — the island is module-static,
  single-instance.
- ⏳ **Smooth routed-edge interactivity** — curved / orthogonal `<path>` edges
  that re-route during drag are static-render-only so far.

### Desktop

Authoritative: [`docs/11-desktop-roadmap.md`](docs/11-desktop-roadmap.md).
Windows validated on a real host; **Linux remains host-gated** (cross-compiles
clean, behavior-unvalidated — no Linux host available).

- ⏳🔒 **GTK4 + WebKitGTK 6.0** behind `-Dgtk4` — largest item; GTK3 +
  WebKitGTK 4.1 wired today. Needs Ubuntu 24 LTS / Fedora 41 validation.
- 🟡 **Updates apply** — macOS (`.app` swap) + Windows (side-by-side swap)
  ship; Linux (AppImageUpdate) 🔒 remains.
- 🟡 **Image clipboard** — macOS (PNG) + Windows (`CF_DIBV5` via WIC) ship;
  Linux (`image/png` GtkClipboard target) 🔒 remains.
- 🟡 **Full a11y provider** — role-desc / subrole on macOS (NSAccessibility) +
  Windows (UIA); Linux help only, role-desc/subrole pending an AtkObject
  provider (🔒).
- 🟡 **Live Win/Linux validation** — Windows done; Linux 🔒 needs a real
  Ubuntu/Fedora boot of every code path.

---

## Notes

- **Keep this file in sync** with each guide's "Not yet / Deferred" section
  (or fold it into `docs/README.md`). Release versions live in `CHANGELOG.md`
  and the git tags (`v0.x.y`) — those are authoritative.
- **Genuinely out of scope (not bugs):** the `_post` fire-and-forget path, the
  `verve-spa` meta opt-out (unimplemented by design), and decimal-operand CLDR
  plural forms (integer counts only) are intentional, not pending.
