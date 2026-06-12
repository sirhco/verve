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
    extract("dragProject") + extract("dragSnapResolve") +
    extract("splitLineRuns") + extract("flipNatural") + extract("flipDelta") +
    extract("stSnapResolve") + extract("dragZoneHit") + extract("glTweenState") +
    "return { mpSample, buildMorphD, animIsTriggerOnly, dragProject, dragSnapResolve, " +
    "splitLineRuns, flipNatural, flipDelta, stSnapResolve, dragZoneHit, glTweenState };",
)();
const {
  mpSample, buildMorphD, animIsTriggerOnly, dragProject, dragSnapResolve,
  splitLineRuns, flipNatural, flipDelta, stSnapResolve, dragZoneHit, glTweenState,
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

if (fails === 0) {
  console.log("anim conformance: ALL PASS (mp + morph + routing + drag + split + flip + snap + gl)");
} else {
  console.log(`anim conformance: ${fails} FAILURES`);
  process.exit(1);
}
