// Conformance check for the verve.js anim interpreter's pure functions
// against the Zig-side wire contract (serialize.zig golden tests).
//
// Run manually: node tests/js/anim_conformance.mjs
// (not wired into `zig build test` — node is not a build dependency)
//
// Slices `// @verve-extract <name>` ... `// @verve-extract-end` blocks
// out of src/bridge/verve.js and exercises them with the same inputs the
// Zig goldens freeze.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const src = readFileSync(join(root, "src", "bridge", "verve.js"), "utf8");

const extract = (name) => {
  const start = src.indexOf(`// @verve-extract ${name}\n`);
  const end = src.indexOf("// @verve-extract-end", start);
  if (start < 0 || end < 0) throw new Error(`extract block missing: ${name}`);
  return src.slice(start, end);
};

const fns = new Function(
  extract("mpSample") + extract("buildMorphD") + extract("animIsTriggerOnly") +
    extract("dragProject") + extract("dragBounce") + extract("dragSnapResolve") +
    extract("splitLineRuns") + extract("flipNatural") + extract("flipDelta") +
    extract("flipCounterScale") +
    extract("stSnapResolve") + extract("dragZoneHit") + extract("glTweenState") +
    extract("tweenHasGl") + extract("sortableSlotIndex") + extract("sortableAutoscroll") +
    "return { mpSample, buildMorphD, animIsTriggerOnly, dragProject, dragBounceReflect, dragSnapResolve, " +
    "splitLineRuns, flipNatural, flipDelta, flipCounterScale, flipCounterScaleClear, " +
    "stSnapResolve, dragZoneHit, glTweenState, tweenHasGl, sortableSlotIndex, sortableAutoscroll };",
)();
const {
  mpSample, buildMorphD, animIsTriggerOnly, dragProject, dragBounceReflect, dragSnapResolve,
  splitLineRuns, flipNatural, flipDelta, flipCounterScale, flipCounterScaleClear,
  stSnapResolve, dragZoneHit, glTweenState, tweenHasGl, sortableSlotIndex, sortableAutoscroll,
} = fns;

let fails = 0;
const check = (name, cond) => {
  if (!cond) {
    fails++;
    console.log("FAIL:", name);
  }
};
const approx = (a, b, eps = 1e-9) => Math.abs(a - b) < eps;

// ---- mpSample: golden "mp":{"pts":[0,0,5,0,10,0]} (stride 2) ----
{
  const pts = [0, 0, 5, 0, 10, 0];
  let v = mpSample(pts, 2, 0);
  check("mp e=0", approx(v[0], 0) && approx(v[1], 0));
  v = mpSample(pts, 2, 0.5);
  check("mp e=0.5 midpoint", approx(v[0], 5) && approx(v[1], 0));
  v = mpSample(pts, 2, 1);
  check("mp e=1 end", approx(v[0], 10));
  // quarter between sample 0 and 1
  v = mpSample(pts, 2, 0.25);
  check("mp e=0.25", approx(v[0], 2.5));
  // overshoot extrapolates along the end tangent (index clamped, t not)
  v = mpSample(pts, 2, 1.1);
  check("mp overshoot extrapolates", approx(v[0], 11));
  v = mpSample(pts, 2, -0.1);
  check("mp undershoot extrapolates", approx(v[0], -1));
}

// ---- mpSample stride 3: angle column lerps ----
{
  const pts = [0, 0, 0, 10, 0, 90];
  const v = mpSample(pts, 3, 0.5);
  check("mp stride3 angle", approx(v[0], 5) && approx(v[2], 45));
}

// ---- buildMorphD: golden line morph (1/3-2/3 contract) ----
// "mo":{"a":[0,0,3.33,0,6.67,0,10,0],"b":[0,0,0,3.33,0,6.67,0,10],"sp":[1]}
{
  const st = {
    a: [0, 0, 3.33, 0, 6.67, 0, 10, 0],
    b: [0, 0, 0, 3.33, 0, 6.67, 0, 10],
    sp: [1],
    z: null,
  };
  check("morph e=0", buildMorphD(st, 0) === "M0,0C3.33,0 6.67,0 10,0");
  check("morph e=1", buildMorphD(st, 1) === "M0,0C0,3.33 0,6.67 0,10");
  check(
    "morph e=0.5",
    buildMorphD(st, 0.5) === "M0,0C1.67,1.67 3.34,3.34 5,5",
  );
}

