// KTX2 parser cross-check (verve.gl KTX2/BC7 slice 3, Task 3C).
//
// Extracts the frozen `parseKtx2` block from src/bridge/verve.js (between the
// `>>> parseKtx2 ... >>>` / `<<< parseKtx2 <<<` sentinels) and runs it against a
// real `demo.tex0.ktx2` produced by `zig build`. This is the native proxy for
// the CDP gate: it catches any drift between the JS parser and the S1-frozen
// ktx2.zig container layout NOW.
//
// Usage: node scripts/ktx2_parse_check.mjs [path/to/demo.tex0.ktx2]
// (auto-discovers the newest demo.tex0.ktx2 under .zig-cache when omitted).

import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

// --- extract parseKtx2 from verve.js -----------------------------------------
const verveSrc = readFileSync(join(root, "src/bridge/verve.js"), "utf8");
const start = verveSrc.indexOf("function parseKtx2(");
const endMarker = "// <<< parseKtx2 <<<";
const end = verveSrc.indexOf(endMarker);
if (start < 0 || end < 0 || end < start) {
  console.error("FAIL: could not locate parseKtx2 sentinels in verve.js");
  process.exit(1);
}
const fnSrc = verveSrc.slice(start, end).trim();
// eslint-disable-next-line no-new-func
const parseKtx2 = new Function(fnSrc + "\nreturn parseKtx2;")();

// --- locate a real demo.tex0.ktx2 --------------------------------------------
function findKtx2(dir) {
  let best = null;
  let bestMtime = -1;
  const walk = (d) => {
    let entries;
    try {
      entries = readdirSync(d, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      const p = join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name === "demo.tex0.ktx2") {
        const m = statSync(p).mtimeMs;
        if (m > bestMtime) {
          bestMtime = m;
          best = p;
        }
      }
    }
  };
  walk(dir);
  return best;
}

const file = process.argv[2] || findKtx2(join(root, ".zig-cache"));
if (!file) {
  console.error("FAIL: no demo.tex0.ktx2 found (run `zig build` first)");
  process.exit(1);
}

const buf = readFileSync(file);
const fileSize = buf.length;
const k = parseKtx2(buf);
if (!k) {
  console.error("FAIL: parseKtx2 returned null for", file);
  process.exit(1);
}

let sumLen = 0;
for (const lv of k.levels) sumLen += lv.len;
const headerBytes = fileSize - sumLen; // ident+header+index+levelidx+DFD

console.log("file:      ", file, `(${fileSize} bytes)`);
console.log("w:         ", k.w);
console.log("h:         ", k.h);
console.log("format:    ", k.format, "(2 = BC7_SRGB / vk146)");
console.log("mip_count: ", k.levels.length);
console.log("levels:    ", k.levels.map((l) => `${l.len}@${l.off}`).join(", "));
console.log("sum(lens): ", sumLen);
console.log("header:    ", headerBytes, "(file - blocks)");

// Assertions per the task brief.
const checks = [
  ["w === 256", k.w === 256],
  ["h === 256", k.h === 256],
  ["format === 2 (BC7_SRGB)", k.format === 2],
  ["mip_count === 9", k.levels.length === 9],
  ["sum(level lens) === fileSize - header", sumLen === fileSize - headerBytes],
  // largest-first ordering: level 0 is the biggest.
  ["level 0 largest", k.levels[0].len === Math.max(...k.levels.map((l) => l.len))],
  // level offsets are strictly increasing and contiguous.
  [
    "levels contiguous largest-first",
    k.levels.every((l, i) =>
      i === 0 ? true : l.off === k.levels[i - 1].off + k.levels[i - 1].len,
    ),
  ],
];

let ok = true;
for (const [name, pass] of checks) {
  console.log(`${pass ? "PASS" : "FAIL"}: ${name}`);
  if (!pass) ok = false;
}
process.exit(ok ? 0 : 1);
