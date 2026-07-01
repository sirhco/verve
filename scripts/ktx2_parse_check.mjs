// KTX2 parser cross-check (verve.gl KTX2/BC7+S3TC slice 3, Task 3C).
//
// Extracts the frozen `parseKtx2` block from src/bridge/verve.js (between the
// `>>> parseKtx2 ... >>>` / `<<< parseKtx2 <<<` sentinels) and runs it against a
// real `demo.tex0.bc7.ktx2` produced by `zig build`. This is the native proxy for
// the CDP gate: it catches any drift between the JS parser and the S1-frozen
// ktx2.zig container layout NOW.
//
// Also validates S3TC files via:
//   (a) raw KTX2 header reads (vkFormat, w/h, level0 byteLength) — structural gate
//   (b) parseKtx2 result — asserts format tag 4 (BC1_SRGB) for demo and 6 (BC3_SRGB)
//       for cutout, now that S3 extended parseKtx2 to know BC1/BC3 vkFormats.
//
// Usage: node scripts/ktx2_parse_check.mjs [path/to/demo.tex0.bc7.ktx2]
// (auto-discovers the newest demo.tex0.bc7.ktx2 under .zig-cache when omitted).

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

// --- locate a real KTX2 file by name under a directory -----------------------
function findKtx2(dir, name) {
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
      else if (e.name === name) {
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

// --- BC7 validation via parseKtx2 --------------------------------------------
const file = process.argv[2] || findKtx2(join(root, ".zig-cache"), "demo.tex0.bc7.ktx2");
if (!file) {
  console.error("FAIL: no demo.tex0.bc7.ktx2 found (run `zig build` first)");
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
let ok = true;
const checks = [
  ["w === 256", k.w === 256],
  ["h === 256", k.h === 256],
  ["format === 2 (BC7_SRGB)", k.format === 2],
  ["mip_count === 9", k.levels.length === 9],
  // Real structural check: block-data start (file - blocks) must equal ktx2.zig's
  // off_mip = ident+header+index (80) + levelCount*24 + DFD (28). Ties the parsed
  // level sizes back to the known S1 container geometry (catches parser drift).
  [
    "header === 80 + levelCount*24 + 28 (ktx2.zig off_mip)",
    headerBytes === 80 + k.levels.length * 24 + 28,
  ],
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

for (const [name, pass] of checks) {
  console.log(`${pass ? "PASS" : "FAIL"}: ${name}`);
  if (!pass) ok = false;
}

// --- S3TC validation via parseKtx2 (3C) --------------------------------------
// S3 extended parseKtx2 to know BC1/BC3 vkFormats; run it directly on the
// .s3tc.ktx2 siblings and assert the expected format tags.
function validateS3tcParsed(filePath, expectTag, label) {
  const buf = readFileSync(filePath);
  const kk = parseKtx2(buf);
  console.log(`\n${label} parseKtx2: ${kk ? `format=${kk.format} w=${kk.w} h=${kk.h} mips=${kk.levels.length}` : "null"}`);
  const parsed = [
    [`${label} parseKtx2 not null`, kk !== null],
    [`${label} format === ${expectTag}`, kk !== null && kk.format === expectTag],
    [`${label} w === 256`, kk !== null && kk.w === 256],
    [`${label} h === 256`, kk !== null && kk.h === 256],
    [`${label} mip_count === 9`, kk !== null && kk.levels.length === 9],
  ];
  for (const [name, pass] of parsed) {
    console.log(`${pass ? "PASS" : "FAIL"}: ${name}`);
    if (!pass) ok = false;
  }
}

// --- S3TC validation via raw KTX2 header reads --------------------------------
// Belt-and-suspenders structural gate (vkFormat, w/h, level0 byteLength).
//   KTX2 header layout (all little-endian):
//     0x00 [12] identifier
//     0x0C [4]  vkFormat
//     0x10 [4]  typeSize
//     0x14 [4]  pixelWidth
//     0x18 [4]  pixelHeight
//     0x28 [4]  levelCount
//     0x50 [8]  level[0].byteOffset  (level index starts at 0x50)
//     0x58 [8]  level[0].byteLength
// BC1 (no alpha): vkFormat 131 (UNORM) or 132 (SRGB); block = 8 bytes → 256²: 32768 B
// BC3 (alpha):    vkFormat 137 (UNORM) or 138 (SRGB); block = 16 bytes → 256²: 65536 B
const ktx2Ident = Buffer.from([
  0xab, 0x4b, 0x54, 0x58, 0x20, 0x32, 0x30, 0xbb, 0x0d, 0x0a, 0x1a, 0x0a,
]);

function validateS3tcRaw(filePath, expectVkFormats, expectLevel0Len, label) {
  const s3tcBuf = readFileSync(filePath);
  const identOk = ktx2Ident.every((b, i) => s3tcBuf[i] === b);
  const vkFormat = s3tcBuf.readUInt32LE(12);
  const pixW = s3tcBuf.readUInt32LE(20);
  const pixH = s3tcBuf.readUInt32LE(24);
  // level[0].byteLength is the second u64 in the first level-index entry (at 0x50+8 = 0x58).
  const level0Len = Number(s3tcBuf.readBigUInt64LE(0x58));

  console.log(`\n${label} file:   `, filePath, `(${s3tcBuf.length} bytes)`);
  console.log(`${label} vkFormat:`, vkFormat, `(expect ${expectVkFormats.join(" or ")})`);
  console.log(`${label} w/h:     `, pixW, pixH);
  console.log(`${label} level0:  `, level0Len, `(expect ${expectLevel0Len})`);

  const s3tcChecks = [
    [`${label} KTX2 identifier valid`, identOk],
    [`${label} vkFormat is ${expectVkFormats.join("/")}`, expectVkFormats.includes(vkFormat)],
    [`${label} w === 256`, pixW === 256],
    [`${label} h === 256`, pixH === 256],
    [`${label} level0 byteLength === ${expectLevel0Len}`, level0Len === expectLevel0Len],
  ];
  for (const [name, pass] of s3tcChecks) {
    console.log(`${pass ? "PASS" : "FAIL"}: ${name}`);
    if (!pass) ok = false;
  }
}

// demo.tex0 is opaque base-color → BC1 sRGB (vkFormat 132); 256²: 64×64 blocks × 8B = 32768 B
const demoS3tc = findKtx2(join(root, ".zig-cache"), "demo.tex0.s3tc.ktx2");
if (demoS3tc) {
  validateS3tcRaw(demoS3tc, [131, 132], 32768, "demo.s3tc");
  validateS3tcParsed(demoS3tc, 4, "demo.s3tc"); // 4 = BC1_RGB_SRGB (vk132)
} else {
  console.log("\nSKIP: demo.tex0.s3tc.ktx2 not found under .zig-cache (run `zig build` first)");
}

// cutout.tex0 has alpha → BC3 sRGB (vkFormat 138); 256²: 64×64 blocks × 16B = 65536 B
const cutoutS3tc = findKtx2(join(root, ".zig-cache"), "cutout.tex0.s3tc.ktx2");
if (cutoutS3tc) {
  validateS3tcRaw(cutoutS3tc, [137, 138], 65536, "cutout.s3tc");
  validateS3tcParsed(cutoutS3tc, 6, "cutout.s3tc"); // 6 = BC3_SRGB (vk138)
} else {
  console.log("\nSKIP: cutout.tex0.s3tc.ktx2 not found under .zig-cache (run `zig build` first)");
}

process.exit(ok ? 0 : 1);