// ---- buildMorphD: closed flag + multi-subpath ----
{
  const st = {
    a: [0, 0, 1, 0, 2, 0, 3, 0, /* sub2 */ 10, 10, 11, 10, 12, 10, 13, 10],
    b: [0, 0, 1, 0, 2, 0, 3, 0, 10, 10, 11, 10, 12, 10, 13, 10],
    sp: [1, 1],
    z: [1, 0],
  };
  const d = buildMorphD(st, 0.5);
  check(
    "morph multi-subpath + z",
    d === "M0,0C1,0 2,0 3,0ZM10,10C11,10 12,10 13,10",
  );
}

// ---- animCreate routing: tween-less trigger vs animation carriers ----
// Regression: an mp-only (or mo-only) descriptor with "sc" must BUILD the
// animation (scrub needs something to drive), not route to the
// anim.reveal trigger-only path.
{
  check("reveal-only routes trigger-only",
    animIsTriggerOnly({ v: 1, sc: { s: [0, 0.85], cls: "in-view" } }) === true);
  check("props + sc builds anim",
    animIsTriggerOnly({ v: 1, p: { opacity: { f: 0 } }, sc: {} }) === false);
  check("mp + sc builds anim (scrubbed motion path)",
    animIsTriggerOnly({ v: 1, mp: { pts: [0, 0, 1, 1] }, sc: { scr: 0.3 } }) === false);
  check("mo + sc builds anim",
    animIsTriggerOnly({ v: 1, mo: { a: [], b: [], sp: [] }, sc: {} }) === false);
  check("keyframes + sc builds anim",
    animIsTriggerOnly({ v: 1, k: [], sc: {} }) === false);
  check("timeline + sc builds anim",
    animIsTriggerOnly({ v: 1, tl: 1, ch: [], sc: {} }) === false);
  check("no sc never trigger-only",
    animIsTriggerOnly({ v: 1, mp: { pts: [] } }) === false);
}

// ---- Draggable: inertia endpoint projection + snap resolution ----
{
  // total remaining travel of v(t) = v * r^t is v / ln(1/r)
  check("project 1000 @ r=0.05", approx(dragProject(1000, 0.05), 1000 / Math.log(20), 1e-9));
  check("project zero v", dragProject(0, 0.05) === 0);
  check("project negative v", dragProject(-500, 0.05) < 0);
  // higher retention coasts further
  check("retention ordering", dragProject(1000, 0.3) > dragProject(1000, 0.05));

  // grid snap: golden config "sn":{"g":[40,40]}
  let s = dragSnapResolve({ g: [40, 40] }, 37, 81);
  check("grid snap", s[0] === 40 && s[1] === 80);
  s = dragSnapResolve({ g: [40, 40] }, -19, -21);
  check("grid snap negative", s[0] === -0 + 0 || s[0] === 0);
  check("grid snap negative y", dragSnapResolve({ g: [40, 40] }, -19, -21)[1] === -40);
  // points: golden config "sn":{"p":[0,0,120,80]}
  s = dragSnapResolve({ p: [0, 0, 120, 80] }, 100, 70);
  check("points nearest", s[0] === 120 && s[1] === 80);
  s = dragSnapResolve({ p: [0, 0, 120, 80] }, 10, 10);
  check("points nearest origin", s[0] === 0 && s[1] === 0);
  // none = passthrough
  s = dragSnapResolve(null, 13.5, -2);
  check("snap none passthrough", s[0] === 13.5 && s[1] === -2);

  // routing: data-drag has its own attribute/scanner — the anim routing
  // predicate must not care about a "dr" key
  check("animIsTriggerOnly ignores dr",
    animIsTriggerOnly({ v: 1, sc: {}, dr: {} }) === true);
}

