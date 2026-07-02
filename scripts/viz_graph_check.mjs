// viz_graph_check.mjs — canvas_buf binary validator for /viz/graph.bin.
//
// Reads the built graph.bin, parses the 48-byte canvas_buf header, validates
// node/edge counts (~1500 nodes, ~2949 edges), spot-checks known values from
// the deterministic genGraph algorithm, and verifies the total file size
// matches 48 + node_count*8 + edge_count*8.
//
// Mirrors the pattern of scripts/ktx2_parse_check.mjs (template).
//
// Usage:
//   node scripts/viz_graph_check.mjs /tmp/g.bin
//   node scripts/viz_graph_check.mjs          # auto-discovers under zig-out/

import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

// ── auto-discover under zig-out/ when no path given ────────────────────────
function findNewest(dir, name) {
  let best = null;
  let bestMtime = 0;
  const walk = (d) => {
    let entries;
    try { entries = readdirSync(d, { withFileTypes: true }); }
    catch { return; }
    for (const e of entries) {
      const p = join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name === name) {
        const m = statSync(p).mtimeMs;
        if (m > bestMtime) { bestMtime = m; best = p; }
      }
    }
  };
  walk(dir);
  return best;
}

const file = process.argv[2] || findNewest(join(root, "zig-out"), "graph.bin");
if (!file) {
  console.error("FAIL: no graph.bin found — run `zig build` first");
  process.exit(1);
}

const buf = readFileSync(file);
const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);

// ── header parse (48 bytes, little-endian) ─────────────────────────────────
const HEADER_SIZE = 48;
if (buf.length < HEADER_SIZE) {
  console.error(`FAIL: file too small (${buf.length} bytes, need at least ${HEADER_SIZE})`);
  process.exit(1);
}

const cam_x      = dv.getFloat32(0,  true);
const cam_y      = dv.getFloat32(4,  true);
const scale      = dv.getFloat32(8,  true);
const node_count = dv.getUint32(12,  true);
const edge_count = dv.getUint32(16,  true);
const hover      = dv.getInt32(20,   true);
const sel        = dv.getInt32(24,   true);
const node_r     = dv.getFloat32(28, true);

// ── size check ─────────────────────────────────────────────────────────────
const expected_size = HEADER_SIZE + node_count * 8 + edge_count * 8;
if (buf.length !== expected_size) {
  console.error(
    `FAIL: size mismatch: file=${buf.length} bytes, ` +
    `expected ${expected_size} (48 + ${node_count}*8 + ${edge_count}*8)`
  );
  process.exit(1);
}

// ── count sanity ───────────────────────────────────────────────────────────
if (node_count < 1400 || node_count > 1600) {
  console.error(`FAIL: node_count ${node_count} not near 1500`);
  process.exit(1);
}
if (edge_count < 2800 || edge_count > 3100) {
  console.error(`FAIL: edge_count ${edge_count} not plausible for ~1500-node graph`);
  process.exit(1);
}

// ── default header check ───────────────────────────────────────────────────
if (hover !== -1) {
  console.error(`FAIL: hover=${hover}, expected -1 (no hover)`);
  process.exit(1);
}
if (sel !== -1) {
  console.error(`FAIL: select=${sel}, expected -1 (no selection)`);
  process.exit(1);
}

// ── spot-check node 0 ─────────────────────────────────────────────────────
// node 0: i=0, col=0, row=0, hsh=(0*2654435761)>>16=0
//   jx = 0%17 - 8 = -8,  jy = (0/17)%17 - 8 = -8
//   xs[0] = 0*22 + (-8) = -8,  ys[0] = 0*22 + (-8) = -8
const x0 = dv.getFloat32(HEADER_SIZE,     true);
const y0 = dv.getFloat32(HEADER_SIZE + 4, true);
const eps = 0.001;
if (Math.abs(x0 - (-8)) > eps) {
  console.error(`FAIL: xs[0]=${x0}, expected -8`);
  process.exit(1);
}
if (Math.abs(y0 - (-8)) > eps) {
  console.error(`FAIL: ys[0]=${y0}, expected -8`);
  process.exit(1);
}

// ── spot-check first two edges ────────────────────────────────────────────
// edge[0]: i=1 left neighbour → ef[0]=1, et[0]=0
// edge[50]: i=50 upper neighbour → ef[50]=50, et[50]=0
const ebase = HEADER_SIZE + node_count * 8;
const ef0 = dv.getUint32(ebase,           true);
const et0 = dv.getUint32(ebase + 4,       true);
const ef50 = dv.getUint32(ebase + 50 * 8, true);
const et50 = dv.getUint32(ebase + 50 * 8 + 4, true);

if (ef0 !== 1 || et0 !== 0) {
  console.error(`FAIL: edge[0] = (${ef0},${et0}), expected (1,0)`);
  process.exit(1);
}
if (ef50 !== 50 || et50 !== 0) {
  console.error(`FAIL: edge[50] = (${ef50},${et50}), expected (50,0)`);
  process.exit(1);
}

console.log(`PASS: ${file}`);
console.log(`  size=${buf.length} bytes  nodes=${node_count}  edges=${edge_count}`);
console.log(`  header: cam=(${cam_x},${cam_y}) scale=${scale} node_r=${node_r} hover=${hover} select=${sel}`);
console.log(`  xs[0]=${x0} ys[0]=${y0}  edge[0]=(${ef0}→${et0})  edge[50]=(${ef50}→${et50})`);
