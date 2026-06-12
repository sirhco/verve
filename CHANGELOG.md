# Changelog

All notable changes to Verve are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **`verve.gl` P5 — verve.anim fusion: gl-target tweens + scroll-scrub
  demo** (`src/core/anim/tween.zig`, `src/core/anim/serialize.zig`,
  `src/core/gl/anim_target.zig`, `src/client/island_runtime.zig`,
  `src/bridge/verve.js`, `src/client/islands/GlScene.zig`,
  `src/core/gl_scene.zig`):
  - **gl-target prop kind** (`serialize.zig`): frozen wire key
    `"@gl:<target_id-decimal>"`, value `{"gl":<id>,"gls":<slot>,
    "to":<num>}` + optional `"f"` from-value. Non-gl output
    byte-identical (frozen regression golden). The `@gl` prefix lets
    `animWriteProp` route to the setter indirect table, returning before
    any DOM write.
  - **Target-id encoding** (`src/core/gl/anim_target.zig`, frozen):
    u32 `[31:24]` kind (0=camera, 1=material, 2=model) | `[23:8]`
    submesh (material only) | `[7:0]` field. Camera fields: yaw=0,
    pitch=1, distance=2. Material: metallic=0, roughness=1. Model:
    yaw=0. Path grammar: `"camera.yaw"`, `"material:<Name>.metallic"`,
    `"model.yaw"` — resolved once at setup against the vmesh v3 name
    table.
  - **Tween builders** (`tween.zig`): `glTarget(id, slot, to)`,
    `glTargetFrom(id, slot, from)`, `glTargetRange(id, slot, from,
    to)` — island-only (slot resolved at hydration); `"@gl"` is a
    reserved selector name.
  - **Setter registration** (`island_runtime.zig`):
    `animGlSetter(*const fn(u32,f64) void) u32` — registers a
    `fn(target_id, value)` callback and returns its indirect-table
    slot. Mirrors the `dyn`/`mod` registration pattern.
  - **JS engine** (`verve.js`): `animWriteProp` gl branch interpolates
    + applies modifiers then calls `indirectTable.get(gls)(gl, value)`;
    `from` defaults to 0 when `"f"` is absent. `verve_anim_register_setter` import wires chunk-registered setters.
  - **GlScene scroll-scrub** (`GlScene.zig`): `.scrub(true)` prop
    zeroes autoRotate and builds a scroll-scrubbed timeline in
    `vmesh_ready`: model.yaw turntable (current → current + 2π) +
    `material:Cube.roughness` sweep (0.045 → 1.0), `ScrollTrigger`
    over the island-internal section with `smooth: 0.4`.
  - **`/gl-scene` route** updated: island-internal 300 vh section,
    sticky 100 vh viewport, aspect-ratio canvas box, "scroll to spin"
    copy.
  - **Separate rAF loops kept** (deviation recorded): anim writes gl
    statics on its own tick; gl reads them the next frame (≤1 frame
    lag at 60 fps). Shared-tick pass deferred.
  - **Deferred** (recorded): shared-rAF tick, `node:<Name>.rotation`
    paths, emissive tween paths, SSR-side glTarget.
  - **Wire goldens**: `@gl:<id>` key, `gl/gls/to/f` value fields —
    frozen by golden tests in `serialize.zig`.
  - Guide: `docs/24-gl.md` (P5 section); cross-ref in
    `docs/23-animation.md`.

- **`verve.gl` P4 — interactive orbit camera, BVH ray-picking,
  declarative `ctx.glScene`, GPU lifecycle** (`src/core/gl/orbit.zig`,
  `ray.zig`, `bvh.zig`, `registry.zig`, `src/core/gl_scene.zig`,
  `src/client/islands/GlScene.zig`):
  - **Orbit camera** (`orbit.zig`): damped spherical-coordinate
    controller. `OrbitInput` carries `dyaw/dpitch/dzoom` impulses;
    `Orbit.tick(dt_ms, input)` integrates via frame-rate-independent
    exponential decay (`a = 1 − exp(−k·dt_s)`); `eye()` and
    `viewMatrix(up)` expose the result. Min/max clamps on distance and
    pitch. `autoRotate` in `GlScene` bypasses damping for a constant
    rad/s rate.
  - **Pick ray** (`ray.zig`): `rayFromCamera(eye, target, up, fov_y,
    aspect, ndc_x, ndc_y)` builds the camera basis analytically (no
    matrix inverse). `intersectTriangle` uses Möller–Trumbore.
  - **BVH** (`bvh.zig`): flat 32-byte nodes (FROZEN format: `aabb_min
    f32×3 @0`, `aabb_max f32×3 @12`, `left_or_first u32 @24`, `count
    u32 @28`). `bvh.build` (native, median split, allocating).
    `bvh.walk` (freestanding, fixed `[64]u32` stack, no alloc — wasm
    safe). `nodesFromBytes` / `triPermFromBytes` reinterpret vmesh BVH
    section in place.
  - **vmesh v3**: 56-byte header gains `bvh_off`, `bvh_node_count`,
    `name_table_off`, `name_count` (fields @40–@55). BVH nodes +
    tri-perm appended after texture blob (16-aligned). Name table: 12
    bytes/entry (FNV-1a-32 hash, absolute blob offset, blob_len), then
    UTF-8 name blob. Entry index == submesh index. `gl_asset_gen` bakes
    BVH + names at build time; `gltf.zig` extracts mesh/node names with
    `"mesh{n}"` fallback. v1/v2 files hard-rejected by the reader.
  - **GPU resource registry** (`registry.zig`): `Registry(cap)` — fixed
    comptime capacity, freestanding. `record{Buffer,Shader,Texture,
    TextureEx}` mirror each `CREATE_*` issue. `replay(enc)` re-emits all
    records into an `Encoder` on context restore. `overflowed()` signals
    capacity exhaustion. Asset-region pointers remain valid across
    context loss for the page lifetime.
  - **DELETE_RESOURCE wire tag 14**: `Encoder.deleteResource(kind,
    handle)` — payload 8 bytes (`kind u32`, `handle u32`; 0=buffer,
    1=texture, 2=shader). Bridge frees the GPU object and nulls the
    handle slot. Issued on island unmount and resource replacement. P3
    bytes untouched — P4 is strictly additive.
  - **GPU lifecycle management**: bridge `disposeGlState` on island
    unmount (`canvas.isConnected`) and when frame export returns 0.
    `webglcontextlost` (preventDefault, loop stopped) and
    `webglcontextrestored` (handle arrays reset, `<frame>_restore` called,
    loop resumed). Poster swap: `img[data-gl-poster]` hidden on first
    non-empty `interpret()`, restored on context loss or no-WebGL2.
  - **`ctx.glScene` declarative builder** (`src/core/gl_scene.zig`):
    fluent `GlSceneBuilder` — `.camera(opts)`, `.light(opts)`,
    `.autoRotate(rad_s)`, `.onPick(name, closure_id)` (cap 4), `.build()`
    → `*verve.Node`. Emits `<div>` wrapper, `<canvas>` with orbit/pick
    event handlers, optional `<img data-gl-poster>`, wrapped in the
    `GlScene` island marker. Props positional contract: `src`, `env`,
    `orbit_distance`, `orbit_pitch`, `orbit_yaw`, `auto_rotate`,
    `light_dir_x/y/z` (scalars — codec lacks fixed arrays),
    `light_intensity`, `pick_names[]`, `pick_event_ids[]`.
  - **`GlScene` island chunk** (`src/client/islands/GlScene.zig`,
    ~33 KB wasm): orbit drag/wheel via pointer capture, click pick +
    frame-throttled hover (`data-gl-pick` / `data-gl-hover` attrs +
    `dispatchEvent` closure ids). Model identity; camera orbits.
    `glscene_frame_restore` export triggers `registry.replay` on next
    frame. `/gl-scene` demo route: declarative orbit + auto-rotate +
    picking.
- **`verve.gl` P3 — PBR metallic-roughness über-shader, image-based
  lighting, directional/point lights, ACES tonemap** (`src/core/gl/`,
  `src/client/asset_region.zig`): Cook-Torrance GGX + split-sum IBL +
  ACES comptime über-shader with `variant_pbr` / `variant_normal_map` /
  `variant_emissive` sub-bits; four new wire tags (`CREATE_TEXTURE_EX`,
  `SET_LIGHTS`, `BIND_IBL`, `DRAW_PBR`); uniform/sampler contract
  (slots 0–4 material, 5/6/7 IBL); material block 12 f32; up to 4
  lights × 8 f32. vmesh v2: stride-48 vertices (pos/normal/tangent4/uv),
  72-byte PBR submesh records, build-side tangent generation. `.venv`
  prefiltered environment format: RGBA16F-only irradiance 32² + 6-mip
  specular 128² + BRDF LUT 64² — prefilter runs at build time (~3.6 s).
  Dedicated 4 MB page-scoped client asset region (`verve_asset_alloc /
  reset / used`) replaces chunk arena for large fetched assets. FNV-64
  GLSL hash goldens freeze all PBR shader permutations; venv hostile
  tests; prefilter numerics tests. sRGB decode in-shader (pow 2.2) for
  base-color and emissive only. Demo `/gl` route: full-variant PBR cube
  under studio IBL + warm dir light + cool point light.
- **`verve.gl` — native 3D engine, phases P1–P2** (new, `src/core/gl/`):
  pure-Zig scene graph (SoA, pre-order dirty propagation), column-major
  f32 math, and a flat binary command stream walked by a small WebGL2
  interpreter in the bridge — zero-copy typed-array views over linear
  memory, byte layout frozen by golden tests (`command.zig`). Unlit
  vertex-color and textured/lit shader variants. Guide: `docs/24-gl.md`;
  demo: the `/gl` route.
- **`verve.gl` asset pipeline**: build-time `.glb` → packed `.vmesh`
  (`tools/gen_demo_glb` + `tools/gl_asset_gen`, wired into `build.zig`,
  served at `/gl/<name>.vmesh`); pure-Zig PNG decode/encode, glb parser,
  and a freestanding zero-parse `.vmesh` reader — all hardened against
  hostile input. Runtime fetch into the chunk arena via the `gl_load`
  chunk import.
- **Windows ARM64 cross-compile gate**: `zig build win-native-arm64`
  (artifacts under `zig-out/bin/arm64/`). Both WebView2 loader DLLs
  (x64 + arm64, SDK 1.0.3967.48) are now vendored — fresh clones build
  and run the smoke without manual DLL placement. Native-host smoke and
  the scaffolded desktop app hardware-validated on Windows x86-64 and
  ARM64.

### Fixed

- **`verve.gl` fixture cube winding** (`src/core/gl/fixture.zig`): the
  ±X and ±Y faces of the procedural unit cube had CW vertex order since
  P2, causing backface culling to discard the exterior surfaces — the
  cube rendered inside-out. Corrected to CCW in commit e1818c2.
- Win-native smoke page now loads over the boot `verve://` navigation
  (asset-table entry) instead of racing it with `loadHtml` — exercises
  the embedded asset router on hardware.
- `vtSlot` COM helper: `@alignCast` required by aarch64.

### Known limitations

- Island chunks all link static data at the same base in the shared
  linear memory: at most **one stateful chunk per page** (the `/gl` demo
  drives both canvases from a single chunk for this reason). Framework
  fix (per-chunk data regions) planned.

## [0.4.0] - 2026-06-11

The animation release: a complete GSAP-class animation engine
(`verve.anim`) — core tweens/timelines plus the full plugin set
(ScrollTrigger with snap, Observer, ScrollSmoother, MotionPath,
MorphSVG, Draggable with drop zones, SplitText, FLIP) — pure Zig with
one hand-written JS interpreter, wire format frozen by golden +
conformance tests. Guide: `docs/23-animation.md`; runnable demos: the
`/anim` and `/smooth` routes.

### Added

- **`verve.anim` — core animation engine** (new, `src/core/anim/`):
  tweens, timelines (labels + position arithmetic), keyframes-in-tween,
  31 easings, grid/distribution stagger, snap/clamp/wrap + wasm fn
  modifiers, dynamic per-target end values, and a control API
  (pause/play/reverse/restart/seek/seekLabel/timeScale/kill). Hybrid
  execution: Zig builds + serializes `"v":1` descriptors
  (`serialize.zig` golden tests are the wire contract); a verve.js
  interpreter owns the rAF loop and composes one `style.transform`
  write per element per frame. Two surfaces: declarative SSR
  `Node.animate(...)` (`data-anim`, no island needed) and imperative
  island `verve.animPlay(...)` → `AnimHandle`. Built-in
  `prefers-reduced-motion` handling (jump-to-end default, `.play` /
  `.skip` overrides, live media-query flips). Guide:
  `docs/23-animation.md`; demo: the `/anim` route.
- **`verve.anim` ScrollTrigger** (`src/core/anim/scroll.zig`, wire key
  `"sc"`): gate tweens/timelines with GSAP-style toggle actions, scrub
  progress to the scrollbar (exact or smoothed), pin elements with
  layout-preserving spacers, zero-wasm class-toggle reveals
  (`anim.reveal`), debug markers, and island callbacks
  (`verve.scrollCallbacks` / standalone `verve.scrollTrigger` →
  `ScrollTriggerHandle`). Vertical window scroll in v1; geometry cached
  as document-space pixels, re-measured on resize/load/fonts.
- **`verve.observe` Observer** (islands): unified wheel/touch/
  pointer-drag/scroll input with ring-buffer velocity tracking, axis
  lock, tolerance, and preventDefault control — substrate for future
  ScrollSmoother/Draggable.
- **`verve.setRefStyle`** — per-handle inline style setter
  (`el.style.setProperty`) alongside `setRefAttr`.
- **`verve.anim` MotionPath + MorphSVG** (`src/core/anim/path.zig`):
  full SVG path parser (relative commands, S/T reflection, arcs with
  compressed flags) normalizing to cubic Béziers, arc-length sampling,
  and morph matching (winding auto-reverse, de Casteljau count
  equalization, cyclic alignment) — all Zig-side, freestanding-safe.
  `.motionPath(.{ .path = d, .rotate = true })` animates along any path
  (viz `edgePathD` output plugs in directly) through the shared
  transform composer; `.morph(.{ .from, .to })` lerps matched
  control-point arrays into per-frame `d` rebuilds. Wire keys `"mp"` /
  `"mo"`; both compose with timelines, stagger, and ScrollTrigger scrub
  as pure phase functions. Conformance: serializer goldens +
  `node tests/js/anim_conformance.mjs`.
- **`verve.anim` SplitText** (`src/core/anim/split.zig` +
  `Node.splitText(.{ .by = .chars })`): server-side text splitting into
  animatable spans — chars/words/words_and_chars cost zero JS; `lines`
  emits word spans the bridge groups by offsetTop at hydrate (before
  animations resolve targets). One `aria-hidden` wrapper + parent
  `aria-label` keep screen readers reading the original sentence;
  whitespace preserved verbatim so wrapping is unchanged. Composes with
  stagger + ScrollTrigger for typographic reveals.
- **`verve.anim` FLIP** (`verve.flipCapture`/`flipPlay`, island-only):
  First-Last-Invert-Play layout animation — capture rects, mutate the
  DOM (the keyed reconciler's identity-preserving moves are the fast
  path; `data-vkey` matching covers recreated nodes), invert
  synchronously through the shared transform composer, ease to identity
  in the ticker. Entered elements fade in; per-element stagger; single
  on_complete; reduced motion = instant no-op with callback.
- **`verve.anim` Draggable** (`src/core/anim/drag.zig`, wire root
  `"dr"` / `data-drag` attribute): pointer drag with grip handles, axis
  lock, per-gesture bounds (selector or translate-space rect), grid /
  nearest-point snap, and inertia throws (analytic endpoint projection —
  exponential friction integrated in closed form, endpoint clamped and
  snapped, so flicks decelerate exactly onto the grid; no bounce). 3px
  engage threshold keeps inner clicks alive; touch-action set per axis
  at create; reduced motion keeps dragging but lands releases instantly.
  SSR `node.draggable(anim.draggable(a, .{...}))` (zero-wasm) and island
  `verve.draggable(cfg, cbs)` → `DragHandle` (kill/disable/enable/setPos
  + x/y/velocity/isDragging/isThrowing). Position writes share the anim
  transform composer, so rotate/scale tweens compose with an active drag.
- **`verve.anim` ScrollSmoother** (`src/core/anim/smoother.zig` +
  `Node.smoothScroll(.{ .smooth = 1.2 })`, completing the GSAP-class
  spec): native-scroll-preserving inertia — a viewport-fixed wrapper +
  content translated by the smoothed scroll + a body-height spacer keep
  the scrollbar, keyboard, anchors, and a11y fully native while the
  visual eases. ScrollTrigger math switches to the smoothed position;
  pins become transform counter-translations (fixed breaks inside
  transformed content); `data-speed`/`data-lag` parallax
  (`Node.parallaxSpeed`/`parallaxLag`); touch native by default;
  reduced motion fully disables. Island getters `verve.smootherY` /
  `smootherVelocity` / `smootherActive`. Demo: the `/smooth` route.
- **`verve.anim` ScrollTrigger snap** (`.snap = .{ .step = 1.0/3.0 }`
  or `.{ .points = &.{...} }` + `.snap_duration`): when input goes idle
  inside a trigger's span, the NATIVE scroll glides (outCubic) to the
  nearest progress point — nearest candidate across triggers,
  direction-biased ties, user input cancels; composes with the smoother
  by construction. Wire keys `"snap"`/`"snapd"`.
- **`verve.anim` polish batch**: islands can morph FROM a live shape —
  new `verve_ref_attr_len`/`verve_ref_get_attr` ops +
  `verve.refGetAttrArena(handle, "d")` (probe-then-copy, never
  truncates); MotionPath `.align_to = .start` re-bases the polyline on
  its first sample (motion starts at the element's current position —
  fixes the raw-absolute-coordinates footgun); Draggable drop zones
  (`.zones` selector + `.zone_class` hover styling + `on_drop` with
  `DragHandle.dropZone()/hoverZone()`, page-coord per-gesture
  hit-testing, drop decided at release before any throw); FLIP
  `on_enter`/`on_leave` callbacks (fire synchronously inside play, also
  under reduced motion, before `on_complete`).

## [0.3.0] - 2026-06-10

The visualization release: a complete pure-Zig chart + graph library
(`verve.viz`), live data streaming over a new server-push hub, and a
breaking rework of how island chunks share the wasm function table.
Guide: `docs/22-visualization.md`; runnable demos: the `/viz` route and
`examples/viz-live/`.

### Added