// ---- Draggable: elastic bounce reflection ----
{
  // bounce=1: fully elastic — velocity inverts, position mirrors
  let r = dragBounceReflect(110, 200, 100, 1.0);
  check("bounce=1 pos reflects at wall", approx(r.pos, 90));
  check("bounce=1 endpoint reflects", approx(r.endpoint, 0));

  // bounce=0.5: half damped
  // over = 120-100 = 20; rpos = 100 - 20*0.5 = 90
  // endOver = 200-100 = 100; rendpoint = 100 - 100*0.5 = 50
  r = dragBounceReflect(120, 200, 100, 0.5);
  check("bounce=0.5 pos half-damps", approx(r.pos, 90));
  check("bounce=0.5 endpoint half-damps", approx(r.endpoint, 50));

  // bounce=0: hard clamp — no overshoot, endpoint pins to wall
  r = dragBounceReflect(115, 180, 100, 0);
  check("bounce=0 pos pins to wall", approx(r.pos, 100));
  check("bounce=0 endpoint pins to wall", approx(r.endpoint, 100));

  // min wall (pos < min): reflect off lower bound
  r = dragBounceReflect(-10, -50, 0, 0.5);
  check("bounce min wall pos", approx(r.pos, 5)); // 0 - (-10)*0.5 = 5
  check("bounce min wall endpoint", approx(r.endpoint, 25)); // 0 - (-50)*0.5 = 25

  // no overshoot: calling with pos inside bounds should still apply formula
  // (caller guards; test that zero over = no change)
  r = dragBounceReflect(100, 100, 100, 0.5);
  check("bounce exact at wall no change", approx(r.pos, 100) && approx(r.endpoint, 100));
}

// ---- SplitText: offsetTop -> line runs ----
{
  check("runs empty", JSON.stringify(splitLineRuns([])) === "[]");
  check("runs single", JSON.stringify(splitLineRuns([0])) === "[[0,1]]");
  check("runs three lines",
    JSON.stringify(splitLineRuns([0, 0, 20, 20, 20, 40])) === "[[0,2],[2,5],[5,6]]");
  check("runs sub-0.5px jitter stays one line",
    JSON.stringify(splitLineRuns([0, 0.3, 0.4])) === "[[0,3]]");
}

// ---- FLIP: natural-rect recovery + center deltas ----
{
  const sId = { x: 0, y: 0, sx: 1, sy: 1 };
  // identity: equal rects, zero xform -> zero deltas, unit ratios
  let n1 = flipNatural({ left: 100, top: 50, width: 80, height: 40 }, sId);
  check("natural identity", n1.cx === 140 && n1.cy === 70 && n1.w === 80 && n1.h === 40);
  let d = flipDelta(n1, n1, true);
  check("delta identity", d.dx === 0 && d.dy === 0 && d.rx === 1 && d.ry === 1);

  // xform subtraction recovers natural center/size
  const sX = { x: 10, y: -5, sx: 2, sy: 2 };
  const n2 = flipNatural({ left: 60, top: 25, width: 160, height: 80 }, sX);
  check("natural subtracts translate", approx(n2.cx, 60 + 80 - 10) && approx(n2.cy, 25 + 40 + 5));
  check("natural divides scale", n2.w === 80 && n2.h === 40);

  // pure move
  const a2 = { cx: 0, cy: 0, w: 50, h: 50 };
  const b2 = { cx: 30, cy: -10, w: 50, h: 50 };
  d = flipDelta(a2, b2, true);
  check("delta move", d.dx === -30 && d.dy === 10 && d.rx === 1);

  // 2:1 scale ratio
  d = flipDelta({ cx: 0, cy: 0, w: 100, h: 60 }, { cx: 0, cy: 0, w: 50, h: 30 }, true);
  check("delta scale 2:1", d.rx === 2 && d.ry === 2);
  // useScale=false pins ratios
  d = flipDelta({ cx: 0, cy: 0, w: 100, h: 60 }, { cx: 0, cy: 0, w: 50, h: 30 }, false);
  check("delta scale pinned", d.rx === 1 && d.ry === 1);
  // degenerate last width -> ratio 1
  d = flipDelta({ cx: 0, cy: 0, w: 100, h: 60 }, { cx: 0, cy: 0, w: 0, h: 30 }, true);
  check("delta degenerate", d.rx === 1);
}

