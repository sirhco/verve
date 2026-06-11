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
    "return { mpSample, buildMorphD, animIsTriggerOnly };",
)();
const { mpSample, buildMorphD, animIsTriggerOnly } = fns;

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

if (fails === 0) {
  console.log("anim conformance: ALL PASS (mpSample + buildMorphD)");
} else {
  console.log(`anim conformance: ${fails} FAILURES`);
  process.exit(1);
}