- **`verve.viz` — native visualization library** (new, `src/core/viz/`,
  zero deps, SVG-as-`Node`-tree so every chart renders with JS off):
  - **Scene model** — resolution-independent `Shape` union
    (circle/rect/line/polyline/path/text/group) + `Style`, serialized
    through the normal renderer (`viz.sceneToNode`). Scales (linear with
    invert, band, log, time) with nice-tick generation and an axis builder.
  - **15 chart types** — bar, stacked bar, grouped bar, line, area,
    scatter, pie/donut, candlestick (OHLC), box plot (+ `boxStats`),
    heatmap, radar, violin (Gaussian KDE), **sankey** (longest-path
    layering + barycenter ordering, cubic ribbon links), **treemap**
    (squarified, Bruls 2000, flat parent-index hierarchy), **chord**
    (d3-convention group arcs + quadratic ribbons).
  - **Graph layouts** — tidy tree, radial, deterministic force-directed,
    and layered DAG with Sugiyama crossing minimization
    (`dag_crossing_iterations`) and virtual-node routing for long edges
    (`dagLayoutRouted`).
  - **Edge routing** — `GraphOpts.edge_routing = .straight | .curved |
    .orthogonal`: Catmull-Rom splines or Manhattan runs with rounded
    corners through the reserved virtual-node channels; `viz.edgePathD`
    is the low-level path builder.
  - **Interactive graph island** (`VizGraphInteractive`) — wheel zoom
    toward the cursor, pointer-captured pan + node drag (gestures survive
    leaving the svg), hover tooltips, click select, **double-click
    subtree collapse** (BFS visibility, `+N` hidden-descendant badge,
    composes with live updates), and runtime add/remove of nodes under
    **any layout**: force relaxes incrementally; tree/radial/dag
    recompute client-side via the new `viz_core` chunk module
    (`geom.fitBox`/`applyFit` keep SSR↔client positions bit-identical)
    and tween survivors over 24 eased frames.
  - **Live data over SSE push** — the server diffs its graph
    (`viz.diffGraphs`) and broadcasts seq-ordered wire deltas
    (`{"seq":N,"ops":[…]}` via `viz.writeDeltaJson`; canonical apply
    semantics in `viz.applyDeltaOps`); the island applies frames in seq
    order and resyncs from the seq-stamped pull snapshot on any gap.
    Polling fallback when EventSource is unavailable.
- **Server push hub** (`src/server/push.zig`) — `push.publish(channel,
  bytes)` broadcasts to every subscriber of `GET /push?channel=<name>`
  (SSE): 32-frame resume ring with `Last-Event-ID` replay, a resync
  control frame when a subscriber falls out of the window, and
  `push.subscriberCount` so publishers can idle. Transport-agnostic hub;
  an app opts into the framework's once-per-second publisher thread by
  declaring `pub fn vizAdvanceTick(buf: []u8) ?[]const u8`.
- **Client runtime, phase 7** (`docs/20-client-runtime.md`):
  - `pushSubscribe(channel, island, export)` / `pushUnsubscribe` —
    deliver SSE frames to a NAMED chunk export; `fetchToExport(api,
    island, export)` — one-shot POST→export (the resync hook).
    Host-call based, zero function-table entries.
  - **Pointer capture** — `eventCapturePointer()` flags the bridge to
    `setPointerCapture` the handler's element; new delegated
    `pointercancel` + `dblclick` events with `Node.onPointerCancel` /
    `onDblClick` stamps; `eventDeltaY()` / `eventButton()` accessors and
    `Node.onWheel` / `onPointer*` stamps (landed earlier in the cycle).
  - `verveRafNamed` host fn — a JS `requestAnimationFrame` loop driving a
    named chunk export (`fn () i32`, nonzero continues).
  - `viz_core` chunk module — the pure-math slice of `verve.viz`
    (geometry, layouts, interaction, edge paths) importable by chunks.
- **`examples/viz-live/`** — minimal standalone app for the
  push-streaming stack (push hub → wire deltas → seq-ordered apply →
  snapshot resync), reusing the framework's interactive island chunk via
  a build-time source-fallback chain.
- **App test suite** — `src/app/api.zig` test blocks now actually run:
  `zig build test` gained a dedicated app-module artifact (Zig collects
  tests only from a compilation's root module, so the previous in-file
  tests were silently dead).
- Integration tests for `/push` (ordered delta stream, bad-channel 400,
  `Last-Event-ID` resume without replay).

### Changed

- **BREAKING: wasm function-table isolation** (replaces the Phase 13G
  shared table). The main client now **imports** a JS-owned growable
  `__indirect_function_table` (`build.zig`: `import_table = true`, was
  `export_table`); every island chunk instantiates against a **private**
  table; the bridge's `makeChunkRuntime` translates each fn-pointer
  index crossing into the main runtime (`registerEvent`, `cleanup`,
  response/drop handlers, the four timer fns) into a freshly grown
  main-table slot. Previously a chunk's element segment wrote into the
  shared table at the same slots as the main client's own entries —
  "function signature mismatch" crashes as soon as a chunk's
  address-taken function set grew. **Anything that instantiates
  `client.wasm` must now supply `env.__indirect_function_table`**: the
  web bridge, the desktop template (`verve_desktop.js`), and all example
  builds are updated; custom hosts must follow suit.
- **BREAKING: `VizGraphInteractive.Props`** gained `ids`, `layout`, and
  `margin` fields (the props codec is positional — chunk mirrors must
  match field order).
- The demo `vizGraph` server-fn snapshot is now seq-stamped
  (`{seq, nodes, edges}`) and a pure read — the model only advances via
  the publisher thread, so pull-only clients see a stable graph.
- `/viz` demo expanded: edge-routing A/B/C cards, sankey/treemap/chord
  cards, a "⟳ layout" cycle button, and SSE-push live streaming behind
  the "● live" toggle.

### Fixed

- Drag/pan gestures no longer end when the pointer crosses the svg edge
  — pointer capture keeps them alive; gestures end on `pointerup` /
  `pointercancel`, never `pointerout`.
- The framework server no longer hard-requires `app.vizAdvanceTick` —
  the publisher thread is `@hasDecl`-gated, unbreaking downstream app
  builds (islands-demo, client-runtime, showcase, scaffolds).