// ---- ScrollTrigger snap: progress-space resolution ----
{
  // step form
  check("snap step nearest down", stSnapResolve(0.25, 0.3, 1) === 0.25);
  check("snap step nearest up", stSnapResolve(0.25, 0.45, 1) === 0.5);
  check("snap step tie dir+", stSnapResolve(0.25, 0.375, 1) === 0.5);
  check("snap step tie dir-", stSnapResolve(0.25, 0.375, -1) === 0.25);
  check("snap step 1 rounds to end", stSnapResolve(1, 0.6, 1) === 1);
  check("snap step 1 rounds to start", stSnapResolve(1, 0.4, 1) === 0);
  check("snap step clamp at 1", stSnapResolve(0.25, 1, 1) === 1);
  check("snap step clamp at 0", stSnapResolve(0.25, 0, -1) === 0);
  // points form
  check("snap points nearest", stSnapResolve([0, 0.5, 1], 0.2, 1) === 0);
  check("snap points nearest mid", stSnapResolve([0, 0.5, 1], 0.6, 1) === 0.5);
  check("snap points tie dir+", stSnapResolve([0, 0.5], 0.25, 1) === 0.5);
  check("snap points tie dir-", stSnapResolve([0, 0.5], 0.25, -1) === 0);
  // directional snap (4th arg true): prefer target in direction of travel
  // step form directional
  check("snap step dir+ directional forward", stSnapResolve(0.25, 0.1, 1, true) === 0.25);
  check("snap step dir- directional backward", stSnapResolve(0.25, 0.9, -1, true) === 0.75);
  check("snap step dir+ directional skips behind", stSnapResolve(0.25, 0.49, 1, true) === 0.5);
  check("snap step dir- directional skips ahead", stSnapResolve(0.25, 0.26, -1, true) === 0.25);
  // points form directional
  check("snap points dir+ directional forward", stSnapResolve([0, 0.5, 1], 0.1, 1, true) === 0.5);
  check("snap points dir- directional backward", stSnapResolve([0, 0.5, 1], 0.9, -1, true) === 0.5);
  check("snap points dir+ directional fallback nearest when at end", stSnapResolve([0, 0.5, 1], 1, 1, true) === 1);
  check("snap points dir- directional fallback nearest when at start", stSnapResolve([0, 0.5, 1], 0, -1, true) === 0);
  // directional=false (explicit) behaves like nearest
  check("snap points non-directional explicit false", stSnapResolve([0, 0.5, 1], 0.2, 1, false) === 0);
  // boundary fling edge cases: just past snap point going forward/backward
  check("snap step fling forward past boundary", stSnapResolve(0.25, 0.26, 1, true) === 0.5);
  check("snap step fling backward past boundary", stSnapResolve(0.25, 0.24, -1, true) === 0.0);
}

// ---- Drag drop-zone hit testing ----
{
  const rects = [
    [0, 0, 100, 100],
    [50, 50, 150, 150], // overlaps zone 0
    [200, 0, 300, 100],
  ];
  check("zone inside", dragZoneHit(rects, 250, 50) === 2);
  check("zone boundary inclusive", dragZoneHit(rects, 100, 100) === 0);
  check("zone overlap first wins", dragZoneHit(rects, 75, 75) === 0);
  check("zone miss", dragZoneHit(rects, 175, 50) === -1);
  check("zone empty", dragZoneHit([], 10, 10) === -1);
}

// ---- gl-target tween state: wire facts + from-default contract ----
// props key "@gl:<id>", value {gl,gls,to,(f)}. glTargetFrom emits to:0 + f.
{
  // explicit from (glTargetFrom): f is the start, to is the end
  let s = glTweenState({ gl: 7, gls: 3, to: 6.283, f: 1.5 });
  check("gl explicit from/to", s.kind === "gl" && s.from === 1.5 && s.to === 6.283);
  check("gl ids coerced u32", s.gl === 7 && s.gls === 3);
  // from-only via glTargetFrom: to placeholder 0, f is the start
  s = glTweenState({ gl: 0, gls: 1, to: 0, f: 2.5 });
  check("gl from-only honors f", s.from === 2.5 && s.to === 0);
  // no f -> deterministic 0 start (engine value unknowable JS-side)
  s = glTweenState({ gl: 0, gls: 1, to: 6.283 });
  check("gl no-f defaults from 0", s.from === 0 && s.to === 6.283);
  // linear interpolation parity with the numeric path (from + (to-from)*e)
  const lerp = (st, e) => st.from + (st.to - st.from) * e;
  check("gl lerp e=0", approx(lerp(s, 0), 0));
  check("gl lerp e=0.5", approx(lerp(s, 0.5), 3.1415));
  check("gl lerp e=1", approx(lerp(s, 1), 6.283));
}

// ---- tweenHasGl: gates gl-only tweens past zero-DOM-target rejection ----
// A scrub timeline built with no DOM selector (anim.to(arena, null)) carries
// only "@gl:<id>" props; it must be recognized as gl-bearing so buildTweenInst
// runs it as one virtual instance instead of dropping it (the bug that left
// the /gl-scene turntable/roughness/node/emissive scrub dead).
{
  check("hasGl true for @gl prop", tweenHasGl({ "@gl:0": { gl: 0, gls: 1, to: 6.28 } }) === true);
  check("hasGl true mixed gl+dom", tweenHasGl({ opacity: { to: 1 }, "@gl:5": { gl: 5 } }) === true);
  check("hasGl false for dom-only", tweenHasGl({ opacity: { to: 1 }, x: { to: 10 } }) === false);
  check("hasGl false for null props", tweenHasGl(null) === false);
  check("hasGl false for empty props", tweenHasGl({}) === false);
}

// ---- flipCounterScale: inverse-scale math ----
// Simulates the DOM via plain objects with a .style.transform field.
{
  // Build a mock element with two children
  const makeEl = (n) => {
    const children = Array.from({ length: n }, () => ({ style: { transform: "" } }));
    return { children };
  };

  // scaleX=2, scaleY=1 → children get scale(0.5,1)
  {
    const el = makeEl(2);
    flipCounterScale(el, 2, 1);
    check("counterScale scaleX=2 child0", el.children[0].style.transform === "scale(0.5,1)");
    check("counterScale scaleX=2 child1", el.children[1].style.transform === "scale(0.5,1)");
  }

  // scaleX=1, scaleY=3 → children get scale(1,0.333...)
  {
    const el = makeEl(1);
    flipCounterScale(el, 1, 3);
    const expected = `scale(1,${1 / 3})`;
    check("counterScale scaleY=3", el.children[0].style.transform === expected);
  }

  // scaleX=0.5, scaleY=0.5 → children get scale(2,2)
  {
    const el = makeEl(1);
    flipCounterScale(el, 0.5, 0.5);
    check("counterScale shrink inverts", el.children[0].style.transform === "scale(2,2)");
  }

  // identity: sx=1, sy=1 → children get scale(1,1) (no-op)
  {
    const el = makeEl(1);
    flipCounterScale(el, 1, 1);
    check("counterScale identity", el.children[0].style.transform === "scale(1,1)");
  }

  // degenerate: sx=0 → treated as 1 (avoid divide-by-zero)
  {
    const el = makeEl(1);
    flipCounterScale(el, 0, 2);
    check("counterScale sx=0 degenerates to 1", el.children[0].style.transform === "scale(1,0.5)");
  }

  // clear: removes transform from all children
  {
    const el = makeEl(2);
    flipCounterScale(el, 2, 2);
    flipCounterScaleClear(el);
    check("counterScaleClear child0", el.children[0].style.transform === "");
    check("counterScaleClear child1", el.children[1].style.transform === "");
  }

  // no children: must not throw
  {
    const el = makeEl(0);
    let threw = false;
    try { flipCounterScale(el, 2, 2); flipCounterScaleClear(el); } catch { threw = true; }
    check("counterScale no children safe", !threw);
  }
}