- The latent function-table clobber affecting every chunk with
  address-taken functions (e.g. JsonProbe's 14 element slots) is
  eliminated by table isolation.

### Upgrade notes

- **Custom wasm hosts**: create a growable table and pass it at client
  instantiation — `new WebAssembly.Table({ initial: 256, element:
  "anyfunc" })` as `env.__indirect_function_table`. Apps using the stock
  `verve.js` / `verve_desktop.js` bridges need no changes; re-vendor the
  bridge + `build.zig` (or re-scaffold) to pick the rework up.
- **Example-style builds**: flip the main client from
  `wasm.export_table = true` to `wasm.import_table = true`; chunks keep
  `import_table = true`.
- **Apps with island chunks mirroring `VizGraphInteractive.Props`**:
  append the new `ids` / `layout` / `margin` fields in order.

## [0.2.0] - 2026-06-07

### Changed

- **All three desktop backends now real-hardware validated** — macOS
  (aarch64, live since v0.1.9), Linux GTK4 + WebKitGTK 6.0 (aarch64,
  2026-06-06), and Windows 11 + WebView2 (2026-06-07, v0.1.42 fixes).
  First release where "it works on all three platforms" is a verified
  claim rather than a cross-compile assumption.

### Known limitations

- Desktop auto-updater apply: macOS only; Win/Linux pending signing-infra decision.
- Full a11y provider (UIA Win + ATK Linux): beyond current `setAccessibilityLabel`.
- Linux image clipboard (`writeImage` / `readImage`): returns `Unsupported`.
- Silent print on Windows: `ShowPrintUI` only (advisory print settings).
- Global hotkeys Linux: X11 only; Wayland stub returns `Unsupported`.

## [0.1.42] - 2026-06-07

### Fixed

- **Windows desktop scaffold: first real-hardware boot** — the Bundle 9 native
  WebView2 host had only ever been cross-compiled; running a scaffolded
  `--desktop` app on real Windows 11 surfaced five Windows-only defects (all in
  code paths the macOS/Linux CI never compiles), now fixed:
  - **`ICoreWebView2CustomSchemeRegistration::SetAllowedOrigins` signature** —
    the vendored `WebView2.h` declares the 2nd parameter as `LPCWSTR *`, not
    `LPWSTR *`; the mismatch left the COM class abstract and failed to compile.
  - **`notifications.zig` non-exhaustive switch** — the Windows balloon-fallback
    switch over `tray.Error` omitted the (macOS-only) `ObjcClassMissing` variant,
    a compile error on the Windows path.
  - **Blank webview (`E_INVALIDARG`)** — `VerveEnvironmentOptions.
    get_TargetCompatibleBrowserVersion` returned an empty string, so
    `CreateCoreWebView2EnvironmentWithOptions` rejected the options object
    (`0x80070057`) and the window showed an error dialog over a blank page. Now
    reports the SDK target version (`148.0.3967.48`, matching
    `CORE_WEBVIEW_TARGET_PRODUCT_VERSION` in the vendored
    `WebView2EnvironmentOptions.h`).
  - **Query-string navigations failed (`ERR_INVALID_RESPONSE`)** — the
    `verve://app/...` scheme handler passed the raw URL path (including `?query`)
    to the asset router, so any navigation carrying a query string (e.g. the
    smoke harness's `index.html?smoke=1`) missed the asset table. The host now
    trims `?`/`#` before lookup, matching macOS's `NSURL.path`.
  - **IPC entirely non-functional** — Windows injected only a minimal
    `window.verve = { post }` document-start script and never the shared
    `ipc.zig` shim, so `window.verve.send` / `request` / `onMessage` were
    undefined and every IPC round-trip (server-fns, the demo "Send ping", the
    smoke driver, the minimal template's "Greet") silently no-op'd. Added a
    `wv2_add_user_script` host ABI; `windows_native.zig` now injects
    `ipc.shim_js` at document-start (mirroring macOS's `WKUserScript`) and
    intercepts the `__verve_title:` marker for native title sync.
- **`desktop.updates` Windows build** — `applyUpdateWindows` used
  `std.process.getEnvVarOwned`, removed in Zig 0.16's io-based process API,
  which broke the desktop test compile on Windows. Reads `%TEMP%` via
  `GetEnvironmentVariableW` instead.
- **Linux GTK4: WebKitGTK 6.0 sandbox** — `webkit_web_context_set_sandbox_enabled`
  was removed in WebKitGTK 6.0; the sandbox is now disabled via
  `g_setenv("WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS", …)`
  (`std.c.setenv` is absent in Zig 0.16.0), which also fixes VMs / kernels with
  unprivileged user namespaces disabled.
- **Linux GTK4: drag-drop loaded the file instead of firing the callback** —
  the `GtkDropTarget` is now attached to the `WebKitWebView` (higher priority
  than the window), and the `decide-policy` handler ignores
  `WEBKIT_NAVIGATION_TYPE_OTHER` navigations **only** when the URI starts with
  `file://`. The earlier type-only check also swallowed the initial
  programmatic `verve://` page load (white screen).
- **macOS: ObjC error handling** — unrecoverable ObjC failures now `@panic`
  with descriptive messages instead of being swallowed, and tray init returns a
  name-specific error so callers can degrade gracefully.
- **Client runtime capacity** — raised the static-array slot limits
  (`MAX_SLOTS` 256→1024, `MAX_ISLAND_OWNERS` 64→256, `MAX_EVENT_SLOTS`
  1024→4096, `MAX_RESPONSE_SLOTS` 256→1024) so production apps don't hit
  capacity under normal workloads; capacity-exceeded panics now name the
  constant + file to raise.

### Added

- **`tools/validate_scaffold_windows.ps1`** — local regression guard that
  reproduces the CI scaffold → build → verify for both the `full` and `minimal`
  `--desktop` templates. The full template's gate runs `app.exe --smoke` and
  requires `checksum.txt` + a clean self-terminate (page load + WASM hydration +
  IPC round-trip + webview snapshot), catching blank-webview / broken-IPC
  regressions that the per-app screen-capture `smoke_windows.ps1` silently
  passes.
- **Desktop template: drag-drop demo** — the `--desktop` scaffold now wires
  `setDragDropHandler` in `main.zig` with an `onDragDrop` handler in
  `handlers.zig` that logs each dropped path and calls
  `window.verve.handleDragDrop` for the demo. (`onDragDrop` takes
  `[]const []const u8`, not a NUL-terminated pointer.)
- **Linux GTK4: window-chrome accessibility** — `setAccessibilityLabel` /
  `setAccessibilityHelp` implemented via `gtk_accessible_update_property_value`
  (`g_value_set_string` copies the string, so the stack buffer is safe after
  the call).

### Changed

- **Docs: API stability tiers** — `src/verve.zig` now splits its exports into
  **Stable** and **Internal** sections with a module-level policy explaining
  what each tier means for app code vs framework tooling.
- **Chore** — `.worktrees/` added to `.gitignore`.

### Upgrade notes

- **Desktop apps (Windows + Linux GTK4)**: re-vendor `src/desktop/` (re-run
  `verve-cli new`, or copy the tree) to pick up the WebView2 host + IPC-shim
  fixes and the GTK4 sandbox/drag-drop fixes. No app-level source changes
  required. To adopt the new drag-drop demo, re-scaffold or copy the
  `setDragDropHandler` wiring from `templates/desktop/src/{main,handlers}.zig`.

---

## [0.1.41] - 2026-06-06

### Fixed

- **Linux GTK4: live validation on aarch64 Linux** — first real-hardware boot
  of the `-Dgtk4=true` backend (aarch64, WebKitGTK 6.0 / libsoup 3). Multiple
  API incompatibilities surfaced and resolved:
  - **`SnapshotError` set mismatch** — `error.Backend` and `error.OutOfMemory`
    returned from `takeSnapshotPng` are not members of `SnapshotError`. Mapped
    to `CaptureFailed` / `EncodeFailed` / `WriteFailed` as appropriate.
  - **libsoup 3 cookie API** — `SoupDate` and `soup_date_*` removed in libsoup
    3; migrated `marshalCookie` / `buildSoupCookie` to `GDateTime` +
    `g_date_time_new_from_unix_utc` / `g_date_time_to_unix` /
    `g_date_time_unref`. Updated `soup_cookie_get/set_expires` signatures.
  - **WebKitGTK 6.0 script-message callback** — `WebKitJavascriptResult` and
    `webkit_javascript_result_get_js_value` removed; `script-message-received`
    now delivers `JSCValue *` as the second argument directly. Updated
    `onScriptMessage` and `ScriptMessageCallback` type alias.
  - **Snapshot stub** — `webkit_web_view_snapshot[_finish]` absent in installed
    webkitgtk-6.0; `takeSnapshotPng` returns `error.Unsupported`. Dead
    `SnapshotCell` / `onSnapshotDone` removed.
  - **Tray GTK4 conflict** — `libayatana-appindicator3` links GTK3
    (`libgdk-3.so`); loading it in a GTK4 process double-registers GLib types
    and segfaults. `LinuxTray.bareInit` now returns `error.Unsupported` when
    built with `-Dgtk4=true`.
  - **Cookie async lifetime** — `GetAllCookiesCell` stored a raw `GAsyncResult
    *` past the callback boundary; GLib frees the GTask after the callback
    returns, leaving a dangling pointer and a failing `g_task_is_valid`
    assertion. `webkit_cookie_manager_get_all_cookies_finish` is now called
    inside `onGetAllCookiesDone` with the source manager. Cell now stores the
    resulting `GList *`, matching the pattern used by file/alert dialog
    callbacks.
  - **WebKit sandbox** — `bwrap` crashes on kernels where unprivileged user
    namespaces are disabled (`kernel.unprivileged_userns_clone=0`).
    `webkit_web_context_set_sandbox_enabled(ctx, 0)` is called after context
    creation, removing the need for `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS`.

### Changed

- **Linux GTK4 scaffold docs** — `templates/desktop/README.md` and
  `templates/desktop-minimal/README.md` now document GTK4 prerequisite packages
  (`libgtk-4-dev libwebkitgtk-6.0-dev` / `gtk4-devel webkitgtk6.0-devel`), the
  `-Dgtk4=true` build flag, and known GTK4 limitations (tray + snapshot return
  `error.Unsupported`). Platform support matrix corrected: Linux snapshot was
  incorrectly `✓` (now `stub`); Linux tray entry now shows
  `✓ GTK3 / stub GTK4`.

### Upgrade notes

- **GTK4 apps**: re-vendor `src/desktop/` to pick up the libsoup 3 and WebKit
  callback fixes. No app-level source changes required.

---

## [0.1.40] - 2026-06-05

### Fixed

- **Windows `verve://` top-level navigation (blank webview).** The previous
  release added `AddWebResourceRequestedFilter` but omitted the required
  `ICoreWebView2EnvironmentOptions4::SetCustomSchemeRegistrations` call at
  environment creation time. WebView2 silently rejects `Navigate("verve://…")`
  for any scheme that wasn't pre-registered — the filter alone only intercepts
  sub-resource requests from existing `http/https` pages, not the navigation
  document itself. Fixed by:
  - `CustomSchemeRegistration`: minimal `ICoreWebView2CustomSchemeRegistration`
    implementation. `TreatAsSecure = TRUE` (enables WASM, `window.crypto`, and
    other secure-context APIs). `HasAuthorityComponent = TRUE` (correct for the
    `verve://app/…` URL structure where `app` is the authority).
  - `VerveEnvironmentOptions`: minimal `ICoreWebView2EnvironmentOptions` v1–v4
    chain. Only v4 `GetCustomSchemeRegistrations` has a real body; all other
    property getters return safe defaults. WebView2 QIs through the version
    chain and uses whatever is present.
  - `wv2_run`: constructs `VerveEnvironmentOptions` when a scheme handler is
    registered and passes it as the third argument to
    `CreateCoreWebView2EnvironmentWithOptions` (was `nullptr`).
  - `ControllerHandler`: QIs `ICoreWebView2_22` to use
    `AddWebResourceRequestedFilterWithRequestSourceKinds(…,
    SOURCE_KINDS_ALL)` so document-level requests are also intercepted.
    Falls back to the base `AddWebResourceRequestedFilter` on older WebView2
    runtimes that don't expose `ICoreWebView2_22`.
- **Stale "spike" strings removed** from `webview2_host.cpp` file header and
  error dialog captions.

### Upgrade notes

- **No app source changes.** Re-vendor `src/desktop/win_native/webview2_host.cpp`
  to pick up the fix. Apps scaffolded from 0.1.39 will have the broken version;
  apps scaffolded from 0.1.40 onward will be correct.

## [0.1.39] - 2026-06-05

### Added

- **Linux GTK4 + WebKitGTK 6.0 backend (`-Dgtk4=true`).** A full parallel
  Linux backend (`src/desktop/linux_gtk4.zig`, ~2000 lines) targets GTK 4 +
  WebKitGTK 6.0 — the stack shipping by default on Ubuntu 24.04 LTS and
  Fedora 41+. The existing GTK3 + WebKitGTK 4.1 path is unchanged. Enable
  with `-Dgtk4=true` at build time:
  ```
  zig build run -Dgtk4=true
  ```
  The GTK4 backend covers the full `Window` surface at parity with macOS and
  Windows: window lifecycle (GMainLoop), navigation, window chrome, IPC
  (`webkit_web_view_evaluate_javascript`), cookies via `WebKitNetworkSession`,
  clipboard via `GdkClipboard` (async API), file/alert dialogs
  (`GtkFileDialog` / `GtkAlertDialog`, GTK 4.10+), drag-and-drop
  (`GtkDropTarget`), focus events (`GtkEventControllerFocus`), resize via
  `notify::default-width/height`, color-scheme, deep link, print, snapshot
  (WK6 `GdkTexture` path — no Cairo), and accessibility. Live validation on
  Ubuntu 24.04 is in progress.

- **Linux GTK3 image clipboard.** `Clipboard.writeImage` / `readImage` are
  now implemented on GTK3 via `GdkPixbuf` (loader → `gtk_clipboard_set_image`
  on write; `gtk_clipboard_wait_for_image` → `gdk_pixbuf_save_to_bufferv` on
  read). No extra linker line needed — `gdk-pixbuf-2.0` is a transitive dep
  of `gtk+-3.0`.

- **Windows `verve://` asset-serving scheme handler.** `wv2_set_scheme_handler`
  added to `host.h` / `webview2_host.cpp`. The native C++ host now registers
  `AddWebResourceRequestedFilter("scheme://*")` once the WebView2 controller
  is ready; `SchemeRequestHandler` resolves paths via the Zig `asset_router`,
  copies bytes through `SHCreateMemStream`, and sets `Content-Type` headers.
  `windows_native.zig` wires the handler in `init()` + `openChildWindow()` and
  queues the initial `verve://app/<initial_path>` navigation. Previously the
  Windows native backend loaded no assets (the `opts.assets`, `opts.scheme`,
  and `opts.initial_path` fields were silently ignored).

### Fixed

- **GTK4 geometry hints.** `gtk_window_set_geometry_hints` was removed in
  GTK4; replaced with `gtk_widget_set_size_request` for minimum size
  constraints.
- **WK6 snapshot API.** `webkit_web_view_get_snapshot` is a WebKitGTK 4.1
  API; WK6 uses `webkit_web_view_snapshot` returning `GdkTexture*` (no
  Cairo surface). `takeSnapshotPng` rewritten to the `GdkTexture` → RGBA →
  `GdkPixbuf` → `gdk_pixbuf_save_to_bufferv` path.
- **GTK4 cookie done-flags not atomic.** Async completion callbacks used
  plain assignment; replaced with `@atomicStore(.release)` /
  `@atomicLoad(.acquire)` to prevent the compiler hoisting the load out of
  the spin loop.
- **GdkPixbuf ABI bug (GTK3 image clipboard).** `gdk_pixbuf_save_to_buffer`
  is C variadic (`...`); on x86-64 SysV the variadic and non-variadic calling
  conventions differ, producing UB. Fixed by using `gdk_pixbuf_save_to_bufferv`
  (fixed-arity with `option_keys`/`option_values` arrays).
- **Borrowed pixbuf double-unref.** `gdk_pixbuf_loader_get_pixbuf` returns a
  borrowed ref owned by the loader; the extra `g_object_unref(pixbuf)` call
  corrupted the refcount. Removed.
- **Loader not closed on error path.** `gdk_pixbuf_loader_close` must be
  called before `g_object_unref(loader)` even when a write fails.
- Various GTK4 backend fixes: `g_file_get_path` result freed after DnD
  callback; both `notify::default-width` and `notify::default-height` signal
  IDs stored and disconnected; `stackFallback` used in `clipboardWriteText`
  (no allocator available at that call site); sentinel array double-null
  removed; `evaluate_javascript` callback param fixed from double-optional to
  single; `Window.deinit` no longer calls `alloc.destroy(self)` on a
  stack-allocated `Window`.

### Upgrade notes

- **GTK4 backend is opt-in.** Existing GTK3 builds are unchanged. To use
  GTK4, install `libgtk-4-dev` + `libwebkitgtk-6.0-dev` and pass
  `-Dgtk4=true` to `zig build`.
- **Windows asset serving** now works end-to-end. Apps scaffolded before
  0.1.39 should re-vendor `src/desktop/win_native/` to pick up
  `webview2_host.cpp` and `host.h` changes.
- **macOS desktop backend unchanged.**

## [0.1.38] - 2026-06-04

### Changed

- **Windows desktop backend reimplemented as a native C++ WebView2 host.**
  The previous backend was ~4000 lines of pure-Zig hand-rolled COM (vtable
  offsets transcribed by hand from `WebView2.h`). It is replaced by a native
  C++ host (`src/desktop/win_native/webview2_host.cpp`) behind a thin flat C
  ABI, with `src/desktop/windows_native.zig` as the Zig backend. The C++
  compiler generates the COM vtables from the real (vendored) `WebView2.h`, so
  there are no more hand-counted offsets. **The public `Window` / `desktop`
  API is unchanged** — this is an implementation + reliability change, not an
  API change. The Windows backend is now **verified on real Windows hardware**
  (it was previously cross-compile-only): window/webview lifecycle, the
  JS↔Zig bridge, geometry/state, navigation, events, drag-and-drop, dialogs,
  child windows, cookies, clipboard (text/HTML/image), print, snapshot,
  accessibility, tray, and notifications were all exercised on-device.

### Added

- **Windows HTML clipboard (`CF_HTML`).** `Clipboard.writeHtml` / `readHtml`
  now work on Windows (registered `HTML Format` with a byte-accurate `CF_HTML`
  header built by a unit-tested pure-Zig codec), so HTML pastes into Word /
  WordPad as formatted content. Linux remains `error.Unsupported`.

### Removed

- **NuGet WebView2 auto-vendor.** Windows builds no longer fetch the WebView2
  SDK from NuGet on first build. The SDK header and the x64
  `WebView2Loader.dll` are vendored in-tree under
  `src/desktop/win_native/include/`; the build compiles the native C++ host
  and ships `WebView2Loader.dll` next to the produced `.exe`. Scaffolded
  `--desktop` apps build offline with no network step. The
  `tools/fetch_webview2.{sh,ps1}` scripts are gone.

### Fixed

- **Windows cookie/clipboard deadlock.** Synchronous cookie reads
  (`cookies().get()/delete()`) pump a nested message loop awaiting WebView2's
  async `GetCookies` completion. WebView2 serializes its event callbacks and
  will not fire the completion while a `WebMessageReceived` handler is on the
  stack, so calling these from inside the JS bridge deadlocked. Bridge
  messages are now delivered via a posted window message handled in `WndProc`,
  off the WebView2 callback stack.
- **Windows backend-selection segfault.** `cookies.zig` / `clipboard.zig`
  selected the desktop backend independently of `window.zig`; a `Window` from
  one backend could hand its native window pointer to a `CookieStore` /
  `Clipboard` that dispatched into the other, dereferencing a foreign pointer.
  Backend selection is now single-sourced in `src/desktop/backend.zig`.

### Upgrade notes

- **No app source changes** — the desktop `Window` / `desktop` API is unchanged.
- **Existing scaffolded `--desktop` apps** (generated before 0.1.38) carry a
  vendored copy of the framework's `src/desktop/` plus the old template
  `build.zig`. To pick up the native host, **re-scaffold** with the 0.1.38
  `verve-cli` (or re-vendor `src/desktop/` + the desktop `build.zig`). Old
  projects also still contain now-unused `tools/fetch_webview2.{sh,ps1}` +
  `tools/webview2.pinned.txt` — safe to delete.
- **Windows runtime**: requires the Microsoft Edge WebView2 Evergreen Runtime
  (preinstalled on Windows 11; on Windows 10 install Microsoft's bootstrapper).
  The build ships `WebView2Loader.dll` next to the `.exe`.
- **macOS and Linux desktop backends are unchanged.**

## [0.1.37] - 2026-06-02

### Added

- **Windows image clipboard (`CF_DIBV5`).** `Clipboard.writeImage` /
  `readImage` now work on Windows, at parity with macOS. The cross-platform
  wire format stays raw PNG bytes; the backend transcodes PNG ↔ 32bpp-BGRA
  DIB through WIC (`Windowscodecs`) — write packs a bottom-up
  `BITMAPV5HEADER` blob under `CF_DIBV5`, read accepts `CF_DIBV5`/`CF_DIB`
  (24/32bpp, opaque-BGRX handling) and re-encodes to PNG. The pure
  `buildDibV5` / `dibToBgra` helpers are unit-tested. Linux remains
  `error.Unsupported`.

- **Windows accessibility UIA provider.** `setAccessibilityRoleDescription`,
  `setAccessibilitySubrole`, and `setAccessibilityHelp` are no longer no-ops
  on Windows: a per-window server-side `IRawElementProviderSimple` answers
  `WM_GETOBJECT`/`UiaRootObjectId` (`UiaReturnRawElementProvider`), mapping
  role description → `UIA_LocalizedControlType`, help → `UIA_HelpText`, and
  the `dialog`/`system_dialog` subroles → `UIA_IsDialog`;
  `UiaHostProviderFromHwnd` supplies Name/bounds and the WebView2 subtree.
  Links `Uiautomationcore`. Brings Windows to parity with the macOS
  NSAccessibility surface (Linux role-desc/subrole still pending an
  AtkObject provider).

- **Windows rich WinRT Toast.** `notifications.show` now prefers the modern
  Action Center toast over the legacy balloon: it sets a per-app AUMID
  (`SetCurrentProcessExplicitAppUserModelID`), lazily creates the Start-menu
  `.lnk` carrying `System.AppUserModel.ID` (IShellLink + IPropertyStore +
  IPersistFile), then activates an `XmlDocument` `ToastGeneric` template →
  `ToastNotificationManager` → `IToastNotifier::Show`. Falls back to the
  `Shell_NotifyIconW` balloon when WinRT activation fails. Links the WinRT
  API-set stubs (`api-ms-win-core-winrt-l1-1-0` +
  `api-ms-win-core-winrt-string-l1-1-0` — zig's mingw has no x86_64
  `combase` import lib); pure `buildToastXml`/`xmlEscape` unit-tested.

- **Windows auto-updater apply.** `updates.applyUpdate` now installs on
  Windows (previously macOS-only). Pure-Zig side-by-side swap: download +
  SHA-256 verify → extract via the bundled `tar.exe` to `%TEMP%` → spawn a
  detached `swap.cmd` that waits for the running PID, robocopy-/MOVEs the new
  tree over the locked install dir, relaunches, and self-deletes. Unsigned
  in-place replacement (not Squirrel/MSIX); `error.NotBundled` in the
  `\zig-out\` dev layout. `applyUpdate` now dispatches per-OS; the pure
  `buildSwapScript` is unit-tested. Linux apply remains `error.Unsupported`.

  All four Windows backends are hand-rolled COM/WinRT and verified by
  cross-compile (x86_64 + aarch64-windows) plus their pure-fn unit tests;
  live delivery (clipboard paste, screen-reader announce, Action Center
  banner, exe swap) is host-gated.

### Fixed

- **Example builds (`app_client` wiring).** All 11 `examples/*/build.zig`
  failed the wasm-client build with `no module named 'app_client'` after the
  shared `src/client/main.zig` began importing `app_client` for the typed
  `_call` round-trip demo — each example created the module but only wired it
  into the server, not the client. Each now adds
  `client_mod.addImport("app_client", app_client_mod)`; the codegen examples
  (`showcase`, `islands-demo`, `client-runtime`) additionally move the
  generated `app_client.zig` into a dedicated `WriteFiles` to avoid a
  `client → app_client → assets(client.wasm) → client` dependency loop. The
  shared client's demo call site is now guarded with
  `if (comptime @hasDecl(app_client, "incrementCount_call"))`, so it compiles
  against any app's generated or stub `app_client` instead of requiring an
  `incrementCount` server fn.

## [0.1.36] - 2026-06-02

### Added

- **Scaffold `zig build notarize` step (macOS).** A new desktop-template
  build step submits a signed + hardened `.app` to Apple's notary service
  via a `notarytool` keychain profile, staples the ticket, and leaves a
  distributable stapled zip: `ditto`-zip → `xcrun notarytool submit --wait`
  → `xcrun stapler staple` → re-zip the stapled `.app`. Gated on
  `-Dnotarize-profile=<name>` + `-Dcodesign=<Developer ID Application>`;
  requesting notarize implies the hardened runtime. The framework has no
  app of its own to notarize — each downstream app runs the step under its
  own Developer ID. Setup + usage in `docs/19-desktop.md`.

- **Windows `verve://` custom-scheme asset serving.** The Windows backend
  now serves the embedded asset table to WebView2 through a real registered
  custom scheme — an `ICustomSchemeRegistration` COM object supplied via
  `ICoreWebView2EnvironmentOptions4` (hand-rolled vtable +
  `CoTaskMemAlloc`-backed COM strings + `CreateStreamOnHGlobal` response
  streams), plus the `ICoreWebView2_22` web-resource-requested filter.
  This brings Windows to parity with macOS (`WKURLSchemeHandler`) and Linux
  (WebKit custom scheme) for `verve://app/*` requests.

### Fixed

- **Windows scaffold generation.** `verve-cli new` now writes a valid
  `build.zig.zon` on Windows: path relativization uses the platform-aware
  `std.fs.path.relative` (the POSIX variant mis-tokenized `C:\` drive paths
  into a bogus `../C:\…`), and backslashes in the generated `.path` literal
  are normalized to `/` (a backslash is a Zig string-escape character, and
  the build system accepts `/` separators on every host).

- **Windows WebView2 vendoring + runtime.** The scaffold's WebView2 fetch
  step falls back to Windows PowerShell 5.1 (`powershell`) when PowerShell 7
  (`pwsh`, an optional install) is absent, and now installs
  `WebView2Loader.dll` next to `app.exe` so the binary's load-time import
  resolves.

## [0.1.35] - 2026-06-02

### Added

- **Window-chrome accessibility provider (macOS).** Three new `Window`
  methods extend the desktop accessibility surface beyond the existing
  `setAccessibilityLabel`: `setAccessibilityHelp` (sets `AXHelp` — the
  supplementary description VoiceOver reads after the label),
  `setAccessibilityRoleDescription` (overrides the spoken role name), and
  `setAccessibilitySubrole(.standard | .dialog | .system_dialog |
  .floating)` (maps each tag to the matching `NSAccessibility*WindowSubrole`
  constant). macOS publishes them through `objc_msgSend`; Linux maps
  `setAccessibilityHelp` to `atk_object_set_description` and no-ops the other
  two; Windows no-ops all three (no UIA provider). Web content + native menus
  already self-publish their own accessibility tree, so they stay out of
  scope. New `AccessibilitySubrole` enum on the desktop surface.

### Changed

- **macOS notifications migrated to `UNUserNotificationCenter`.**
  `desktop.notifications.show` no longer uses the deprecated
  `NSUserNotification`. The macOS path now guards on the process being a
  bundled app (`[[NSBundle mainBundle] bundleIdentifier]`; an unbundled
  process returns `error.Unsupported`), lazily requests authorization on the
  first call and pumps a nested `NSRunLoop` until the grant resolves (caching
  it process-wide; a denied grant returns `error.Unsupported`), then delivers
  via `UNMutableNotificationContent` + `UNNotificationRequest` (nil trigger =
  immediate). The desktop scaffold links `UserNotifications.framework`. The
  cross-platform `show(allocator, opts)` surface is unchanged; the Linux
  (libnotify) and Windows (tray balloon) paths are untouched.

### Fixed

- **Client binding-walker now runs in island-free apps.** The JS auto-walker
  that registers `bindI32` / `bindStr` / `bindBool` / `bindF32` signals is
  gated on the wasm exporting `verve_island_scratch_ptr` /
  `verve_island_scratch_capacity`. Those accessors (and the backing scratch
  buffer) lived in the framework's `src/client/main.zig`, so an app shipping
  its own client entry without islands — e.g. a fresh desktop scaffold — never
  exported them: the walker silently skipped, no signals registered, and every
  reactive binding (the demo counter) was inert. The buffer + accessors moved
  to the shared `src/client/runtime_exports.zig` (force-included via
  `verve_client`), so every client entry now exports them. Both JS bridges
  (`verve.js`, the desktop `verve_desktop.js`) now `console.warn` when the
  walker is skipped instead of failing silently. A regression-guard test in
  the client suite keeps the accessors from drifting back out.

## [0.1.34] - 2026-06-02

### Added

- **Client-side value fetch (`fetchSignal`).** An island chunk whose value
  wasn't resolved at SSR (`islandStateValue` returns null — the resource was
  still loading, or it's a `LocalResource`) fetches it client-side:
  `verve.fetchSignal(T, action_name, args, signal_name)` posts a correlated
  server-fn request (`x-verve-rid`) and registers a one-shot settler that decodes
  the typed reply `value` via the chunk JSON service and sets the named,
  vid-scoped signal — `dispatchResponse` restores the island vid first, so two
  instances of one component never cross. `T` is the signal type
  (`i32` / `[]const u8` / `bool` / `f32`). On server error / no reply the signal
  keeps its loading value (error path deferred). This required extending Phase A's
  rid correlation to the **chunk runtime**: `verve_next_req_id` /
  `verve_register_response_handler_once` / `verve_server_fn_post_rid` are now
  exported to the `verve_runtime` namespace with matching chunk-façade wrappers —
  any chunk can do a one-shot correlated request → typed-reply loop, not just
  value fetches. Guide: `docs/15-islands.md`.

- **i18n lazy catalogs (`LazyCatalog`).** For very large multi-locale translation
  sets, an opt-in `LazyCatalog` ships each locale as a separate embedded JSON blob
  and parses + caches only the active (and default-fallback) locale on first
  lookup, mutex-guarded for the server worker pool. Fallback chain is
  locale → default → key. A build-time walker turns `i18n/<locale>.json` (flat
  `{ "key": "value" }`) into an `@embedFile`d `locales` manifest module —
  single-binary distribution preserved; missing dir degrades to an empty manifest.
  Options: `-Di18n-dir` (default `i18n/`), `-Di18n-default`. `resolveLocale` is now
  duck-typed (`catalog: anytype`) so it works with both `LazyCatalog` and the
  existing comptime `Catalog` (which stays the zero-cost choice for small sets).
  New public surface: `verve.I18nLazyCatalog`, `verve.I18nLocale`. Guide:
  `docs/14-i18n.md`.

## [0.1.33] - 2026-06-01

### Added

- **Server-fn `_call` wasm round-trip.** `app_client.<name>_call(arena, args,
  on_reply)` now completes a real correlated round-trip in the browser, not just
  on native. The wasm path serializes `args`, allocates a correlation id,
  registers a one-shot `(name, rid)` typed decoder, and posts to `/api/<name>`
  with the `x-verve-rid` header; the server echoes `"rid":N`, the reply routes to
  the matching handler, decodes the typed `value`, and fires `on_reply` — two
  concurrent calls never cross. Void-returning actions post fire-and-forget. The
  generated `app_client` module is now compiled into the wasm client (via a
  dedicated build `WriteFiles` to avoid a cycle through `client.wasm`); the client
  installs the correlation + allocation surface at hydrate via
  `verve.serverFnGen.installWasmHooks(...)`. `core/server_fn_gen.zig` reaches the
  client runtime through dependency-inversion hooks, so the target-agnostic core
  stays free of any `client/` import. Demo: the `/counter` page's "call +" button.
  Guide: `docs/03-actions.md`.

### Changed

- **Keyed-list (`bindForEach`) multi-instance namespacing.** `registerForEach`
  now suffixes its `parent_bind` by the enclosing island's `vid` (matching the
  server-side `z-bind` suffix from `rewriteBindings`), so two instances of one
  component each reconcile only their own keyed list. The previous manual
  distinct-parent-bind workaround is no longer needed. Guide: `docs/15-islands.md`.

### Fixed

- **Chunk-handler cross-component name collisions.** `z-on-click` string dispatch
  resolved chunk exports through a flat, last-writer-wins map keyed only by export
  name, so two island components exporting the same handler name collided (the
  second-loaded chunk shadowed the first). Chunk exports are now nested by island
  `data-name` then export name, and dispatch resolves against the click target's
  enclosing `<verve-island>` — same-named handlers in different components no
  longer collide. Guide: `docs/15-islands.md`.

## [0.1.32] - 2026-06-01

### Added

**Interactive islands, end to end** — the island stack moves from
marker-emission-only to a complete client lifecycle: typed props, server-resolved
resource state, per-instance reactive ownership with disposal, and multi-instance
independence. App islands (separate per-island `.wasm` chunks sharing the main
client's memory) can now decode typed props, read server state, register reactive
signals + handlers, and dispose cleanly on navigation or unmount. New runnable
demo: `examples/islands-demo` (two independent Counter islands). Guide updates in
`docs/15-islands.md`, `docs/18-streaming.md`, `docs/16-spa-router.md`,
`docs/12-wasm-client.md`.

- **Streaming SSR is truly async (P2).** `Resource` fetchers run via
  `std.Io.async` (`resource.create(T, io, owner, ctx, fetcher)` launches the
  fetcher + stores a `Future`); `Renderer.streamRender(w, io, node, reg)` awaits
  every suspended boundary's in-flight future **concurrently** and emits each
  `<template id="verve-vs-N">` chunk in **completion order** (out-of-order on the
  wire — a fast boundary lands before a slow one). Worker tasks only block on
  futures; all Signal mutation + node rendering stay on the main thread.

- **Per-island + route lifecycle (P1).** `verve_unmount_route()` disposes a route's
  reactive scope on SPA navigation (re-arming the owner; clears the slot tables),
  fired by the bridge before the body swap. A `MutationObserver` hydrates each
  `<verve-island>` on insertion (closing the post-nav re-hydration gap) and calls
  `verve_unmount_island(vid)` on removal. Islands carry an auto-assigned unique
  `data-vid`; signals/effects/cleanups register under per-`vid` child owners and
  dispose with the island.

- **Island resource-state hydration (P1.5).** `ctx.islandState(.{...})` /
  `ctx.islandStateStruct(key, value)` serialize a server-resolved value into a
  per-page `<script type="application/verve-state">` (keyed by `vid`); the client
  `verve.resourceFromState` / `resourceStructFromState` / `islandStateValue`
  reconstruct it with **no re-fetch**.

- **Typed island props via a binary codec (P3).** Added a panic-free decoder to
  `src/core/serialize.zig` (mirrors the encoder; bounds-checked, allocation-capped
  against malicious `data-props`). `verve.encodeProps(ctx, P{...})` →
  `verve.decodeProps(P, bytes, alloc)`; `data-props` is now base64 of the binary
  codec. `props_schema` is demoted to optional documentation — the comptime `Props`
  type is the contract.

- **Chunk-runtime integration.** App chunks reach the new features through
  `island_runtime.zig`: `verve.decodeProps`, `verve.islandStateValue(T, key)`
  (reads the shared state blob via `verve_current_state_ptr/_len`). The bridge wraps
  each chunk `hydrate` in `verve_enter_island(vid)` / `verve_exit_island()` so chunk
  signals scope to the island's vid; `z-on-click="<name>"` dispatches to the
  chunk's exported handler (scoped to its island).

- **Multi-instance islands.** Two `<verve-island>` of one component on a page now
  work independently with no author burden — the framework suffixes each instance's
  `z-bind` / `data-ref` (and the client DOM updates / `queryRef`) by `vid`
  (`name__v1`, `name__v2`). The reserved separator is `__v`.

- **Server-fn `_call` correlated callback (P4).** `app_client.<name>_call(arena,
  args, on_reply)` — typed callback variant. Native runs synchronously; the wasm
  path threads a per-call request id (`x-verve-rid` header, echoed in the reply) and
  a one-shot `(route, rid)` reply handler (`registerResponseHandlerOnce`) so
  concurrent calls never cross. (The wasm round-trip is wired pending
  `app_client`-in-wasm-client; native works today.)

- **i18n: RTL + pluralization (P5).** `verve.i18nIsRtl(locale)` / `verve.i18nDir`
  (10-language RTL set) for `<html dir="…">`. `verve.PluralCategory` +
  `verve.pluralCategory(locale, n)` — CLDR cardinal rules for a curated set of
  language families (English/French/East-Slavic/Polish/Czech-Slovak/Arabic/Asian
  other-only; unknown → English; integer counts). `verve.tPlural(catalog, locale,
  key_base, n, arena)` selects `key.<category>` (fallback to `.other`/base) and
  substitutes `{n}`.

- **Desktop image clipboard (P6).** `Clipboard.writeImage(png)` /
  `readImage(alloc)` (raw PNG bytes). macOS implemented via `NSData` +
  `setData:forType:` / `dataForType:` with `public.png` (verified by a host
  round-trip). Windows (`CF_DIB`) + Linux (`image/png` GtkClipboard target) return
  `error.Unsupported` — follow-ups.

## [0.1.31] - 2026-05-29

### Added

Built-in **GFM markdown rendering** and **syntax highlighting** — pure-Zig,
server-side, safe-by-default. These replace third-party JS dependencies
(`marked` / `markdown-it`, `highlight.js` / `prism`): markdown is parsed in
`src/core/` at SSR time and emitted into the `Node` tree, so there is no
client wasm cost and no JavaScript. New guide:
`docs/21-markdown-and-highlighting.md`; new demo: `examples/markdown/`.

- **`ctx.markdown(src)` / `ctx.markdownOpts(src, opts)`** (`verve.markdown`,
  `verve.MarkdownOptions`). GFM = CommonMark core (headings, lists,
  emphasis/strong, links, images, blockquotes, fenced + indented code,
  autolinks, reference links, backslash escapes) plus GFM tables with
  per-column alignment, task lists, and strikethrough. Returns a real `Node`
  subtree (fragment), so every text leaf flows through the framework's single
  `escapeHtml` — no second escaper to get wrong.

- **`ctx.codeBlock(src, lang)`** (`verve.highlight`, `verve.HighlightLang`,
  `verve.detectLang`). Hand-written tokenizers for Zig, JavaScript/TypeScript,
  JSON, HTML/XML, CSS, Bash, and Markdown, plus a generic fallback. Emits
  `<span class="tok-…">` tokens using a stable class contract themed by
  `verve.highlightThemeCss` (bundled light/dark). Markdown fenced code blocks
  auto-highlight via the same engine. Distinct from the existing inline
  `ctx.code(text)`.

- **Safe-by-default sanitization.** Link/image/autolink URLs pass through the
  new `verve.sanitizeUrl` (exported standalone): only `http`, `https`,
  `mailto`, `tel`, and scheme-less URLs are allowed; `javascript:`,
  `vbscript:`, `data:`, `file:`, and control-character scheme bypasses are
  rejected. Raw HTML embedded in markdown source is stripped (no allowlist).

- **`ctx.textNode(text)`** — a bare escaped character-data node (renders via
  `escapeHtml` with no wrapping element), the building block for interleaving
  plain text with inline elements and highlight spans.

- **`examples/client-runtime/`** — runnable demo for the v0.1.30 client-runtime
  primitives (previously docs-only). Mounts the `JsonProbe` island and
  exercises all six phases — typed IPC, events-with-data, timers/storage/
  clipboard, forms/measurement, JS interop, chunk arena + drag-drop — from one
  page. Linked from `docs/20-client-runtime.md`.

## [0.1.30] - 2026-05-29

### Added

Client-runtime feature track — wasm-side primitives so frontend/desktop
apps write application logic in Zig instead of a hand-maintained inline
`<script>` blob. New guide: `docs/20-client-runtime.md`. All capabilities
are chunk-callable through the `verve_runtime` import; the design keeps a
single `std.json` parser in the main client so per-island chunks stay
small (the `JsonProbe` demo island exercising every feature is ~3.4 KB).

- **Typed IPC replies + shared JSON service** (Phase 1). One `std.json`
  parser lives in the main client (`src/client/json_service.zig`),
  exposed via `verve_json_*` accessor exports. Chunks read replies
  through `verve.JsonDoc` accessors or the typed `verve.readStruct(Reply,
  doc, allocator)` — no per-chunk JSON scanner. `verve.serverFnPost`
  re-exports the outbound POST through `verve_runtime`. Server-side gains
  a callback-style `serverFnGen.call` + codegen'd `app_client.<name>_call`.

- **Events with data** (Phase 2). Closure event handlers can now read the
  dispatching event: `verve.eventMods()`, `eventKey(buf)`,
  `eventTargetAttr(name, buf)` (the handler element's `data-*`),
  `eventCoordX/Y()`, and `eventPreventDefault()` / `eventStopPropagation()`.
  The bridge stages the event before dispatch and honors the flags after;
  the target dataset is parsed through the shared JSON service.
  (`src/client/event_state.zig`.)

- **Timers, storage, clipboard** (Phase 3). `verve.setTimeout` /
  `setInterval` / `requestAnimationFrame` / `queueMicrotask` /
  `clearTimer` (handlers cross as function-table indices),
  `verve.storage.{get,set,remove,len}` over `localStorage`, and
  `verve.clipboardWrite` (async API with an `execCommand` fallback).

- **Forms & DOM measurement** (Phase 4). `verve.refValueStr`,
  `refRequestSubmit`, `refSelect`, `refBlur`, `refScrollIntoView`,
  `refRect()`, `viewport()`, `matchMedia(query)`, and `formCollect(bind,
  buf)` (serializes a form's named fields to JSON for `readStruct`).

- **Generic JS interop escape hatch** (Phase 5). `verve.host(name,
  args_json, out)` (sync) and `verve.hostAsync(name, args_json, route)`
  (result fans back through the response-handler path). Apps register
  functions in `window.verveHost` — the supported path for Intl
  date/number formatting, markdown, syntax highlight, and canvas without
  verve owning those APIs.

- **Chunk-local arena + drag-drop** (Phase 6). `verve.chunkArena()` is a
  real `std.mem.Allocator` over a bump region in the main client
  (`src/client/chunk_arena.zig`) with `chunkArenaMark` / `chunkArenaReset`
  for per-dispatch recycling — replaces worst-case static buffers.
  `verve.registerDrop(bind, handler)` + `verve.currentDrop(buf)` deliver
  dropped-file bytes (written straight into the arena) to wasm.

Implementation touched `src/client/{json_service,event_state,chunk_arena}.zig`
(new), `runtime_exports.zig`, `island_runtime.zig`, `src/core/server_fn_gen.zig`,
`tools/server_fn_codegen.zig`, and `src/bridge/verve.js`. `src/verve.zig`
unchanged.

## [0.1.29] - 2026-05-27

### Added

- **HTML composition via named templates** (G2). Per-island wasm
  chunks compose new DOM nodes from server-rendered prototypes
  instead of formatting markup with `std.fmt` strings. Row HTML
  lives in `components.zig` next to the rest of the page; chunks
  just clone, fill, append.

  Server side:
  - `Context.template(name, inner) *Node` — wraps `inner` in
    `<template data-vt="<name>">`. Browser parses but doesn't
    render the inner subtree until a chunk clones it.
  - `Node.slot(name)` — marks a fillable element inside a
    template; renderer stamps `data-vt-slot="<name>"`.
  - Renderer test in `src/core/renderer.zig` covers the wrapped
    output.

  Wasm side:
  - `verve.cloneTemplate(name) ?i32` — looks up `[data-vt]`,
    clones content, returns a `refHandles[]`-style handle.
  - `verve.slotText(h, slot, text)` /
    `verve.slotAttr(h, slot, name, value)` — fill named slots
    inside the cloned subtree.
  - `verve.appendToBind(parent_bind, h)` — graft the cloned
    fragment into every `[z-bind="<parent>"]` element
    (re-cloned per parent so multiple bound parents don't share
    the same node reference).

  Implementation:
  - `src/client/dom.zig` — 4 new externs + native stubs +
    module-level exports.
  - `src/client/runtime.zig` — Zig wrappers.
  - `src/client/runtime_exports.zig` — chunk-callable wrappers
    (`verve_clone_template`, `verve_slot_text`, `verve_slot_attr`,
    `verve_append_to_bind`).
  - `src/client/island_runtime.zig` — chunk-side extern decls +
    Zig wrappers.
  - `src/client/verve_client.zig` — re-exports for downstream
    wasm clients.
  - `src/bridge/verve.js` + `templates/desktop/frontend/verve_desktop.js`
    — 4 new handlers in `env.verve` (leverages existing
    `refHandles[]` table from Bundle 3 + the `<template>` +
    `cloneNode` precedent already in the bridge for keyed-list
    reconciler + verveSwap). Web bridge adds the 4 new exports
    to its `verveRuntime` chunk import object.

  Event handlers on cloned rows work via either flavor: string-name
  dispatch (`z-on-click="<exported_name>"` on a template inner
  node fires through the existing delegate after append), or
  closure-id dispatch (chunks stamp `z-on-click-id="<id>"` via
  `slotAttr` after `registerEvent` returns, before appending).

  `docs/12-wasm-client.md` gains a "HTML composition via named
  templates" section with a worked todo-row example.

  Deferred: handle disposal for the `refHandles[]` table (pairs
  with the future per-route Owner scoping work that disposes on
  SPA navigation). Renderer-to-wasm port stays the alternative
  path captured in `~/.claude/plans/g2-html-composition-in-wasm.md`;
  revisit only if real apps demand dynamic in-wasm composition
  templates can't model.

## [0.1.28] - 2026-05-27

### Added

- **IPC response handlers** (G3 — closes the upstream-flagged gap
  in `src/client/dom.zig:142` "async response delivery lands with
  the streaming runtime in a later phase"). Outbound IPC was
  already wired through `server_fn_post` (web → `/api/<name>`
  fetch) and `post_json_i32` (desktop → `window.verve.send`);
  replies used to land in JS only — wasm couldn't observe them.

  Per-route subscription model:

  - `verve.registerResponseHandler(route, *const fn ([*]const u8, u32) void)`
    records a handler against `route`. Multiple handlers per route
    are allowed; they fire in registration order. Slot cap: 256
    (raise `MAX_RESPONSE_SLOTS` in `runtime.zig` if needed).
  - `verve_dispatch_response(route_ptr, route_len, body_ptr, body_len)`
    is the export the bridge JS calls once it has staged the reply
    body bytes into shared memory.

  Bridge JS wiring:

  - **Desktop** (`templates/desktop/frontend/verve_desktop.js`):
    subscribes to `window.verve.onMessage(...)` and forwards every
    inbound message (whose `type` is a string) to
    `verve_dispatch_response`. `__verve_id`-correlated replies
    (consumed by `window.verve.request(...)`'s Promise chain)
    don't reach wasm handlers, so wasm-initiated request/response
    uses `server_fn_post` (which goes through `send`).
  - **Web** (`src/bridge/verve.js`): the `server_fn_post` extern
    now awaits the fetch response and dispatches the body to
    `verve_dispatch_response` after the POST completes.

  Body bytes are staged through the runtime's island scratch
  buffer (default 8 KB); replies that overflow drop with a console
  warning rather than truncate. Re-exported through `verve_client`
  + chunk-side `island_runtime.zig`. Bridge JS adds the two new
  entries to its `verveRuntime` chunk import object.

  Test in `src/client/runtime.zig` covers the slot-table
  registration + per-route dispatch + multi-handler fan-out +
  unknown-route silent-drop semantics.

### Docs

- `docs/12-wasm-client.md` — new "IPC response handlers" section
  with a worked end-to-end example covering chunk-side
  registration + outbound call + bridge-mediated reply.

## [0.1.27] - 2026-05-27

### Added

- **Wasm-callable keyed-list reconciler** (G1). New
  `verve_list_diff(parent_ptr, parent_len, old_keys_ptr,
  old_keys_count, new_keys_ptr, new_keys_count, new_html_ptr,
  new_html_count)` export wraps `runtime.applyReconcile` for
  per-island chunks. Slice-of-slice args cross as
  `[*]const []const u8` + count pairs — Zig slices share their
  `(ptr, len)` layout across chunk + main runtime so no packing is
  needed. The runtime allocates a short-lived arena under the
  long-lived bump heap for the planner's scratch and disposes it on
  return.

  Chunk-side façade in `src/client/island_runtime.zig` exposes the
  friendly `verve.listDiff(parent, old_keys, new_keys, new_html)`
  wrapper. Re-exported through `verve_client` as `verve.listDiff`.
  Bridge JS adds `verve_list_diff` to the `verveRuntime` import
  object. Length-mismatched calls short-circuit; native dom stubs
  let the unit test exercise the dispatch path without a real DOM.

### Docs

- **G4 — Reactive lists** pattern documented in
  `docs/12-wasm-client.md`. Client-side Signals are intentionally
  scalar-only (`i32` / `str` / `bool` / `f32`); for list-shaped
  state, decompose into a list-of-keys Signal + per-row scalar
  Signals + `verve.listDiff` for ordering. The legacy
  `bindForEach(handle, ctx, render_fn)` path stays the
  effect-driven option that re-runs on Signal change and caches
  the previous key order.
- **README + topic guides swept for v0.1.12..v0.1.26 features.**
  README's Reactivity + Islands sections rewritten to cover typed
  bindings + auto-walker, declarative `autoHydrate`, idempotent
  `register*`, closure-style event handlers (`registerEvent` +
  `onClickFn` + 4 other event kinds), slot-table introspection,
  NodeRef ops (`queryRef` + `setRef*` + `refValueI32`/`F32`),
  `verve.cleanup`, chunk-side reactive runtime (Phase 13F),
  cross-module closure events (Phase 13G), multi-instance islands,
  and a new "Downstream wasm clients (`verve_client` module)"
  subsection. "Use as a Zig package" gains a worked
  `verve_client` example. `docs/12-wasm-client.md` surface table
  refreshed; new sections for NodeRef ops, cleanup hooks,
  slot-table introspection, extended closure-event coverage.
  Topic index + glossary, desktop guide, and desktop scaffold
  README all updated. Pure doc — no behavior change.

## [0.1.26] - 2026-05-27

### Added

- `verve.cleanup(handler)` helper. Registers a `*const fn () void`
  against the runtime's root Owner; runs in LIFO order when the
  Owner disposes. Today the Owner only disposes via test reset, so
  cleanups are dormant in production — the API exists so apps can
  declare resource teardown ahead of the future SPA-navigation work
  that will dispose per-route owners between pages.

  Re-exported through `verve_client.cleanup` and the chunk-side
  `island_runtime.cleanup`. Chunks pass their fn pointer as a u32
  table index — same ABI as `registerEvent`, same cross-module
  function-table sharing that Phase 13G wired in. Bridge JS adds
  `verve_cleanup` to the `verveRuntime` chunk import object.

  Test in `src/client/runtime.zig` covers registration + LIFO
  firing on dispose.

## [0.1.25] - 2026-05-27

### Added

- Slot-table introspection. Read-only views over the live signal +
  event slot tables — useful for in-page debug overlays, hydration
  log lines pinning down which bindings registered, and capacity-watch
  dashboards.

  - `slotCount` / `slotCapacity` — signal slot usage + ceiling
  - `eventSlotCount` / `eventSlotCapacity` — event handler slot usage
  - `slotName(idx, buf)` — copy the bind-name at `idx` into `buf`
  - `slotKind(idx)` — `TypeTag` (i32/str/bool/f32) of the slot at `idx`

  Re-exported through `verve_client` (`TypeTag` now `pub`); also
  exposed as `verve_*` exports for chunks via `runtime_exports.zig`
  (slot kind comes back as `0..3` with `0xFFFFFFFF` for out-of-range)
  and re-wrapped in `island_runtime.zig` for Zig-friendly chunk
  callers. Bridge JS adds the six new entries to its `verveRuntime`
  import object so chunks can call them.

### Changed

- **Slot capacity bumps**. `MAX_SLOTS` raised from 64 → 256;
  `MAX_EVENT_SLOTS` raised from 256 → 1024. Both were tighter than
  real-app usage would tolerate (one binding per visually-distinct
  reactive span + one event handler per visually-distinct click
  target). Bumps are static-array size only — no per-slot overhead
  beyond what's already paid.

## [0.1.24] - 2026-05-27

### Added

- Suspense / control-flow / SPA-nav / i18n façade exposure. Pure
  additive re-exports of symbols already public on the `verve`
  module — every one of them was already wasm-compat (no host-only
  deps in their core files), the gap was just that downstream
  clients couldn't reach them through `verve_client`.

  Added to `src/client/verve_client.zig`:
  - **Suspense**: `suspense`, `transition`, `markSuspended`
  - **Control flow**: `show`, `forEach`, `portal`
  - **SPA navigation**: `link`, `LinkOpts` — required for the
    browser-only template that lands next
  - **i18n**: `I18nCatalog`, `I18nEntry`, `resolveLocale`

  Tests + build + desktop smoke all green; no behavior change to
  any existing surface.

## [0.1.23] - 2026-05-27

### Added

- Phase 14 — JS-driven auto-walker for typed bindings. Apps that
  use the new `Node.bindI32` / `bindStr` / `bindBool` / `bindF32`
  methods get zero per-bind wasm registration boilerplate: the
  renderer stamps `data-vh-type` + `data-vh-initial` (and
  `data-vh-class` for bool) on the bound element, and the bridge JS
  walker calls the matching `verve_register_<kind>` export with the
  name + initial value staged through the runtime's island scratch
  buffer. The legacy `Node.bind` + `verve_init_<name>` +
  `verve_hydrate` path still works — `register*` is idempotent on
  the bind-name (since v0.1.21) so running both paths is safe.

  Surface:
  - `src/core/node.zig` — new `BindKind` enum + 4 typed binding
    methods, 6 new optional fields on `Node`.
  - `src/core/renderer.zig` — emit the three new attrs per typed
    binding alongside the existing `z-bind` / `data-vh`.
  - `src/bridge/verve.js` + `templates/desktop/frontend/verve_desktop.js`
    — walker phase right after `verve_hydrate`. Uses the runtime's
    `verve_island_scratch_*` exports to pass name + initial bytes
    into wasm without needing a separate JS allocator.
  - `src/client/verve_client.zig` — `comptime { _ = @import("runtime_exports.zig"); }`
    so downstream wasm clients (the desktop template) ship the
    `verve_register_<kind>` exports the walker calls.

  Desktop template scaffold migrated as the reference example.
  `components.zig` now uses `bindI32("count", 0)` /
  `bindI32("clicks", 0)`; `src/client/main.zig` drops the
  `verve_init_count`, `verve_init_clicks`, `verve_hydrate` exports
  entirely and ships only the two click handlers. Smoke golden
  checksum unchanged (1789) — DOM text output is identical.

## [0.1.22] - 2026-05-27

### Added

- Phase 13G — closure-style event handlers from per-island chunks.
  `src/client/island_runtime.zig` exposes `registerEvent(handler)`
  + `dispatchEvent(id)`; chunks call them like the main client does
  (`registerEvent(&myHandler) -> u32` slot id; stamp via
  `Node.onClickFn(id)` at render time).

  The fn pointer crosses the chunk → main-runtime boundary as a
  table index. `build.zig` exports the main client's indirect
  function table (`wasm.export_table = true`) and imports it into
  each per-island chunk (`exe.import_table = true`); the bridge JS
  passes the table through as `env.__indirect_function_table` at
  chunk `WebAssembly.instantiateStreaming`. Result: `&handler`
  taken inside a chunk lands at an index the main runtime's
  `event_slots` array can also call via `call_indirect` from
  `verve_event_dispatch` — no JS hops needed for dispatch, no
  per-chunk handler-name registries.

  Wasm MVP function ABI can't carry `*const fn () void` across
  module boundaries directly; the runtime export
  (`runtime_exports.zig`) takes the table index as `u32` and casts
  back to a fn pointer via `@ptrFromInt(@as(usize, idx))`. The
  chunk-side wrapper passes `@intFromPtr(handler)`. Idiomatic Zig
  on both sides, no callers see the cast.

  Closes the second of the two natural follow-ons from the
  Phase 13F audit. Multi-instance + closure events together give
  chunks the full reactive surface the main client has.

  Files: `build.zig` (export/import table flags), `src/client/
  runtime_exports.zig` (`verve_register_event` + `verve_dispatch_event`
  exports), `src/client/island_runtime.zig` (externs + Zig wrappers),
  `src/bridge/verve.js` (capture + pass the table; register the
  two new entries in `verveRuntime`), `docs/15-islands.md` (worked
  example).

## [0.1.21] - 2026-05-27

### Added

- Multi-instance island support. Bridge JS now stamps a per-page
  document-order id as `data-instance="N"` on each `<verve-island>`
  marker and threads it through to the chunk's `hydrate(props_ptr,
  props_len, root_id)` call (previously always passed 0). Chunks
  needing per-instance state namespace their bind-names using
  `root_id` — e.g.
  `std.fmt.bufPrint(&buf, "counter_island_{d}", .{root_id})`.
  Documented in `docs/15-islands.md`.

### Changed

- `runtime.registerI32` / `registerStr` / `registerBool` /
  `registerF32` are now **idempotent on the bind-name**. A second
  call with a name already in the slot table returns the existing
  slot's pointer and discards the new initial value, instead of
  silently allocating a duplicate slot whose state nobody else can
  reach. Lets multi-instance islands and hot-reloaded chunks call
  `register*` defensively without piling up dead allocations. Test
  in `src/client/runtime.zig` covers the idempotent return + shared
  mutation semantics.

## [0.1.20] - 2026-05-27

### Added

- Phase 13F — per-island WASM chunks can now call the main client's
  reactive runtime. Each chunk imports a `verve_runtime` namespace
  the bridge JS resolves against matching exports on the main
  `client.wasm` instance at chunk instantiation time. Chunks
  `@import("verve")` (resolved against `src/client/island_runtime.zig`
  via a new `verve_island` build module) and call:

  - `registerI32` / `registerStr` / `registerBool` / `registerF32` —
    allocate per-island Signals under the main runtime's root Owner
  - `signalSetI32` / `Str` / `Bool` / `F32` — name-keyed `Signal.set`
  - `signalGetI32` / `Bool` / `F32` / `Str(name, buf)` /
    `signalGetStrLen` — name-keyed `Signal.peek` (two-call read for
    strings)
  - `queryRef` + `setRefText` / `setRefTextI32` / `setRefAttr` /
    `setRefValue` / `setRefClass` / `focusRef` / `removeRef` /
    `refValueI32` / `refValueF32` — NodeRef resolution + per-handle ops

  The wrappers live in `src/client/runtime_exports.zig` and are
  pulled into the main client via `comptime { _ = @import(...); }`
  in `src/client/main.zig` so their `export fn verve_*` decls land
  in the main wasm's export table. Bridge JS (`src/bridge/verve.js`)
  builds a `verveRuntime` import object from those exports once after
  main instantiation and passes it to every per-island chunk's
  `WebAssembly.instantiateStreaming` call.

  Closure-style event registration (passing a `*const fn () void`
  across the chunk boundary) deferred — needs cross-module function-
  table sharing. Chunks export named handler functions and use the
  existing `[z-on-click="<exportedName>"]` dispatch path; bridge
  JS already routes string-name clicks to the chunk's instance.

  `src/client/islands/Counter.zig` migrated to demonstrate the new
  API end-to-end — registers `counter_island` signal in `hydrate`,
  exports `counter_island_bump` which mutates it via `signalSet/GetI32`.
  Stub chunks weigh ~73 bytes; Counter now weighs ~290 bytes (still
  shipping only what the chunk actually does, no duplicated runtime).

  Files: `src/client/runtime_exports.zig` (new), `src/client/island_runtime.zig`
  (new), `src/client/main.zig` (pull runtime_exports), `src/client/tests.zig`
  (aggregate), `build.zig` (new `verve_island` module + chunk imports),
  `src/bridge/verve.js` (verveRuntime imports), `src/client/islands/Counter.zig`
  + `_default.zig` (header refresh), `docs/12-wasm-client.md` +
  `docs/15-islands.md` (chunk-side API documented).

## [0.1.19] - 2026-05-27

### Added

- Closure-style event handlers for `submit`, `input`, `change`, and
  `keydown` — companion methods to `Node.onClickFn` shipped in
  v0.1.17. Each takes a `u32` slot id returned by
  `verve.registerEvent(...)`; the renderer stamps
  `z-on-<event>-id="<n>"`; bridge JS registers a delegated listener
  per event type and routes the id through the same
  `verve_event_dispatch(id)` export. Submit handlers run with
  `preventDefault()` so the native form post does not fire;
  input / change / keydown run alongside the native handling.
  Handler signature stays `fn () void` — input-event handlers read
  the new value via `verve.refValueI32` / `refValueF32` against a
  co-stamped NodeRef (Bundle 6 surface).

  Closes the second of the two "natural follow-ons" from the
  post-Bundle-5 gap audit. Files: `src/core/node.zig` (4 new
  fields + 4 new methods), `src/core/renderer.zig` (4 new attr
  stamps), `src/bridge/verve.js` + `templates/desktop/frontend/
  verve_desktop.js` (factored `dispatchEventId` helper + 4 new
  delegated listeners).

## [0.1.18] - 2026-05-27

### Added

- Per-handle NodeRef mutation + introspection externs. Once
  `verve.queryRef(ref)` resolves a handle, downstream code reaches
  into the live element via:
  - `setRefText(h, text)` / `setRefTextI32(h, v)` — replace text content
  - `setRefAttr(h, name, value)` — `Element.setAttribute`
  - `setRefValue(h, v)` — `el.value` for form inputs
  - `setRefClass(h, class, on: bool)` — classList add/remove
  - `focusRef(h)` / `removeRef(h)` — focus + remove
  - `refValueI32(h)` / `refValueF32(h)` — parse `el.value` as number
  Bridge JS looks up `refHandles[h]`; stale / out-of-range handles
  short-circuit to a no-op (read variants return 0) so wasm code stays
  resilient against a hot-swapped build.

  Closes one of the two "natural follow-ons" called out in the
  post-Bundle-5 gap audit. Files: `src/client/dom.zig` (9 new externs
  + native stubs + exports), `src/client/runtime.zig` (Zig wrappers),
  `src/client/verve_client.zig` (re-exports), `src/bridge/verve.js`
  + `templates/desktop/frontend/verve_desktop.js` (9 new handlers each).

## [0.1.17] - 2026-05-27

### Added

- Closure-style click handlers (Bundle 5 of the verve_client gap-close
  plan — closes the last gap). Register a `*const fn () void` via
  `verve.registerEvent(handler)` → returns a `u32` slot id; pass it
  to `Node.onClickFn(id)` at render time. The renderer stamps
  `z-on-click-id="<id>"`; the bridge JS click delegate routes it
  through `verve_event_dispatch(id)` which invokes the registered
  fn pointer. Handler keeps whatever state it captured at
  registration — no flat-namespace export name required. 256 slots
  in the runtime's `event_slots` table; out-of-range / unregistered
  ids dispatch as no-ops. Both `[z-on-click]` (string-name) and
  `[z-on-click-id]` (closure) flavors coexist on the same node;
  id-style wins when both are stamped. Test added in
  `src/client/runtime.zig`.

  Files: `src/core/node.zig` (new `z_on_click_id` field +
  `onClickFn` method), `src/core/renderer.zig` (stamps the new
  attribute), `src/client/runtime.zig` (slot table + dispatcher
  + export), `src/client/verve_client.zig` (re-exports),
  `src/bridge/verve.js` + `templates/desktop/frontend/verve_desktop.js`
  (delegate routes id-style first, falls through to name-style),
  `docs/12-wasm-client.md` (usage example).

## [0.1.16] - 2026-05-27

### Added

- `autoHydrate(bindings)` declarative hydration helper (Bundle 4 of
  the verve_client gap-close plan). Takes a slice of
  `Binding { name, initial }` and dispatches to the matching
  `registerI32` / `registerStr` / `registerBool` / `registerF32` per
  entry — the `BindingInitial` union tag picks the variant. Lets
  downstream wasm clients declare all their bindings in one block
  instead of scattering `register*` calls across `verve_hydrate`.
  Initial values still come from the caller; the bridge's existing
  `verve_init_<name>(value)` walker remains the recommended source.
  Desktop template scaffold migrated to demonstrate. Re-exported
  through `verve_client` along with the `Binding` + `BindingInitial`
  types. Full auto-walker (renderer-stamped type info + generic
  `verve_register` extern) deferred — captured as future work in
  the gap-close plan.

## [0.1.15] - 2026-05-27

### Added

- NodeRef resolution end-to-end (Bundle 3 of the verve_client
  gap-close plan). `src/client/dom.zig` gains a `query_ref(id_ptr,
  id_len) i32` extern + native stub. `src/client/runtime.zig` gains
  a `queryRef(ref)` wrapper that accepts any `verve.NodeRef(.tag)`
  instance and returns the JS-owned handle (>=1) or null when the
  bridge can't find a matching `[data-ref="<id>"]`. The wasm-client
  façade re-exports `NodeRef`, `NodeRefTag`, `queryRef`. Both
  bridges (`src/bridge/verve.js`, `templates/desktop/frontend/
  verve_desktop.js`) gain the `query_ref` extern handler — backed
  by a module-scoped `refHandles[]` array with index 0 reserved for
  "not found" — plus a `window.verveQueryRef(id)` helper for
  hand-written JS that wants the lookup without going through wasm.
  Per-handle mutation externs (set text, focus, etc.) deferred to a
  future bundle; this commit ships resolution only.

## [0.1.14] - 2026-05-27

### Added

- Desktop bridge JS gains `server_fn_post` and `post_json_i32`
  externs (Bundle 2 of the verve_client gap-close plan). Both
  translate the web `/api/<name>` POST contract into a fire-and-
  forget IPC message via `window.verve.send`, so wasm-side code
  written against `verve.serverFnGen.post(...)` or `dom.post_json_i32`
  runs identically on desktop builds. `post_json_i32` strips a
  leading `/api/` prefix from the path and uses the remainder as
  the IPC route `type`; routes without the prefix dispatch
  verbatim. Schema drift between the action's `Args` and the
  registered Router route surfaces as a parse failure in the
  handler — the bridge logs invalid JSON bodies and IPC send
  errors to the console.

## [0.1.13] - 2026-05-27

### Added

- `verve_client` façade expanded — re-exports `Action`, `createAction`,
  `serverFn`, `serverFnGen` (server-function primitives + the wasm-side
  `server_fn_post` bridge), `Resource`, `ResourceState`, `createResource`,
  `createLocalResource` (async state), `Store`, `createStore` (field-
  grained reactivity), `ErrorBoundary`, `createErrorBoundary`. Bundle 1
  of the verve_client gap-close plan — pure additive re-exports; no
  runtime changes. Downstream wasm clients can now reach the full
  reactive surface, not just `Signal` + `Effect`.

## [0.1.12] - 2026-05-27

### Added

- `verve_client` public module — re-exports the reactive primitives
  (`Signal`, `Effect`, `Owner`, `createEffect`, `batch`, `untrack`) and
  the DOM-wired adapter (`registerI32` / `registerStr` / `registerBool`
  / `registerF32`, `registerForEach`, `bindForEach`, `applyReconcile`)
  for downstream wasm clients. The desktop template scaffold now
  imports it as `@import("verve")` from `src/client/main.zig` and
  drives DOM mutations through `Signal.set` → `on_set` instead of the
  prior direct `set_text_by_bind_i32` externs. The desktop bridge JS
  (`templates/desktop/frontend/verve_desktop.js`) gains the keyed-list
  reconciler primitives (`create_keyed_child`, `move_keyed_child`,
  `remove_keyed_child`) ported verbatim from `src/bridge/verve.js`.
- `Window.printWithOptions` Linux: full `GtkPrintSettings`
  integration (Bundle 8 of the Win/Linux backfill plan). `copies`,
  `pages` (translated 1-indexed PageRange → 0-indexed GtkPageRange),
  and `printer_name` populate a `GtkPrintSettings` attached via
  `webkit_print_operation_set_print_settings` before the dialog
  opens. Settings pre-fill the dialog; user can still override.
  Windows extras remain **advisory** — `ShowPrintUI` doesn't
  accept a settings struct; framework now logs a warning when
  caller sets non-default `copies` / `pages` / `printer_name`.
  Full Windows silent-print via `ICoreWebView2_16::Print` +
  `ICoreWebView2PrintSettings` + completion-handler impostor
  deferred (needs Windows host for vtable-slot validation).
- `desktop.hotkeys.Manager` Windows + Linux X11 implementations
  (Bundles 6 + 7 of the Win/Linux backfill plan). macOS Carbon
  impl unchanged. Wayland deferred (needs GlobalShortcuts xdg
  portal). Windows uses `RegisterHotKey` against a hidden
  `HWND_MESSAGE` window owned by the manager + a small custom
  wndProc that handles `WM_HOTKEY`. Self-contained — no
  changes to the rest of the Win backend. `MOD_NOREPEAT` set
  to suppress auto-fire on held keys. Linux uses libX11 loaded
  at runtime via `std.c.dlopen("libX11.so.6")` + memoized
  fn-pointer struct (lets the module load cleanly on
  Wayland-only / headless installs). `XGrabKey` is called 4×
  per binding to cover the (NumLock × CapsLock) toggle combos.
  Dedicated worker thread runs `XNextEvent`; callback fires
  from worker thread. `XSetErrorHandler` swallows BadAccess
  globally so contested grabs don't abort the process.
  Wayland sessions (detected via `XDG_SESSION_TYPE=wayland`)
  return `error.Unsupported` from init — XGrabKey on the
  XWayland root only fires when an X11 client has focus,
  which breaks the "global" promise.
- `desktop.fswatch.Watcher` Linux implementation (Bundle 5 of
  the Win/Linux backfill plan). The module is now complete on all
  three backends. Linux uses `inotify_init1(IN_NONBLOCK |
  IN_CLOEXEC)` + `inotify_add_watch(IN_MODIFY | IN_ATTRIB |
  IN_MOVED_FROM | IN_MOVED_TO | IN_CREATE | IN_DELETE)`, wraps
  the fd in `g_io_channel_unix_new`, and installs a
  `g_io_add_watch(G_IO_IN, ...)` so events dispatch on the GTK
  main loop. Callback fires on the **main thread**, matching
  macOS FSEvents. v1 is non-recursive (single inode) — callers
  walk subtrees themselves if needed. Shutdown via
  `g_source_remove` + `inotify_rm_watch` + `g_io_channel_unref`.
- `desktop.fswatch.Watcher` Windows implementation (Bundle 4 of
  the Win/Linux backfill plan). macOS FSEvents impl unchanged.
  Linux still pending (Bundle 5). Windows uses
  `ReadDirectoryChangesW` against a `FILE_FLAG_BACKUP_SEMANTICS
  | FILE_FLAG_OVERLAPPED` directory handle, pumped by a dedicated
  worker thread blocking on `GetOverlappedResult(..., TRUE)`.
  Recursive watch (`bWatchSubtree=TRUE`) covers file + dir name
  changes, attributes, size, last-write, and creation events.
  Shutdown via `CancelIoEx` + atomic stop flag from `deinit`.
  16 KiB buffer per watcher. **v1 callback threading**:
  callback fires from the worker thread, not the UI thread —
  apps that need main-thread delivery should marshal across
  themselves (PostMessage / queue drain from the main loop).
  `Watcher` struct gained per-platform `macos_impl` /
  `windows_impl` slots; `deinit` cleans up whichever the
  factory populated.
- `Clipboard.writeHtml` / `readHtml` Win + Linux implementations
  (Bundle 3 of the Win/Linux backfill plan). macOS impl unchanged.
  Win uses the CF_HTML clipboard format with a dynamically
  registered format ID (`RegisterClipboardFormatW("HTML Format")`)
  and the Microsoft-spec header (Version + zero-padded 10-digit
  StartHTML / EndHTML / StartFragment / EndFragment byte
  offsets). Read parses the fragment offsets and returns just the
  fragment bytes — caller doesn't see the wrapper. Linux uses
  `gtk_clipboard_set_with_data` with a `text/html` GtkTargetEntry
  + get_func reading a process-global cached payload (single-window
  assumption matches the rest of the framework). Read via
  `gtk_clipboard_wait_for_contents` + `gtk_selection_data_get_data`.
  Image clipboard formats (TIFF / DIB / image/png) still pending
  on all 3 backends.
- `desktop.deep_link.registerScheme` Win + Linux implementations
  (Bundle 2 of the Win/Linux backfill plan). Closes the macOS-only
  stub. Win writes the `HKCU\Software\Classes\<scheme>` registry
  tree (default value + `URL Protocol` marker +
  `shell\open\command` with `"<exe>" "%1"`); exe path resolved via
  `GetModuleFileNameW`. Linux writes
  `~/.local/share/applications/<bundle_id>.desktop` with
  `MimeType=x-scheme-handler/<scheme>;` + `NoDisplay=true`; exe
  path from `readlink("/proc/self/exe")`. `xdg-mime default ...`
  is not invoked — callers run that command themselves to set
  the explicit default handler. macOS impl unchanged.

### Changed

- **Breaking**: `desktop.deep_link.registerScheme` signature gained
  an `allocator` parameter — now `(allocator, scheme, bundle_id)`.
  Required by the new Win + Linux impls for string composition;
  macOS impl ignores the value. Existing callers must add their
  allocator. Pre-1.0, no compatibility shim.
- Linux `libayatana-appindicator3` (tray) + `libnotify`
  (notifications) are now loaded at runtime via `std.c.dlopen` +
  memoized fn-pointer structs instead of link-time `extern fn`
  declarations. Scaffolds on distros that don't ship those libs
  build cleanly; calls to `Tray.init` / `notifications.show`
  return `error.Unsupported` at runtime instead of failing at
  link time. Tries the modern soname (`libayatana-appindicator3.so.1`
  / `libnotify.so.4`) first, falls back to the unversioned `.so`,
  caches the null on miss so the `dlopen` attempt is one-shot
  per process. Distros that already have the libs see no
  behavior change. (Bundle 1 of the Win/Linux backfill plan.)

## [0.1.9] - 2026-05-29

Closes the last two macOS-touching roadmap items for self-built
apps: auto-updater apply phase + opt-in hardened runtime + signing
docs. macOS is feature-complete for personal-use distribution as
of this release. Notarization remains a documented manual sequence
(framework deliberately does not automate it — credential handling
belongs in CI, not `build.zig`).

### Added

- `desktop.updates.applyUpdate(allocator, io, info)` — macOS apply
  phase. Pure stdlib, no Sparkle vendor. Algorithm: locate the
  running `.app` via `_NSGetExecutablePath` walking up to the first
  `.app` ancestor → download `info.download_url` into memory →
  SHA-256 over the bytes, compare to `info.sha256` (lowercase hex,
  case-insensitive) → stage `.{name}.app.verve-update/` next to the
  target so the rename stays on a single volume → extract via
  `/usr/bin/tar -xzf` → two-step rename swap (current → `.old`,
  new → current, restore on failure) → `open -n <bundle>` then
  `std.process.exit(0)`. Win + Linux return `error.Unsupported`
  (Squirrel / MSIX / AppImageUpdate territory). Bare-binary callers
  (`./zig-out/bin/app`) get `error.NotBundled`.
- `UpdateInfo.sha256` — new required field on the feed schema.
  `checkForUpdate` tolerates absence (defaults to ""); `applyUpdate`
  returns `MissingChecksum` when the digest isn't 64 hex chars.
  Feed schema gained `sha256` next to `version` / `download_url` /
  `notes`. Trust anchor is the feed URL itself (HTTPS to
  infrastructure you control); SHA-256 catches CDN corruption and
  transport tampering but not a compromised feed host.
- `ApplyError` set on `desktop.updates` — `Unsupported, Network,
  BadChecksum, NotBundled, ExtractFailed, SwapFailed,
  RelaunchFailed, MissingChecksum, OutOfMemory`.
- `-Dhardened=true` scaffold build option — opt-in hardened
  runtime + WKWebView entitlements on `templates/desktop/build.zig`.
  Generates a scaffold-local `.entitlements` plist with the three
  keys WKWebView needs under the hardened runtime
  (`com.apple.security.cs.allow-jit`,
  `...allow-unsigned-executable-memory`,
  `...disable-library-validation`) and threads
  `--options=runtime --entitlements <generated>` into the existing
  codesign step via `addPrefixedFileArg`. Default (`hardened=false`)
  is byte-for-byte identical to today's signing path.
- Template README — new "Auto-update" section documenting the
  feed shape + `checkForUpdate` → `applyUpdate` flow + v1 limits
  (macOS-only, bundled-only). New "Distributing to other Macs"
  section walking the Developer ID cert → hardened build →
  `xcrun notarytool submit` → `xcrun stapler staple` sequence as
  manual commands. `-Dhardened` added to both build-flag tables.

### Changed

- `desktop.updates` module header rewritten to describe the new
  two-phase shape (check + apply). Trust model documented inline.
- `parseUpdateFeed` accepts the new `sha256` field (optional in
  feed JSON; defaults to "" when omitted so old feeds keep
  parsing) and copies it into the returned `UpdateInfo`.

### Verified

- `zig build` + `zig build test` PASS (52 tests; 6 new unit tests
  in `updates.zig` cover hex encoding, bundle resolution, missing-
  checksum guard, sha256 parse).
- 3-backend cross-compile (`aarch64-macos` / `x86_64-linux-gnu` /
  `x86_64-windows-gnu`) clean for `updates.zig` + `window.zig`.
- Fresh scaffold + `zig build smoke` PASS (checksum 1789 matches
  golden).
- Default codesign path (`zig build codesign -Dcodesign=-`) still
  emits `Signature=adhoc` with `flags=0x2(adhoc)` — unchanged from
  v0.1.8.
- Hardened codesign path (`zig build codesign -Dcodesign=-
  -Dhardened=true`) emits `flags=0x10002(adhoc,runtime)` with all
  three WKWebView entitlement keys present in `--entitlements -`
  dump.

## [0.1.8] - 2026-05-28

Complete macOS surface sweep — eleven items closing every macOS-
only gap from the post-v0.1.7 roadmap. Four new framework modules
(`desktop.network`, `desktop.fswatch`, `desktop.hotkeys`,
`desktop.process`), IOKit battery completion, SF Symbol tray
fallback, clipboard HTML, runtime URL-scheme registration, print
page-range / copies / printer settings, plus a couple polish items.
Cross-platform stubs (`error.Unsupported`) ship on Win + Linux
where the macOS API has no portable counterpart yet.

### Added — macOS surface completion (2026-05-28)

Eleven items closing every macOS-only item from the post-v0.1.6
roadmap. Cross-platform stubs (`error.Unsupported`) ship on
Win + Linux where the macOS API has no portable counterpart yet.

- `desktop.power` macOS battery — `batteryPercent` / `isCharging`
  return real values via IOKit `IOPSCopyPowerSourcesInfo` +
  `IOPSCopyPowerSourcesList` + `IOPSGetPowerSourceDescription`,
  reading `kIOPSCurrentCapacityKey` / `kIOPSMaxCapacityKey` for
  the percentage and `kIOPSIsChargingKey` (CFBoolean) for AC
  state. Keys built at runtime via `CFStringCreateWithCString`
  since `IOPSKeys.h` `#define`s them as C string literals (not
  extern CFString symbols). Closes the only known per-platform
  null in `desktop.power`.
- `desktop.network` (new module) — `isOnline() bool`. macOS:
  `SCNetworkReachabilityCreateWithName("apple.com")` +
  `SCNetworkReachabilityGetFlags`, treating Reachable +
  !ConnectionRequired as online. Windows:
  `InternetGetConnectedState`. Linux: `getifaddrs` + scan for any
  non-loopback iface in `IFF_UP | IFF_RUNNING`.
- `desktop.fswatch` (new module) — `Watcher.init(allocator, path,
  cb, ctx)`. macOS: `FSEventStreamCreate` with file-events flag,
  scheduled on the main run loop, 1s coalescing latency; C
  trampoline reads the event-paths array and fires the Zig
  callback once per change. Windows + Linux return
  `error.Unsupported` (ReadDirectoryChangesW + inotify follow-ups).
- `desktop.hotkeys` (new module) — `Manager` that registers global
  hotkeys (fire even when app is blurred) via Carbon
  `RegisterEventHotKey` + `InstallEventHandler` on
  `GetApplicationEventTarget`. Public surface:
  `Modifiers { cmd, ctrl, option, shift }` packed struct +
  `register(id, mods, keycode)` + `unregister(id)`.
  Single-manager-per-process v1 (`g_singleton` routes the
  event-handler trampoline). Windows + Linux return
  `error.Unsupported`.
- `desktop.process` (new module) — `runCapture` (block + collect
  stdout / stderr + exit code) and `spawnDetached` (fire-and-
  forget, stdio ignored). Thin wrapper over `std.process.Child`
  with desktop-friendly defaults. Cross-platform stdlib reshape.
- `desktop.deep_link.registerScheme(scheme, bundle_id)` — runtime
  URL-scheme registration. macOS: LaunchServices
  `LSSetDefaultHandlerForURLScheme`. Complements the build-time
  `CFBundleURLTypes` path. Requires a bundled `.app` with the
  scheme already declared in `Info.plist` — bare `zig-out/bin/app`
  binaries return `error.Backend`. Windows + Linux return
  `error.Unsupported` (HKCU registry + xdg-mime follow-ups).
- `Clipboard.writeHtml(html)` / `readHtml(allocator)` — macOS uses
  `NSPasteboardTypeHTML` (`public.html`). Windows + Linux return
  `error.Unsupported` (CF_HTML header format + GtkClipboard
  `text/html` target are future bundles).
- `TrayOptions.icon_symbol` — macOS-only field reads an SF Symbol
  name (e.g. `"bolt.fill"`, `"doc.text"`) and renders via
  `+[NSImage imageWithSystemSymbolName:accessibilityDescription:]`
  (macOS 11+). Lets demos ship a real tray icon without bundling
  a PNG. Demo scaffold uses `"bolt.fill"`. Ignored on Win + Linux.
- `PrintOptions` extended — new fields `copies: u32 = 1`,
  `pages: ?PageRange = null` (`{ from, to }`), and
  `printer_name: ?[]const u8 = null`. macOS reads each through
  NSPrintInfo dictionary keys (`NSCopies` / `NSFirstPage` /
  `NSLastPage` + `NSPrintAllPages = false` /
  `[NSPrinter printerWithName:]` → `setPrinter:`) before
  `printOperationWithPrintInfo:` packages the job. Print info is
  copied off the shared singleton so settings don't bleed into
  later operations. Win + Linux ignore the extras for now.
- macOS `pumpUntilDone` re-entrancy hazard documented at
  `src/desktop/macos.zig`. Safe from IPC handlers (default mode);
  unsafe from inside another modal run loop. No code change.
- macOS `LSMinimumSystemVersion` bumped 10.15 → 11.0 in
  `templates/desktop/build.zig`'s Info.plist generator. Covers
  the shipped selectors that need 11+
  (`printOperationWithPrintInfo`, snapshot APIs, the new IOKit /
  SF Symbols / LaunchServices paths added this session).

### Framework linkage

Templates (both full + minimal) now link IOKit, CoreFoundation,
SystemConfiguration, CoreServices, Carbon on macOS. Root
`build.zig` mirrors the linkage on the host-target test artifact
so the framework's own headless tests resolve the symbols.

## [0.1.7] - 2026-05-27

Six post-`v0.1.6` bundles. Native print on all three backends,
a new minimal scaffold variant, a beefed-up demo scaffold, and
two framework bug fixes that surfaced once the demo scaffold
exercised more of the surface live.

### Added — Native print API (2026-05-27)

- `Window.printWithOptions(opts: PrintOptions) PrintError!void` on
  all three backends. Legacy `Window.print() void` preserved as a
  thin wrapper (`printWithOptions(.{}) catch {}`) so existing
  callers compile unchanged. New types in `options.zig`:
  `PrintDialogKind = enum { default, browser, system }`,
  `PrintOptions = struct { kind: PrintDialogKind = .default }`,
  `PrintError = error { Unsupported, Backend, Cancelled, OutOfMemory }`.
  macOS: `[NSPrintInfo sharedPrintInfo]` +
  `[WKWebView printOperationWithPrintInfo:]` +
  `[NSPrintOperation runOperation]`. `opts.kind` ignored (system
  dialog is the only path). Windows:
  `ICoreWebView2_16::ShowPrintUI` reached via QI from base `Wv2` to
  new `Wv2_16` interface; `default | browser` →
  `COREWEBVIEW2_PRINT_DIALOG_KIND_BROWSER`, `system` → `..._SYSTEM`.
  Edge WebView2 runtimes older than version 111 (March 2023) answer
  `E_NOINTERFACE` → `error.Unsupported`. `SLOT_WV2_16_ShowPrintUI =
  104` is hand-extracted from `WebView2.h`. Linux:
  `webkit_print_operation_new` + `webkit_print_operation_run_dialog`
  + `g_object_unref`; `WEBKIT_PRINT_OPERATION_RESPONSE_CANCEL` →
  `error.Cancelled`.

### Added — `--template minimal` scaffold variant (2026-05-27)

- `verve-cli new <dir> --desktop --template minimal` emits a
  single-window app with one IPC route and a static HTML page.
  Intended as a clean starting point for downstream apps that want
  to opt in to features one at a time instead of pruning the
  demo-rich scaffold. The minimal template ships:
  `build.zig` (stripped — no SSR / WASM / dev / smoke / bundle steps),
  `src/main.zig` (~30 lines), `src/handlers.zig` (one `greet` route
  formatting `Hello, <name>!`), `frontend/index.html` (form + input
  + button + greeting), responsive `style.css` (clamp + max-width
  28rem + dark-mode + focus rings), and the `tools/fetch_webview2.*`
  scripts (Windows prereq). `verve-cli` gained a `DesktopTemplate {
  full, minimal }` enum + `--template <name>` flag; `--template`
  with `--web` warns. The full (demo-rich) template is the default.

### Added — Desktop scaffold demo enhancements (2026-05-27)

- The full demo scaffold (`templates/desktop/`) grew six new IPC
  routes + matching feature cards, all wired through the existing
  Router + `dl.kv` markup pattern:
  - `fetch_url` — real outbound HTTP via `std.http.Client` (with
    User-Agent + Accept headers) hitting `api.github.com/repos/
    ziglang/zig`, JSON parsed server-side with `ignore_unknown_fields`,
    returns full_name / description / stars / forks. Network / HTTP /
    parse failures map to explicit status strings.
  - `system_info` — `osVersion` + `locale` + `cpuCount` +
    `totalMemory` + `uptime` via `desktop.system`. Best-effort:
    per-field failures collapse to defaults.
  - `disk_space` — `desktop.disk.spaceAt(homeDir)` — total +
    available bytes.
  - `open_file` — native NSOpenPanel / IFileOpenDialog /
    GtkFileChooser via `window.openFileDialog`, plus `statFile` for
    size. Cancelled → `status="cancelled"`.
  - `window_action` — switch on action string → `minimize` /
    `maximize` / `restore` / `center` / `setFullscreen(true|false)`.
  - `deep_link_test` — fires `Window.deliverUrl` with a synthetic
    `verve://app/demo` URL so the deep-link card round-trip can be
    exercised from inside the app (no need to leave + `open
    verve://...` from a terminal).
- `RouterCtx` gained `environ: std.process.Environ` (threaded from
  `init.minimal.environ`) so system + paths handlers can read XDG /
  HOME / LANG.
- `frontend/style.css` rewritten responsive: CSS grid
  `repeat(auto-fit, minmax(320px, 1fr))` replaces the fixed-width
  card stack; cards reflow into 1/2/3/4 columns. Fluid `clamp()`
  typography + padding + `max-width: 1280px` container. Mobile
  breakpoint at 600px collapses `.row` to vertical with full-width
  buttons. New themed `.result-panel` + `.result-panel.{loading,
  ok, error}` patterns; new `dl.kv` markup for key/value readouts.
  Log card spans the full row at every width via
  `main > section:last-child { grid-column: 1 / -1 }`.

### Fixed — `desktop.disk` integer overflow on macOS (2026-05-27)

- `src/desktop/disk.zig`'s `StatvfsPosix` extern struct declared
  every block-count field as `c_ulong` (64-bit on both LP64
  targets). On macOS, `fsblkcnt_t` is actually `unsigned int` (32
  bits), so `f_blocks` read picked up the high half of `f_bfree`
  as garbage — multiplying by `f_frsize` panicked with `integer
  overflow` the first time a scaffold IPC handler called
  `desktop.disk.spaceAt` on a real volume. Fix: alias
  `fsblkcnt_t = if (macos) c_uint else c_ulong` and use it for the
  three block-count + three file-count fields. No public API
  change.

### Fixed — `desktop.system` Zig 0.16 + Error set (2026-05-27)

- `system.zig` `uptimeMacos` called `std.time.timestamp()` — not a
  member of `std.time` in Zig 0.16. Replaced with libc `time(null)`
  extern.
- `system.zig` `localeMacos` + `osVersionMacos` returned
  `error.Backend` but the declared `Error` set is
  `{ Unsupported, OutOfMemory, NotFound }`. Swapped to
  `error.Unsupported` (closest in-set match). Both bugs were
  latent because no framework caller exercised the paths before
  the v0.1.7 scaffold demo wired them through.

## [0.1.6] - 2026-05-26

Three small post-`v0.1.5` additions. Power state, file-reveal,
uptime.

### Added — Power / battery state (2026-05-26)

- New `desktop.power` module: `batteryPercent() ?u32` +
  `isCharging() bool`. Windows: `GetSystemPowerStatus`
  (kernel32) reads `BatteryLifePercent` + `ACLineStatus`.
  Linux: posix open + read on
  `/sys/class/power_supply/BAT[0-9]/capacity` + `/status`
  (iterates BAT0..BAT9). macOS returns null / false — IOKit
  integration deferred until scaffold links the IOKit framework.

### Added — shell.showInFolder (2026-05-26)

- New `desktop.shell.showInFolder(allocator, path) Error!void`
  pairs with `openUrl`. Reveals a file in the OS file manager.
  macOS: `[NSWorkspace selectFile:inFileViewerRootedAtPath:]`
  (Finder pre-selects). Windows: `ShellExecuteW(NULL, "open",
  "explorer.exe", "/select,\"<path>\"", ...)` (Explorer
  pre-selects). Linux: `xdg-open <parent_dir>` — freedesktop
  has no portable "open + select" verb across file managers.

### Added — System uptime (2026-05-26)

- `desktop.system.uptime() u64` returns seconds since boot.
  macOS: `sysctlbyname("kern.boottime")` + `time` delta.
  Windows: `GetTickCount64() / 1000`. Linux: parses the
  integer portion of the first float in `/proc/uptime`.

## [0.1.5] - 2026-05-26

Four small post-`v0.1.4` window + system additions.

### Added — Window attention request (2026-05-26)

- `Window.requestAttention(critical: bool)` pulses dock icon /
  flashes taskbar / sets WM urgency hint. macOS: `[NSApp
  requestUserAttention:]` with NSCriticalRequest /
  NSInformationalRequest. Windows: `FlashWindowEx(FLASHW_ALL [|
  FLASHW_TIMERNOFG])` with new FLASHWINFO extern struct. Linux:
  `gtk_window_set_urgency_hint(TRUE)`.

### Added — System resource info (2026-05-26)

- `desktop.system.cpuCount() usize` — logical CPU count incl.
  hyperthreads (fallback 1).
- `desktop.system.totalMemory() u64` — physical RAM bytes
  (fallback 0).
- Thin wrappers over `std.Thread.getCpuCount` and
  `std.process.totalSystemMemory`.

### Added — Disk space query (2026-05-26)

- New `desktop.disk` module: `spaceAt(allocator, path)
  Error!Space`. `Space { total, available, free }` in bytes.
  POSIX: `statvfs` (f_blocks/f_bavail/f_bfree × f_frsize).
  Windows: `GetDiskFreeSpaceExW`. Useful for capacity dashboards
  + pre-flight checks before large writes.

### Added — Window state queries (2026-05-26)

- `Window.isMinimized()` / `isMaximized()` / `isFullscreen()` on
  all 3 backends. macOS: `isMiniaturized` / `isZoomed` /
  `styleMask` bit-check. Windows: `IsIconic` / `IsZoomed` from
  user32 + cached `fullscreen` flag. Linux:
  `gdk_window_get_state` mask checks + `gtk_window_is_maximized`.

## [0.1.4] - 2026-05-26

Six post-`v0.1.3` polish bundles. Standard directories, system
queries, launch-at-login, plus webview + window controls
(zoom + scale factor + system bell).

### Added — Standard directories (2026-05-26)

- New `desktop.paths` module: `dataDir` / `cacheDir` /
  `configDir` / `homeDir` / `tempDir`. Takes
  `std.process.Environ` (typically `init.minimal.environ`) +
  allocator + app name; returns owned UTF-8 absolute path.
- macOS: `~/Library/Application Support/<app>` +
  `~/Library/Caches/<app>`. Windows: `%APPDATA%\<app>` +
  `%LOCALAPPDATA%\<app>`. Linux: XDG ($XDG_DATA_HOME /
  $XDG_CACHE_HOME / $XDG_CONFIG_HOME) with
  `$HOME/.local/share` / `$HOME/.cache` / `$HOME/.config`
  fallbacks. Pure stdlib.

### Added — System info (2026-05-26)

- New `desktop.system` module:
  `locale(allocator, environ) ![]u8` returns IETF-style locale
  tag (e.g. `en_US`); `osVersion(allocator) ![]u8` returns the
  host OS version string. macOS:
  `[NSLocale currentLocale].localeIdentifier` +
  `[NSProcessInfo processInfo].operatingSystemVersionString`.
  Windows: `GetUserDefaultLocaleName` + `RtlGetVersion`
  (OSVERSIONINFOEXW from ntdll.dll). Linux: `LC_ALL` / `LANG`
  env vars with `.UTF-8` / `@modifier` suffixes stripped, +
  `/etc/os-release` `PRETTY_NAME` parse.

### Added — Window zoom level (2026-05-26)

- `Window.setZoom(level)` / `Window.getZoom()` on all 3
  backends. `1.0` = 100%. macOS: `WKWebView setPageZoom:` /
  `pageZoom`. Windows: `ICoreWebView2Controller::get_ZoomFactor`
  / `put_ZoomFactor` (vtSlots 11 / 12). Linux:
  `webkit_web_view_set_zoom_level` / `_get_zoom_level`.

### Added — System bell + processId (2026-05-26)

- `desktop.system.beep()` triggers the OS audible alert
  (NSBeep / MessageBeep / stdout BEL).
- `desktop.system.processId()` returns the current PID as u32
  (POSIX `getpid` / Win `GetCurrentProcessId`).

### Added — Auto-launch on login (2026-05-26)

- New `desktop.autostart` module: `enable(allocator, io,
  environ, opts)` / `disable(...)` / `isEnabled(...)`.
  User-scoped (no admin prompt). macOS writes
  `~/Library/LaunchAgents/<name>.plist`; Windows writes
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` registry
  value via advapi32; Linux writes
  `~/.config/autostart/<name>.desktop`. `Options` struct carries
  `name` / `exe_path` / `display_name` / `args`. Pure stdlib +
  per-platform externs.

### Added — Window scale factor (2026-05-26)

- `Window.scaleFactor()` returns HiDPI multiplier of the
  window's current screen as f32. macOS:
  `[window backingScaleFactor]`. Windows: `GetDpiForWindow(hwnd)
  / 96.0`. Linux: `gtk_widget_get_scale_factor`.

## [0.1.3] - 2026-05-26

Seven post-`v0.1.2` polish bundles. Closes the navigation + shell
+ display ergonomics gap.

### Added — Window event callbacks (2026-05-26)

- `WindowOptions.on_resize` / `on_focus` / `on_close` + matching
  `Window.setResizeHandler` / `setFocusHandler` / `setCloseHandler`
  on all 3 backends. `ResizeHandler` fires with new content size;
  `FocusHandler` with focused/blurred state; `CloseHandler` returns
  `true` to allow close, `false` to keep window open (for "Unsaved
  changes?" prompts).
- macOS: `VerveWindowDelegate` NSObject subclass with
  `windowDidResize:` + `windowDidBecomeKey:` + `windowDidResignKey:`
  + `windowShouldClose:`. Windows: `WM_SIZE` + `WM_ACTIVATE` +
  `WM_CLOSE` wndProc cases. Linux: `g_signal_connect_data` on
  `configure-event`, `focus-in-event`, `focus-out-event`,
  `delete-event`.

### Added — Window min/max size (2026-05-26)

- `Window.setMinSize(w, h)` / `setMaxSize(w, h)` on all 3 backends;
  `(0, 0)` clears the bound. macOS: `setContentMinSize:` /
  `setContentMaxSize:`. Windows: new `WM_GETMINMAXINFO` wndProc
  case patches `ptMinTrackSize` / `ptMaxTrackSize`. Linux:
  `gtk_window_set_geometry_hints` with `GDK_HINT_MIN_SIZE` /
  `GDK_HINT_MAX_SIZE` flags.

### Added — Multi-display enumeration (2026-05-26)

- New `desktop.displays` module: `list(allocator) Error![]Display`.
  `Display { x, y, width, height, scale, primary }`. macOS:
  `[NSScreen screens]` + `backingScaleFactor` with Y-flip into
  top-left coords for cross-platform parity. Windows:
  `EnumDisplayMonitors` + `GetMonitorInfoW` + `GetDpiForMonitor`
  (Shcore.dll). Linux: `gdk_display_get_default` +
  `gdk_display_get_n_monitors` / `_get_monitor` / `_get_geometry` /
  `_get_scale_factor`. Scaffold `build.zig` gains `Shcore` link
  on the Windows branch.

### Added — Shell helpers (2026-05-26)

- New `desktop.shell` module: `openUrl(allocator, url) Error!void`.
  Hands a URL to the OS shell so it opens externally (default
  browser for http/https, registered handler for mailto/custom
  schemes). macOS: `[NSWorkspace openURL:]`. Windows:
  `ShellExecuteW(NULL, "open", url, NULL, NULL, SW_SHOWNORMAL)`.
  Linux: `posix.fork` + `execvp("xdg-open", ...)`.

### Added — Navigation helpers (2026-05-26)

- `Window.reload()` / `goBack()` / `goForward()` on all 3 backends.
  macOS: `WKWebView reloadFromOrigin` / `goBack` / `goForward`.
  Windows: vtSlots 31 / 40 / 41 on ICoreWebView2. Linux:
  `webkit_web_view_reload` / `_go_back` / `_go_forward`.

### Added — Navigation queries (2026-05-26)

- `Window.canGoBack()` / `canGoForward()` / `currentUrl(allocator)
  ![]u8` / `currentTitle(allocator) ![]u8` on all 3 backends.
  Pairs with `goBack` / `goForward` for history-aware UI; URL +
  title getters enable bookmark / share / address-bar features.
  macOS: WKWebView selectors + new `nsStringToOwnedUtf8` helper.
  Windows: vtSlots 38 / 39 / 4 / 48 + shared `wv2StringGetter`
  for LPWSTR-out + UTF-16→UTF-8 + `CoTaskMemFree`. Linux:
  `webkit_web_view_can_go_back` / `_can_go_forward` /
  `_get_uri` / `_get_title`.

### Added — Page title auto-sync (2026-05-26)

- IPC `shim_js` now polls `document.title` every 500ms + posts a
  `__verve_title:<title>` marker through the native bridge.
  Each backend's script-message trampoline intercepts the prefix
  before forwarding to the user's MessageHandler, calling the
  native title setter (`setTitle:` / `gtk_window_set_title` /
  `SetWindowTextW`). Pages mutating `<title>` propagate to the
  OS title bar / taskbar / window list with no app-side code.

## [0.1.2] - 2026-05-26

Four post-`v0.1.1` bundles. Window state + lifecycle + checked
auto-updater.

### Added — Auto-updater check (2026-05-26)

- New `desktop.updates` module:
  `checkForUpdate(allocator, feed_url, current_version) Error!?UpdateInfo`.
  Pure stdlib (`std.http.Client` + `std.json`); identical on all
  3 platforms; no native frameworks linked. Returns `null` when
  the caller is already up to date; otherwise `{ version,
  download_url, notes }` — caller owns each string. Lower-level
  `parseUpdateFeed(body, current)` lets apps drive their own HTTP
  fetch. SemVer compare via `compareSemver` (numeric-prefix
  ordering, tolerates leading `v` + `-rc1`-style suffixes).
- Applying the update — download, signature verify, swap binary,
  restart — stays out of scope. That's Sparkle / Squirrel /
  AppImageUpdate per-platform polish, deferred.

### Added — Window always-on-top + opacity (2026-05-26)

- `Window.setAlwaysOnTop(bool)` toggles whether the window floats
  above normal-stack peers. `Window.setOpacity(f64)` in `[0.0,
  1.0]`. macOS: `setLevel:NSFloatingWindowLevel` + `setAlphaValue:`
  / `setOpaque:`. Windows: `SetWindowPos(HWND_TOPMOST)` +
  `SetLayeredWindowAttributes(LWA_ALPHA)` with `WS_EX_LAYERED`
  stamped via `SetWindowLongPtrW`. Linux:
  `gtk_window_set_keep_above` + `gtk_widget_set_opacity`.

### Added — Window geometry + lifecycle (2026-05-26)

- Seven new methods: `setSize`, `setPosition`, `center`,
  `minimize`, `maximize`, `restore`, `setFullscreen`. macOS:
  `setContentSize:` / `setFrameTopLeftPoint:` / `center` /
  `miniaturize:` / `zoom:` / `deminiaturize:` /
  `toggleFullScreen:`. Windows: `SetWindowPos` + `ShowWindow(SW_*)`;
  fullscreen via strip-WS_OVERLAPPEDWINDOW + monitor-size
  SetWindowPos (saved style/rect cache on `WindowCtx`). Linux:
  `gtk_window_resize` / `_move` / `_iconify` / `_maximize` /
  `_unmaximize` / `_fullscreen` / `_unfullscreen` /
  `_set_position(CENTER)` / `_present`.

### Added — Window visibility + focus (2026-05-26)

- `Window.show()` / `hide()` / `focus()` / `setResizable(bool)`
  on all 3 backends. macOS: `makeKeyAndOrderFront:` +
  `activateIgnoringOtherApps:` / `orderOut:` / styleMask toggle.
  Windows: `ShowWindow(SW_SHOW/HIDE/RESTORE)` +
  `SetForegroundWindow`; resizable via `WS_THICKFRAME` |
  `WS_MAXIMIZEBOX` + `SetWindowPos(SWP_FRAMECHANGED)`. Linux:
  `gtk_widget_show_all` / `_hide` / `gtk_window_present` /
  `_set_resizable`. Template demo's tray "Show window" item now
  actually calls `window.show()` + `window.focus()` (was faked
  with evalJs before).

## [0.1.1] - 2026-05-26

Six P3 bundles shipped post-`v0.1.0`. Mostly closes the desktop
backlog — only GTK4, WinRT Toast (polish), full UIA / NSAccessibility
providers, and the auto-updater remain.

### Added — Custom tray icons (2026-05-26)

- `Tray.setIcon(path)` + `TrayOptions.icon_path` on all 3 backends.
  Replaces the stock `IDI_APPLICATION` glyph on Windows; macOS uses
  any `NSImage`-readable format with `setTemplate:true` for menu-bar
  tinting; Linux routes through `app_indicator_set_icon_full`
  (accepts absolute PNG path or theme icon name). `owns_icon` on
  Windows tracks LoadImageW-loaded HICONs vs the shared stock icon
  so `DestroyIcon` only fires on the owned variant.

### Added — Win balloon notifications (2026-05-26)

- Replaces `error.Unsupported` in `notifications.show` on Windows
  with `Shell_NotifyIconW(NIM_MODIFY, NIF_INFO)` against the active
  `desktop.tray` icon. Renders as a Win10/11 balloon tip (older
  shell) / Action Center entry (modern). Requires `desktop.tray.init`
  to have run first — without an active tray, the call returns
  `error.Backend`. WinRT Toast (`ToastNotificationManager`) deferred
  as polish.

### Added — Hicolor / Linux desktop integration (2026-05-26)

- New `zig build install-icons` step in `templates/desktop/build.zig`
  stages a freedesktop icon-theme tree + `.desktop` launcher entry
  under `zig-out/share/` for user (`~/.local/share`) or system
  (`/usr/share`) install. Build options:
  - `-Dlinux-icon=<path>` (single PNG → `scalable/apps/<name>.png`)
  - `-Dlinux-icon-<N>=<path>` for N in
    `{16,22,24,32,48,64,96,128,256,512}` (per-size variants)
  - `-Dlinux-categories=<x;y;>`, `-Dlinux-comment=<text>`,
    `-Dlinux-generic-name=<text>`, `-Dlinux-exec=<text>` for the
    `.desktop` file fields.
  Step is gated on `target.result.os.tag == .linux`.

### Added — Drag-drop with native file paths (2026-05-26)

- `Window.setDragDropHandler(cb, ctx)` + `WindowOptions.on_drag_drop`
  on all 3 backends. Single callback `fn(ctx, paths: []const []const u8)`
  fires with UTF-8 absolute filesystem paths — the browser
  `DataTransfer` API hides these by design.
- macOS: `VerveDragWindow` NSWindow subclass via
  `objc_allocateClassPair` + `object_setClass`;
  `registerForDraggedTypes:` with `public.file-url`;
  `performDragOperation:` reads
  `[NSPasteboard readObjectsForClasses:@[NSURL.class]]`.
- Windows: minimal `IDropTarget` COM impl embedded in `WindowCtx`
  (`drop_target` field, mirrors the env/ctrl/msg/res handler embed
  pattern). `OleInitialize` + `RegisterDragDrop`; `Drop` reads
  `IDataObject::GetData(CF_HDROP)` → `DragQueryFileW`. `RevokeDragDrop`
  on `WM_DESTROY`.
- Linux: `gtk_drag_dest_set(window, GTK_DEST_DEFAULT_ALL, NULL, 0,
  GDK_ACTION_COPY)` + `gtk_drag_dest_add_uri_targets` +
  `drag-data-received` signal. Strips `file://` URI prefix.

In-app drag sources (drags originating inside the WebView) remain
out of scope — those flow through standard HTML5 drag-drop events.

### Added — Print API (2026-05-26)

- `Window.print()` on all 3 backends. v1 dispatches via the page's
  `window.print()` — each native engine (WKWebView / WebView2 /
  WebKitGTK) renders its built-in print UI off that call. Native
  print APIs (`NSPrintOperation` / `ICoreWebView2_16::ShowPrintUI` /
  `webkit_print_operation_run_dialog`) deferred as polish for
  silent print + advanced controls.

### Added — Accessibility label API (2026-05-26)

- `Window.setAccessibilityLabel(text)` on all 3 backends. macOS:
  `[NSWindow setAccessibilityLabel:]`. Linux:
  `gtk_widget_get_accessible(window)` + `atk_object_set_name`.
  Windows: routes through `setTitle` (no separate Win32 a11y-label
  channel without a custom UIA provider; deferred).

### CLI

- No `verve-cli` changes vs `v0.1.0`. The `--release` / `--release-hash`
  flags shipped with `v0.1.0` continue to work — point at any
  released tag (`--release v0.1.1`).

## [0.1.0] - 2026-05-26

First tagged release. Closes P1 (#16–#23), every P2 platform port,
and the high-frequency P3 surface (clipboard, single-instance,
color-scheme follow, app icons, native menu bars on all 3,
deep-link URL handlers, tray icons + notifications, tray click
handlers + submenus).

### Added — Tray click handlers + submenus (2026-05-26)

- **Expanded `desktop.tray` API.** `TrayMenuItem { label, id,
  enabled, children }` value type — null label = separator,
  non-empty children = submenu parent. `TrayOptions` grew `menu`,
  `on_click` + `on_click_ctx`, `on_menu_item` + `on_menu_item_ctx`.
  ABI matches `MessageHandler` / `UrlOpenHandler` /
  `ColorSchemeHandler`. New `Tray.setMenu(items)` (deep-copies),
  `setClickHandler`, `setMenuItemHandler`. `Tray.impl` is now
  heap-allocated so callback singletons see a stable address after
  `init` returns by value.
- **macOS.** NSMenu via `objc_msgSend`; items target a process-wide
  `VerveTrayTarget` NSObject (registered lazily via
  `objc_allocateClassPair`) with `verveTrayItem:` /
  `verveTrayClick:` selectors. Each `NSMenuItem.setTag:` carries
  the user id; the trampoline reads `[sender tag]` and dispatches.
- **Windows.** `NOTIFYICONDATAW.uCallbackMessage = WM_VERVE_TRAY`
  (= `WM_USER + 100`, declared pub in `windows.zig`). wndProc
  forwards mouse events to `tray_dispatch_message` and `WM_COMMAND`
  IDs in the `0xC000` block to `tray_dispatch_command`. Right
  click / WM_CONTEXTMENU show the menu via `TrackPopupMenu` with
  the MSDN `SetForegroundWindow` + `PostMessage(WM_NULL)` dance.
  Tray IDs use `0xC000 | (user_id & 0x0FFF)` — no collisions with
  the default `0x8000` File/Edit range.
- **Linux.** GtkMenu via `gtk_menu_item_new_with_label` +
  `gtk_menu_shell_append`; submenus via
  `gtk_menu_item_set_submenu`; disabled rows via
  `gtk_widget_set_sensitive`. Each leaf gets `g_signal_connect_data`
  with an allocator-owned `ItemBox { *LinuxTray, id }` as
  user_data; boxes freed in `deinit`. AppIndicator has no
  icon-click signal so `on_click` is a no-op when a menu is set.
- **Template demo.** 4-item tray menu (Show window / Notify / sep /
  Quit) wired to a new `handlers.onTrayItem`; new "Tray menu" card
  in components; golden smoke checksum 284 → 605.
- **v1 limitation.** Single-tray-per-process — `g_macos_tray` /
  `g_windows_tray` are unguarded singletons. Multi-tray would need
  per-target ivars + an HWND-keyed registry. Deferred.

### Added — Tray icons + native notifications (2026-05-25)

- **New `desktop.tray` module.** `tray.init(allocator, &window,
  .{ .label, .tooltip })` creates a system-tray / status-bar icon;
  `setTooltip(text)` updates the hover text; `deinit` removes it.
  macOS: `NSStatusItem` from `[NSStatusBar systemStatusBar]`.
  Windows: `Shell_NotifyIconW(NIM_ADD)` with stock
  `IDI_APPLICATION` icon (`NIF_ICON | NIF_TIP`). Linux:
  `app_indicator_new` (libayatana-appindicator3) with an empty
  `GtkMenu` attached because some Ayatana versions silently refuse
  to render the icon without one. Click handlers + submenus are
  deferred to a future bundle.
- **New `desktop.notifications` module.** `notifications.show(allocator,
  .{ .title, .body })`. macOS: `NSUserNotification` +
  `NSUserNotificationCenter.deliverNotification:`. Linux: `notify_init`
  + `notify_notification_new` + `notify_notification_show` (libnotify).
  Windows returns `error.Unsupported` — Toast notifications need
  COM + AUMID + Start-menu registration, deferred to a future
  bundle. Apps that need Win notifications today combine
  `desktop.tray` with a manual `Shell_NotifyIconW(NIF_INFO)` call
  against the tray icon.
- **Backend exposure.** `src/desktop/windows.zig` gains `hwndOf(window)`
  so sibling modules can reach the underlying HWND without going
  through the cross-platform `Window` facade.
- **Template demo wiring.** Scaffold `main.zig` opens a tray icon
  on startup; `handlers.zig` ships a `notify` IPC route that fires
  a native notification; `components.zig` adds a "Notify" button
  card.

### Added — Win/Linux warm-launch URL forwarding (2026-05-25)

- **New `desktop.deep_link` module** with two halves:
  `forwardToRunningInstance(allocator, name, url)` (second-instance
  side) and `startListener(window, name)` (running-instance side).
  macOS makes both calls no-ops because `NSAppleEventManager`
  already routes URLs to the running process; Win + Linux now
  implement real cross-process delivery.
- **Windows** — `FindWindowW("VerveWindow", null)` locates the
  running app's HWND; `SendMessageW(WM_COPYDATA)` ships the URL
  with a `0x55524C00` ("URL\0") `dwData` sentinel so unrelated
  WM_COPYDATA traffic doesn't trip the receiver. The wndProc
  WM_COPYDATA case validates the sentinel, bounds-checks the
  payload (≤4 KB), and fires `on_url_open` on the matched
  `WindowCtx`.
- **Linux** — abstract `AF_UNIX SOCK_DGRAM` socket bound to
  `\0verve-deeplink-<single_instance_name>`. Sender `connect`s +
  `send`s a single datagram with the URL bytes. Receiver wraps the
  bound fd in a `GIOChannel` with a `G_IO_IN` watch so the GTK
  main loop dispatches inbound URLs; `close_on_unref(true)` cleans
  the fd up when the window is destroyed.
- **Template `main.zig`** — second-instance `AlreadyRunning`
  branch now calls `forwardToRunningInstance(allocator, name, u)`
  when `--url <u>` was provided, then exits. After the primary
  instance opens its window it calls
  `deep_link.startListener(&window, instance_name)` to bind the
  receive side.

### Added — Desktop deep-link URL handlers (2026-05-25)

- **`Window.setUrlOpenHandler(cb, ctx)` + `Window.deliverUrl(url)`**
  on the public surface; new `UrlOpenHandler` type and
  `on_url_open` / `on_url_open_ctx` fields on `WindowOptions`.
- **macOS — `NSAppleEventManager` handler** for
  `kInternetEventClass`/`kAEGetURL` (FourCharCode `'GURL'`,
  0x4755524C). Installs lazily on the first non-null
  `setUrlOpenHandler` call. Cocoa queues URL events that arrived
  before the AEH installed, then drains them on the next run-loop
  spin — so a `verve://...` URL clicked from Finder before
  `Window.init` even ran still reaches the callback.
- **Windows + Linux — cold-launch only.** Backend stores the
  callback on `WindowCtx`; the scaffold template's `main.zig`
  parses `--url <u>` or any positional starting with `verve://`
  and feeds it through `Window.deliverUrl(url)` after the window
  opens. Warm-launch second-instance forwarding (`WM_COPYDATA` on
  Win, abstract `AF_UNIX` socket on Linux) is a follow-up.
- **Scaffold `build.zig` — `-Durl-scheme=<name>`.** Injects
  `CFBundleURLTypes` into the macOS `Info.plist` so Launch
  Services routes `<scheme>://...` URLs to the .app.
- **Template demo wiring.** `handlers.zig` ships an `onUrlOpen`
  example that logs + dispatches the URL into the page via a new
  `window.verve.handleDeepLink` bridge hook; `components.zig`
  gains a "Deep link" card that mirrors the most-recent URL.

### Added — Desktop native menu bars on Windows + Linux (2026-05-25)

- **Default menu bar on every backend.** `install_default_menu = true`
  (the existing flag, previously honored only on macOS) now stamps a
  File + Edit bar on Windows and Linux for parity with the macOS
  App + Edit + Window default. Only File→Quit (Ctrl+Q) binds a real
  OS accelerator; Edit items render the shortcut hint in the label
  but do not attach an accelerator, because WebView2 and WebKitGTK
  handle Ctrl+C/V/X/Z/Y/A natively inside text inputs and a real
  OS-level binding would consume the key event before the webview
  saw it.
- **Win32 wiring.** `CreateMenu` + `CreatePopupMenu` + `AppendMenuW`
  + `SetMenu`; one-entry `HACCEL` driven through
  `TranslateAcceleratorW` in the main `GetMessageW` loop. Quit posts
  `WM_CLOSE` so multi-window last-window-quit semantics keep firing
  through the existing HWND registry. Accelerator table freed in
  `WM_DESTROY`.
- **GTK wiring.** `GtkBox(GTK_ORIENTATION_VERTICAL)` wrap stacks
  `gtk_menu_bar_new` above the webview; `gtk_accel_group_new` carries
  Ctrl+Q; Quit routes through `gtk_widget_destroy(window)` so the
  `live_windows` counter triggers `gtk_main_quit` only on the last
  close. Layout switch is conditional on the flag — opt-out apps keep
  the unchanged `gtk_container_add(window, webview)` tree.

### Added — Desktop framework polish (2026-05-24)

- **`--dev <dir>` runtime asset fallback.** Desktop scheme handler
  checks `<dir>/<path>` before the embedded `public_assets` table
  on every request, so hand-written frontend assets (`style.css`,
  `verve_desktop.js`, …) reload with Cmd+R instead of triggering a
  full process-restart rebuild. Rejects `..` and post-strip
  absolute paths; 16 MB per-file ceiling. Wired through
  `WindowOptions.dev_assets: ?DevAssetsConfig`.
- **Win + Linux ports of `openFileDialog` / `saveFileDialog` /
  `showAlert`.** Linux uses `GtkFileChooserNative` + `GtkMessageDialog`;
  Windows uses `GetOpenFileNameW` / `GetSaveFileNameW` + `MessageBoxW`.
  Win folder-picking returns `Unsupported` (needs `IFileOpenDialog`);
  custom alert labels honored on mac + Linux, mapped to standard
  buttons on Windows.
- **Win + Linux `takeSnapshotPng` ports.** Linux uses
  `webkit_web_view_get_snapshot` → cairo PNG; Windows uses
  `ICoreWebView2::CapturePreview` → `IStream` → `WriteFile`. Same
  byte-deterministic PNG output as the macOS reference.
- **Single-instance enforcement.**
  `desktop.single_instance.acquire(allocator, name)` returns an
  opaque `Lock` held for process lifetime. macOS + Linux use POSIX
  `flock(LOCK_EX | LOCK_NB)` on `<TMPDIR>/verve.<name>.lock`;
  Windows uses `CreateMutexW` under `Local\Verve.<name>`. Scaffold
  template wires it at startup automatically.
- **Cross-platform clipboard read/write.** `Window.clipboard()`
  returns a handle with `writeText` / `readText`. macOS:
  `NSPasteboard.generalPasteboard`; Windows: `OpenClipboard` +
  `CF_UNICODETEXT` + HGLOBAL ownership transfer; Linux:
  `gtk_clipboard_get(CLIPBOARD)` + `set_text` / `wait_for_text` +
  `gtk_clipboard_store`.
- **`Window.colorScheme()`** returns `.light` / `.dark` /
  `.unknown`. macOS: `[NSApp.effectiveAppearance].name`; Windows:
  `RegGetValueW(HKCU\…\Personalize\AppsUseLightTheme)`; Linux:
  GtkSettings' `gtk-application-prefer-dark-theme`. Pair with
  `Window.setColorSchemeHandler(cb, ctx)` for live change events
  via NSDistributedNotificationCenter (mac), WM_SETTINGCHANGE
  (win), GtkSettings notify signal (linux).
- **App icons (macOS `.app` bundle).** Scaffold `build.zig` gains
  a `-Dicon=<path>` option. Bundle step copies the supplied
  `.icns` into `Contents/Resources/AppIcon.icns` and injects
  `CFBundleIconFile = "AppIcon"` into the generated Info.plist.
  Absolute and build-root-relative paths both work.

### Fixed — Desktop framework

- **`openChildWindow` crash on multi-window apps.** The macOS
  backend re-registered `VerveSchemeHandler` and
  `VerveMessageHandler` Obj-C classes for every `Window.init`,
  but the Objective-C runtime rejects duplicate class names with
  `objc_allocateClassPair failed`. Classes are now cached at
  module scope and reused for every window.
- **`webview2.pinned.txt` SHA-512 populated.** Previously blank
  with TODO; reproducible Windows builds now actually verify the
  downloaded SDK. Also fixed `fetch_webview2.sh` `cut -d= -f2`
  truncating the trailing `==` base64 padding.
- **CI smoke server CSRF.** `--csrf=disable` added to the
  workflow's smoke-test invocation; form-encoded `/api/<fn>` POSTs
  no longer fail with `403`.
- **`verve-cli new <hyphenated-dir>`.** Basename-derived package
  names previously errored with `InvalidName` on hyphens. Hyphens
  / dots in basename now sanitize to `_`; explicit `--name=<n>`
  keeps the strict validation.

### Fixed — Docs

- **`docs/11-desktop-roadmap.md` #18 status.** Item was marked open
  even though commits 49b053d (J1 build-time SSR) and 3338d45
  (J2+J3 WASM + bridge) had landed. Doc now reflects shipped state.

## [0.1.0] — 2026-05-21

First public release. Server-side rendering with fine-grained
reactivity, a wasm32-freestanding client runtime that hosts the
real Signal/Effect graph, per-island WASM code-splitting, and a
single-binary distribution — all in pure Zig 0.16, zero external
runtime dependencies.

### Added — Routing + rendering

- Comptime route parser with path parameters (`/work/:slug`),
  wildcards (`/files/*rest`), and nested layouts via
  `ctx.outlet()`.
- `Route.layout` for grouping child routes under a shared shell.
- `ProtectedRoute` guards + `Redirect` sentinel
  (`ctx.redirect("/login")`).
- `ctx.location` (`useLocation`) with lazy query parsing +
  `isActive`.
- `RequestMeta` exposing cookies, Accept-Language, User-Agent,
  Origin, Host.
- Streaming HTML output via `std.http.Server`, chunked transfer
  encoding, no full-body buffering.

### Added — Reactivity (server + WASM client)

- Full SolidJS/Leptos-style reactive runtime: `Signal`,
  `Effect`, `Owner`, `Store`, `Resource`.
- Reactive `ErrorBoundary` — `Signal(?anyerror)` with
  `captureError` / `reset`.
- `untrack` / `batch` escape hatches.
- Per-request Owner with LIFO `on_cleanup` disposal.
- WASM client hosts the real reactive graph — `registerI32` /
  `registerStr` / `registerBool` / `registerF32` allocate
  Signals whose `on_set` hook drives DOM updates.
- 256 KB per-frame scratch allocator separate from the
  long-lived bump heap so reactive memory usage stays bounded by
  the largest single-frame render.

### Added — Keyed-list reconciler

- LIS-based planner emits the minimum (insert | move | remove)
  op sequence to turn the live DOM into a new key order.
- `ForEachHandle` caches the parent's current key order;
  `update(arena, new_keys, new_html)` diffs against the cache
  and dispatches DOM ops.
- `bindForEach(handle, ctx, render_fn)` ties a list-valued
  computation into the reactive graph — closure re-runs when any
  tracked Signal changes, automatically reconciles.

### Added — Components + head slots

- Arena-backed `*Node` tree with fluent chain methods.
- Head slot accumulator — `setTitle` / `metaTag` / `linkTag` /
  `jsonLd` with explicit priority + replace-not-append semantics.
- `provide` / `use` DI through the owner chain.
- `Slot` / `SlotMap` named-children API.
- `show` / `forEach` / `portal` control-flow helpers (server +
  reactive client-side via the reconciler).
- `NodeRef` typed handles + `data-ref` markers.

### Added — Actions / server functions

- Comptime dispatcher walks `app.Actions` to expose every
  `pub fn` as `POST /api/<name>`.
- Form-encoded bodies URL-decoded; JSON bodies parsed via
  `std.json`. Return types may be `void`, `!void`, `T`, or `!T`.
- `ctx.serverFn(f, args)` — server-side direct call.
- **Build-time codegen** (`tools/server_fn_codegen.zig`) emits
  `app_client.zig` with one typed wrapper per Action: native
  `<name>(arena, args) → Ret` plus WASM-callable
  `<name>_post(arena, args) → void` (JSON-serialize + JS-bridge
  fetch).
- Auto-303 redirect to `Referer` on form POSTs — works without
  any client-side JS.

### Added — Islands (per-island WASM chunks)

- `verve.island(ctx, opts, inner)` emits `<verve-island
  data-name=… data-props=…>` markers.
- **Build-time manifest codegen**
  (`tools/island_manifest_gen.zig`) walks `app.islands` and
  emits `client_manifest.zig` listing each island's name, props
  schema, and chunk URL.
- **Per-island WASM chunks** — `build.zig` parses
  `src/app/islands.zig` at configure time and builds one chunk
  per declared island. Custom logic via
  `src/client/islands/<Name>.zig`; everything else picks up a
  shared `_default.zig` stub.
- **Shared linear memory** — chunks import their memory from
  the main `client.wasm` via `env.memory`. Per-chunk size drops
  to ~73 bytes (vs. ~180 B standalone).
- JS bridge fetches chunks lazily, caches per name, copies props
  through shared scratch, calls `hydrate(ptr, len, root_id)`.
- In-process `verve_island_dispatch` for islands registered via
  `island.register(name, hydrate_fn)` in the main bundle.

### Added — Streaming SSR (out-of-order Suspense)

- `Suspense` boundary parks a continuation on the active
  `StreamRegistry` when `markSuspended()` fires and a registry
  is in scope.
- `verve.withStreamRegistry(reg, ctx, build_fn)` activates the
  thread-local for the lifetime of `build_fn`.
- `Renderer.streamRender(w, node, reg)` flushes the shell first,
  then drains every parked slot as
  `<template id="verve-vs-{id}">{real}</template>` +
  `verveSwap({id})` chunks.
- `window.verveSwap(id)` JS helper unwraps the matching template
  into the placeholder `<div data-vs="{id}">`. Reactive state
  on surrounding nodes survives.

### Added — SPA navigation

- `verve.link(ctx, href, label, opts)` emits anchors with
  `data-vlink`.
- Bridge intercepts same-origin clicks, fetches the page, merges
  `<head>` (title / meta by name|property / link by rel), swaps
  `<body>` innerHTML, pushes history.
- Optional prefetch-on-hover via `data-vprefetch="hover"`.
- `popstate` handler restores prior navigations.

### Added — Auth + security

- CSRF — HMAC-SHA256 token, auto-issued cookie + `__csrf` form
  field. `ctx.actionForm` injects the field automatically.
  `VERVE_CSRF_KEY` env var pins the secret across restarts.
- CSP nonce — per-request 12-byte hex nonce in
  `Content-Security-Policy: script-src 'nonce-…'
  'strict-dynamic'`.
- Origin pinning on form POSTs.
- `SameSite=Strict` on the CSRF cookie.
- `--csrf=enforce|disable` flag (default enforce).

### Added — Static assets

- `/public/*` routing — runtime via `--public-dir DIR`, or
  comptime-embedded via `-Dpublic-dir=DIR`.
- Hashed URLs (`/public/style-d5a73163.css`) with
  `Cache-Control: public, max-age=31536000, immutable`.
  `ctx.assetHref("style.css")` resolves the hashed form.
- mtime-aware LRU for `--public-dir` reads.
- Precompressed `.br` / `.gz` siblings served when present.

### Added — i18n

- `verve.I18nCatalog` + `resolveLocale` — cookie → query →
  Accept-Language → default with language-prefix fallback.

### Added — Dev + ops

- `--dev` auto-reload via injected WS-disconnect-reconnect
  script; `/__verve/dev_ws` upgrade endpoint.
- `/events` Server-Sent Events.
- `/ws` bidirectional WebSocket.
- `/health` — JSON: `{status, uptime_sec, requests}`.
- `/metrics` — per-route latency JSON.
- Bounded-admission worker pool (`--workers N`, default
  `CPU * 2`); excess returns 503.
- `LISTEN_FDS` env var for systemd socket activation.
- Graceful shutdown on `SIGINT` / `SIGTERM`.

### Added — Scaffolder

- `verve-cli new <dir>` writes the entire Verve source tree
  (sources + build wiring + test fixtures) into a target
  directory, emitting a fresh `build.zig.zon` with the chosen
  package name. Generated apps are self-contained — no Zig
  package-manager dependency, no git clone.

### Added — Build + tooling

- `zig build` produces a single-binary `verve-server` with the
  WASM client, per-island chunks, JS bridge, public assets, and
  manifest baked in. Plus `verve-cli` for scaffolding.
- `zig build test` runs 155+ tests spanning core / server /
  client / integration suites.
- `zig build docs` emits Zig autodoc HTML/JS to
  `zig-out/docs/api/`.
- 18 handwritten topic guides under `docs/`.
- 8 runnable example apps under `examples/`, including a full
  hybrid-product `showcase`.
- CI matrix (ubuntu-latest + macos-latest) runs `zig fmt`,
  `zig build`, `zig build test`, plus curl smoke tests against
  the live binary.

### Deferred (tracked for the 0.x line)

- **Phase 13F** — export the main runtime's Signal-registration
  + DOM-primitive symbols to per-island chunk imports so chunks
  can wire reactive state from inside their own `hydrate` body.
- **Phase 14C** — async `ctx.fetch` over `std.Io.async`
  (gated on Zig 0.16 ecosystem) so parked Suspense boundaries
  can genuinely wait on an upstream rather than re-running
  synchronously.
- **Typed WASM-side value returns** from server-fn calls
  (depends on Phase 14C's continuation shape).
- **Native TLS server** — production path today is to terminate
  TLS at a reverse proxy; revisit when `std.crypto.tls.Server`
  ships.
- **Brotli encoder** — gzip on the fly + precomputed `.br`
  siblings cover production today; revisit when a vetted
  pure-Zig brotli encoder lands.

[Unreleased]: https://github.com/sirhco/verve/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/sirhco/verve/releases/tag/v0.1.0