// ---- sortableSlotIndex: insertion-slot from pointer + item rects ----
// Pure fn (pointerPos, itemRects, axis) → targetIndex.
// axis: 0=both/x+y (uses y), 1=x, 2=y (default).
// Each rect is {left, top, right, bottom} (or DOMRect-compatible).
// Returns the DROP slot index (0 = before first, n = after last).
{
  // Three equal-height items stacked vertically (y axis):
  // item 0: top=0   bottom=100
  // item 1: top=100 bottom=200
  // item 2: top=200 bottom=300
  const rects = [
    { left: 0, top: 0,   right: 100, bottom: 100 },
    { left: 0, top: 100, right: 100, bottom: 200 },
    { left: 0, top: 200, right: 100, bottom: 300 },
  ];
  // pointer above first item → slot 0
  check("sortable: above first → 0", sortableSlotIndex({ x: 50, y: -10 }, rects, 2) === 0);
  // pointer in top half of first item → slot 0 (before item 0)
  check("sortable: top-half item0 → 0", sortableSlotIndex({ x: 50, y: 25 }, rects, 2) === 0);
  // pointer in bottom half of first item → slot 1 (after item 0)
  check("sortable: bottom-half item0 → 1", sortableSlotIndex({ x: 50, y: 75 }, rects, 2) === 1);
  // pointer in top half of item 1 → slot 1 (before item 1)
  check("sortable: top-half item1 → 1", sortableSlotIndex({ x: 50, y: 125 }, rects, 2) === 1);
  // pointer in bottom half of item 1 → slot 2 (after item 1)
  check("sortable: bottom-half item1 → 2", sortableSlotIndex({ x: 50, y: 175 }, rects, 2) === 2);
  // pointer in top half of item 2 → slot 2
  check("sortable: top-half item2 → 2", sortableSlotIndex({ x: 50, y: 225 }, rects, 2) === 2);
  // pointer in bottom half of item 2 → slot 3 (after last)
  check("sortable: bottom-half item2 → 3", sortableSlotIndex({ x: 50, y: 275 }, rects, 2) === 3);
  // pointer below last item → slot 3
  check("sortable: below last → 3", sortableSlotIndex({ x: 50, y: 350 }, rects, 2) === 3);

  // x-axis (axis=1): three items side by side
  // item 0: left=0   right=100
  // item 1: left=100 right=200
  // item 2: left=200 right=300
  const hRects = [
    { left: 0,   top: 0, right: 100, bottom: 50 },
    { left: 100, top: 0, right: 200, bottom: 50 },
    { left: 200, top: 0, right: 300, bottom: 50 },
  ];
  check("sortable x: left of first → 0", sortableSlotIndex({ x: -5, y: 25 }, hRects, 1) === 0);
  check("sortable x: top-half item0 → 0", sortableSlotIndex({ x: 25, y: 25 }, hRects, 1) === 0);
  check("sortable x: bottom-half item0 → 1", sortableSlotIndex({ x: 75, y: 25 }, hRects, 1) === 1);
  check("sortable x: right of last → 3", sortableSlotIndex({ x: 350, y: 25 }, hRects, 1) === 3);

  // axis=0 (both/unspecified) falls back to y
  check("sortable axis=0 uses y", sortableSlotIndex({ x: 50, y: 25 }, rects, 0) === 0);
  check("sortable axis=0 uses y bottom", sortableSlotIndex({ x: 50, y: 75 }, rects, 0) === 1);

  // empty rects → always 0
  check("sortable: empty rects → 0", sortableSlotIndex({ x: 50, y: 50 }, [], 2) === 0);
}

// ---- sortableAutoscroll: edge-band scroll velocity pure fn ----
// Contract: (pointerPos, containerRect, edgePx) → scrollDelta
// • delta = 0 when pointer is outside the edge band (middle of container)
// • delta < 0 when pointer is within edgePx of the top edge (scroll up)
// • delta > 0 when pointer is within edgePx of the bottom edge (scroll down)
// • magnitude ramps from 0 (at outer boundary of band) to MAX_SPEED (at edge)
// • exactly at the edge band boundary → ~0 (but still within band so > 0)
// • magnitude is monotonically increasing with proximity to the edge
// • returns 0 when pointer is outside the container entirely
{
  // Container: top=100, bottom=500, edgePx=40
  // Middle band: y=140..460 → delta=0
  const rect = { left: 0, top: 100, right: 200, bottom: 500 };
  const edgePx = 40;

  // Pointer in the middle → 0
  check("autoscroll: middle → 0",
    sortableAutoscroll({ x: 100, y: 300 }, rect, edgePx) === 0);

  // Pointer near top edge (y=110, 10px from top=100, well within 40px band) → negative
  const nearTop = sortableAutoscroll({ x: 100, y: 110 }, rect, edgePx);
  check("autoscroll: near top → negative", nearTop < 0);

  // Pointer near bottom edge (y=490, 10px from bottom=500, well within 40px band) → positive
  const nearBottom = sortableAutoscroll({ x: 100, y: 490 }, rect, edgePx);
  check("autoscroll: near bottom → positive", nearBottom > 0);

  // Pointer outside container entirely → 0
  check("autoscroll: above container → 0",
    sortableAutoscroll({ x: 100, y: 50 }, rect, edgePx) === 0);
  check("autoscroll: below container → 0",
    sortableAutoscroll({ x: 100, y: 600 }, rect, edgePx) === 0);

  // Exactly at the outer boundary of the top band (y=140 = top+edgePx):
  // fromTop = 40 = edgePx → delta = 0 (band boundary, speed = 0)
  const atTopBoundary = sortableAutoscroll({ x: 100, y: 140 }, rect, edgePx);
  check("autoscroll: at top band boundary → 0", atTopBoundary === 0);

  // Exactly at the outer boundary of the bottom band (y=460 = bottom-edgePx):
  // fromBottom = 40 = edgePx → delta = 0
  const atBottomBoundary = sortableAutoscroll({ x: 100, y: 460 }, rect, edgePx);
  check("autoscroll: at bottom band boundary → 0", atBottomBoundary === 0);

  // Magnitude monotonic: closer to top → larger negative magnitude
  const close1 = sortableAutoscroll({ x: 100, y: 120 }, rect, edgePx); // 20px from top
  const close2 = sortableAutoscroll({ x: 100, y: 110 }, rect, edgePx); // 10px from top
  check("autoscroll: magnitude monotonic near top", Math.abs(close2) > Math.abs(close1));

  // Magnitude monotonic: closer to bottom → larger positive magnitude
  const close3 = sortableAutoscroll({ x: 100, y: 480 }, rect, edgePx); // 20px from bottom
  const close4 = sortableAutoscroll({ x: 100, y: 490 }, rect, edgePx); // 10px from bottom
  check("autoscroll: magnitude monotonic near bottom", Math.abs(close4) > Math.abs(close3));

  // Symmetry: same distance from top and bottom → same absolute magnitude
  const topDelta = sortableAutoscroll({ x: 100, y: 115 }, rect, edgePx); // 15px from top
  const botDelta = sortableAutoscroll({ x: 100, y: 485 }, rect, edgePx); // 15px from bottom
  check("autoscroll: symmetric magnitude top/bottom",
    Math.abs(Math.abs(topDelta) - Math.abs(botDelta)) < 1e-9);
}

// ---- sortableAutoscroll: HORIZONTAL axis path (ax=1) ----
// For a horizontal list the call site projects x→y and left/right→top/bottom
// before calling sortableAutoscroll, so the same pure fn covers both axes.
// These cases simulate exactly what the rAF call site passes for ax=1.
{
  // Horizontal container: left=200, right=800, edgePx=50
  // Call site transforms: pointerPos.y = pointer.x, rect.top = cr.left, rect.bottom = cr.right
  const hRect = { top: 200, bottom: 800 }; // left=200→top, right=800→bottom
  const edgePx = 50;

  // Pointer in the middle (x=500) → projected y=500, inside band 250..750 → 0
  check("autoscroll-h: middle → 0",
    sortableAutoscroll({ x: 0, y: 500 }, hRect, edgePx) === 0);

  // Pointer near left edge (x=210, 10px from left=200) → projected y=210, within 50px band → negative
  const nearLeft = sortableAutoscroll({ x: 0, y: 210 }, hRect, edgePx);
  check("autoscroll-h: near left edge → negative", nearLeft < 0);

  // Pointer near right edge (x=790, 10px from right=800) → projected y=790, within 50px band → positive
  const nearRight = sortableAutoscroll({ x: 0, y: 790 }, hRect, edgePx);
  check("autoscroll-h: near right edge → positive", nearRight > 0);

  // Pointer outside container (x=100, left of left=200) → projected y=100 < top=200 → 0
  check("autoscroll-h: left of container → 0",
    sortableAutoscroll({ x: 0, y: 100 }, hRect, edgePx) === 0);

  // Pointer outside container (x=900, right of right=800) → projected y=900 > bottom=800 → 0
  check("autoscroll-h: right of container → 0",
    sortableAutoscroll({ x: 0, y: 900 }, hRect, edgePx) === 0);

  // Magnitude monotonic: closer to left edge → larger negative
  const hClose1 = sortableAutoscroll({ x: 0, y: 230 }, hRect, edgePx); // 30px from left
  const hClose2 = sortableAutoscroll({ x: 0, y: 215 }, hRect, edgePx); // 15px from left
  check("autoscroll-h: magnitude monotonic near left", Math.abs(hClose2) > Math.abs(hClose1));

  // Symmetry: same distance left vs right → same absolute magnitude
  const leftD = sortableAutoscroll({ x: 0, y: 220 }, hRect, edgePx); // 20px from left
  const rightD = sortableAutoscroll({ x: 0, y: 780 }, hRect, edgePx); // 20px from right
  check("autoscroll-h: symmetric magnitude left/right",
    Math.abs(Math.abs(leftD) - Math.abs(rightD)) < 1e-9);
}

if (fails === 0) {
  console.log("anim conformance: ALL PASS (mp + morph + routing + drag + split + flip + snap + gl + gl-only + counter-scale + sortable-slot + sortable-autoscroll + sortable-autoscroll-h)");
} else {
  console.log(`anim conformance: ${fails} FAILURES`);
  process.exit(1);
}
